packer {
  # ARM plugin provided by mkaczanowski/packer-builder-arm container
  # No required_plugins needed when using Docker-based build
}

# Path to the SSH pubkey that Makefile downloads from artifacts.dvntm.deevnet.net.
# This must exist BEFORE packer starts (because the 'file' provisioner is prepared up-front).
variable "ssh_pubkey_local_path" {
  type    = string
  default = "/build/build/keys/a_autoprov_rsa.pub"
}

source "arm" "raspios_bookworm_autoprov" {
  # Base image in zip archive (archiver supports zip, not standalone gz/xz)
  file_urls             = ["file:///build/packer/pi/raspios-bookworm-base.zip"]
  file_target_extension = "zip"
  file_checksum_type    = "none"

  image_build_method = "reuse"
  image_path         = "raspios-bookworm-autoprov.img"
  image_size         = "4G"
  image_type         = "dos"

  # Boot + root layout
  image_partitions {
    name         = "boot"
    type         = "c"
    start_sector = "8192"
    filesystem   = "vfat"
    size         = "256M"
    mountpoint   = "/boot"
  }
  image_partitions {
    name         = "root"
    type         = "83"
    start_sector = "532480"
    filesystem   = "ext4"
    size         = "0"
    mountpoint   = "/"
  }

  # Required for 64-bit ARM usermode emulation inside the chroot
  qemu_binary_source_path      = "/usr/bin/qemu-aarch64-static"
  qemu_binary_destination_path = "/usr/bin/qemu-aarch64-static"

  image_chroot_env = [
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  ]
}

build {
  name    = "raspios-bookworm-autoprov"
  sources = ["source.arm.raspios_bookworm_autoprov"]

  # --- Copy pubkey (downloaded by Makefile from artifacts) into the image ---
  provisioner "file" {
    source      = var.ssh_pubkey_local_path
    destination = "/tmp/a_autoprov_rsa.pub"
  }

  # --- Provision autoprov user (no network needed inside chroot) ---
  provisioner "shell" {
    inline = [
      "set -e",
      "if ! id a_autoprov >/dev/null 2>&1; then useradd -m -s /bin/bash -G sudo,audio,video,adm,dialout,plugdev,gpio,i2c,spi a_autoprov; fi",
      "mkdir -p /home/a_autoprov/.ssh",
      "cat /tmp/a_autoprov_rsa.pub > /home/a_autoprov/.ssh/authorized_keys",
      "chown -R a_autoprov:a_autoprov /home/a_autoprov/.ssh",
      "chmod 700 /home/a_autoprov/.ssh",
      "chmod 600 /home/a_autoprov/.ssh/authorized_keys",
      "echo 'a_autoprov ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/010_a_autoprov-nopasswd",
      "chmod 440 /etc/sudoers.d/010_a_autoprov-nopasswd",
      "apt-get update",
      "apt-get install -y python3 python3-apt"
    ]
  }

  # --- SDR provisioning (converted from ansible-local) ---
  provisioner "shell" {
    inline = [
      "set -e",
      "echo 'Creating packer-provisioned marker file...'",
      "cat > /etc/packer-provisioned << 'MARKER'",
      "Image: pi-sdr-bookworm",
      "Build Date: $(date -Iseconds)",
      "MARKER",
      "chmod 644 /etc/packer-provisioned",
      "echo 'SDR provisioning complete'"
    ]
  }

  post-processor "manifest" {
    output = "raspios-bookworm-autoprov-manifest.json"
  }
}
