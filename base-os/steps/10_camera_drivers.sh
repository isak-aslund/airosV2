#!/bin/bash
# ============================================================================
# AirOS Build Script - Step 10: Base System
# Description: Applies NVIDIA binaries, patches kernel, creates default user
# ============================================================================
set -e

step_install_econ_imx678() {
    log_step "🔧 Installing e-con ISP settings and misc files"
    ECON_RELEASE="e-CAM86_CUONX_JETSON_ONX_ONANO_L4T36.4.0_14-MAY-2025_R02"
    ECON_PATH="$WORKSPACE/$ECON_RELEASE"
    ECON_MISC="e-CAM86_CUONX_L4T36.4.0_JP6.1.0_JETSON-ONX-ONANO_R02"
    ECON_MISC_PATH=$ECON_PATH/$ECON_MISC/ONX_ONANO
    if [ ! -d "$ECON_PATH" ]; then
        echo "Extracting e-con IMX678 driver package"
        tar x -I gzip -f $AirOS/camera_drivers/$ECON_RELEASE.tar.gz -C $WORKSPACE || log_fail "Failed to extract e-con IMX678 driver package"
        cd $ECON_PATH
        tar xf $ECON_PATH/$ECON_MISC.tar.gz -C $ECON_PATH || log_fail "Failed to extract e-con IMX678 misc package"
    fi

    cp $ECON_PATH/Firmware/imx678_cam_fw.bin \
        $L4T_ROOTFS/lib/firmware/imx678_cam_fw.bin -f || log_fail "Failed to copy imx678_cam_fw.bin"

    # ISP settings
    cp "$ECON_MISC_PATH/misc/camera_overrides_jetson-onx.isp" \
        "$L4T_ROOTFS/var/nvidia/nvcam/settings/camera_overrides.isp" || log_fail "Failed to copy camera_overrides.isp"
    chmod 664 "$L4T_ROOTFS/var/nvidia/nvcam/settings/camera_overrides.isp"
    chown root:root "$L4T_ROOTFS/var/nvidia/nvcam/settings/camera_overrides.isp"

    # libnvisppg library
    cp "$ECON_MISC_PATH/misc/libnvisppg.so" \
        "$L4T_ROOTFS/usr/lib/aarch64-linux-gnu/nvidia/libnvisppg.so" || log_fail "Failed to copy libnvisppg.so"
    chmod 755 "$L4T_ROOTFS/usr/lib/aarch64-linux-gnu/nvidia/libnvisppg.so"

    # libnvcamerautils library
    cp "$ECON_MISC_PATH/misc/libnvcamerautils.so" \
        "$L4T_ROOTFS/usr/lib/aarch64-linux-gnu/nvidia/libnvcamerautils.so" || log_fail "Failed to copy libnvcamerautils.so"
    chmod 755 "$L4T_ROOTFS/usr/lib/aarch64-linux-gnu/nvidia/libnvcamerautils.so"

    # v4l2-compliance
    cp "$ECON_MISC_PATH/misc/v4l2-compliance" "$L4T_ROOTFS/usr/local/bin/" -f || log_fail "Failed to copy v4l2-compliance"
    chmod +x "$L4T_ROOTFS/usr/local/bin/v4l2-compliance"

    log_step "✅ e-con ISP/misc installation complete"
}

step_install_framos_IMX678() {
    log_step "📦 Installing FRAMOS IMX678 driver"
    FRAMOS_PATH="$WORKSPACE/framos-jetson-drivers"
    cd $WORKSPACE
    [ -d "$FRAMOS_PATH" ] || git clone https://github.com/framosimaging/framos-jetson-drivers.git $FRAMOS_PATH
    cd $FRAMOS_PATH
    git checkout l4t-r36.4

    # Apply camera_common NULL-ops guard patch
    log_info "Applying camera_common NULL-ops guard patch"
    GUARD_PATCH="$AirOS/patches/camera_drivers/framos_camera_common_null_ops_guard.patch"
    CAMERA_COMMON="$FRAMOS_PATH/source/nvidia-oot/drivers/media/platform/tegra/camera/camera_common.c"

    if ! grep -q "camera_common_ops_null_warned" "$CAMERA_COMMON"; then
        log_info "Applying camera_common NULL-ops guard"
        cd "$FRAMOS_PATH" && git apply "$GUARD_PATCH" || log_fail "camera_common NULL-ops guard patch failed"
    else
        log_info "  ✓ camera_common NULL-ops guard already present"
    fi

    cp -r source/hardware $L4T_SOURCE/. # TODO not necessary?
    cp -r source/nvidia-oot $L4T_SOURCE/.
    cp $FRAMOS_PATH/tools/jetson-config-camera*.py $L4T_ROOTFS/usr/bin/.
    cp $FRAMOS_PATH/tools/crosslink_configurator $L4T_ROOTFS/usr/bin/.
    mkdir -p $L4T_ROOTFS/opt/framos
    cp -r $FRAMOS_PATH/firmware $L4T_ROOTFS/opt/framos/.

    log_info "Installing FRAMOS IMX678 ISP settings"
    cd $FRAMOS_PATH
    git checkout l4t-r36.4.4 isp/IMX678_IRC650.isp
    cp $FRAMOS_PATH/isp/IMX678_IRC650.isp $L4T_ROOTFS/var/nvidia/nvcam/settings/camera_overrides.isp
    chown root:root $L4T_ROOTFS/var/nvidia/nvcam/settings/camera_overrides.isp
    chmod 664 $L4T_ROOTFS/var/nvidia/nvcam/settings/camera_overrides.isp
}

apply_patch_idempotent() {
    local patch_file="$1"
    local patch_dir="${2:-.}"
    local strip="${3:-1}"
    set +e
    patch -d "$patch_dir" -N -f -p"$strip" < "$patch_file" 2>/dev/null
    local rc=$?
    set -e
    if [ $rc -ne 0 ]; then
        # Check if patch is already applied (reverse dry-run succeeds)
        if patch -d "$patch_dir" -R --dry-run -f -p"$strip" < "$patch_file" >/dev/null 2>&1; then
            log_info "  Already applied: $(basename "$patch_file")"
        else
            log_fail "Patch $(basename "$patch_file") failed to apply"
        fi
    fi
}

step_apply_patches() {
    log_step "🔧 Applying patches and code modifications"

    # Apply standard L4T patches for ECON camera drivers (Makefile, max96712, vi/channel, etc.)
    cd $WORKSPACE
    for p in $AirOS/patches/*.patch; do
        apply_patch_idempotent "$p" "$WORKSPACE" 1
    done

    # ============================================================================
    # PROGRAMMATIC CODE MODIFICATIONS (vendor-independent, idempotent)
    # ============================================================================

    # 1. Add WDR DOL pixel formats to sensor_common.c (for AR0234 support)
    log_info "Adding WDR DOL pixel formats to sensor_common.c"
    SENSOR_COMMON="$L4T_SOURCE/nvidia-oot/drivers/media/platform/tegra/camera/sensor_common.c"

    # Check what's already present and add what's missing
    if ! grep -q "bayer_wdr_dol_gbrg12" "$SENSOR_COMMON"; then
        if ! grep -q "bayer_wdr_dol_rggb12" "$SENSOR_COMMON"; then
            # NVIDIA original - has only rggb10, missing rggb12, gbrg10, gbrg12
            # Add all three missing formats after existing rggb10
            awk '/bayer_wdr_dol_rggb10/ {print; getline; print; print "\telse if (strncmp(pixel_t, \"bayer_wdr_dol_rggb12\", size) == 0)"; print "\t\t*format = V4L2_PIX_FMT_SRGGB12;"; print "\telse if (strncmp(pixel_t, \"bayer_wdr_dol_gbrg10\", size) == 0)"; print "\t\t*format = V4L2_PIX_FMT_SGBRG10;"; print "\telse if (strncmp(pixel_t, \"bayer_wdr_dol_gbrg12\", size) == 0)"; print "\t\t*format = V4L2_PIX_FMT_SGBRG12;"; next} {print}' "$SENSOR_COMMON" > "$SENSOR_COMMON.tmp" && mv "$SENSOR_COMMON.tmp" "$SENSOR_COMMON"
            log_info "  ✓ Added missing WDR DOL formats (rggb12, gbrg10/12)"
        else
            # FRAMOS base - has rggb10/12, missing gbrg10/12
            awk '/bayer_wdr_dol_rggb12/ {print; getline; print; print "\telse if (strncmp(pixel_t, \"bayer_wdr_dol_gbrg10\", size) == 0)"; print "\t\t*format = V4L2_PIX_FMT_SGBRG10;"; print "\telse if (strncmp(pixel_t, \"bayer_wdr_dol_gbrg12\", size) == 0)"; print "\t\t*format = V4L2_PIX_FMT_SGBRG12;"; next} {print}' "$SENSOR_COMMON" > "$SENSOR_COMMON.tmp" && mv "$SENSOR_COMMON.tmp" "$SENSOR_COMMON"
            log_info "  ✓ Added missing WDR DOL formats (gbrg10/12)"
        fi
    else
        log_info "  ✓ All WDR DOL formats already present"
    fi

    # Apply camera driver module patches
    log_info "Adding camera driver modules"
    mkdir -p $L4T_SOURCE/sensor_driver
    apply_patch_idempotent "$AirOS/patches/camera_drivers/e-CAM25_CUONX_JETSON_ONX_ONANO_L4T36.4.0_module.patch" "$L4T_SOURCE/sensor_driver" 1
    if [ "$IMX678_VENDOR" = "econ" ]; then
        apply_patch_idempotent "$AirOS/patches/camera_drivers/e-CAM86_CUONX_JETSON_ONX_ONANO_L4T36.4.0_module.patch" "$L4T_SOURCE/sensor_driver" 1
        apply_patch_idempotent "$AirOS/patches/camera_drivers/Linux_for_Tegra_source_nvidia-oot_drivers_media_platform_tegra_camera_tegracam_ctrls.c.patch" "$WORKSPACE" 1
    fi

    log_info "✅ All patches and modifications applied successfully"
}
