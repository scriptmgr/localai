# NVIDIA CUDA Installation Guide

## AlmaLinux 9 + ELRepo kernel-ml + RTX 2080 (Headless AI Server)

This guide installs the NVIDIA driver, CUDA toolkit, and NVIDIA Container Toolkit on:

* AlmaLinux 9
* ELRepo `kernel-ml`
* NVIDIA GeForce RTX 2080
* Headless AI/CUDA server
* Secure Boot disabled

---

# 1. Verify the Running Kernel

```bash
uname -r
```

Expected output:

```text
7.2.6-1.el9.elrepo.x86_64
```

---

# 2. Install Kernel Development Packages and DKMS

```bash
sudo dnf install -y \
    kernel-ml-devel-$(uname -r) \
    dkms
```

Verify:

```bash
rpm -q kernel-ml-devel
```

---

# 3. Check for Existing NVIDIA Packages

```bash
rpm -qa | grep -Ei 'nvidia|cuda'
```

If packages are found from a previous installation:

```bash
sudo dnf remove '*nvidia*' '*cuda*'
```

---

# 4. Check for Nouveau

Determine whether the open-source Nouveau driver is loaded:

```bash
lsmod | grep nouveau
```

If no output is returned, skip to Step 5.

If Nouveau is loaded, create a blacklist file:

```bash
sudo tee /etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
```

Rebuild the initramfs:

```bash
sudo dracut -f
```

---

# 5. Enable Required Repositories

Enable CRB:

```bash
sudo dnf config-manager --set-enabled crb
```

Install EPEL:

```bash
sudo dnf install -y epel-release
```

---

# 6. Add NVIDIA CUDA Repository

```bash
sudo dnf config-manager --add-repo \
https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo
```

Refresh metadata:

```bash
sudo dnf clean all
sudo dnf makecache
```

---

# 7. Enable NVIDIA Open DKMS Driver Stream

The RTX 2080 (Turing architecture) supports NVIDIA's open kernel modules.

```bash
sudo dnf module enable -y nvidia-driver:open-dkms
```

---

# 8. Install NVIDIA Driver

Preferred installation:

```bash
sudo dnf install -y nvidia-open
```

If `nvidia-open` is unavailable:

```bash
sudo dnf install -y \
    nvidia-driver-cuda \
    kmod-nvidia-open-dkms
```

---

# 9. Install CUDA Toolkit

Install CUDA compiler, headers, libraries, and development tools:

```bash
sudo dnf install -y cuda-toolkit
```

Verify:

```bash
nvcc --version
```

---

# 10. Reboot

```bash
sudo reboot
```

---

# 11. Verify Driver Installation

Check GPU visibility:

```bash
nvidia-smi
```

Verify loaded modules:

```bash
lsmod | grep nvidia
```

Expected modules:

```text
nvidia
nvidia_uvm
nvidia_modeset
```

Check DKMS status:

```bash
dkms status
```

---

# 12. Verify CUDA

```bash
nvcc --version
```

```bash
nvidia-smi
```

Both commands should complete successfully.

---

# 13. Install NVIDIA Container Toolkit (Recommended)

Install toolkit:

```bash
sudo dnf install -y nvidia-container-toolkit
```

Configure Docker:

```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

Test GPU access inside a container:

```bash
docker run --rm --gpus all \
  nvidia/cuda:12.9.1-base-rockylinux9 \
  nvidia-smi
```

The RTX 2080 should appear inside the container.

---

# Optional: Disable Graphical Target

For dedicated AI servers:

```bash
sudo systemctl set-default multi-user.target
```

---

# Quick Install

For a fresh system:

```bash
sudo dnf install -y kernel-ml-devel-$(uname -r) dkms epel-release

sudo dnf config-manager --set-enabled crb

sudo dnf config-manager --add-repo \
https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo

sudo dnf module enable -y nvidia-driver:open-dkms

sudo dnf install -y \
    nvidia-open \
    cuda-toolkit \
    nvidia-container-toolkit

sudo reboot
```

After reboot:

```bash
nvidia-smi
```
