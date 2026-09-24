# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository builds customized OS images for various platforms using HashiCorp Packer. Images are created for Raspberry Pi (ARM-based) and Proxmox virtual machines. The primary purpose is to create base images with an automation user (`a_autoprov`) configured for passwordless SSH and sudo access, enabling downstream Ansible automation.

Base images are sourced from the local nginx artifact server (or remote), provisioned
with the automation user, and emitted as `.img` files for Raspberry Pi or VM templates
for Proxmox, each with a manifest JSON.

**The exception is `pi-backend`** (`docs/pi-backend.md`): a take-home image for a tenant's own Pi.
It is built on the same Packer step, then `pi-backend-config.yml` **removes** `a_autoprov` and fails
the build if any trace remains. Nothing secret is baked in; `deevnet-kit init` makes the card's CA
and tokens on first boot. Don't add Deevnet access to it.

### Platform-Specific Details

**Raspberry Pi (ARM)**:
- Uses Packer ARM plugin with QEMU ARM64 emulation
- Requires `qemu-aarch64-static` binary on host for chroot operations
- Creates DOS partition table with boot (FAT) and root (ext4) partitions
- User provisioned with Raspberry Pi hardware groups (gpio, i2c, spi, etc.)

**Proxmox**:
- Uses Packer Proxmox builder with kickstart-based installation
- Creates VM templates that can be cloned for deployment
- Requires environment variables for Proxmox API credentials

## Development Commands

Run `make help` for the full target list.

### Building Proxmox Templates

Preferred: the per-node Make targets. They read the API token from
`host_vars/<host>/vault.yml` in the Deevnet inventory (via
`ansible/playbooks/pve-env.yml`) and select that node's disk storage pool, so no
credentials are exported by hand.

```bash
make proxmox-fedora-pve2                      # Fedora 44 on node pve2 (hv02)
make proxmox-fedora-pve1 FEDORA_RELEASE=43    # Fedora 43 on node pve  (hv01)

eval "$(make -s pve2-env)"                    # or export into the shell
make pve-env-clean                            # remove the rendered file after
```

Direct packer invocation still works if `TF_VAR_proxmox_*` are exported.

### File Format

**Always use HCL format for Packer configurations** (`.pkr.hcl` extension). JSON format is not used in this repository.

## Configuration Variables

### Common Variables (`packer/common/variables.pkrvars.hcl`)

- `automation_user`: Username for automation (default: `a_autoprov`)
- `ssh_pubkey_url`: URL to SSH public key
- `artifact_server_url`: Base URL for artifact server

### Proxmox Variables

`TF_VAR_proxmox_url`, `TF_VAR_proxmox_token_id`, `TF_VAR_proxmox_token_secret`,
and `TF_VAR_proxmox_node` are environment variables. These are normally rendered
from the inventory vault by `make pve1-env` / `make pve2-env` rather than set by
hand. Node map: `pve` = hv01 (10.20.99.21), `pve2` = hv02 (10.20.99.22).

## Prerequisites

**For all builds**:
- HashiCorp Packer installed
- Local artifact server hosting base images and SSH keys (or override variables)

**For Raspberry Pi builds**:
- `qemu-aarch64-static` binary available at `/usr/bin/qemu-aarch64-static`
- Packer ARM plugin (auto-installed via `packer init`)

**For Proxmox builds**:
- Access to Proxmox VE infrastructure
- API token with appropriate permissions
- Fedora Server ISO uploaded to Proxmox storage
