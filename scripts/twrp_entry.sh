#!/usr/bin/env bash
# scripts/twrp_entry.sh - Get the BNRV700 (Quill) into Ryogo's TWRP and prepare /data.
#
# Ryogo TWRP for this board (nook_ntx_6sl, a.k.a. "Quill"):
#   project : https://github.com/Ryogo-X/nook_ntx_6sl_twrp
#   release : 3.3.1.v2
#   asset   : twrp_quill.img   (device-specific recovery image)
#
# Entering TWRP recovery (once TWRP is installed) is done by the hardware key
# method below, or `adb reboot recovery` from the running OS.
#
# The one-time install writes the recovery partition via fastboot.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TWRP_REPO="Ryogo-X/nook_ntx_6sl_twrp"
TWRP_TAG="3.3.1.v2"
TWRP_IMAGE="twrp_quill.img"
TWRP_URL="https://github.com/Ryogo-X/nook_ntx_6sl_twrp/releases/download/3.3.1.v2/twrp_quill.img"
TWRP_SIZE=8067072
DOWNLOADS_DIR="${ROOT_DIR}/downloads"
TWRP_LOCAL="${DOWNLOADS_DIR}/${TWRP_IMAGE}"

# --- logging (matches scripts/deploy.sh style) ---
log_info() { echo -e "\033[1;34m[*] $*\033[0m"; }
log_warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
log_error() { echo -e "\033[1;31m[-] $*\033[0m" >&2; }
log_success() { echo -e "\033[1;32m[+] $*\033[0m"; }

function print_workflow() {
    cat <<EOF
======================================================================
 Getting to Ryogo's TWRP on the BNRV700 (Quill)
======================================================================

 A. One-time install (write TWRP to the recovery partition, then never
    repeat):
      1. Enter fastboot:   adb reboot fastboot
         (or power off, then hold Power + Home ~8 s until the display
         flashes, then connect USB)
      2. Verify:           fastboot devices
      3. Flash TWRP:       fastboot flash recovery ${TWRP_LOCAL}
      4. Reboot:           fastboot reboot
    Image: ${TWRP_IMAGE} from ${TWRP_REPO} release ${TWRP_TAG}.
    (Fetch it any time with:  bash "$0" --download)

 B. Enter TWRP recovery afterward - hardware key method:
      1. Power off your Nook completely.
      2. Connect the device to your computer using a USB cable (this
         ensures stable detection and helps trigger the proper boot
         cycle).
      3. Give a short press to the Power button, then release it.
      4. Immediately press and hold the Home button (the "n" button)
         right after releasing the power button.
      5. Keep holding the Home button until the device boots into the
         TWRP recovery interface.
    Alternative (no key fiddling): from the running OS,  adb reboot recovery

 C. Prepare /data for the rootfs payload (while in TWRP):
      1. In TWRP, mount Data. Or from the host:  adb shell mount /data
      2. Verify recovery ADB:  adb get-state   (expect "recovery")

 Reference: XDA "[GP, G3, GP7.8] TWRP & alternative firmware", page 4.
======================================================================
EOF
}

function verify_twrp_image() {
    local size magic
    size="$(stat -c %s "${TWRP_LOCAL}" 2>/dev/null || echo 0)"
    magic="$(head -c 8 "${TWRP_LOCAL}" 2>/dev/null)"
    if [ "${magic}" != "ANDROID!" ]; then
        log_error "Bad TWRP image: missing 'ANDROID!' boot header in ${TWRP_LOCAL}"
        return 1
    fi
    if [ "${size}" -ne "${TWRP_SIZE}" ]; then
        log_warn "TWRP image size is ${size} (expected ${TWRP_SIZE}); continuing."
    fi
    log_success "TWRP image verified (${size} bytes, ANDROID! boot header)."
}

function download_twrp() {
    if [ -f "${TWRP_LOCAL}" ]; then
        log_info "TWRP image already present: ${TWRP_LOCAL}"
        verify_twrp_image
        return 0
    fi
    mkdir -p "${DOWNLOADS_DIR}"
    log_info "Downloading ${TWRP_IMAGE} (${TWRP_TAG}) from ${TWRP_REPO}..."
    curl -fsSL --max-time 180 "${TWRP_URL}" -o "${TWRP_LOCAL}"
    verify_twrp_image
    log_success "Downloaded and verified ${TWRP_LOCAL}."
}

function in_fastboot() {
    fastboot devices 2>/dev/null | grep -q .
}

function in_twrp_recovery() {
    local state mounts
    state="$(adb get-state 2>/dev/null || true)"
    case "${state}" in
        recovery|device) ;;
        *) return 1 ;;
    esac
    # The Linux chroot mounts /data/linuxroot/proc while it is running; pure
    # TWRP has no such mount, so its presence means the chroot is up (not TWRP).
    mounts="$(adb shell 'mount' 2>/dev/null || true)"
    if printf '%s\n' "${mounts}" | grep -q 'linuxroot/proc'; then
        return 1
    fi
    adb shell "[ -f /sbin/recovery ] || grep -qi recovery /proc/cmdline" 2>/dev/null
}

function mount_data() {
    # Probe the real write path the deploy uses: an actual adb push into /data.
    # The adb shell uid in TWRP may lack write access even when adb push can.
    local probe
    probe="$(mktemp "${TMPDIR:-/tmp}/tw_probe.XXXXXX")"
    if adb push "${probe}" /data/.tw_probe 2>/dev/null; then
        adb shell "rm -f /data/.tw_probe" 2>/dev/null || true
        log_success "/data is writable for adb push (TWRP)."
    else
        log_warn "/data not writable for adb push - mount Data in TWRP, then re-run."
    fi
    rm -f "${probe}"
}

function wait_for_twrp() {
    for _ in $(seq 1 45); do
        if in_twrp_recovery; then
            log_success "TWRP recovery active."
            return 0
        fi
        sleep 1
    done
    log_error "Could not detect TWRP recovery within 45 s."
    print_workflow
    return 1
}

CMD="${1:-verify}"
case "${CMD}" in
    --install)
        print_workflow
        download_twrp
        log_info "Entering fastboot..."
        adb reboot fastboot
        sleep 5
        if in_fastboot; then
            log_success "Device in fastboot."
            log_info "Flashing TWRP to the recovery partition (one-time)..."
            fastboot flash recovery "${TWRP_LOCAL}"
            fastboot reboot
            log_success "TWRP installed. Now enter TWRP recovery (hardware key method, or 'adb reboot recovery')."
        else
            log_error "Device not in fastboot. Enter fastboot manually (workflow A), then:"
            log_error "    fastboot flash recovery ${TWRP_LOCAL}"
        fi
        ;;
    --enter-recovery)
        print_workflow
        log_info "Requesting reboot into recovery (adb reboot recovery)..."
        adb reboot recovery 2>/dev/null || true
        log_info "If the device does not return to TWRP, use the hardware key method (workflow B)."
        wait_for_twrp
        mount_data
        ;;
    --download)
        download_twrp
        ;;
    verify|--verify)
        if in_twrp_recovery; then
            log_success "Already in Ryogo TWRP recovery."
            mount_data
            exit 0
        fi
        print_workflow
        log_warn "Device is not in TWRP recovery yet. Enter it via workflow B (hardware key"
        log_warn "method) or run:  bash \"$0\" --enter-recovery   (then re-run the deploy)."
        ;;
    --help|-h|help)
        print_workflow
        echo
        echo "Usage: $0 [verify | --verify | --enter-recovery | --install | --download]"
        ;;
    *)
        log_error "Unknown command: ${CMD}"
        print_workflow
        exit 2
        ;;
esac
