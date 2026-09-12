#!/usr/bin/env bash
# scripts/device_check.sh - BNRV700 on-device health check suite.
#
# Usage:
#   make device-check
#   bash scripts/device_check.sh [--glyph]
#
# Requires the device connected via adb (the chroot's own adbd provides the
# adb endpoint) and the Linux chroot running. Runs scripts/device_check/
# chroot_checks.sh inside the chroot (EPDC round-trip, input nodes, daemons,
# frontlight, battery, linking, disk). --glyph additionally captures the
# live framebuffer and asserts the visible page contains rendered text
# (needs python3 + Pillow on the host).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"

ADB_PORT="${ADB_PORT:-9922}"
SSH_TARGET="${SSH_TARGET:-root@127.0.0.1}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o BatchMode=yes -o LogLevel=ERROR)
GLYPH=0
[ "${1:-}" = "--glyph" ] && GLYPH=1

command -v adb >/dev/null 2>&1 || { echo "device-check: adb not found" >&2; exit 2; }
[ -x "${BUILD_DIR}/epdc_probe" ] || {
    echo "device-check: ${BUILD_DIR}/epdc_probe missing (run 'make native' first)" >&2
    exit 2
}

adb start-server >/dev/null 2>&1 || true
if ! adb devices | awk 'NR > 1 && $2 == "device"' | grep -q .; then
    echo "device-check: no adb device in state 'device' (run: adb devices)" >&2
    exit 2
fi
adb forward "tcp:${ADB_PORT}" tcp:22 >/dev/null

ssh_run() {
    timeout 60 ssh -p "${ADB_PORT}" "${SSH_OPTS[@]}" "${SSH_TARGET}" "$@"
}

if ! ssh_run "echo alive" >/dev/null 2>&1; then
    echo "device-check: chroot SSH via port ${ADB_PORT} unreachable" >&2
    echo "               (is the Linux chroot running? check 'adb forward' and adbd)" >&2
    exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Deploy the fresh probe + check script into the chroot, then run.
cat "${BUILD_DIR}/epdc_probe" | ssh_run "cat > /opt/bin/epdc_probe && chmod 755 /opt/bin/epdc_probe"
cat "${SCRIPT_DIR}/device_check/chroot_checks.sh" | ssh_run "cat > /opt/bin/chroot_checks.sh && chmod 755 /opt/bin/chroot_checks.sh"
ssh_run "sh /opt/bin/chroot_checks.sh" > "${TMP}/report" || true

ok=0; bad=0; info=0
while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
        OK\ *)   ok=$((ok + 1));   printf 'PASS %s\n' "${line#OK }" ;;
        BAD\ *)  bad=$((bad + 1)); printf 'FAIL %s\n' "${line#BAD }" ;;
        INFO\ *) info=$((info + 1)); printf 'INFO %s\n' "${line#INFO }" ;;
        *)       printf 'RAW  %s\n' "$line" ;;
    esac
done < "${TMP}/report"

if [ "$GLYPH" = 1 ]; then
    raw="${TMP}/fb.raw"
    adb shell "dd if=/dev/fb0 of=/data/local/tmp/fb.raw bs=65536 count=248 2>/dev/null"
    adb pull /data/local/tmp/fb.raw "${raw}" >/dev/null
    if python3 "${SCRIPT_DIR}/fbshot.py" "${raw}" "${TMP}/fb" --check 5000 >/dev/null; then
        ok=$((ok + 1))
        printf 'PASS glyph-ink rendered text detected on the visible page\n'
    else
        bad=$((bad + 1))
        printf 'FAIL glyph-ink no rendered text on the visible page\n'
    fi
fi

echo
echo "device-check: ${ok} passed, ${bad} failed, ${info} informational"
[ "${bad}" -eq 0 ] || exit 1
