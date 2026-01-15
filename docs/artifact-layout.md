# Artifact Layout

Organization and naming conventions for build artifacts.

## Artifact Types

### Raspberry Pi Images

**Naming:** `raspios-bookworm-<platform>-<variant>.img.xz`

| Variant | Description |
|---------|-------------|
| `pi-sdr` | CaribouLite SDR HAT support |
| `pi-pidp11` | PiDP-11 with SIMH emulator |

**Output location:** Repository root
**Example:** `raspios-bookworm-dvntm-pi-sdr.img.xz`

Each image also produces a manifest JSON with build metadata.

### Proxmox VM Templates

**Naming:** `<os>-<version>` (stored directly in Proxmox)

| Template | Description |
|----------|-------------|
| `fedora-43` | Fedora Server 43 with automation user |

**Output location:** Proxmox storage (not local files)

### Proxmox VE ISOs

**Naming:** `proxmox-ve-<version>-autoprov-<fs>.iso`

| Variant | Description |
|---------|-------------|
| `autoprov-zfs` | ZFS filesystem with embedded answer |
| `autoprov-ext4` | ext4+LVM with embedded answer |
| `autoprov-http` | HTTP answer fetch (for PXE) |

**Output location:** `packer/proxmox/pve-iso/output/`

### PXE Boot Artifacts

**Output location:** `packer/proxmox/pve-iso/pxe/`

| File | Description |
|------|-------------|
| `linux26` | Proxmox kernel |
| `initrd` | Initial ramdisk (~1.6GB) |
| `ipxe-proxmox.ipxe` | iPXE boot script |

## Common Characteristics

All images include:
- Automation user `a_autoprov` with SSH key authentication
- Passwordless sudo for automation user
- Ready for downstream Ansible provisioning
