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

.DEFAULT_GOAL := help

# Terminal colors
RED    := \033[0;31m
GREEN  := \033[0;32m
YELLOW := \033[0;33m
NC     := \033[0m

# ------------------------------------------------------------
# Artifact source of truth
# ------------------------------------------------------------
ARTIFACT_URL := http://artifacts.dvntm.deevnet.net

# ------------------------------------------------------------
# Raspberry Pi – Bookworm image pipeline
# ------------------------------------------------------------

# Image naming components
PI_IMAGE_PLATFORM := dvntm
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
PVE_HOSTNAME ?= pve.local
PVE_TIMEZONE ?= America/New_York
PVE_COUNTRY ?= us
PVE_KEYBOARD ?= en-us
PVE_EMAIL ?= root@localhost
PVE_ROOT_PASSWORD_HASH ?=
PVE_SSH_PUBKEY ?=
PVE_ANSWER_URL ?=
PVE_CERT_FP ?=

# Output paths
PVE_ISO_OUTPUT_DIR := $(CURDIR)/packer/proxmox/pve-iso/output
PVE_PXE_OUTPUT_DIR := $(CURDIR)/packer/proxmox/pve-iso/pxe

.PHONY: help init validate clean check-deps check-loop-devices
.PHONY: pi-bookworm-image pi-resize-image pi-sdr pi-sdr-config pi-compress-image
.PHONY: pi-pidp11 pi-bookworm-image-pidp11 pi-resize-image-pidp11 pi-pidp11-config pi-compress-image-pidp11
.PHONY: init-pi init-proxmox proxmox-fedora
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
	@echo "  proxmox-fedora         Build Proxmox Fedora 43 template"
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
	cd packer/proxmox/fedora-base-image && packer init fedora-43.pkr.hcl

# ------------------------------------------------------------
# Validation
# ------------------------------------------------------------
validate:
	cd packer/pi && packer validate sdr-bookworm.pkr.hcl
	cd packer/proxmox/fedora-base-image && packer validate fedora-43.pkr.hcl

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
proxmox-fedora: init-proxmox
	cd packer/proxmox/fedora-base-image && packer build fedora-43.pkr.hcl

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
