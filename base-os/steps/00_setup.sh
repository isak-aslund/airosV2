#!/bin/bash
# ============================================================================
# AirOS Build Script - Step 00: Setup
# Description: Validates environment, downloads L4T, and extracts all packages
# ============================================================================
set -e
# ----------- VALIDATION -----------
step_validate_build_environment() {
    log_step "🔍 Validating build environment prerequisites"
    log_info "Checking qemu-aarch64-static availability..."
    if [ ! -x "/usr/bin/qemu-aarch64-static" ]; then
        log_error "❌ /usr/bin/qemu-aarch64-static not found!"
        log_info "   This is required for cross-architecture chroot operations."
        log_info "   Please install 'qemu-user-static' in your Docker image or host system."
        return 1
    fi
    log_info "✅ qemu-aarch64-static found at /usr/bin/qemu-aarch64-static"

    log_info "Checking binfmt_misc kernel support..."
    if [ ! -d /proc/sys/fs/binfmt_misc ]; then
        log_error "❌ /proc/sys/fs/binfmt_misc not available!"
        log_info "   The kernel's binfmt_misc support is required for qemu-user emulation."
        log_info "   Make sure your Docker container runs with --privileged flag."
        return 1
    fi
    log_info "✅ binfmt_misc kernel support available"

    log_info "Ensuring QEMU aarch64 binfmt registration..."
    if command -v update-binfmts >/dev/null 2>&1; then
        update-binfmts --enable qemu-aarch64 >/dev/null 2>&1 || true
    fi
    log_info "✅ QEMU aarch64 ready"

    log_step "✅ Build environment validation complete - all prerequisites met!"
    return 0
}

# ----------- DOWNLOAD -----------
step_download_l4t() {
    log_step "📥 Downloading L4T base files"

    mkdir -p $WORKSPACE
    cd $WORKSPACE

    # L4T BSP
    [ -f "Jetson_Linux_R36.4.0_aarch64.tbz2" ] || \
        wget https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.0/release/Jetson_Linux_R36.4.0_aarch64.tbz2

    # Sample root filesystem
    [ -f "Tegra_Linux_Sample-Root-Filesystem_R36.4.0_aarch64.tbz2" ] || \
        wget https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.0/release/Tegra_Linux_Sample-Root-Filesystem_R36.4.0_aarch64.tbz2

    # Kernel sources
    [ -f "public_sources.tbz2" ] || \
        wget https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.0/sources/public_sources.tbz2

    # Tool chain
    [ -f "aarch64--glibc--stable-2022.08-1.tar.bz2" ] || \
        wget https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v3.0/toolchain/aarch64--glibc--stable-2022.08-1.tar.bz2

    log_step "✅ Downloads complete!"
}

# ----------- EXTRACTION -----------
step_extract_l4t() {
    log_step "📦 Extracting L4T"
    cd $WORKSPACE
    [ -d "$WORKSPACE/Linux_for_Tegra" ] || tar --use-compress-program=lbzip2 -xf Jetson_Linux_R36.4.0_aarch64.tbz2
}

step_extract_rootfs() {
    log_step "📦 Extracting Ubuntu rootfs"
    cd $WORKSPACE
    [ -d "$WORKSPACE/Linux_for_Tegra/rootfs/bin" ] || tar --use-compress-program=lbzip2 -xpf Tegra_Linux_Sample-Root-Filesystem_R36.4.0_aarch64.tbz2 -C Linux_for_Tegra/rootfs/
    mkdir -p $L4T_ROOTFS/home/$FIRST_USER_NAME/dev
    mkdir -p $L4T_ROOTFS/home/$FIRST_USER_NAME/Downloads
}

step_extract_toolchain() {
    log_step "📦 Extracting toolchain"
    cd $WORKSPACE
    [ -d "$TOOL_CHAIN/bin" ] || {
        mkdir -p $TOOL_CHAIN
        tar --use-compress-program=lbzip2 --strip-components=1 -xf $WORKSPACE/aarch64--glibc--stable-2022.08-1.tar.bz2 -C $TOOL_CHAIN
        export PATH=$TOOL_CHAIN/bin:$PATH
    }
}

step_extract_kernel_package() {
    log_step "📦 Extracting kernel package"
    cd $WORKSPACE
    [ -d "$L4T_SOURCE/hardware" ] || {
        tar --use-compress-program=lbzip2 -xf public_sources.tbz2
        cd $L4T_SOURCE
        #./source_sync.sh -k -t jetson_36.4
        tar --use-compress-program=lbzip2 -xf kernel_src.tbz2
        tar --use-compress-program=lbzip2 -xf kernel_oot_modules_src.tbz2
        tar --use-compress-program=lbzip2 -xf nvidia_kernel_display_driver_source.tbz2
    }
}

step_apply_nvidia_binaries() {
    log_step "🔧 Applying NVIDIA binaries"
    cd $L4T_DIR

    # Idempotency: skip if NVIDIA binaries are already installed (from a previous run)
    if [ -f "$L4T_ROOTFS/usr/lib/aarch64-linux-gnu/tegra/libcuda.so" ]; then
        log_info "NVIDIA binaries already installed — skipping"
        return 0
    fi

    # apply_binaries.sh runs nv-apply-debs.sh which installs L4T debs via QEMU chroot.
    # The libc-bin post-install trigger (ldconfig) is known to segfault under QEMU 6.x
    # user-mode emulation. This is cosmetic — all packages install correctly.
    set +e
    ./apply_binaries.sh
    rc=$?
    set -e
    if [ $rc -ne 0 ]; then
        # Check if the failure is just the known QEMU libc-bin trigger issue
        if [ -f "$L4T_ROOTFS/usr/lib/aarch64-linux-gnu/tegra/libcuda.so" ]; then
            log_warn "apply_binaries.sh exited with code $rc (likely QEMU libc-bin trigger segfault — non-fatal)"
        else
            log_error "ERROR: ./apply_binaries.sh exited with code $rc. NVIDIA binaries not installed."
            return $rc
        fi
    fi
}

step_create_default_user() {
    log_step "👤 Creating default user"
    # Idempotency: skip if user already exists in rootfs
    if grep -q "^${FIRST_USER_NAME}:" "$L4T_ROOTFS/etc/passwd" 2>/dev/null; then
        log_info "User $FIRST_USER_NAME already exists — skipping"
        return 0
    fi
    cd $L4T_DIR
    ./tools/l4t_create_default_user.sh \
        --username $FIRST_USER_NAME \
        --password $FIRST_USER_PASSWORD \
        --hostname airos-drone \
        --autologin \
        --accept-license
}
