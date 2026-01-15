#!/bin/bash
#
# CaribouLite SDR Validation Script
# Validates OS configuration and tests SDR hardware functionality
#
# Usage: cariboulite-validate.sh [--quick|--full|--rf-test]
#   --quick   : OS checks only (kernel modules, boot config, device nodes)
#   --full    : OS checks + SoapySDR detection + hardware self-test (default)
#   --rf-test : Full test + RF capture and analysis (requires numpy/scipy)
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# Test mode
TEST_MODE="${1:---full}"

pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((++PASS_COUNT)) || true
}

fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((++FAIL_COUNT)) || true
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    ((++WARN_COUNT)) || true
}

info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

header() {
    echo ""
    echo -e "${CYAN}=== $1 ===${NC}"
}

# ============================================================
# OS Configuration Checks
# ============================================================

check_kernel_modules() {
    header "Kernel Modules"

    # Check smi_stream_dev
    if lsmod | grep -q "smi_stream_dev"; then
        pass "smi_stream_dev module loaded"
    else
        fail "smi_stream_dev module NOT loaded"
        info "Run: sudo modprobe smi_stream_dev"
    fi

    # Check bcm2835_smi
    if lsmod | grep -q "bcm2835_smi"; then
        pass "bcm2835_smi module loaded"
    else
        fail "bcm2835_smi module NOT loaded"
    fi

    # Check blacklist is working
    if lsmod | grep -q "bcm2835_smi_dev"; then
        warn "bcm2835_smi_dev loaded (should be blacklisted)"
    else
        pass "bcm2835_smi_dev correctly blacklisted"
    fi
}

check_boot_config() {
    header "Boot Configuration"

    local config_txt=""
    if [[ -f /boot/firmware/config.txt ]]; then
        config_txt="/boot/firmware/config.txt"
    elif [[ -f /boot/config.txt ]]; then
        config_txt="/boot/config.txt"
    else
        fail "config.txt not found"
        return
    fi

    info "Checking $config_txt"

    # Check i2c_vc is enabled
    if grep -q "^dtparam=i2c_vc=on" "$config_txt"; then
        pass "dtparam=i2c_vc=on is enabled"
    else
        fail "dtparam=i2c_vc=on is NOT enabled (required for EEPROM)"
    fi

    # Check spi1-3cs overlay
    if grep -q "^dtoverlay=spi1-3cs" "$config_txt"; then
        pass "dtoverlay=spi1-3cs is enabled"
    else
        fail "dtoverlay=spi1-3cs is NOT enabled (required for modem/FPGA)"
    fi

    # Check standard SPI is disabled
    if grep -q "^dtparam=spi=on" "$config_txt"; then
        warn "dtparam=spi=on is enabled (should be commented out)"
    else
        pass "dtparam=spi=on correctly disabled"
    fi

    # Check standard I2C is disabled
    if grep -q "^dtparam=i2c_arm=on" "$config_txt"; then
        warn "dtparam=i2c_arm=on is enabled (should be commented out)"
    else
        pass "dtparam=i2c_arm=on correctly disabled"
    fi
}

check_device_nodes() {
    header "Device Nodes"

    # Check /dev/smi
    if [[ -c /dev/smi ]]; then
        pass "/dev/smi character device exists"
        local perms
        perms=$(stat -c "%a" /dev/smi)
        if [[ "$perms" == "666" ]]; then
            pass "/dev/smi has correct permissions (666)"
        else
            warn "/dev/smi permissions are $perms (expected 666)"
        fi
    else
        fail "/dev/smi device NOT found"
    fi

    # Check SPI devices
    if ls /dev/spidev1.* >/dev/null 2>&1; then
        pass "SPI1 devices present (/dev/spidev1.*)"
    else
        warn "SPI1 devices not found"
    fi

    # Check I2C
    if [[ -c /dev/i2c-10 ]] || [[ -c /dev/i2c-0 ]]; then
        pass "I2C device present"
    else
        warn "I2C device not found (may be OK if using different bus)"
    fi
}

check_modprobe_config() {
    header "Modprobe Configuration"

    if [[ -f /etc/modprobe.d/smi_stream_mod_cariboulite.conf ]]; then
        pass "SMI stream module config exists"
        local opts
        opts=$(grep "^options" /etc/modprobe.d/smi_stream_mod_cariboulite.conf 2>/dev/null || echo "")
        if [[ -n "$opts" ]]; then
            info "$opts"
        fi
    else
        warn "SMI stream module config not found (created by install.sh)"
    fi

    if [[ -f /etc/modprobe.d/blacklist-bcm_smi.conf ]]; then
        pass "BCM SMI blacklist config exists"
    else
        warn "BCM SMI blacklist config not found (created by install.sh)"
    fi
}

# ============================================================
# SoapySDR Tests
# ============================================================

check_soapysdr_find() {
    header "SoapySDR Device Detection"

    if ! command -v SoapySDRUtil &>/dev/null; then
        fail "SoapySDRUtil not found in PATH"
        return
    fi

    local output
    if output=$(SoapySDRUtil --find 2>&1); then
        # Check for Cariboulite (handle both "driver=Cariboulite" and "driver = Cariboulite")
        if echo "$output" | grep -qi "driver.*=.*Cariboulite"; then
            pass "CaribouLite device detected by SoapySDR"

            if echo "$output" | grep -q "channel = S1G"; then
                pass "S1G channel found (389-510 MHz, 779-1020 MHz)"
            fi

            if echo "$output" | grep -q "channel = HiF"; then
                pass "HiF channel found (1-6000 MHz)"
            fi
        else
            fail "CaribouLite device NOT detected"
            info "Output: $output"
        fi
    else
        fail "SoapySDRUtil --find failed"
        info "Error: $output"
    fi
}

check_soapysdr_probe() {
    header "SoapySDR Device Probe"

    if ! command -v SoapySDRUtil &>/dev/null; then
        return
    fi

    local output
    if output=$(SoapySDRUtil --probe="driver=Cariboulite" 2>&1); then
        if echo "$output" | grep -q "hardware=Cariboulite"; then
            pass "SoapySDR probe successful"

            # Extract hardware info
            local hw_rev
            hw_rev=$(echo "$output" | grep "hardware_revision" | head -1 || echo "")
            if [[ -n "$hw_rev" ]]; then
                info "$hw_rev"
            fi

            local serial
            serial=$(echo "$output" | grep "serial_number" | head -1 || echo "")
            if [[ -n "$serial" ]]; then
                info "$serial"
            fi
        else
            warn "Probe returned but hardware info missing"
        fi
    else
        fail "SoapySDR probe failed"
    fi
}

# ============================================================
# Hardware Self-Test
# ============================================================

run_hardware_test() {
    header "Hardware Self-Test"

    local test_app="/opt/cariboulite/build/cariboulite_test_app"

    if [[ ! -x "$test_app" ]]; then
        warn "cariboulite_test_app not found (run install.sh first)"
        return
    fi

    info "Running hardware self-test..."

    local output
    # Strip ANSI color codes for reliable grep matching
    output=$("$test_app" 2>&1 | head -60 | sed 's/\x1b\[[0-9;]*m//g') || true

    if [[ -z "$output" ]]; then
        fail "Hardware test application produced no output"
        return
    fi

    # Check for FPGA
    if echo "$output" | grep -qi "FPGA.*operational\|FPGA.*running\|FPGA.*programming"; then
        pass "FPGA initialized successfully"
    else
        warn "FPGA status unclear"
    fi

    # Check for modem
    if echo "$output" | grep -qi "AT86RF215\|Modem.*Version\|at86rf215"; then
        pass "AT86RF215 modem detected"
    else
        warn "Modem detection unclear"
    fi

    # Check for mixer
    if echo "$output" | grep -qi "RFFC507\|rffc507"; then
        pass "RFFC5072 mixer detected"
    else
        warn "Mixer detection unclear"
    fi

    # Check for board detection
    if echo "$output" | grep -qi "CaribouLite.*FULL\|Product.*CaribouLite"; then
        pass "CaribouLite board detected"
    else
        warn "Board detection unclear"
    fi
}

# ============================================================
# RF Capture Test
# ============================================================

run_rf_test() {
    header "RF Capture Test"

    local capture_file="/tmp/cariboulite_test_capture.cs16"
    local freq=100000000  # 100 MHz FM band
    local samples=500000  # ~125ms at 4MSps

    # Check for cariboulite_util
    if ! command -v cariboulite_util &>/dev/null; then
        warn "cariboulite_util not found in PATH"
        return
    fi

    info "Capturing RF samples at 100 MHz..."

    # Capture samples using HiF channel (channel 1)
    if cariboulite_util -c 1 -f $freq -g 50 -n $samples "$capture_file" 2>&1; then
        if [[ -f "$capture_file" ]]; then
            local file_size
            file_size=$(stat -c%s "$capture_file")

            if [[ $file_size -gt 0 ]]; then
                pass "RF capture successful ($file_size bytes)"

                # Quick validation - read first 256 bytes only
                local zero_check
                zero_check=$(head -c 256 "$capture_file" | od -A n -t x1 | tr -d ' \n')
                if [[ "$zero_check" =~ ^0+$ ]]; then
                    fail "Captured data is all zeros (hardware issue)"
                else
                    pass "Captured data contains valid samples"
                fi
            else
                fail "Capture file is empty"
            fi

            rm -f "$capture_file"
        else
            fail "Capture file not created"
        fi
    else
        fail "RF capture command failed"
    fi
}

# ============================================================
# Summary
# ============================================================

print_summary() {
    echo ""
    echo -e "${CYAN}============================================${NC}"
    echo -e "${CYAN}           VALIDATION SUMMARY${NC}"
    echo -e "${CYAN}============================================${NC}"
    echo ""
    echo -e "  ${GREEN}Passed:${NC}   $PASS_COUNT"
    echo -e "  ${RED}Failed:${NC}   $FAIL_COUNT"
    echo -e "  ${YELLOW}Warnings:${NC} $WARN_COUNT"
    echo ""

    if [[ $FAIL_COUNT -eq 0 ]]; then
        echo -e "${GREEN}All critical tests passed!${NC}"
        if [[ $WARN_COUNT -gt 0 ]]; then
            echo -e "${YELLOW}Some warnings may need attention.${NC}"
        fi
        return 0
    else
        echo -e "${RED}Some tests failed. Please review above.${NC}"
        return 1
    fi
}

# ============================================================
# Main
# ============================================================

main() {
    echo ""
    echo -e "${CYAN}CaribouLite SDR Validation${NC}"
    echo -e "${CYAN}==========================${NC}"
    echo ""
    info "Test mode: $TEST_MODE"
    info "Hostname: $(hostname)"
    info "Kernel: $(uname -r)"
    info "Date: $(date)"

    # Always run OS checks
    check_kernel_modules
    check_boot_config
    check_device_nodes
    check_modprobe_config

    # Full mode adds SoapySDR and hardware tests
    if [[ "$TEST_MODE" == "--full" ]] || [[ "$TEST_MODE" == "--rf-test" ]]; then
        check_soapysdr_find
        check_soapysdr_probe
        run_hardware_test
    fi

    # RF test mode adds capture test
    if [[ "$TEST_MODE" == "--rf-test" ]]; then
        run_rf_test
    fi

    print_summary
}

# Show help
if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    echo "CaribouLite SDR Validation Script"
    echo ""
    echo "Usage: $0 [--quick|--full|--rf-test]"
    echo ""
    echo "Options:"
    echo "  --quick   OS checks only (kernel modules, boot config, devices)"
    echo "  --full    OS checks + SoapySDR + hardware self-test (default)"
    echo "  --rf-test Full test + RF capture verification"
    echo ""
    echo "Exit codes:"
    echo "  0 - All critical tests passed"
    echo "  1 - One or more tests failed"
    exit 0
fi

main
