# localai

A single-file installer that turns a bare EL8/9/10 (AlmaLinux, Rocky, RHEL,
Oracle Linux, CentOS Stream) or Fedora host into a local AI workspace: Docker
CE, an optional NVIDIA/AMD GPU container runtime, a native Ollama service,
and OmniRoute, Open WebUI, ComfyUI, and Dockge running as containers — all
bound to the Docker bridge gateway so nothing is exposed to the internet
except SSH.

---

## 📦 Install

Requires `x86_64` and one of AlmaLinux, Rocky Linux, RHEL, Oracle Linux,
CentOS Stream (8, 9, or 10), or Fedora, run as root.

```bash
curl -fsSL https://raw.githubusercontent.com/scriptmgr/localai/main/install.sh -o install.sh
sudo bash install.sh
```

The installer is idempotent — re-running it skips services that already
exist and reuses previously generated credentials.

### Configuration

Every setting is an environment variable with a sane default; override any
of them before running the script:

| Variable | Default | Purpose |
|----------|---------|---------|
| `PROFILE` | `auto` | `auto`, `cpu`, or `gpu` — forces the hardware profile |
| `MODEL_TIER` | `auto` | `auto`, `cpu`, `small`, `medium`, `large`, or `none` — which Ollama model set to pull |
| `INSTALL_GPU_DRIVER` | `0` | Install a missing NVIDIA driver automatically (requires a reboot) |
| `INSTALL_DOCKGE` | `1` | Deploy the Dockge stack manager |
| `INSTALL_COMFYUI` | `1` | Deploy ComfyUI |
| `PULL_MODELS` | `1` | Pull the selected model tier on first run |
| `OLLAMA_PORT` | `11434` | Port Ollama binds on the Docker bridge gateway |
| `STACKS_DIR` | `/opt/stacks` | Dockge-managed compose stacks directory |
| `CREDS_FILE` | `$HOME/.config/env/local-AI.sh` | Where generated secrets are stored (mode 0600) |
| `REQ_CORES` / `REQ_RAM_GB` / `REQ_VRAM_GB` / `REQ_DISK_GB` | `8` / `16` / `8` / `2000` | Minimum requirement floor |
| `SKIP_REQ_CHECK` | `0` | Bypass the minimum requirements gate |
| `ALLOW_OFFLOAD` | `1` | Let spare system RAM count toward a bigger model tier via CPU offload |

Example, forcing the CPU profile and skipping model downloads:

```bash
sudo PROFILE=cpu PULL_MODELS=0 bash install.sh
```

### Reaching the dashboards

Every service binds to the Docker bridge gateway only, so reach them with an
SSH tunnel:

```bash
ssh -L 8080:172.17.0.1:8080 -L 20128:172.17.0.1:20128 root@server
```

(The installer prints the exact gateway address and a ready-to-use tunnel
command at the end of the run.)

---

## 🛠️ Development

This project ships as a single Bash script — there is no build step.

```bash
shellcheck install.sh
bash -n install.sh
```

Testing changes safely requires a disposable EL/Fedora VM or container host
running Docker itself (the script refuses to run inside a container via
`/.dockerenv` detection, and refuses anything but `x86_64`).

---

## 📄 License

WTFPL — see [LICENSE.md](LICENSE.md)
