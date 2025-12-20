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

source "proxmox-iso" "fedora-kickstart" {

  # --- Packer HTTP server for Kickstart ---
  http_bind_address = "0.0.0.0"
  http_port_min     = 8487
  http_port_max     = 8487

  # Boot sequence for Fedora kickstart installation
  boot_command = [
    "<wait5>",
    "c<wait>",
    "<enter><wait>",
    "linux (cd)/images/pxeboot/vmlinuz ip=dhcp rd.neednet=1 inst.stage2=cdrom inst.repo=cdrom inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/kickstart.cfg<enter><wait5>",
    "initrd (cd)/images/pxeboot/initrd.img<enter><wait15>",
    "boot<enter>"
  ]
  boot_wait = "10s"

  # Disk configuration
  disks {
    disk_size    = "256G"
    storage_pool = var.storage_pool
    type         = "scsi"
  }

  # HTTP server for kickstart file (templated for {{ .HTTPIP }} substitution)
  http_content = {
    "/kickstart.cfg" = file("${path.root}/http/kickstart.cfg")
  }

  # Boot ISO configuration
  boot_iso {
    type         = "ide"
    iso_file     = var.iso_file
    iso_checksum = "none"
    unmount      = true
  }

  insecure_skip_tls_verify = true

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
  cores   = 4
  sockets = 1
  cpu_type = "host"

  # SSH configuration (user created by kickstart)
  ssh_timeout    = "60m"
  ssh_username   = "a_autoprov"
  ssh_agent_auth = true

  # Template configuration
  qemu_agent           = true
  template_description = "Fedora Server 43-1.6, generated on ${timestamp()}"
  template_name        = "fedora-server-43-1.6"
}

build {
  sources = ["source.proxmox-iso.fedora-kickstart"]

  # Post-installation provisioning
  provisioner "shell" {
    inline = [
      # Install additional packages
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
