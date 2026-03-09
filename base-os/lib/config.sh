#!/bin/bash
# ============================================================================
# AirOS Build Script - Configuration Loader
# Description: Loads and exports build configuration variables
# ============================================================================

# Determine AirOS version:
# Priority:
# 1. If current git commit has a tag, use that tag name
# 2. Else, use the current git branch name
# 3. Else, use AirOS_VERSION environment variable if set
# 4. Else, default to 0.0.1
AirOS_VERSION=""
if [ -d "$(pwd)/.git" ] || git rev-parse --git-dir >/dev/null 2>&1; then
	# Try exact tag first (for release builds)
	if git describe --tags --exact-match >/dev/null 2>&1; then
		AirOS_VERSION=$(git describe --tags --exact-match 2>/dev/null)
	else
		# Fall back to branch name
		AirOS_VERSION=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
	fi
fi

# Allow override from environment variable
export AirOS_VERSION="${AirOS_VERSION:-0.0.1}"

# Core paths
export AirOS="${AirOS:-/AirOS}"
export WORKSPACE="${WORKSPACE:-$AirOS/workspace}"
export L4T_DIR="${L4T_DIR:-$WORKSPACE/Linux_for_Tegra}"
export L4T_ROOTFS="${L4T_ROOTFS:-$L4T_DIR/rootfs}"
export L4T_SOURCE="${L4T_SOURCE:-$L4T_DIR/source}"

# Toolchain paths
export TOOL_CHAIN="${TOOL_CHAIN:-$WORKSPACE/tool_chain}"
export CROSS_COMPILE="${CROSS_COMPILE:-$TOOL_CHAIN/bin/aarch64-buildroot-linux-gnu-}"
export TEGRA_KERNEL_OUT="${TEGRA_KERNEL_OUT:-$L4T_SOURCE/out/nvidia-linux-header}"
export KERNEL_HEADERS="${KERNEL_HEADERS:-$L4T_SOURCE/kernel/kernel-jammy-src}"
export INSTALL_MOD_PATH="${INSTALL_MOD_PATH:-$L4T_ROOTFS}"

# Build configuration
export ARCH="${ARCH:-arm64}"

## Make a filesystem-safe version of AirOS_VERSION (replace slashes/spaces with underscores)
AirOS_VERSION_SAFE="${AirOS_VERSION//\//_}"
AirOS_VERSION_SAFE="${AirOS_VERSION_SAFE// /_}"
export AirOS_VERSION_SAFE

# Tarball will be named with sanitized AirOS version (avoid creating subdirs when branch names contain /)
export AIROS_L4T_TAR="${AIROS_L4T_TAR:-${AirOS_VERSION_SAFE}_$(date +"%Y%m%d_%H%M").tar.gz}"

# Load user configuration file (will be sourced after logging is available)
CONFIG_FILE="${CONFIG_FILE:-$AirOS/AirOS.conf}"
