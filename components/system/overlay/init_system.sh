#!/bin/sh
# /opt/init_system.sh - Alpine Userspace Init Entrypoint
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export HOME="/root"
export OPENSSL_armcap=0

echo "==> [init_system] Alpine Linux userspace booting at $(date)..."

# Ensure glibc loader compatibility symlink exists
[ ! -e /lib/libc.so ] && ln -sf libc.so.6 /lib/libc.so 2>/dev/null || true

# Enforce hardware panel orientation (1: 90 deg clockwise with header at physical top, Nook button at bottom)
echo 1 > /sys/class/graphics/fb0/rotate 2>/dev/null || true

# Direct visual splash on E Ink panel using LuaJIT FFI for full hardware wake-up
if [ -x /opt/koreader/luajit ] && [ -f /opt/splash.lua ]; then
    /opt/koreader/luajit /opt/splash.lua 2>/dev/null || true
fi

# 1. Dual-channel ComfortLight sysfs compatibility shadow
mkdir -p /tmp/fake_backlight
ln -sf /sys/devices/platform/imx-i2c.1/i2c-1/1-0038/backlight/lm3630a_leda /tmp/fake_backlight/lm3630a_leda
ln -sf /sys/devices/platform/imx-i2c.1/i2c-1/1-0038/backlight/lm3630a_ledb /tmp/fake_backlight/lm3630a_ledb
ln -sf /sys/devices/platform/imx-i2c.1/i2c-1/1-0038/backlight/lm3630a_led /tmp/fake_backlight/lm3630a_led
ln -sf /sys/devices/platform/mxc_msp430_fl.0/backlight/mxc_msp430_fl.0 /tmp/fake_backlight/mxc_msp430.0
ln -sf /sys/devices/platform/mxc_msp430_fl.0/backlight/mxc_msp430_fl.0 /tmp/fake_backlight/mxc_msp430_fl.0
ln -sf /sys/devices/platform/imx-i2c.1/i2c-1/1-0038/backlight/lm3630a_leda /tmp/fake_backlight/lm3630a_led1a
ln -sf /sys/devices/platform/imx-i2c.1/i2c-1/1-0038/backlight/lm3630a_ledb /tmp/fake_backlight/lm3630a_led1b
if ! grep -q "/tmp/fake_backlight" /proc/mounts 2>/dev/null; then
    mount --bind /tmp/fake_backlight /sys/class/backlight 2>/dev/null || true
fi

# 2. Hardware Audio Codec Probe (ALC5640/5645 for 3.5mm Headphone Jack)
if [ ! -d /proc/asound/card0 ]; then
    echo "==> [init_system] Initializing ALC5640/5645 hardware audio codec..."
    if [ -f /sys/bus/i2c/devices/i2c-0/new_device ]; then
        echo 0x1a > /sys/bus/i2c/devices/i2c-0/delete_device 2>/dev/null || true
        echo 0x1c > /sys/bus/i2c/devices/i2c-0/delete_device 2>/dev/null || true
        echo "rt5640 0x1a" > /sys/bus/i2c/devices/i2c-0/new_device 2>/dev/null || true
        echo "rt5640 0x1c" > /sys/bus/i2c/devices/i2c-0/new_device 2>/dev/null || true
    fi
fi

# Unmute ALSA headphone jack output channels
if command -v amixer >/dev/null 2>&1; then
    amixer -c 0 sset 'Headphone' 80% unmute 2>/dev/null || true
    amixer -c 0 sset 'DAC1' 80% unmute 2>/dev/null || true
    amixer -c 0 sset 'HP' 80% unmute 2>/dev/null || true
    amixer -c 0 sset 'Master' 80% unmute 2>/dev/null || true
fi

# 3. Start RTL8723DS Bluetooth (Audio A2DP + Keyboard HID)
if [ -x /opt/enable-bluetooth.sh ]; then
    echo "==> [init_system] Launching Bluetooth subsystem in background..."
    /bin/sh /opt/enable-bluetooth.sh >/var/log/bt_init.log 2>&1 &
fi

# 4. Bring up Wi-Fi and obtain a DHCP lease before starting network services.
# KOReader's OTA manager requires NetworkMgr to see an already-online link;
# relying on the interactive Wi-Fi menu leaves wlan0 absent or lease-less at
# boot on this device.
if [ -x /opt/koreader/enable-wifi.sh ]; then
    echo "==> [init_system] Bringing up Wi-Fi..."
    /bin/sh /opt/koreader/enable-wifi.sh >/var/log/wifi_init.log 2>&1 || true
    if [ -x /opt/koreader/obtain-ip.sh ]; then
        /bin/sh /opt/koreader/obtain-ip.sh >>/var/log/wifi_init.log 2>&1 || true
    fi
fi

# 5. Start dropbear SSH daemon for Wi-Fi debug/sideload
mkdir -p /etc/dropbear
if [ ! -x /usr/sbin/dropbear ] && [ -x /opt/koreader/dropbear ]; then
    ln -sf /opt/koreader/dropbear /usr/sbin/dropbear
fi

if [ -x /usr/sbin/dropbear ]; then
    echo "==> [init_system] Starting dropbear SSH daemon on port 22..."
    /usr/sbin/dropbear -R -B -p 22 2>/dev/null || true
elif [ -x /opt/koreader/dropbear ]; then
    echo "==> [init_system] Starting /opt/koreader/dropbear on port 22..."
    /opt/koreader/dropbear -R -B -p 22 2>/dev/null || true
fi

# 5. Configure USB gadget for concurrent MTP + ADB and start uMTP-Responder
if [ -d /sys/class/android_usb/android0 ]; then
    CURRENT_FUNC=$(cat /sys/class/android_usb/android0/functions 2>/dev/null)
    if [ "$CURRENT_FUNC" != "mtp,adb" ]; then
        echo "==> [init_system] Configuring USB gadget functions to mtp,adb..."
        /system/bin/setprop sys.usb.config mtp,adb 2>/dev/null || {
            echo 0 > /sys/class/android_usb/android0/enable 2>/dev/null || true
            echo "mtp,adb" > /sys/class/android_usb/android0/functions 2>/dev/null || true
            echo 1 > /sys/class/android_usb/android0/enable 2>/dev/null || true
        }
    fi
fi

# Launch uMTP-Responder daemon for PC file management
if [ -x /bin/umtprd ] || [ -x /usr/bin/umtprd ]; then
    UMTPRD_BIN="/usr/bin/umtprd"
    [ -x /bin/umtprd ] && UMTPRD_BIN="/bin/umtprd"
    if [ -f /etc/umtprd/umtprd.conf ] && ! pgrep -x umtprd >/dev/null 2>&1; then
        echo "==> [init_system] Launching uMTP-Responder MTP daemon..."
        $UMTPRD_BIN -conf /etc/umtprd/umtprd.conf >/var/log/umtprd.log 2>&1 &
    fi
fi

# Ensure unified books library symlinks
mkdir -p /data/media/0/Books
[ ! -e /data/books ] && ln -sfn /data/media/0/Books /data/books || true
[ ! -e /home/books ] && ln -sfn /data/media/0/Books /home/books || true
[ ! -e /root/books ] && ln -sfn /data/media/0/Books /root/books || true

# 6. Launch Syncthing headlessly in background
mkdir -p /data/syncthing/config /data/syncthing/notes /sdcard/Music
if [ -x /usr/bin/syncthing ]; then
    su -s /bin/sh -c "syncthing -home=/data/syncthing/config -gui-address=0.0.0.0:8384 &" root 2>/dev/null || true
fi

# 7. Start background battery usage logger (records every 5 minutes)
if [ -x /opt/battery_tracker.sh ]; then
    ( while true; do
        /bin/sh /opt/battery_tracker.sh log 2>/dev/null || true
        sleep 300
      done
    ) &
fi

# 8. Start Hardware Button Supervisor Daemon (btn-watcher)
if [ -x /opt/bin/btn-watcher ]; then
    echo "==> [init_system] Launching hardware button supervisor daemon (btn-watcher)..."
    pkill -x btn-watcher 2>/dev/null || true
    /opt/bin/btn-watcher /dev/input/event0 >/var/log/btn-watcher.log 2>&1 &
    sleep 1
    # Create by-path symlink so Plato and other readers detect virtual button device
    VIRT_EVENT=$(grep -l "nook-virtual-keys" /sys/class/input/event*/device/name 2>/dev/null | sed 's|/sys/class/input/||; s|/device/name||' | head -n 1)
    if [ -n "$VIRT_EVENT" ]; then
        mkdir -p /dev/input/by-path
        ln -sf "/dev/input/$VIRT_EVENT" /dev/input/by-path/platform-gpio-keys-event
    fi
fi

# 9. Unified font sharing initialization across KOReader, Plato, NetSurf, and system
mkdir -p /usr/share/fonts/shared /opt/koreader/fonts /opt/plato/fonts
[ ! -e /opt/koreader/fonts/shared ] && ln -sfn /usr/share/fonts/shared /opt/koreader/fonts/shared || true
[ ! -e /opt/koreader/fonts/system ] && ln -sfn /system/fonts /opt/koreader/fonts/system || true
for f in /usr/share/fonts/shared/*; do
    [ -f "$f" ] && ln -sf "$f" "/opt/plato/fonts/$(basename "$f")" 2>/dev/null || true
done

# 10. Dynamic reader supervisor loop (supports seamless switching between KOReader and Plato)
echo "==> [init_system] Launching reader supervisor loop..."
echo "koreader" > /tmp/current_app
echo "koreader" > /tmp/active_reader
export KO_DONT_GRAB_INPUT=1


while true; do
    ACTIVE=$(cat /tmp/current_app 2>/dev/null || cat /tmp/active_reader 2>/dev/null || echo "koreader")
    if [ "$ACTIVE" = "plato" ] && [ -x /opt/start_plato.sh ]; then
        echo "==> [supervisor] Starting Plato Document Reader..."
        /bin/sh /opt/start_plato.sh
        echo "koreader" > /tmp/current_app
        echo "koreader" > /tmp/active_reader
    elif [ "$ACTIVE" = "netsurf" ] && [ -x /opt/start_browser.sh ]; then
        echo "==> [supervisor] Starting NetSurf Browser..."
        /bin/sh /opt/start_browser.sh
        echo "koreader" > /tmp/current_app
        echo "koreader" > /tmp/active_reader
    else
        echo "==> [supervisor] Starting KOReader..."
        /bin/sh /opt/start_koreader.sh
    fi
    sleep 1
done
