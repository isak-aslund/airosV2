#!/bin/bash
# ============================================================================
# AirOS Build Script - Step 20: Kernel & Drivers
# Description: Builds kernel, DTBs, and configures boot
# ============================================================================
set -e
# ----------- Kernel config and build -----------
step_configure_extlinux() {
    log_step "📝 Configuring extlinux.conf for camera overlays"

    EXTLINUX_CONF="$L4T_ROOTFS/boot/extlinux/extlinux.conf"
    KERNEL_IMAGE="/boot/Image"
    FDT="/boot/dtb/kernel_tegra234-p3768-0000+p3767-0001-nv.dtb"
    INITRD="/boot/initrd"
    APPEND="\${cbootargs}"
    BACKUP_LABEL="Airolit AirOS Backup (no camera overlays)"

    COMMON_OVERLAYS=(
        "/boot/airolit_CX10_AIROLIGHT.dtbo"
        "/boot/airolit_CX10_COMMON.dtbo"
    )

    AR0234_OVERLAY="/boot/airolit_CX10_AR0234.dtbo"

    if [ "$IMX678_VENDOR" = "framos" ]; then
        VENDOR_OVERLAYS=(
            "/boot/airolit_CX10_FRAMOS_IMX678.dtbo"
        )
        MENU_LABEL="Airolit Camera Drivers FRAMOS IMX678 + AR0234"
    elif [ "$IMX678_VENDOR" = "econ" ]; then
        VENDOR_OVERLAYS=(
            "/boot/airolit_CX10_ECON_IMX678.dtbo"
        )
        MENU_LABEL="Airolit Camera Drivers E-CON IMX678 + AR0234"
    else
        log_fail "❌ Unknown IMX678_VENDOR: $IMX678_VENDOR"
    fi

    # AR0234 MUST be loaded BEFORE FPV camera overlays to avoid camera platform override
    OVERLAYS_LIST=("${COMMON_OVERLAYS[@]}" "$AR0234_OVERLAY" "${VENDOR_OVERLAYS[@]}")
    IFS=',' OVERLAYS="${OVERLAYS_LIST[*]}"

    tee "$EXTLINUX_CONF" > /dev/null <<EOF
TIMEOUT 30
DEFAULT airos

MENU TITLE L4T boot options

LABEL airos
      MENU LABEL $MENU_LABEL
      LINUX $KERNEL_IMAGE
      FDT $FDT
      INITRD $INITRD
      APPEND $APPEND
      OVERLAYS $OVERLAYS

LABEL airos-backup
      MENU LABEL $BACKUP_LABEL
      LINUX $KERNEL_IMAGE
      FDT $FDT
      INITRD $INITRD
      APPEND $APPEND
EOF
    log_info "Done configuring extlinux.conf"
}

# ----------- DEVICE TREE OVERLAYS -----------
add_dtbo_to_makefile() {
    local dts_file="$1"
    local dtbo_name="${dts_file%.dts}.dtbo"
    local DTBO_MAKEFILE="$L4T_SOURCE/hardware/nvidia/t23x/nv-public/overlay/Makefile"

    log_info "Adding $dtbo_name to Makefile"
    cp "$AirOS/dtbs/$dts_file" "$L4T_SOURCE/hardware/nvidia/t23x/nv-public/overlay/"

    if ! grep -q "dtbo-y += $dtbo_name" "$DTBO_MAKEFILE"; then
        awk 'NR==12{print "dtbo-y += '"$dtbo_name"'"}1' "$DTBO_MAKEFILE" > "$DTBO_MAKEFILE.tmp" && mv "$DTBO_MAKEFILE.tmp" "$DTBO_MAKEFILE"
    fi
}

step_copy_device_tree_overlays() {
    log_step "📦 Copying device tree overlays"

    add_dtbo_to_makefile "airolit_CX10_COMMON.dts"
    add_dtbo_to_makefile "airolit_CX10_AR0234.dts"

    if [ "$IMX678_VENDOR" = "framos" ]; then
        add_dtbo_to_makefile "airolit_CX10_FRAMOS_IMX678.dts"
    elif [ "$IMX678_VENDOR" = "econ" ]; then
        add_dtbo_to_makefile "airolit_CX10_ECON_IMX678.dts"
    fi
}


step_build_kernel() {
    log_step "🔨 Building and installing kernel modules..."
    # Idempotency: skip if kernel Image and modules are already built
    if [ -f "$L4T_DIR/kernel/Image" ] && \
       [ -d "$L4T_ROOTFS/lib/modules" ] && \
       ls "$L4T_ROOTFS/lib/modules"/*/modules.dep >/dev/null 2>&1; then
        log_info "Kernel already built — skipping (delete $L4T_DIR/kernel/Image to force rebuild)"
        return 0
    fi
    cd $L4T_SOURCE
    make -C kernel
    if [ $? -ne 0 ]; then
        log_fail "❌ make -C kernel failed!"
    fi

    make install -C kernel
    if [ $? -ne 0 ]; then
        log_fail "❌ make install -C kernel failed!"
    fi
    cp $KERNEL_HEADERS/arch/arm64/boot/Image ${L4T_DIR}/kernel/Image

    make modules
    if [ $? -ne 0 ]; then
        log_fail "❌ make modules failed!"
    fi

    make modules_install
    if [ $? -ne 0 ]; then
        log_fail "❌ make modules_install failed!"
    fi

    make dtbs
    if [ $? -ne 0 ]; then
        log_fail "❌ make dtbs failed!"
    fi
    cp kernel-devicetree/generic-dts/dtbs/* $L4T_DIR/kernel/dtb/

    cd $L4T_DIR
    ./tools/l4t_update_initrd.sh
    if [ $? -ne 0 ]; then
        log_fail "❌ ./tools/l4t_update_initrd.sh failed!"
    fi
}

step_copy_dtbo_to_rootfs() {
    log_step "📦 Copying DTBO files to rootfs"
    cp $L4T_SOURCE/kernel-devicetree/generic-dts/dtbs/airolit_CX10_COMMON.dtbo $L4T_ROOTFS/boot/
    cp $L4T_SOURCE/kernel-devicetree/generic-dts/dtbs/airolit_CX10_AR0234.dtbo $L4T_ROOTFS/boot/
    cp $AirOS/dtbs/airolit_CX10_AIROLIGHT.dtbo $L4T_ROOTFS/boot/airolit_CX10_AIROLIGHT.dtbo
    if [ "$IMX678_VENDOR" = "framos" ]; then
        mkdir -p $L4T_ROOTFS/boot/framos/dtbo
        cp $L4T_SOURCE/kernel-devicetree/generic-dts/dtbs/airolit_CX10_FRAMOS_IMX678.dtbo $L4T_ROOTFS/boot/
    elif [ "$IMX678_VENDOR" = "econ" ]; then
        cp $L4T_SOURCE/kernel-devicetree/generic-dts/dtbs/airolit_CX10_ECON_IMX678.dtbo $L4T_ROOTFS/boot/
    fi
}

step_setup_power_mode() {
    log_step "⚡ Setting up power mode configuration"

    # Patch nvpmodel config to set default power mode (configurable via DEFAULT_POWER_MODE)
    if [ -f "$L4T_ROOTFS/etc/nvpmodel/nvpmodel_p3767_0001.conf" ]; then
        # Validate power mode value (0-3 for Orin NX)
        if [[ "$DEFAULT_POWER_MODE" =~ ^[0-3]$ ]]; then
            sed -i "s/< PM_CONFIG DEFAULT=[0-9] >/< PM_CONFIG DEFAULT=$DEFAULT_POWER_MODE >/" "$L4T_ROOTFS/etc/nvpmodel/nvpmodel_p3767_0001.conf"

            # Get mode name for logging
            case "$DEFAULT_POWER_MODE" in
                0) MODE_NAME="MAXN (25W)" ;;
                1) MODE_NAME="10W" ;;
                2) MODE_NAME="15W" ;;
                3) MODE_NAME="20W" ;;
            esac

            log_info "✓ Set nvpmodel default to mode $DEFAULT_POWER_MODE ($MODE_NAME)"
        else
            log_warning "⚠️  Invalid DEFAULT_POWER_MODE=$DEFAULT_POWER_MODE (must be 0-3), keeping default"
        fi
    else
        log_warning "⚠️  nvpmodel_p3767_0001.conf not found, skipping power mode configuration"
    fi
}

step_setup_journald() {
    log_step "📊 Configuring journald for persistent storage"

    cp "$AirOS/configs/journald.conf" "$L4T_ROOTFS/etc/systemd/journald.conf"
    log_info "✓ Journald configured with persistent storage (2GB max)"
}

step_disable_snapd() {
    log_step "🧹 Disabling snapd in rootfs (avoid boot hangs)"

    # Ensure systemd dirs exist even if systemd isn't fully configured yet.
    mkdir -p "$L4T_ROOTFS/etc/systemd/system"
    mkdir -p "$L4T_ROOTFS/etc/systemd/system/multi-user.target.wants"

    # Masking is safer than disable since it prevents socket activation + the seeded/autoimport units.
    ln -sf /dev/null "$L4T_ROOTFS/etc/systemd/system/snapd.service"
    ln -sf /dev/null "$L4T_ROOTFS/etc/systemd/system/snapd.socket"
    ln -sf /dev/null "$L4T_ROOTFS/etc/systemd/system/snapd.seeded.service"
    ln -sf /dev/null "$L4T_ROOTFS/etc/systemd/system/snapd.autoimport.service"
    ln -sf /dev/null "$L4T_ROOTFS/etc/systemd/system/snapd.apparmor.service" 2>/dev/null || true

    # Also remove any leftover wants symlinks if they exist (harmless if missing).
    rm -f "$L4T_ROOTFS/etc/systemd/system/multi-user.target.wants/snapd.service" \
          "$L4T_ROOTFS/etc/systemd/system/multi-user.target.wants/snapd.autoimport.service" \
          "$L4T_ROOTFS/etc/systemd/system/multi-user.target.wants/snapd.seeded.service" || true

    rm -f "$L4T_ROOTFS/etc/systemd/system/sockets.target.wants/snapd.socket" || true

    log_info "✓ snapd masked in rootfs"
}
