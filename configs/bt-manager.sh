#!/bin/sh
# /opt/bt-manager.sh - Bluetooth Device Manager (Keyboard & Audio)

ACTION="${1:-status}"
ARG="${2:-}"

case "$ACTION" in
    on|enable)
        /bin/sh /opt/enable-bluetooth.sh
        ;;

    off|disable)
        pkill -x bluealsa 2>/dev/null || true
        pkill -x bluetoothd 2>/dev/null || true
        pkill -x rtk_hciattach 2>/dev/null || true
        if [ -e /sys/class/rfkill/rfkill0/state ]; then
            echo 0 > /sys/class/rfkill/rfkill0/state
        fi
        echo "[bluetooth] Bluetooth disabled."
        ;;

    scan)
        /bin/sh /opt/enable-bluetooth.sh >/dev/null 2>&1
        echo "Scanning for Bluetooth devices (5s)..."
        bluetoothctl --timeout 5 scan on 2>/dev/null || true
        echo "--- Available Devices ---"
        bluetoothctl devices 2>/dev/null || echo "No devices found"
        ;;

    pair|connect)
        if [ -z "$ARG" ]; then
            echo "Usage: $0 connect <MAC_ADDRESS>"
            exit 1
        fi
        /bin/sh /opt/enable-bluetooth.sh >/dev/null 2>&1
        echo "Pairing and connecting to $ARG..."
        bluetoothctl pair "$ARG" 2>/dev/null || true
        bluetoothctl trust "$ARG" 2>/dev/null || true
        bluetoothctl connect "$ARG" 2>/dev/null || true
        ;;

    disconnect)
        if [ -z "$ARG" ]; then
            echo "Usage: $0 disconnect <MAC_ADDRESS>"
            exit 1
        fi
        bluetoothctl disconnect "$ARG" 2>/dev/null || true
        ;;

    status)
        echo "--- Bluetooth Status ---"
        if pgrep -x rtk_hciattach >/dev/null 2>&1; then
            echo "Controller: Active (rtk_hciattach running)"
        else
            echo "Controller: Inactive"
        fi
        if command -v hciconfig >/dev/null 2>&1; then
            hciconfig -a 2>/dev/null || true
        fi
        echo "--- Paired Devices ---"
        bluetoothctl paired-devices 2>/dev/null || echo "None"
        ;;

    *)
        echo "Usage: $0 {on|off|scan|connect <MAC>|disconnect <MAC>|status}"
        exit 1
        ;;
esac
