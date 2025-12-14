# Deevnet Image Factory
# High-level orchestration for image builds
#
# NOTE: This Makefile does NOT attempt to install dependencies or modify
# system state. All prerequisites must be pre-installed on the builder node.

# Terminal colors
RED    := \033[0;31m
GREEN  := \033[0;32m
YELLOW := \033[0;33m
NC     := \033[0m

.PHONY: help init validate build clean check-deps
.PHONY: pi-sdr proxmox-fedora
.PHONY: init-pi init-proxmox

# Default target
help:
	@echo "Deevnet Image Factory"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@echo "Initialization:"
	@echo "  init            Initialize all Packer plugins"
	@echo "  init-pi         Initialize Raspberry Pi plugins"
	@echo "  init-proxmox    Initialize Proxmox plugins"
	@echo ""
	@echo "Build targets:"
	@echo "  pi-sdr          Build Raspberry Pi SDR image"
	@echo "  proxmox-fedora  Build Proxmox Fedora 43 template"
	@echo ""
	@echo "Utilities:"
	@echo "  check-deps      Check for required build dependencies"
	@echo "  validate        Validate all Packer configurations"
	@echo "  clean           Remove build artifacts"

# Initialize all plugins
init: init-pi init-proxmox

init-pi:
	cd packer/pi && packer init sdr-bookworm.pkr.hcl

init-proxmox:
	cd packer/proxmox/fedora-base-image && packer init fedora-43.pkr.hcl

# Validate configurations
validate:
	cd packer/pi && packer validate sdr-bookworm.pkr.hcl
	cd packer/proxmox/fedora-base-image && packer validate fedora-43.pkr.hcl

# Build targets
pi-sdr: init-pi
	cd packer/pi && packer build sdr-bookworm.pkr.hcl

proxmox-fedora: init-proxmox
	cd packer/proxmox/fedora-base-image && packer build fedora-43.pkr.hcl

# Clean build artifacts
clean:
	rm -f packer/pi/*.img
	rm -f packer/pi/*-manifest.json
	rm -f packer/proxmox/*-manifest.json

# Check for required build dependencies
check-deps:
	@echo "$(YELLOW)→ Checking build dependencies...$(NC)"
	@MISSING=""; \
	command -v packer &> /dev/null || MISSING="$$MISSING packer"; \
	command -v go &> /dev/null || MISSING="$$MISSING go"; \
	command -v ansible &> /dev/null || MISSING="$$MISSING ansible"; \
	command -v curl &> /dev/null || MISSING="$$MISSING curl"; \
	command -v wget &> /dev/null || MISSING="$$MISSING wget"; \
	command -v tree &> /dev/null || MISSING="$$MISSING tree"; \
	command -v qemu-aarch64-static &> /dev/null || MISSING="$$MISSING qemu-aarch64-static(qemu-user-static)"; \
	command -v qemu-system-x86_64 &> /dev/null || MISSING="$$MISSING qemu-system-x86_64"; \
	command -v qemu-img &> /dev/null || MISSING="$$MISSING qemu-img"; \
	command -v virsh &> /dev/null || MISSING="$$MISSING virsh(libvirt)"; \
	command -v xorriso &> /dev/null || MISSING="$$MISSING xorriso"; \
	command -v genisoimage &> /dev/null || MISSING="$$MISSING genisoimage"; \
	command -v unsquashfs &> /dev/null || MISSING="$$MISSING unsquashfs(squashfs-tools)"; \
	command -v mksquashfs &> /dev/null || MISSING="$$MISSING mksquashfs(squashfs-tools)"; \
	if [ -n "$$MISSING" ]; then \
		echo "$(RED)✗ Missing dependencies:$$MISSING$(NC)"; \
		echo "$(YELLOW)  On Fedora, install with:$(NC)"; \
		echo "$(YELLOW)    sudo dnf install packer golang ansible-core curl wget tree \\$(NC)"; \
		echo "$(YELLOW)                      qemu-user-static qemu-system-x86 qemu-img \\$(NC)"; \
		echo "$(YELLOW)                      libvirt libvirt-client xorriso genisoimage squashfs-tools$(NC)"; \
		echo "$(YELLOW)  Note: Packer may require adding HashiCorp repo first:$(NC)"; \
		echo "$(YELLOW)    sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/fedora/hashicorp.repo$(NC)"; \
		exit 1; \
	fi
	@if ! groups | grep -qw libvirt; then \
		echo "$(RED)✗ User '$(USER)' is not in the libvirt group$(NC)"; \
		echo "$(YELLOW)  Add with: sudo usermod -a -G libvirt $(USER)$(NC)"; \
		echo "$(YELLOW)  Then log out and back in$(NC)"; \
		exit 1; \
	fi
	@if ! systemctl is-active --quiet libvirtd; then \
		echo "$(RED)✗ libvirtd service is not running$(NC)"; \
		echo "$(YELLOW)  Start with: sudo systemctl enable --now libvirtd$(NC)"; \
		exit 1; \
	fi
	@if [ ! -e /dev/kvm ]; then \
		echo "$(RED)✗ /dev/kvm not found — KVM acceleration unavailable$(NC)"; \
		echo "$(YELLOW)  Your system may not support virtualization or BIOS VT-x/AMD-V is disabled$(NC)"; \
		exit 1; \
	fi
	@if ! lsmod | grep -qw kvm; then \
		echo "$(RED)✗ KVM kernel module is not loaded$(NC)"; \
		echo "$(YELLOW)  Load with: sudo modprobe kvm && sudo modprobe kvm_amd  # or kvm_intel$(NC)"; \
		exit 1; \
	fi
	@if ! groups | grep -qw kvm; then \
		echo "$(RED)✗ User '$(USER)' is not in the kvm group$(NC)"; \
		echo "$(YELLOW)  Add with: sudo usermod -aG kvm $(USER)$(NC)"; \
		echo "$(YELLOW)  Then log out and back in$(NC)"; \
		exit 1; \
	fi
	@if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then \
		echo "$(RED)✗ User '$(USER)' does not have permission to access /dev/kvm$(NC)"; \
		echo "$(YELLOW)  Fix with: sudo chown root:kvm /dev/kvm && sudo chmod 660 /dev/kvm$(NC)"; \
		exit 1; \
	fi
	@echo "$(GREEN)✓ All dependencies found$(NC)"
