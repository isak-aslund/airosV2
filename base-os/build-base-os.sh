#!/bin/bash
set -euo pipefail

# AirOS Base OS Builder
# Builds a minimal L4T image with Docker + NVIDIA Container Toolkit
# for running the containerized AirOS application stack.
#
# Prerequisites:
#   - Docker on host (for cross-compilation)
#   - SSH keys for private git repos
#
# Usage: ./build-base-os.sh [--skip-kernel]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
AIROS_REF="$PROJECT_ROOT/airos"
OUT_DIR="$PROJECT_ROOT/out"

# Source existing build config and libraries
source "$AIROS_REF/lib/config.sh"
source "$AIROS_REF/lib/logging.sh"
source "$AIROS_REF/AirOS.conf"

echo "============================================"
echo "  AirOS Base OS Builder"
echo "  Version: $AirOS_VERSION"
echo "  Target: Jetson Orin NX (L4T R36.4.0)"
echo "============================================"

# --- Phase 1: Reuse existing kernel/driver build ---
# Steps 00 (setup), 10 (camera drivers), 20 (kernel) are unchanged.
# These produce the L4T rootfs with custom kernel and camera drivers.

log_info "Phase 1: Building kernel and camera drivers (reusing existing pipeline)"
log_info "Running: airos/steps/00_setup.sh"
source "$AIROS_REF/steps/00_setup.sh"
run_step_00

log_info "Running: airos/steps/10_camera_drivers.sh"
source "$AIROS_REF/steps/10_camera_drivers.sh"
run_step_10

if [ "${1:-}" != "--skip-kernel" ]; then
    log_info "Running: airos/steps/20_kernel.sh"
    source "$AIROS_REF/steps/20_kernel.sh"
    run_step_20
fi

# --- Phase 2: Minimal rootfs (replaces airos/steps/30_rootfs.sh) ---
log_info "Phase 2: Installing minimal base OS packages"

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
        nano mosh btop lsof \
        v4l-utils \
        udev

    # Tailscale
    curl -fsSL https://tailscale.com/install.sh | sh

    # Cleanup
    apt-get clean
    rm -rf /var/lib/apt/lists/*
CHROOT_EOF

# --- Phase 3: Install configuration files ---
log_info "Phase 3: Installing AirOS configuration"

# Docker daemon config (NVIDIA runtime + log rotation)
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
cp "$PROJECT_ROOT/docker-compose.yml" "$L4T_ROOTFS/etc/airos/"
cp "$PROJECT_ROOT/versions.env" "$L4T_ROOTFS/etc/airos/"
cp "$PROJECT_ROOT/.env" "$L4T_ROOTFS/etc/airos/"
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

# --- Phase 4: Write metadata ---
log_info "Phase 4: Writing build metadata"

cat > "$L4T_ROOTFS/etc/airos-base-info" <<EOF
AIROS_BASE_VERSION=$AirOS_VERSION
L4T_VERSION=R36.4.0
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
BUILD_TYPE=base-os
EOF

# --- Phase 5: Export ---
log_info "Phase 5: Exporting image"
mkdir -p "$OUT_DIR"

# Run NVIDIA's finalize step
cd "$L4T_DIR"
./apply_binaries.sh

OUTFILE="$OUT_DIR/airos-base-${AirOS_VERSION_SAFE}_$(date +%Y%m%d_%H%M).tar.gz"
tar czf "$OUTFILE" \
    --exclude='source' \
    --exclude='nv_tools' \
    -C "$(dirname "$L4T_DIR")" "$(basename "$L4T_DIR")"

log_info "Base OS image exported to: $OUTFILE"
log_info "Flash with: cd Linux_for_Tegra && sudo ./flash.sh jetson-orin-nx-devkit-nvme internal"
