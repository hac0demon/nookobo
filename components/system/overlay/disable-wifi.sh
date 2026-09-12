#!/bin/sh
# /opt/koreader/disable-wifi.sh - Wi-Fi teardown script for BNRV700 / Quill

echo "[disable-wifi.sh] Disabling Wi-Fi..."

INTERFACE="${INTERFACE:-wlan0}"

# 1. Stop DHCP client
if [ -x "/sbin/dhcpcd" ]; then
    dhcpcd -k "${INTERFACE}" 2>/dev/null || true
fi
killall -q -TERM udhcpc dhcpcd 2>/dev/null || true

# 2. Terminate wpa_supplicant
if [ -x /sbin/wpa_cli ]; then
    wpa_cli -i "${INTERFACE}" terminate 2>/dev/null || true
fi
killall -q -TERM wpa_supplicant 2>/dev/null || true
rm -f "/var/run/wpa_supplicant/${INTERFACE}" 2>/dev/null || true

# 3. Bring interface down
ifconfig "${INTERFACE}" 0.0.0.0 down 2>/dev/null || true

# 4. Unload module if loaded
if grep -q "^8723ds " /proc/modules; then
    rmmod 8723ds 2>/dev/null || true
fi

# 5. Power off Wi-Fi chip via /dev/ntx_io (ioctl 208 = CM_WIFI_CTRL, 0 = OFF)
if [ -e /dev/ntx_io ]; then
    /opt/koreader/luajit /opt/koreader/frontend/device/kobo/ntx_io.lua 208 0 2>/dev/null || true
fi

echo "[disable-wifi.sh] Wi-Fi disabled successfully."
exit 0
