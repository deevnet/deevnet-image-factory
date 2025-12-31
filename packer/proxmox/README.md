# packer/proxmox

Packer configurations for Proxmox VM templates and bare metal installer ISOs.

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

---

## Fedora VM Template

Builds a Fedora Server 43 template in Proxmox using kickstart.

### Usage

```bash
packer init fedora-base-image/fedora-43.pkr.hcl
packer build fedora-base-image/fedora-43.pkr.hcl
```

### Required Environment Variables

- `TF_VAR_proxmox_url` - Proxmox API URL
- `TF_VAR_proxmox_token_id` - API token ID
- `TF_VAR_proxmox_token_secret` - API token secret
- `TF_VAR_proxmox_node` - Target Proxmox node

---

## Proxmox VE Bare Metal Installer ISO

Builds customized Proxmox VE installer ISOs with embedded or HTTP-fetched answer files for automated bare metal installation.

### Prerequisites

1. **Proxmox ISO on artifact server** - Fetch via ansible-collection-deevnet.builder artifacts role
2. **Container built** - One-time setup

### Quick Start

```bash
# From repository root

# 1. Build the container (one-time)
make proxmox-pve-iso-container

# 2. Generate a root password hash
PW_HASH=$(openssl passwd -6 'yourpassword')

# 3. Build an ISO with embedded answer file
make proxmox-pve-iso-zfs \
    PVE_HOSTNAME=pve01.example.com \
    PVE_ROOT_PASSWORD_HASH="$PW_HASH"
```

### Make Targets

| Target | Description |
|--------|-------------|
| `proxmox-pve-iso-container` | Build Debian container with Proxmox tooling (one-time) |
| `proxmox-pve-iso-zfs` | Build ISO with embedded ZFS answer file |
| `proxmox-pve-iso-ext4` | Build ISO with embedded ext4+LVM answer file |
| `proxmox-pve-iso-http` | Build ISO for HTTP answer fetch (PXE-compatible) |
| `proxmox-pve-pxe` | Extract kernel/initrd for PXE boot |
| `proxmox-pve-iso-clean` | Clean build artifacts |

### Build Variables

Override on the command line:

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

### Examples

**ZFS with DHCP (most common):**
```bash
make proxmox-pve-iso-zfs \
    PVE_HOSTNAME=pve01.dvnt.deevnet.net \
    PVE_ROOT_PASSWORD_HASH="$(openssl passwd -6 'secret')"
```

**ext4+LVM with static IP:**
```bash
make proxmox-pve-iso-ext4 \
    PVE_HOSTNAME=pve02.dvnt.deevnet.net \
    PVE_ROOT_PASSWORD_HASH="$PW_HASH"
```

**HTTP-fetch for PXE boot:**
```bash
make proxmox-pve-iso-http \
    PVE_ANSWER_URL=http://artifacts.dvntm.deevnet.net/isos/proxmox/answers/default.toml
```

### PXE Boot

For network installation:

```bash
# Extract kernel/initrd
make proxmox-pve-pxe

# Outputs to packer/proxmox/pve-iso/pxe/:
#   linux26              - Kernel
#   initrd               - Initial ramdisk (~1.6GB)
#   ipxe-proxmox.ipxe    - iPXE boot script
```

Upload these to your artifact server. The iPXE script boots via HTTP (required due to initrd size).

### Output

ISOs are created in `packer/proxmox/pve-iso/output/`:
- `proxmox-ve-8.4-1-autoprov-zfs.iso`
- `proxmox-ve-8.4-1-autoprov-ext4.iso`
- `proxmox-ve-8.4-1-autoprov-http.iso`

### How It Works

1. Container runs `proxmox-auto-install-assistant` (Debian-only tool)
2. Answer file template is rendered with your variables
3. Answer file is validated
4. ISO is prepared with embedded or HTTP-fetch configuration
5. Boot the ISO - installation proceeds unattended
