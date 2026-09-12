#!/usr/bin/env bash
# scripts/repurpose_partitions.sh - Repurpose /system (mmcblk0p5) for rootfs & /cache (mmcblk0p6) for swap
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PAYLOAD_TAR="${ROOT_DIR}/build/deploy_payload.tar.gz"
BACKUP_DIR="${ROOT_DIR}/backup"

echo "======================================================================"
echo "    BNRV700 Partition Repurposing Assistant"
echo "    - /dev/block/mmcblk0p5 (~360 MB) -> Dedicated Alpine Rootfs"
echo "    - /dev/block/mmcblk0p6 (~342 MB) -> High-Speed Swap Partition"
echo "======================================================================"

# Ensure deploy payload is built
if [ ! -f "${PAYLOAD_TAR}" ]; then
    echo "==> Deploy payload missing. Building fresh payload first..."
    make -C "${ROOT_DIR}" payload
fi

mkdir -p "${BACKUP_DIR}"

wait_for_twrp() {
    echo "==> Checking for TWRP recovery connection via ADB..."
    local state=""
    for _ in $(seq 1 30); do
        state=$(adb get-state 2>/dev/null || true)
        if [ "${state}" = "recovery" ] || [ "${state}" = "device" ]; then
            if adb shell "[ -f /sbin/recovery ] || grep -qi recovery /proc/cmdline" 2>/dev/null; then
                echo "==> Device detected in TWRP recovery mode."
                return 0
            fi
        fi
        sleep 1
    done

    echo "==> Device is not in recovery. Attempting reboot into TWRP recovery..."
    adb reboot recovery 2>/dev/null || true
    echo "==> Waiting for TWRP to load (up to 45s)..."
    for _ in $(seq 1 45); do
        if adb shell "[ -f /sbin/recovery ] || grep -qi recovery /proc/cmdline" 2>/dev/null; then
            echo "==> TWRP recovery active."
            return 0
        fi
        sleep 1
    done

    echo "ERROR: Could not detect TWRP recovery mode via ADB." >&2
    echo "Please boot the device into TWRP (Power + Page Down / Home) and try again." >&2
    exit 1
}

wait_for_twrp

echo ""
echo "----------------------------------------------------------------------"
echo "STEP 1: Backing up stock Android /system partition (/dev/block/mmcblk0p5)"
echo "----------------------------------------------------------------------"
BACKUP_FILE="${BACKUP_DIR}/system_backup_$(date +'%Y%m%d_%H%M%S').img"
echo "==> Creating raw image backup to ${BACKUP_FILE}..."
adb shell "dd if=/dev/block/mmcblk0p5 bs=4M" > "${BACKUP_FILE}"
echo "==> Backup complete: $(ls -lh "${BACKUP_FILE}" | awk '{print $5}')"

echo ""
echo "----------------------------------------------------------------------"
echo "STEP 2: Formatting /cache (/dev/block/mmcblk0p6) as Linux Swap (342 MB)"
echo "----------------------------------------------------------------------"
adb shell "umount /cache 2>/dev/null || true"
adb shell "mkswap /dev/block/mmcblk0p6"
echo "==> /dev/block/mmcblk0p6 successfully initialized as swap space."

echo ""
echo "----------------------------------------------------------------------"
echo "STEP 3: Formatting /system (/dev/block/mmcblk0p5) as ext4 Rootfs (360 MB)"
echo "----------------------------------------------------------------------"
adb shell "umount /system 2>/dev/null || true"
adb shell "mke2fs -t ext4 -L 'ALPINE_SYSTEM' /dev/block/mmcblk0p5 2>/dev/null || make_ext4fs /dev/block/mmcblk0p5"
adb shell "mkdir -p /system"
adb shell "mount -t ext4 /dev/block/mmcblk0p5 /system"
echo "==> /dev/block/mmcblk0p5 formatted and mounted at /system."

echo ""
echo "----------------------------------------------------------------------"
echo "STEP 4: Deploying Alpine Linux + KOReader Rootfs to /system"
echo "----------------------------------------------------------------------"
echo "==> Pushing ${PAYLOAD_TAR} directly to /system..."
adb push "${PAYLOAD_TAR}" /system/deploy_payload.tar.gz
echo "==> Unpacking payload on /system..."
adb shell "tar -xzf /system/deploy_payload.tar.gz -C /system && rm -f /system/deploy_payload.tar.gz"
adb shell "chmod +x /system/opt/*.sh /system/opt/koreader/*.sh 2>/dev/null || true"

echo ""
echo "----------------------------------------------------------------------"
echo "STEP 5: Verifying /system filesystem space and payload"
echo "----------------------------------------------------------------------"
adb shell "df -h /system"
adb shell "ls -la /system/opt/init_system.sh /system/opt/start_koreader.sh"
adb shell "umount /system"

echo ""
echo "======================================================================"
echo "SUCCESS: Partition repurposing complete!"
echo "- /system (/dev/block/mmcblk0p5) is now your dedicated Alpine rootfs."
echo "- /cache (/dev/block/mmcblk0p6) is formatted for instant swap memory."
echo "- Stock Android backup saved to: ${BACKUP_FILE}"
echo "======================================================================"
