# Proxmox VM Template

Builds a Fedora Server 43 VM template in Proxmox using kickstart. The template can be cloned to create new VMs.

## Build

```bash
# Set credentials
export TF_VAR_proxmox_url="https://proxmox:8006/api2/json"
export TF_VAR_proxmox_token_id="user@pam!token"
export TF_VAR_proxmox_token_secret="secret"
export TF_VAR_proxmox_node="pve"

# Build template
make proxmox-fedora
```

## What's Included

- Automation user (`a_autoprov`) with SSH key and passwordless sudo
- Minimal Fedora Server installation
- Cloud-init ready

## Required Environment Variables

| Variable | Description |
|----------|-------------|
| `TF_VAR_proxmox_url` | Proxmox API URL |
| `TF_VAR_proxmox_token_id` | API token ID |
| `TF_VAR_proxmox_token_secret` | API token secret |
| `TF_VAR_proxmox_node` | Target Proxmox node |

## Output

Template is stored directly in Proxmox (not as a local file).

## Related Files

- `packer/proxmox/fedora-base-image/fedora-43.pkr.hcl` - Packer template definition
- `packer/proxmox/fedora-base-image/http/kickstart.cfg` - Kickstart configuration
