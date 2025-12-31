#!/usr/bin/env bash
#
# extract-pxe.sh - Extract PXE boot artifacts from Proxmox VE ISO
#
# Extracts kernel (linux26) and initrd from ISO for network boot.
# Based on: https://github.com/morph027/pve-iso-2-pxe
#
# Usage: extract-pxe.sh <source-iso> <output-dir>
#
# Output:
#   <output-dir>/linux26   - Kernel
#   <output-dir>/initrd    - Initial ramdisk
#
# Note: For automated installation via PXE, the ISO must be prepared
# with HTTP fetch mode using build-iso.sh first.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<EOF
Usage: $0 <source-iso> <output-dir>

Extracts kernel and initrd from Proxmox VE ISO for PXE booting.

Output files:
  <output-dir>/linux26   Kernel image
  <output-dir>/initrd    Initial ramdisk (compressed)

Boot parameters for iPXE/GRUB:
  vga=791 video=vesafb:ywrap,mtrr ramdisk_size=16777216 rw quiet splash=silent proxmox-start-auto-installer
EOF
    exit 1
}

[[ $# -ge 2 ]] || usage

SOURCE_ISO="$1"
OUTPUT_DIR="$2"

# Validate source ISO
if [[ ! -f "$SOURCE_ISO" ]]; then
    log_error "Source ISO not found: $SOURCE_ISO"
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Create temp directory for extraction
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

log_info "Extracting PXE artifacts from: $SOURCE_ISO"

# Mount ISO
MOUNT_POINT="${TMPDIR}/iso"
mkdir -p "$MOUNT_POINT"

# Extract files using xorriso (works without root/mounting)
log_info "Extracting kernel and initrd..."

# Extract kernel
xorriso -osirrox on -indev "$SOURCE_ISO" \
    -extract /boot/linux26 "${OUTPUT_DIR}/linux26" 2>/dev/null || {
    # Try alternative path for older ISOs
    xorriso -osirrox on -indev "$SOURCE_ISO" \
        -extract /linux26 "${OUTPUT_DIR}/linux26" 2>/dev/null || {
        log_error "Failed to extract kernel from ISO"
        exit 1
    }
}

# Extract initrd
xorriso -osirrox on -indev "$SOURCE_ISO" \
    -extract /boot/initrd.img "${OUTPUT_DIR}/initrd" 2>/dev/null || {
    # Try alternative path
    xorriso -osirrox on -indev "$SOURCE_ISO" \
        -extract /boot/initrd "${OUTPUT_DIR}/initrd" 2>/dev/null || {
        xorriso -osirrox on -indev "$SOURCE_ISO" \
            -extract /initrd.img "${OUTPUT_DIR}/initrd" 2>/dev/null || {
            log_error "Failed to extract initrd from ISO"
            exit 1
        }
    }
}

# Verify files
if [[ ! -f "${OUTPUT_DIR}/linux26" ]]; then
    log_error "Kernel extraction failed"
    exit 1
fi

if [[ ! -f "${OUTPUT_DIR}/initrd" ]]; then
    log_error "Initrd extraction failed"
    exit 1
fi

# Get file info
KERNEL_SIZE=$(stat -c%s "${OUTPUT_DIR}/linux26")
INITRD_SIZE=$(stat -c%s "${OUTPUT_DIR}/initrd")

log_info "Extraction complete!"
log_info "  Kernel: ${OUTPUT_DIR}/linux26 ($(numfmt --to=iec-i --suffix=B "$KERNEL_SIZE"))"
log_info "  Initrd: ${OUTPUT_DIR}/initrd ($(numfmt --to=iec-i --suffix=B "$INITRD_SIZE"))"

# Warn about large initrd for TFTP
if [[ "$INITRD_SIZE" -gt 536870912 ]]; then  # 512MB
    log_warn "Initrd is $(numfmt --to=iec-i --suffix=B "$INITRD_SIZE") - too large for TFTP"
    log_warn "Use iPXE with HTTP boot instead of traditional TFTP"
fi

log_info ""
log_info "iPXE boot example:"
log_info "  kernel http://server/linux26 vga=791 video=vesafb:ywrap,mtrr ramdisk_size=16777216 rw quiet splash=silent proxmox-start-auto-installer"
log_info "  initrd http://server/initrd"
log_info "  boot"
