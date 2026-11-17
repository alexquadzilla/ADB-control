#!/system/bin/sh
DIR=/data/local/tmp/scripts
PIDFILE="$DIR/cache_cleaner.pid"
LOG="$DIR/cache_cleaner.log"
MARKER="$DIR/last_clean_day.txt"
MAX_LOG_BYTES=256000     # жёсткий предел размера лога: 250 КБ
TRIM_LOG_BYTES=128000    # при превышении оставляем последние ~125 КБ

mkdir -p "$DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
    # Ротация по размеру (250 КБ) после каждой записи
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

log "START. pid=$$"

while true; do
    DAY=$(date '+%d')

    if [ "$DAY" = "10" ] || [ "$DAY" = "20" ]; then
        LAST_DAY=""
        [ -f "$MARKER" ] && LAST_DAY=$(cat "$MARKER")

        if [ "$LAST_DAY" != "$DAY" ]; then
            log "Очистка кэша. День: $DAY"
            
            # === 1. Штатная очистка через Android API ===
            pm trim-caches 100G > /dev/null 2>&1
            
            # === 2. Стандартные папки кэша приложений (БЕЗОПАСНО) ===
            find /data/data -type d -name "cache" -exec rm -rf {}/* \; 2>/dev/null
            find /data/data -type d -name "code_cache" -exec rm -rf {}/* \; 2>/dev/null
            find /sdcard/Android/data -type d -name "cache" -exec rm -rf {}/* \; 2>/dev/null
            
            # === 3. ВАЖНО: НЕ трогаем папку files/! ===
            # В /data/data/com.signage.player/files/content_cache/ лежат видеоролики
            # для оффлайн-показа. Их удаление ломает работу плеера.
            
            # === 4. Кэш системного провайдера загрузок ===
            rm -rf /data/data/com.android.providers.downloads/cache/* 2>/dev/null
            
            # === 5. Неизвестная папка /sdcard/etv ===
            rm -rf /sdcard/etv/* 2>/dev/null
            
            # === 6. Логи крашей ===
            rm -rf /sdcard/crashlog/* 2>/dev/null
            
            # === 7. Общие временные файлы ===
            rm -rf /data/local/tmp/*.log 2>/dev/null
            rm -rf /data/local/tmp/*.tmp 2>/dev/null
            
            echo "$DAY" > "$MARKER"
            log "Очистка завершена"
        fi
    fi

    sleep 3600
done