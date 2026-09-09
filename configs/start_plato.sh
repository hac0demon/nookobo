#!/bin/sh
# /opt/start_plato.sh - Launch Plato Document Reader on BNRV700
export PATH="/opt/plato/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LD_LIBRARY_PATH="/opt/plato/libs:/lib:$LD_LIBRARY_PATH"
export LD_PRELOAD="/opt/plato/libs/libbnrv700_plato_shim.so"
export PRODUCT="daylight"
export MODEL_NUMBER="381"
cd /opt/plato

echo "[start_plato] Launching Plato Document Reader at $(date)..."

# Ensure mutually exclusive execution: terminate any running KOReader instances
pkill -9 -f reader.lua 2>/dev/null || true
pkill -9 -f start_koreader.sh 2>/dev/null || true

# Ensure books directory exists
mkdir -p /data/books

# Setup shadow sysfs for Plato dual-channel frontlight & EPDC
if ! grep -q "/tmp/fake_backlight" /proc/mounts 2>/dev/null; then
    mkdir -p /tmp/fake_backlight
    ln -sfn /sys/devices/platform/imx-i2c.1/i2c-1/1-0038/backlight/lm3630a_leda /tmp/fake_backlight/lm3630a_leda
    ln -sfn /sys/devices/platform/imx-i2c.1/i2c-1/1-0038/backlight/lm3630a_ledb /tmp/fake_backlight/lm3630a_ledb
    ln -sfn /sys/devices/platform/imx-i2c.1/i2c-1/1-0038/backlight/lm3630a_led /tmp/fake_backlight/lm3630a_led
    ln -sfn /sys/devices/platform/mxc_msp430_fl.0/backlight/mxc_msp430_fl.0 /tmp/fake_backlight/mxc_msp430.0
    ln -sfn /sys/devices/platform/mxc_msp430_fl.0/backlight/mxc_msp430_fl.0 /tmp/fake_backlight/mxc_msp430_fl.0
    ln -sfn /sys/devices/platform/imx-i2c.1/i2c-1/1-0038/backlight/lm3630a_leda /tmp/fake_backlight/lm3630a_led1a
    ln -sfn /sys/devices/platform/imx-i2c.1/i2c-1/1-0038/backlight/lm3630a_ledb /tmp/fake_backlight/lm3630a_led1b
    mount --bind /tmp/fake_backlight /sys/class/backlight 2>/dev/null || true
fi

# Hardware EPDC auto-refresh for Plato
if [ -f /sys/class/graphics/fb0/epdc_auto_update ]; then
    echo 1 > /sys/class/graphics/fb0/epdc_auto_update
fi

# Launch Plato targeting books directory using glibc loader
/lib/ld-2.19.so --library-path /opt/plato/libs:/lib ./plato /data/books
STATUS=$?
echo "[start_plato] Plato exited with status $STATUS"

# Reset active reader to KOReader upon exit
echo "koreader" > /tmp/current_app
echo "koreader" > /tmp/active_reader
exit $STATUS
