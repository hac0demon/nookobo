#!/bin/sh
# /opt/koreader/obtain-ip.sh - Obtain DHCP lease for BNRV700

INTERFACE="${INTERFACE:-wlan0}"

# Close any non-standard fds
for fd in /proc/"$$"/fd/*; do
    fd_id="$(basename "${fd}")"
    if [ -e "${fd}" ] && [ "${fd_id}" -gt 2 ]; then
        eval "exec ${fd_id}>&-" 2>/dev/null || true
    fi
done

echo "[obtain-ip.sh] Requesting DHCP lease on ${INTERFACE} via udhcpc..."
UDHCPC_SCRIPT="/usr/share/udhcpc/default.script"
if [ ! -f "${UDHCPC_SCRIPT}" ]; then
    UDHCPC_SCRIPT="/etc/udhcpc/default.script"
fi

# Use BusyBox udhcpc (Linux 3.0.35 kernel does not support BPF required by dhcpcd)
if [ -f "${UDHCPC_SCRIPT}" ]; then
    udhcpc -i "${INTERFACE}" -n -q -s "${UDHCPC_SCRIPT}" -b
else
    udhcpc -i "${INTERFACE}" -n -q -b
fi
