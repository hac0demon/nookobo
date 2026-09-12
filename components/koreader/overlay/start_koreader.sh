#!/bin/sh
# /opt/start_koreader.sh - Standalone KOReader launcher for BNRV700
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export FRAMEBUFFER=/dev/fb0
export KO_DONT_GRAB_INPUT=1
export KOR_INPUT_TOUCH=/dev/input/event1
export KOR_INPUT_KEYS=/dev/input/event2

export PRODUCT="daylight"
export MODEL_NUMBER="373"
export KOREADER_DIR="/opt/koreader"
export EXT_FONT_DIR="/usr/share/fonts/shared:/system/fonts"

# Wi-Fi networking variables for Realtek 8723DS on BNRV700
export INTERFACE="wlan0"
export WIFI_MODULE="8723ds"
export WPA_SUPPLICANT_DRIVER="nl80211,wext"

# Ensure mutually exclusive execution: terminate any running Plato instances
pkill -9 -f plato 2>/dev/null || true
pkill -9 -f start_plato.sh 2>/dev/null || true

mkdir -p /data/books
mkdir -p /mnt/onboard/.kobo/Kobo
mkdir -p /var/run/wpa_supplicant /run/wpa_supplicant /etc/wpa_supplicant
chmod 755 /var/run/wpa_supplicant /run/wpa_supplicant 2>/dev/null || true
if [ ! -f /etc/wpa_supplicant/wpa_supplicant.conf ]; then
    cat << 'EOF' > /etc/wpa_supplicant/wpa_supplicant.conf
ctrl_interface=/var/run/wpa_supplicant
update_config=1
EOF
    chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf
fi
echo "dummy,dummy,4.38.23171,dummy,dummy,373" > /mnt/onboard/.kobo/version
[ -f "/mnt/onboard/.kobo/Kobo/Kobo eReader.conf" ] || touch "/mnt/onboard/.kobo/Kobo/Kobo eReader.conf"

# Ensure persistent patches and shims directory exists
mkdir -p /opt/koreader/patches
if [ -f /opt/1-bnrv700-hardware.lua ]; then
    cp -f /opt/1-bnrv700-hardware.lua /opt/koreader/patches/1-bnrv700-hardware.lua
fi

apply_bnrv700_shims() {
    if [ -d /opt/bnrv700-shims ]; then
        echo "==> [start_koreader] Linking BNRV700 hardware shims into /opt/koreader..."
        for s in /opt/bnrv700-shims/*.sh; do
            if [ -f "$s" ]; then
                ln -sf "$s" "/opt/koreader/$(basename "$s")"
            fi
        done
        if [ -d /opt/bnrv700-shims/plugins ]; then
            mkdir -p /opt/koreader/plugins
            for p in /opt/bnrv700-shims/plugins/*; do
                if [ -e "$p" ]; then
                    ln -sfn "$p" "/opt/koreader/plugins/$(basename "$p")"
                fi
            done
        fi
        chmod +x /opt/bnrv700-shims/*.sh 2>/dev/null || true
    fi
    if [ -f /opt/1-bnrv700-hardware.lua ]; then
        mkdir -p /opt/koreader/patches
        ln -sf /opt/1-bnrv700-hardware.lua /opt/koreader/patches/1-bnrv700-hardware.lua 2>/dev/null || true
    fi
}

# Initial synchronization of hardware shims
apply_bnrv700_shims

cd /opt/koreader

# KOReader's bundled OTA package.index (including the 2024.07 bundle) expects
# this marker while creating the local zsync input package.  Some release
# archives omit the empty file, which makes tar return non-zero and causes the
# integrated updater to report a generic update failure before zsync starts.
[ -e /opt/koreader/update_once.marker ] || : > /opt/koreader/update_once.marker

# Supervisor execution loop: handles in-app OTA upgrades (exit code 85)
while true; do
    # Check for downloaded OTA update tarball from KOReader update workflow
    if [ -f /opt/koreader/ota/koreader.updated.tar ]; then
        echo "==> [OTA] Detected pending update: /opt/koreader/ota/koreader.updated.tar"
        echo "==> [OTA] Unpacking update into /opt/koreader..."
        tar -xf /opt/koreader/ota/koreader.updated.tar -C /opt/koreader --strip-components=1 2>&1
        rm -f /opt/koreader/ota/koreader.updated.tar 2>/dev/null || true

        # Re-apply BNRV700 hardware shims over updated binaries
        apply_bnrv700_shims
        sync
        echo "==> [OTA] Update successfully applied! Restarting KOReader..."
    fi

    echo "==> [start_koreader] Launching ./reader.lua /data/books/ at $(date)..."
    ./reader.lua /data/books/ "$@"
    RET=$?
    echo "==> [start_koreader] ./reader.lua exited with code ${RET}"

    # Return code 85 indicates user requested restart or OTA update installation
    if [ "${RET}" -eq 85 ]; then
        echo "==> [start_koreader] Restart requested (code 85). Re-checking for updates and respawning..."
        sleep 1
        continue
    fi

    # Any other exit code breaks loop and returns to init supervisor
    break
done
