#!/bin/sh
# /opt/koreader/release-ip.sh - Release DHCP lease for BNRV700

INTERFACE="${INTERFACE:-wlan0}"

if [ -x "/sbin/dhcpcd" ]; then
    dhcpcd -k "${INTERFACE}" 2>/dev/null || true
fi
killall -q -TERM udhcpc dhcpcd 2>/dev/null || true
ifconfig "${INTERFACE}" 0.0.0.0 2>/dev/null || true
