packer {
  required_plugins {
    arm = {
      source  = "github.com/mkaczanowski/arm"
      version = ">= 1.0.0"
    }
  }
}

variable "base_image_url" {
  type    = string
  default = "http://localhost/pi-images/2025-11-24/2025-11-24-raspios-bookworm-arm64-lite.img.xz"
}

variable "ssh_pubkey_url" {
  type    = string
  default = "http://localhost/keys/ssh/a_autoprov_rsa.pub"
}

source "arm" "raspios_bookworm_autoprov" {
  # Raspberry Pi Bookworm 64-bit Lite image served by nginx artifacts
  file_urls             = [var.base_image_url]
  file_target_extension = "xz"

  image_build_method = "reuse"
  image_path         = "raspios-bookworm-autoprov.img"
  image_size         = "4G"
  image_type         = "dos"

  # Boot + root layout
  image_partitions = [
    {
      name         = "boot"
      type         = "c"
      start_sector = "8192"
      filesystem   = "vfat"
      size         = "256M"
      mountpoint   = "/boot"
    },
    {
      name         = "root"
      type         = "83"
      start_sector = "532480"
      filesystem   = "ext4"
      size         = "0"
      mountpoint   = "/"
    }
  ]

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

  # --- Provision autoprov user ---
  provisioner "shell" {
    inline = [
      "set -e",

      # Create user with sudo + Pi-friendly groups
      "if ! id a_autoprov >/dev/null 2>&1; then " +
        "useradd -m -s /bin/bash -G sudo,audio,video,adm,dialout,plugdev,gpio,i2c,spi a_autoprov; " +
      "fi",

      # Install the SSH public key
      "mkdir -p /home/a_autoprov/.ssh",
      "curl -fsSL \"${var.ssh_pubkey_url}\" > /home/a_autoprov/.ssh/authorized_keys",
      "chown -R a_autoprov:a_autoprov /home/a_autoprov/.ssh",
      "chmod 700 /home/a_autoprov/.ssh",
      "chmod 600 /home/a_autoprov/.ssh/authorized_keys",

      # Passwordless sudo for Ansible automation
      "echo 'a_autoprov ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/010_a_autoprov-nopasswd",
      "chmod 440 /etc/sudoers.d/010_a_autoprov-nopasswd"
    ]
  }

  post-processor "manifest" {
    output = "raspios-bookworm-autoprov-manifest.json"
  }
}
