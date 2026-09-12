#!/bin/sh
# /opt/start_browser.sh - Launch NetSurf directly on /dev/fb0 with EPDC auto-refresh
# Target panel: 1404x1872 @ 16-bit E Ink Carta HD

export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export HOME=/root
export FRAMEBUFFER=/dev/fb0
export TSLIB_TSDEVICE=/dev/input/event1
export TSLIB_CALIBFILE=/etc/pointercal
export OPENSSL_armcap=0
export LD_LIBRARY_PATH=/usr/lib:/lib:/opt

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

# Check Wi-Fi state before browser launch; if off, enable it for NetSurf
WIFI_WAS_OFF=0
if ! grep -q "^8723ds " /proc/modules 2>/dev/null || ! [ -d /sys/class/net/wlan0 ]; then
    WIFI_WAS_OFF=1
    echo "[start_browser] Wi-Fi is currently off, enabling for NetSurf..."
    if [ -x /opt/koreader/enable-wifi.sh ]; then
        /opt/koreader/enable-wifi.sh
    fi
fi

# Ensure an IP address is obtained and route is active before opening browser
if ! ifconfig wlan0 2>/dev/null | grep -q "inet addr:"; then
    echo "[start_browser] Requesting DHCP lease on wlan0..."
    if [ -x /opt/koreader/obtain-ip.sh ]; then
        /opt/koreader/obtain-ip.sh
    fi
    # Wait up to 6 seconds for an IP address and default route
    for _ in 1 2 3 4 5 6; do
        if ifconfig wlan0 2>/dev/null | grep -q "inet addr:"; then
            echo "[start_browser] Network is connected: $(ifconfig wlan0 | grep 'inet addr:')"
            break
        fi
        sleep 1
    done
fi

TARGET_URL="${1:-https://lite.duckduckgo.com}"
echo "==> [start_browser] Launching netsurf-fb at ${TARGET_URL}..."

touch /tmp/netsurf_running

# Start remote phone keyboard web daemon on port 8080 if not already running
if [ -x /opt/bin/nook-webkey ] && ! pgrep -x nook-webkey >/dev/null 2>&1; then
    echo "[start_browser] Starting nook-webkey remote phone input server on port 8080..."
    /opt/bin/nook-webkey >/var/log/nook-webkey.log 2>&1 &
fi

# Wipe framebuffer and perform full GC16 hardware refresh to eliminate reader ghosting
if [ -x /opt/koreader/luajit ]; then
    /opt/koreader/luajit -e '
        local ffi = require("ffi")
        local C = ffi.C
        ffi.cdef[[
            int open(const char *path, int flags);
            int close(int fd);
            int ioctl(int fd, unsigned long req, ...);
            void *memset(void *s, int c, size_t n);
            void *mmap(void *addr, size_t length, int prot, int flags, int fd, long offset);
            int munmap(void *addr, size_t length);
        ]]
        local fd = C.open("/dev/fb0", 2)
        if fd >= 0 then
            local mem = C.mmap(nil, 2816 * 1872, 3, 1, fd, 0)
            if mem ~= nil and ffi.cast("intptr_t", mem) ~= -1 then
                C.memset(mem, 0xFF, 2816 * 1872)
                C.munmap(mem, 2816 * 1872)
            end
            local upd = ffi.new("char[64]")
            ffi.cast("uint32_t*", upd)[0] = 0 -- top
            ffi.cast("uint32_t*", upd)[1] = 0 -- left
            ffi.cast("uint32_t*", upd)[2] = 1404 -- width
            ffi.cast("uint32_t*", upd)[3] = 1872 -- height
            ffi.cast("uint32_t*", upd)[4] = 2 -- GC16
            ffi.cast("uint32_t*", upd)[5] = 1 -- FULL (0 = PARTIAL, 1 = FULL)
            ffi.cast("int*", upd)[7] = 4096 -- ambient temp (TEMP_USE_AMBIENT = 4096)
            C.ioctl(fd, 0x4040462e, upd)
            C.close(fd)
        end
    ' 2>/dev/null || true
fi

# Launch NetSurf with custom direct Linux /dev/fb0 SDL 1.2 shim
if [ -x /usr/bin/netsurf-fb ]; then
    LD_LIBRARY_PATH=/usr/lib:/lib:/opt LD_PRELOAD="/opt/libSDL-1.2.so.0" /usr/bin/netsurf-fb -f sdl -w 1404 -h 1872 -b 16 "${TARGET_URL}" >> /var/log/netsurf.log 2>&1
    RET=$?
    echo "[start_browser] netsurf-fb exited with status $RET at $(date)" >> /var/log/netsurf.log
elif [ -x /usr/local/bin/netsurf-fb ]; then
    LD_LIBRARY_PATH=/usr/lib:/lib:/opt LD_PRELOAD="/opt/libSDL-1.2.so.0" /usr/local/bin/netsurf-fb -f sdl -w 1404 -h 1872 -b 16 "${TARGET_URL}" >> /var/log/netsurf.log 2>&1
    RET=$?
    echo "[start_browser] netsurf-fb exited with status $RET at $(date)" >> /var/log/netsurf.log
else
    echo "ERROR: netsurf-fb binary not found in /usr/bin or /usr/local/bin!" >> /var/log/netsurf.log
fi

rm -f /tmp/netsurf_running

# If Wi-Fi was off before starting browser, turn it back off to save battery
if [ "$WIFI_WAS_OFF" = "1" ] && [ -x /opt/koreader/disable-wifi.sh ]; then
    echo "[start_browser] Restoring Wi-Fi to previous OFF state to conserve power..."
    /opt/koreader/disable-wifi.sh
fi

# When browser exits, disable EPDC auto-update so KOReader has exclusive waveform control
if [ -f /sys/class/graphics/fb0/epdc_auto_update ]; then
    echo 0 > /sys/class/graphics/fb0/epdc_auto_update 2>/dev/null || true
fi
