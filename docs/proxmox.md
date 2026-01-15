# Proxmox Builds

This document covers two things:
1. **VM Templates** - Guest OS images that run *on* Proxmox (Fedora)
2. **Proxmox VE Installation** - Automated ISOs for installing *Proxmox itself* on bare metal

## Overview

| Type | Purpose |
|------|---------|
| **VM Templates** | Fedora base images for cloning guest VMs |
| **PVE Bare Metal ISOs** | Automated installation of Proxmox VE hypervisor |

## VM Templates

### Fedora 43 Template

Builds a Fedora Server 43 template in Proxmox using kickstart.

```bash
# Set credentials
export TF_VAR_proxmox_url="https://proxmox:8006/api2/json"
export TF_VAR_proxmox_token_id="user@pam!token"
export TF_VAR_proxmox_token_secret="secret"
export TF_VAR_proxmox_node="pve"

# Build template
make proxmox-fedora
```

The template includes:
- Automation user (`a_autoprov`) with SSH key and passwordless sudo
- Minimal Fedora Server installation
- Cloud-init ready

### Required Environment Variables

| Variable | Description |
|----------|-------------|
| `TF_VAR_proxmox_url` | Proxmox API URL |
| `TF_VAR_proxmox_token_id` | API token ID |
| `TF_VAR_proxmox_token_secret` | API token secret |
| `TF_VAR_proxmox_node` | Target Proxmox node |

## Proxmox VE Bare Metal Installation

Builds customized ISOs for installing **Proxmox VE itself** (the hypervisor) on bare metal hardware. These ISOs include embedded or HTTP-fetched answer files for fully automated, unattended installation.

### Prerequisites

1. Build the container with Proxmox tooling (one-time):
   ```bash
   make proxmox-pve-iso-container
   ```

2. Generate a root password hash:
   ```bash
   PW_HASH=$(openssl passwd -6 'yourpassword')
   ```

### Build Targets

| Target | Description |
|--------|-------------|
| `proxmox-pve-iso-zfs` | ISO with embedded ZFS answer file |
| `proxmox-pve-iso-ext4` | ISO with embedded ext4+LVM answer file |
| `proxmox-pve-iso-http` | ISO for HTTP answer fetch (PXE-compatible) |
| `proxmox-pve-pxe` | Extract kernel/initrd for PXE boot |

### Examples

**ZFS with DHCP (most common):**
```bash
make proxmox-pve-iso-zfs \
    PVE_HOSTNAME=pve01.example.com \
    PVE_ROOT_PASSWORD_HASH="$PW_HASH"
```

**ext4+LVM:**
```bash
make proxmox-pve-iso-ext4 \
    PVE_HOSTNAME=pve02.example.com \
    PVE_ROOT_PASSWORD_HASH="$PW_HASH"
```

**HTTP-fetch for PXE boot:**
```bash
make proxmox-pve-iso-http \
    PVE_ANSWER_URL=http://artifacts.example.com/answers/default.toml
```

### Build Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PVE_ISO_VERSION` | `8.4-1` | Proxmox VE version |
| `PVE_HOSTNAME` | `pve.local` | Target FQDN |
| `PVE_TIMEZONE` | `America/New_York` | Timezone |
| `PVE_COUNTRY` | `us` | Country code |
| `PVE_KEYBOARD` | `en-us` | Keyboard layout |
| `PVE_EMAIL` | `root@localhost` | Admin email |
| `PVE_ROOT_PASSWORD_HASH` | (required) | Root password hash |
| `PVE_ANSWER_URL` | (for http mode) | Answer file URL |

### Output

ISOs are created in `packer/proxmox/pve-iso/output/`:
- `proxmox-ve-8.4-1-autoprov-zfs.iso`
- `proxmox-ve-8.4-1-autoprov-ext4.iso`
- `proxmox-ve-8.4-1-autoprov-http.iso`

## PXE Boot

For network installation of Proxmox VE:

```bash
# Extract kernel/initrd
make proxmox-pve-pxe
```

Outputs to `packer/proxmox/pve-iso/pxe/`:

| File | Description |
|------|-------------|
| `linux26` | Proxmox kernel |
| `initrd` | Initial ramdisk (~1.6GB) |
| `ipxe-proxmox.ipxe` | iPXE boot script |

Upload these to your artifact server. The iPXE script boots via HTTP (required due to initrd size).

## How It Works

1. Container runs `proxmox-auto-install-assistant` (Debian-only tool)
2. Answer file template is rendered with your variables
3. Answer file is validated
4. ISO is prepared with embedded or HTTP-fetch configuration
5. Boot the ISO - installation proceeds unattended

## Related Files

- `packer/proxmox/fedora-base-image/fedora-43.pkr.hcl` - Fedora template definition
- `packer/proxmox/fedora-base-image/http/kickstart.cfg` - Kickstart configuration
- `packer/proxmox/pve-iso/` - PVE ISO builder scripts and templates
