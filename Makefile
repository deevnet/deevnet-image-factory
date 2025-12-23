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

.PHONY: help init validate clean check-deps check-loop-devices
.PHONY: pi-bookworm-image pi-sdr pi-sdr-config
.PHONY: init-pi init-proxmox proxmox-fedora

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
	@echo "  proxmox-fedora         Build Proxmox Fedora 43 template"
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

# Full SDR image = base image + offline config
pi-sdr: pi-bookworm-image pi-sdr-config
	echo "$(GREEN)✓ Pi SDR image complete: $(PI_BOOKWORM_AUTOPROV_IMG)$(NC)"

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
# Proxmox
# ------------------------------------------------------------
proxmox-fedora: init-proxmox
	cd packer/proxmox/fedora-base-image && packer build fedora-43.pkr.hcl

# ------------------------------------------------------------
# Clean
# ------------------------------------------------------------
clean:
	rm -f packer/pi/*.img packer/pi/*.zip
	rm -f packer/pi/*-manifest.json
	rm -f "$(PI_BOOKWORM_AUTOPROV_IMG)" "$(PI_BOOKWORM_AUTOPROV_MANIFEST)"
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
	if [[ -n "$$MISSING" ]]; then
		echo "$(RED)✗ Missing dependencies:$$MISSING$(NC)"
		exit 1
	fi
	echo "$(GREEN)✓ All dependencies found$(NC)"
