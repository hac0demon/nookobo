#!/bin/sh
# /opt/koreader/enable-wifi.sh - Wi-Fi bringup script for BNRV700 / Quill

echo "[enable-wifi.sh] Enabling Wi-Fi for BNRV700..."

# Close any non-standard fds to prevent leaking into child processes
for fd in /proc/"$$"/fd/*; do
    fd_id="$(basename "${fd}")"
    if [ -e "${fd}" ] && [ "${fd_id}" -gt 2 ]; then
        eval "exec ${fd_id}>&-" 2>/dev/null || true
    fi
done

INTERFACE="${INTERFACE:-wlan0}"

# 1. Power on Wi-Fi chip via /dev/ntx_io (ioctl 208 = CM_WIFI_CTRL, 1 = ON)
if [ -e /dev/ntx_io ]; then
    echo "[enable-wifi.sh] Powering on Wi-Fi chip via /dev/ntx_io..."
    /opt/koreader/luajit /opt/koreader/frontend/device/kobo/ntx_io.lua 208 1 2>/dev/null || true
    usleep 250000 2>/dev/null || sleep 1
fi

# 2. Load Realtek 8723ds kernel module if not already loaded
if ! grep -q "^8723ds " /proc/modules; then
    echo "[enable-wifi.sh] Loading 8723ds kernel module..."
    if [ -f /lib/modules/8723ds.ko ]; then
        insmod /lib/modules/8723ds.ko ifname="${INTERFACE}" if2name=p2p0 2>/dev/null || true
    elif [ -f /system/wifi/8723ds.ko ]; then
        insmod /system/wifi/8723ds.ko ifname="${INTERFACE}" if2name=p2p0 2>/dev/null || true
    fi
    usleep 500000 2>/dev/null || sleep 1
fi

# 3. Wait up to 3 seconds for network interface to appear
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if [ -d "/sys/class/net/${INTERFACE}" ]; then
        echo "[enable-wifi.sh] Interface ${INTERFACE} detected in sysfs."
        break
    fi
    usleep 200000 2>/dev/null || sleep 1
done

# 4. Bring the network interface UP
ifconfig "${INTERFACE}" up 2>/dev/null || true

# 5. Prepare wpa_supplicant control directory and configuration
mkdir -p /var/run/wpa_supplicant /run/wpa_supplicant /etc/wpa_supplicant
chmod 755 /var/run/wpa_supplicant /run/wpa_supplicant 2>/dev/null || true

if [ ! -f /etc/wpa_supplicant/wpa_supplicant.conf ]; then
    cat << 'CONFEOF' > /etc/wpa_supplicant/wpa_supplicant.conf
ctrl_interface=/var/run/wpa_supplicant
update_config=1
CONFEOF
    chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf
fi

# Remove stale control socket if it exists
rm -f "/var/run/wpa_supplicant/${INTERFACE}" 2>/dev/null || true

# 6. Start wpa_supplicant daemon if not already running
if ! pkill -0 wpa_supplicant 2>/dev/null; then
    echo "[enable-wifi.sh] Starting wpa_supplicant on ${INTERFACE}..."
    wpa_supplicant -D nl80211 -i "${INTERFACE}" -c /etc/wpa_supplicant/wpa_supplicant.conf -C /var/run/wpa_supplicant -B
    
    # Wait up to 2 seconds for control socket to be created
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if [ -S "/var/run/wpa_supplicant/${INTERFACE}" ]; then
            echo "[enable-wifi.sh] Control socket /var/run/wpa_supplicant/${INTERFACE} is ready."
            break
        fi
        usleep 200000 2>/dev/null || sleep 1
    done
fi

echo "[enable-wifi.sh] Wi-Fi enabled successfully."
exit 0
