#!/usr/bin/env bash
# AI Suite Installer for EL 8/9/10 (AlmaLinux, Rocky, RHEL, Oracle Linux,
# CentOS Stream, ...) and Fedora
#
# Installs: Docker CE, (optional) NVIDIA Container Toolkit, Ollama (native),
#           OmniRoute, Open WebUI, ComfyUI, and Dockge.
#
# Networking model:
#   Every service binds to the Docker bridge gateway (DOCKER_GW), discovered at
#   runtime rather than assumed to be 172.17.0.1. That address is reachable from
#   the host and from every bridge container, but is not routable from the
#   internet, so nothing is published on the public interface.
#
#   Reach the dashboards with an SSH tunnel, e.g.
#     ssh -L 8080:DOCKER_GW:8080 root@server

set -Eeo pipefail

# ---------------------------------------------------------------- configuration
CREDS_FILE=${CREDS_FILE:-$HOME/.config/env/local-AI.sh}
OLLAMA_PORT=${OLLAMA_PORT:-11434}
INSTALL_DOCKGE=${INSTALL_DOCKGE:-1}
INSTALL_COMFYUI=${INSTALL_COMFYUI:-1}
PULL_MODELS=${PULL_MODELS:-1}
STACKS_DIR=${STACKS_DIR:-/opt/stacks}

# ------------------------------------------------------ minimum requirements
# Two supported profiles. PROFILE=auto picks gpu when a card is present.
#   gpu  - requires REQ_VRAM_GB on a single card
#   cpu  - no GPU required; the VRAM floor does not apply
#
# These are a flat floor - the minimum to run this script "for anyone" -
# independent of which model tier gets selected below. A tier is still free to
# demand MORE than the floor (the large set wants 64 GB RAM, not 16), but never
# less: e.g. disk is a flat 2 TB even for the ~9 GB cpu model set, because the
# floor also has to cover container images, ComfyUI output, and general
# headroom, not just the models. Override any of these in the environment, or
# set SKIP_REQ_CHECK=1 to bypass the gate entirely.
PROFILE=${PROFILE:-auto}
REQ_CORES=${REQ_CORES:-8}
REQ_RAM_GB=${REQ_RAM_GB:-16}
REQ_VRAM_GB=${REQ_VRAM_GB:-8}          # only enforced under the gpu profile
REQ_DISK_GB=${REQ_DISK_GB:-2000}
SKIP_REQ_CHECK=${SKIP_REQ_CHECK:-0}

# A card present with no working driver is left alone by default - see the
# GPU / VRAM detection section for why (reboot + Secure Boot risk). Set to 1
# to install it automatically: ELRepo's kmod-nvidia on a kernel-ml/kernel-lt
# host, RPM Fusion's akmod-nvidia otherwise.
INSTALL_GPU_DRIVER=${INSTALL_GPU_DRIVER:-0}

# Model sets are chosen from the profile and detected VRAM. A 32B model at q8
# needs ~35 GB of VRAM to stay resident; on an 8 GB card Ollama spills most
# layers to CPU and throughput collapses, so the floor spec gets the small set.
# Tiers above small raise the RAM/VRAM bar past the floor above; MODEL_TIER=auto
# never selects a tier the detected hardware can't satisfy.
# MODEL_TIER=auto|cpu|small|medium|large|none
MODEL_TIER=${MODEL_TIER:-auto}

#                    approx download   VRAM needed   RAM recommended
#   cpu    (auto on no GPU)   ~9 GB        -              16 GB (floor)
#   small  (auto on  8-11GB) ~18 GB        8 GB           16 GB (floor)
#   medium (auto on 12-31GB) ~38 GB       12 GB           32 GB
#   large  (auto on   32GB+) ~73 GB       32 GB           64 GB
MODELS_CPU=(                          # ~9 GB, q4_K_M - the right quant for CPU
  "llama3.2:3b"                       #  2.0 GB
  "qwen2.5-coder:3b"                  #  1.9 GB
  "deepseek-r1:8b"                    #  5.2 GB
)
MODELS_SMALL=(                        # ~18 GB, fits an 8 GB card
  "llama3.1:8b"                       #  4.9 GB
  "qwen2.5-coder:7b-instruct-q8_0"    #  8.1 GB
  "deepseek-r1:8b"                    #  5.2 GB
)
MODELS_MEDIUM=(                       # ~38 GB, for 12-31 GB cards
  "${MODELS_SMALL[@]}"
  "deepseek-r1:32b"                   # 19.9 GB
)
MODELS_LARGE=(                        # ~73 GB, for 32 GB+ cards
  "${MODELS_MEDIUM[@]}"
  "qwen2.5-coder:32b-instruct-q8_0"   # 34.8 GB
)
# Note: the newest Llama generation is Llama 4, but llama4:scout is 67 GB and
# llama4:maverick is 245 GB - both well beyond the 8 GB floor, so neither is a
# default. Add manually on a large host: ollama pull llama4:scout

# -------------------------------------------------------------------- logging
if [ -t 1 ]; then B=$'\033[0;34m'; G=$'\033[0;32m'; Y=$'\033[0;33m'; R=$'\033[0;31m'; N=$'\033[0m'
else B=""; G=""; Y=""; R=""; N=""; fi
info() { printf '%s[ INFO ]%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s[  OK  ]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s[ WARN ]%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%s[ FAIL ]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
trap 'die "aborted at line $LINENO: ${BASH_COMMAND}"' ERR

have()           { command -v "$1" >/dev/null 2>&1; }
container_gone() { ! docker ps -a --format '{{.Names}}' | grep -qx "$1"; }

# ------------------------------------------------------------------- preflight
[ "$(id -u)" -eq 0 ] || die "run this installer as root (sudo -i)."
[ "$(uname -m)" = "x86_64" ] || die "this script targets x86_64; found $(uname -m)."
if [ -f /.dockerenv ]; then
  die "do not run this inside a container."
fi
# Detect the distro family and major version.
#   el     - RHEL and derivatives (AlmaLinux, Rocky, Oracle Linux, CentOS
#            Stream, ...). PLATFORM_ID is authoritative (platform:el9);
#            VERSION_ID is the fallback and may carry a minor (RHEL "9.4").
#   fedora - plain Fedora, which never sets PLATFORM_ID=platform:elN and
#            whose VERSION_ID is a bare release number (e.g. "42").
# EL_MAJOR is reused as "the distro's major version" for both families - it
# feeds dnf's $releasever substitution either way.
OS_FAMILY=""
EL_MAJOR=""
if [ -r /etc/os-release ]; then
  # shellcheck source=/dev/null
  . /etc/os-release
  case "${PLATFORM_ID:-}" in platform:el*) EL_MAJOR=${PLATFORM_ID#platform:el} ;; esac
  if [ -n "$EL_MAJOR" ]; then
    OS_FAMILY=el
  elif [ "${ID:-}" = "fedora" ]; then
    OS_FAMILY=fedora
    EL_MAJOR=${VERSION_ID%%.*}
  else
    OS_FAMILY=el
    EL_MAJOR=${VERSION_ID%%.*}
  fi
fi
if [ "$OS_FAMILY" = "fedora" ]; then
  case "$EL_MAJOR" in
    ''|*[!0-9]*) die "could not determine the Fedora version from /etc/os-release." ;;
    *) ok "Detected ${NAME:-Fedora} ${VERSION_ID:-$EL_MAJOR}." ;;
  esac
else
  case "$EL_MAJOR" in
    8|9|10) ok "Detected ${NAME:-EL} ${VERSION_ID:-$EL_MAJOR} (el${EL_MAJOR})." ;;
    ''|*[!0-9]*) die "could not determine the EL major version from /etc/os-release." ;;
    *)
      if [ "$EL_MAJOR" -ge 11 ]; then
        warn "el${EL_MAJOR} is newer than this script was tested against; continuing."
      else
        die "el${EL_MAJOR} is too old - this script needs dnf and systemd (EL8+)."
      fi
      ;;
  esac
fi

# KERNEL_PKG is the RPM that owns the running kernel's module directory -
# kernel, kernel-ml, kernel-lt, kernel-uek, etc. Deriving it this way (rather
# than pattern-matching `uname -r`) is what makes the later kernel-module and
# driver steps generalize correctly across stock, ELRepo, and UEK kernels
# without hardcoding each case.
KERNEL_RELEASE=$(uname -r)
KERNEL_PKG=$(rpm -qf --qf '%{NAME}\n' "/lib/modules/${KERNEL_RELEASE}" 2>/dev/null || true)
case "$KERNEL_PKG" in
  kernel|'') ;;  # stock kernel, or rpm -qf couldn't resolve it - nothing extra to say
  *) info "Running ${KERNEL_PKG} (${KERNEL_RELEASE}) - matching kernel-module packages are named ${KERNEL_PKG}-*, not kernel-*." ;;
esac


if have getenforce && [ "$(getenforce)" = "Enforcing" ]; then SELINUX_ON=1; else SELINUX_ON=0; fi

# ------------------------------------------------------- GPU / VRAM detection
# GPU_VENDOR is nvidia, amd or none. DRIVER_OK distinguishes "no card" from
# "card present but the driver isn't working" - nvidia-smi/kfd success alone
# can't tell those apart, so PCI presence is checked independently via
# pciutils (cheap, safe, installed unconditionally for this one purpose).
if ! have lspci; then
  dnf install -y pciutils >/dev/null 2>&1 || true
fi
GPU_PCI=""
if have lspci; then
  GPU_PCI=$(lspci 2>/dev/null| grep -iE 'vga|3d|display'|| true)   # PCI class 03xx = display controllers
fi
PCI_NVIDIA=0
PCI_AMD=0
if printf '%s' "$GPU_PCI" | grep -qi nvidia; then PCI_NVIDIA=1; fi
if printf '%s' "$GPU_PCI" | grep -Eqi 'AMD|ATI|Advanced Micro Devices'; then PCI_AMD=1; fi

GPU_VENDOR=none
DRIVER_OK=0
VRAM_GB=0
if have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then
  GPU_VENDOR=nvidia
  DRIVER_OK=1
  VRAM_MIB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
             | sort -rn | head -n1)
  VRAM_GB=$(( ${VRAM_MIB:-0} / 1024 ))
  ok "NVIDIA GPU: $(nvidia-smi -L | head -n1) (${VRAM_GB} GB VRAM)"
elif [ "$PCI_NVIDIA" -eq 1 ]; then
  GPU_VENDOR=nvidia
  DRIVER_OK=0
  warn "NVIDIA card detected on the PCI bus, but no working driver (nvidia-smi failed)."
elif [ -e /dev/kfd ] || compgen -G "/sys/class/drm/card*/device/mem_info_vram_total" >/dev/null; then
  GPU_VENDOR=amd
  DRIVER_OK=1
  VRAM_BYTES=$(cat /sys/class/drm/card*/device/mem_info_vram_total 2>/dev/null | sort -rn | head -n1)
  VRAM_GB=$(( ${VRAM_BYTES:-0} / 1024 / 1024 / 1024 ))
  ok "AMD GPU detected via ROCm/amdgpu (${VRAM_GB} GB VRAM)"
elif [ "$PCI_AMD" -eq 1 ]; then
  GPU_VENDOR=amd
  DRIVER_OK=0
  warn "AMD card detected on the PCI bus, but /dev/kfd is not present (amdgpu not loaded)."
else
  warn "No GPU found on the PCI bus. Installing CPU-only."
fi

# NVIDIA's driver is not in-kernel and genuinely needs installing; AMD's
# amdgpu ships in the kernel itself, so a missing /dev/kfd with a card
# present usually means a reboot is pending after a kernel update, or the
# card predates/postdates this kernel's amdgpu support - neither is fixable
# by installing a package, so AMD gets a diagnostic message, not an install.
if [ "$GPU_VENDOR" = "nvidia" ] && [ "$DRIVER_OK" -eq 0 ]; then
  if [ "$INSTALL_GPU_DRIVER" -eq 1 ]; then
    if [ -z "$KERNEL_PKG" ]; then
      die "could not determine the running kernel's package - can't select a matching kernel-devel for the driver build."
    fi

    # ELRepo and RPM Fusion both ship NVIDIA drivers, on different release
    # cadences. On an ELRepo kernel (kernel-ml/kernel-lt), ELRepo's own
    # kmod-nvidia is the better default - released by the same team as the
    # kernel itself, so it's more likely tested against exactly this kernel
    # version. RPM Fusion's akmod-nvidia rebuilds locally against whatever
    # kernel is running, which works fine on a stock kernel's slower release
    # pace but can lag kernel-ml's faster one. Any other kernel keeps RPM
    # Fusion, since there's no evidence ELRepo's driver is the better choice
    # there.
    DRIVER_SOURCE=rpmfusion
    case "$KERNEL_PKG" in
      kernel-ml|kernel-lt) DRIVER_SOURCE=elrepo ;;
    esac

    DRIVER_INSTALLED=0
    if [ "$DRIVER_SOURCE" = "elrepo" ]; then
      info "Kernel is ${KERNEL_PKG} - installing the NVIDIA driver via ELRepo (kmod-nvidia)..."

      # RPM Fusion's akmod-nvidia rebuilds against whatever kernel is running
      # regardless of source, so a pre-existing install would keep fighting
      # ELRepo's pre-built module for ownership of the nvidia device. Glob-
      # matched for the same reason as below: per-kernel akmod build artifacts
      # aren't a fixed set of names.
      RPMFUSION_NVIDIA_PKGS=$(rpm -qa 'akmod-nvidia*' 'kmod-nvidia-*-akmod*' 'xorg-x11-drv-nvidia*' 2>/dev/null || true)
      if [ -n "$RPMFUSION_NVIDIA_PKGS" ]; then
        for CONFLICT_PKG in $RPMFUSION_NVIDIA_PKGS; do
          info "Removing ${CONFLICT_PKG} (RPM Fusion's NVIDIA driver - conflicts with ELRepo's kmod-nvidia)..."
          rpm -e --nodeps "$CONFLICT_PKG" || warn "could not remove ${CONFLICT_PKG}; the kmod-nvidia install below may fail."
        done
      fi

      if ! dnf install -y nvidia-detect >/dev/null 2>&1; then
        warn "could not install nvidia-detect - is ELRepo enabled on this host?"
      else
        # nvidia-detect prints its recommendation (e.g. "kmod-nvidia" or
        # "kmod-nvidia-580xx") on its own last line - which exact package a
        # card needs isn't knowable ahead of time, that's the tool's job.
        NVIDIA_PKG=$(nvidia-detect 2>/dev/null | tail -n1)
        if [ -z "$NVIDIA_PKG" ]; then
          warn "nvidia-detect could not identify a driver package for this card."
        elif dnf install -y "$NVIDIA_PKG" >/dev/null 2>&1; then
          DRIVER_INSTALLED=1
        else
          warn "could not install ${NVIDIA_PKG} from ELRepo."
        fi
      fi
    else
      # ELRepo also ships NVIDIA drivers (kmod-nvidia*), independent of RPM
      # Fusion's. Running both is a well-documented conflict - competing
      # kernel modules, competing akmod/weak-modules build hooks - so any
      # ELRepo variant is removed first. Glob-matched rather than a fixed name
      # list: ELRepo publishes per-kernel-version and legacy-branch
      # subpackages (kmod-nvidia-580xx, kmod-nvidia-<kernel-version>, ...)
      # that a literal package name wouldn't catch.
      ELREPO_NVIDIA_PKGS=$(rpm -qa 'kmod-nvidia*' 'nvidia-x11-drv*' 2>/dev/null || true)
      if [ -n "$ELREPO_NVIDIA_PKGS" ]; then
        for CONFLICT_PKG in $ELREPO_NVIDIA_PKGS; do
          info "Removing ${CONFLICT_PKG} (ELRepo's NVIDIA driver - conflicts with RPM Fusion's akmod-nvidia)..."
          rpm -e --nodeps "$CONFLICT_PKG" || warn "could not remove ${CONFLICT_PKG}; the akmod-nvidia install below may fail."
        done
      fi

      info "Installing the NVIDIA driver via RPM Fusion (akmod-nvidia)..."
      if dnf install -y akmod-nvidia "${KERNEL_PKG}-devel" >/dev/null 2>&1; then
        info "Building the kernel module for ${KERNEL_RELEASE} (akmods, can take a few minutes)..."
        akmods --force >/dev/null 2>&1 || true
        DRIVER_INSTALLED=1
      else
        warn "could not install akmod-nvidia - is RPM Fusion nonfree enabled on this host?"
      fi
    fi

    if [ "$DRIVER_INSTALLED" -eq 1 ]; then
      # Without this, the reboot below doesn't actually produce a working
      # driver: nouveau (the in-kernel open-source driver) loads first and
      # claims the card, and the proprietary module then refuses to load
      # alongside it. This applies regardless of which vendor built that
      # module. Blacklisting alone isn't enough either - nouveau is commonly
      # loaded from the initramfs itself, before /etc/modprobe.d on the real
      # root is ever consulted - so the initramfs has to be rebuilt too.
      info "Blacklisting nouveau (conflicts with the proprietary driver) and rebuilding the initramfs..."
      cat >/etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
      if ! dracut --force >/dev/null 2>&1; then
        warn "dracut failed to rebuild the initramfs - nouveau may still load at boot and block the NVIDIA module."
      fi

      SECURE_BOOT_ON=0
      if have mokutil && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
        SECURE_BOOT_ON=1
      fi
      cat <<EOF

==========================================================================
 NVIDIA driver installed (${DRIVER_SOURCE}) - a REBOOT is required before it
 will load.
==========================================================================
EOF
      if [ "$SECURE_BOOT_ON" -eq 1 ]; then
        if [ "$DRIVER_SOURCE" = "elrepo" ]; then
          cat <<EOF
 Secure Boot is ENABLED. ELRepo signs kmod-nvidia with their own key rather
 than a locally-generated one, so there's no key to build - just import the
 one already on disk and enroll it at next boot (interactive password
 prompt, cannot be scripted):
   mokutil --import /etc/pki/elrepo/SECURE-BOOT-KEY-elrepo.org.der
 (If that file is missing: wget https://elrepo.org/SECURE-BOOT-KEY-elrepo.org.der)
 Details: https://elrepo.org/wiki/doku.php?id=secureboot
EOF
        else
          cat <<EOF
 Secure Boot is ENABLED. The freshly built module will not load until it is
 MOK-enrolled (or Secure Boot is disabled) - this needs an interactive
 password prompt at boot and cannot be scripted. See:
   https://rpmfusion.org/Howto/Secure%20Boot
EOF
        fi
      fi
      cat <<EOF
 Reboot now, then re-run this script to continue with the driver active.
==========================================================================
EOF
      exit 0
    else
      warn "Install the NVIDIA driver yourself, then re-run this script."
    fi
  else
    warn "Set INSTALL_GPU_DRIVER=1 to install it automatically - ELRepo's kmod-nvidia on a"
    warn "kernel-ml/kernel-lt host, RPM Fusion's akmod-nvidia otherwise. Either way this"
    warn "requires a reboot afterward, and won't work if Secure Boot is enabled without"
    warn "MOK-enrolling the driver's signing key first."
    warn "Continuing as CPU profile for this run."
  fi
elif [ "$GPU_VENDOR" = "amd" ] && [ "$DRIVER_OK" -eq 0 ]; then
  warn "amdgpu is part of the kernel itself - nothing to install. If this card was just"
  warn "installed or the kernel was just updated, a reboot often fixes it. Otherwise this"
  warn "kernel's amdgpu may not support this card. Check: dmesg | grep -i amdgpu"
fi

# A card with no working driver has no usable VRAM this run, whatever
# INSTALL_GPU_DRIVER is set to - fall back to the cpu profile rather than
# treating it as a GPU host with 0 GB of VRAM.
if [ "$DRIVER_OK" -eq 0 ]; then
  GPU_VENDOR=none
  VRAM_GB=0
fi

# ---------------------------------------------------- minimum requirements gate
if [ "$PROFILE" = "auto" ]; then
  if [ "$GPU_VENDOR" = "none" ]; then
    PROFILE=cpu
  else
    PROFILE=gpu
  fi
fi
case "$PROFILE" in
  cpu) ok "Installing in CPU profile - the VRAM requirement does not apply." ;;
  gpu) [ "$GPU_VENDOR" != "none" ] || die "PROFILE=gpu but no NVIDIA or AMD GPU was detected." ;;
  *)   die "PROFILE must be auto, cpu or gpu." ;;
esac

CPU_CORES=$(nproc)
RAM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)

# Resolve the model tier BEFORE the gate, because the thresholds derive from it.
#
# ALLOW_OFFLOAD lets a modest card still auto-select a bigger, better tier when
# the host has RAM to spare: Ollama puts whatever doesn't fit in VRAM into
# system RAM and runs those layers on the CPU. That works, but per-token speed
# on the offloaded layers is far below GPU-resident speed. OFFLOAD_RESERVE_GB
# is held back for the OS, Docker, and the other containers this script runs;
# whatever RAM remains counts as extra capacity alongside VRAM when picking a
# tier. Set ALLOW_OFFLOAD=0 to size the tier off VRAM alone, as before.
ALLOW_OFFLOAD=${ALLOW_OFFLOAD:-1}
OFFLOAD_RESERVE_GB=${OFFLOAD_RESERVE_GB:-16}

if [ "$MODEL_TIER" = "auto" ]; then
  OFFLOAD_ROOM_GB=0
  CAPACITY_GB=$VRAM_GB
  if [ "$PROFILE" = "cpu" ]; then
    MODEL_TIER=cpu
  else
    if [ "$ALLOW_OFFLOAD" -eq 1 ]; then
      OFFLOAD_ROOM_GB=$(( RAM_GB - OFFLOAD_RESERVE_GB ))
      if [ "$OFFLOAD_ROOM_GB" -lt 0 ]; then
        OFFLOAD_ROOM_GB=0
      fi
      CAPACITY_GB=$(( VRAM_GB + OFFLOAD_ROOM_GB ))
    fi
    if [ "$CAPACITY_GB" -ge 32 ]; then
      MODEL_TIER=large
    elif [ "$CAPACITY_GB" -ge 12 ]; then
      MODEL_TIER=medium
    else
      MODEL_TIER=small
    fi
  fi
  if [ "$PROFILE" = "cpu" ]; then
    info "Selected the ${MODEL_TIER} model set (cpu profile, ${RAM_GB} GB RAM)."
  elif [ "$ALLOW_OFFLOAD" -eq 1 ]; then
    info "Selected the ${MODEL_TIER} model set (${PROFILE} profile, ${VRAM_GB} GB VRAM + up to ${OFFLOAD_ROOM_GB} GB RAM offload)."
  else
    info "Selected the ${MODEL_TIER} model set (${PROFILE} profile, ${VRAM_GB} GB VRAM)."
  fi
else
  info "Model tier forced to ${MODEL_TIER}."
fi

#                       models  VRAM needed  RAM recommended
case "$MODEL_TIER" in
  none)   MODELS=();                      TIER_VRAM_REC=0;  TIER_RAM_REC=0  ;;
  cpu)    MODELS=("${MODELS_CPU[@]}");    TIER_VRAM_REC=0;  TIER_RAM_REC=0  ;;
  small)  MODELS=("${MODELS_SMALL[@]}");  TIER_VRAM_REC=8;  TIER_RAM_REC=0  ;;
  medium) MODELS=("${MODELS_MEDIUM[@]}"); TIER_VRAM_REC=12; TIER_RAM_REC=32 ;;
  large)  MODELS=("${MODELS_LARGE[@]}");  TIER_VRAM_REC=32; TIER_RAM_REC=64 ;;
  *) die "MODEL_TIER must be auto, cpu, small, medium, large or none." ;;
esac
if [ "$PROFILE" = "cpu" ]; then
  TIER_VRAM_REC=0   # the cpu tier never needs VRAM
fi

# The floor above is a hard minimum for anyone running this script; a tier can
# only raise the effective bar past it (medium/large want more RAM and VRAM
# than the floor gives), never lower it - disk in particular stays flat at the
# floor regardless of tier, since it covers images and general headroom, not
# just models.
EFF_RAM_GB=$REQ_RAM_GB
if [ "$TIER_RAM_REC" -gt "$EFF_RAM_GB" ]; then
  EFF_RAM_GB=$TIER_RAM_REC
fi
EFF_VRAM_GB=$REQ_VRAM_GB
if [ "$TIER_VRAM_REC" -gt "$EFF_VRAM_GB" ]; then
  EFF_VRAM_GB=$TIER_VRAM_REC
fi

# Available space on each distinct filesystem backing the two data paths.
mkdir -p /var/lib/docker /usr/share/ollama
chmod 777 /usr/share/ollama
DISK_GB=$(df -BG --output=avail,target /var/lib/docker /usr/share/ollama 2>/dev/null \
          | tail -n +2 | sort -u -k2,2 | awk '{gsub(/G/,"",$1); s+=$1} END {printf "%d", s}')

info "System: ${CPU_CORES} cores, ${RAM_GB} GB RAM, ${DISK_GB} GB free, ${VRAM_GB} GB VRAM (${PROFILE} profile)"
info "Floor: ${REQ_CORES} cores, ${REQ_RAM_GB} GB RAM, ${REQ_DISK_GB} GB disk, ${REQ_VRAM_GB} GB VRAM"
if [ "$EFF_RAM_GB" -gt "$REQ_RAM_GB" ] || [ "$EFF_VRAM_GB" -gt "$REQ_VRAM_GB" ]; then
  info "The ${MODEL_TIER} model set recommends ${EFF_RAM_GB} GB RAM / ${EFF_VRAM_GB} GB VRAM (above the floor)."
fi

REQ_FAILED=()
[ "$CPU_CORES" -ge "$REQ_CORES" ]  || REQ_FAILED+=("CPU cores: ${CPU_CORES} < ${REQ_CORES}")
[ "$DISK_GB"   -ge "$REQ_DISK_GB" ] || REQ_FAILED+=("Free disk: ${DISK_GB} GB < ${REQ_DISK_GB} GB")
# RAM and VRAM are compared against the floor with a small tolerance: a "16 GB"
# host reports ~15 GB usable once firmware and integrated video have taken
# their reservations.
[ "$RAM_GB" -ge $(( REQ_RAM_GB - 1 )) ] || REQ_FAILED+=("RAM: ${RAM_GB} GB < ${REQ_RAM_GB} GB")
if [ "$REQ_VRAM_GB" -gt 0 ] && [ "$PROFILE" = "gpu" ] && [ "$VRAM_GB" -lt $(( REQ_VRAM_GB - 1 )) ]; then
  REQ_FAILED+=("VRAM: ${VRAM_GB} GB < ${REQ_VRAM_GB} GB")
fi

# A tier recommendation the floor didn't already cover is a warning, not a
# gate failure: the small set still runs on a 16 GB / 8 GB box, just fine.
if [ "$RAM_GB" -lt $(( TIER_RAM_REC - 1 )) ]; then
  warn "${RAM_GB} GB RAM is below the ${TIER_RAM_REC} GB recommended for the ${MODEL_TIER} set - expect swapping under load."
fi
if [ "$PROFILE" = "gpu" ] && [ "$VRAM_GB" -lt $(( TIER_VRAM_REC - 1 )) ]; then
  warn "${VRAM_GB} GB VRAM is below the ${TIER_VRAM_REC} GB recommended for the ${MODEL_TIER} set - expect CPU offload."
fi
if [ "$PROFILE" = "cpu" ]; then
  warn "No GPU acceleration. Expect a few tokens/sec; 3B models stay responsive, 8B is slow."
fi

if [ "${#REQ_FAILED[@]}" -gt 0 ]; then
  for f in "${REQ_FAILED[@]}"; do warn "requirement not met - ${f}"; done
  if [ "$SKIP_REQ_CHECK" -eq 1 ]; then
    warn "SKIP_REQ_CHECK=1 set - continuing on an under-specified host."
  else
    die "minimum requirements not met. Re-run with SKIP_REQ_CHECK=1 to override."
  fi
else
  ok "System meets minimum requirements."
fi

# ------------------------------------------------------ 0. persistent secrets
# Regenerating on a re-run would lock you out of an existing OmniRoute install,
# so secrets are written once and sourced back afterwards.
umask 077
mkdir -p "$(dirname "$CREDS_FILE")"
if [ -f "$CREDS_FILE" ]; then
  info "Reusing credentials from $CREDS_FILE"
else
  info "Generating credentials -> $CREDS_FILE"
  cat >"$CREDS_FILE" <<EOF
# AI Suite generated secrets - keep private. Sourced by the installer.
OMNI_API_KEY_SECRET='$(openssl rand -hex 32)'
OMNI_JWT_SECRET='$(openssl rand -base64 48)'
OMNI_STORAGE_KEY='$(openssl rand -hex 32)'
OMNI_WS_BRIDGE_SECRET='$(openssl rand -base64 32)'
OMNI_ADMIN_PASS='$(openssl rand -base64 18)'
EOF
fi
chmod 600 "$CREDS_FILE"
# shellcheck source=/dev/null
. "$CREDS_FILE"

# ------------------------------------------------------------- 1. base packages
info "Refreshing package metadata..."
dnf check-update >/dev/null || true          # exit 100 just means "updates exist"
dnf install -y curl ca-certificates openssl zstd tar iproute >/dev/null
ok "Base packages ready."

# ----------------------------------------------------------------- 2. Docker CE
# rpm -q docker-ce rather than `have docker`: podman-docker ships a
# /usr/bin/docker shim that satisfies `command -v docker` identically to the
# real thing, which would otherwise make this check skip the whole install
# and leave the rest of the script silently running against podman's
# compatibility layer instead of real dockerd.
if ! rpm -q docker-ce >/dev/null 2>&1; then
  # A handful of packages collide with docker-ce/containerd.io on shared file
  # paths - podman-docker and moby-engine both ship /usr/bin/docker; a
  # standalone runc or containerd conflicts with the copies containerd.io
  # bundles internally. None of this is visible to `command -v`, so each is
  # checked and removed unconditionally before the install is attempted.
  #
  # --nodeps rather than `dnf remove`: these are thin/leaf packages (nothing
  # needs to cascade), and a dependency-respecting remove would otherwise try
  # to pull podman itself down with podman-docker - this script has no
  # business touching podman, only the docker-cli shim that conflicts.
  for CONFLICT_PKG in podman-docker moby-engine docker docker-common docker-engine runc containerd; do
    if rpm -q "$CONFLICT_PKG" >/dev/null 2>&1; then
      info "Removing ${CONFLICT_PKG} (conflicts with docker-ce/containerd.io)..."
      rpm -e --nodeps "$CONFLICT_PKG" || warn "could not remove ${CONFLICT_PKG}; the docker-ce install below may fail."
    fi
  done

  info "Installing Docker CE..."
  # Try installing straight away first. If a Docker repo is already enabled -
  # under any file/repo-id name, e.g. a renamed or internally-mirrored one -
  # dnf pulls docker-ce from it and there's nothing else to do. Only add
  # Docker's own repo as a fallback, so an existing repo is never duplicated
  # or fought over for the same repo-id.
  if dnf install -y docker-ce docker-ce-cli containerd.io \
                    docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1; then
    ok "Docker CE installed from an already-enabled repo."
  else
    # Docker publishes separate repo trees per distro family - centos for EL
    # derivatives (Alma/Rocky/Oracle/RHEL/CentOS Stream all use this one; there
    # is no distinct "oraclelinux" tree), fedora for Fedora. Using the wrong
    # one 404s.
    DOCKER_REPO_OS=centos
    if [ "$OS_FAMILY" = "fedora" ]; then
      DOCKER_REPO_OS=fedora
    fi
    info "No enabled repo provides docker-ce - adding Docker's official ${DOCKER_REPO_OS} repo for ${EL_MAJOR}..."
    # Written straight to reposdir rather than via `dnf config-manager --add-repo`:
    # dnf5 (EL10+, Fedora) dropped that flag in favour of `addrepo --from-repofile`,
    # and fetching the file works identically under both.
    #
    # $releasever is substituted for the detected major, because on genuine
    # RHEL it expands to a minor version ("9.4") that Docker does not publish.
    # (Fedora's $releasever is already a bare number, so this is a harmless
    # no-op there.)
    curl -fsSL "https://download.docker.com/linux/${DOCKER_REPO_OS}/docker-ce.repo" \
      | sed "s/\$releasever/${EL_MAJOR}/g" >/etc/yum.repos.d/docker-ce.repo
    dnf install -y docker-ce docker-ce-cli containerd.io \
                   docker-buildx-plugin docker-compose-plugin
  fi
fi
systemctl enable --now docker
ok "Docker ready ($(docker --version))."

# Docker's default bridge needs xt_addrtype, which on some kernels (most
# commonly a minimal image) lives in a separate "-modules-extra" package
# rather than kernel-core. KERNEL_PKG (derived earlier from the RPM that
# owns the running kernel's module directory) gives the correct package name
# whether that's kernel, kernel-ml, kernel-lt, or kernel-uek - idempotent via
# the modinfo check, and installing it never requires a reboot since kernel
# modules load on demand.
if ! modinfo xt_addrtype >/dev/null 2>&1; then
  if [ -n "$KERNEL_PKG" ]; then
    EXTRAS_PKG="${KERNEL_PKG}-modules-extra"
    case "$KERNEL_PKG" in
      kernel-uek*) EXTRAS_PKG="${KERNEL_PKG}-modules-extra-netfilter" ;;
    esac
    info "xt_addrtype unavailable for ${KERNEL_RELEASE} - installing ${EXTRAS_PKG}..."
    if dnf install -y "$EXTRAS_PKG" >/dev/null 2>&1; then
      ok "${EXTRAS_PKG} installed."
      # Docker was already started above and may have come up with a broken
      # bridge if xt_addrtype was missing at that point - restart now that
      # the module is available so the bridge network gets created correctly.
      info "Restarting Docker to pick up xt_addrtype..."
      systemctl restart docker
    else
      warn "could not install ${EXTRAS_PKG}. Docker's bridge network may fail to start;"
      warn "check: journalctl -u docker"
    fi
  else
    warn "could not determine the running kernel's package - skipping the xt_addrtype check."
  fi
else
  ok "xt_addrtype available for ${KERNEL_RELEASE}."
fi

# The gateway address of the default bridge. Do not hardcode 172.17.0.1: Docker
# picks another pool when that range collides with the provider's network, and
# default-address-pools overrides it outright.
DOCKER_GW=$(docker network inspect bridge -f '{{ (index .IPAM.Config 0).Gateway }}')
DOCKER_SUBNET=$(docker network inspect bridge -f '{{ (index .IPAM.Config 0).Subnet }}')
[ -n "$DOCKER_GW" ] || die "could not determine the Docker bridge gateway."
ok "Docker bridge gateway: ${DOCKER_GW} (subnet ${DOCKER_SUBNET})"

# -------------------------------------------- 3. GPU container runtime (NVIDIA)
if [ "$PROFILE" = "gpu" ] && [ "$GPU_VENDOR" = "nvidia" ]; then
  if ! have nvidia-ctk; then
    info "Adding the NVIDIA Container Toolkit repository..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
      -o /etc/yum.repos.d/nvidia-container-toolkit.repo
    dnf install -y nvidia-container-toolkit
  fi
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
  ok "NVIDIA container runtime configured."
elif [ "$PROFILE" = "gpu" ] && [ "$GPU_VENDOR" = "amd" ]; then
  # AMD needs no container toolkit: ROCm containers get the GPU by passing the
  # /dev/kfd and /dev/dri device nodes through directly.
  info "AMD GPU - skipping NVIDIA Container Toolkit (ROCm uses /dev/kfd)."
fi

# ---------------------------------------------------------- 4. firewall policy
# Binding to DOCKER_GW keeps services off the public interface, but it does not
# exempt them from netfilter: container -> DOCKER_GW traffic still traverses
# INPUT. One rule covers the bridge subnet; nothing else is opened.
#
# (The xt_addrtype / kernel-modules-extra gap that could otherwise break
# Docker's bridge here is handled automatically right after Docker starts -
# see the "kernel netfilter modules" step above.)
info "Applying firewall policy..."
dnf install -y firewalld >/dev/null
systemctl enable --now firewalld
firewall-cmd --permanent --add-service=ssh >/dev/null

# The default bridge's interface is named docker0 unless daemon.json (or an
# explicit bridge network option) overrides it - ask Docker rather than
# assuming, so a renamed bridge still gets zoned correctly.
DOCKER_BRIDGE_IFACE=$(docker network inspect bridge -f '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null || true)
if [ -z "$DOCKER_BRIDGE_IFACE" ]; then
  DOCKER_BRIDGE_IFACE=docker0
fi
DOCKER_ZONE=$(firewall-cmd --get-zone-of-interface="$DOCKER_BRIDGE_IFACE" 2>/dev/null || true)
if [ -z "$DOCKER_ZONE" ]; then
  DOCKER_ZONE=$(firewall-cmd --get-default-zone)
fi
ZONE_TARGET=$(firewall-cmd --permanent --zone="$DOCKER_ZONE" --get-target 2>/dev/null || true)
if [ -z "$ZONE_TARGET" ]; then
  ZONE_TARGET="default"
fi
if [ "$ZONE_TARGET" != "ACCEPT" ]; then
  firewall-cmd --permanent --zone="$DOCKER_ZONE" \
    --add-rich-rule="rule family=ipv4 source address=${DOCKER_SUBNET} accept" >/dev/null
  info "Allowed ${DOCKER_SUBNET} inbound on zone ${DOCKER_ZONE}."
else
  info "Zone ${DOCKER_ZONE} already accepts bridge traffic."
fi
firewall-cmd --reload >/dev/null
ok "Firewall active. Only ssh is reachable from the internet."

# ----------------------------------------------------------------- 5. Ollama
# Upstream now ships .tar.zst; the old ollama-linux-amd64.tgz URL returns 404.
if ! have ollama; then
  info "Downloading the official Ollama linux-amd64 package (~1.4 GB)..."
  TMP_TARBALL=$(mktemp /tmp/ollama-XXXXXX.tar.zst)
  curl -fL --retry 3 https://ollama.com/download/ollama-linux-amd64.tar.zst -o "$TMP_TARBALL"
  info "Extracting to /usr/local..."
  # /usr/local rather than /usr: the tarball is an unpackaged upstream binary,
  # and /usr is dnf/rpm's territory - dropping files there risks colliding with
  # (or being wiped by) a distro package touching the same paths.
  mkdir -p /usr/local/bin /usr/local/lib
  rm -rf /usr/local/lib/ollama                 # upstream-recommended before upgrade
  # Piped through zstd rather than `tar --zstd`: that flag needs GNU tar 1.31+
  # and EL8 ships 1.30.
  zstd -dc "$TMP_TARBALL" | tar -xf - -C /usr/local
  rm -f "$TMP_TARBALL"

  if [ "$PROFILE" = "gpu" ] && [ "$GPU_VENDOR" = "amd" ]; then
    info "Adding the ROCm runtime bundle for AMD (~1 GB)..."
    TMP_ROCM=$(mktemp /tmp/ollama-rocm-XXXXXX.tar.zst)
    curl -fL --retry 3 https://ollama.com/download/ollama-linux-amd64-rocm.tar.zst -o "$TMP_ROCM"
    zstd -dc "$TMP_ROCM" | tar -xf - -C /usr/local
    rm -f "$TMP_ROCM"
  fi
fi
ok "Ollama installed."

if ! id -u ollama >/dev/null 2>&1; then
  info "Creating the unprivileged ollama system account..."
  useradd -r -s /sbin/nologin -U -m -d /usr/share/ollama ollama
fi
if [ "$PROFILE" = "gpu" ]; then
  usermod -a -G video,render ollama 2>/dev/null || warn "could not add ollama to video/render groups."
fi

# DOCKER_GW does not exist until dockerd has created the bridge, hence the
# ordering dependency. If Docker ever recreates the bridge on a different
# subnet, re-run this script to rewrite the unit.
info "Writing /etc/systemd/system/ollama.service (bound to ${DOCKER_GW})..."
cat >/etc/systemd/system/ollama.service <<EOF
[Unit]
Description=Ollama AI Engine Daemon
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="OLLAMA_HOST=${DOCKER_GW}:${OLLAMA_PORT}"
Environment="OLLAMA_MODELS=/usr/share/ollama/.ollama/models"
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
# ProtectSystem=full mounts /usr read-only; OLLAMA_MODELS lives under
# /usr/share/ollama, so that one path needs an explicit carve-out or every
# model pull fails with a permission error.
ReadWritePaths=/usr/share/ollama

[Install]
WantedBy=multi-user.target
EOF

# The ollama CLI defaults to 127.0.0.1:11434, which is no longer where the
# daemon listens, so point every login shell at the real address.
info "Writing /etc/profile.d/ollama.sh..."
cat >/etc/profile.d/ollama.sh <<EOF
# Managed by install-ai-suite.sh - the Ollama daemon binds the Docker bridge
# gateway, not loopback. Re-run the installer if the bridge subnet changes.
export OLLAMA_HOST="${DOCKER_GW}:${OLLAMA_PORT}"
EOF
chmod 644 /etc/profile.d/ollama.sh
export OLLAMA_HOST="${DOCKER_GW}:${OLLAMA_PORT}"

systemctl daemon-reload
systemctl enable ollama >/dev/null
systemctl restart ollama

info "Waiting for the Ollama API on ${OLLAMA_HOST}..."
for _ in $(seq 1 60); do
  if curl -fsS "http://${OLLAMA_HOST}/api/version" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
curl -fsS "http://${OLLAMA_HOST}/api/version" >/dev/null \
  || die "Ollama did not come up. Check: journalctl -u ollama -n 50"
ok "Ollama serving on ${OLLAMA_HOST}."

# --------------------------------------------------------------- 6. OmniRoute
if container_gone omniroute; then
  info "Deploying OmniRoute AI gateway on ${DOCKER_GW}:20128..."
  # --env-file rather than a run of -e KEY=value for the secrets: with -e, each
  # value is a literal `docker run` argument, so it shows up in `ps`/`/proc/<pid>/cmdline`
  # for the life of that invocation and in anything that logs the executed
  # command line. A file isn't - only its path is. (This does not hide the
  # values from `docker inspect` or the container's own /proc/<pid>/environ;
  # Docker bakes the resolved env into the container config either way -
  # closing that would need OmniRoute to support file-based secrets or
  # Swarm secrets, neither of which this single-node docker-run setup uses.)
  # umask 077 is already active from the credentials step above, so this
  # temp file is created mode 600; chmod is explicit for clarity.
  OMNI_ENV_FILE=$(mktemp /tmp/omniroute-env-XXXXXX)
  chmod 600 "$OMNI_ENV_FILE"
  cat >"$OMNI_ENV_FILE" <<EOF
PORT=20128
HOSTNAME=0.0.0.0
DATA_DIR=/app/data
NODE_ENV=production
API_KEY_SECRET=${OMNI_API_KEY_SECRET}
JWT_SECRET=${OMNI_JWT_SECRET}
STORAGE_ENCRYPTION_KEY=${OMNI_STORAGE_KEY}
OMNIROUTE_WS_BRIDGE_SECRET=${OMNI_WS_BRIDGE_SECRET}
INITIAL_PASSWORD=${OMNI_ADMIN_PASS}
OMNIROUTE_ALLOW_PRIVATE_PROVIDER_URLS=true
EOF
  docker run -d \
    --name omniroute \
    --restart unless-stopped \
    --stop-timeout 40 \
    -p "${DOCKER_GW}:20128:20128" \
    --env-file "$OMNI_ENV_FILE" \
    -v omniroute-data:/app/data \
    diegosouzapw/omniroute:latest >/dev/null
  rm -f "$OMNI_ENV_FILE"
  ok "OmniRoute started."
else
  ok "OmniRoute already exists - leaving it alone."
fi

# ------------------------------------------------------------- 7. Open WebUI
if container_gone open-webui; then
  info "Deploying Open WebUI on ${DOCKER_GW}:8080..."
  docker run -d \
    --name open-webui \
    --restart unless-stopped \
    -p "${DOCKER_GW}:8080:8080" \
    -e OLLAMA_BASE_URL="http://${DOCKER_GW}:${OLLAMA_PORT}" \
    -v open-webui:/app/backend/data \
    ghcr.io/open-webui/open-webui:main >/dev/null
  ok "Open WebUI started."
else
  ok "Open WebUI already exists - leaving it alone."
fi

# ---------------------------------------------------------------- 8. ComfyUI
if [ "$INSTALL_COMFYUI" -eq 1 ] && container_gone comfyui; then
  # PROFILE=cpu forces the CPU image even when a card is present.
  if [ "$PROFILE" = "cpu" ]; then COMFY_VENDOR=none; else COMFY_VENDOR=$GPU_VENDOR; fi
  case "$COMFY_VENDOR" in
    nvidia) COMFY_TAG=cu130-slim; GPU_ARGS=(--gpus all --runtime=nvidia) ;;
    amd)    COMFY_TAG=rocm;       GPU_ARGS=(--device /dev/kfd --device /dev/dri
                                            --group-add video --security-opt seccomp=unconfined) ;;
    *)      COMFY_TAG=cpu;        GPU_ARGS=() ;;
  esac
  info "Deploying ComfyUI (yanwk/comfyui-boot:${COMFY_TAG}) on ${DOCKER_GW}:8188..."
  docker run -d \
    --name comfyui \
    --restart unless-stopped \
    "${GPU_ARGS[@]}" \
    -p "${DOCKER_GW}:8188:8188" \
    -v comfyui-models:/root/ComfyUI/models \
    -v comfyui-nodes:/root/ComfyUI/custom_nodes \
    -v comfyui-input:/root/ComfyUI/input \
    -v comfyui-output:/root/ComfyUI/output \
    -v comfyui-cache:/root/.cache \
    "yanwk/comfyui-boot:${COMFY_TAG}" >/dev/null \
    || warn "ComfyUI failed to start - inspect with: docker logs comfyui"
fi

# ------------------------------------------------------------- 9. Dockge
if [ "$INSTALL_DOCKGE" -eq 1 ]; then
  if container_gone dockge; then
    info "Deploying Dockge on ${DOCKER_GW}:5001..."
    mkdir -p "$STACKS_DIR"
    SEL=""
    if [ "$SELINUX_ON" -eq 1 ]; then
      SEL=":z"
    fi
    docker run -d \
      --name dockge \
      --restart unless-stopped \
      -p "${DOCKER_GW}:5001:5001" \
      -e DOCKGE_STACKS_DIR="$STACKS_DIR" \
      -v "/var/run/docker.sock:/var/run/docker.sock" \
      -v "dockge-data:/app/data" \
      -v "${STACKS_DIR}:${STACKS_DIR}${SEL}" \
      louislam/dockge:1 >/dev/null
    ok "Dockge started. Create the admin account on first visit."
  else
    ok "Dockge already exists - leaving it alone."
  fi
else
  info "Skipping Dockge (INSTALL_DOCKGE=0)."
fi

case "$MODEL_TIER" in
  none)   TIER_DOWNLOAD_GB=0  ;;
  cpu)    TIER_DOWNLOAD_GB=9  ;;
  small)  TIER_DOWNLOAD_GB=18 ;;
  medium) TIER_DOWNLOAD_GB=38 ;;
  large)  TIER_DOWNLOAD_GB=73 ;;
esac

# ------------------------------------------------------------ 10. model pulls
# MODELS and the tier were resolved during preflight, since the requirements
# gate derives its thresholds from them.
if [ "$PULL_MODELS" -eq 1 ] && [ "${#MODELS[@]}" -gt 0 ]; then
  FREE_GB=$(df -BG --output=avail /usr/share/ollama | tail -n1 | tr -dc '0-9')
  if [ "${FREE_GB:-0}" -lt "$TIER_DOWNLOAD_GB" ]; then
    warn "Only ${FREE_GB} GB free on /usr/share/ollama; the ${MODEL_TIER} set needs ~${TIER_DOWNLOAD_GB} GB. Skipping."
  else
    for m in "${MODELS[@]}"; do
      info "Pulling ${m}..."
      ollama pull "$m" || warn "failed to pull ${m}; continuing."
    done
    ok "Model preload complete (${MODEL_TIER} set)."
  fi
fi

# ------------------------------------------------------------------- summary
SERVER_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
TUNNEL="ssh -L 8080:${DOCKER_GW}:8080 -L 20128:${DOCKER_GW}:20128"
SERVICES="   Open WebUI    ->  http://127.0.0.1:8080
   OmniRoute     ->  http://127.0.0.1:20128"

if [ "$INSTALL_COMFYUI" -eq 1 ]; then
  TUNNEL="${TUNNEL} -L 8188:${DOCKER_GW}:8188"
  SERVICES="${SERVICES}
   ComfyUI       ->  http://127.0.0.1:8188"
fi
if [ "$INSTALL_DOCKGE" -eq 1 ]; then
  TUNNEL="${TUNNEL} -L 5001:${DOCKER_GW}:5001"
  SERVICES="${SERVICES}
   Dockge        ->  http://127.0.0.1:5001"
fi

cat <<EOF

==========================================================================
 AI workspace deployed on $(hostname)
==========================================================================
 Internet-facing ports:  22 (ssh) only
 Profile:                ${PROFILE} (${GPU_VENDOR}, ${VRAM_GB} GB VRAM) / ${MODEL_TIER} models
 Bridge gateway:         ${DOCKER_GW}
 Ollama API:             ${DOCKER_GW}:${OLLAMA_PORT}

 Everything below is bound to the bridge gateway. Tunnel in with:
   ${TUNNEL} root@${SERVER_IP}

${SERVICES}

 OmniRoute admin password:  ${OMNI_ADMIN_PASS}
 Secrets file:              ${CREDS_FILE}  (mode 0600)

 Add Ollama to OmniRoute as a provider at:
   http://${DOCKER_GW}:${OLLAMA_PORT}

 New shells pick up OLLAMA_HOST from /etc/profile.d/ollama.sh.
 In this shell:  export OLLAMA_HOST=${DOCKER_GW}:${OLLAMA_PORT}
==========================================================================
EOF
