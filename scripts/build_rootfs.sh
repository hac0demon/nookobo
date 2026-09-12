#!/usr/bin/env bash
# scripts/build_rootfs.sh - Fetch dependencies, construct Alpine ARMHF rootfs, inject configs, package payload
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

DOWNLOADS_DIR="${ROOT_DIR}/downloads"
STAGING_DIR="${ROOT_DIR}/staging"
BUILD_DIR="${ROOT_DIR}/build"
KERNEL_OVERLAY="${ROOT_DIR}/components/kernel/overlay"
KOREADER_OVERLAY="${ROOT_DIR}/components/koreader/overlay"
NETSURF_OVERLAY="${ROOT_DIR}/components/netsurf/overlay"
SYSTEM_OVERLAY="${ROOT_DIR}/components/system/overlay"

ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/armhf/alpine-minirootfs-3.20.0-armhf.tar.gz"
ALPINE_FILE="${DOWNLOADS_DIR}/alpine-minirootfs-3.20.0-armhf.tar.gz"

KOREADER_URL="https://github.com/koreader/koreader/releases/download/v2024.07/koreader-kobo-v2024.07.zip"
KOREADER_FILE="${DOWNLOADS_DIR}/koreader-kobo-v2024.07.zip"

GLIBC_URL="http://archive.debian.org/debian/pool/main/g/glibc/libc6_2.19-18+deb8u10_armhf.deb"
GLIBC_FILE="${DOWNLOADS_DIR}/libc6_2.19-18+deb8u10_armhf.deb"

LIBGCC_URL="http://archive.debian.org/debian/pool/main/g/gcc-4.9/libgcc1_4.9.2-10+deb8u1_armhf.deb"
LIBGCC_FILE="${DOWNLOADS_DIR}/libgcc1_4.9.2-10+deb8u1_armhf.deb"

APK_STATIC_URL="https://dl-cdn.alpinelinux.org/alpine/v3.20/main/x86_64/apk-tools-static-2.14.4-r1.apk"
APK_STATIC_BIN="${DOWNLOADS_DIR}/sbin/apk.static"

PAYLOAD_TAR="${BUILD_DIR}/deploy_payload.tar.gz"

mkdir -p "${DOWNLOADS_DIR}" "${BUILD_DIR}"

echo "==> Step 1: Downloading components..."
if [ ! -f "${ALPINE_FILE}" ]; then
    echo "Downloading Alpine Linux ARMHF minirootfs..."
    curl -fSL "${ALPINE_URL}" -o "${ALPINE_FILE}"
else
    echo "Using cached Alpine Linux archive: ${ALPINE_FILE}"
fi

if [ ! -f "${KOREADER_FILE}" ]; then
    echo "Downloading KOReader Kobo/ARMHF bundle..."
    curl -fSL "${KOREADER_URL}" -o "${KOREADER_FILE}"
else
    echo "Using cached KOReader archive: ${KOREADER_FILE}"
fi

# Download compatible ARMHF glibc (Linux 2.6.32+ ABI) for KOReader binaries
if [ ! -f "${GLIBC_FILE}" ]; then
    echo "Downloading Debian Jessie glibc runtime (libc6 2.19)..."
    curl -fSL "${GLIBC_URL}" -o "${GLIBC_FILE}"
fi
if [ ! -f "${LIBGCC_FILE}" ]; then
    echo "Downloading libgcc1..."
    curl -fSL "${LIBGCC_URL}" -o "${LIBGCC_FILE}"
fi

# Download apk.static for host-side rootfs package installation
if [ ! -x "${APK_STATIC_BIN}" ]; then
    echo "Downloading apk-tools-static for x86_64..."
    curl -sL "${APK_STATIC_URL}" | tar -xz -C "${DOWNLOADS_DIR}" sbin/apk.static 2>/dev/null || true
    chmod +x "${APK_STATIC_BIN}"
fi

echo "==> Step 2: Unpacking Alpine Linux rootfs to staging/...";
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"
tar -xzf "${ALPINE_FILE}" -C "${STAGING_DIR}"

# Fix root directory permissions (must be 755 owned by root for proper .netsurf creation)
chmod 755 "${STAGING_DIR}/root"

echo "==> Step 3: Installing essential packages via apk.static into staging rootfs..."
"${APK_STATIC_BIN}" --root "${STAGING_DIR}" --arch armhf \
    -X https://dl-cdn.alpinelinux.org/alpine/v3.20/main \
    -X https://dl-cdn.alpinelinux.org/alpine/v3.20/community \
    -X https://dl-cdn.alpinelinux.org/alpine/edge/main \
    -X https://dl-cdn.alpinelinux.org/alpine/edge/community \
    --allow-untrusted add --no-scripts \
    wpa_supplicant wireless-tools dropbear dhcpcd iw ca-certificates \
    netsurf-framebuffer freetype font-dejavu umtprd syncthing \
    bluez bluez-deprecated bluez-alsa alsa-utils alsa-lib mpg123 i2c-tools curl \
    espeak-ng

# Overwrite Alpine's netsurf-framebuffer with our freetype-enabled build
if [ -f "${ROOT_DIR}/build/netsurf-fb" ]; then
    echo "==> Overwriting netsurf-fb with freetype-enabled build..."
    cp "${ROOT_DIR}/build/netsurf-fb" "${STAGING_DIR}/usr/bin/netsurf-fb"
    chmod +x "${STAGING_DIR}/usr/bin/netsurf-fb"
fi

echo "==> Step 4: Installing compatible ARMHF glibc runtime (Linux 2.6.32+ ABI) into rootfs..."
GLIBC_TMP="${BUILD_DIR}/glibc_tmp"
rm -rf "${GLIBC_TMP}"
mkdir -p "${GLIBC_TMP}"
ar -x "${GLIBC_FILE}" --output="${GLIBC_TMP}"
tar -xf "${GLIBC_TMP}"/data.tar.* -C "${GLIBC_TMP}"
cp -a "${GLIBC_TMP}"/lib/arm-linux-gnueabihf/* "${STAGING_DIR}/lib/"

rm -rf "${GLIBC_TMP}"/*
ar -x "${LIBGCC_FILE}" --output="${GLIBC_TMP}"
tar -xf "${GLIBC_TMP}"/data.tar.* -C "${GLIBC_TMP}"
cp -a "${GLIBC_TMP}"/lib/arm-linux-gnueabihf/* "${STAGING_DIR}/lib/"
rm -rf "${GLIBC_TMP}"

echo "==> Step 5: Unpacking KOReader into staging/opt/koreader/..."
mkdir -p "${STAGING_DIR}/opt"
unzip -q -o "${KOREADER_FILE}" -d "${STAGING_DIR}/opt/"

if [ ! -d "${STAGING_DIR}/opt/koreader" ] && [ -f "${STAGING_DIR}/opt/reader.lua" ]; then
    mkdir -p "${STAGING_DIR}/opt/koreader_tmp"
    mv "${STAGING_DIR}/opt"/* "${STAGING_DIR}/opt/koreader_tmp/" 2>/dev/null || true
    mv "${STAGING_DIR}/opt/koreader_tmp" "${STAGING_DIR}/opt/koreader"
fi

if [ ! -f "${STAGING_DIR}/opt/koreader/reader.lua" ]; then
    echo "ERROR: KOReader reader.lua not found in staging/opt/koreader/!" >&2
    exit 1
fi

echo "==> Step 6: Injecting configuration templates and launchers..."
mkdir -p "${STAGING_DIR}/root/.netsurf" "${STAGING_DIR}/etc/netsurf"
mkdir -p "${STAGING_DIR}/etc/apk"
mkdir -p "${STAGING_DIR}/data/books"
mkdir -p "${STAGING_DIR}/data/syncthing/notes"
mkdir -p "${STAGING_DIR}/data/syncthing/config"
mkdir -p "${STAGING_DIR}/opt/koreader/settings"
mkdir -p "${STAGING_DIR}/lib/modules"

# Copy Wi-Fi kernel driver
if [ -f "${DOWNLOADS_DIR}/8723ds.ko" ]; then
    cp "${DOWNLOADS_DIR}/8723ds.ko" "${STAGING_DIR}/lib/modules/8723ds.ko"
fi

# Copy launchers and scripts
cp "${SYSTEM_OVERLAY}/init_system.sh" "${STAGING_DIR}/opt/init_system.sh"
cp "${KOREADER_OVERLAY}/start_koreader.sh" "${STAGING_DIR}/opt/start_koreader.sh"
cp "${NETSURF_OVERLAY}/start_browser.sh" "${STAGING_DIR}/opt/start_browser.sh"
cp "${SYSTEM_OVERLAY}/splash.lua" "${STAGING_DIR}/opt/splash.lua"

# Configure NetSurf high-DPI font scale
if [ -f "${NETSURF_OVERLAY}/Choices" ]; then
    cp "${NETSURF_OVERLAY}/Choices" "${STAGING_DIR}/root/.netsurf/Choices"
    cp "${NETSURF_OVERLAY}/Choices" "${STAGING_DIR}/etc/netsurf/Choices"
fi

# Configure uMTP-Responder for USB MTP file sharing
mkdir -p "${STAGING_DIR}/etc/umtprd"
if [ -f "${SYSTEM_OVERLAY}/umtprd.conf" ]; then
    cp "${SYSTEM_OVERLAY}/umtprd.conf" "${STAGING_DIR}/etc/umtprd/umtprd.conf"
    cp "${SYSTEM_OVERLAY}/umtprd.conf" "${STAGING_DIR}/opt/umtprd.conf"
fi

# Install BNRV700 custom Wi-Fi lifecycle scripts into KOReader directory and persistent shims
mkdir -p "${STAGING_DIR}/opt/bnrv700-shims"
for script in enable-wifi.sh disable-wifi.sh obtain-ip.sh release-ip.sh restore-wifi-async.sh; do
    cp "${SYSTEM_OVERLAY}/${script}" "${STAGING_DIR}/opt/koreader/${script}"
    cp "${SYSTEM_OVERLAY}/${script}" "${STAGING_DIR}/opt/bnrv700-shims/${script}"
done

# Install KOReader NetSurf browser plugin
if [ -d "${NETSURF_OVERLAY}/browser.koplugin" ]; then
    mkdir -p "${STAGING_DIR}/opt/koreader/plugins/browser.koplugin"
    mkdir -p "${STAGING_DIR}/opt/bnrv700-shims/plugins/browser.koplugin"
    cp -rf "${NETSURF_OVERLAY}/browser.koplugin"/* "${STAGING_DIR}/opt/koreader/plugins/browser.koplugin/"
    cp -rf "${NETSURF_OVERLAY}/browser.koplugin"/* "${STAGING_DIR}/opt/bnrv700-shims/plugins/browser.koplugin/"
fi

# Install KOReader Minfolio note-taking plugin (mapped to /data/syncthing/notes/)
if [ -d "${DOWNLOADS_DIR}/minfolio.koplugin/minfolio.koplugin" ]; then
    mkdir -p "${STAGING_DIR}/opt/koreader/plugins/minfolio.koplugin"
    mkdir -p "${STAGING_DIR}/opt/bnrv700-shims/plugins/minfolio.koplugin"
    cp -rf "${DOWNLOADS_DIR}/minfolio.koplugin/minfolio.koplugin"/* "${STAGING_DIR}/opt/koreader/plugins/minfolio.koplugin/"
    cp -rf "${DOWNLOADS_DIR}/minfolio.koplugin/minfolio.koplugin"/* "${STAGING_DIR}/opt/bnrv700-shims/plugins/minfolio.koplugin/"
fi

# Install KOReader QuickRSS plugin (native E-Ink RSS reader via libcurl)
if [ -d "${DOWNLOADS_DIR}/quickrss.koplugin/quickrss.koplugin" ]; then
    mkdir -p "${STAGING_DIR}/opt/koreader/plugins/quickrss.koplugin"
    mkdir -p "${STAGING_DIR}/opt/bnrv700-shims/plugins/quickrss.koplugin"
    cp -rf "${DOWNLOADS_DIR}/quickrss.koplugin/quickrss.koplugin"/* "${STAGING_DIR}/opt/koreader/plugins/quickrss.koplugin/"
    cp -rf "${DOWNLOADS_DIR}/quickrss.koplugin/quickrss.koplugin"/* "${STAGING_DIR}/opt/bnrv700-shims/plugins/quickrss.koplugin/"
fi

# Install KOReader Audio Player plugin (MP3 playback via 3.5mm jack / Bluetooth)
if [ -d "${KOREADER_OVERLAY}/plugins/audioplayer.koplugin" ]; then
    mkdir -p "${STAGING_DIR}/opt/koreader/plugins/audioplayer.koplugin"
    mkdir -p "${STAGING_DIR}/opt/bnrv700-shims/plugins/audioplayer.koplugin"
    cp -rf "${KOREADER_OVERLAY}/plugins/audioplayer.koplugin"/* "${STAGING_DIR}/opt/koreader/plugins/audioplayer.koplugin/"
    cp -rf "${KOREADER_OVERLAY}/plugins/audioplayer.koplugin"/* "${STAGING_DIR}/opt/bnrv700-shims/plugins/audioplayer.koplugin/"
fi

# Install KOReader Read Aloud plugin (eSpeak-NG TTS via 3.5mm jack)
if [ -d "${KOREADER_OVERLAY}/plugins/readaloud.koplugin" ]; then
    mkdir -p "${STAGING_DIR}/opt/koreader/plugins/readaloud.koplugin"
    mkdir -p "${STAGING_DIR}/opt/bnrv700-shims/plugins/readaloud.koplugin"
    cp -rf "${KOREADER_OVERLAY}/plugins/readaloud.koplugin"/* "${STAGING_DIR}/opt/koreader/plugins/readaloud.koplugin/"
    cp -rf "${KOREADER_OVERLAY}/plugins/readaloud.koplugin"/* "${STAGING_DIR}/opt/bnrv700-shims/plugins/readaloud.koplugin/"
fi

# Install KOReader Plato Switcher plugin
if [ -d "${KOREADER_OVERLAY}/plugins/switch_plato.koplugin" ]; then
    mkdir -p "${STAGING_DIR}/opt/koreader/plugins/switch_plato.koplugin"
    mkdir -p "${STAGING_DIR}/opt/bnrv700-shims/plugins/switch_plato.koplugin"
    cp -rf "${KOREADER_OVERLAY}/plugins/switch_plato.koplugin"/* "${STAGING_DIR}/opt/koreader/plugins/switch_plato.koplugin/"
    cp -rf "${KOREADER_OVERLAY}/plugins/switch_plato.koplugin"/* "${STAGING_DIR}/opt/bnrv700-shims/plugins/switch_plato.koplugin/"
fi

# Install KOReader Battery Usage Monitor plugin
if [ -d "${KOREADER_OVERLAY}/plugins/batterytracker.koplugin" ]; then
    mkdir -p "${STAGING_DIR}/opt/koreader/plugins/batterytracker.koplugin"
    mkdir -p "${STAGING_DIR}/opt/bnrv700-shims/plugins/batterytracker.koplugin"
    cp -rf "${KOREADER_OVERLAY}/plugins/batterytracker.koplugin"/* "${STAGING_DIR}/opt/koreader/plugins/batterytracker.koplugin/"
    cp -rf "${KOREADER_OVERLAY}/plugins/batterytracker.koplugin"/* "${STAGING_DIR}/opt/bnrv700-shims/plugins/batterytracker.koplugin/"
fi

# Ensure Wallabag KOReader plugin is preserved in persistent shims
if [ -d "${STAGING_DIR}/opt/koreader/plugins/wallabag.koplugin" ]; then
    mkdir -p "${STAGING_DIR}/opt/bnrv700-shims/plugins/wallabag.koplugin"
    cp -rf "${STAGING_DIR}/opt/koreader/plugins/wallabag.koplugin"/* "${STAGING_DIR}/opt/bnrv700-shims/plugins/wallabag.koplugin/"
fi

# Deploy Plato Document Reader alongside KOReader
if [ -f "${DOWNLOADS_DIR}/plato-0.9.45.zip" ]; then
    echo "==> Deploying Plato Document Reader into /opt/plato/..."
    mkdir -p "${STAGING_DIR}/opt/plato"
    unzip -q -o "${DOWNLOADS_DIR}/plato-0.9.45.zip" -d "${STAGING_DIR}/opt/plato/"
    chmod +x "${STAGING_DIR}/opt/plato/plato"
    chmod +x "${STAGING_DIR}/opt/plato"/*.sh 2>/dev/null || true
    cp "${SYSTEM_OVERLAY}/start_plato.sh" "${STAGING_DIR}/opt/start_plato.sh"
    chmod +x "${STAGING_DIR}/opt/start_plato.sh"
    # Ensure glibc libstdc++ is included in Plato libs
    if [ -d "${DOWNLOADS_DIR}/libstdc++_extracted/usr/lib/arm-linux-gnueabihf" ]; then
        cp -a "${DOWNLOADS_DIR}/libstdc++_extracted/usr/lib/arm-linux-gnueabihf"/libstdc++.so.6* "${STAGING_DIR}/opt/plato/libs/" 2>/dev/null || true
    fi
    if [ -f "${ROOT_DIR}/build/libbnrv700_plato_shim.so" ]; then
        cp "${ROOT_DIR}/build/libbnrv700_plato_shim.so" "${STAGING_DIR}/opt/plato/libs/libbnrv700_plato_shim.so"
    fi
    if [ -f "${SYSTEM_OVERLAY}/Settings.toml" ]; then
        cp "${SYSTEM_OVERLAY}/Settings.toml" "${STAGING_DIR}/opt/plato/Settings.toml"
    fi
fi

# Install KOReader Plato Manager plugin
if [ -d "${KOREADER_OVERLAY}/plugins/platomanager.koplugin" ]; then
    mkdir -p "${STAGING_DIR}/opt/koreader/plugins/platomanager.koplugin"
    mkdir -p "${STAGING_DIR}/opt/bnrv700-shims/plugins/platomanager.koplugin"
    cp -rf "${KOREADER_OVERLAY}/plugins/platomanager.koplugin"/* "${STAGING_DIR}/opt/koreader/plugins/platomanager.koplugin/"
    cp -rf "${KOREADER_OVERLAY}/plugins/platomanager.koplugin"/* "${STAGING_DIR}/opt/bnrv700-shims/plugins/platomanager.koplugin/"
fi

# Install hardware button supervisor daemon and helper scripts
mkdir -p "${STAGING_DIR}/opt/bin" "${STAGING_DIR}/opt/scripts"
[ -f "${ROOT_DIR}/build/btn-watcher" ] && cp "${ROOT_DIR}/build/btn-watcher" "${STAGING_DIR}/opt/bin/btn-watcher"
[ -f "${ROOT_DIR}/build/epdc_probe" ] && cp "${ROOT_DIR}/build/epdc_probe" "${STAGING_DIR}/opt/bin/epdc_probe"
[ -f "${ROOT_DIR}/build/libSDL-1.2.so.0" ] && cp "${ROOT_DIR}/build/libSDL-1.2.so.0" "${STAGING_DIR}/opt/libSDL-1.2.so.0"
[ -f "${ROOT_DIR}/scripts/update_plato.sh" ] && cp "${ROOT_DIR}/scripts/update_plato.sh" "${STAGING_DIR}/opt/scripts/update_plato.sh"
[ -f "${ROOT_DIR}/scripts/toggle_frontlight.sh" ] && cp "${ROOT_DIR}/scripts/toggle_frontlight.sh" "${STAGING_DIR}/opt/scripts/toggle_frontlight.sh"
chmod +x "${STAGING_DIR}/opt/bin"/* "${STAGING_DIR}/opt/scripts"/* 2>/dev/null || true

# Ensure glibc loader compatibility symlink
ln -sf libc.so.6 "${STAGING_DIR}/lib/libc.so" 2>/dev/null || true

# Install Bluetooth & Audio management utilities
cp "${SYSTEM_OVERLAY}/enable-bluetooth.sh" "${STAGING_DIR}/opt/enable-bluetooth.sh"
cp "${SYSTEM_OVERLAY}/bt-manager.sh" "${STAGING_DIR}/opt/bt-manager.sh"
cp "${SYSTEM_OVERLAY}/audiocontrol.sh" "${STAGING_DIR}/opt/audiocontrol.sh"
cp "${SYSTEM_OVERLAY}/speak.sh" "${STAGING_DIR}/opt/speak.sh"
cp "${SYSTEM_OVERLAY}/battery_tracker.sh" "${STAGING_DIR}/opt/battery_tracker.sh"
ln -sf /opt/bt-manager.sh "${STAGING_DIR}/usr/bin/bt-manager" 2>/dev/null || true
ln -sf /opt/audiocontrol.sh "${STAGING_DIR}/usr/bin/audiocontrol" 2>/dev/null || true
ln -sf /opt/speak.sh "${STAGING_DIR}/usr/bin/speak" 2>/dev/null || true
ln -sf /opt/battery_tracker.sh "${STAGING_DIR}/usr/bin/battery-tracker" 2>/dev/null || true

# Install Realtek RTL8723DS Bluetooth UART initialization binary
mkdir -p "${STAGING_DIR}/usr/sbin"
if [ -f "${DOWNLOADS_DIR}/RTL8723DS_BT_Linux/rtk_hciattach/rtk_hciattach" ]; then
    cp "${DOWNLOADS_DIR}/RTL8723DS_BT_Linux/rtk_hciattach/rtk_hciattach" "${STAGING_DIR}/usr/sbin/rtk_hciattach"
    chmod +x "${STAGING_DIR}/usr/sbin/rtk_hciattach"
fi

# Install Realtek Bluetooth firmware for RTL8723DS
mkdir -p "${STAGING_DIR}/lib/firmware/rtlbt"
if [ -d "${DOWNLOADS_DIR}/RTL8723DS_BT_Linux/8723D" ]; then
    cp "${DOWNLOADS_DIR}/RTL8723DS_BT_Linux/8723D/rtl8723d_fw" "${STAGING_DIR}/lib/firmware/rtlbt/rtl8723d_fw" 2>/dev/null || true
    cp "${DOWNLOADS_DIR}/RTL8723DS_BT_Linux/8723D/rtl8723d_config" "${STAGING_DIR}/lib/firmware/rtlbt/rtl8723d_config" 2>/dev/null || true
    ln -sf rtl8723d_fw "${STAGING_DIR}/lib/firmware/rtlbt/rtl8723ds_fw" 2>/dev/null || true
    ln -sf rtl8723d_config "${STAGING_DIR}/lib/firmware/rtlbt/rtl8723ds_config" 2>/dev/null || true
fi

# Configure default ALSA sound routing (3.5mm Headphone Jack)
mkdir -p "${STAGING_DIR}/etc"
cat << 'ALSAEOF' > "${STAGING_DIR}/etc/asound.conf"
pcm.!default {
    type asym
    playback.pcm {
        type plug
        slave.pcm "hw:0,0"
    }
    capture.pcm {
        type plug
        slave.pcm "hw:0,0"
    }
}
ctl.!default {
    type hw
    card 0
}
ALSAEOF

chmod +x "${STAGING_DIR}/opt"/*.sh
chmod +x "${STAGING_DIR}/opt/koreader"/*.sh
chmod +x "${STAGING_DIR}/opt/bnrv700-shims"/*.sh

# Install BNRV700 hardware adaptation userpatch (survives OTA updates cleanly)
mkdir -p "${STAGING_DIR}/opt/koreader/patches"
cp "${KOREADER_OVERLAY}/1-bnrv700-hardware.lua" "${STAGING_DIR}/opt/1-bnrv700-hardware.lua"
cp "${KOREADER_OVERLAY}/1-bnrv700-hardware.lua" "${STAGING_DIR}/opt/koreader/patches/1-bnrv700-hardware.lua"

# Configure dropbear system SSH daemon
mkdir -p "${STAGING_DIR}/etc/dropbear"
ln -sf /usr/sbin/dropbear "${STAGING_DIR}/opt/koreader/dropbear" 2>/dev/null || true

# Prepare wpa_supplicant directories and configuration
mkdir -p "${STAGING_DIR}/run/wpa_supplicant" "${STAGING_DIR}/etc/wpa_supplicant"
cat << 'CONFFILE' > "${STAGING_DIR}/etc/wpa_supplicant/wpa_supplicant.conf"
ctrl_interface=/var/run/wpa_supplicant
update_config=1
CONFFILE
chmod 600 "${STAGING_DIR}/etc/wpa_supplicant/wpa_supplicant.conf"

# Install custom patched Cortex-A9 umtprd for /dev/mtp_usb
if [ -f "${ROOT_DIR}/build/umtprd" ]; then
    cp "${ROOT_DIR}/build/umtprd" "${STAGING_DIR}/bin/umtprd"
fi
ln -sf /bin/umtprd "${STAGING_DIR}/usr/bin/umtprd" 2>/dev/null || true
ln -sf /sbin/wpa_supplicant "${STAGING_DIR}/usr/sbin/wpa_supplicant" 2>/dev/null || true
ln -sf /sbin/wpa_cli "${STAGING_DIR}/usr/sbin/wpa_cli" 2>/dev/null || true
mkdir -p "${STAGING_DIR}/lib/firmware/rtlbt"
if [ -d "${DOWNLOADS_DIR}/android_firmware/firmware" ]; then
    cp -a "${DOWNLOADS_DIR}/android_firmware/firmware"/* "${STAGING_DIR}/lib/firmware/" 2>/dev/null || true
    cp -a "${DOWNLOADS_DIR}/android_firmware/firmware"/* "${STAGING_DIR}/lib/firmware/rtlbt/" 2>/dev/null || true
fi

# Unlock root in shadow for easy SSH
sed -i 's/^root:\*:/root::/' "${STAGING_DIR}/etc/shadow" 2>/dev/null || true

# Seed Kobo configuration and helper script for flawless device detection
cat << 'KOBOCFG' > "${STAGING_DIR}/bin/kobo_config.sh"
#!/bin/sh
echo "frost"
KOBOCFG
chmod 755 "${STAGING_DIR}/bin/kobo_config.sh"

mkdir -p "${STAGING_DIR}/mnt/onboard/.kobo/Kobo"
echo "dummy,dummy,4.38.23171,dummy" > "${STAGING_DIR}/mnt/onboard/.kobo/version"
touch "${STAGING_DIR}/mnt/onboard/.kobo/Kobo/Kobo eReader.conf"

# Copy NetSurf Choices
cp "${NETSURF_OVERLAY}/Choices" "${STAGING_DIR}/root/.netsurf/Choices"

# Copy KOReader button event map
cp "${KOREADER_OVERLAY}/event_map.lua" "${STAGING_DIR}/opt/koreader/settings/event_map.lua"
cp "${KOREADER_OVERLAY}/event_map.lua" "${STAGING_DIR}/opt/koreader/event_map.lua"

# Seed resolv.conf for initial chroot package management
cat << 'RESOLV' > "${STAGING_DIR}/etc/resolv.conf"
nameserver 1.1.1.1
nameserver 8.8.8.8
RESOLV

# Pre-configure apk repositories for main and community
cat << 'REPOS' > "${STAGING_DIR}/etc/apk/repositories"
https://dl-cdn.alpinelinux.org/alpine/v3.20/main
https://dl-cdn.alpinelinux.org/alpine/v3.20/community
REPOS

# Create musl library path configuration for proper dynamic linking
cat << 'LDPATH' > "${STAGING_DIR}/etc/ld-musl-armhf.path"
/usr/lib
/lib
/opt
LDPATH

echo "==> Step 7: Packaging payload into ${PAYLOAD_TAR}..."

# Write the release version marker (used by the boot-time self-update log
# and scripts/device_check.sh to identify the installed rootfs).
RELEASE_VERSION="${BNRV700_RELEASE:-$(git -C "${ROOT_DIR}" describe --tags --always --dirty 2>/dev/null || echo local)}"
printf 'bnrv700-rootfs %s %s\n' "${RELEASE_VERSION}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${STAGING_DIR}/etc/bnrv700-release"
echo "==> Version marker: bnrv700-rootfs ${RELEASE_VERSION}"

tar -czf "${PAYLOAD_TAR}" -C "${STAGING_DIR}" .

# Publish the payload checksum for the boot-time self-update verification.
( cd "${BUILD_DIR}" && sha256sum deploy_payload.tar.gz > deploy_payload.tar.gz.sha256 )
echo "==> Payload checksum: ${BUILD_DIR}/deploy_payload.tar.gz.sha256"

echo "==> Successfully created rootfs payload: ${PAYLOAD_TAR} ($(ls -lh "${PAYLOAD_TAR}" | awk '{print $5}'))"
