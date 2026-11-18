# Take-Home VM Backend Image Build

This document covers building the `vm-backend` image (CHG-0074): the take-home backend of
[`pi-backend`](pi-backend.md) as an **amd64 virtual machine** (qcow2) for Proxmox and KVM.

## Overview

The VM runs exactly what the Pi image runs, with the same app contract, `deevnet-kit` and
self-test. It is built by the same play, `ansible/playbooks/pi-backend-config.yml`, with
`medium=vm`. Everything in [pi-backend.md](pi-backend.md) about the services, the self-test and the
known differences from Deevnet holds here. This page covers only what differs.

| | Pi | VM |
|---|---|---|
| Base image | Raspberry Pi OS Lite, through the shared Packer step | Debian 12 `nocloud`, dated build, pinned by SHA512 |
| Architecture | arm64 | amd64 |
| Owner's settings | `deevnet-kit.txt` on the boot partition | `deevnet-kit setup` on the console (tty1), written to `/etc/deevnet-kit/deevnet-kit.txt` |
| Owner's login | `userconf.txt` and `ssh` on the boot partition | `deevnet-kit setup`: a user in `sudo`, a password, and an optional SSH key that makes SSH key-only |
| Network | Raspberry Pi OS's NetworkManager; Wi-Fi from `deevnet-kit.txt` | `systemd-networkd`, DHCP on any Ethernet adapter with the MAC as client ID; bridged only |
| Disk | 8G card image, grown by Raspberry Pi OS | 16G sparse disk; `deevnet-kit-growroot` grows the root to fill a bigger disk on every boot |
| Clock | `fake-hwclock`, seeded with the build's time | the hypervisor's |
| What the base leaves open | `a_autoprov`, from the Packer step: removed | root signs in with no password: locked, and the build fails if not |

## Inputs

The same pinned versions as the Pi, for amd64 (`PI_BACKEND_*_amd64` in the Makefile):

- `deevnet-kit` and `deevnet-log-user`, staged by `make stage-vm` in `deevnet-provisioning-api`;
- the log bridge, staged by `make stage-pi PI_ARCH=amd64` in `deevnet-log-bridge` at the commit the
  Pi pins;
- silo, the static binary from the amd64 image Deevnet runs (`container-images/silo`), which the
  same build stage made from the same release;
- VictoriaLogs, vmutils, the metrics cluster, Alertmanager, ntfy and Grafana: the upstream amd64
  releases, staged once by `make vm-backend-stage-upstream` with the release's own checksums;
- Debian's `nocloud` image, staged by the same target under `vm-images/debian/`.

Downloads across the core router are throttled: `curl --limit-rate $(UPSTREAM_RATE)` for the
releases, and apt's `Acquire::http::Dl-Limit` (`APT_DL_LIMIT`, KB/s) for the packages the play
installs.

## Build Process

```bash
# Once per version bump, on the Builder
make vm-backend-stage-upstream

# Full pipeline: inputs -> base disk -> config -> qcow2
make vm-backend

# Into the tenant downloads tree; then push it to the observability store
make vm-backend-publish
```

| Step | What it does |
|---|---|
| `vm-backend-inputs` | The amd64 binaries and releases into `build/vm-backend-inputs/`, each checked |
| `vm-backend-base` | Debian's qcow2 as a raw disk of `VM_BACKEND_DISK_SIZE`, the GPT backup header moved and the root partition grown |
| `vm-backend-config` | The raw disk's root mounted, the build host's `resolv.conf` lent for apt (Debian's points into `/run`), and the play run with `medium=vm` |
| `vm-backend-compress` | A compressed qcow2 and its sha256 |

## First Boot

1. `deevnet-kit-growroot` grows the root file system to fill the disk.
2. `deevnet-kit-setup` asks on tty1 for the tenant, index, host name and the owner's login, and
   writes `/etc/deevnet-kit/deevnet-kit.txt` last. The console's login prompt waits for it.
3. `deevnet-kit-firstboot` requires setup, then runs `deevnet-kit init --config
   /etc/deevnet-kit/deevnet-kit.txt`, as on a Pi. If setup fails, first boot doesn't run, and the
   next boot asks again.

From there the VM is a Pi: the same services start, and the self-test runs on every boot.

The machine ID is empty in the image, so each VM makes its own on first boot, and two VMs from one
image don't share a DHCP or mDNS identity. The SSH host keys are made on first boot, as on the Pi.
