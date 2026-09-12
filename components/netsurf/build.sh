#!/bin/bash
# components/netsurf/build.sh - Cross build the NetSurf framebuffer frontend for the
# BNRV700 (i.MX6SL / musl armhf) with the FreeType glyph backend.
#
# Alpine ships netsurf-framebuffer with the framebuffer frontend's default
# NETSURF_FB_FONTLIB := internal, i.e. font_internal.c's ~256 glyph Latin-1
# bitmap font, so libfreetype is never linked and no non-Latin-1 script
# (Cyrillic, Greek, ...) can be drawn no matter what Choices says.  Rebuilding
# with NETSURF_FB_FONTLIB=freetype is the only fix.
#
# The build environment is assembled from three sources and never touches the
# device:
#   * downloads/toolchain_arm        Buildroot GCC 13 musl armhf cross toolchain
#   * downloads/alpine_sysroot/usr.tar   /usr/include + /usr/lib pulled from the device
#   * downloads/apks/*.apk           -dev APKs matching the device's ABI
# They are hardlink/extracted into one merged sysroot; the APK .pc files are
# rewritten to absolute sysroot paths so pkg-config works without
# PKG_CONFIG_SYSROOT_DIR (which would corrupt the in-tree prefix paths).
#
# nsgenbind (a host build tool) needs flex+bison: they are unpacked from Debian
# .debs into downloads/hosttools so nothing is installed system wide.

set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
DL="$REPO/downloads"
SRC="$DL/netsurf_src/netsurf-all-3.11"
SYS="$DL/alpine_sysroot/root"
HT="$DL/hosttools"
TOOLBIN="$DL/toolchain_arm/bin"
TRIPLET=arm-buildroot-linux-musleabihf
# AGENTS.md: i.MX6SL is Cortex-A9 r2p10 with VFPv3-D16 and NO NEON.  Anything
# wider (vfpv3-d32, neon) traps with SIGILL on this SoC.
ARCHFLAGS="-march=armv7-a -mcpu=cortex-a9 -mfpu=vfpv3-d16 -mfloat-abi=hard"
BUILD_TRIPLET="$(cc -dumpmachine)"

NS_OPTS=(
    "TARGET=framebuffer"
    "HOST=$TRIPLET"
    "BUILD=$BUILD_TRIPLET"
    "AR=$TOOLBIN/$TRIPLET-ar"
    "RANLIB=$TOOLBIN/$TRIPLET-ranlib"
    # Font backend: this is the whole point of the rebuild.
    "NETSURF_FB_FONTLIB=freetype"
    "NETSURF_FB_FONTPATH=/usr/share/fonts/dejavu:/usr/share/fonts/noto"
    # Alpine's netsurf-framebuffer links neither duktape nor libhpdf; match it.
    # JS off also keeps the host nsgenbind tool out of the compile path.
    "NETSURF_USE_DUKTAPE=NO"
    "NETSURF_USE_HARU_PDF=NO"
    "STRIP=$TOOLBIN/$TRIPLET-strip"
    # tools/convert_image runs on the host (it bakes the toolbar PNGs into C
    # arrays) and links libpng, which this host does not ship headers for.  The
    # Debian -dev deb unpacked into $HT/root below matches the host runtime.
    "BUILD_LIBPNG_CFLAGS=-I$HT/root/usr/include/libpng16"
    # Debian's deb ships only libpng.a (the .so symlinks dangle without the
    # runtime package in the same prefix), so the host tool links statically and
    # has to name zlib and libm explicitly.
    "BUILD_LIBPNG_LDFLAGS=-L$HT/root/usr/lib/x86_64-linux-gnu -lpng -lz -lm"
    "PREFIX=/usr"
)

log() { printf '==> %s\n' "$*"; }

[ -d "$SRC/netsurf" ] || { echo "missing $SRC - extract netsurf-all-3.11.tar.gz first" >&2; exit 1; }
[ -x "$TOOLBIN/$TRIPLET-gcc" ] || { echo "missing toolchain in $TOOLBIN" >&2; exit 1; }
for hosttool in perl sed install make pkg-config dpkg-deb apt-get; do
    command -v "$hosttool" >/dev/null || { echo "missing host tool: $hosttool" >&2; exit 1; }
done

bash "$REPO/scripts/ensure_netsurf_inputs.sh"

# Keep the NetSurf-side OSK integration reproducible.  The preload shim exports
# this weakly-consumed callback; it is intentionally optional for stock builds.
if ! grep -q 'SDL_ShowKeyboardForTextInput' "$SRC/netsurf/frontends/framebuffer/gui.c"; then
    log "applying BNRV700 NetSurf text-input OSK patch"
    patch -d "$SRC" -p1 --forward < "$REPO/components/netsurf/src/netsurf_fb_osk.patch"
fi

needs_sysroot_assembly=0
[ -d "$SYS/usr/lib/pkgconfig" ] || needs_sysroot_assembly=1
for target_lib in libz.so libssl.so libcrypto.so; do
    [ -e "$SYS/usr/lib/$target_lib" ] || needs_sysroot_assembly=1
done

if [ "$needs_sysroot_assembly" -eq 1 ]; then
    log "assembling merged sysroot"
    rm -rf "$SYS"
    mkdir -p "$SYS/usr"
    cp -as "$TOOLBIN/../$TRIPLET/sysroot/." "$SYS/"
    tar xf "$DL/alpine_sysroot/usr.tar" -C "$SYS/usr"
    for apk in "$DL"/apks/*.apk; do
        tar xzf "$apk" -C "$SYS" 2>/dev/null || true
    done
    # Make the APK pkg-config files self-locating inside the sysroot.
    find "$SYS" -name '*.pc' -print0 | xargs -0 sed -i \
        -e "s|^prefix=/usr$|prefix=$SYS/usr|" \
        -e "s|^includedir=/usr|includedir=$SYS/usr|" \
        -e "s|^libdir=/usr|libdir=$SYS/usr|"
    # The device ships shared objects only; dev APKs provide the .so links.
    for so in "$SYS"/usr/lib/*.so.*; do
        base="${so##*/}"
        stem="${base%%.so*}"
        [ -e "$SYS/usr/lib/$stem.so" ] || ln -sf "$base" "$SYS/usr/lib/$stem.so"
    done
fi

for target_lib in libz.so libssl.so libcrypto.so; do
    [ -e "$SYS/usr/lib/$target_lib" ] || {
        echo "ERROR: merged target sysroot is missing ${target_lib}; check zlib-dev/openssl-dev APKs" >&2
        exit 1
    }
done

log "staging host tools (flex/bison/m4/gperf/libpng-dev) + target cc wrapper"
mkdir -p "$HT/bin" "$HT/hostdeb" "$HT/root"
# Unpack each -dev/tool package only when its payload is missing, so a partially
# staged tree heals instead of being skipped wholesale.
for pkg in flex bison m4 gperf libpng-dev; do
    case "$pkg" in
        libpng-dev) marker="$HT/root/usr/include/libpng16/png.h" ;;
        *)          marker="$HT/root/usr/bin/$pkg" ;;
    esac
    [ -e "$marker" ] && continue
    ls "$HT"/hostdeb/"$pkg"_*.deb >/dev/null 2>&1 || \
        ( cd "$HT/hostdeb" && apt-get download "$pkg" >/dev/null )
    for deb in "$HT"/hostdeb/"$pkg"_*.deb; do dpkg-deb -x "$deb" "$HT/root"; done
done
ln -sf "$(command -v gcc)" "$HT/bin/$BUILD_TRIPLET-gcc"

cat > "$HT/bin/$TRIPLET-gcc" <<EOF
#!/bin/sh
exec "$TOOLBIN/$TRIPLET-gcc" --sysroot="$SYS" $ARCHFLAGS "\$@"
EOF
chmod +x "$HT/bin/$TRIPLET-gcc"

export PATH="$HT/bin:$HT/root/usr/bin:$TOOLBIN:$PATH"
export LD_LIBRARY_PATH="$HT/root/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# The unpacked bison looks for its skeletons under the deb staging prefix, not /usr.
export BISON_PKGDATADIR="$HT/root/usr/share/bison"
# flex execs m4 by absolute path unless M4 says otherwise (this host has no /usr/bin/m4).
export M4="$HT/root/usr/bin/m4"
export PKG_CONFIG_PATH="$SYS/usr/lib/pkgconfig"
# LIBDIR keeps the host's x86_64 .pc files out of the way; the in-tree prefix is
# first so the freshly cross built libraries win over anything else.
export PKG_CONFIG_LIBDIR="$SRC/inst-framebuffer/lib/pkgconfig:$SYS/usr/lib/pkgconfig"
unset PKG_CONFIG_SYSROOT_DIR
export CFLAGS="-O2 $ARCHFLAGS"
export LDFLAGS=""
# The browser Makefile is self contained and ignores HOST, so the cross compiler
# has to come from the environment.  HOST keeps the buildsystem-based libraries
# on their cross-compiling code path.
export CC="$HT/bin/$TRIPLET-gcc"
export CXX="$TOOLBIN/$TRIPLET-g++"

if [ "${KEEP:-0}" = "1" ]; then
    log "keeping previous inst-framebuffer (KEEP=1)"
else
    log "cleaning previous inst-framebuffer"
    rm -rf "$SRC/inst-framebuffer"
    ( cd "$SRC" && for d in libnslog libwapcaplet libparserutils libcss libhubbub libdom \
                           libnsbmp libnsgif librosprite libnsutils libutf8proc libnspsl \
                           libsvgtiny libnsfb netsurf; do
        make -s -C "$d" distclean >/dev/null 2>&1 || true
      done )
fi

log "building ${NS_OPTS[*]}"
cd "$SRC"
make -j"$(nproc)" "${NS_OPTS[@]}" 2>&1 | tee "$DL/nsbuild.log" | \
    grep -vE '^\s*(CC|AR|AR-A|LINK|INSTALL|INSTALL-APP|INSTALL-FRONTEND|MKDIR|GENCC|GEN|LEX|YACC|BISON|FLEX|HOSTCC)\s' || true

log "installing into \$SYS/netsurf-stage"
make -C "$SRC" "${NS_OPTS[@]}" DESTDIR="$SYS/netsurf-stage" install 2>&1 | tail -3

BIN="$SYS/netsurf-stage/usr/bin/netsurf-fb"
[ -f "$BIN" ] || { echo "BUILD FAILED - see $DL/nsbuild.log" >&2; exit 1; }

log "checking for forbidden NEON / d16-d31 FPU usage"
# VFPv3-D16 gives d0..d15 only and there is no NEON unit at all.  vadd/vmul/vfma
# etc. are plain VFPv3 and stay legal, so only NEON structure accesses and any
# reference to d16..d31 are disqualifying.
NEON_RE='\bv(ld|st)[1-4]\.[0-9]|\bvtbl|\bvtbb|\bvzip|\bvuzp|\bvtrn\.|\bin d(1[6-9]|2[0-9]|3[01])\b|\bd(1[6-9]|2[0-9]|3[01])\s*,'
if "$TOOLBIN/$TRIPLET-objdump" -d "$BIN" | grep -E "$NEON_RE" | head -10 | grep -q .; then
    echo "REJECT: binary uses instructions the i.MX6SL cannot execute" >&2
    exit 1
fi
"$TOOLBIN/$TRIPLET-readelf" -d "$BIN" | grep -E 'NEEDED' || true
log "ok: $BIN ($(stat -c %s "$BIN") bytes)"
mkdir -p "$REPO/build"
cp "$BIN" "$REPO/build/netsurf-fb"
chmod 755 "$REPO/build/netsurf-fb"
