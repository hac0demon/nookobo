#!/usr/bin/env bash
# scripts/deploy.sh - Interactive, gated deployment and testing tool for BNRV700
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

BOOT_IMG="${ROOT_DIR}/build/boot_linux.img"
PAYLOAD_TAR="${ROOT_DIR}/build/deploy_payload.tar.gz"
BOOT_LINUX_SH="${ROOT_DIR}/components/kernel/overlay/boot_linux.sh"

function log_info() {
    echo -e "\033[1;34m[*] $1\033[0m"
}

function log_warn() {
    echo -e "\033[1;33m[!] $1\033[0m"
}

function log_error() {
    echo -e "\033[1;31m[-] $1\033[0m"
}

function log_success() {
    echo -e "\033[1;32m[+] $1\033[0m"
}

function check_build_artifacts() {
    local missing=0
    if [ ! -f "${BOOT_IMG}" ]; then
        log_warn "Patched boot image '${BOOT_IMG}' not found. Run 'make patch-boot' first."
        missing=1
    fi
    if [ ! -f "${PAYLOAD_TAR}" ]; then
        log_warn "Rootfs payload '${PAYLOAD_TAR}' not found. Run 'make rootfs' first."
        missing=1
    fi
    if [ ! -f "${BOOT_LINUX_SH}" ]; then
        log_warn "Bootstrap script '${BOOT_LINUX_SH}' not found."
        missing=1
    fi
    return ${missing}
}

function show_device_status() {
    log_info "Scanning for connected devices..."
    echo "--- ADB Devices ---"
    adb devices 2>/dev/null || echo "adb not available or failed to query"
    echo "--- Fastboot Devices ---"
    fastboot devices 2>/dev/null || echo "fastboot not available or failed to query"
}

function tethered_test_boot() {
    log_info "=== Non-Destructive Tethered Boot Test ==="
    echo "This loads 'build/boot_linux.img' into RAM via USB fastboot without modifying internal eMMC storage."
    echo "Command to execute:"
    echo -e "  \033[1;36mfastboot boot ${BOOT_IMG}\033[0m"
    echo ""
    read -rp "Do you want to proceed with tethered test boot? (y/N): " confirm
    if [[ "${confirm}" =~ ^[Yy]$ ]]; then
        log_info "Executing: fastboot boot ${BOOT_IMG}"
        fastboot boot "${BOOT_IMG}"
        log_success "Tethered boot instruction sent. Device will boot patched kernel and ramdisk into RAM."
    else
        log_info "Tethered boot canceled by user."
    fi
}

function deploy_rootfs_twrp() {
    log_info "=== Deploy Rootfs & Bootstrapper via TWRP ADB ==="
    echo "Prerequisite: Device must be booted into TWRP recovery with /data partition mounted."
    echo "This operation will:"
    echo "  1. Create /data/linuxroot, /data/syncthing/notes, /data/books"
    echo "  2. Push components/kernel/overlay/boot_linux.sh to /data/boot_linux.sh (chmod 755)"
    echo "  3. Push build/deploy_payload.tar.gz to /data/ and extract into /data/linuxroot"
    echo "  4. Clean up /data/deploy_payload.tar.gz"
    echo ""
    read -rp "Proceed with TWRP payload deployment? (y/N): " confirm
    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        log_info "Deployment canceled by user."
        return
    fi

    log_info "Creating target directories on device..."
    adb shell "mkdir -p /data/linuxroot /data/syncthing/notes /data/syncthing/config /data/books"

    log_info "Pushing bootstrapper script to /data/boot_linux.sh..."
    adb push "${BOOT_LINUX_SH}" /data/boot_linux.sh
    adb shell "chmod 755 /data/boot_linux.sh"

    log_info "Pushing rootfs payload to /data/deploy_payload.tar.gz..."
    adb push "${PAYLOAD_TAR}" /data/deploy_payload.tar.gz

    log_info "Extracting payload into /data/linuxroot..."
    adb shell "tar -xzf /data/deploy_payload.tar.gz -C /data/linuxroot/"
    adb shell "rm -f /data/deploy_payload.tar.gz"

    log_success "Rootfs and bootstrapper successfully deployed to /data."
}

function interactive_chroot_setup() {
    log_info "=== Post-Install: Alpine Package Setup in TWRP ==="
    echo "To finalize the Alpine Linux userspace, run apk inside chroot:"
    echo "Note: 'gcompat' provides the GNU C library loader needed for KOReader."
    echo ""
    echo -e "\033[1;36m  adb shell\033[0m"
    echo -e "\033[1;36m  chroot /data/linuxroot /bin/sh\033[0m"
    echo -e "\033[1;36m  apk update\033[0m"
    echo -e "\033[1;36m  apk add gcompat syncthing netsurf-framebuffer tslib font-dejavu dropbear curl ca-certificates\033[0m"
    echo -e "\033[1;36m  exit\033[0m"
    echo ""
    read -rp "Execute chroot apk package installation automatically now via ADB? (y/N): " confirm
    if [[ "${confirm}" =~ ^[Yy]$ ]]; then
        log_info "Updating apk repositories inside chroot..."
        adb shell "chroot /data/linuxroot apk update"
        log_info "Installing runtime packages (including gcompat for KOReader)..."
        adb shell "chroot /data/linuxroot apk add gcompat syncthing netsurf-framebuffer tslib font-dejavu dropbear curl ca-certificates"
        log_success "Chroot package installation complete."
    else
        log_info "Skipping automatic package install. You can run the commands manually."
    fi
}

function flash_boot_partition() {
    log_warn "=== DANGER: PERMANENT BOOT PARTITION FLASH ==="
    echo "This writes 'build/boot_linux.img' directly to the internal eMMC boot partition."
    echo "Make sure you have thoroughly tested with 'fastboot boot' first!"
    echo ""
    read -rp "Type 'FLASH' in all caps to confirm flashing the boot partition: " confirm
    if [ "${confirm}" == "FLASH" ]; then
        log_info "Executing: fastboot flash boot ${BOOT_IMG}"
        fastboot flash boot "${BOOT_IMG}"
        read -rp "Reboot device now? (y/N): " do_reboot
        if [[ "${do_reboot}" =~ ^[Yy]$ ]]; then
            fastboot reboot
            log_success "Device rebooted."
        fi
    else
        log_info "Flash aborted. Partition was not modified."
    fi
}

function deploy_payload_sdcard() {
    log_info "=== Stage Payload via Android /sdcard ==="
    echo "This pushes 'build/deploy_payload.tar.gz' (and its .sha256 checksum) to '/sdcard/' via ADB while in Android."
    echo "When 'build/boot_linux.img' is booted, 'boot_linux.sh' verifies the checksum and auto-extracts it into /data/linuxroot."
    echo ""
    read -rp "Push payload to /sdcard now? (y/N): " confirm
    if [[ "${confirm}" =~ ^[Yy]$ ]]; then
        log_info "Pushing ${PAYLOAD_TAR} to /sdcard/deploy_payload.tar.gz..."
        adb push "${PAYLOAD_TAR}" /sdcard/deploy_payload.tar.gz
        if [ -f "${PAYLOAD_TAR}.sha256" ]; then
            adb push "${PAYLOAD_TAR}.sha256" /sdcard/deploy_payload.tar.gz.sha256
        fi
        log_success "Payload staged on /sdcard. It will be auto-extracted on first Linux boot."
    else
        log_info "Staging canceled."
    fi
}

function reboot_to_twrp() {
    log_info "Rebooting device into TWRP recovery via ADB..."
    adb reboot recovery
    log_success "Device is rebooting to recovery."
}

function reboot_to_bootloader() {
    log_info "Rebooting device into Fastboot bootloader via ADB..."
    adb reboot bootloader
    log_success "Device is rebooting to bootloader (fastboot)."
}

function print_menu() {
    echo ""
    echo "========================================================="
    echo "  BNRV700 (Quill) Alpine Linux Deployment Assistant"
    echo "========================================================="
    echo "1) Check ADB / Fastboot device status"
    echo "2) Stage rootfs payload to /sdcard (running Android ADB)"
    echo "3) Deploy rootfs and boot_linux.sh via TWRP (recovery ADB)"
    echo "4) Run Alpine package installation in chroot (recovery ADB)"
    echo "5) Non-destructive tethered test boot (fastboot boot)"
    echo "6) Reboot device to TWRP recovery (adb reboot recovery)"
    echo "7) Reboot device to Fastboot mode (adb reboot bootloader)"
    echo "8) Flash boot partition permanently (Gated Fastboot Flash)"
    echo "9) Print manual deployment runbook"
    echo "10) Exit"
    echo "========================================================="
}

function print_runbook() {
    cat << 'EOF'
=== BNRV700 Manual Deployment Runbook ===

1. Enter TWRP Recovery on the Nook.
2. Ensure /data partition is mounted:
     adb shell mount /data
3. Push bootstrapper and rootfs:
     adb shell "mkdir -p /data/linuxroot /data/syncthing/notes /data/syncthing/config /data/books"
     adb push components/kernel/overlay/boot_linux.sh /data/boot_linux.sh
     adb shell "chmod 755 /data/boot_linux.sh"
     adb push build/deploy_payload.tar.gz /data/
     adb shell "tar -xzf /data/deploy_payload.tar.gz -C /data/linuxroot/"
     adb shell "rm -f /data/deploy_payload.tar.gz"
4. Install packages inside chroot:
     adb shell
     chroot /data/linuxroot /bin/sh
     apk update
     apk add gcompat syncthing netsurf-framebuffer tslib font-dejavu dropbear curl ca-certificates
     exit
5. Non-destructive tethered boot test (Device in fastboot mode):
     fastboot boot build/boot_linux.img
6. Permanent flash once validated:
     fastboot flash boot build/boot_linux.img
     fastboot reboot
EOF
}

# Handle command-line arguments if passed
if [ "${1:-}" == "--test-boot" ]; then
    tethered_test_boot
    exit 0
elif [ "${1:-}" == "--push-rootfs" ]; then
    deploy_rootfs_twrp
    exit 0
elif [ "${1:-}" == "--runbook" ]; then
    print_runbook
    exit 0
elif [ "${1:-}" == "--help" ] || [ "${1:-}" == "-h" ]; then
    echo "Usage: $0 [--test-boot | --push-rootfs | --runbook | --help]"
    echo "Run without arguments for interactive guided deployment."
    exit 0
fi

# Interactive menu loop
while true; do
    print_menu
    read -rp "Select an option [1-10]: " choice
    case "${choice}" in
        1) show_device_status ;;
        2) deploy_payload_sdcard ;;
        3) deploy_rootfs_twrp ;;
        4) interactive_chroot_setup ;;
        5) tethered_test_boot ;;
        6) reboot_to_twrp ;;
        7) reboot_to_bootloader ;;
        8) flash_boot_partition ;;
        9) print_runbook ;;
        10) log_info "Exiting deployment tool."; exit 0 ;;
        *) log_warn "Invalid selection." ;;
    esac
done
