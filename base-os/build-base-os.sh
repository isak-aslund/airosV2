#!/bin/bash
set -euo pipefail

# AirOS Base OS Builder
# Builds a minimal L4T image with Docker + NVIDIA Container Toolkit
# for running the containerized AirOS application stack.
#
# Must run inside Docker container for proper QEMU cross-arch chroot.
# Usage:
#   ./build-base-os.sh [--skip-kernel]         # auto-launches Docker
#   ./build-base-os.sh --inside [--skip-kernel] # called from within container

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- If not inside the container, build and launch it ---
if [ "${1:-}" != "--inside" ]; then
    PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
    echo "Building base-os build container..."
    docker build -t airos-base-builder -f "$SCRIPT_DIR/Dockerfile" "$PROJECT_ROOT"
    echo "Launching build inside container..."
    mkdir -p "$PROJECT_ROOT/out"
    docker run --rm --privileged \
        -v "$PROJECT_ROOT/out:/output" \
        -v airos-build-workspace:/AirOS/workspace \
        airos-base-builder --inside "$@"
    echo "Build complete. Output in $PROJECT_ROOT/out/"
    exit 0
fi
shift  # remove --inside

PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="/output"

# Point $AirOS at /AirOS (container workdir) so step files resolve paths
export AirOS="$SCRIPT_DIR"

# Source build libraries and config
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/AirOS.conf"

# Source all step modules (defines step_* functions)
source "$SCRIPT_DIR/steps/00_setup.sh"
source "$SCRIPT_DIR/steps/10_camera_drivers.sh"
source "$SCRIPT_DIR/steps/20_kernel.sh"

echo "============================================"
echo "  AirOS Base OS Builder"
echo "  Version: $AirOS_VERSION"
echo "  Target: Jetson Orin NX (L4T R36.4.0)"
echo "  AirOS dir: $AirOS"
echo "============================================"

# --- Pre-flight: verify all required files exist ---
log_info "Pre-flight check: verifying required files..."
PREFLIGHT_OK=true
required_files=(
    "$SCRIPT_DIR/lib/config.sh"
    "$SCRIPT_DIR/lib/logging.sh"
    "$SCRIPT_DIR/AirOS.conf"
    "$SCRIPT_DIR/steps/00_setup.sh"
    "$SCRIPT_DIR/steps/10_camera_drivers.sh"
    "$SCRIPT_DIR/steps/20_kernel.sh"
    "$SCRIPT_DIR/configs/daemon.json"
    "$SCRIPT_DIR/configs/journald.conf"
    "$SCRIPT_DIR/configs/70-airolit-cameras.rules"
    "$SCRIPT_DIR/configs/airos-compose.service"
    "$SCRIPT_DIR/configs/airos-watchdog.service"
    "$SCRIPT_DIR/configs/airos-watchdog.timer"
    "$SCRIPT_DIR/configs/airos-watchdog.sh"
    "$SCRIPT_DIR/configs/network.yml"
    "/project/docker-compose.yml"
    "/project/versions.env"
)

# Camera driver files (vendor-dependent)
if [ "${IMX678_VENDOR:-econ}" = "econ" ]; then
    required_files+=("$SCRIPT_DIR/camera_drivers/e-CAM86_CUONX_JETSON_ONX_ONANO_L4T36.4.0_14-MAY-2025_R02.tar.gz")
fi

# DTBs
required_files+=(
    "$SCRIPT_DIR/dtbs/airolit_CX10_COMMON.dts"
    "$SCRIPT_DIR/dtbs/airolit_CX10_AR0234.dts"
)

# Container images (must be built first with 'make build-all')
for img in airos-video.tar airos-flight.tar airos-manager.tar; do
    if [ ! -f "$OUT_DIR/$img" ]; then
        log_error "Missing: $OUT_DIR/$img — run 'make build-all' first"
        PREFLIGHT_OK=false
    fi
done

# Patches directory
if [ ! -d "$SCRIPT_DIR/patches" ]; then
    log_error "Missing directory: $SCRIPT_DIR/patches/"
    PREFLIGHT_OK=false
fi

for f in "${required_files[@]}"; do
    if [ ! -f "$f" ]; then
        log_error "Missing: $f"
        PREFLIGHT_OK=false
    fi
done

if [ "$PREFLIGHT_OK" != "true" ]; then
    log_error "Pre-flight check failed. Fix missing files before building."
    exit 1
fi
log_info "Pre-flight check passed."

# --- Phase 1: Reuse existing kernel/driver build ---
# Setup: validate, download, extract, apply binaries, create user
log_info "Phase 1a: Setup (validate, download, extract)"
step_validate_build_environment
step_download_l4t
step_extract_l4t
step_extract_rootfs
step_extract_toolchain
step_extract_kernel_package
step_apply_nvidia_binaries
step_create_default_user

# Camera drivers
log_info "Phase 1b: Camera drivers"
if [ "$IMX678_VENDOR" = "framos" ]; then
    step_install_framos_IMX678
elif [ "$IMX678_VENDOR" = "econ" ]; then
    step_install_econ_imx678
fi
step_apply_patches

# Kernel
if [ "${1:-}" != "--skip-kernel" ]; then
    log_info "Phase 1c: Kernel build"
    step_configure_extlinux
    step_copy_device_tree_overlays
    step_build_kernel
    step_copy_dtbo_to_rootfs
    step_setup_power_mode
    step_setup_journald
    step_disable_snapd
fi

# --- Phase 2: Minimal rootfs (replaces airos/steps/30_rootfs.sh) ---
log_info "Phase 2: Installing minimal base OS packages"

# Cleanup mounts on exit (set up early so any failure path cleans up)
cleanup_chroot_mounts() {
    umount "$L4T_ROOTFS/run" 2>/dev/null || true
    umount "$L4T_ROOTFS/dev/pts" 2>/dev/null || true
    umount "$L4T_ROOTFS/dev" 2>/dev/null || true
    umount "$L4T_ROOTFS/sys" 2>/dev/null || true
    umount "$L4T_ROOTFS/proc" 2>/dev/null || true
    # Restore original resolv.conf if backup exists
    if [ -f "$L4T_ROOTFS/etc/resolv.conf.temp" ]; then
        mv "$L4T_ROOTFS/etc/resolv.conf.temp" "$L4T_ROOTFS/etc/resolv.conf"
    fi
}
trap cleanup_chroot_mounts EXIT

# Idempotency: skip chroot package install if Docker is already installed in rootfs
if chroot "$L4T_ROOTFS" /usr/bin/docker --version >/dev/null 2>&1; then
    log_info "Phase 2 already complete (Docker found in rootfs) — skipping"
else

# Enable internet access in chroot
log_info "Enabling internet access in chroot..."
# Handle re-runs: only move resolv.conf if backup doesn't already exist
if [ ! -f "$L4T_ROOTFS/etc/resolv.conf.temp" ]; then
    mv "$L4T_ROOTFS/etc/resolv.conf" "$L4T_ROOTFS/etc/resolv.conf.temp"
fi
cp /etc/resolv.conf "$L4T_ROOTFS/etc/resolv.conf"
cp /usr/bin/qemu-aarch64-static "$L4T_ROOTFS/usr/bin/"
mount -t proc /proc "$L4T_ROOTFS/proc" 2>/dev/null || true
mount -t sysfs /sys "$L4T_ROOTFS/sys" 2>/dev/null || true
mount -o bind /dev "$L4T_ROOTFS/dev" 2>/dev/null || true
mount -o bind /dev/pts "$L4T_ROOTFS/dev/pts" 2>/dev/null || true
mount -t tmpfs tmpfs "$L4T_ROOTFS/run" 2>/dev/null || true
mkdir -p /proc/sys/fs/binfmt_misc

# Install packages in chroot
chroot "$L4T_ROOTFS" /bin/bash <<'CHROOT_EOF'
    export DEBIAN_FRONTEND=noninteractive

    # Docker Engine (from Docker's official repo for NVIDIA compat)
    apt-get update
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg lsb-release

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update
    apt-get install -y --no-install-recommends \
        docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # NVIDIA Container Toolkit
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update
    apt-get install -y --no-install-recommends nvidia-container-toolkit

    nvidia-ctk runtime configure --runtime=docker

    # System essentials
    apt-get install -y --no-install-recommends \
        openssh-server \
        network-manager \
        chrony \
        nano vim tmux mosh btop lsof \
        v4l-utils \
        udev \
        zsh fzf

    # Modern CLI tools (not all available in apt for arm64, install via binary)
    # bat
    apt-get install -y --no-install-recommends bat
    # eza
    curl -fsSL https://github.com/eza-community/eza/releases/latest/download/eza_aarch64-unknown-linux-gnu.tar.gz | tar xz -C /usr/local/bin/
    # zoxide
    curl -fsSL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash
    # zellij
    curl -fsSL https://github.com/zellij-org/zellij/releases/latest/download/zellij-aarch64-unknown-linux-musl.tar.gz | tar xz -C /usr/local/bin/
    # duf
    curl -fsSL https://github.com/muesli/duf/releases/latest/download/duf_0.8.1_linux_arm64.tar.gz | tar xz -C /usr/local/bin/ duf
    # tldr
    pip3 install --no-cache-dir tldr
    # isd
    pip3 install --no-cache-dir isd
    # neofetch
    apt-get install -y --no-install-recommends neofetch

    # Set zsh as default shell for root and default user
    chsh -s /usr/bin/zsh root
    chsh -s /usr/bin/zsh cx10

    # Install zsh plugins
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git /usr/share/zsh-syntax-highlighting
    git clone https://github.com/zsh-users/zsh-autosuggestions.git /usr/share/zsh-autosuggestions

    # Create default zshrc
    cat > /root/.zshrc <<'ZSHRC'
# History
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt share_history hist_ignore_dups hist_ignore_space

# Completion
autoload -Uz compinit && compinit
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'

# Plugins
source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh

# Aliases
alias ls='eza -la --icons --color=always --group-directories-first'
alias ll='eza -la --icons --color=always --group-directories-first'
alias lt='eza --tree --icons'
alias cat='batcat --style=plain'

# Key bindings
bindkey '^ ' forward-word
bindkey '^o' autosuggest-accept
bindkey '^H' backward-kill-word

# Zoxide
eval "$(zoxide init zsh)"

# Prompt
autoload -Uz promptinit && promptinit
PROMPT='%F{cyan}%n@%m%f %F{blue}%~%f %# '
ZSHRC

    # Copy zshrc to default user
    cp /root/.zshrc /home/cx10/.zshrc
    chown cx10:cx10 /home/cx10/.zshrc

    # Tailscale
    curl -fsSL https://tailscale.com/install.sh | sh

    # Cleanup
    apt-get clean
    rm -rf /var/lib/apt/lists/*
CHROOT_EOF

# Clean up chroot mounts after Phase 2
cleanup_chroot_mounts

fi  # end Phase 2 idempotency guard

# --- Phase 3: Install configuration files ---
log_info "Phase 3: Installing AirOS configuration"

# Docker daemon config (NVIDIA runtime + log rotation)
mkdir -p "$L4T_ROOTFS/etc/docker"
cp "$SCRIPT_DIR/configs/daemon.json" "$L4T_ROOTFS/etc/docker/daemon.json"

# Udev rules for camera symlinks
cp "$SCRIPT_DIR/configs/70-airolit-cameras.rules" "$L4T_ROOTFS/etc/udev/rules.d/"

# Systemd services
cp "$SCRIPT_DIR/configs/airos-compose.service" "$L4T_ROOTFS/etc/systemd/system/"
cp "$SCRIPT_DIR/configs/airos-watchdog.service" "$L4T_ROOTFS/etc/systemd/system/"
cp "$SCRIPT_DIR/configs/airos-watchdog.timer" "$L4T_ROOTFS/etc/systemd/system/"
cp "$SCRIPT_DIR/configs/airos-watchdog.sh" "$L4T_ROOTFS/usr/local/bin/"
chmod +x "$L4T_ROOTFS/usr/local/bin/airos-watchdog.sh"

# Enable services
chroot "$L4T_ROOTFS" /bin/bash <<'CHROOT_EOF'
    systemctl enable docker.service
    systemctl enable airos-compose.service
    systemctl enable airos-watchdog.timer
    # Disable snapd to avoid boot hangs
    systemctl mask snapd.service snapd.socket snapd.seeded.service
CHROOT_EOF

# Create /etc/airos/ with default config
mkdir -p "$L4T_ROOTFS/etc/airos"
cp "/project/docker-compose.yml" "$L4T_ROOTFS/etc/airos/"
cp "/project/versions.env" "$L4T_ROOTFS/etc/airos/"
cp "/project/.env" "$L4T_ROOTFS/etc/airos/"
cp "$SCRIPT_DIR/configs/network.yml" "$L4T_ROOTFS/etc/airos/"

# Apply default network config via NetworkManager
# Create connection profile for static IP
cat > "$L4T_ROOTFS/etc/NetworkManager/system-connections/eth-dual-ip.nmconnection" <<'NM_EOF'
[connection]
id=eth-dual-ip
type=ethernet
interface-name=enP8p1s0
autoconnect=true

[ipv4]
method=manual
address1=192.168.144.111/24
address2=10.223.0.111/16
gateway=192.168.144.78

[ipv6]
method=auto
NM_EOF
chmod 600 "$L4T_ROOTFS/etc/NetworkManager/system-connections/eth-dual-ip.nmconnection"

# --- Phase 4: Pre-load container images ---
log_info "Phase 4: Installing container images into rootfs"

# Copy container image tars into the rootfs
mkdir -p "$L4T_ROOTFS/etc/airos/images"
for img in airos-video.tar airos-flight.tar airos-manager.tar; do
    log_info "Copying $img..."
    cp "$OUT_DIR/$img" "$L4T_ROOTFS/etc/airos/images/"
done

# Create a first-boot script that loads images into Docker and cleans up
cat > "$L4T_ROOTFS/etc/airos/load-images.sh" <<'LOAD_EOF'
#!/bin/bash
# First-boot: load pre-bundled container images into Docker
set -e
IMAGE_DIR="/etc/airos/images"
if [ -d "$IMAGE_DIR" ] && ls "$IMAGE_DIR"/*.tar 1>/dev/null 2>&1; then
    echo "AirOS: Loading container images..."
    for tar in "$IMAGE_DIR"/*.tar; do
        echo "  Loading $(basename $tar)..."
        docker load < "$tar"
    done
    rm -rf "$IMAGE_DIR"
    echo "AirOS: Container images loaded and cleaned up."
fi
LOAD_EOF
chmod +x "$L4T_ROOTFS/etc/airos/load-images.sh"

# Create a oneshot systemd service to run before airos-compose
cat > "$L4T_ROOTFS/etc/systemd/system/airos-load-images.service" <<'SVC_EOF'
[Unit]
Description=Load pre-bundled AirOS container images
After=docker.service
Before=airos-compose.service
ConditionPathExists=/etc/airos/images

[Service]
Type=oneshot
ExecStart=/etc/airos/load-images.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVC_EOF

# Enable it
chroot "$L4T_ROOTFS" /bin/bash <<'CHROOT_EOF'
    systemctl enable airos-load-images.service
CHROOT_EOF

# --- Phase 5: Write metadata ---
log_info "Phase 5: Writing build metadata"

cat > "$L4T_ROOTFS/etc/airos-base-info" <<EOF
AIROS_BASE_VERSION=$AirOS_VERSION
L4T_VERSION=R36.4.0
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
BUILD_TYPE=base-os
EOF

# --- Pre-export cleanup ---
rm -f "$L4T_ROOTFS/usr/bin/qemu-aarch64-static"
rm -f "$L4T_ROOTFS"/*.rej 2>/dev/null || true

# --- Phase 5b: Pre-flash verification ---
log_info "Phase 5b: Pre-flash verification"
VERIFY_FAIL=0

verify_file() {
    if [ ! -f "$1" ]; then
        log_error "MISSING: $1"
        VERIFY_FAIL=1
    else
        log_info "  ✅ $(basename "$1")"
    fi
}

verify_dir() {
    if [ ! -d "$1" ]; then
        log_error "MISSING: $1"
        VERIFY_FAIL=1
    else
        log_info "  ✅ $(basename "$1")/"
    fi
}

# Kernel
log_info "Checking kernel..."
verify_file "$L4T_DIR/kernel/Image"
verify_dir "$L4T_ROOTFS/lib/modules"

# DTBOs
log_info "Checking device tree overlays..."
verify_file "$L4T_ROOTFS/boot/airolit_CX10_COMMON.dtbo"
verify_file "$L4T_ROOTFS/boot/airolit_CX10_AR0234.dtbo"
verify_file "$L4T_ROOTFS/boot/airolit_CX10_AIROLIGHT.dtbo"
if [ "$IMX678_VENDOR" = "econ" ]; then
    verify_file "$L4T_ROOTFS/boot/airolit_CX10_ECON_IMX678.dtbo"
elif [ "$IMX678_VENDOR" = "framos" ]; then
    verify_file "$L4T_ROOTFS/boot/airolit_CX10_FRAMOS_IMX678.dtbo"
fi

# Camera drivers
log_info "Checking camera drivers..."
verify_file "$L4T_ROOTFS/var/nvidia/nvcam/settings/camera_overrides.isp"
if [ "$IMX678_VENDOR" = "econ" ]; then
    verify_file "$L4T_ROOTFS/lib/firmware/imx678_cam_fw.bin"
fi
# Kernel modules for cameras
if [ "$IMX678_VENDOR" = "econ" ]; then
    verify_file "$L4T_ROOTFS/lib/modules/5.15.148-tegra/updates/e-con_cam.ko"
fi
verify_file "$L4T_ROOTFS/lib/modules/5.15.148-tegra/updates/ar0234.ko"

# NVIDIA binaries
log_info "Checking NVIDIA binaries..."
verify_file "$L4T_ROOTFS/usr/lib/aarch64-linux-gnu/tegra/libcuda.so"

# Docker + NVIDIA Container Toolkit
log_info "Checking Docker + NVIDIA runtime..."
verify_file "$L4T_ROOTFS/usr/bin/docker"
verify_file "$L4T_ROOTFS/usr/bin/nvidia-ctk"
verify_file "$L4T_ROOTFS/etc/docker/daemon.json"

# Container images
log_info "Checking container images..."
verify_file "$L4T_ROOTFS/etc/airos/images/airos-video.tar"
verify_file "$L4T_ROOTFS/etc/airos/images/airos-flight.tar"
verify_file "$L4T_ROOTFS/etc/airos/images/airos-manager.tar"

# AirOS config
log_info "Checking AirOS configuration..."
verify_file "$L4T_ROOTFS/etc/airos/docker-compose.yml"
verify_file "$L4T_ROOTFS/etc/airos/versions.env"
verify_file "$L4T_ROOTFS/etc/airos/.env"
verify_file "$L4T_ROOTFS/etc/airos-base-info"

# Systemd services
log_info "Checking systemd services..."
verify_file "$L4T_ROOTFS/etc/systemd/system/airos-compose.service"
verify_file "$L4T_ROOTFS/etc/systemd/system/airos-load-images.service"
verify_file "$L4T_ROOTFS/etc/systemd/system/airos-watchdog.service"
verify_file "$L4T_ROOTFS/etc/systemd/system/airos-watchdog.timer"

# Service enablement (symlinks)
log_info "Checking service enablement..."
for svc in docker.service airos-compose.service airos-load-images.service; do
    link="$L4T_ROOTFS/etc/systemd/system/multi-user.target.wants/$svc"
    if [ ! -L "$link" ] && [ ! -f "$link" ]; then
        log_error "Service not enabled: $svc"
        VERIFY_FAIL=1
    else
        log_info "  ✅ $svc enabled"
    fi
done

# Udev rules
log_info "Checking udev rules..."
verify_file "$L4T_ROOTFS/etc/udev/rules.d/70-airolit-cameras.rules"

# User
log_info "Checking user configuration..."
if grep -q "^${FIRST_USER_NAME}:" "$L4T_ROOTFS/etc/passwd" 2>/dev/null; then
    log_info "  ✅ User $FIRST_USER_NAME exists"
else
    log_error "User $FIRST_USER_NAME missing from /etc/passwd"
    VERIFY_FAIL=1
fi

# Network
log_info "Checking network configuration..."
verify_file "$L4T_ROOTFS/etc/NetworkManager/system-connections/eth-dual-ip.nmconnection"

# Boot config
log_info "Checking boot configuration..."
verify_file "$L4T_ROOTFS/boot/extlinux/extlinux.conf"
if ! grep -q "OVERLAYS" "$L4T_ROOTFS/boot/extlinux/extlinux.conf" 2>/dev/null; then
    log_error "extlinux.conf missing OVERLAYS line"
    VERIFY_FAIL=1
fi

# Chroot cleanup
log_info "Checking chroot cleanup..."
if [ -f "$L4T_ROOTFS/usr/bin/qemu-aarch64-static" ]; then
    log_error "qemu-aarch64-static left in rootfs"
    VERIFY_FAIL=1
else
    log_info "  ✅ No qemu binary in rootfs"
fi
if [ -f "$L4T_ROOTFS/etc/resolv.conf.temp" ]; then
    log_error "resolv.conf.temp not cleaned up"
    VERIFY_FAIL=1
else
    log_info "  ✅ resolv.conf clean"
fi

# Summary
echo ""
log_info "Build info:"
cat "$L4T_ROOTFS/etc/airos-base-info"
echo ""

if [ "$VERIFY_FAIL" -ne 0 ]; then
    log_error "❌ Pre-flash verification FAILED — see errors above"
    exit 1
fi
log_info "✅ All pre-flash checks passed!"

# --- Phase 6: Export ---
log_info "Phase 6: Exporting image"
mkdir -p "$OUT_DIR"

# Ensure chroot mounts are fully cleaned before archiving
cleanup_chroot_mounts
# Force-unmount anything still mounted under rootfs (Phase 3/4 chroot calls may remount)
for mnt in "$L4T_ROOTFS/proc" "$L4T_ROOTFS/sys" "$L4T_ROOTFS/dev/pts" "$L4T_ROOTFS/dev" "$L4T_ROOTFS/run"; do
    umount -lf "$mnt" 2>/dev/null || true
done

OUTFILE="$OUT_DIR/airos-base-${AirOS_VERSION_SAFE}_$(date +%Y%m%d_%H%M).tar.gz"
# Clean virtual filesystem dirs but preserve essential structure
for vfs in proc sys; do
    rm -rf "$L4T_ROOTFS/$vfs"
    mkdir -p "$L4T_ROOTFS/$vfs"
done
# dev needs console and null for init
rm -rf "$L4T_ROOTFS/dev"
mkdir -p "$L4T_ROOTFS/dev"
# run needs lock/ dir (/var/lock -> /run/lock, used by flash and systemd)
rm -rf "$L4T_ROOTFS/run"
mkdir -p "$L4T_ROOTFS/run/lock"

tar --exclude='./source' \
    --exclude='./nv_tools' \
    --exclude='./generate_capsule' \
    --warning=no-file-changed \
    -C "$L4T_DIR" -cf - . | pigz -p "$(nproc)" > "$OUTFILE"

log_info "Base OS image exported to: $OUTFILE"
log_info "Flash with: cd Linux_for_Tegra && sudo ./flash.sh jetson-orin-nx-devkit-nvme internal"
