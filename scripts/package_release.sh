#!/usr/bin/env bash
# Create the small, user-facing release directory from build outputs.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-$(git -C "${ROOT_DIR}" describe --tags --always --dirty 2>/dev/null || echo snapshot)}"
VERSION="${VERSION//\//-}"
PAYLOAD="${PAYLOAD:-${ROOT_DIR}/build/deploy_payload.tar.gz}"
BOOT="${BOOT:-${ROOT_DIR}/build/boot_linux.img}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/build/release/bnrv700-${VERSION}}"
INSTALL_TEMPLATE="${ROOT_DIR}/packaging/INSTALL.md"

if [ ! -f "${PAYLOAD}" ]; then
    echo "ERROR: missing rootfs payload: ${PAYLOAD}" >&2
    echo "Run: make rootfs" >&2
    exit 1
fi
if [ ! -f "${INSTALL_TEMPLATE}" ]; then
    echo "ERROR: missing release install instructions: ${INSTALL_TEMPLATE}" >&2
    exit 1
fi

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"
cp "${PAYLOAD}" "${OUT_DIR}/bnrv700-${VERSION}-rootfs.tar.gz"

if [ -f "${BOOT}" ]; then
    cp "${BOOT}" "${OUT_DIR}/bnrv700-${VERSION}-boot.img"
else
    echo "No boot image supplied; creating a rootfs-only release." >&2
fi

sed "s/@VERSION@/${VERSION}/g" "${INSTALL_TEMPLATE}" > "${OUT_DIR}/INSTALL.md"

mapfile -t ASSETS < <(find "${OUT_DIR}" -maxdepth 1 -type f \
    \( -name '*-rootfs.tar.gz' -o -name '*-boot.img' \) -printf '%f\n' | sort)
(
    cd "${OUT_DIR}"
    sha256sum "${ASSETS[@]}" > SHA256SUMS
    zip -q -j "bnrv700-${VERSION}-install.zip" \
        "${ASSETS[@]}" INSTALL.md SHA256SUMS
)

echo "Release assets:"
find "${OUT_DIR}" -maxdepth 1 -type f -printf '  %f %s bytes\n' | sort
