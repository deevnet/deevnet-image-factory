# packer/proxmox

Packer configurations for Proxmox VM templates and bare metal Proxmox VE installer ISOs.

Documentation:
- [VM Template](../../docs/proxmox-vm-template.md) - Fedora template build
- [PVE Install](../../docs/proxmox-pve-install.md) - Bare metal hypervisor installation

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
