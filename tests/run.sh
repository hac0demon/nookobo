#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"

echo "==> Checking component layout"
for required in \
    components/kernel/overlay/boot_linux.sh \
    components/common/include/font8x16.h \
    components/common/include/font8x16_cyrillic.h \
    components/kernel/patch_boot.sh \
    components/koreader/overlay/1-bnrv700-hardware.lua \
    components/netsurf/src/sdl_fb0_shim.c \
    components/netsurf/src/netsurf_fb_osk.patch \
    components/system/src/btn-watcher.c \
    components/system/src/plato_shim.c \
    components/system/overlay/init_system.sh; do
    test -e "${ROOT_DIR}/${required}" || { echo "missing: ${required}" >&2; exit 1; }
done

echo "==> Checking shell syntax"
while IFS= read -r -d '' script; do
    bash -n "${script}"
done < <(find "${ROOT_DIR}/scripts" "${ROOT_DIR}/components" -type f -name '*.sh' -print0)

echo "==> Checking Makefiles and rootfs references"
make -C "${ROOT_DIR}" --dry-run native >/dev/null
if rg -n 'configs/(boot_linux|1-bnrv700|Choices|Settings)|workspace/(btn-watcher|plato_shim|sdl_fb0_shim|nook-webkey)' \
    "${ROOT_DIR}/Makefile" "${ROOT_DIR}/scripts" "${ROOT_DIR}/components"; then
    echo "stale pre-component source path found" >&2
    exit 1
fi

echo "==> Checking Lua syntax when a LuaJIT interpreter is available"
LUAJIT="${LUAJIT:-}"
if [ -z "${LUAJIT}" ] && command -v luajit >/dev/null 2>&1; then
    LUAJIT="$(command -v luajit)"
fi
if [ -n "${LUAJIT}" ] && [ -x "${LUAJIT}" ]; then
    while IFS= read -r -d '' lua_file; do
        "${LUAJIT}" -e 'assert(loadfile(arg[1]))' "${lua_file}"
    done < <(find "${ROOT_DIR}/components" -type f -name '*.lua' -print0)
else
    echo "    skipped: no host LuaJIT (device KOReader LuaJIT can validate plugins)"
fi

echo "==> Running shellcheck when available"
if command -v shellcheck >/dev/null 2>&1; then
    while IFS= read -r -d '' script; do
        shellcheck --severity=warning "${script}"
    done < <(find "${ROOT_DIR}/scripts" "${ROOT_DIR}/components" -type f -name '*.sh' -print0)
else
    echo "    skipped: no host shellcheck (install it to enable this gate; CI installs it)"
fi

echo "==> Checking ARM ABI of built binaries when present"
if command -v readelf >/dev/null 2>&1; then
    for binary in "${BUILD_DIR}/btn-watcher" "${BUILD_DIR}/app-switcher" \
        "${BUILD_DIR}/libbnrv700_plato_shim.so" "${BUILD_DIR}/libSDL-1.2.so.0" \
        "${BUILD_DIR}/nook-webkey" "${BUILD_DIR}/netsurf-fb"; do
        [ -e "${binary}" ] || continue
        attrs="$(readelf -A "${binary}" 2>/dev/null || true)"
        grep -q 'Tag_CPU_arch: v7' <<<"${attrs}" || { echo "not ARMv7: ${binary}" >&2; exit 1; }
        grep -q 'Tag_FP_arch: VFPv3-D16' <<<"${attrs}" || { echo "wrong FPU ABI: ${binary}" >&2; exit 1; }
        grep -q 'Tag_ABI_VFP_args: VFP registers' <<<"${attrs}" || { echo "not hard-float: ${binary}" >&2; exit 1; }
    done
fi

echo "all checks passed"
