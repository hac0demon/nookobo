#!/bin/sh
# /opt/bin/chroot_checks.sh - BNRV700 on-device health checks (device-check).
# Runs inside the Linux chroot. Emits one "OK|BAD|INFO <name> <detail>"
# line per check; scripts/device_check.sh aggregates the results.

ok()   { printf 'OK %s %s\n' "$1" "$2"; }
bad()  { printf 'BAD %s %s\n' "$1" "$2"; }
info() { printf 'INFO %s %s\n' "$1" "$2"; }

# --- apk database -------------------------------------------------------
if apk info >/dev/null 2>&1; then
    ok apk-db "readable ($(apk info 2>/dev/null | wc -l) packages)"
else
    bad apk-db "apk info failed"
fi

# --- rootfs version marker -------------------------------------------------
if [ -f /etc/bnrv700-release ]; then
    ok rootfs-version "$(cat /etc/bnrv700-release)"
else
    info rootfs-version "marker absent (payload predates versioning)"
fi

# --- EPDC / framebuffer -------------------------------------------------
if [ -c /dev/fb0 ]; then
    ok fb0 "character device present"
else
    bad fb0 "missing"
fi

if [ -x /opt/bin/epdc_probe ]; then
    probe_out="$(/opt/bin/epdc_probe 2>&1)"
    probe_rc=$?
    if [ "$probe_rc" -eq 0 ]; then
        ok epdc "probe OK (panel refreshed once)"
    else
        bad epdc "probe failed: $(printf '%s' "$probe_out" | tr '\n' ' ')"
    fi
else
    info epdc "probe binary not installed (/opt/bin/epdc_probe)"
fi

# --- input devices ------------------------------------------------------
if [ -c /dev/input/event1 ]; then
    ok input-event1 "elan touch present"
else
    bad input-event1 "missing"
fi
if [ -c /dev/input/event2 ]; then
    ok input-event2 "virtual key node present"
else
    bad input-event2 "missing"
fi
vkey=""
for d in /sys/class/input/input*; do
    [ -r "$d/name" ] || continue
    n="$(cat "$d/name" 2>/dev/null)"
    case "$n" in
        *nook-virtual-keys*) vkey="$d";;
    esac
done
if [ -n "$vkey" ]; then
    ok uinput-virtkeys "$(basename "$vkey") registered"
else
    bad uinput-virtkeys "no nook-virtual-keys uinput device"
fi

# --- resident daemons ---------------------------------------------------
if pgrep btn-watcher >/dev/null 2>&1; then
    ok daemon-btn-watcher "running"
else
    bad daemon-btn-watcher "not running"
fi
if pgrep dropbear >/dev/null 2>&1; then
    ok daemon-dropbear "running"
else
    bad daemon-dropbear "not running"
fi
if [ -x /usr/bin/syncthing ]; then
    if pgrep syncthing >/dev/null 2>&1; then
        ok daemon-syncthing "running"
    else
        bad daemon-syncthing "installed but not running"
    fi
else
    info daemon-syncthing "not installed (payload predates syncthing)"
fi
if pgrep luajit >/dev/null 2>&1 || pgrep plato >/dev/null 2>&1; then
    ok reader-process "alive"
else
    bad reader-process "neither luajit nor plato running"
fi

# --- dropbear port ------------------------------------------------------
if grep -q ':0016 ' /proc/net/tcp 2>/dev/null || grep -q ':0016 ' /proc/net/tcp6 2>/dev/null; then
    ok dropbear-port "22 listening"
else
    bad dropbear-port "22 not listening"
fi

# --- frontlight round-trip (restores original value) --------------------
fl=/sys/class/backlight/mxc_msp430_fl.0/brightness
if [ -f "$fl" ]; then
    orig="$(cat "$fl" 2>/dev/null)"
    want=0
    [ "$orig" = "0" ] && want=1
    printf '%s\n' "$want" > "$fl" 2>/dev/null
    got="$(cat "$fl" 2>/dev/null)"
    printf '%s\n' "$orig" > "$fl" 2>/dev/null
    if [ "$got" = "$want" ]; then
        ok frontlight "write/read-back OK (restored $orig)"
    else
        bad frontlight "wrote $want, read back $got (orig $orig)"
    fi
else
    bad frontlight "sysfs node missing"
fi

# --- battery -------------------------------------------------------------
bat=/sys/class/power_supply/mc13892_bat
if [ -f "$bat/capacity" ]; then
    c="$(cat "$bat/capacity" 2>/dev/null)"
    case "$c" in
        ''|*[!0-9]*) bad battery "capacity not numeric: '$c'" ;;
        *)
            if [ "$c" -ge 0 ] && [ "$c" -le 100 ]; then
                st="$(cat "$bat/status" 2>/dev/null)"
                on="$(cat /sys/class/power_supply/mc13892_charger/online 2>/dev/null)"
                ok battery "capacity=${c}% status=${st} usb_online=${on}"
            else
                bad battery "capacity out of range: $c"
            fi
            ;;
    esac
else
    bad battery "mc13892_bat sysfs missing"
fi

# --- NetSurf dynamic linking ---------------------------------------------
if [ -x /usr/bin/netsurf-fb ]; then
    missing="$(ldd /usr/bin/netsurf-fb 2>&1 | grep -c 'not found' || true)"
    if [ "$missing" = "0" ]; then
        ok netsurf-libs "all NEEDED libraries resolved"
    else
        bad netsurf-libs "$missing unresolved libraries"
    fi
else
    bad netsurf-fb "binary missing"
fi

# --- disk usage -----------------------------------------------------------
use="$(df -k / 2>/dev/null | awk 'NR==2 {gsub(/%/, "", $5); print $5}')"
if [ -n "$use" ]; then
    if [ "$use" -lt 85 ]; then
        ok disk "/ at ${use}% used"
    else
        bad disk "/ at ${use}% used (>= 85%)"
    fi
else
    bad disk "df failed"
fi

# --- supervisor state files -----------------------------------------------
for f in /tmp/current_app /tmp/active_reader; do
    if [ -s "$f" ]; then
        ok "state-$(basename "$f")" "$(head -n1 "$f" | tr -d '\n')"
    else
        bad "state-$(basename "$f")" "missing or empty"
    fi
done

# --- Plato shim (informational) -------------------------------------------
if [ -f /opt/plato/libs/libbnrv700_plato_shim.so ]; then
    ok plato-shim "present"
else
    info plato-shim "not deployed"
fi
