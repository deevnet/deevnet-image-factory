# Proxmox VM Template

Builds a Fedora Server VM template in Proxmox using kickstart. The template can be cloned to create new VMs.

The release is selected with `FEDORA_RELEASE`, which picks the matching
`fedora-<release>.pkrvars.hcl`. Keep it in sync with `deevnet_fedora_current`
in the Deevnet inventory.

## Build

The `proxmox-fedora-pve1` / `proxmox-fedora-pve2` targets read the API token
out of `host_vars/<host>/vault.yml` in the Deevnet inventory, so nothing has to
be exported by hand. They also select the right disk storage pool for that node.

```bash
make proxmox-fedora-pve2                      # Fedora 44 on node pve2 (hv02)
make proxmox-fedora-pve1 FEDORA_RELEASE=43    # Fedora 43 on node pve  (hv01)
```

To use the credentials elsewhere (or with the plain `proxmox-fedora` target),
export them into the current shell:

```bash
eval "$(make -s pve2-env)"
make proxmox-fedora
make pve-env-clean          # remove the rendered credential file when done
```

Both require the ansible-vault password - set `ANSIBLE_VAULT_PASSWORD_FILE`
or answer the prompt.

## Manual credentials

The plain `make proxmox-fedora` target uses whatever is already exported:

```bash
export TF_VAR_proxmox_url="https://proxmox:8006/api2/json"
export TF_VAR_proxmox_token_id="user@pam!token"
export TF_VAR_proxmox_token_secret="secret"
export TF_VAR_proxmox_node="pve"
make proxmox-fedora
```

## What's Included

- Automation user (`a_autoprov`) with SSH key and passwordless sudo
- Minimal Fedora Server installation
- Cloud-init: **not yet** — no cloud-init drive on the template and the package is not
  installed. Clones boot as `fedora-template` and take a DHCP lease via NetworkManager.
  Tracked as part of the tenant fabric work.

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

- `packer/proxmox/fedora-base-image/fedora.pkr.hcl` - Packer template definition
- `packer/proxmox/fedora-base-image/fedora-*.pkrvars.hcl` - per-release variables
- `ansible/playbooks/pve-env.yml` - renders vault credentials into TF_VAR_proxmox_*
- `packer/proxmox/fedora-base-image/http/kickstart.cfg` - Kickstart configuration
