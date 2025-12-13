# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository builds customized OS images for various platforms using HashiCorp Packer. Images are created for Raspberry Pi (ARM-based) and Proxmox virtual machines. The primary purpose is to create base images with an automation user (`a_autoprov`) configured for passwordless SSH and sudo access, enabling downstream Ansible automation.

## Repository Structure

```
packer/
├── common/             # Shared variables and configuration
├── proxmox/            # Proxmox VM template builds (Fedora)
├── pi/                 # Raspberry Pi image builds
└── builder/            # Builder node image (self-hosting)

iso/
└── fedora/             # Fedora kickstart configuration

ansible/
├── playbooks/          # Ansible playbooks for provisioning
└── inventories/        # Inventory files

docs/                   # Project documentation
spec/                   # Requirements and specifications
```

## Architecture

### Image Build Hierarchy

The repository uses a platform-organized architecture:

1. **Proxmox Templates** (`packer/proxmox/`): VM templates for Proxmox VE
2. **Raspberry Pi Images** (`packer/pi/`): ARM64 images for Raspberry Pi devices
3. **Builder Node** (`packer/builder/`): Self-hosting build infrastructure image
4. **ISO Builds** (`iso/`): Bootable ISOs with kickstart/autoinstall

### Image Building Pipeline

1. **Base Image Sourcing**: Downloads official OS images from local nginx artifact server or remote sources
2. **Base Provisioning**: Creates automation user and configures fundamental access/permissions
3. **Output**: Platform-specific artifacts (`.img` files for Raspberry Pi, VM templates for Proxmox)

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

### Building Raspberry Pi Images

```bash
cd packer/pi
packer init sdr-bookworm.pkr.hcl
packer validate sdr-bookworm.pkr.hcl
packer build sdr-bookworm.pkr.hcl

# With custom variables
packer build \
  -var "base_image_url=http://your-server/path/to/image.img.xz" \
  -var "ssh_pubkey_url=http://your-server/path/to/key.pub" \
  sdr-bookworm.pkr.hcl
```

### Building Proxmox Templates

```bash
# Set required environment variables
export TF_VAR_proxmox_url="https://proxmox.example.com:8006/api2/json"
export TF_VAR_proxmox_token_id="user@pam!tokenname"
export TF_VAR_proxmox_token_secret="your-token-secret"
export TF_VAR_proxmox_node="pve"

cd packer/proxmox
packer init fedora-43.pkr.hcl
packer validate fedora-43.pkr.hcl
packer build fedora-43.pkr.hcl
```

### File Format

**Always use HCL format for Packer configurations** (`.pkr.hcl` extension). JSON format is not used in this repository.

## Configuration Variables

### Common Variables (`packer/common/variables.pkrvars.hcl`)

- `automation_user`: Username for automation (default: `a_autoprov`)
- `ssh_pubkey_url`: URL to SSH public key
- `artifact_server_url`: Base URL for artifact server

### Proxmox Variables

- `TF_VAR_proxmox_url`: Proxmox API URL (environment variable)
- `TF_VAR_proxmox_token_id`: API token ID (environment variable)
- `TF_VAR_proxmox_token_secret`: API token secret (environment variable)
- `TF_VAR_proxmox_node`: Target Proxmox node (environment variable)

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

## Output Artifacts

Build outputs vary by platform:
- **Raspberry Pi**: `.img` files ready to flash to SD cards, plus manifest JSON
- **Proxmox**: VM templates stored directly in Proxmox, plus manifest JSON
