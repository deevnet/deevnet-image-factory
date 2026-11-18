# Take-Home Installer ISO Build

This document covers building the `iso-backend` ISO (CHG-0075): an installer that writes the
take-home backend of [`vm-backend`](vm-backend.md) to a disk of an owner's own amd64 computer.

## Overview

The ISO carries the VM's disk, compressed, and writes it as it is. The installed system is the VM,
so everything in [vm-backend.md](vm-backend.md) about the first boot holds: `deevnet-kit setup` asks
on the console, and `deevnet-kit-growroot` grows the root to fill the disk. This page covers only
the installer.

Nothing on the ISO is downloaded or built a second time. Its boot files all come from the VM's
disk:

| On the ISO | From the VM's disk |
|---|---|
| `/live/vmlinuz` | the VM's kernel, Debian's generic `linux-image-amd64` |
| `/live/initrd.img` | made by the VM's `initramfs-tools` with this repository's installer (`mkinitramfs -d scripts/iso-installer/initramfs`) |
| `/boot/grub/i386-pc/` | GRUB for BIOS (`grub-pc-bin`): an El Torito image made by `grub-mkimage`, and the modules |
| The EFI system partition (appended, and copied to `/EFI/BOOT`) | Debian's signed shim as `BOOTX64.EFI`, and Debian's signed GRUB for CDs (`gcdx64.efi.signed`) as `grubx64.efi` |
| `/deevnet/system.img.zst` | the VM's raw disk, zstd-compressed, with its sha256 and size beside it |

Debian's CD GRUB finds the ISO by `/.disk/info` and reads `/boot/grub/grub.cfg`, the same menu
GRUB for BIOS reads. The ISO is hybrid: El Torito for optical drives and an MBR and GPT for a USB
stick, under BIOS and UEFI.

The VM's disk is mounted read-only under an overlay that is thrown away, so making the boot files
changes nothing in the VM's image.

## The Installer

GRUB starts the kernel with `boot=deevnet-install`. initramfs-tools then runs the installer
(`scripts/iso-installer/initramfs/deevnet-install`) where it would mount a root file system. The
installer:

1. finds its own medium by the volume label `DEEVNET_TAKEHOME`, and the disk that medium is on;
2. lists the whole disks big enough for the image, without that disk, optical drives, loop or RAM
   disks;
3. asks the owner to type a listed disk's name, shows what is on it, and asks for the name again;
4. writes the image to the disk and reads it back, comparing the sha256 with the one on the ISO;
5. moves GPT's backup header to the disk's end, then asks for the stick to be removed and reboots.

Anything else typed goes back to the list. `shell` gives a shell, and `off` powers off. If a step
fails, the installer says why and offers a shell or power off. Its tools (`lsblk`, `blkid`,
`sfdisk`, `zstd`, GNU `dd` and others) are copied from the VM's disk into the initramfs, under
`/usr/lib/deevnet-installer/bin`, because klibc's smaller `dd` and `mount` hold the usual paths.

The installed system has no Wi-Fi, so the owner connects it wired.

## Build Process

```bash
# The VM's disk first: the ISO is made from build/vm-backend/*.raw
make vm-backend

# Boot files -> payload -> ISO
make iso-backend

# Into the tenant downloads tree; then push it to the observability store
make iso-backend-publish
```

| Step | What it does |
|---|---|
| `iso-backend-boot` | The VM's root mounted read-only under an overlay; the installer initramfs, GRUB's El Torito image and the EFI system partition image made from it |
| `iso-backend-payload` | The VM's raw disk zstd-compressed, with its sha256 and size; remade only when the raw disk is newer |
| `iso-backend-image` | `xorriso` writes the hybrid ISO and its sha256 |

## Secure Boot

The ISO boots through Debian's signed shim and GRUB, and the installed system boots through the
same, so both may boot with Secure Boot on. Until that is proven, the tenant guide says to turn
Secure Boot off.
