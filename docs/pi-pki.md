# Pi CA Ceremony Image Build

This document covers building `pi-pki`: the offline machine for the Deevnet CA ceremonies, on a
Raspberry Pi 4. The ceremonies themselves are in the deevnet-docs runbook, **Root of Trust**.

## What it is

A Raspberry Pi OS Lite (Bookworm, arm64) system that never joins a network, and carries the
ceremony's signing tool so that the transfer media carries data only.

| | |
|---|---|
| Radios | Wi-Fi and Bluetooth off in firmware (`dtoverlay=disable-wifi`, `disable-bt`) |
| Network | NetworkManager, wpa_supplicant, ModemManager, avahi, bluetooth and timesyncd masked |
| Remote access | `openssh-server` purged; `ssh` and `sshswitch` masked |
| Users | the stock `pi` user removed; one user, `pki`, with no password, logged in on the console (tty1) only, `sudo` for mounting media and setting the clock; `root` locked |
| Persistence | the root is a RAM overlay (`overlayroot=tmpfs`), and the boot partition is mounted read-only: nothing a ceremony does survives a reboot |
| Clock | no `fake-hwclock`: a Pi 4 has no battery clock, so the date is obviously wrong until it is set, and `deevnet-pki-sign` refuses a date before the image's build date |
| Tools | `/usr/local/bin/deevnet-pki-sign` and `/usr/local/share/deevnet-pki/deevnet-pki.cnf`, from `ansible-collection-deevnet.mgmt/scripts/pki` at build |
| Identity | `/etc/deevnet-pki-release`: image name, build date, tools commit |

**What it is not.** It holds no key and no certificate. The Root CA's and Site CAs' keys live on
their own key media, which are only ever plugged into this machine, and the microSD can be
re-flashed at any time.

## Why it is not built like the other Pi images

`pi-sdr`, `pi-pidp11` and `pi-backend` start from the Packer step (`pi-bookworm-image`), which adds
the automation user `a_autoprov` and its SSH key. `pi-pki` starts from the **stock** Lite image and
never has that account, so there is nothing to remove and nothing to forget to remove.

## Build

```bash
make pi-pki            # stock image -> 4G -> offline Ansible (pi-pki-config.yml) -> .img.xz + .sha256
make pi-pki-publish    # to the artifact server: pi-images/pki/ (sudo)
```

The build needs the Pi package repositories once, for `overlayroot`; the image itself never has a
network. `raspi-config`'s overlay switch reads the running kernel, which in a chroot is the build
host's, so the playbook rebuilds the initramfs for the image's own kernels and sets
`overlayroot=tmpfs` on the kernel command line itself.

## Use

1. Check the published `.sha256` and write it on the ceremony's paper record.
2. Flash it to a microSD (Raspberry Pi Imager, or `xzcat … | sudo dd of=/dev/sdX bs=4M`). Do not
   let Imager apply any customization (Wi-Fi, SSH, user): the image needs none.
3. Boot the Pi 4 with an HDMI display and a USB keyboard, and no network cable.
4. Follow the runbook. The login banner lists the steps.

## Checks on a real Pi 4

The build can only inspect the image. On the hardware, once:

- it boots to the `pki` user on the console;
- `ip -brief address` shows only `lo`, and `rfkill list` shows no Wi-Fi or Bluetooth;
- `date` is wrong until set with `sudo date -u -s`;
- `findmnt /` shows the overlay, and a file written under `/home/pki` is gone after a reboot;
- a throwaway ceremony (Root CA, Site CA, then an issuing CA through the transfer media) runs end to
  end.
