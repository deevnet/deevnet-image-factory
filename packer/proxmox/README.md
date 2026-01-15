# packer/proxmox

Packer configurations for Proxmox VM templates and bare metal Proxmox VE installer ISOs.

See [docs/proxmox.md](../../docs/proxmox.md) for full documentation.

## Directory Structure

```
proxmox/
├── fedora-base-image/     # Fedora VM template for Proxmox
│   ├── fedora-43.pkr.hcl
│   └── http/kickstart.cfg
└── pve-iso/               # Proxmox VE bare metal installer ISO builder
    ├── Containerfile
    ├── answer-zfs.toml.template
    ├── answer-ext4.toml.template
    ├── build-iso.sh
    ├── extract-pxe.sh
    └── ipxe-proxmox.ipxe.template
```
