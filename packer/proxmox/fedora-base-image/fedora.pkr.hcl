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
# (ansible-inventory-deevnet/mobile/group_vars/all/main.yml).
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

# --- Build-time networking ---------------------------------------------------
# The installer needs an address before it can fetch the kickstart, and the
# installed system needs one for Packer's SSH provisioner. Using DHCP for that
# couples image builds to a healthy DHCP pool: if the pool is down or full, the
# build boots, waits, and fails ~30 minutes later in dracut with an error that
# points at inst.stage2 rather than at the network.
#
# A pinned address removes that coupling - a build either works or fails for
# reasons inside the build. It is transient: the generalize step at the end of
# the build removes the NetworkManager connection along with machine-id and the
# host keys, so clones of the template do NOT inherit this address. They are
# addressed by cloud-init from the tenant fabric instead.
#
# 10.20.99.79 sits in the .70-.79 experimental/lab range of the mobile
# addressing plan, outside the .200-.230 DHCP pool and outside the .2-.49
# static infrastructure range.
variable "build_use_dhcp" {
  type        = bool
  description = "Address the build VM by DHCP instead of the pinned address."
  default     = false
}

variable "build_ip" {
  type    = string
  default = "10.20.99.79"
}

variable "build_netmask" {
  type    = string
  default = "255.255.255.0"
}

variable "build_gateway" {
  type    = string
  default = "10.20.99.1"
}

variable "build_nameserver" {
  type    = string
  default = "10.20.99.1"
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
  default = "http://artifacts.mobile.deevnet.net"
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

# The template carries an OS disk and nothing else. It is deliberately small:
# sized for an operating system and its packages, not for a workload. A clone
# that needs more grows this disk on first boot - cloud-init's growpart/resizefs
# handle that unaided, which is why the kickstart partitions plain rather than
# LVM - and bulk capacity belongs on a separate data disk attached by whatever
# creates the VM. Sizing the template for the largest imaginable workload makes
# every clone slower to copy, migrate and back up, and cannot be undone: Proxmox
# grows a disk but never shrinks one.
variable "os_disk_size" {
  type        = string
  description = "Size of the template's OS disk. Clones grow it via cloud-init; bulk capacity belongs on a separate data disk."
  default     = "32G"
}

variable "bridge_name" {
  type    = string
  default = "vmbr0"
}

locals {
  # dracut ip= syntax: client:server:gateway:netmask:hostname:interface:autoconf
  # The interface field is deliberately empty - there is exactly one NIC on the
  # build VM and its kernel name varies with the machine type, so naming it
  # would be a guess that fails silently.
  boot_ip = var.build_use_dhcp ? "ip=dhcp" : "ip=${var.build_ip}::${var.build_gateway}:${var.build_netmask}:packer-build::none"

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
    "linux (cd)/images/pxeboot/vmlinuz ${local.boot_ip} rd.neednet=1 inst.stage2=cdrom inst.repo=cdrom inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/kickstart.cfg<enter><wait5>",
    "initrd (cd)/images/pxeboot/initrd.img<enter><wait15>",
    "boot<enter>"
  ]
  boot_wait = "10s"

  # Disk configuration
  disks {
    disk_size    = var.os_disk_size
    storage_pool = var.storage_pool
    type         = "scsi"
  }

  # HTTP server for kickstart file (templated for {{ .HTTPIP }} substitution)
  http_content = {
    "/kickstart.cfg" = templatefile("${path.root}/http/kickstart.cfg.pkrtpl", {
      use_dhcp   = var.build_use_dhcp
      ip         = var.build_ip
      netmask    = var.build_netmask
      gateway    = var.build_gateway
      nameserver = var.build_nameserver
    })
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

  # Cloud-init drive. This is what lets a clone be told its hostname, SSH key
  # and addressing at creation time - without it every clone boots as
  # "fedora-template" and there is no way to seed per-VM identity.
  cloud_init              = true
  cloud_init_storage_pool = var.storage_pool

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
      # cloud-init is here rather than in the kickstart because it is not on
      # the Fedora Server DVD, and %packages runs with --ignoremissing -
      # listing it there fails silently and ships a template that cannot name
      # or address its own clones.
      "sudo dnf -y install podman python3-libdnf5 cloud-init cloud-utils-growpart",

      # Fail loudly if that did not take, rather than discovering it when a
      # clone boots as 'fedora-template' with no address.
      "rpm -q cloud-init cloud-utils-growpart",
      # Unit names are not stable across cloud-init versions: 24.3 renamed
      # cloud-init.service to cloud-init-network.service, so a fixed list
      # breaks on upgrade - which is how this was found. Enable whichever of
      # the known units this version actually ships.
      "for u in cloud-init-local cloud-init-network cloud-init cloud-config cloud-final; do systemctl cat $u.service >/dev/null 2>&1 && sudo systemctl enable $u.service || true; done",
      "sudo systemctl enable cloud-init.target",

      # cloud-init-local exists in every version and runs first; if it is not
      # enabled, nothing else will run either.
      "systemctl is-enabled cloud-init-local.service",

      # Prepare Ansible remote_tmp directory
      "sudo mkdir -p /tmp/.ansible-root",
      "sudo chmod 0700 /tmp/.ansible-root",
      "sudo chown root:root /tmp/.ansible-root"
    ]
  }

  # Must be last. Anything identifying left on disk is inherited by every
  # clone: a shared machine-id breaks DHCP (systemd sends it as the client
  # identifier, so clones collide on one lease) and shared host keys mean every
  # tenant VM presents the same SSH identity.
  provisioner "shell" {
    inline = [
      "sudo cloud-init clean --logs --seed || true",

      # Empty, not missing - systemd generates a fresh ID at boot for an empty
      # file, but a missing one is a first-boot error on some images.
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id",

      # NetworkManager's per-install unique ID and cached connections.
      "sudo rm -f /var/lib/NetworkManager/secret_key /var/lib/NetworkManager/seen-bssids",
      "sudo rm -f /etc/NetworkManager/system-connections/*.nmconnection",

      # Regenerated on first boot by sshd.
      "sudo rm -f /etc/ssh/ssh_host_*key*",

      "sudo rm -rf /var/lib/cloud/instances /var/lib/cloud/instance",
      "sudo sh -c 'rm -f /root/.bash_history /home/a_autoprov/.bash_history' || true"
    ]
  }

  post-processor "manifest" {
    output = "fedora-${var.fedora_release}-manifest.json"
  }
}
