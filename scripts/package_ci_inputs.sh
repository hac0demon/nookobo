#!/usr/bin/env bash
# Package the ignored inputs needed by the GitHub release workflow.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:-${ROOT_DIR}/build/bnrv700-ci-inputs.tar.gz}"
INCLUDE_BOOT="${INCLUDE_BOOT:-1}"

required=(
    downloads/toolchain_arm
    downloads/netsurf_src/netsurf-all-3.11.tar.gz
    downloads/alpine_sysroot/usr.tar
    downloads/apks
)
optional=(
    downloads/8723ds.ko
    downloads/RTL8723DS_BT_Linux
    downloads/android_firmware
    downloads/plato-0.9.45.zip
    downloads/libstdc++_extracted
    scripts/magiskboot
)

for path in "${required[@]}"; do
    [ -e "${ROOT_DIR}/${path}" ] || {
        echo "ERROR: required CI input is missing: ${path}" >&2
        exit 1
    }
done

paths=("${required[@]}")
for path in "${optional[@]}"; do
    [ -e "${ROOT_DIR}/${path}" ] && paths+=("${path}")
done
if [ "${INCLUDE_BOOT}" = 1 ] && [ -f "${ROOT_DIR}/boot_backup.img" ]; then
    paths+=(boot_backup.img)
fi

mkdir -p "$(dirname "${OUTPUT}")"
(
    cd "${ROOT_DIR}"
    tar -czf "${OUTPUT}" "${paths[@]}"
)
sha256sum "${OUTPUT}"
