#!/usr/bin/env bash
#
# build-iso.sh - Build customized Proxmox VE automated installer ISO
#
# This script runs INSIDE the container and performs:
#   1. Render answer file template with variable substitution
#   2. Validate the answer file
#   3. Prepare the ISO with proxmox-auto-install-assistant
#   4. Generate a manifest
#
# Usage: build-iso.sh <mode> <source-iso> <output-iso>
#   mode: "embedded" or "http"
#
# Environment variables for template substitution:
#   PVE_HOSTNAME     - FQDN (default: pve.local)
#   PVE_TIMEZONE     - Timezone (default: America/New_York)
#   PVE_COUNTRY      - Country code (default: us)
#   PVE_KEYBOARD     - Keyboard layout (default: en-us)
#   PVE_EMAIL        - Admin email (default: root@localhost)
#   PVE_ROOT_PASSWORD_HASH - Root password hash (required for embedded)
#   PVE_SSH_PUBKEY   - SSH public key (optional)
#   PVE_ANSWER_URL   - Answer file URL (required for http mode)
#   PVE_CERT_FP      - HTTPS certificate fingerprint (optional, for http mode)
#   PVE_FILESYSTEM   - Filesystem type: zfs or ext4 (default: zfs)

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
Usage: $0 <mode> <source-iso> <output-iso>

Modes:
  embedded   Embed answer file directly in ISO
  http       Configure ISO to fetch answer from URL at boot

Environment variables:
  PVE_HOSTNAME           FQDN (default: pve.local)
  PVE_TIMEZONE           Timezone (default: America/New_York)
  PVE_COUNTRY            Country code (default: us)
  PVE_KEYBOARD           Keyboard layout (default: en-us)
  PVE_EMAIL              Admin email (default: root@localhost)
  PVE_ROOT_PASSWORD_HASH Root password hash (required for embedded)
  PVE_SSH_PUBKEY         SSH public key (optional)
  PVE_ANSWER_URL         Answer file URL (required for http mode)
  PVE_CERT_FP            HTTPS cert fingerprint (optional)
  PVE_FILESYSTEM         zfs or ext4 (default: zfs)
EOF
    exit 1
}

# Defaults
: "${PVE_HOSTNAME:=pve.local}"
: "${PVE_TIMEZONE:=America/New_York}"
: "${PVE_COUNTRY:=us}"
: "${PVE_KEYBOARD:=en-us}"
: "${PVE_EMAIL:=root@localhost}"
: "${PVE_ROOT_PASSWORD_HASH:=}"
: "${PVE_SSH_PUBKEY:=}"
: "${PVE_ANSWER_URL:=}"
: "${PVE_CERT_FP:=}"
: "${PVE_FILESYSTEM:=zfs}"

[[ $# -ge 3 ]] || usage

MODE="$1"
SOURCE_ISO="$2"
OUTPUT_ISO="$3"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/work"
ANSWER_FILE="${WORK_DIR}/answer.toml"

# Validate mode
case "$MODE" in
    embedded|http) ;;
    *) log_error "Invalid mode: $MODE (must be 'embedded' or 'http')"; exit 1 ;;
esac

# Validate source ISO exists
if [[ ! -f "$SOURCE_ISO" ]]; then
    log_error "Source ISO not found: $SOURCE_ISO"
    exit 1
fi

# Setup work directory
mkdir -p "$WORK_DIR"

# Select template based on filesystem
TEMPLATE_FILE="${SCRIPT_DIR}/answer-${PVE_FILESYSTEM}.toml.template"
if [[ ! -f "$TEMPLATE_FILE" ]]; then
    log_error "Template not found: $TEMPLATE_FILE"
    exit 1
fi

log_info "Building Proxmox VE ISO (mode: $MODE, fs: $PVE_FILESYSTEM)"
log_info "Source: $SOURCE_ISO"
log_info "Output: $OUTPUT_ISO"

if [[ "$MODE" == "embedded" ]]; then
    # Require password hash for embedded mode
    if [[ -z "$PVE_ROOT_PASSWORD_HASH" ]]; then
        log_error "PVE_ROOT_PASSWORD_HASH is required for embedded mode"
        log_info "Generate with: openssl passwd -6 'yourpassword'"
        exit 1
    fi

    log_info "Rendering answer file template..."

    # Format SSH keys for TOML array
    SSH_KEYS_TOML=""
    if [[ -n "$PVE_SSH_PUBKEY" ]]; then
        # Handle multiple keys (newline-separated)
        while IFS= read -r key; do
            [[ -n "$key" ]] && SSH_KEYS_TOML+="    \"${key}\",\n"
        done <<< "$PVE_SSH_PUBKEY"
        # Remove trailing comma and newline
        SSH_KEYS_TOML="${SSH_KEYS_TOML%,\\n}"
    fi

    # Render template
    sed \
        -e "s|__PVE_HOSTNAME__|${PVE_HOSTNAME}|g" \
        -e "s|__PVE_TIMEZONE__|${PVE_TIMEZONE}|g" \
        -e "s|__PVE_COUNTRY__|${PVE_COUNTRY}|g" \
        -e "s|__PVE_KEYBOARD__|${PVE_KEYBOARD}|g" \
        -e "s|__PVE_EMAIL__|${PVE_EMAIL}|g" \
        -e "s|__PVE_ROOT_PASSWORD_HASH__|${PVE_ROOT_PASSWORD_HASH}|g" \
        "$TEMPLATE_FILE" > "$ANSWER_FILE"

    # Insert SSH keys (multi-line)
    if [[ -n "$SSH_KEYS_TOML" ]]; then
        # Use awk to replace the placeholder with actual keys
        awk -v keys="$SSH_KEYS_TOML" '{
            gsub(/__PVE_SSH_PUBKEYS__/, keys)
            print
        }' "$ANSWER_FILE" > "${ANSWER_FILE}.tmp" && mv "${ANSWER_FILE}.tmp" "$ANSWER_FILE"
    else
        # Remove empty SSH keys placeholder
        sed -i 's|__PVE_SSH_PUBKEYS__||g' "$ANSWER_FILE"
    fi

    log_info "Validating answer file..."
    if ! proxmox-auto-install-assistant validate-answer "$ANSWER_FILE"; then
        log_error "Answer file validation failed"
        cat "$ANSWER_FILE"
        exit 1
    fi

    log_info "Preparing ISO with embedded answer file..."
    proxmox-auto-install-assistant prepare-iso \
        --fetch-from iso \
        --answer-file "$ANSWER_FILE" \
        "$SOURCE_ISO" \
        --output "$OUTPUT_ISO"

elif [[ "$MODE" == "http" ]]; then
    # Require answer URL for http mode
    if [[ -z "$PVE_ANSWER_URL" ]]; then
        log_error "PVE_ANSWER_URL is required for http mode"
        exit 1
    fi

    log_info "Preparing ISO with HTTP answer fetch..."

    CERT_ARGS=""
    if [[ -n "$PVE_CERT_FP" ]]; then
        CERT_ARGS="--cert-fingerprint $PVE_CERT_FP"
    fi

    # shellcheck disable=SC2086
    proxmox-auto-install-assistant prepare-iso \
        --fetch-from http \
        --url "$PVE_ANSWER_URL" \
        $CERT_ARGS \
        "$SOURCE_ISO" \
        --output "$OUTPUT_ISO"
fi

# Generate manifest
MANIFEST_FILE="${OUTPUT_ISO%.iso}-manifest.json"
log_info "Generating manifest: $MANIFEST_FILE"

cat > "$MANIFEST_FILE" <<EOF
{
  "source_iso": "$(basename "$SOURCE_ISO")",
  "output_iso": "$(basename "$OUTPUT_ISO")",
  "mode": "$MODE",
  "filesystem": "$PVE_FILESYSTEM",
  "hostname": "$PVE_HOSTNAME",
  "build_date": "$(date -Iseconds)",
  "builder": "pve-iso-builder"
}
EOF

log_info "Build complete!"
log_info "  ISO: $OUTPUT_ISO"
log_info "  Manifest: $MANIFEST_FILE"
