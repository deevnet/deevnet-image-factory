# Pi SDR Image Build

This document covers building and deploying the Raspberry Pi SDR image with CaribouLite HAT support.

## Overview

The `pi-sdr` target creates a Raspberry Pi image pre-configured for the [CaribouLite](https://github.com/cariboulabs/cariboulite) software-defined radio HAT. The image includes:

- Base Raspbian Bookworm (ARM64)
- Automation user (`a_autoprov`) for Ansible provisioning
- CaribouLite source code cloned to `/opt/cariboulite`
- Kernel API patch for Linux 6.4+ compatibility
- SoapySDR tools and systemd service (disabled by default)
- Boot configuration for CaribouLite hardware

## Build Process

```bash
# Full pipeline: base image -> resize -> SDR config -> compress
make pi-sdr
```

The build pipeline:
1. **pi-bookworm-image**: Creates base Bookworm image with automation user
2. **pi-resize-image**: Expands image to 8GB
3. **pi-sdr-config**: Applies CaribouLite configuration via Ansible (offline chroot)
4. **pi-compress-image**: Compresses with xz for distribution

## Boot Configuration

CaribouLite requires specific `/boot/firmware/config.txt` settings:

| Setting | Required State | Purpose |
|---------|----------------|---------|
| `dtparam=spi=on` | Commented out | Standard SPI0 conflicts with CaribouLite |
| `dtparam=i2c_arm=on` | Commented out | ARM I2C not used by CaribouLite |
| `dtparam=i2c_vc=on` | Enabled | VideoCore I2C for EEPROM communication |
| `dtoverlay=spi1-3cs` | Enabled | AUX SPI1 with 3 chip selects for modem/FPGA |
| `enable_uart=1` | Enabled | Serial console access |

The CaribouLite `install.sh` script validates these settings and will warn if incorrect.

## First Boot Instructions

After flashing the image to an SD card:

1. Insert SD card and attach CaribouLite HAT to the Raspberry Pi
2. Boot the system
3. Login as `pisdr` (password: `pisdr`) or `a_autoprov` (SSH key auth)
4. Run the CaribouLite installation:

```bash
cd /opt/cariboulite
./install.sh
```

5. Reboot when prompted:

```bash
sudo reboot
```

## Verification

The image includes a validation script at `/home/pisdr/cariboulite-validate.sh` that automates verification.

### Quick Validation

Run the validation script to check everything:

```bash
# Full validation (OS + SoapySDR + hardware self-test)
~/cariboulite-validate.sh

# Quick OS checks only (before install.sh)
~/cariboulite-validate.sh --quick

# Full test including RF capture
~/cariboulite-validate.sh --rf-test
```

### Manual Verification

If you prefer to verify manually:

1. **Check kernel modules are loaded:**
   ```bash
   lsmod | grep smi
   ```
   Expected output:
   ```
   smi_stream_dev         16384  0
   bcm2835_smi            20480  1 smi_stream_dev
   ```

2. **Verify SoapySDR detects the device:**
   ```bash
   SoapySDRUtil --find
   ```
   Expected output should list CaribouLite device with S1G and HiF channels.

3. **Run hardware self-test:**
   ```bash
   /opt/cariboulite/build/cariboulite_test_app
   ```
   Should report FPGA, modem (AT86RF215), and mixer (RFFC5072) initialized.

4. **Test RF capture (optional):**
   ```bash
   cariboulite_util -c 1 -f 100000000 -g 50 -n 500000 /tmp/test.cs16
   ```

### What the Validation Script Checks

| Category | Checks |
|----------|--------|
| Kernel Modules | smi_stream_dev loaded, bcm2835_smi loaded, bcm2835_smi_dev blacklisted |
| Boot Config | i2c_vc enabled, spi1-3cs enabled, standard SPI/I2C disabled |
| Device Nodes | /dev/smi exists with correct permissions, SPI1 devices present |
| Modprobe Config | SMI stream config exists, blacklist config exists |
| SoapySDR | Device detected, S1G and HiF channels found, probe successful |
| Hardware | FPGA initialized, modem detected, mixer detected, self-test passed |
| RF Capture | Samples captured, data is non-zero (--rf-test mode only) |

## Network SDR Access

To enable remote SDR access via SoapyRemote:

```bash
sudo systemctl enable --now SoapySDRServer
```

The server listens on port 55132. Connect from remote clients:

```bash
SoapySDRUtil --find="driver=remote,remote=<pi-ip-address>"
```

## Troubleshooting

### install.sh reports configuration warnings

If `install.sh` warns about SPI or I2C configuration, verify `/boot/firmware/config.txt` contains:

```
#dtparam=spi=on
#dtparam=i2c_arm=on
dtparam=i2c_vc=on
dtoverlay=spi1-3cs
```

### Kernel module fails to compile

The image includes a patch for the `class_create()` kernel API change in Linux 6.4+. If compilation still fails, check kernel headers are installed:

```bash
sudo apt-get install raspberrypi-kernel-headers
```

### No device found by SoapySDR

1. Verify the CaribouLite HAT is properly seated
2. Check dmesg for SMI-related errors: `dmesg | grep -i smi`
3. Ensure both kernel modules loaded: `lsmod | grep smi`

## Related Files

- `ansible/playbooks/pi-sdr-config.yml` - Ansible playbook for SDR configuration
- `packer/pi/sdr-bookworm.pkr.hcl` - Packer base image definition
- `scripts/cariboulite-validate.sh` - Source for the validation script
- `/opt/cariboulite/` - CaribouLite source on the built image
- `/home/pisdr/cariboulite-validate.sh` - Validation script (on built image)
- `/opt/deevnet/README-sdr.txt` - Baked-in reference documentation
