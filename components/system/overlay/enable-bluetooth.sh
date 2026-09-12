#!/bin/sh
# /opt/enable-bluetooth.sh - Initialize Realtek RTL8723DS Bluetooth on BNRV700
set -e

echo "[bluetooth] Initializing RTL8723DS Bluetooth..."

# 1. Unblock rfkill
if [ -e /sys/class/rfkill/rfkill0/state ]; then
    echo 0 > /sys/class/rfkill/rfkill0/state
    sleep 0.2
    echo 1 > /sys/class/rfkill/rfkill0/state
    sleep 0.5
fi

# Ensure UART permissions
chmod 666 /dev/ttymxc1 2>/dev/null || true

# 2. Attach UART controller via rtk_hciattach
if ! pgrep -x rtk_hciattach >/dev/null 2>&1; then
    echo "[bluetooth] Attaching /dev/ttymxc1 via rtk_hciattach..."
    HCIATTACH_BIN=""
    if [ -x /usr/sbin/rtk_hciattach ]; then
        HCIATTACH_BIN="/usr/sbin/rtk_hciattach"
    elif [ -x /usr/bin/rtk_hciattach ]; then
        HCIATTACH_BIN="/usr/bin/rtk_hciattach"
    elif [ -x /opt/rtk_hciattach ]; then
        HCIATTACH_BIN="/opt/rtk_hciattach"
    fi

    if [ -n "$HCIATTACH_BIN" ]; then
        $HCIATTACH_BIN -n -s 115200 /dev/ttymxc1 rtk_h5 1500000 >/var/log/rtk_hciattach.log 2>&1 &
        sleep 2
    else
        echo "[bluetooth] WARNING: rtk_hciattach not found!"
    fi
fi

# 3. Bring up hci0 interface
if command -v hciconfig >/dev/null 2>&1; then
    hciconfig hci0 up 2>/dev/null || true
fi

# 4. Start system D-Bus daemon
mkdir -p /var/run/dbus
if ! pgrep -x dbus-daemon >/dev/null 2>&1; then
    echo "[bluetooth] Starting system dbus-daemon..."
    dbus-uuidgen --ensure 2>/dev/null || true
    dbus-daemon --system --fork 2>/dev/null || true
    sleep 0.5
fi

# 5. Start bluetoothd daemon
if ! pgrep -x bluetoothd >/dev/null 2>&1; then
    echo "[bluetooth] Starting bluetoothd daemon..."
    mkdir -p /var/lib/bluetooth
    if [ -x /usr/lib/bluetooth/bluetoothd ]; then
        /usr/lib/bluetooth/bluetoothd --compat --nodetachs >/var/log/bluetoothd.log 2>&1 &
    elif [ -x /usr/libexec/bluetooth/bluetoothd ]; then
        /usr/libexec/bluetooth/bluetoothd --compat --nodetachs >/var/log/bluetoothd.log 2>&1 &
    fi
    sleep 1
fi

# 6. Start bluealsa daemon for A2DP audio streaming
if command -v bluealsa >/dev/null 2>&1; then
    if ! pgrep -x bluealsa >/dev/null 2>&1; then
        echo "[bluetooth] Starting bluealsa daemon..."
        bluealsa -p a2dp-source -p a2dp-sink >/var/log/bluealsa.log 2>&1 &
    fi
fi

echo "[bluetooth] Bluetooth stack initialized successfully."
