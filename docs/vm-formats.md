# Take-Home VM for VirtualBox and Hyper-V

This document covers `make vm-formats` (CHG-0076): the take-home backend of
[`vm-backend`](vm-backend.md) in the formats a Windows computer runs, an OVA for VirtualBox and a
VHDX for a Hyper-V Generation 2 machine.

## Overview

Both formats carry the VM's raw disk unchanged, so everything in [vm-backend.md](vm-backend.md)
about the first boot holds: `deevnet-kit setup` asks on the console, and `deevnet-kit-growroot`
grows the root to fill the disk. Nothing is built a second time. The target converts the disk,
compares each conversion with it (`qemu-img compare`), and only then packs it.

| File | What it holds |
|---|---|
| `debian-bookworm-mobile-vm-backend.ova` | an OVF 1.0 descriptor, a manifest of sha256s, and the disk as a stream-optimized VMDK, in that order, in a ustar archive |
| `debian-bookworm-mobile-vm-backend.vhdx.zip` | the disk as a dynamic VHDX, zipped: Windows opens a zip itself, and the VHDX alone is 4.5 GB |

Each has its sha256 beside it.

## The OVA

`scripts/vm-formats/ova.py build` writes the descriptor and the manifest and packs the OVA;
`ova.py check` reads it back: the order of its files, the manifest against each file, and the
descriptor's file reference and size against the disk it carries.

The descriptor is OVF 1.0, as VirtualBox exports it, and names:

- a 64-bit Debian machine (`Debian_64`) with 2 CPUs and 2 GB of memory;
- the disk on a SATA (AHCI) controller, with the raw disk's capacity;
- one Intel PRO/1000 adapter (`E1000`) connected `Bridged`. VirtualBox makes it a bridged adapter
  and the owner picks the computer's interface;
- no firmware, so VirtualBox boots it by BIOS, its default. The disk boots by UEFI too.

## The VHDX

A dynamic VHDX, for a Generation 2 machine, which boots by UEFI. Hyper-V's default Secure Boot
template, "Microsoft Windows", refuses Debian's shim. The machine needs the "Microsoft UEFI
Certificate Authority" template, or Secure Boot off.

The kernel is Debian's generic one and the initramfs has `MODULES=most`, so Hyper-V's storage and
network drivers (`hv_storvsc`, `hv_netvsc`) are in it, as AHCI and `e1000` are for VirtualBox. The
network configuration matches any Ethernet device.

## Proof

Both formats are proven under qemu on the Builder, in the firmware their hypervisor gives them:
the OVA's disk under SeaBIOS, the VHDX under OVMF with Secure Boot on. The devices are qemu's, not
VirtualBox's or Hyper-V's; a run on a real host is still to come.

## Publish

`make vm-formats-publish` installs both, with their sha256s, beside the qcow2 under `tenant/vm` on
the artifact server. Push them to the observability store throttled, as the qcow2 was: the core
router has hung under an unthrottled transfer.
