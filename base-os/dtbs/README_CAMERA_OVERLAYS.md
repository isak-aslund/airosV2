# Airolit CX10 Camera Device Tree Structure

## Overview

The device tree configuration follows a modular approach inspired by Framos, where a common base DTS provides shared infrastructure and camera-specific overlays enable individual cameras.

## File Structure

### Base Layer
- **`airolit_CX10_common.dts`** - Common camera platform base
  - Defines tegra-camera-platform with 4 disabled modules
  - Configures VI (Video Input) with 4 disabled ports
  - Configures NVCSI with 4 disabled channels
  - Configures GPIO controller (CAM0_PWDN, CAM1_PWDN)
  - Defines I2C multiplexer structure with 2 channels

### Camera Overlays (CAM0 - Port 0)
- **`airolit_CX10_AR0234.dts`** - ECON AR0234 camera on CAM0
  - Enables sensor_module0
  - Enables VI port 0 and CSI channel 0 (2 lanes)
  - Configures I2C channel 0 with PCA6408 GPIO expander
  - Sensor I2C address: 0x42
  - Video device: video0

### Camera Overlays (CAM1 - Port 2)
- **`airolit_CX10_ECON_IMX678.dts`** - ECON IMX678 camera on CAM1
  - Enables sensor_module1
  - Enables VI port 2 and CSI channel 2 (2 lanes)
  - Configures I2C channel 1 with TCA6424 GPIO expander
  - Sensor I2C address: 0x42
  - Video device: video1
  - Supports E-CON firmware and features

- **`airolit_CX10_FRAMOS_IMX678.dts`** - Framos IMX678 camera on CAM1
  - Enables sensor_module1
  - Enables VI port 2 and CSI channel 2 (2 lanes)
  - Configures I2C channel 1 with TCA6408 GPIO expander
  - Sensor I2C address: 0x1a
  - Video device: video1
  - Supports 10 sensor modes including HDR DOL modes

## Usage in extlinux.conf

The device tree overlays must be loaded in the correct order in your extlinux.conf file:

### Configuration Examples

#### AR0234 (CAM0) + ECON IMX678 (CAM1)
```
LABEL primary
    LINUX /boot/Image
    FDT /boot/dtb/kernel_tegra234-p3768-0000+p3767-0000-nv.dtb
    OVERLAYS /boot/airolit_CX10_common.dtbo /boot/airolit_CX10_AR0234.dtbo /boot/airolit_CX10_ECON_IMX678.dtbo
    APPEND ${cbootargs} ...
```

#### AR0234 (CAM0) + Framos IMX678 (CAM1)
```
LABEL primary
    LINUX /boot/Image
    FDT /boot/dtb/kernel_tegra234-p3768-0000+p3767-0000-nv.dtb
    OVERLAYS /boot/airolit_CX10_common.dtbo /boot/airolit_CX10_AR0234.dtbo /boot/airolit_CX10_FRAMOS_IMX678.dtbo
    APPEND ${cbootargs} ...
```

#### AR0234 (CAM0) only
```
LABEL primary
    LINUX /boot/Image
    FDT /boot/dtb/kernel_tegra234-p3768-0000+p3767-0000-nv.dtb
    OVERLAYS /boot/airolit_CX10_common.dtbo /boot/airolit_CX10_AR0234.dtbo
    APPEND ${cbootargs} ...
```

#### ECON IMX678 (CAM1) only
```
LABEL primary
    LINUX /boot/Image
    FDT /boot/dtb/kernel_tegra234-p3768-0000+p3767-0000-nv.dtb
    OVERLAYS /boot/airolit_CX10_common.dtbo /boot/airolit_CX10_ECON_IMX678.dtbo
    APPEND ${cbootargs} ...
```

#### Framos IMX678 (CAM1) only
```
LABEL primary
    LINUX /boot/Image
    FDT /boot/dtb/kernel_tegra234-p3768-0000+p3767-0000-nv.dtb
    OVERLAYS /boot/airolit_CX10_common.dtbo /boot/airolit_CX10_FRAMOS_IMX678.dtbo
    APPEND ${cbootargs} ...
```

## Important Notes

1. **Load Order**: `airolit_CX10_common.dtbo` MUST always be loaded first
2. **Port Mapping**:
   - CAM0 connector → CSI port 0 → video0
   - CAM1 connector → CSI port 2 → video1
3. **I2C Channels**:
   - CAM0 uses I2C channel 0 (i2c@0)
   - CAM1 uses I2C channel 1 (i2c@1)
4. **GPIO Expanders**:
   - AR0234: PCA6408 @ 0x20
   - ECON IMX678: TCA6424 @ 0x22
   - Framos IMX678: TCA6408 @ 0x20
5. **Cannot Mix IMX678 Variants**: Only one IMX678 overlay (ECON or Framos) can be used at a time on CAM1

## Hardware Configuration

### Supported Combinations
- ✅ AR0234 (CAM0) + ECON IMX678 (CAM1)
- ✅ AR0234 (CAM0) + Framos IMX678 (CAM1)
- ✅ AR0234 (CAM0) only
- ✅ ECON IMX678 (CAM1) only
- ✅ Framos IMX678 (CAM1) only

### Not Supported
- ❌ ECON IMX678 + Framos IMX678 simultaneously (both use same CSI port)

## GPIO Pin Assignments

### Common (defined in airolit_CX10_common.dts)
- CAM0_PWDN: TEGRA234_MAIN_GPIO(H, 6)
- CAM1_PWDN: TEGRA234_MAIN_GPIO(AC, 0)
- CAM_I2C_MUX: TEGRA234_AON_GPIO(CC, 3)

### Camera-specific GPIO expander pins
See individual camera overlay files for specific GPIO expander pin assignments.

## Troubleshooting

### Cameras not detected
1. Verify extlinux.conf has correct overlay order
2. Check that `airolit_CX10_common.dtbo` is loaded first
3. Verify correct .dtbo files are in /boot/
4. Check kernel logs: `dmesg | grep -i camera`

### I2C errors
1. Ensure only compatible overlays are loaded together
2. Check I2C addresses don't conflict
3. Verify GPIO expander initialization: `i2cdetect -y -r 9` or `i2cdetect -y -r 10`

### Video device not appearing
1. Check V4L2 devices: `v4l2-ctl --list-devices`
2. Verify sensor driver loaded: `lsmod | grep -E 'ar0234|imx678|eimx678'`
3. Check device tree: `ls /proc/device-tree/bus@0/cam_i2cmux/`
