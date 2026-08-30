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

# --- Fedora Release ---
# Bumping a release is a two-line change here (or pass a *.pkrvars.hcl file).
# Keep these in sync with deevnet_fedora_current in the Deevnet inventory
# (ansible-inventory-deevnet/dvntm/group_vars/all/main.yml).
variable "fedora_release" {
  type    = string
  default = "44"
}

variable "fedora_build" {
  type    = string
  default = "1.7"
}

# SHA256 of the DVD ISO. Only consulted when iso_download_pve = true; a local:iso
# file is trusted as-is, matching the previous behaviour.
variable "iso_sha256" {
  type    = string
  default = "85837793bfa36db6bc709b4cecd2ec116951b87d9c53c3d95eb2fac8dcf7cf1f"
}

# --- ISO sourcing ---
# false (default): use an ISO already present in Proxmox storage at local:iso/.
# true:            have Proxmox download it from the Deevnet artifact server,
#                  which publishes it via the artifacts role. Removes the manual
#                  hand-copy step, at the cost of requiring the artifact server
#                  to be reachable from the Proxmox node.
variable "iso_download_pve" {
  type    = bool
  default = false
}

variable "artifact_server_url" {
  type    = string
  default = "http://artifacts.dvntm.deevnet.net"
}

variable "iso_storage_pool" {
  type    = string
  default = "local"
}

# --- Infrastructure Variables ---
variable "storage_pool" {
  type    = string
  default = "local-lvm-big-thin"
}

variable "bridge_name" {
  type    = string
  default = "vmbr0"
}

locals {
  version_tag = "${var.fedora_release}-${var.fedora_build}"
  iso_name    = "Fedora-Server-dvd-x86_64-${local.version_tag}.iso"
  iso_url     = "${var.artifact_server_url}/fedora/${var.fedora_release}/iso/${local.iso_name}"
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
  # When iso_download_pve is true Proxmox fetches the ISO from the artifact
  # server and the checksum is enforced; otherwise the pre-staged local:iso
  # file is used and trusted, as before.
  boot_iso {
    type             = "ide"
    iso_file         = var.iso_download_pve ? null : "${var.iso_storage_pool}:iso/${local.iso_name}"
    iso_url          = var.iso_download_pve ? local.iso_url : null
    iso_checksum     = var.iso_download_pve ? "sha256:${var.iso_sha256}" : "none"
    iso_storage_pool = var.iso_download_pve ? var.iso_storage_pool : null
    iso_download_pve = var.iso_download_pve
    unmount          = true
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
  memory   = 4096
  cores    = 4
  sockets  = 1
  cpu_type = "host"

  # SSH configuration (user created by kickstart)
  ssh_timeout    = "60m"
  ssh_username   = "a_autoprov"
  ssh_agent_auth = true

  # Template configuration
  qemu_agent           = true
  template_description = "Fedora Server ${local.version_tag}, generated on ${timestamp()}"
  template_name        = "fedora-server-${local.version_tag}"
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
    output = "fedora-${var.fedora_release}-manifest.json"
  }
}
