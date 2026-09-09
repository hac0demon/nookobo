#!/bin/sh
# /opt/start_browser.sh - Launch NetSurf directly on /dev/fb0 with EPDC auto-refresh
# Target panel: 1404x1872 @ 16-bit E Ink Carta HD

export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export HOME=/root
export FRAMEBUFFER=/dev/fb0
export TSLIB_TSDEVICE=/dev/input/event1
export TSLIB_CALIBFILE=/etc/pointercal

# Ensure EPDC auto-update is enabled so browser writes immediately flash to E Ink
if [ -f /sys/class/graphics/fb0/epdc_auto_update ]; then
    echo 1 > /sys/class/graphics/fb0/epdc_auto_update 2>/dev/null || true
    echo 2 > /sys/class/graphics/fb0/epdc_waveform_mode 2>/dev/null || true
fi

# Ensure font configuration exists
mkdir -p /root/.netsurf
if [ ! -f /root/.netsurf/Choices ] && [ -f /etc/netsurf/Choices ]; then
    cp /etc/netsurf/Choices /root/.netsurf/Choices 2>/dev/null || true
fi

TARGET_URL="${1:-https://lite.duckduckgo.com}"
echo "==> [start_browser] Launching netsurf-fb at ${TARGET_URL}..."

touch /tmp/netsurf_running

# Launch NetSurf with custom direct Linux /dev/fb0 SDL 1.2 shim
if [ -x /usr/bin/netsurf-fb ]; then
    LD_PRELOAD="/opt/libSDL-1.2.so.0" /usr/bin/netsurf-fb -f sdl -w 1404 -h 1872 -b 16 "${TARGET_URL}" >> /var/log/netsurf.log 2>&1
    RET=$?
    echo "[start_browser] netsurf-fb exited with status $RET at $(date)" >> /var/log/netsurf.log
elif [ -x /usr/local/bin/netsurf-fb ]; then
    LD_PRELOAD="/opt/libSDL-1.2.so.0" /usr/local/bin/netsurf-fb -f sdl -w 1404 -h 1872 -b 16 "${TARGET_URL}" >> /var/log/netsurf.log 2>&1
    RET=$?
    echo "[start_browser] netsurf-fb exited with status $RET at $(date)" >> /var/log/netsurf.log
else
    echo "ERROR: netsurf-fb binary not found in /usr/bin or /usr/local/bin!" >> /var/log/netsurf.log
fi

rm -f /tmp/netsurf_running

# When browser exits, disable EPDC auto-update so KOReader has exclusive waveform control
if [ -f /sys/class/graphics/fb0/epdc_auto_update ]; then
    echo 0 > /sys/class/graphics/fb0/epdc_auto_update 2>/dev/null || true
fi
