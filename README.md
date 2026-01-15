# Deevnet Image Factory

Builds customized OS images for Raspberry Pi devices, Proxmox VM templates, and bare metal Proxmox VE installations.

## Build Targets

| Target | Description |
|--------|-------------|
| `make pi-sdr` | Raspberry Pi SDR image with CaribouLite HAT support |
| `make pi-pidp11` | Raspberry Pi PiDP-11 image with SIMH emulator |
| `make proxmox-fedora` | Proxmox Fedora 43 VM template |
| `make proxmox-pve-iso-zfs` | Proxmox VE bare metal ISO (ZFS) |
| `make proxmox-pve-iso-ext4` | Proxmox VE bare metal ISO (ext4+LVM) |
| `make proxmox-pve-pxe` | Extract PXE boot artifacts for network install |

Run `make help` for the full list.

## Quick Start

```bash
# Check prerequisites
make check-deps

# Build a Raspberry Pi SDR image
make pi-sdr

# Build a Proxmox Fedora template (requires env vars)
export TF_VAR_proxmox_url="https://proxmox:8006/api2/json"
export TF_VAR_proxmox_token_id="user@pam!token"
export TF_VAR_proxmox_token_secret="secret"
export TF_VAR_proxmox_node="pve"
make proxmox-fedora
```

## Prerequisites

- Packer
- Ansible
- Podman
- qemu-user-static (for ARM emulation)
- cloud-utils-growpart
- Access to artifact server at `artifacts.dvntm.deevnet.net`

## Documentation

- [Pi SDR Image](docs/pi-sdr.md) - CaribouLite SDR build and usage
- [Pi PiDP-11 Image](docs/pi-pidp11.md) - PDP-11 emulator build
- [Proxmox Builds](docs/proxmox.md) - VM templates and bare metal ISOs
- [Artifact Layout](docs/artifact-layout.md) - Output naming conventions
- [Design Notes](docs/design-notes.md) - Architectural decisions

## Output

All images include an automation user (`a_autoprov`) with SSH key authentication and passwordless sudo for downstream Ansible provisioning.

| Platform | Output |
|----------|--------|
| Raspberry Pi | `.img.xz` files ready for Pi Imager |
| Proxmox VM | Templates stored in Proxmox |
| Proxmox VE | `.iso` files for bare metal install |

## License

MIT
