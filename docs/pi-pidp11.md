# Pi PiDP-11 Image Build

This document covers building and deploying the Raspberry Pi PiDP-11 image for the [PiDP-11](https://obsolescence.wixsite.com/obsolescence/pidp-11) front panel replica.

## Overview

The `pi-pidp11` target creates a Raspberry Pi image pre-configured for the PiDP-11 replica kit. The image includes:

- Base Raspbian Bookworm (ARM64)
- Automation user (`a_autoprov`) for Ansible provisioning
- SIMH simulators from Debian packages
- Boot configuration for GPIO access (SPI, I2C, UART)

## Build Process

```bash
# Full pipeline: base image -> resize -> config -> compress
make pi-pidp11
```

The build pipeline:
1. **pi-bookworm-image-pidp11**: Creates base Bookworm image with automation user
2. **pi-resize-image-pidp11**: Expands image to 8GB
3. **pi-pidp11-config**: Applies PiDP-11 configuration via Ansible (offline chroot)
4. **pi-compress-image-pidp11**: Compresses with xz for distribution

## First Boot Instructions

After flashing the image to an SD card:

1. Insert SD card into your Raspberry Pi with PiDP-11 attached
2. Boot the system
3. Login as `pidp11` (password: `pidp11`) or `a_autoprov` (SSH key auth)

## Included Software

| Package | Description |
|---------|-------------|
| `simh` | Multi-system emulator (PDP-11, VAX, and others) |

SimH binaries are installed to `/usr/bin/`:
- `pdp11` - PDP-11 simulator
- `vax` - VAX simulator
- Many others (see `dpkg -L simh`)

## Boot Configuration

The image configures `/boot/firmware/config.txt` with GPIO settings for the front panel:

| Setting | State | Purpose |
|---------|-------|---------|
| `dtparam=spi=on` | Enabled | SPI for panel communication |
| `dtparam=i2c_arm=on` | Enabled | I2C bus |
| `enable_uart=1` | Enabled | Serial console access |

## User Accounts

| User | Access | Purpose |
|------|--------|---------|
| `a_autoprov` | SSH key only | Ansible automation |
| `pidp11` | Password: `pidp11` | Interactive use |

Both users have passwordless sudo.

## Related Files

- `ansible/playbooks/pi-pidp11-config.yml` - Ansible playbook for PiDP-11 configuration
- `packer/pi/sdr-bookworm.pkr.hcl` - Packer base image definition (shared with SDR)
- `/opt/deevnet/README-pidp11.txt` - Baked-in reference documentation (on built image)
