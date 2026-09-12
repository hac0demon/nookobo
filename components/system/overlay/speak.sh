#!/bin/sh
# /opt/speak.sh - Lightweight eSpeak-NG TTS engine piped to ALSA 3.5mm Headphone Jack
# Uses ~3-5% CPU on single-core Cortex-A9

SPEED="${SPEED:-160}"
VOICE="${VOICE:-en-us}"
PIDFILE="/var/run/speak.pid"

unmute_alsa() {
    if [ -d /proc/asound/card0 ]; then
        amixer -c 0 sset 'Headphone' 80% unmute 2>/dev/null || true
        amixer -c 0 sset 'DAC1' 80% unmute 2>/dev/null || true
        amixer -c 0 sset 'HP' 80% unmute 2>/dev/null || true
        amixer -c 0 sset 'Master' 80% unmute 2>/dev/null || true
    fi
}

case "$1" in
    stop)
        if [ -f "$PIDFILE" ]; then
            PID=$(cat "$PIDFILE")
            kill "$PID" 2>/dev/null || true
            rm -f "$PIDFILE"
        fi
        pkill -x espeak-ng 2>/dev/null || true
        pkill -x aplay 2>/dev/null || true
        echo "[speak] Stopped"
        ;;

    status)
        if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
            echo "SPEAKING"
        else
            echo "IDLE"
        fi
        ;;

    *)
        # Stop any previous speech synthesis
        if [ -f "$PIDFILE" ]; then
            PID=$(cat "$PIDFILE")
            kill "$PID" 2>/dev/null || true
            rm -f "$PIDFILE"
        fi
        pkill -x espeak-ng 2>/dev/null || true
        pkill -x aplay 2>/dev/null || true

        unmute_alsa

        TEXT="$*"
        if [ -z "$TEXT" ]; then
            # Read from stdin
            ( espeak-ng -s "$SPEED" -v "$VOICE" --stdout | aplay -D default -q 2>/dev/null ) &
            echo $! > "$PIDFILE"
        else
            ( espeak-ng -s "$SPEED" -v "$VOICE" "$TEXT" --stdout | aplay -D default -q 2>/dev/null ) &
            echo $! > "$PIDFILE"
        fi
        ;;
esac
