#!/usr/bin/env bash
# scripts/patch_boot.sh - Unpack stock boot.img, inject init.rc hook, repack into boot_linux.img
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

BOOT_ORIG="${1:-${ROOT_DIR}/boot_backup.img}"
OUT_IMG="${2:-${ROOT_DIR}/build/boot_linux.img}"
MAGISKBOOT="${MAGISKBOOT:-${ROOT_DIR}/scripts/magiskboot}"
CONFIG_BOOT_SH="${ROOT_DIR}/components/kernel/overlay/boot_linux.sh"

echo "==> Validating build prerequisites..."
if [ ! -f "${BOOT_ORIG}" ]; then
    echo "ERROR: Stock boot image '${BOOT_ORIG}' not found!" >&2
    exit 1
fi

if [ ! -x "${MAGISKBOOT}" ]; then
    echo "ERROR: Magiskboot binary '${MAGISKBOOT}' not found or not executable!" >&2
    exit 1
fi

mkdir -p "$(dirname "${OUT_IMG}")"
WORK_DIR="${ROOT_DIR}/build/boot_work"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

BOOT_ORIG_ABS="$(cd "$(dirname "${BOOT_ORIG}")" && pwd)/$(basename "${BOOT_ORIG}")"
OUT_IMG_ABS="$(cd "$(dirname "${OUT_IMG}")" && pwd)/$(basename "${OUT_IMG}")"
MAGISKBOOT_ABS="$(cd "$(dirname "${MAGISKBOOT}")" && pwd)/$(basename "${MAGISKBOOT}")"

echo "==> Unpacking ${BOOT_ORIG} with magiskboot..."
cd "${WORK_DIR}"
cp "${BOOT_ORIG_ABS}" "boot.img"
"${MAGISKBOOT_ABS}" unpack "boot.img"

if [ ! -f "ramdisk.cpio" ] || [ ! -f "kernel" ]; then
    echo "ERROR: Failed to unpack ramdisk or kernel from boot image!" >&2
    exit 1
fi

echo "==> Extracting ramdisk.cpio..."
mkdir -p ramdisk
cd ramdisk
cpio -idm --no-absolute-filenames < ../ramdisk.cpio 2>/dev/null

if [ ! -f "init.rc" ]; then
    echo "ERROR: init.rc not found inside ramdisk!" >&2
    exit 1
fi

echo "==> Embedding bootstrapper into ramdisk..."
if [ -f "${CONFIG_BOOT_SH}" ]; then
    cp "${CONFIG_BOOT_SH}" "boot_linux.sh"
    chmod 755 "boot_linux.sh"
fi

echo "==> Patching init.rc and init.hw.rc to execute /data/boot_linux.sh and defuse watchdogs/recovery triggers..."
python3 - << 'PYEOF'
import re, os

with open("init.rc", "r") as f:
    content = f.read()

# 1. Under 'on post-fs-data', inject the bootstrapper copy and async execution
if "boot_linux" not in content:
    hook = """on post-fs-data
    copy /boot_linux.sh /data/boot_linux.sh
    chmod 0755 /data/boot_linux.sh
    start boot_linux
    # exec /system/bin/sh /data/boot_linux.sh"""
    content = re.sub(r"^on post-fs-data\b", hook, content, count=1, flags=re.MULTILINE)

# 2. Append service boot_linux definition if not already defined
if "service boot_linux" not in content:
    svc = """
# Standalone Linux Bootstrapper Service
service boot_linux /system/bin/sh /data/boot_linux.sh
    class core
    user root
    group root
    disabled
    oneshot
"""
    content += svc

# 3. Strip 'critical' flag from all services to permanently defuse init's 4-crash recovery reboot loop
content = re.sub(r"^(\s*)critical\b", r"\1# critical # Stripped to prevent recovery reboot", content, flags=re.MULTILINE)

# 4. Disable Android Dalvik runtime, SurfaceFlinger, and installd from launching
content = re.sub(r"^(\s*class_start\s+main\b)", r"    # \1 # Bypassed for standalone Linux", content, flags=re.MULTILINE)

# 5. Explicitly disable unneeded Android core and main services to prevent crashes/restarts
services_to_disable = [
    "healthd", "healthd-charger", "servicemanager", "vold", "watchdogd",
    "surfaceflinger", "zygote", "installd", "netd", "debuggerd",
    "drm", "media", "bootanim", "keystore"
]

for svc in services_to_disable:
    m = re.search(rf"^service\s+{svc}\b", content, flags=re.MULTILINE)
    if m:
        sub = content[m.start():m.start()+200]
        first_line = sub.split('\n')[0]
        if "disabled" not in sub.split('\n\n')[0]:
            content = content[:m.start()] + first_line + "\n    disabled" + content[m.start()+len(first_line):]

with open("init.rc", "w") as f:
    f.write(content)

# 6. Defuse hardware watchdogd invocation in init.hw.rc if present
if os.path.exists("init.hw.rc"):
    with open("init.hw.rc", "r") as f:
        hw_content = f.read()
    hw_content = re.sub(r"^(\s*start\s+watchdogd\b)", r"    # \1 # Disabled for standalone Linux", hw_content, flags=re.MULTILINE)
    with open("init.hw.rc", "w") as f:
        f.write(hw_content)

# 7. Patch default.prop for root adb and debuggability
if os.path.exists("default.prop"):
    with open("default.prop", "r") as f:
        prop = f.read()
    prop = re.sub(r"ro\.secure=\d+", "ro.secure=0", prop)
    prop = re.sub(r"ro\.debuggable=\d+", "ro.debuggable=1", prop)
    with open("default.prop", "w") as f:
        f.write(prop)
PYEOF

# Verify hook is present
if ! grep -q "boot_linux.sh" init.rc; then
    echo "ERROR: Failed to patch init.rc with boot_linux.sh hook!" >&2
    exit 1
fi

echo "==> Repacking ramdisk.cpio..."
find . | cpio -o -H newc > ../ramdisk.cpio 2>/dev/null
cd ..

echo "==> Repacking boot image into ${OUT_IMG}..."
"${MAGISKBOOT_ABS}" repack "boot.img" "${OUT_IMG_ABS}"

if [ ! -f "${OUT_IMG_ABS}" ]; then
    echo "ERROR: Output boot image was not created!" >&2
    exit 1
fi

echo "==> Cleaning up temporary boot work directory..."
rm -rf "${WORK_DIR}"

echo "==> Successfully created patched boot image: ${OUT_IMG_ABS} ($(ls -lh "${OUT_IMG_ABS}" | awk '{print $5}'))"
