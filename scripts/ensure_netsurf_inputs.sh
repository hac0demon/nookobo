#!/usr/bin/env bash
# Ensure the ARMHF development APKs required by the NetSurf cross build exist.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK_DIR="${ROOT_DIR}/downloads/apks"
APK_STATIC_URL="${APK_STATIC_URL:-https://dl-cdn.alpinelinux.org/alpine/v3.20/main/x86_64/apk-tools-static-2.14.4-r1.apk}"

mkdir -p "${APK_DIR}"

has_apk() {
    compgen -G "${APK_DIR}/$1-*.apk" >/dev/null 2>&1
}

missing=()
for package in zlib-dev openssl-dev; do
    if ! has_apk "${package}"; then
        missing+=("${package}")
    fi
done

if [ "${#missing[@]}" -gt 0 ]; then
    apk_static="${ROOT_DIR}/downloads/sbin/apk.static"
    apk_tmp=""
    cleanup() {
        [ -z "${apk_tmp}" ] || rm -rf "${apk_tmp}"
    }
    trap cleanup EXIT

    if [ ! -x "${apk_static}" ]; then
        apk_tmp="$(mktemp -d)"
        mkdir -p "${apk_tmp}/sbin"
        curl -fsSL "${APK_STATIC_URL}" | tar -xz -C "${apk_tmp}" sbin/apk.static
        apk_static="${apk_tmp}/sbin/apk.static"
        chmod +x "${apk_static}"
    fi

    echo "==> Fetching missing NetSurf target APKs: ${missing[*]}"
    "${apk_static}" --arch armhf \
        -X https://dl-cdn.alpinelinux.org/alpine/v3.20/main \
        -X https://dl-cdn.alpinelinux.org/alpine/v3.20/community \
        --allow-untrusted fetch --output "${APK_DIR}" "${missing[@]}"
fi

for package in zlib-dev openssl-dev; do
    has_apk "${package}" || {
        echo "ERROR: required target APK is still missing: ${package}" >&2
        exit 1
    }
done

echo "==> NetSurf target APK inputs are present"
