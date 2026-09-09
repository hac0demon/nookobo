#!/bin/sh
# /opt/audiocontrol.sh - Unified background audio player & playlist controller for BNRV700
# Supports 3.5mm Headphone Jack (ALC5640/5645 ALSA) and Bluetooth A2DP (BlueALSA)

PLAYLIST_FILE="/var/run/audioplayer.playlist"
SAVED_PLAYLIST="/root/.audioplayer_playlist.txt"
PIDFILE="/var/run/audioplayer.pid"
PLAYER_PIDFILE="/var/run/audioplayer.player.pid"
STATUSFILE="/var/run/audioplayer.status"
TRACKFILE="/var/run/audioplayer.track"
INDEXFILE="/var/run/audioplayer.index"
SHUFFLEFILE="/var/run/audioplayer.shuffle"

unmute_alsa() {
    if [ -d /proc/asound/card0 ]; then
        amixer -c 0 sset 'Headphone' 80% unmute 2>/dev/null || true
        amixer -c 0 sset 'DAC1' 80% unmute 2>/dev/null || true
        amixer -c 0 sset 'HP' 80% unmute 2>/dev/null || true
        amixer -c 0 sset 'Master' 80% unmute 2>/dev/null || true
    fi
}

ensure_playlist() {
    if [ ! -s "$PLAYLIST_FILE" ]; then
        if [ -s "$SAVED_PLAYLIST" ]; then
            cp "$SAVED_PLAYLIST" "$PLAYLIST_FILE"
        else
            mkdir -p /data/media/0/Music /data/music /sdcard/Music 2>/dev/null || true
            find /data/media/0/Music /data/music /sdcard/Music /data/books /usr/share/sounds \
                -type f \( -iname "*.mp3" -o -iname "*.wav" -o -iname "*.ogg" \) 2>/dev/null \
                | sort > "$PLAYLIST_FILE"
            cp "$PLAYLIST_FILE" "$SAVED_PLAYLIST" 2>/dev/null || true
        fi
    fi
    [ -f "$INDEXFILE" ] || echo "0" > "$INDEXFILE"
    [ -f "$SHUFFLEFILE" ] || echo "0" > "$SHUFFLEFILE"
}

get_total_tracks() {
    [ -f "$PLAYLIST_FILE" ] && wc -l < "$PLAYLIST_FILE" || echo "0"
}

get_track_by_index() {
    idx="$1"
    total=$(get_total_tracks)
    [ "$total" -eq 0 ] && return 1
    # 0-indexed to 1-indexed line
    line_num=$((idx + 1))
    sed -n "${line_num}p" "$PLAYLIST_FILE" 2>/dev/null
}

# Daemon loop: runs in background and plays tracks in order or shuffle
run_daemon() {
    echo $$ > "$PIDFILE"
    echo "PLAYING" > "$STATUSFILE"

    while true; do
        ensure_playlist
        total=$(get_total_tracks)
        if [ "$total" -eq 0 ]; then
            echo "STOPPED" > "$STATUSFILE"
            rm -f "$TRACKFILE"
            break
        fi

        idx=$(cat "$INDEXFILE" 2>/dev/null || echo "0")
        if [ "$idx" -ge "$total" ] || [ "$idx" -lt 0 ]; then
            idx=0
            echo "0" > "$INDEXFILE"
        fi

        file=$(get_track_by_index "$idx")
        if [ -z "$file" ] || [ ! -f "$file" ]; then
            idx=$(( (idx + 1) % total ))
            echo "$idx" > "$INDEXFILE"
            sleep 1
            continue
        fi

        echo "$file" > "$TRACKFILE"
        echo "PLAYING" > "$STATUSFILE"

        # Check for Bluetooth audio connection
        BT_MAC=""
        if command -v bluetoothctl >/dev/null 2>&1; then
            BT_MAC=$(bluetoothctl info 2>/dev/null | grep "^Device " | awk '{print $2}' | head -n 1)
        fi

        # Play file
        case "$file" in
            *.wav)
                if [ -n "$BT_MAC" ] && pgrep -x bluealsa >/dev/null 2>&1; then
                    aplay -q -D "bluealsa:DEV=$BT_MAC,PROFILE=a2dp" "$file" 2>/dev/null &
                else
                    unmute_alsa
                    aplay -q "$file" 2>/dev/null &
                fi
                ;;
            *)
                if [ -n "$BT_MAC" ] && pgrep -x bluealsa >/dev/null 2>&1; then
                    mpg123 -q -a "bluealsa:DEV=$BT_MAC,PROFILE=a2dp" "$file" 2>/dev/null &
                else
                    unmute_alsa
                    mpg123 -q "$file" 2>/dev/null &
                fi
                ;;
        esac

        PLAY_PID=$!
        echo "$PLAY_PID" > "$PLAYER_PIDFILE"

        # Wait for player to finish
        wait "$PLAY_PID" 2>/dev/null
        rm -f "$PLAYER_PIDFILE"

        # If stopped externally, exit loop
        cur_status=$(cat "$STATUSFILE" 2>/dev/null || echo "STOPPED")
        if [ "$cur_status" = "STOPPED" ]; then
            break
        fi

        # Compute next index
        shuffle=$(cat "$SHUFFLEFILE" 2>/dev/null || echo "0")
        total=$(get_total_tracks)
        if [ "$shuffle" = "1" ] && [ "$total" -gt 1 ]; then
            # Random next index
            rand_idx=$(awk -v t="$total" 'BEGIN{srand(); print int(rand()*t)}')
            echo "$rand_idx" > "$INDEXFILE"
        else
            next_idx=$(( (idx + 1) % total ))
            echo "$next_idx" > "$INDEXFILE"
        fi
    done

    rm -f "$PIDFILE" "$PLAYER_PIDFILE"
    echo "STOPPED" > "$STATUSFILE"
}

stop_playback() {
    echo "STOPPED" > "$STATUSFILE"
    if [ -f "$PLAYER_PIDFILE" ]; then
        kill -9 $(cat "$PLAYER_PIDFILE" 2>/dev/null) 2>/dev/null || true
        rm -f "$PLAYER_PIDFILE"
    fi
    if [ -f "$PIDFILE" ]; then
        kill -9 $(cat "$PIDFILE" 2>/dev/null) 2>/dev/null || true
        rm -f "$PIDFILE"
    fi
    pkill -9 -x mpg123 2>/dev/null || true
    pkill -9 -x aplay 2>/dev/null || true
}

start_playback() {
    stop_playback
    ensure_playlist
    echo "PLAYING" > "$STATUSFILE"
    /bin/sh "$0" _daemon >/dev/null 2>&1 &
}

case "$1" in
    _daemon)
        run_daemon
        ;;

    play)
        if [ -n "$2" ]; then
            # Specific file or index requested
            if echo "$2" | grep -qE '^[0-9]+$'; then
                echo "$2" > "$INDEXFILE"
            elif [ -f "$2" ]; then
                echo "$2" > "$PLAYLIST_FILE"
                echo "0" > "$INDEXFILE"
            fi
        fi
        start_playback
        ;;

    pause)
        if [ -f "$PIDFILE" ] && [ -f "$PLAYER_PIDFILE" ]; then
            PL_PID=$(cat "$PLAYER_PIDFILE" 2>/dev/null)
            CUR=$(cat "$STATUSFILE" 2>/dev/null || echo "PLAYING")
            if [ "$CUR" = "PLAYING" ]; then
                kill -STOP "$PL_PID" 2>/dev/null || true
                echo "PAUSED" > "$STATUSFILE"
                echo "[audiocontrol] Paused"
            else
                kill -CONT "$PL_PID" 2>/dev/null || true
                echo "PLAYING" > "$STATUSFILE"
                echo "[audiocontrol] Resumed"
            fi
        else
            start_playback
        fi
        ;;

    next)
        ensure_playlist
        total=$(get_total_tracks)
        if [ "$total" -gt 0 ]; then
            idx=$(cat "$INDEXFILE" 2>/dev/null || echo "0")
            shuffle=$(cat "$SHUFFLEFILE" 2>/dev/null || echo "0")
            if [ "$shuffle" = "1" ] && [ "$total" -gt 1 ]; then
                next_idx=$(awk -v t="$total" 'BEGIN{srand(); print int(rand()*t)}')
            else
                next_idx=$(( (idx + 1) % total ))
            fi
            echo "$next_idx" > "$INDEXFILE"
            start_playback
        fi
        ;;

    prev)
        ensure_playlist
        total=$(get_total_tracks)
        if [ "$total" -gt 0 ]; then
            idx=$(cat "$INDEXFILE" 2>/dev/null || echo "0")
            prev_idx=$(( (idx - 1 + total) % total ))
            echo "$prev_idx" > "$INDEXFILE"
            start_playback
        fi
        ;;

    shuffle)
        cur=$(cat "$SHUFFLEFILE" 2>/dev/null || echo "0")
        if [ "$cur" = "1" ]; then
            echo "0" > "$SHUFFLEFILE"
            echo "[audiocontrol] Shuffle: OFF"
        else
            echo "1" > "$SHUFFLEFILE"
            echo "[audiocontrol] Shuffle: ON"
        fi
        ;;

    reorder)
        # Shuffle playlist lines randomly in-place
        ensure_playlist
        if [ -s "$PLAYLIST_FILE" ]; then
            awk 'BEGIN{srand()} {print rand() "\t" $0}' "$PLAYLIST_FILE" | sort -k1,1n | cut -f2- > "${PLAYLIST_FILE}.tmp"
            mv "${PLAYLIST_FILE}.tmp" "$PLAYLIST_FILE"
            cp "$PLAYLIST_FILE" "$SAVED_PLAYLIST" 2>/dev/null || true
            echo "0" > "$INDEXFILE"
            echo "[audiocontrol] Playlist reshuffled"
            if [ "$(cat "$STATUSFILE" 2>/dev/null)" = "PLAYING" ]; then
                start_playback
            fi
        fi
        ;;

    scan)
        scan_dir="${2:-/data/media/0/Music}"
        mkdir -p "$scan_dir" 2>/dev/null || true
        find "$scan_dir" /data/books /sdcard/Music /usr/share/sounds -type f \( -iname "*.mp3" -o -iname "*.wav" -o -iname "*.ogg" \) 2>/dev/null \
            | sort > "$PLAYLIST_FILE"
        cp "$PLAYLIST_FILE" "$SAVED_PLAYLIST" 2>/dev/null || true
        echo "0" > "$INDEXFILE"
        echo "[audiocontrol] Scanned $(wc -l < "$PLAYLIST_FILE") tracks from $scan_dir"
        ;;

    stop)
        stop_playback
        echo "[audiocontrol] Stopped"
        ;;

    status)
        CUR="STOPPED"
        if [ -f "$PIDFILE" ] && kill -0 $(cat "$PIDFILE" 2>/dev/null) 2>/dev/null; then
            CUR=$(cat "$STATUSFILE" 2>/dev/null || echo "PLAYING")
        fi
        TRACK=$(cat "$TRACKFILE" 2>/dev/null || echo "")
        IDX=$(cat "$INDEXFILE" 2>/dev/null || echo "0")
        TOTAL=$(get_total_tracks)
        SHUF=$(cat "$SHUFFLEFILE" 2>/dev/null || echo "0")
        echo "STATUS:${CUR}"
        echo "TRACK:${TRACK}"
        echo "INDEX:${IDX}"
        echo "TOTAL:${TOTAL}"
        echo "SHUFFLE:${SHUF}"
        ;;

    volup)
        if [ -d /proc/asound/card0 ]; then
            amixer -c 0 sset 'Headphone' 5%+ 2>/dev/null || amixer sset Master 5%+ 2>/dev/null || true
        fi
        ;;

    voldown)
        if [ -d /proc/asound/card0 ]; then
            amixer -c 0 sset 'Headphone' 5%- 2>/dev/null || amixer sset Master 5%- 2>/dev/null || true
        fi
        ;;

    *)
        echo "Usage: $0 {play [file|idx]|pause|stop|next|prev|shuffle|reorder|scan [dir]|status|volup|voldown}"
        exit 1
        ;;
esac
