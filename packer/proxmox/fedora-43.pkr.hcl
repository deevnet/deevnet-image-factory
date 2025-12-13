packer {
  required_plugins {
    proxmox = {
      version = "~> 1"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

# --- Proxmox Connection Variables ---
variable "proxmox_url" {
  type    = string
  default = env("TF_VAR_proxmox_url")
}

variable "proxmox_token_id" {
  type    = string
  default = env("TF_VAR_proxmox_token_id")
}

variable "proxmox_token_secret" {
  type      = string
  sensitive = true
  default   = env("TF_VAR_proxmox_token_secret")
}

variable "proxmox_node" {
  type    = string
  default = env("TF_VAR_proxmox_node")
}

# --- Infrastructure Variables ---
variable "iso_file" {
  type    = string
  default = "local:iso/Fedora-Server-dvd-x86_64-43-1.6.iso"
}

variable "storage_pool" {
  type    = string
  default = "local-lvm-big-thin"
}

variable "bridge_name" {
  type    = string
  default = "vmbr0"
}

# --- Automation Variables ---
variable "ssh_pubkey_url" {
  type    = string
  default = "http://localhost/keys/ssh/a_autoprov_rsa.pub"
}

source "proxmox-iso" "fedora-kickstart" {
  # Boot sequence for Fedora kickstart installation
  boot_command = [
    "<wait5>",
    "c<wait>",
    "<enter><wait>",
    "linux (cd)/images/pxeboot/vmlinuz inst.stage2=hd:LABEL=Fedora-S-dvd-x86_64-43 ip=dhcp inst.cmdline inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/kickstart.cfg<enter><wait5>",
    "initrd (cd)/images/pxeboot/initrd.img<enter><wait15>",
    "boot<enter>"
  ]
  boot_wait = "10s"

  # Disk configuration
  disks {
    disk_size    = "64G"
    storage_pool = var.storage_pool
    type         = "scsi"
  }

  # HTTP server for kickstart file
  http_directory = "../../../iso/fedora"

  # ISO configuration
  insecure_skip_tls_verify = true
  iso_file                 = var.iso_file
  iso_checksum             = "none"

  # Network configuration
  network_adapters {
    bridge = var.bridge_name
    model  = "virtio"
  }

  # Proxmox connection
  proxmox_url = var.proxmox_url
  username    = var.proxmox_token_id
  token       = var.proxmox_token_secret
  node        = var.proxmox_node

  # VM resources
  memory  = 4096
  cores   = 2
  sockets = 2

  # SSH configuration (user created by kickstart)
  ssh_timeout    = "60m"
  ssh_username   = "a_autoprov"
  ssh_agent_auth = true

  # Template configuration
  qemu_agent           = true
  template_description = "Fedora Server 43-1.6, generated on ${timestamp()}"
  template_name        = "fedora-server-43-1.6"
  unmount_iso          = true
}

build {
  sources = ["source.proxmox-iso.fedora-kickstart"]

  # Post-installation provisioning
  provisioner "shell" {
    inline = [
      "sudo dnf -y install podman python3-libdnf5",

      # Prepare Ansible remote_tmp directory
      "sudo mkdir -p /tmp/.ansible-root",
      "sudo chmod 0700 /tmp/.ansible-root",
      "sudo chown root:root /tmp/.ansible-root"
    ]
  }

  post-processor "manifest" {
    output = "fedora-43-manifest.json"
  }
}
