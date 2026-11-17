#!/system/bin/sh
# ============================================================
# cache_cleaner.sh v2 — очистка кэша 10-го и 20-го числа
#
# ИСПРАВЛЕНИЕ v2: прежние строки
#     find ... -name cache -exec rm -rf {}/* \;
# были no-op: find вызывает rm БЕЗ shell, глоб "/*" не раскрывается,
# rm получал литеральный путь ".../cache/*" и молча выходил.
# Теперь содержимое удаляется через sh -c, у которого глоб
# раскрывается. Сами папки cache/ остаются (приложения их ждут).
#
# НЕ трогаем files/: в /data/data/com.signage.player/files/content_cache/
# лежат видеоролики оффлайн-показа — их удаление ломает плеер.
# ============================================================
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
    SIZE=$(wc -c < "$LOG" 2>/dev/null)
    if [ "$SIZE" -gt "$MAX_LOG_BYTES" ] 2>/dev/null; then
        tail -c "$TRIM_LOG_BYTES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
    fi
}

# --- Защита от дубля со сверкой cmdline (фикс переиспользования PID) ---
if [ -f "$PIDFILE" ]; then
    OLD_PID=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null && grep -q "cache_cleaner" "/proc/$OLD_PID/cmdline" 2>/dev/null; then
        exit 0
    fi
fi
echo $$ > "$PIDFILE"
trap "rm -f $PIDFILE" EXIT

log "START pid=$$"

while true; do
    DAY=$(date '+%d')

    if [ "$DAY" = "10" ] || [ "$DAY" = "20" ]; then
        LAST_DAY=""
        [ -f "$MARKER" ] && LAST_DAY=$(cat "$MARKER")

        if [ "$LAST_DAY" != "$DAY" ]; then
            log "Очистка кэша. День: $DAY"

            # === 1. Штатная очистка через Android API (безопасна
            #     для работающих приложений, чистит и внешние кэши)
            pm trim-caches 100G > /dev/null 2>&1

            # === 2. Кэши приложений: glob раскрывает sh -c (раньше не работал)
            find /data/data -type d -name cache -exec sh -c 'rm -rf "$0"/*' {} \; 2>/dev/null
            find /data/data -type d -name code_cache -exec sh -c 'rm -rf "$0"/*' {} \; 2>/dev/null
            find /sdcard/Android/data -type d -name cache -exec sh -c 'rm -rf "$0"/*' {} \; 2>/dev/null

            # === 3. ВАЖНО: НЕ трогаем папку files/! (см. шапку)

            # === 4. Кэш системного провайдера загрузок
            rm -rf /data/data/com.android.providers.downloads/cache/* 2>/dev/null

            # === 5. Служебная папка плеера и логи крашей
            rm -rf /sdcard/etv/* 2>/dev/null
            rm -rf /sdcard/crashlog/* 2>/dev/null

            # === 6. Временные файлы (кольца логгера в /data/local/tmp/diag
            #     и логи скриптов в .../scripts/ не задеты — они в подпапках)
            rm -rf /data/local/tmp/*.log 2>/dev/null
            rm -rf /data/local/tmp/*.tmp 2>/dev/null

            echo "$DAY" > "$MARKER"
            log "Очистка завершена"
        fi
    fi

    sleep 3600
done
