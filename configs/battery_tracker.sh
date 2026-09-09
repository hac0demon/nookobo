#!/bin/sh
# /opt/battery_tracker.sh - BNRV700 Battery Usage Tracker & Monitor
# Queries the Ricoh RN5T619 PMIC via /sys/class/power_supply/mc13892_bat

BATT_SYSFS="/sys/class/power_supply/mc13892_bat"
[ ! -d "$BATT_SYSFS" ] && BATT_SYSFS="/sys/class/power_supply/battery"

LOG_FILE="/data/battery_history.csv"

read_val() {
    cat "$BATT_SYSFS/$1" 2>/dev/null || echo "0"
}

ACTION="${1:-status}"

case "$ACTION" in
    log)
        CAP=$(read_val "capacity")
        VOLT=$(read_val "voltage_now")
        VOLT_MV=$((VOLT / 1000))
        STATUS=$(read_val "status")
        TEMP=$(read_val "temp")
        TEMP_C=$(awk "BEGIN {printf \"%.1f\", $TEMP/10}")
        TIME_EMPTY=$(read_val "time_to_empty_now")
        NOW_SEC=$(date +%s)
        NOW_STR=$(date "+%Y-%m-%d %H:%M:%S")

        mkdir -p /data
        if [ ! -f "$LOG_FILE" ]; then
            echo "epoch,datetime,capacity_pct,voltage_mv,status,temp_c,time_empty_s" > "$LOG_FILE"
        fi

        echo "$NOW_SEC,$NOW_STR,$CAP,$VOLT_MV,$STATUS,$TEMP_C,$TIME_EMPTY" >> "$LOG_FILE"

        # Keep rolling last 500 entries (~8 hours at 1/min)
        if [ $(wc -l < "$LOG_FILE") -gt 550 ]; then
            head -n 1 "$LOG_FILE" > "${LOG_FILE}.tmp"
            tail -n 500 "$LOG_FILE" >> "${LOG_FILE}.tmp"
            mv -f "${LOG_FILE}.tmp" "$LOG_FILE"
        fi
        ;;

    status)
        CAP=$(read_val "capacity")
        VOLT=$(read_val "voltage_now")
        VOLT_V=$(awk "BEGIN {printf \"%.2f\", $VOLT/1000000}")
        STATUS=$(read_val "status")
        TEMP=$(read_val "temp")
        TEMP_C=$(awk "BEGIN {printf \"%.1f\", $TEMP/10}")
        HEALTH=$(read_val "health")
        TIME_EMPTY=$(read_val "time_to_empty_now")
        
        HOURS_LEFT=0
        MINS_LEFT=0
        if [ "$TIME_EMPTY" -gt 0 ] 2>/dev/null; then
            HOURS_LEFT=$((TIME_EMPTY / 3600))
            MINS_LEFT=$(((TIME_EMPTY % 3600) / 60))
        fi

        # Calculate discharge rate from CSV if available
        RATE_STR="Calculating..."
        if [ -f "$LOG_FILE" ] && [ $(wc -l < "$LOG_FILE") -gt 5 ]; then
            FIRST_RECORD=$(tail -n 30 "$LOG_FILE" | head -n 1)
            LAST_RECORD=$(tail -n 1 "$LOG_FILE")

            T1=$(echo "$FIRST_RECORD" | cut -d',' -f1)
            C1=$(echo "$FIRST_RECORD" | cut -d',' -f3)
            T2=$(echo "$LAST_RECORD" | cut -d',' -f1)
            C2=$(echo "$LAST_RECORD" | cut -d',' -f3)

            DELTA_T=$((T2 - T1))
            DELTA_C=$((C1 - C2))

            if [ "$DELTA_T" -gt 120 ] 2>/dev/null; then
                HOURLY_RATE=$(awk "BEGIN {printf \"%.1f\", ($DELTA_C / $DELTA_T) * 3600}")
                if [ $(awk "BEGIN {print ($HOURLY_RATE > 0)}") -eq 1 ]; then
                    RATE_STR="${HOURLY_RATE}% / hr"
                else
                    RATE_STR="Idle / Charging"
                fi
            fi
        fi

        echo "CAPACITY:${CAP}%"
        echo "VOLTAGE:${VOLT_V} V"
        echo "STATUS:${STATUS}"
        echo "HEALTH:${HEALTH}"
        echo "TEMP:${TEMP_C} °C"
        echo "RATE:${RATE_STR}"
        if [ "$HOURS_LEFT" -gt 0 ] || [ "$MINS_LEFT" -gt 0 ]; then
            echo "TIME_REMAINING:${HOURS_LEFT}h ${MINS_LEFT}m"
        else
            echo "TIME_REMAINING:N/A"
        fi
        ;;

    report)
        echo "=== BNRV700 Battery Usage Report ==="
        $0 status
        echo ""
        echo "--- Recent Battery Log (Last 10) ---"
        if [ -f "$LOG_FILE" ]; then
            tail -n 10 "$LOG_FILE"
        else
            echo "No history recorded yet."
        fi
        ;;

    clear)
        rm -f "$LOG_FILE"
        echo "[battery_tracker] History log cleared."
        ;;

    *)
        echo "Usage: $0 {log|status|report|clear}"
        exit 1
        ;;
esac
