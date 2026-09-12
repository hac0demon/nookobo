#!/usr/bin/env bash
set -euo pipefail

BOOT_ORIG="boot_backup.img"
BUILD_DIR="build/boot"

mkdir -p "${BUILD_DIR}"
cp "${BOOT_ORIG}" "${BUILD_DIR}/"
cd "${BUILD_DIR}"

magiskboot unpack "${BOOT_ORIG}"
mkdir -p ramdisk_root && cd ramdisk_root
cpio -idm < ../ramdisk.cpio

# Inject bootstrap script before Android zygote triggers
if ! grep -q "boot_linux.sh" init.rc; then
  sed -i '/on post-fs-data/a \    exec /system/bin/sh /data/boot_linux.sh' init.rc
fi

find . | cpio -o -H newc > ../ramdisk.cpio
cd ..
magiskboot repack "${BOOT_ORIG}" "../../boot_linux.img"
echo "==> Successfully compiled boot_linux.img"