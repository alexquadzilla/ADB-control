#!/system/bin/sh
DIR=/data/local/tmp/scripts
PIDFILE="$DIR/watchdog.pid"
COUNTER_FILE="$DIR/reboot_counter.txt"
LOG="$DIR/watchdog.log"
MAX_ERRORS=5
MAX_REBOOTS=3
MAX_LOG_BYTES=256000     # жёсткий предел размера лога: 250 КБ
TRIM_LOG_BYTES=128000    # при превышении оставляем последние ~125 КБ
ERRORS=0

mkdir -p "$DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
    # Ротация по размеру (250 КБ) — вызывается после каждой записи,
    # лог не растёт бесконечно между перезапусками watchdog
    if [ -f "$LOG" ]; then
        SIZE=$(wc -c < "$LOG" 2>/dev/null)
        if [ "$SIZE" -gt "$MAX_LOG_BYTES" ] 2>/dev/null; then
            tail -c "$TRIM_LOG_BYTES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
        fi
    fi
}

if [ -f "$PIDFILE" ]; then
    OLD_PID=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        exit 0
    fi
fi

echo $$ > "$PIDFILE"
trap "rm -f $PIDFILE" EXIT

REBOOTS=0
[ -f "$COUNTER_FILE" ] && REBOOTS=$(cat "$COUNTER_FILE")
[ -z "$REBOOTS" ] && REBOOTS=0

log "START. pid=$$ reboots=$REBOOTS"

while true; do
    if ping -c 2 -W 10 8.8.8.8 > /dev/null 2>&1; then
        if [ "$ERRORS" -gt 0 ] || [ "$REBOOTS" -gt 0 ]; then
            log "PING OK. сброс счетчиков (было errors=$ERRORS reboots=$REBOOTS)"
        fi
        ERRORS=0
        REBOOTS=0
        rm -f "$COUNTER_FILE"
    else
        ERRORS=$((ERRORS + 1))
        log "PING FAIL. errors=$ERRORS/$MAX_ERRORS reboots=$REBOOTS/$MAX_REBOOTS"
        if [ "$ERRORS" -ge "$MAX_ERRORS" ]; then
            if [ "$REBOOTS" -ge "$MAX_REBOOTS" ]; then
                log "ЛИМИТ РЕБУТОВ. Ждём появления сети, перезагрузок больше не будет."
                ERRORS=0
            else
                REBOOTS=$((REBOOTS + 1))
                echo "$REBOOTS" > "$COUNTER_FILE"
                log "REBOOT # $REBOOTS"
                /system/bin/reboot
                sleep 60
            fi
        fi
    fi
    sleep 30
done