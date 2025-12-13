# Deevnet Image Factory
# High-level orchestration for image builds
#
# NOTE: This Makefile does NOT attempt to install dependencies or modify
# system state. All prerequisites must be pre-installed on the builder node.

.PHONY: help init validate build clean
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
	@echo "  validate        Validate all Packer configurations"
	@echo "  clean           Remove build artifacts"

# Initialize all plugins
init: init-pi init-proxmox

init-pi:
	cd packer/pi && packer init sdr-bookworm.pkr.hcl

init-proxmox:
	cd packer/proxmox && packer init fedora-43.pkr.hcl

# Validate configurations
validate:
	cd packer/pi && packer validate sdr-bookworm.pkr.hcl
	cd packer/proxmox && packer validate fedora-43.pkr.hcl

# Build targets
pi-sdr: init-pi
	cd packer/pi && packer build sdr-bookworm.pkr.hcl

proxmox-fedora: init-proxmox
	cd packer/proxmox && packer build fedora-43.pkr.hcl

# Clean build artifacts
clean:
	rm -f packer/pi/*.img
	rm -f packer/pi/*-manifest.json
	rm -f packer/proxmox/*-manifest.json
