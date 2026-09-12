#!/system/bin/sh
# /data/boot_linux.sh - Early init bootstrapper for Alpine Linux chroot on BNRV700
# Decouples userspace from Android Dalvik/SurfaceFlinger into native Linux

trap "" HUP INT

LOGFILE="/data/boot_linux.log"
PIDFILE="/dev/.boot_linux.pid"

# Clean up any stale persistent pidfile from previous versions
rm -f /data/boot_linux.pid 2>/dev/null || true

# Guard against duplicate concurrent execution
if [ -f "${PIDFILE}" ]; then
    OLDPID=$(cat "${PIDFILE}" 2>/dev/null || true)
    if [ -n "${OLDPID}" ] && [ -d "/proc/${OLDPID}" ] && grep -q "boot_linux" "/proc/${OLDPID}/cmdline" 2>/dev/null; then
        echo "[boot_linux] Already running as PID ${OLDPID}, skipping duplicate invocation." >> "${LOGFILE}"
        exit 0
    fi
fi
echo $$ > "${PIDFILE}"

# Guard against unprivileged execution
if [ "$(id -u 2>/dev/null)" != "0" ] && [ "$(id 2>/dev/null | grep -o 'uid=0')" != "uid=0" ]; then
    echo "[boot_linux] ERROR: Must be run as root (current uid: $(id -u 2>/dev/null || echo 'unknown'))" >> "${LOGFILE}"
    exit 1
fi

echo "==> [boot_linux] Initializing at $(date)" > "${LOGFILE}"
chmod 666 "${LOGFILE}" 2>/dev/null || true

# Clear bootloader message block (BCB) in misc partition to prevent stuck recovery reboot loops
if [ -e /dev/block/mmcblk0p8 ]; then
    dd if=/dev/zero of=/dev/block/mmcblk0p8 bs=1024 count=16 2>/dev/null || true
fi

# Defuse hardware watchdog if present and start background petter loop
if [ -e /dev/watchdog ]; then
    printf 'V' > /dev/watchdog 2>/dev/null || true
    ( while true; do
        if [ -e /dev/watchdog ]; then
            echo 1 > /dev/watchdog 2>/dev/null || true
        fi
        sleep 5
      done
    ) &
    echo "[boot_linux] Hardware watchdog defused and background petter active (PID $!)" >> "${LOGFILE}"
fi

# Hold wake lock to prevent kernel opportunistic sleep / early-suspend
if [ -e /sys/power/wake_lock ]; then
    echo "boot_linux_active" > /sys/power/wake_lock 2>/dev/null || true
fi

# Protect supervisor and child userspace from Android Low Memory Killer (LMK) / OOM
if [ -e /sys/module/lowmemorykiller/parameters/minfree ]; then
    echo 0 > /sys/module/lowmemorykiller/parameters/minfree 2>/dev/null || true
fi
if [ -e /proc/$$/oom_score_adj ]; then
    echo -1000 > /proc/$$/oom_score_adj 2>/dev/null || true
fi

# Proactively stop Android UI runtime and surfaceflinger so they cannot touch the screen
stop bootanim 2>/dev/null || true
stop surfaceflinger 2>/dev/null || true
stop zygote 2>/dev/null || true
setprop ctl.stop bootanim 2>/dev/null || true
setprop ctl.stop surfaceflinger 2>/dev/null || true
setprop ctl.stop zygote 2>/dev/null || true

# Wait for mmcblk0p* data partition to settle
sleep 1

# Hardware EPDC Initializer: Enable auto-refresh and default 16-level grayscale
if [ -f /sys/class/graphics/fb0/epdc_auto_update ]; then
    echo 1 > /sys/class/graphics/fb0/epdc_auto_update
    echo 2 > /sys/class/graphics/fb0/epdc_waveform_mode
    echo "[boot_linux] EPDC auto-update (1) and waveform mode (2) configured" >> "${LOGFILE}"
fi

# Set CPU governor to powersave / ondemand
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
    echo ondemand > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
fi

# Ensure framebuffer and input devices exist and have proper permissions
if [ ! -e /dev/fb0 ] && [ -e /dev/graphics/fb0 ]; then
    ln -s /dev/graphics/fb0 /dev/fb0
fi
chmod 666 /dev/fb0 /dev/graphics/fb0 2>/dev/null || true
chmod 666 /dev/input/* 2>/dev/null || true
chmod 666 /sys/class/graphics/fb0/* 2>/dev/null || true
chmod 666 /sys/class/backlight/*/* 2>/dev/null || true
chmod 666 /dev/ttymxc* /dev/rfkill 2>/dev/null || true
chmod 666 /sys/class/rfkill/*/* 2>/dev/null || true
chmod 666 /dev/snd/* 2>/dev/null || true

# ------------------------------------------------------------------------------
# Partition Repurposing: Cache Partition (/dev/block/mmcblk0p6, ~342 MB)
# ------------------------------------------------------------------------------
# Activate /cache as high-speed Linux swap to prevent OOM under heavy loads
if [ -b /dev/block/mmcblk0p6 ]; then
    echo "[boot_linux] Configuring /cache (/dev/block/mmcblk0p6) as swap space..." >> "${LOGFILE}"
    if ! grep -q "/dev/block/mmcblk0p6" /proc/swaps 2>/dev/null; then
        mkswap /dev/block/mmcblk0p6 2>/dev/null || true
        swapon /dev/block/mmcblk0p6 2>/dev/null || true
    fi
    if grep -q "/dev/block/mmcblk0p6" /proc/swaps 2>/dev/null; then
        echo "[boot_linux] Swap active on /dev/block/mmcblk0p6" >> "${LOGFILE}"
    else
        echo "[boot_linux] WARNING: Could not activate swap on /dev/block/mmcblk0p6" >> "${LOGFILE}"
    fi
fi

# ------------------------------------------------------------------------------
# Partition Repurposing: System Partition (/dev/block/mmcblk0p5, ~360 MB)
# ------------------------------------------------------------------------------
# Determine rootfs location: support dedicated /system partition or /data/linuxroot
if [ -f "/system/opt/init_system.sh" ]; then
    ROOTFS="/system"
    mount -o remount,rw /system 2>/dev/null || true
    echo "[boot_linux] Dedicated partition mode: Using /system (/dev/block/mmcblk0p5) as Alpine rootfs" >> "${LOGFILE}"
elif [ -d "/data/linuxroot" ]; then
    ROOTFS="/data/linuxroot"
    echo "[boot_linux] Shared partition mode: Using /data/linuxroot as Alpine rootfs" >> "${LOGFILE}"
else
    ROOTFS="/data/linuxroot"
    mkdir -p "$ROOTFS"
fi

mkdir -p $ROOTFS/proc $ROOTFS/sys $ROOTFS/dev $ROOTFS/dev/pts
mkdir -p $ROOTFS/sdcard $ROOTFS/mnt/sdcard $ROOTFS/data
if [ "$ROOTFS" != "/system" ]; then
    mkdir -p $ROOTFS/system
    mount -o bind /system $ROOTFS/system 2>/dev/null || true
fi

mount -t proc none $ROOTFS/proc 2>/dev/null || true
mount -t sysfs none $ROOTFS/sys 2>/dev/null || true
mount -o bind /dev $ROOTFS/dev 2>/dev/null || true
mount -t devpts none $ROOTFS/dev/pts 2>/dev/null || true
mount -o bind /data $ROOTFS/data 2>/dev/null || true

# Mount user storage (Android internal storage: Downloads, Books, etc.)
if [ -d /data/media/0 ]; then
    mount -o bind /data/media/0 $ROOTFS/sdcard 2>/dev/null || true
    mount -o bind /data/media/0 $ROOTFS/mnt/sdcard 2>/dev/null || true
    rm -rf $ROOTFS/data/books 2>/dev/null || true
    ln -sf /sdcard $ROOTFS/data/books 2>/dev/null || true
elif [ -d /data/media ]; then
    mount -o bind /data/media $ROOTFS/sdcard 2>/dev/null || true
    mount -o bind /data/media $ROOTFS/mnt/sdcard 2>/dev/null || true
    rm -rf $ROOTFS/data/books 2>/dev/null || true
    ln -sf /sdcard $ROOTFS/data/books 2>/dev/null || true
fi

# Background root command watcher for tethered maintenance
( while true; do
    if [ -f /data/local/tmp/root_exec.sh ]; then
        echo "[root_exec] Executing $(date)..." > /data/local/tmp/root_exec.log
        /system/bin/sh /data/local/tmp/root_exec.sh >> /data/local/tmp/root_exec.log 2>&1
        rm -f /data/local/tmp/root_exec.sh
    fi
    sleep 1
  done
) &

run_tar() {
    if [ -x /system/bin/tar ]; then
        /system/bin/tar "$@"
    elif [ -x /system/bin/busybox ]; then
        /system/bin/busybox tar "$@"
    elif [ -x /sbin/busybox ]; then
        /sbin/busybox tar "$@"
    elif [ -x "$ROOTFS/lib/ld-musl-armhf.so.1" ] && [ -x "$ROOTFS/bin/busybox" ]; then
        "$ROOTFS/lib/ld-musl-armhf.so.1" "$ROOTFS/bin/busybox" tar "$@"
    elif [ -x "$ROOTFS/bin/tar" ]; then
        "$ROOTFS/bin/tar" "$@"
    else
        tar "$@"
    fi
}

unpack_payload_if_present() {
    PAYLOAD_SRC=""
    if [ -f "/sdcard/deploy_payload.tar.gz" ]; then
        PAYLOAD_SRC="/sdcard/deploy_payload.tar.gz"
    elif [ -f "/data/media/0/deploy_payload.tar.gz" ]; then
        PAYLOAD_SRC="/data/media/0/deploy_payload.tar.gz"
    elif [ -f "/data/deploy_payload.tar.gz" ]; then
        PAYLOAD_SRC="/data/deploy_payload.tar.gz"
    fi

    if [ -n "$PAYLOAD_SRC" ]; then
        # Verify the payload checksum when a .sha256 sibling was staged
        # next to it (deploy.sh and release assets provide one).
        if [ -f "${PAYLOAD_SRC}.sha256" ]; then
            WANT_SHA="$(head -n1 "${PAYLOAD_SRC}.sha256" | awk '{print $1}')"
            GOT_SHA=""
            if [ -x /system/bin/toybox ]; then
                GOT_SHA="$(/system/bin/toybox sha256sum "${PAYLOAD_SRC}" 2>/dev/null | awk '{print $1}')"
            elif command -v sha256sum >/dev/null 2>&1; then
                GOT_SHA="$(sha256sum "${PAYLOAD_SRC}" 2>/dev/null | awk '{print $1}')"
            elif [ -x "$ROOTFS/lib/ld-musl-armhf.so.1" ] && [ -x "$ROOTFS/bin/busybox" ]; then
                GOT_SHA="$("$ROOTFS/lib/ld-musl-armhf.so.1" "$ROOTFS/bin/busybox" sha256sum "${PAYLOAD_SRC}" 2>/dev/null | awk '{print $1}')"
            fi
            if [ -n "$GOT_SHA" ]; then
                if [ "$GOT_SHA" = "$WANT_SHA" ]; then
                    echo "[boot_linux] Payload checksum OK." >> "${LOGFILE}"
                else
                    echo "[boot_linux] Payload checksum MISMATCH (want ${WANT_SHA}, got ${GOT_SHA}); keeping ${PAYLOAD_SRC} for retry." >> "${LOGFILE}"
                    return 0
                fi
            else
                echo "[boot_linux] No sha256sum available; skipping payload checksum verification." >> "${LOGFILE}"
            fi
        fi

        OLD_VERSION="$(cat "$ROOTFS/etc/bnrv700-release" 2>/dev/null || echo unknown)"
        echo "[boot_linux] Found payload $PAYLOAD_SRC, deploying to $ROOTFS (installed: ${OLD_VERSION})..." >> "${LOGFILE}"
        mkdir -p "$ROOTFS"
        run_tar -xzf "$PAYLOAD_SRC" -C "$ROOTFS" 2>> "${LOGFILE}" || true
        rm -f "$PAYLOAD_SRC" "${PAYLOAD_SRC}.sha256" 2>/dev/null || true
        chmod +x "$ROOTFS/opt"/*.sh 2>/dev/null || true
        NEW_VERSION="$(cat "$ROOTFS/etc/bnrv700-release" 2>/dev/null || echo unknown)"
        echo "[boot_linux] Payload deployed successfully at $(date). rootfs version: ${OLD_VERSION} -> ${NEW_VERSION}" >> "${LOGFILE}"
    fi
}

unpack_payload_if_present

run_chroot() {
    if [ -x /system/bin/busybox ]; then
        /system/bin/busybox chroot "$@"
    elif [ -x /sbin/chroot ]; then
        /sbin/chroot "$@"
    elif [ -x /sbin/busybox ]; then
        /sbin/busybox chroot "$@"
    elif [ -x "$ROOTFS/bin/busybox" ]; then
        "$ROOTFS/bin/busybox" chroot "$@"
    else
        chroot "$@"
    fi
}

echo "[boot_linux] Launching chroot..." >> "${LOGFILE}"

# Validate chroot entrypoint
if [ -f "$ROOTFS/opt/init_system.sh" ]; then
    echo "[boot_linux] Launching Alpine Linux supervisor loop in foreground..." >> "${LOGFILE}"
    echo "[boot_linux] Alpine Linux chroot launching" > /dev/kmsg 2>/dev/null || true
    chmod +x "$ROOTFS/opt"/*.sh 2>/dev/null || true
    
    # Foreground supervisor loop keeping Linux alive
    while true; do
        unpack_payload_if_present
        echo "[boot_linux] Starting userspace session at $(date)..." >> "${LOGFILE}"
        run_chroot "$ROOTFS" /bin/sh /opt/init_system.sh >> /data/linux_init.log 2>&1
        STATUS=$?
        echo "[boot_linux] Userspace session exited with status ${STATUS} at $(date). Respawning in 2s..." >> "${LOGFILE}"
        sleep 2
    done
else
    echo "[boot_linux] ERROR: $ROOTFS/opt/init_system.sh not found!" >> "${LOGFILE}"
    echo "[boot_linux] ERROR: Rootfs payload not installed in $ROOTFS. Use deploy.sh to push payload." > /dev/kmsg 2>/dev/null || true
fi
