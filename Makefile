# Deevnet Image Factory
# High-level orchestration for image builds
#
# NOTE: This Makefile does NOT attempt to install dependencies or modify
# system state. All prerequisites must be pre-installed on the builder node.

# ------------------------------------------------------------
# Shell behavior (critical for pipefail + traps + long recipes)
# ------------------------------------------------------------
SHELL := /usr/bin/bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

# ------------------------------------------------------------
# Build parameters
# ------------------------------------------------------------
# Fedora release used for Proxmox template builds. Selects the matching
# fedora-<release>.pkrvars.hcl. Keep in sync with deevnet_fedora_current in
# the Deevnet inventory.
#   make proxmox-fedora                    # current (44)
#   make proxmox-fedora FEDORA_RELEASE=43  # previous
FEDORA_RELEASE ?= 44

.DEFAULT_GOAL := help

# Terminal colors
RED    := \033[0;31m
GREEN  := \033[0;32m
YELLOW := \033[0;33m
NC     := \033[0m

# ------------------------------------------------------------
# Artifact source of truth
# ------------------------------------------------------------
ARTIFACT_URL := http://artifacts.mobile.deevnet.net

# ------------------------------------------------------------
# Proxmox API credentials (read from the Deevnet inventory vault)
# ------------------------------------------------------------
# The TF_VAR_proxmox_* variables Packer reads via env() are fetched per run by
# scripts/pve-creds and eval'd into the recipe's own environment. NOTHING IS
# WRITTEN TO DISK: the token lives in the build's process environment and
# nowhere else (Build-Time Secrets runbook). The two hypervisors are standalone
# nodes, each with its own API token:
#
#   pve1  ->  dv02hyp001p01  (10.20.99.21)
#   pve2  ->  dv02hyp002p02  (10.20.99.22)
#
# pve1/pve2 here are slot names for the first and second hypervisor, not node
# names: since ADR-0008 the node name is the inventory name (see PVE*_NODE).
#
#   eval "`make -s pve2-env`"     # export into the current shell
#   make proxmox-fedora-pve2      # or let the build target fetch them itself
#
# Source: the hypervisor's host_vars in the inventory vault, the authoritative
# copy. Builds do not read OpenBao, which is sealed outside work sessions
# (CHG-0037). Set ANSIBLE_VAULT_PASSWORD_FILE, or answer the prompt.
DEEVNET_INVENTORY ?= $(CURDIR)/../ansible-inventory-deevnet/mobile
PVE_CREDS         := $(CURDIR)/scripts/pve-creds
export DEEVNET_INVENTORY

# Inventory host -> Proxmox node name. These are now the same string on both
# hypervisors - the node was renamed to match its inventory name - but the pair
# is kept so a node that ever diverges again is one variable, not a code change.
PVE1_HOST ?= dv02hyp001p01
PVE1_NODE ?= dv02hyp001p01
PVE2_HOST ?= dv02hyp002p02
PVE2_NODE ?= dv02hyp002p02

# VM disk storage. The two nodes do NOT expose the same pools, so the Packer
# default (local-lvm-big-thin, which only exists on hyp001) is overridden per node.
# Both are lvmthin. The template's OS disk is 32G (see os_disk_size in
# fedora.pkr.hcl); clones grow it at first boot, and workload data belongs on a
# separate data disk, not on a bigger template.
#   dv02hyp001p01  local-lvm-big-thin  1100G
#   dv02hyp002p02  local-lvm            348G
PVE1_STORAGE_POOL ?= local-lvm-big-thin
PVE2_STORAGE_POOL ?= local-lvm

# Passed through to `packer build`, e.g. PACKER_EXTRA_ARGS='-var storage_pool=local-lvm'
PACKER_EXTRA_ARGS ?=

# Fetch one hypervisor's credentials into THIS recipe's environment.
# $(1) = inventory host, $(2) = node name. The recipes run in one shell
# (.ONESHELL), so the exports reach the packer command below them. The fetch is
# assigned first: under -e a failed fetch stops the recipe, where eval "$$(...)"
# would carry on to packer with no credentials.
define pve_creds
PVE_EXPORTS="$$($(PVE_CREDS) $(1) $(2))"
eval "$$PVE_EXPORTS"
endef

# ------------------------------------------------------------
# Raspberry Pi – Bookworm image pipeline
# ------------------------------------------------------------

# Image naming components
PI_IMAGE_PLATFORM := mobile
PI_IMAGE_VARIANT  := pi-sdr
PI_IMAGE_NAME     := raspios-bookworm-$(PI_IMAGE_PLATFORM)-$(PI_IMAGE_VARIANT)

# Base OS image (from artifacts)
PI_BOOKWORM_IMAGE_XZ_URL := $(ARTIFACT_URL)/pi-images/2025-11-24/2025-11-24-raspios-bookworm-arm64-lite.img.xz
PI_BOOKWORM_IMAGE_BASE   := $(CURDIR)/packer/pi/raspios-bookworm-base.img
PI_BOOKWORM_IMAGE_ZIP    := $(CURDIR)/packer/pi/raspios-bookworm-base.zip

# Output artifacts
PI_BOOKWORM_AUTOPROV_IMG      := $(CURDIR)/$(PI_IMAGE_NAME).img
PI_BOOKWORM_AUTOPROV_MANIFEST := $(CURDIR)/$(PI_IMAGE_NAME)-manifest.json

# SSH public key (source of truth = artifacts)
PI_BOOKWORM_SSH_PUBKEY_URL  := $(ARTIFACT_URL)/keys/ssh/a_autoprov_rsa.pub
PI_BOOKWORM_SSH_PUBKEY_FILE := $(CURDIR)/build/keys/a_autoprov_rsa.pub

# Offline mount point for image config
PI_BOOKWORM_MNT := /mnt/pi-bookworm-image

# Container image for ARM build
PI_PACKER_ARM_CONTAINER := docker.io/mkaczanowski/packer-builder-arm:latest

# ------------------------------------------------------------
# Proxmox VE ISO – Automated installer pipeline
# ------------------------------------------------------------

# Proxmox VE ISO source (from artifacts or override)
PVE_ISO_VERSION ?= 8.4-1
PVE_ISO_FILENAME := proxmox-ve_$(PVE_ISO_VERSION).iso
PVE_ISO_URL ?= $(ARTIFACT_URL)/isos/proxmox/$(PVE_ISO_FILENAME)
PVE_ISO_LOCAL := $(CURDIR)/packer/proxmox/pve-iso/$(PVE_ISO_FILENAME)

# Container for Proxmox ISO tooling
PVE_ISO_CONTAINER := localhost/pve-iso-builder:latest

# Build variables (can be overridden on command line)
#
# PVE_HOSTNAME is the installer's default and is deliberately generic - it is
# the Proxmox default that produced the "pve"/"pve2" node names ADR-0008 then
# had to undo. A node name is not safely renamable after the fact, so pass the
# real inventory name at build time: PVE_HOSTNAME=dv02hyp003p01.mobile.deevnet.net
PVE_HOSTNAME ?= pve.local
PVE_TIMEZONE ?= America/New_York
PVE_COUNTRY ?= us
PVE_KEYBOARD ?= en-us
PVE_EMAIL ?= root@localhost
PVE_ROOT_PASSWORD_HASH ?=
PVE_SSH_PUBKEY ?=
PVE_ANSWER_URL ?=
PVE_CERT_FP ?=
# udev ID_SERIAL of the disk Proxmox installs onto. Set it for any node with a
# data disk; unpinned, the installer takes the first disk it finds. For a SATA
# disk this is model_serial - the /dev/disk/by-id/ata-* name without "ata-" -
# not the short serial lsblk prints. Recorded per node in inventory as
# proxmox_install_disk_serial.
PVE_DISK_SERIAL ?=

# Output paths
PVE_ISO_OUTPUT_DIR := $(CURDIR)/packer/proxmox/pve-iso/output
PVE_PXE_OUTPUT_DIR := $(CURDIR)/packer/proxmox/pve-iso/pxe

.PHONY: help init validate check clean check-deps check-loop-devices
.PHONY: pi-bookworm-image pi-resize-image pi-sdr pi-sdr-config pi-compress-image
.PHONY: pi-pidp11 pi-bookworm-image-pidp11 pi-resize-image-pidp11 pi-pidp11-config pi-compress-image-pidp11
.PHONY: vm-backend vm-backend-stage-upstream vm-backend-inputs vm-backend-base vm-backend-config vm-backend-compress vm-backend-publish
.PHONY: iso-backend iso-backend-boot iso-backend-payload iso-backend-image iso-backend-publish
.PHONY: pi-pki pi-pki-image pi-pki-config pi-pki-compress pi-pki-publish
.PHONY: pi-backend pi-backend-inputs pi-backend-stage-upstream pi-backend-publish pi-bookworm-image-backend pi-resize-image-backend pi-backend-config pi-compress-image-backend
.PHONY: init-pi init-proxmox proxmox-fedora
.PHONY: pve1-env pve2-env pve-env-clean
.PHONY: proxmox-fedora-pve1 proxmox-fedora-pve2 proxmox-fedora-tenant
.PHONY: proxmox-pve-iso-container proxmox-pve-iso-zfs proxmox-pve-iso-ext4
.PHONY: proxmox-pve-iso-http proxmox-pve-pxe proxmox-pve-iso-clean

# ------------------------------------------------------------
# Help
# ------------------------------------------------------------
help:
	@echo "Deevnet Image Factory"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@echo "Initialization:"
	@echo "  init                  Initialize all Packer plugins"
	@echo "  init-pi               Raspberry Pi builds use container packer"
	@echo "  init-proxmox           Initialize Proxmox plugins"
	@echo ""
	@echo "Build targets:"
	@echo "  pi-bookworm-image      Build generic Raspberry Pi Bookworm image (autoprov only)"
	@echo "  pi-sdr                 Build fully baked Raspberry Pi SDR image (base + offline config)"
	@echo "  pi-pidp11              Build fully baked Raspberry Pi PiDP-11 image (base + simh)"
	@echo "  pi-backend             Build the take-home tenant backend image (MQTT + logs, no Deevnet access)"
	@echo "  pi-backend-stage-upstream  Stage the arm64 VictoriaLogs/vmauth releases on the artifact server (sudo)"
	@echo "  pi-backend-publish     Publish the built .img.xz to the tenant downloads tree (sudo)"
	@echo "  vm-backend             Build the take-home tenant backend as an amd64 VM image (qcow2, Proxmox/KVM)"
	@echo "  vm-backend-stage-upstream  Stage the amd64 releases and Debian's base image, throttled (sudo)"
	@echo "  vm-backend-publish     Publish the built .qcow2 to the tenant downloads tree (sudo)"
	@echo "  iso-backend            Build the take-home installer ISO (hybrid BIOS/UEFI) from the VM backend's disk (sudo)"
	@echo "  iso-backend-publish    Publish the built .iso to the tenant downloads tree (sudo)"
	@echo "  pi-pki                 Build the offline CA ceremony image for a Raspberry Pi 4 (no network, tools baked in)"
	@echo "  pi-pki-publish         Publish the ceremony image and its sha256 to the artifact server (sudo)"
	@echo "  proxmox-fedora         Build Proxmox Fedora template (FEDORA_RELEASE=$(FEDORA_RELEASE))"
	@echo "  proxmox-fedora-pve1    ... on node $(PVE1_NODE), credentials from vault ($(PVE1_HOST))"
	@echo "  proxmox-fedora-pve2    ... on node $(PVE2_NODE): not needed, it runs tenant workloads only"
	@echo "  proxmox-fedora-tenant  Tenant workload template (no a_autoprov) on $(PVE2_NODE)"
	@echo ""
	@echo "Proxmox credentials (from the Deevnet inventory vault):"
	@echo "  pve1-env               Print TF_VAR_proxmox_* exports for $(PVE1_NODE)  (eval it)"
	@echo "  pve2-env               Print TF_VAR_proxmox_* exports for $(PVE2_NODE)  (eval it)"
	@echo "  pve-env-clean          Delete legacy rendered credential files (none are written now)"
	@echo ""
	@echo "Proxmox VE bare metal ISO:"
	@echo "  proxmox-pve-iso-container  Build container with Proxmox tooling (one-time)"
	@echo "  proxmox-pve-iso-zfs        Build ISO with embedded ZFS answer file"
	@echo "  proxmox-pve-iso-ext4       Build ISO with embedded ext4+LVM answer file"
	@echo "  proxmox-pve-iso-http       Build ISO for HTTP answer fetch (PXE-ready)"
	@echo "  proxmox-pve-pxe            Extract kernel/initrd for PXE boot"
	@echo "  proxmox-pve-iso-clean      Clean PVE ISO build artifacts"
	@echo ""
	@echo "Utilities:"
	@echo "  validate               Validate all Packer configurations"
	@echo "  check                  Syntax-check all Packer configurations (no secrets or plugins; CI runs this)"
	@echo "  check-deps             Check for required build dependencies"
	@echo "  check-loop-devices     Verify loop devices exist"
	@echo "  clean                  Remove build artifacts"

# ------------------------------------------------------------
# Init
# ------------------------------------------------------------
init: init-proxmox
	@echo "$(YELLOW)Note: Pi builds use container-based packer, no init required$(NC)"

init-pi:
	@echo "$(YELLOW)Pi builds use mkaczanowski/packer-builder-arm container$(NC)"
	@echo "$(YELLOW)No packer init required – run 'make pi-bookworm-image'$(NC)"

init-proxmox:
	cd packer/proxmox/fedora-base-image && packer init fedora.pkr.hcl

# ------------------------------------------------------------
# Validation
# ------------------------------------------------------------
validate:
	cd $(CURDIR)/packer/pi && packer validate sdr-bookworm.pkr.hcl
	cd $(CURDIR)/packer/proxmox/fedora-base-image && packer validate -var-file=fedora-$(FEDORA_RELEASE).pkrvars.hcl fedora.pkr.hcl

# Syntax only: needs no variables, no Proxmox and no ARM builder plugin, so it
# runs anywhere. `validate` is the full check.
check:
	cd $(CURDIR)/packer/pi && packer validate -syntax-only sdr-bookworm.pkr.hcl
	cd $(CURDIR)/packer/proxmox/fedora-base-image && packer validate -syntax-only fedora.pkr.hcl

# ------------------------------------------------------------
# Pi builds
# ------------------------------------------------------------

# Generic Bookworm Pi image (autoprov only)
pi-bookworm-image: check-loop-devices $(PI_BOOKWORM_IMAGE_ZIP) $(PI_BOOKWORM_SSH_PUBKEY_FILE)
	echo "$(GREEN)→ Building generic Pi Bookworm image (autoprov)...$(NC)"
	sudo podman run --rm --privileged --network=host \
		--security-opt label=disable \
		-v /dev:/dev \
		-v "$(CURDIR)":/build:rw \
		$(PI_PACKER_ARM_CONTAINER) \
		build \
		  -var "ssh_pubkey_local_path=/build/$(patsubst $(CURDIR)/%,%,$(PI_BOOKWORM_SSH_PUBKEY_FILE))" \
		  -var "image_name=$(PI_IMAGE_NAME)" \
		  packer/pi/sdr-bookworm.pkr.hcl
	echo "$(GREEN)✓ Base Bookworm image ready: $(PI_BOOKWORM_AUTOPROV_IMG)$(NC)"

# Resize root partition to fill 8G image
pi-resize-image: $(PI_BOOKWORM_AUTOPROV_IMG)
	echo "$(GREEN)→ Expanding image file to 8G...$(NC)"
	sudo truncate -s 8G "$(PI_BOOKWORM_AUTOPROV_IMG)"
	echo "$(GREEN)→ Resizing root partition to fill image...$(NC)"
	LOOPDEV="$$(sudo losetup --find --partscan --show "$(PI_BOOKWORM_AUTOPROV_IMG)")"
	trap 'sudo losetup -d "$$LOOPDEV" 2>/dev/null || true' EXIT
	sudo partprobe "$$LOOPDEV"
	sudo udevadm settle
	: "Expand partition 2 to fill available space"
	sudo growpart "$$LOOPDEV" 2
	: "Expand ext4 filesystem"
	sudo e2fsck -f -y "$${LOOPDEV}p2" || true
	sudo resize2fs "$${LOOPDEV}p2"
	echo "$(GREEN)✓ Root partition resized to ~7G$(NC)"

# Compress image for distribution (Pi Imager supports .img.xz natively)
pi-compress-image: $(PI_BOOKWORM_AUTOPROV_IMG)
	echo "$(GREEN)→ Compressing image with xz (this may take a few minutes)...$(NC)"
	sudo xz -f -k -6 -T0 "$(PI_BOOKWORM_AUTOPROV_IMG)"
	echo "$(GREEN)✓ Compressed image: $(PI_BOOKWORM_AUTOPROV_IMG).xz$(NC)"

# Full SDR image = base image + resize + offline config + compress
pi-sdr: pi-bookworm-image pi-resize-image pi-sdr-config pi-compress-image
	echo "$(GREEN)✓ Pi SDR image complete: $(PI_BOOKWORM_AUTOPROV_IMG).xz$(NC)"

# Offline configuration step (Ansible against mounted image)
pi-sdr-config: $(PI_BOOKWORM_AUTOPROV_IMG)
	echo "$(GREEN)→ Applying SDR config to Bookworm image (offline Ansible)...$(NC)"

	: "Paths based on repo layout"
	PLAYBOOK="$(CURDIR)/ansible/playbooks/pi-sdr-config.yml"
	INVENTORY="$(CURDIR)/ansible/inventories/local.yml"

	[[ -f "$$PLAYBOOK" ]]  || { echo "$(RED)✗ Missing playbook: $$PLAYBOOK$(NC)"; exit 1; }
	[[ -f "$$INVENTORY" ]] || { echo "$(RED)✗ Missing inventory: $$INVENTORY$(NC)"; exit 1; }

	: "Pre-clean any leftover mounts from a prior failed run"
	sudo umount -R "$(PI_BOOKWORM_MNT)" 2>/dev/null || true
	sudo mkdir -p "$(PI_BOOKWORM_MNT)"

	: "Attach loop device with partition scanning"
	LOOPDEV="$$(sudo losetup --find --partscan --show "$(PI_BOOKWORM_AUTOPROV_IMG)")"
	echo "$(YELLOW)→ Using $$LOOPDEV$(NC)"

	: "Always clean up mounts + loop device (even if ansible fails)"
	trap 'sudo umount -R "$(PI_BOOKWORM_MNT)" 2>/dev/null || true; sudo losetup -d "$$LOOPDEV" 2>/dev/null || true' EXIT

	: "Race fix: force kernel/udev to (re)create loop partition nodes"
	sudo partprobe "$$LOOPDEV" 2>/dev/null || true
	sudo partx -u "$$LOOPDEV" 2>/dev/null || true
	sudo udevadm settle || true

	: "Wait briefly for /dev/loopXp1 and /dev/loopXp2 to exist"
	for i in {1..10}; do
		if [[ -b "$${LOOPDEV}p1" && -b "$${LOOPDEV}p2" ]]; then break; fi
		sleep 0.2
	done

	: "Hard fail if the partition nodes still aren't present"
	if [[ ! -b "$${LOOPDEV}p1" || ! -b "$${LOOPDEV}p2" ]]; then
		echo "$(RED)✗ Loop partition nodes not present: $${LOOPDEV}p1 / $${LOOPDEV}p2$(NC)"
		ls -l "$$LOOPDEV" || true
		ls -l "$${LOOPDEV}p"* 2>/dev/null || true
		lsblk "$$LOOPDEV" || true
		exit 1
	fi

	: "Mount root + boot"
	sudo mount "$${LOOPDEV}p2" "$(PI_BOOKWORM_MNT)"
	sudo mkdir -p "$(PI_BOOKWORM_MNT)/boot"
	sudo mount "$${LOOPDEV}p1" "$(PI_BOOKWORM_MNT)/boot"

	: "Minimal mounts needed for chroot operations"
	sudo mount --bind /dev  "$(PI_BOOKWORM_MNT)/dev"
	sudo mount -t proc proc "$(PI_BOOKWORM_MNT)/proc"
	sudo mount -t sysfs sys  "$(PI_BOOKWORM_MNT)/sys"

	: "Ensure qemu usermode is present inside the image for any chroot execution"
	sudo install -m 0755 /usr/bin/qemu-aarch64-static "$(PI_BOOKWORM_MNT)/usr/bin/qemu-aarch64-static"

	: "Run offline Ansible (fails hard on errors)"
	sudo ansible-playbook \
	  -i "$$INVENTORY" \
	  "$$PLAYBOOK" \
	  --extra-vars "chroot_root=$(PI_BOOKWORM_MNT)"

	echo "$(GREEN)✓ SDR config applied$(NC)"

# ------------------------------------------------------------
# Pi PiDP-11 Image Build
# ------------------------------------------------------------

PI_PIDP11_IMAGE_VARIANT := pi-pidp11
PI_PIDP11_IMAGE_NAME := raspios-bookworm-$(PI_IMAGE_PLATFORM)-$(PI_PIDP11_IMAGE_VARIANT)
PI_PIDP11_AUTOPROV_IMG := $(CURDIR)/$(PI_PIDP11_IMAGE_NAME).img

# Full PiDP-11 image = base image + resize + offline config + compress
pi-pidp11: pi-bookworm-image-pidp11 pi-resize-image-pidp11 pi-pidp11-config pi-compress-image-pidp11
	echo "$(GREEN)✓ Pi PiDP-11 image complete: $(PI_PIDP11_AUTOPROV_IMG).xz$(NC)"

# Build base Bookworm image with a_autoprov (reuses sdr-bookworm.pkr.hcl)
pi-bookworm-image-pidp11: check-loop-devices $(PI_BOOKWORM_IMAGE_ZIP) $(PI_BOOKWORM_SSH_PUBKEY_FILE)
	echo "$(GREEN)→ Building Pi PiDP-11 Bookworm image (autoprov)...$(NC)"
	sudo podman run --rm --privileged --network=host \
		--security-opt label=disable \
		-v /dev:/dev \
		-v "$(CURDIR)":/build:rw \
		$(PI_PACKER_ARM_CONTAINER) \
		build \
		  -var "ssh_pubkey_local_path=/build/$(patsubst $(CURDIR)/%,%,$(PI_BOOKWORM_SSH_PUBKEY_FILE))" \
		  -var "image_name=$(PI_PIDP11_IMAGE_NAME)" \
		  packer/pi/sdr-bookworm.pkr.hcl
	echo "$(GREEN)✓ Base Bookworm image ready: $(PI_PIDP11_AUTOPROV_IMG)$(NC)"

# Resize root partition to fill 8G image
pi-resize-image-pidp11: $(PI_PIDP11_AUTOPROV_IMG)
	echo "$(GREEN)→ Expanding image file to 8G...$(NC)"
	sudo truncate -s 8G "$(PI_PIDP11_AUTOPROV_IMG)"
	echo "$(GREEN)→ Resizing root partition to fill image...$(NC)"
	LOOPDEV="$$(sudo losetup --find --partscan --show "$(PI_PIDP11_AUTOPROV_IMG)")"
	trap 'sudo losetup -d "$$LOOPDEV" 2>/dev/null || true' EXIT
	sudo partprobe "$$LOOPDEV"
	sudo udevadm settle
	: "Expand partition 2 to fill available space"
	sudo growpart "$$LOOPDEV" 2
	: "Expand ext4 filesystem"
	sudo e2fsck -f -y "$${LOOPDEV}p2" || true
	sudo resize2fs "$${LOOPDEV}p2"
	echo "$(GREEN)✓ Root partition resized to ~7G$(NC)"

# Offline configuration step (Ansible against mounted image)
pi-pidp11-config: $(PI_PIDP11_AUTOPROV_IMG)
	echo "$(GREEN)→ Applying PiDP-11 config to Bookworm image (offline Ansible)...$(NC)"

	: "Paths based on repo layout"
	PLAYBOOK="$(CURDIR)/ansible/playbooks/pi-pidp11-config.yml"
	INVENTORY="$(CURDIR)/ansible/inventories/local.yml"

	[[ -f "$$PLAYBOOK" ]]  || { echo "$(RED)✗ Missing playbook: $$PLAYBOOK$(NC)"; exit 1; }
	[[ -f "$$INVENTORY" ]] || { echo "$(RED)✗ Missing inventory: $$INVENTORY$(NC)"; exit 1; }

	: "Pre-clean any leftover mounts from a prior failed run"
	sudo umount -R "$(PI_BOOKWORM_MNT)" 2>/dev/null || true
	sudo mkdir -p "$(PI_BOOKWORM_MNT)"

	: "Attach loop device with partition scanning"
	LOOPDEV="$$(sudo losetup --find --partscan --show "$(PI_PIDP11_AUTOPROV_IMG)")"
	echo "$(YELLOW)→ Using $$LOOPDEV$(NC)"

	: "Always clean up mounts + loop device (even if ansible fails)"
	trap 'sudo umount -R "$(PI_BOOKWORM_MNT)" 2>/dev/null || true; sudo losetup -d "$$LOOPDEV" 2>/dev/null || true' EXIT

	: "Race fix: force kernel/udev to (re)create loop partition nodes"
	sudo partprobe "$$LOOPDEV" 2>/dev/null || true
	sudo partx -u "$$LOOPDEV" 2>/dev/null || true
	sudo udevadm settle || true

	: "Wait briefly for /dev/loopXp1 and /dev/loopXp2 to exist"
	for i in {1..10}; do
		if [[ -b "$${LOOPDEV}p1" && -b "$${LOOPDEV}p2" ]]; then break; fi
		sleep 0.2
	done

	: "Hard fail if the partition nodes still aren't present"
	if [[ ! -b "$${LOOPDEV}p1" || ! -b "$${LOOPDEV}p2" ]]; then
		echo "$(RED)✗ Loop partition nodes not present: $${LOOPDEV}p1 / $${LOOPDEV}p2$(NC)"
		ls -l "$$LOOPDEV" || true
		ls -l "$${LOOPDEV}p"* 2>/dev/null || true
		lsblk "$$LOOPDEV" || true
		exit 1
	fi

	: "Mount root + boot"
	sudo mount "$${LOOPDEV}p2" "$(PI_BOOKWORM_MNT)"
	sudo mkdir -p "$(PI_BOOKWORM_MNT)/boot"
	sudo mount "$${LOOPDEV}p1" "$(PI_BOOKWORM_MNT)/boot"

	: "Minimal mounts needed for chroot operations"
	sudo mount --bind /dev  "$(PI_BOOKWORM_MNT)/dev"
	sudo mount -t proc proc "$(PI_BOOKWORM_MNT)/proc"
	sudo mount -t sysfs sys  "$(PI_BOOKWORM_MNT)/sys"

	: "Ensure qemu usermode is present inside the image for any chroot execution"
	sudo install -m 0755 /usr/bin/qemu-aarch64-static "$(PI_BOOKWORM_MNT)/usr/bin/qemu-aarch64-static"

	: "Run offline Ansible (fails hard on errors)"
	sudo ansible-playbook \
	  -i "$$INVENTORY" \
	  "$$PLAYBOOK" \
	  --extra-vars "chroot_root=$(PI_BOOKWORM_MNT)"

	echo "$(GREEN)✓ PiDP-11 config applied$(NC)"

# Compress PiDP-11 image for distribution
pi-compress-image-pidp11: $(PI_PIDP11_AUTOPROV_IMG)
	echo "$(GREEN)→ Compressing image with xz (this may take a few minutes)...$(NC)"
	sudo xz -f -k -6 -T0 "$(PI_PIDP11_AUTOPROV_IMG)"
	echo "$(GREEN)✓ Compressed image: $(PI_PIDP11_AUTOPROV_IMG).xz$(NC)"

# ------------------------------------------------------------
# Pi take-home backend image Build
# ------------------------------------------------------------
# A mini Deevnet for a tenant to take home: Mosquitto, VictoriaLogs, vmauth,
# the log bridge and deevnet-kit, with the same app contract as Deevnet and
# no Deevnet access (docs/pi-backend.md). Its inputs are arm64 binaries from
# the artifact server, fetched into build/pi-backend/.

PI_BACKEND_IMAGE_VARIANT := pi-backend
PI_BACKEND_IMAGE_NAME := raspios-bookworm-$(PI_IMAGE_PLATFORM)-$(PI_BACKEND_IMAGE_VARIANT)
PI_BACKEND_AUTOPROV_IMG := $(CURDIR)/$(PI_BACKEND_IMAGE_NAME).img
PI_BACKEND_INPUTS := $(CURDIR)/build/pi-backend

# Deevnet's own builds, staged by each repo's `make stage-pi`, each pinned to
# the exact file it installs (<binary>:<version>). Staging a new build changes
# nothing here until its version is bumped. The log bridge's is one commit past
# its v0.1.1 tag: what -latest pointed at when pinned.
PI_BACKEND_DEEVNET_BINARIES := deevnet-kit:v0.27.0 deevnet-log-user:v0.27.0 deevnet-log-bridge:v0.1.1-1-g20abb75

# Upstream releases, pinned to the versions Deevnet's log store runs
# (deevnet.mgmt victorialogs role). The checksums are the release's own.
PI_BACKEND_VLOGS_VERSION := v1.52.0
# Each upstream release in two builds: arm64 for the Pi, amd64 for the take-home
# VM (CHG-0074). A name ends in the architecture; so does its checksum's.
PI_BACKEND_VLOGS_TARBALL_arm64 := victoria-logs-linux-arm64-$(PI_BACKEND_VLOGS_VERSION).tar.gz
PI_BACKEND_VLOGS_SHA256_arm64  := 91338c3e5e3d743a862c0a8665bf80862f639dbd4de6f6ff19ada7df5e9acf45
PI_BACKEND_VLOGS_TARBALL_amd64 := victoria-logs-linux-amd64-$(PI_BACKEND_VLOGS_VERSION).tar.gz
PI_BACKEND_VLOGS_SHA256_amd64  := d14f585144b8d6813f15e11f0041f487e15e10e5f5e5a31be0311367e93d3494
# vmauth and vmalert from vmutils, and the metrics store's cluster, at the
# release Deevnet's metrics store and vmalert run (deevnet.mgmt metrics_store
# and alerting roles, CHG-0070, CHG-0071).
PI_BACKEND_VMUTILS_VERSION := v1.156.0
PI_BACKEND_VMUTILS_TARBALL_arm64 := vmutils-linux-arm64-$(PI_BACKEND_VMUTILS_VERSION).tar.gz
PI_BACKEND_VMUTILS_SHA256_arm64  := 1a8e4ed55df2a59d5cd03056213f50d293d4fab029e38dd960597362d92cf176
PI_BACKEND_VMUTILS_TARBALL_amd64 := vmutils-linux-amd64-$(PI_BACKEND_VMUTILS_VERSION).tar.gz
PI_BACKEND_VMUTILS_SHA256_amd64  := d71f7f00e07782531000620ec6c2a9d7ec83324f364dd1f36095ab378b5fb43b
PI_BACKEND_VMCLUSTER_TARBALL_arm64 := victoria-metrics-linux-arm64-$(PI_BACKEND_VMUTILS_VERSION)-cluster.tar.gz
PI_BACKEND_VMCLUSTER_SHA256_arm64  := 74505196bf58779c0b9eca0b6b469a9bdd5a8802b9dfc1ed1e40b71004992643
PI_BACKEND_VMCLUSTER_TARBALL_amd64 := victoria-metrics-linux-amd64-$(PI_BACKEND_VMUTILS_VERSION)-cluster.tar.gz
PI_BACKEND_VMCLUSTER_SHA256_amd64  := e026eb6da6221c9058ad5ebeb8dda97106b2086b628d84c5c2b3d3ed8a7939d4
PI_BACKEND_UPSTREAM_PATH := pi-images/victoria
# Alerting's other two, the versions Deevnet's alerting role runs (CHG-0071).
PI_BACKEND_ALERTMANAGER_VERSION := 0.35.0
PI_BACKEND_ALERTMANAGER_TARBALL_arm64 := alertmanager-$(PI_BACKEND_ALERTMANAGER_VERSION).linux-arm64.tar.gz
PI_BACKEND_ALERTMANAGER_SHA256_arm64  := b7a8a69f849c6f837348b05476195862152f9de8eae338eb36ab29801d341654
PI_BACKEND_ALERTMANAGER_TARBALL_amd64 := alertmanager-$(PI_BACKEND_ALERTMANAGER_VERSION).linux-amd64.tar.gz
PI_BACKEND_ALERTMANAGER_SHA256_amd64  := 6c7752a903c40c8a749e0b29df9240437e4fbb8228068d0af8807377db32addd
PI_BACKEND_NTFY_VERSION := 2.38.0
PI_BACKEND_NTFY_TARBALL_arm64 := ntfy_$(PI_BACKEND_NTFY_VERSION)_linux_arm64.tar.gz
PI_BACKEND_NTFY_SHA256_arm64  := f596c52b0391a6da4ef5071d7eb367d6c7693e9e1b6b11fdb3c79b887cf125d3
PI_BACKEND_NTFY_TARBALL_amd64 := ntfy_$(PI_BACKEND_NTFY_VERSION)_linux_amd64.tar.gz
PI_BACKEND_NTFY_SHA256_amd64  := b1ff7cae482a6b802c28cddd83b63c7e146bf96a5ff97894278ab478b3a0436c
PI_BACKEND_ALERTING_PATH := pi-images/alerting
# silo, the bucket store Deevnet's buckets run on. arm64 is cross-built from the
# same tag by deevnet-container-image-factory (`make binary IMAGE=silo
# ARCH=arm64`, CHG-0073); amd64 is the static binary in the amd64 image Deevnet
# runs, built by the same stage (CHG-0074). Each is staged beside its sha256.
PI_BACKEND_SILO_VERSION := RELEASE.2026-11-12T00-00-00Z
# Grafana and its VictoriaLogs plugin, the versions Deevnet runs (deevnet.mgmt
# grafana role, CHG-0024). Grafana's checksum is the one it publishes; the
# plugin zip is the one the Builder already mirrors for Deevnet (deevnet.builder
# artifacts, fetched-artifacts), whose sha256 inventory pins. One zip carries
# every platform's backend.
PI_BACKEND_GRAFANA_VERSION := 13.2.2
PI_BACKEND_GRAFANA_TARBALL_arm64 := grafana_13.2.2_34846740809_linux_arm64.tar.gz
PI_BACKEND_GRAFANA_SHA256_arm64  := 7268f9a576f919f14e6263b344a85b6ac8d768fbda247910c43ce4e12c747a72
PI_BACKEND_GRAFANA_TARBALL_amd64 := grafana_13.2.2_34846740809_linux_amd64.tar.gz
PI_BACKEND_GRAFANA_SHA256_amd64  := 9662c838a09824fdb072e5f6fbdd45b62cf541b20f3d609ea5011e6e5f544c8f
PI_BACKEND_GRAFANA_RELEASE_URL := https://dl.grafana.com/grafana/release/$(PI_BACKEND_GRAFANA_VERSION)
PI_BACKEND_GRAFANA_PATH    := pi-images/grafana
PI_BACKEND_GRAFANA_PLUGIN  := grafana-plugins/victoriametrics-logs-datasource-v0.32.0.zip
PI_BACKEND_GRAFANA_PLUGIN_SHA256 := 8204d097b17f53b1c3a71761047734b7980bd983710c6cfcef8d938abe5eeef0
# What `file` says of a binary built for each.
PI_BACKEND_MAGIC_arm64 := ARM aarch64
PI_BACKEND_MAGIC_amd64 := x86-64
# Downloads across the core router are throttled (INC-0005).
UPSTREAM_RATE ?= 1500K
PI_BACKEND_ARTIFACTS_ROOT ?= /srv/deevnet-http

# Full backend image = inputs + base image + resize + offline config + compress
pi-backend: pi-backend-inputs pi-bookworm-image-backend pi-resize-image-backend pi-backend-config pi-compress-image-backend
	echo "$(GREEN)✓ Pi backend image complete: $(PI_BACKEND_AUTOPROV_IMG).xz$(NC)"

# One-time, on the Builder: put the upstream releases for one architecture
# ($(1)) where the build fetches them. Pis and the take-home VM are outside the
# artifact role's mirroring, so this is their stage step. Each download is
# throttled, a file already staged with the right checksum is not fetched
# again, and a download whose checksum is wrong is refused.
define backend_stage_upstream
	A="$(PI_BACKEND_ARTIFACTS_ROOT)"
	sudo install -d -o nginx -g nginx -m 0755 "$$A/$(PI_BACKEND_UPSTREAM_PATH)" "$$A/$(PI_BACKEND_GRAFANA_PATH)" "$$A/$(PI_BACKEND_ALERTING_PATH)"
	TMP="$$(mktemp -d -p /srv)"
	trap 'rm -rf "$$TMP"' EXIT
	stage() { # dir file sha256 url
	  if [[ -f "$$A/$$1/$$2" ]] && echo "$$3  $$A/$$1/$$2" | sha256sum -c --quiet - 2>/dev/null; then
	    echo "have $$1/$$2"; return 0
	  fi
	  curl -fsSL --limit-rate "$(UPSTREAM_RATE)" -o "$$TMP/$$2" "$$4"
	  echo "$$3  $$TMP/$$2" | sha256sum -c -
	  sudo install -o nginx -g nginx -m 0644 "$$TMP/$$2" "$$A/$$1/$$2"
	  rm -f "$$TMP/$$2"
	}
	stage "$(PI_BACKEND_UPSTREAM_PATH)" "$(PI_BACKEND_VLOGS_TARBALL_$(1))" "$(PI_BACKEND_VLOGS_SHA256_$(1))" \
	  "https://github.com/VictoriaMetrics/VictoriaLogs/releases/download/$(PI_BACKEND_VLOGS_VERSION)/$(PI_BACKEND_VLOGS_TARBALL_$(1))"
	stage "$(PI_BACKEND_UPSTREAM_PATH)" "$(PI_BACKEND_VMUTILS_TARBALL_$(1))" "$(PI_BACKEND_VMUTILS_SHA256_$(1))" \
	  "https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/$(PI_BACKEND_VMUTILS_VERSION)/$(PI_BACKEND_VMUTILS_TARBALL_$(1))"
	stage "$(PI_BACKEND_UPSTREAM_PATH)" "$(PI_BACKEND_VMCLUSTER_TARBALL_$(1))" "$(PI_BACKEND_VMCLUSTER_SHA256_$(1))" \
	  "https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/$(PI_BACKEND_VMUTILS_VERSION)/$(PI_BACKEND_VMCLUSTER_TARBALL_$(1))"
	stage "$(PI_BACKEND_ALERTING_PATH)" "$(PI_BACKEND_ALERTMANAGER_TARBALL_$(1))" "$(PI_BACKEND_ALERTMANAGER_SHA256_$(1))" \
	  "https://github.com/prometheus/alertmanager/releases/download/v$(PI_BACKEND_ALERTMANAGER_VERSION)/$(PI_BACKEND_ALERTMANAGER_TARBALL_$(1))"
	stage "$(PI_BACKEND_ALERTING_PATH)" "$(PI_BACKEND_NTFY_TARBALL_$(1))" "$(PI_BACKEND_NTFY_SHA256_$(1))" \
	  "https://github.com/binwiederhier/ntfy/releases/download/v$(PI_BACKEND_NTFY_VERSION)/$(PI_BACKEND_NTFY_TARBALL_$(1))"
	stage "$(PI_BACKEND_GRAFANA_PATH)" "$(PI_BACKEND_GRAFANA_TARBALL_$(1))" "$(PI_BACKEND_GRAFANA_SHA256_$(1))" \
	  "$(PI_BACKEND_GRAFANA_RELEASE_URL)/$(PI_BACKEND_GRAFANA_TARBALL_$(1))"
	echo "$(GREEN)✓ $(1) releases staged under $$A/pi-images$(NC)"
endef

pi-backend-stage-upstream:
	$(call backend_stage_upstream,arm64)

# Publish the finished image to the tenant downloads tree (CHG-0025), which the
# observability store serves to DVNTM-TD, so a meetup flashes cards from the
# site rather than the library's internet. Publishes what is here: run
# `make pi-backend` first.
pi-backend-publish:
	[[ -f "$(PI_BACKEND_AUTOPROV_IMG).xz" ]] || { echo "$(RED)✗ No $(PI_BACKEND_AUTOPROV_IMG).xz: run make pi-backend$(NC)"; exit 1; }
	DEST="$(PI_BACKEND_ARTIFACTS_ROOT)/tenant/pi"
	sudo install -d -o nginx -g nginx -m 0755 "$$DEST"
	sudo install -o nginx -g nginx -m 0644 "$(PI_BACKEND_AUTOPROV_IMG).xz" "$$DEST/"
	cd "$$DEST" && sha256sum "$(PI_BACKEND_IMAGE_NAME).img.xz" | sudo tee "$(PI_BACKEND_IMAGE_NAME).img.xz.sha256" >/dev/null
	echo "$(GREEN)✓ Published $$DEST/$(PI_BACKEND_IMAGE_NAME).img.xz$(NC)"

# Fetch every binary the image installs, at its pinned version, for one
# architecture ($(1)) into one inputs directory ($(2)).
define backend_inputs
	echo "$(YELLOW)→ Fetching $(1) backend inputs from artifacts...$(NC)"
	IN="$(2)"
	rm -rf "$$IN"
	mkdir -p "$$IN/tmp"
	for bv in $(PI_BACKEND_DEEVNET_BINARIES); do
	  b="$${bv%%:*}"; v="$${bv#*:}"
	  curl -fsSL -o "$$IN/$$b" "$(ARTIFACT_URL)/binaries/$$b/$$b-$$v-linux-$(1)"
	done
	cd "$$IN/tmp"
	curl -fsSL -O "$(ARTIFACT_URL)/$(PI_BACKEND_UPSTREAM_PATH)/$(PI_BACKEND_VLOGS_TARBALL_$(1))"
	curl -fsSL -O "$(ARTIFACT_URL)/$(PI_BACKEND_UPSTREAM_PATH)/$(PI_BACKEND_VMUTILS_TARBALL_$(1))"
	curl -fsSL -O "$(ARTIFACT_URL)/$(PI_BACKEND_UPSTREAM_PATH)/$(PI_BACKEND_VMCLUSTER_TARBALL_$(1))"
	curl -fsSL -O "$(ARTIFACT_URL)/$(PI_BACKEND_ALERTING_PATH)/$(PI_BACKEND_ALERTMANAGER_TARBALL_$(1))"
	curl -fsSL -O "$(ARTIFACT_URL)/$(PI_BACKEND_ALERTING_PATH)/$(PI_BACKEND_NTFY_TARBALL_$(1))"
	printf '%s  %s\n' \
	  "$(PI_BACKEND_VLOGS_SHA256_$(1))" "$(PI_BACKEND_VLOGS_TARBALL_$(1))" \
	  "$(PI_BACKEND_VMUTILS_SHA256_$(1))" "$(PI_BACKEND_VMUTILS_TARBALL_$(1))" \
	  "$(PI_BACKEND_VMCLUSTER_SHA256_$(1))" "$(PI_BACKEND_VMCLUSTER_TARBALL_$(1))" \
	  "$(PI_BACKEND_ALERTMANAGER_SHA256_$(1))" "$(PI_BACKEND_ALERTMANAGER_TARBALL_$(1))" \
	  "$(PI_BACKEND_NTFY_SHA256_$(1))" "$(PI_BACKEND_NTFY_TARBALL_$(1))" | sha256sum -c -
	tar -xzf "$(PI_BACKEND_VLOGS_TARBALL_$(1))" -C "$$IN" victoria-logs-prod
	tar -xzf "$(PI_BACKEND_VMUTILS_TARBALL_$(1))" -C "$$IN" vmauth-prod vmalert-prod
	tar -xzf "$(PI_BACKEND_VMCLUSTER_TARBALL_$(1))" -C "$$IN" vmstorage-prod vminsert-prod vmselect-prod
	tar -xzf "$(PI_BACKEND_ALERTMANAGER_TARBALL_$(1))" -C "$$IN" --strip-components=1 \
	  alertmanager-$(PI_BACKEND_ALERTMANAGER_VERSION).linux-$(1)/alertmanager
	tar -xzf "$(PI_BACKEND_NTFY_TARBALL_$(1))" -C "$$IN" --strip-components=1 \
	  ntfy_$(PI_BACKEND_NTFY_VERSION)_linux_$(1)/ntfy
	curl -fsSL -O "$(ARTIFACT_URL)/binaries/silo/silo-$(PI_BACKEND_SILO_VERSION)-linux-$(1)"
	curl -fsSL -O "$(ARTIFACT_URL)/binaries/silo/silo-$(PI_BACKEND_SILO_VERSION)-linux-$(1).sha256"
	sha256sum -c "silo-$(PI_BACKEND_SILO_VERSION)-linux-$(1).sha256"
	install -m 0755 "silo-$(PI_BACKEND_SILO_VERSION)-linux-$(1)" "$$IN/silo"
	for b in $(foreach bv,$(PI_BACKEND_DEEVNET_BINARIES),$(firstword $(subst :, ,$(bv)))) \
	         victoria-logs-prod vmauth-prod vmalert-prod vmstorage-prod vminsert-prod vmselect-prod alertmanager ntfy silo; do
	  file "$$IN/$$b" | grep -q '$(PI_BACKEND_MAGIC_$(1))' || { echo "$(RED)✗ $$b is not a $(1) binary$(NC)"; exit 1; }
	done
	: "Grafana and its plugin stay packed; the config play unpacks them into the image"
	curl -fsSL -o "$$IN/grafana.tar.gz" "$(ARTIFACT_URL)/$(PI_BACKEND_GRAFANA_PATH)/$(PI_BACKEND_GRAFANA_TARBALL_$(1))"
	curl -fsSL -o "$$IN/grafana-plugin.zip" "$(ARTIFACT_URL)/$(PI_BACKEND_GRAFANA_PLUGIN)"
	printf '%s  %s\n%s  %s\n' \
	  "$(PI_BACKEND_GRAFANA_SHA256_$(1))" "$$IN/grafana.tar.gz" \
	  "$(PI_BACKEND_GRAFANA_PLUGIN_SHA256)" "$$IN/grafana-plugin.zip" | sha256sum -c -
	rm -rf "$$IN/tmp"
	echo "$(GREEN)✓ Inputs ready in $$IN$(NC)"
endef

pi-backend-inputs:
	$(call backend_inputs,arm64,$(PI_BACKEND_INPUTS))

# Build base Bookworm image (reuses sdr-bookworm.pkr.hcl). The a_autoprov user
# it adds is removed again by pi-backend-config.
pi-bookworm-image-backend: check-loop-devices $(PI_BOOKWORM_IMAGE_ZIP) $(PI_BOOKWORM_SSH_PUBKEY_FILE)
	echo "$(GREEN)→ Building Pi backend Bookworm image...$(NC)"
	sudo podman run --rm --privileged --network=host \
		--security-opt label=disable \
		-v /dev:/dev \
		-v "$(CURDIR)":/build:rw \
		$(PI_PACKER_ARM_CONTAINER) \
		build \
		  -var "ssh_pubkey_local_path=/build/$(patsubst $(CURDIR)/%,%,$(PI_BOOKWORM_SSH_PUBKEY_FILE))" \
		  -var "image_name=$(PI_BACKEND_IMAGE_NAME)" \
		  packer/pi/sdr-bookworm.pkr.hcl
	echo "$(GREEN)✓ Base Bookworm image ready: $(PI_BACKEND_AUTOPROV_IMG)$(NC)"

# Resize root partition to fill 8G image
pi-resize-image-backend: $(PI_BACKEND_AUTOPROV_IMG)
	echo "$(GREEN)→ Expanding image file to 8G...$(NC)"
	sudo truncate -s 8G "$(PI_BACKEND_AUTOPROV_IMG)"
	echo "$(GREEN)→ Resizing root partition to fill image...$(NC)"
	LOOPDEV="$$(sudo losetup --find --partscan --show "$(PI_BACKEND_AUTOPROV_IMG)")"
	trap 'sudo losetup -d "$$LOOPDEV" 2>/dev/null || true' EXIT
	sudo partprobe "$$LOOPDEV"
	sudo udevadm settle
	: "Expand partition 2 to fill available space"
	sudo growpart "$$LOOPDEV" 2
	: "Expand ext4 filesystem"
	sudo e2fsck -f -y "$${LOOPDEV}p2" || true
	sudo resize2fs "$${LOOPDEV}p2"
	echo "$(GREEN)✓ Root partition resized to ~7G$(NC)"

# Offline configuration step (Ansible against mounted image)
pi-backend-config: $(PI_BACKEND_AUTOPROV_IMG)
	echo "$(GREEN)→ Applying backend config to Bookworm image (offline Ansible)...$(NC)"

	: "Paths based on repo layout"
	PLAYBOOK="$(CURDIR)/ansible/playbooks/pi-backend-config.yml"
	INVENTORY="$(CURDIR)/ansible/inventories/local.yml"

	[[ -f "$$PLAYBOOK" ]]  || { echo "$(RED)✗ Missing playbook: $$PLAYBOOK$(NC)"; exit 1; }
	[[ -f "$$INVENTORY" ]] || { echo "$(RED)✗ Missing inventory: $$INVENTORY$(NC)"; exit 1; }
	[[ -d "$(PI_BACKEND_INPUTS)" ]] || { echo "$(RED)✗ No inputs: run make pi-backend-inputs$(NC)"; exit 1; }
	: "The owner's starter PKI tools (ADR-0041 §3), from the deevnet.mgmt checkout beside this one"
	[[ -x "$(PI_PKI_TOOLS)/deevnet-pki-owner.sh" && -x "$(PI_PKI_TOOLS)/deevnet-pki-media.sh" && -f "$(PI_PKI_TOOLS)/deevnet-pki-owner.cnf" ]] \
	  || { echo "$(RED)✗ No owner PKI tools at $(PI_PKI_TOOLS)$(NC)"; exit 1; }
	TOOLS_REF="$$(git -C "$(PI_PKI_TOOLS)" rev-parse --short HEAD)$$(git -C "$(PI_PKI_TOOLS)" diff --quiet -- . || echo -dirty)"

	: "Pre-clean any leftover mounts from a prior failed run"
	sudo umount -R "$(PI_BOOKWORM_MNT)" 2>/dev/null || true
	sudo mkdir -p "$(PI_BOOKWORM_MNT)"

	: "Attach loop device with partition scanning"
	LOOPDEV="$$(sudo losetup --find --partscan --show "$(PI_BACKEND_AUTOPROV_IMG)")"
	echo "$(YELLOW)→ Using $$LOOPDEV$(NC)"

	: "Always clean up mounts + loop device (even if ansible fails)"
	trap 'sudo umount -R "$(PI_BOOKWORM_MNT)" 2>/dev/null || true; sudo losetup -d "$$LOOPDEV" 2>/dev/null || true' EXIT

	: "Race fix: force kernel/udev to (re)create loop partition nodes"
	sudo partprobe "$$LOOPDEV" 2>/dev/null || true
	sudo partx -u "$$LOOPDEV" 2>/dev/null || true
	sudo udevadm settle || true

	: "Wait briefly for /dev/loopXp1 and /dev/loopXp2 to exist"
	for i in {1..10}; do
		if [[ -b "$${LOOPDEV}p1" && -b "$${LOOPDEV}p2" ]]; then break; fi
		sleep 0.2
	done

	: "Hard fail if the partition nodes still aren't present"
	if [[ ! -b "$${LOOPDEV}p1" || ! -b "$${LOOPDEV}p2" ]]; then
		echo "$(RED)✗ Loop partition nodes not present: $${LOOPDEV}p1 / $${LOOPDEV}p2$(NC)"
		ls -l "$$LOOPDEV" || true
		ls -l "$${LOOPDEV}p"* 2>/dev/null || true
		lsblk "$$LOOPDEV" || true
		exit 1
	fi

	: "Mount root + boot"
	sudo mount "$${LOOPDEV}p2" "$(PI_BOOKWORM_MNT)"
	sudo mkdir -p "$(PI_BOOKWORM_MNT)/boot"
	sudo mount "$${LOOPDEV}p1" "$(PI_BOOKWORM_MNT)/boot"

	: "Minimal mounts needed for chroot operations"
	sudo mount --bind /dev  "$(PI_BOOKWORM_MNT)/dev"
	sudo mount -t proc proc "$(PI_BOOKWORM_MNT)/proc"
	sudo mount -t sysfs sys  "$(PI_BOOKWORM_MNT)/sys"

	: "Ensure qemu usermode is present inside the image for any chroot execution"
	sudo install -m 0755 /usr/bin/qemu-aarch64-static "$(PI_BOOKWORM_MNT)/usr/bin/qemu-aarch64-static"

	: "Run offline Ansible (fails hard on errors)"
	sudo ansible-playbook \
	  -i "$$INVENTORY" \
	  "$$PLAYBOOK" \
	  --extra-vars "chroot_root=$(PI_BOOKWORM_MNT) pi_backend_inputs=$(PI_BACKEND_INPUTS) pki_tools_src=$(PI_PKI_TOOLS) pki_tools_ref=$$TOOLS_REF"

	: "The emulator is a build tool, not part of the owner's image"
	sudo rm -f "$(PI_BOOKWORM_MNT)/usr/bin/qemu-aarch64-static"

	echo "$(GREEN)✓ Backend config applied$(NC)"

# Compress backend image for distribution
pi-compress-image-backend: $(PI_BACKEND_AUTOPROV_IMG)
	echo "$(GREEN)→ Compressing image with xz (this may take a few minutes)...$(NC)"
	sudo xz -f -k -6 -T0 "$(PI_BACKEND_AUTOPROV_IMG)"
	echo "$(GREEN)✓ Compressed image: $(PI_BACKEND_AUTOPROV_IMG).xz$(NC)"

# ------------------------------------------------------------
# Take-home VM image Build (CHG-0074)
# ------------------------------------------------------------
# The Pi's take-home backend as an amd64 virtual machine (qcow2) for Proxmox
# and KVM: the same services, deevnet-kit and self-test, built by the same
# configuration play with medium=vm (docs/vm-backend.md). It starts from
# Debian's official bookworm "nocloud" image, as the Pi image starts from
# Raspberry Pi OS: no cloud-init, and the play locks the root login that image
# leaves open. A VM has no boot partition to edit, so its first boot asks on the
# console (deevnet-kit setup).

VM_BACKEND_IMAGE_NAME := debian-bookworm-$(PI_IMAGE_PLATFORM)-vm-backend
VM_BACKEND_BUILD      := $(CURDIR)/build/vm-backend
VM_BACKEND_INPUTS     := $(CURDIR)/build/vm-backend-inputs
VM_BACKEND_RAW        := $(VM_BACKEND_BUILD)/$(VM_BACKEND_IMAGE_NAME).raw
VM_BACKEND_QCOW2      := $(CURDIR)/$(VM_BACKEND_IMAGE_NAME).qcow2
VM_BACKEND_MNT        := /mnt/vm-backend-image
# The disk the VM sees. qcow2 is sparse, so the file stays small; the root
# file system grows to fill a bigger disk on every boot (deevnet-kit-growroot).
VM_BACKEND_DISK_SIZE  := 16G

# Debian's dated build, pinned with the SHA512 Debian publishes beside it.
VM_DEBIAN_BUILD  := 20261117-2665
VM_DEBIAN_IMAGE  := debian-12-nocloud-amd64-$(VM_DEBIAN_BUILD).qcow2
VM_DEBIAN_SHA512 := 43888727748a395aeec05646db5042fdccec9e9d8bb1af6250fb9476ad3925abb483695753075d6ede9e7a4ca3825a2d10cf0ba3f39663e2a402144d94294369
VM_DEBIAN_URL    := https://cloud.debian.org/images/cloud/bookworm/$(VM_DEBIAN_BUILD)/$(VM_DEBIAN_IMAGE)
VM_DEBIAN_PATH   := vm-images/debian

# apt inside the image, throttled across the core router (KB/s; 0 = no limit).
APT_DL_LIMIT ?= 1500

# Full VM image = inputs + base disk + offline config + qcow2
vm-backend: vm-backend-inputs vm-backend-base vm-backend-config vm-backend-compress
	echo "$(GREEN)✓ VM backend image complete: $(VM_BACKEND_QCOW2)$(NC)"

# One-time, on the Builder: the amd64 releases, and Debian's base image.
vm-backend-stage-upstream:
	$(call backend_stage_upstream,amd64)
	A="$(PI_BACKEND_ARTIFACTS_ROOT)/$(VM_DEBIAN_PATH)"
	sudo install -d -o nginx -g nginx -m 0755 "$$A"
	if [[ -f "$$A/$(VM_DEBIAN_IMAGE)" ]] && echo "$(VM_DEBIAN_SHA512)  $$A/$(VM_DEBIAN_IMAGE)" | sha512sum -c --quiet - 2>/dev/null; then
	  echo "have $(VM_DEBIAN_PATH)/$(VM_DEBIAN_IMAGE)"
	else
	  TMP="$$(mktemp -d -p /srv)"
	  trap 'rm -rf "$$TMP"' EXIT
	  curl -fsSL --limit-rate "$(UPSTREAM_RATE)" -o "$$TMP/$(VM_DEBIAN_IMAGE)" "$(VM_DEBIAN_URL)"
	  echo "$(VM_DEBIAN_SHA512)  $$TMP/$(VM_DEBIAN_IMAGE)" | sha512sum -c -
	  sudo install -o nginx -g nginx -m 0644 "$$TMP/$(VM_DEBIAN_IMAGE)" "$$A/"
	fi
	echo "$(GREEN)✓ Debian base staged under $$A$(NC)"

vm-backend-inputs:
	$(call backend_inputs,amd64,$(VM_BACKEND_INPUTS))

# Debian's image as a raw disk of VM_BACKEND_DISK_SIZE, its root (partition 1)
# grown to fill it.
vm-backend-base: check-loop-devices
	echo "$(GREEN)→ Preparing the Debian base disk...$(NC)"
	mkdir -p "$(VM_BACKEND_BUILD)"
	BASE="$(VM_BACKEND_BUILD)/$(VM_DEBIAN_IMAGE)"
	if ! { [[ -f "$$BASE" ]] && echo "$(VM_DEBIAN_SHA512)  $$BASE" | sha512sum -c --quiet - 2>/dev/null; }; then
	  curl -fsSL -o "$$BASE" "$(ARTIFACT_URL)/$(VM_DEBIAN_PATH)/$(VM_DEBIAN_IMAGE)"
	  echo "$(VM_DEBIAN_SHA512)  $$BASE" | sha512sum -c -
	fi
	rm -f "$(VM_BACKEND_RAW)"
	qemu-img convert -f qcow2 -O raw "$$BASE" "$(VM_BACKEND_RAW)"
	qemu-img resize -f raw "$(VM_BACKEND_RAW)" "$(VM_BACKEND_DISK_SIZE)"
	LOOPDEV="$$(sudo losetup --find --partscan --show "$(VM_BACKEND_RAW)")"
	trap 'sudo losetup -d "$$LOOPDEV" 2>/dev/null || true' EXIT
	sudo partprobe "$$LOOPDEV" 2>/dev/null || true
	sudo udevadm settle
	: "GPT: move the backup header to the new end, then grow the root partition"
	sudo sfdisk --relocate gpt-bak-std "$$LOOPDEV"
	sudo partprobe "$$LOOPDEV" 2>/dev/null || true
	sudo growpart "$$LOOPDEV" 1
	sudo e2fsck -f -y "$${LOOPDEV}p1" || true
	sudo resize2fs "$${LOOPDEV}p1"
	echo "$(GREEN)✓ Base disk ready: $(VM_BACKEND_RAW)$(NC)"

# Offline configuration: the Pi's play, medium=vm, against the mounted root.
vm-backend-config: $(VM_BACKEND_RAW)
	echo "$(GREEN)→ Applying backend config to the VM disk (offline Ansible)...$(NC)"
	PLAYBOOK="$(CURDIR)/ansible/playbooks/pi-backend-config.yml"
	INVENTORY="$(CURDIR)/ansible/inventories/local.yml"
	[[ -d "$(VM_BACKEND_INPUTS)" ]] || { echo "$(RED)✗ No inputs: run make vm-backend-inputs$(NC)"; exit 1; }
	[[ -x "$(PI_PKI_TOOLS)/deevnet-pki-owner.sh" && -x "$(PI_PKI_TOOLS)/deevnet-pki-media.sh" && -f "$(PI_PKI_TOOLS)/deevnet-pki-owner.cnf" ]] \
	  || { echo "$(RED)✗ No owner PKI tools at $(PI_PKI_TOOLS)$(NC)"; exit 1; }
	TOOLS_REF="$$(git -C "$(PI_PKI_TOOLS)" rev-parse --short HEAD)$$(git -C "$(PI_PKI_TOOLS)" diff --quiet -- . || echo -dirty)"
	M="$(VM_BACKEND_MNT)"
	sudo umount -R "$$M" 2>/dev/null || true
	sudo mkdir -p "$$M"
	LOOPDEV="$$(sudo losetup --find --partscan --show "$(VM_BACKEND_RAW)")"
	RESOLV_LINK=""
	cleanup() {
	  if [[ -n "$$RESOLV_LINK" ]]; then sudo rm -f "$$M/etc/resolv.conf"; sudo ln -s "$$RESOLV_LINK" "$$M/etc/resolv.conf"; fi
	  sudo umount -R "$$M" 2>/dev/null || true
	  sudo losetup -d "$$LOOPDEV" 2>/dev/null || true
	}
	trap cleanup EXIT
	sudo partprobe "$$LOOPDEV" 2>/dev/null || true
	sudo udevadm settle || true
	for i in {1..10}; do [[ -b "$${LOOPDEV}p1" ]] && break; sleep 0.2; done
	[[ -b "$${LOOPDEV}p1" ]] || { echo "$(RED)✗ No $${LOOPDEV}p1$(NC)"; exit 1; }
	sudo mount "$${LOOPDEV}p1" "$$M"
	sudo mount --bind /dev "$$M/dev"
	sudo mount -t proc proc "$$M/proc"
	sudo mount -t sysfs sys "$$M/sys"
	: "Debian's resolv.conf points into /run, empty in a chroot: the build host's for the build, put back after"
	if [[ -L "$$M/etc/resolv.conf" ]]; then
	  RESOLV_LINK="$$(readlink "$$M/etc/resolv.conf")"
	  sudo rm -f "$$M/etc/resolv.conf"
	  sudo cp -L /etc/resolv.conf "$$M/etc/resolv.conf"
	fi
	sudo ansible-playbook -i "$$INVENTORY" "$$PLAYBOOK" \
	  --extra-vars "medium=vm chroot_root=$$M pi_backend_inputs=$(VM_BACKEND_INPUTS) pki_tools_src=$(PI_PKI_TOOLS) pki_tools_ref=$$TOOLS_REF apt_dl_limit=$(APT_DL_LIMIT)"
	echo "$(GREEN)✓ VM backend config applied$(NC)"

# The raw disk as a compressed qcow2, with its sha256 beside it.
vm-backend-compress: $(VM_BACKEND_RAW)
	echo "$(GREEN)→ Writing the compressed qcow2...$(NC)"
	qemu-img convert -f raw -O qcow2 -c "$(VM_BACKEND_RAW)" "$(VM_BACKEND_QCOW2)"
	cd "$(CURDIR)" && sha256sum "$(VM_BACKEND_IMAGE_NAME).qcow2" > "$(VM_BACKEND_IMAGE_NAME).qcow2.sha256"
	echo "$(GREEN)✓ $(VM_BACKEND_QCOW2) ($$(du -h "$(VM_BACKEND_QCOW2)" | cut -f1))$(NC)"

# Publish beside the Pi image in the tenant downloads tree (CHG-0025). Then
# push it to the observability store as the Pi image is (--tags tenant-downloads).
vm-backend-publish:
	[[ -f "$(VM_BACKEND_QCOW2)" ]] || { echo "$(RED)✗ No $(VM_BACKEND_QCOW2): run make vm-backend$(NC)"; exit 1; }
	DEST="$(PI_BACKEND_ARTIFACTS_ROOT)/tenant/vm"
	sudo install -d -o nginx -g nginx -m 0755 "$$DEST"
	sudo install -o nginx -g nginx -m 0644 "$(VM_BACKEND_QCOW2)" "$$DEST/"
	cd "$$DEST" && sha256sum "$(VM_BACKEND_IMAGE_NAME).qcow2" | sudo tee "$(VM_BACKEND_IMAGE_NAME).qcow2.sha256" >/dev/null
	echo "$(GREEN)✓ Published $$DEST/$(VM_BACKEND_IMAGE_NAME).qcow2$(NC)"

# ------------------------------------------------------------
# Take-home installer ISO Build (CHG-0075)
# ------------------------------------------------------------
# The VM's disk (vm-backend's raw image) on a hybrid ISO, bootable on BIOS and
# UEFI, that writes it to a disk of the owner's own computer (docs/iso-backend.md).
# Everything on the ISO comes from that disk: its kernel, an installer initramfs
# made by its initramfs-tools, its GRUB for BIOS, and Debian's signed shim and
# GRUB for UEFI. The backend is built once for both media; nothing new is
# downloaded.

ISO_BACKEND_IMAGE_NAME := debian-bookworm-$(PI_IMAGE_PLATFORM)-backend-installer
ISO_BACKEND_BUILD      := $(CURDIR)/build/iso-backend
ISO_BACKEND_TREE       := $(ISO_BACKEND_BUILD)/tree
ISO_BACKEND_PAYLOAD    := $(ISO_BACKEND_BUILD)/payload
ISO_BACKEND_ISO        := $(CURDIR)/$(ISO_BACKEND_IMAGE_NAME).iso
ISO_BACKEND_LOWER      := /mnt/iso-backend-lower
ISO_BACKEND_ROOT       := /mnt/iso-backend-root
ISO_BACKEND_SRC        := $(CURDIR)/scripts/iso-installer
# The volume label the installer finds its own medium by.
ISO_BACKEND_LABEL      := DEEVNET_TAKEHOME

# Full ISO = the VM's disk, then the boot files and the payload, then the ISO
iso-backend: iso-backend-boot iso-backend-payload iso-backend-image
	echo "$(GREEN)✓ Installer ISO complete: $(ISO_BACKEND_ISO)$(NC)"

# The boot files, made inside the VM's root (read-only, under an overlay that
# is thrown away): the kernel, the installer initramfs, GRUB for BIOS, and the
# EFI system partition image with Debian's signed shim and CD GRUB.
iso-backend-boot: check-loop-devices
	[[ -f "$(VM_BACKEND_RAW)" ]] || { echo "$(RED)✗ No $(VM_BACKEND_RAW): run make vm-backend$(NC)"; exit 1; }
	echo "$(GREEN)→ Making the installer's boot files from the VM's disk...$(NC)"
	L="$(ISO_BACKEND_LOWER)"; R="$(ISO_BACKEND_ROOT)"; O="$(ISO_BACKEND_BUILD)/overlay"
	sudo umount -R "$$R" 2>/dev/null || true
	sudo umount "$$L" 2>/dev/null || true
	sudo rm -rf "$$O"
	sudo mkdir -p "$$L" "$$R" "$$O/upper" "$$O/work"
	LOOPDEV="$$(sudo losetup --read-only --find --partscan --show "$(VM_BACKEND_RAW)")"
	cleanup() {
	  sudo umount -R "$$R" 2>/dev/null || true
	  sudo umount "$$L" 2>/dev/null || true
	  sudo losetup -d "$$LOOPDEV" 2>/dev/null || true
	  sudo rm -rf "$$O"
	}
	trap cleanup EXIT
	sudo udevadm settle || true
	for i in {1..10}; do [[ -b "$${LOOPDEV}p1" ]] && break; sleep 0.2; done
	sudo mount -o ro "$${LOOPDEV}p1" "$$L"
	sudo mount -t overlay overlay -o "lowerdir=$$L,upperdir=$$O/upper,workdir=$$O/work" "$$R"
	sudo mount --bind /dev "$$R/dev"
	sudo mount -t proc proc "$$R/proc"
	sudo mount -t sysfs sys "$$R/sys"
	KVER="$$(ls "$$R/lib/modules" | sort -V | tail -1)"
	sudo cp -r "$(ISO_BACKEND_SRC)/initramfs" "$$R/tmp/deevnet-installer"
	sudo chroot "$$R" mkinitramfs -d /tmp/deevnet-installer -o /tmp/initrd.img "$$KVER"
	sudo chroot "$$R" grub-mkimage -O i386-pc-eltorito -d /usr/lib/grub/i386-pc -p /boot/grub \
	  -o /tmp/eltorito.img biosdisk iso9660 part_msdos part_gpt normal search search_fs_file configfile linux echo test halt
	T="$(ISO_BACKEND_TREE)"
	rm -rf "$$T"
	mkdir -p "$$T/live" "$$T/boot/grub/i386-pc" "$$T/.disk"
	G="$$R/usr/lib/grub"
	sudo install -m 0644 "$$R/boot/vmlinuz-$$KVER" "$$T/live/vmlinuz"
	sudo install -m 0644 "$$R/tmp/initrd.img" "$$T/live/initrd.img"
	sudo install -m 0644 "$$R/tmp/eltorito.img" "$$G"/i386-pc/*.mod "$$G"/i386-pc/*.lst "$$T/boot/grub/i386-pc/"
	sudo install -m 0644 "$$G/i386-pc/boot_hybrid.img" "$(ISO_BACKEND_BUILD)/boot_hybrid.img"
	install -m 0644 "$(ISO_BACKEND_SRC)/grub.cfg" "$$T/boot/grub/grub.cfg"
	echo "Deevnet take-home backend installer ($(ISO_BACKEND_IMAGE_NAME), kernel $$KVER)" > "$$T/.disk/info"
	: "The EFI system partition: shim as the removable path, Debian's signed CD GRUB beside it"
	E="$(ISO_BACKEND_BUILD)/efi.img"
	rm -f "$$E"
	mkfs.vfat -C -n DEEVNET_EFI "$$E" 8192 >/dev/null
	mmd -i "$$E" ::/EFI ::/EFI/BOOT
	sudo cat "$$R/usr/lib/shim/shimx64.efi.signed" | mcopy -i "$$E" - ::/EFI/BOOT/BOOTX64.EFI
	sudo cat "$$R/usr/lib/shim/mmx64.efi.signed"   | mcopy -i "$$E" - ::/EFI/BOOT/mmx64.efi
	sudo cat "$$G/x86_64-efi-signed/gcdx64.efi.signed" | mcopy -i "$$E" - ::/EFI/BOOT/grubx64.efi
	: "The same tree in the ISO's file system, for tools that copy files to a stick"
	mcopy -s -i "$$E" ::/EFI "$$T/"
	sudo chown -R "$$(id -u):$$(id -g)" "$$T" "$(ISO_BACKEND_BUILD)/boot_hybrid.img"
	echo "$(GREEN)✓ Boot files ready (kernel $$KVER)$(NC)"

# The VM's raw disk, compressed, with the sha256 and size the installer checks
# what it wrote against.
iso-backend-payload: $(ISO_BACKEND_PAYLOAD)/system.img.zst

$(ISO_BACKEND_PAYLOAD)/system.img.zst: $(VM_BACKEND_RAW)
	echo "$(GREEN)→ Compressing the VM's disk for the ISO...$(NC)"
	P="$(ISO_BACKEND_PAYLOAD)"
	mkdir -p "$$P"
	rm -f "$$P"/system.img.*
	stat -c %s "$(VM_BACKEND_RAW)" > "$$P/system.img.size.tmp"
	sha256sum < "$(VM_BACKEND_RAW)" | sed 's/ .*/  system.img/' > "$$P/system.img.sha256.tmp"
	zstd -T0 -12 -q -f "$(VM_BACKEND_RAW)" -o "$$P/system.img.zst.tmp"
	mv "$$P/system.img.size.tmp" "$$P/system.img.size"
	mv "$$P/system.img.sha256.tmp" "$$P/system.img.sha256"
	mv "$$P/system.img.zst.tmp" "$$P/system.img.zst"
	echo "$(GREEN)✓ Payload: $$(du -h "$$P/system.img.zst" | cut -f1)$(NC)"

# The hybrid ISO: El Torito for BIOS (GRUB) and UEFI (the appended EFI system
# partition), and an MBR and GPT so it also boots written to a USB stick.
iso-backend-image:
	[[ -f "$(ISO_BACKEND_TREE)/live/initrd.img" ]] || { echo "$(RED)✗ No boot files: run make iso-backend-boot$(NC)"; exit 1; }
	[[ -f "$(ISO_BACKEND_PAYLOAD)/system.img.zst" ]] || { echo "$(RED)✗ No payload: run make iso-backend-payload$(NC)"; exit 1; }
	echo "$(GREEN)→ Writing the hybrid ISO...$(NC)"
	rm -f "$(ISO_BACKEND_ISO)"
	xorriso -as mkisofs -r -J -joliet-long -iso-level 3 \
	  -V "$(ISO_BACKEND_LABEL)" -o "$(ISO_BACKEND_ISO)" \
	  --grub2-mbr "$(ISO_BACKEND_BUILD)/boot_hybrid.img" \
	  --protective-msdos-label -partition_cyl_align off -partition_offset 16 --mbr-force-bootable \
	  -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b "$(ISO_BACKEND_BUILD)/efi.img" \
	  -appended_part_as_gpt -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
	  -c /boot/grub/boot.cat \
	  -b /boot/grub/i386-pc/eltorito.img -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
	  -eltorito-alt-boot -e --interval:appended_partition_2:all:: -no-emul-boot \
	  -graft-points "$(ISO_BACKEND_TREE)" "/deevnet/=$(ISO_BACKEND_PAYLOAD)"
	cd "$(CURDIR)" && sha256sum "$(ISO_BACKEND_IMAGE_NAME).iso" > "$(ISO_BACKEND_IMAGE_NAME).iso.sha256"
	echo "$(GREEN)✓ $(ISO_BACKEND_ISO) ($$(du -h "$(ISO_BACKEND_ISO)" | cut -f1))$(NC)"

# Publish beside the VM image in the tenant downloads tree (CHG-0025), then push
# it to the observability store, throttled and detached, as the VM image was.
iso-backend-publish:
	[[ -f "$(ISO_BACKEND_ISO)" ]] || { echo "$(RED)✗ No $(ISO_BACKEND_ISO): run make iso-backend$(NC)"; exit 1; }
	DEST="$(PI_BACKEND_ARTIFACTS_ROOT)/tenant/iso"
	sudo install -d -o nginx -g nginx -m 0755 "$$DEST"
	sudo install -o nginx -g nginx -m 0644 "$(ISO_BACKEND_ISO)" "$$DEST/"
	cd "$$DEST" && sha256sum "$(ISO_BACKEND_IMAGE_NAME).iso" | sudo tee "$(ISO_BACKEND_IMAGE_NAME).iso.sha256" >/dev/null
	echo "$(GREEN)✓ Published $$DEST/$(ISO_BACKEND_IMAGE_NAME).iso$(NC)"

# ------------------------------------------------------------
# Supporting targets
# ------------------------------------------------------------

# Fetch SSH public key from artifacts
$(PI_BOOKWORM_SSH_PUBKEY_FILE):
	echo "$(YELLOW)→ Fetching SSH public key from artifacts...$(NC)"
	mkdir -p "$(dir $@)"
	curl -fsSL "$(PI_BOOKWORM_SSH_PUBKEY_URL)" -o "$@"
	test -s "$@"
	echo "$(GREEN)✓ SSH public key ready$(NC)"

# Zip base image (archiver only supports zip)
# ---------------------------------------------------------------------------
# pi-pki: the offline CA ceremony machine (Raspberry Pi 4; runbook Root of Trust)
#
# Built from the STOCK Raspberry Pi OS Lite image, not pi-bookworm-image: that
# step adds a_autoprov and its SSH key, which the ceremony machine must never
# have. No network, no radios, no SSH, one local user; deevnet-pki-sign.sh and its
# profile baked in from ansible-collection-deevnet.mgmt/scripts/pki.
# ---------------------------------------------------------------------------
PI_PKI_IMAGE_NAME := raspios-bookworm-$(PI_IMAGE_PLATFORM)-pki
PI_PKI_IMG        := $(CURDIR)/$(PI_PKI_IMAGE_NAME).img
PI_PKI_MNT        := /mnt/pi-pki-image
PI_PKI_TOOLS      := $(abspath $(CURDIR)/../ansible-collection-deevnet.mgmt/scripts/pki)
PI_PKI_PUBLISH    := /srv/deevnet-http/pi-images/pki

pi-pki: check-loop-devices pi-pki-image pi-pki-config pi-pki-compress
	echo "$(GREEN)✓ Ceremony image: $(PI_PKI_IMG).xz (sha256 in $(PI_PKI_IMG).xz.sha256)$(NC)"

pi-pki-image: $(PI_BOOKWORM_IMAGE_BASE)
	echo "$(GREEN)→ Copying the stock Raspberry Pi OS Lite image...$(NC)"
	sudo rm -f "$(PI_PKI_IMG)" "$(PI_PKI_IMG).xz" "$(PI_PKI_IMG).xz.sha256"
	cp --sparse=always "$(PI_BOOKWORM_IMAGE_BASE)" "$(PI_PKI_IMG)"
	: "4G: room for the overlay packages; first boot no longer expands it"
	truncate -s 4G "$(PI_PKI_IMG)"
	LOOPDEV="$$(sudo losetup --find --partscan --show "$(PI_PKI_IMG)")"
	trap 'sudo losetup -d "$$LOOPDEV" 2>/dev/null || true' EXIT
	sudo partprobe "$$LOOPDEV"; sudo udevadm settle
	sudo growpart "$$LOOPDEV" 2
	sudo e2fsck -f -y "$${LOOPDEV}p2" || true
	sudo resize2fs "$${LOOPDEV}p2"

pi-pki-config: $(PI_PKI_IMG)
	echo "$(GREEN)→ Configuring the ceremony image (offline Ansible)...$(NC)"
	PLAYBOOK="$(CURDIR)/ansible/playbooks/pi-pki-config.yml"
	INVENTORY="$(CURDIR)/ansible/inventories/local.yml"
	[[ -x "$(PI_PKI_TOOLS)/deevnet-pki-sign.sh" && -x "$(PI_PKI_TOOLS)/deevnet-pki-media.sh" && -x "$(PI_PKI_TOOLS)/deevnet-pki-ceremony.sh" && -f "$(PI_PKI_TOOLS)/deevnet-pki.cnf" ]] \
	  || { echo "$(RED)✗ No ceremony tools at $(PI_PKI_TOOLS)$(NC)"; exit 1; }
	TOOLS_REF="$$(git -C "$(PI_PKI_TOOLS)" rev-parse --short HEAD)$$(git -C "$(PI_PKI_TOOLS)" diff --quiet -- . || echo -dirty)"
	sudo umount -R "$(PI_PKI_MNT)" 2>/dev/null || true
	sudo mkdir -p "$(PI_PKI_MNT)"
	LOOPDEV="$$(sudo losetup --find --partscan --show "$(PI_PKI_IMG)")"
	trap 'sudo umount -R "$(PI_PKI_MNT)" 2>/dev/null || true; sudo losetup -d "$$LOOPDEV" 2>/dev/null || true' EXIT
	sudo partprobe "$$LOOPDEV" 2>/dev/null || true; sudo partx -u "$$LOOPDEV" 2>/dev/null || true; sudo udevadm settle || true
	for i in {1..10}; do [[ -b "$${LOOPDEV}p1" && -b "$${LOOPDEV}p2" ]] && break; sleep 0.2; done
	[[ -b "$${LOOPDEV}p1" && -b "$${LOOPDEV}p2" ]] || { echo "$(RED)✗ Loop partitions missing$(NC)"; exit 1; }
	sudo mount "$${LOOPDEV}p2" "$(PI_PKI_MNT)"
	sudo mount "$${LOOPDEV}p1" "$(PI_PKI_MNT)/boot/firmware"
	sudo mount --bind /dev "$(PI_PKI_MNT)/dev"
	sudo mount -t proc proc "$(PI_PKI_MNT)/proc"
	sudo mount -t sysfs sys "$(PI_PKI_MNT)/sys"
	: "Package installs in the chroot need name resolution, for the build only"
	sudo mount --bind /etc/resolv.conf "$(PI_PKI_MNT)/etc/resolv.conf"
	sudo install -m 0755 /usr/bin/qemu-aarch64-static "$(PI_PKI_MNT)/usr/bin/qemu-aarch64-static"
	sudo ansible-playbook -i "$$INVENTORY" "$$PLAYBOOK" \
	  --extra-vars "chroot_root=$(PI_PKI_MNT) pki_tools_src=$(PI_PKI_TOOLS) pki_tools_ref=$$TOOLS_REF"
	sudo umount "$(PI_PKI_MNT)/etc/resolv.conf"
	sudo rm -f "$(PI_PKI_MNT)/usr/bin/qemu-aarch64-static"

pi-pki-compress: $(PI_PKI_IMG)
	echo "$(GREEN)→ Compressing...$(NC)"
	sudo xz -f -k -6 -T0 "$(PI_PKI_IMG)"
	cd "$(dir $(PI_PKI_IMG))" && sha256sum "$(notdir $(PI_PKI_IMG)).xz" | tee "$(notdir $(PI_PKI_IMG)).xz.sha256"

pi-pki-publish:
	[[ -f "$(PI_PKI_IMG).xz" ]] || { echo "$(RED)✗ No $(PI_PKI_IMG).xz: run make pi-pki$(NC)"; exit 1; }
	sudo install -d -o nginx -g nginx -m 0755 "$(PI_PKI_PUBLISH)"
	sudo install -o nginx -g nginx -m 0644 "$(PI_PKI_IMG).xz" "$(PI_PKI_IMG).xz.sha256" "$(PI_PKI_PUBLISH)/"
	echo "$(GREEN)✓ Published $(PI_PKI_PUBLISH)/$(PI_PKI_IMAGE_NAME).img.xz$(NC)"

$(PI_BOOKWORM_IMAGE_ZIP): $(PI_BOOKWORM_IMAGE_BASE)
	echo "$(YELLOW)→ Creating zip archive of base image...$(NC)"
	cd "$(dir $<)" && zip -0 "$(notdir $@)" "$(notdir $<)"
	echo "$(GREEN)✓ Zip archive ready$(NC)"

# Download and extract base image
$(PI_BOOKWORM_IMAGE_BASE):
	echo "$(YELLOW)→ Downloading and extracting Bookworm base image...$(NC)"
	curl -fsSL "$(PI_BOOKWORM_IMAGE_XZ_URL)" | xz -d > "$@"
	echo "$(GREEN)✓ Base image ready$(NC)"

# Ensure loop devices exist
check-loop-devices:
	if [[ ! -e /dev/loop0 ]]; then
		echo "$(RED)✗ No loop devices found (/dev/loop0 missing)$(NC)"
		echo "$(YELLOW)  Create with: sudo modprobe loop$(NC)"
		exit 1
	fi
	echo "$(GREEN)✓ Loop devices available$(NC)"

# ------------------------------------------------------------
# Proxmox VM Template
# ------------------------------------------------------------
# Uses whatever TF_VAR_proxmox_* are already exported in your shell.
proxmox-fedora: init-proxmox
	cd packer/proxmox/fedora-base-image && packer build $(PACKER_EXTRA_ARGS) -var-file=fedora-$(FEDORA_RELEASE).pkrvars.hcl fedora.pkr.hcl

# Same build, with the credentials fetched for that node (never written to disk).
proxmox-fedora-pve1: init-proxmox
	$(call pve_creds,$(PVE1_HOST),$(PVE1_NODE))
	echo "$(GREEN)→ Building Fedora $(FEDORA_RELEASE) template on node $(PVE1_NODE)...$(NC)"
	cd packer/proxmox/fedora-base-image
	packer build -var storage_pool=$(PVE1_STORAGE_POOL) $(PACKER_EXTRA_ARGS) \
		-var-file=fedora-$(FEDORA_RELEASE).pkrvars.hcl fedora.pkr.hcl

proxmox-fedora-pve2: init-proxmox
	$(call pve_creds,$(PVE2_HOST),$(PVE2_NODE))
	echo "$(GREEN)→ Building Fedora $(FEDORA_RELEASE) template on node $(PVE2_NODE)...$(NC)"
	cd packer/proxmox/fedora-base-image
	packer build -var storage_pool=$(PVE2_STORAGE_POOL) $(PACKER_EXTRA_ARGS) \
		-var-file=fedora-$(FEDORA_RELEASE).pkrvars.hcl fedora.pkr.hcl

# The template tenant workloads clone (ADR-0028): fedora-tenant-<ver>, with no
# a_autoprov. Tenants live on the tenant hypervisor, so it builds there.
proxmox-fedora-tenant: init-proxmox
	$(call pve_creds,$(PVE2_HOST),$(PVE2_NODE))
	echo "$(GREEN)→ Building Fedora $(FEDORA_RELEASE) TENANT template on node $(PVE2_NODE)...$(NC)"
	cd packer/proxmox/fedora-base-image
	packer build -var flavor=tenant -var storage_pool=$(PVE2_STORAGE_POOL) $(PACKER_EXTRA_ARGS) \
		-var-file=fedora-$(FEDORA_RELEASE).pkrvars.hcl fedora.pkr.hcl

# ------------------------------------------------------------
# Proxmox credentials
# ------------------------------------------------------------
# Print exports for the current shell:  eval "`make -s pve2-env`"
pve1-env:
	$(PVE_CREDS) $(PVE1_HOST) $(PVE1_NODE)

pve2-env:
	$(PVE_CREDS) $(PVE2_HOST) $(PVE2_NODE)

# One-time cleanup: credentials used to be rendered to build/pve-env/*.env.
pve-env-clean:
	rm -rf "$(CURDIR)/build/pve-env"
	echo "$(GREEN)✓ Removed any legacy rendered Proxmox credential files$(NC)"

# ------------------------------------------------------------
# Proxmox VE Bare Metal ISO
# ------------------------------------------------------------

# Build container with Proxmox auto-install tooling
proxmox-pve-iso-container:
	echo "$(GREEN)→ Building Proxmox ISO builder container...$(NC)"
	podman build -t pve-iso-builder -f packer/proxmox/pve-iso/Containerfile packer/proxmox/pve-iso/
	echo "$(GREEN)✓ Container ready: $(PVE_ISO_CONTAINER)$(NC)"

# Download Proxmox ISO from artifacts
$(PVE_ISO_LOCAL):
	echo "$(YELLOW)→ Downloading Proxmox VE ISO...$(NC)"
	mkdir -p "$(dir $@)"
	curl -fsSL "$(PVE_ISO_URL)" -o "$@"
	test -s "$@"
	echo "$(GREEN)✓ ISO downloaded: $@$(NC)"

# Fetch SSH public key for answer file
.pve-ssh-pubkey: $(PI_BOOKWORM_SSH_PUBKEY_FILE)
	@: "Reuse the Pi SSH pubkey fetch target"

# Build ISO with embedded ZFS answer file
proxmox-pve-iso-zfs: $(PVE_ISO_LOCAL) $(PI_BOOKWORM_SSH_PUBKEY_FILE)
	echo "$(GREEN)→ Building Proxmox VE ISO with ZFS (embedded answer)...$(NC)"
	@if [[ -z "$(PVE_ROOT_PASSWORD_HASH)" ]]; then \
		echo "$(RED)✗ PVE_ROOT_PASSWORD_HASH required$(NC)"; \
		echo "$(YELLOW)  Generate with: openssl passwd -6 'yourpassword'$(NC)"; \
		exit 1; \
	fi
	mkdir -p "$(PVE_ISO_OUTPUT_DIR)"
	: "Read SSH key into variable"
	SSH_KEY="$$(cat "$(PI_BOOKWORM_SSH_PUBKEY_FILE)")"
	podman run --rm \
		-v "$(CURDIR)/packer/proxmox/pve-iso":/work:rw \
		-e PVE_HOSTNAME="$(PVE_HOSTNAME)" \
		-e PVE_DISK_SERIAL="$(PVE_DISK_SERIAL)" \
		-e PVE_TIMEZONE="$(PVE_TIMEZONE)" \
		-e PVE_COUNTRY="$(PVE_COUNTRY)" \
		-e PVE_KEYBOARD="$(PVE_KEYBOARD)" \
		-e PVE_EMAIL="$(PVE_EMAIL)" \
		-e PVE_ROOT_PASSWORD_HASH="$(PVE_ROOT_PASSWORD_HASH)" \
		-e PVE_SSH_PUBKEY="$$SSH_KEY" \
		-e PVE_FILESYSTEM=zfs \
		$(PVE_ISO_CONTAINER) \
		-c "/work/build-iso.sh embedded /work/$(PVE_ISO_FILENAME) /work/output/proxmox-ve-$(PVE_ISO_VERSION)-autoprov-zfs.iso"
	echo "$(GREEN)✓ ZFS ISO ready: $(PVE_ISO_OUTPUT_DIR)/proxmox-ve-$(PVE_ISO_VERSION)-autoprov-zfs.iso$(NC)"

# Build ISO with embedded ext4+LVM answer file
proxmox-pve-iso-ext4: $(PVE_ISO_LOCAL) $(PI_BOOKWORM_SSH_PUBKEY_FILE)
	echo "$(GREEN)→ Building Proxmox VE ISO with ext4+LVM (embedded answer)...$(NC)"
	@if [[ -z "$(PVE_ROOT_PASSWORD_HASH)" ]]; then \
		echo "$(RED)✗ PVE_ROOT_PASSWORD_HASH required$(NC)"; \
		echo "$(YELLOW)  Generate with: openssl passwd -6 'yourpassword'$(NC)"; \
		exit 1; \
	fi
	mkdir -p "$(PVE_ISO_OUTPUT_DIR)"
	: "Read SSH key into variable"
	SSH_KEY="$$(cat "$(PI_BOOKWORM_SSH_PUBKEY_FILE)")"
	podman run --rm \
		-v "$(CURDIR)/packer/proxmox/pve-iso":/work:rw \
		-e PVE_HOSTNAME="$(PVE_HOSTNAME)" \
		-e PVE_DISK_SERIAL="$(PVE_DISK_SERIAL)" \
		-e PVE_TIMEZONE="$(PVE_TIMEZONE)" \
		-e PVE_COUNTRY="$(PVE_COUNTRY)" \
		-e PVE_KEYBOARD="$(PVE_KEYBOARD)" \
		-e PVE_EMAIL="$(PVE_EMAIL)" \
		-e PVE_ROOT_PASSWORD_HASH="$(PVE_ROOT_PASSWORD_HASH)" \
		-e PVE_SSH_PUBKEY="$$SSH_KEY" \
		-e PVE_FILESYSTEM=ext4 \
		$(PVE_ISO_CONTAINER) \
		-c "/work/build-iso.sh embedded /work/$(PVE_ISO_FILENAME) /work/output/proxmox-ve-$(PVE_ISO_VERSION)-autoprov-ext4.iso"
	echo "$(GREEN)✓ ext4 ISO ready: $(PVE_ISO_OUTPUT_DIR)/proxmox-ve-$(PVE_ISO_VERSION)-autoprov-ext4.iso$(NC)"

# Build ISO for HTTP answer fetch (PXE-compatible)
proxmox-pve-iso-http: $(PVE_ISO_LOCAL)
	echo "$(GREEN)→ Building Proxmox VE ISO with HTTP answer fetch...$(NC)"
	@if [[ -z "$(PVE_ANSWER_URL)" ]]; then \
		echo "$(RED)✗ PVE_ANSWER_URL required$(NC)"; \
		echo "$(YELLOW)  Example: make proxmox-pve-iso-http PVE_ANSWER_URL=http://example.com/answer.toml$(NC)"; \
		exit 1; \
	fi
	mkdir -p "$(PVE_ISO_OUTPUT_DIR)"
	podman run --rm \
		-v "$(CURDIR)/packer/proxmox/pve-iso":/work:rw \
		-e PVE_ANSWER_URL="$(PVE_ANSWER_URL)" \
		-e PVE_CERT_FP="$(PVE_CERT_FP)" \
		$(PVE_ISO_CONTAINER) \
		-c "/work/build-iso.sh http /work/$(PVE_ISO_FILENAME) /work/output/proxmox-ve-$(PVE_ISO_VERSION)-autoprov-http.iso"
	echo "$(GREEN)✓ HTTP ISO ready: $(PVE_ISO_OUTPUT_DIR)/proxmox-ve-$(PVE_ISO_VERSION)-autoprov-http.iso$(NC)"

# Extract kernel/initrd for PXE boot
proxmox-pve-pxe: $(PVE_ISO_LOCAL)
	echo "$(GREEN)→ Extracting PXE boot artifacts...$(NC)"
	mkdir -p "$(PVE_PXE_OUTPUT_DIR)"
	podman run --rm \
		-v "$(CURDIR)/packer/proxmox/pve-iso":/work:rw \
		$(PVE_ISO_CONTAINER) \
		-c "/work/extract-pxe.sh /work/$(PVE_ISO_FILENAME) /work/pxe"
	: "Generate iPXE script from template"
	sed "s|__ARTIFACT_URL__|$(ARTIFACT_URL)/isos/proxmox|g" \
		packer/proxmox/pve-iso/ipxe-proxmox.ipxe.template \
		> "$(PVE_PXE_OUTPUT_DIR)/ipxe-proxmox.ipxe"
	echo "$(GREEN)✓ PXE artifacts ready in: $(PVE_PXE_OUTPUT_DIR)$(NC)"
	echo "$(YELLOW)  Upload linux26, initrd, and ipxe-proxmox.ipxe to artifact server$(NC)"

# Clean PVE ISO build artifacts
proxmox-pve-iso-clean:
	rm -rf "$(PVE_ISO_OUTPUT_DIR)" "$(PVE_PXE_OUTPUT_DIR)"
	rm -f "$(PVE_ISO_LOCAL)"
	rm -f packer/proxmox/pve-iso/work/*.toml
	echo "$(GREEN)✓ PVE ISO artifacts cleaned$(NC)"

# ------------------------------------------------------------
# Clean
# ------------------------------------------------------------
clean:
	rm -f packer/pi/*.img packer/pi/*.zip
	rm -f packer/pi/*-manifest.json
	rm -f "$(PI_BOOKWORM_AUTOPROV_IMG)" "$(PI_BOOKWORM_AUTOPROV_IMG).xz" "$(PI_BOOKWORM_AUTOPROV_MANIFEST)"
	rm -f "$(PI_BOOKWORM_SSH_PUBKEY_FILE)"

# ------------------------------------------------------------
# Dependency check
# ------------------------------------------------------------
check-deps:
	echo "$(YELLOW)→ Checking build dependencies...$(NC)"
	MISSING=""
	command -v packer >/dev/null || MISSING="$$MISSING packer"
	command -v ansible-playbook >/dev/null || MISSING="$$MISSING ansible"
	command -v curl >/dev/null || MISSING="$$MISSING curl"
	command -v zip >/dev/null || MISSING="$$MISSING zip"
	command -v xz >/dev/null || MISSING="$$MISSING xz"
	command -v podman >/dev/null || MISSING="$$MISSING podman"
	command -v qemu-aarch64-static >/dev/null || MISSING="$$MISSING qemu-user-static"
	command -v growpart >/dev/null || MISSING="$$MISSING cloud-utils-growpart"
	if [[ -n "$$MISSING" ]]; then
		echo "$(RED)✗ Missing dependencies:$$MISSING$(NC)"
		exit 1
	fi
	echo "$(GREEN)✓ All dependencies found$(NC)"
