# packer/proxmox

Packer configurations for Proxmox VM templates.

## Files

- `fedora-43.pkr.hcl` - Fedora Server 43 base template

## Usage

```bash
packer init fedora-43.pkr.hcl
packer build fedora-43.pkr.hcl
```

## Required Environment Variables

- `TF_VAR_proxmox_url` - Proxmox API URL
- `TF_VAR_proxmox_token_id` - API token ID
- `TF_VAR_proxmox_token_secret` - API token secret
- `TF_VAR_proxmox_node` - Target Proxmox node
