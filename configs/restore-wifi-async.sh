#!/bin/sh
# /opt/koreader/restore-wifi-async.sh - Background Wi-Fi reconnect for BNRV700

RestoreWifi() {
    echo "[$(date)] restore-wifi-async.sh: Restarting Wi-Fi"

    ./enable-wifi.sh

    INTERFACE="${INTERFACE:-wlan0}"
    wpac_timeout=0
    while ! wpa_cli -i "${INTERFACE}" status 2>/dev/null | grep -q "wpa_state=COMPLETED"; do
        if [ ${wpac_timeout} -ge 60 ]; then
            echo "[$(date)] restore-wifi-async.sh: Failed to connect to preferred AP!"
            ./disable-wifi.sh
            return 1
        fi
        usleep 250000 2>/dev/null || sleep 1
        wpac_timeout=$((wpac_timeout + 1))
    done

    ./obtain-ip.sh
    echo "[$(date)] restore-wifi-async.sh: Restarted Wi-Fi successfully"
}

RestoreWifi &
