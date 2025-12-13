# packer/pi

Packer configurations for Raspberry Pi images.

## Files

- `sdr-bookworm.pkr.hcl` - Raspberry Pi OS Bookworm 64-bit for SDR applications

## Usage

```bash
packer init sdr-bookworm.pkr.hcl
packer build sdr-bookworm.pkr.hcl
```

## Prerequisites

- `qemu-aarch64-static` binary at `/usr/bin/qemu-aarch64-static`
- Packer ARM plugin (auto-installed via `packer init`)
