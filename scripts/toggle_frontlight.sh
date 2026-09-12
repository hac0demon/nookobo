#!/bin/sh
# /opt/scripts/toggle_frontlight.sh - Toggle frontlight ON/OFF instantly
STATE_FILE="/tmp/frontlight_saved_level"
SYS_MSP="/sys/class/backlight/mxc_msp430_fl.0/brightness"
SYS_LEDA="/sys/class/backlight/lm3630a_leda/brightness"
SYS_LEDB="/sys/class/backlight/lm3630a_ledb/brightness"

CURRENT_MSP=$(cat "$SYS_MSP" 2>/dev/null || echo 0)
CURRENT_LEDA=$(cat "$SYS_LEDA" 2>/dev/null || echo 0)

if [ "$CURRENT_MSP" -gt 0 ] || [ "$CURRENT_LEDA" -gt 0 ]; then
    # Light is currently ON -> Save current levels and turn OFF
    echo "$CURRENT_MSP $CURRENT_LEDA" > "$STATE_FILE"
    echo 0 > "$SYS_MSP" 2>/dev/null || true
    echo 0 > "$SYS_LEDA" 2>/dev/null || true
    echo 0 > "$SYS_LEDB" 2>/dev/null || true
else
    # Light is currently OFF -> Restore previous level (or default)
    RESTORE_MSP=25
    RESTORE_LEDA=50
    if [ -f "$STATE_FILE" ]; then
        READ_VALS=$(cat "$STATE_FILE")
        VAL_MSP=$(echo "$READ_VALS" | awk '{print $1}')
        VAL_LEDA=$(echo "$READ_VALS" | awk '{print $2}')
        [ -n "$VAL_MSP" ] && [ "$VAL_MSP" -gt 0 ] && RESTORE_MSP="$VAL_MSP"
        [ -n "$VAL_LEDA" ] && [ "$VAL_LEDA" -gt 0 ] && RESTORE_LEDA="$VAL_LEDA"
    fi
    echo "$RESTORE_MSP" > "$SYS_MSP" 2>/dev/null || true
    echo "$RESTORE_LEDA" > "$SYS_LEDA" 2>/dev/null || true
fi
