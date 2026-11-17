#!/system/bin/sh
# ============================================================
# network_watchdog.sh v2 — сторож сети для LED-экранов (T982)
#
# Профиль отказа парка (по досье "Проблема Wi-Fi"): гибель драйвера
# AIC8800 — скан умирает, соединение рвётся, самовосстановления нет,
# помогает только перезагрузка. Поэтому лестница восстановления:
#   1) шлюз не пингуется (3 цикла подряд) -> svc wifi disable/enable
#      (до 3 раз — экран при этом не гаснет, контент локальный);
#   2) рестарты Wi-Fi не помогли         -> reboot (до 3 раз,
#      счётчик персистентный в reboot_counter.txt);
#   3) WAN (8.8.8.8) недоступен при живом шлюзе -> только журнал,
#      БЕЗ ребута: это авария 4G-модема/провайдера, ребут не поможет.
# Раз в час: контроль сканера — "0 сетей при живом соединении" —
# предвестник смерти драйвера; предупредительный рестарт Wi-Fi.
# ============================================================
DIR=/data/local/tmp/scripts
PIDFILE="$DIR/watchdog.pid"
COUNTER_FILE="$DIR/reboot_counter.txt"
GW_FILE="$DIR/gateway.txt"
LOG="$DIR/watchdog.log"
MAX_ERRORS=3        # неудачных цикла подряд до восстановления (цикл ~30 c)
MAX_WIFIX=3         # рестартов Wi-Fi до эскалации в ребут
MAX_REBOOTS=3       # ребутов подряд до режима "ждать сеть"
SCAN_EVERY=120      # период проверки сканера в циклах (~час)
MAX_SCANFIX=3       # рестартов Wi-Fi по признаку мёртвого сканера
ERRORS=0
WIFIX=0
SCANFIX=0
SCAN_DEAD=0
CYCLES=0

mkdir -p "$DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
    # Ротация по размеру: лог не растёт бесконечно между перезапусками
    SIZE=$(wc -c < "$LOG" 2>/dev/null)
    if [ "$SIZE" -gt 256000 ] 2>/dev/null; then
        tail -c 128000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
    fi
}

# --- Защита от дубля: сверяем ИМЯ процесса, а не только номер PID.
# После ребута счётчик PID начинается заново, и lone kill -0 даёт
# ложное "уже запущен" (устаревший PID занят чужим процессом) —
# из-за этого watchdog мог молча не стартовать после ребута.
if [ -f "$PIDFILE" ]; then
    OLD_PID=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null && grep -q "network_watchdog" "/proc/$OLD_PID/cmdline" 2>/dev/null; then
        exit 0
    fi
fi
echo $$ > "$PIDFILE"
trap "rm -f $PIDFILE" EXIT

REBOOTS=0
[ -f "$COUNTER_FILE" ] && REBOOTS=$(cat "$COUNTER_FILE")
[ -z "$REBOOTS" ] && REBOOTS=0

# Шлюз кэшируем в файл: при смерти драйвера маршрут исчезает из
# таблицы, а адрес из кэша остаётся — и это ровно тот случай,
# когда ребут оправдан. awk не используем: в toybox его может не быть.
GW=$(ip route 2>/dev/null | grep '^default' | head -n 1 | cut -d' ' -f3)
if [ -n "$GW" ]; then
    echo "$GW" > "$GW_FILE"
else
    [ -f "$GW_FILE" ] && GW=$(cat "$GW_FILE")
fi
# Аварийный адрес по умолчанию — подсеть точек парка (192.168.100.x)
[ -z "$GW" ] && GW=192.168.100.1

log "START pid=$$ gw=$GW reboots=$REBOOTS"

wifi_restart() {
    log "WIFI-RESTART: svc wifi disable/enable"
    svc wifi disable 2>/dev/null
    sleep 5
    svc wifi enable 2>/dev/null
    sleep 60
}

# Контроль сканера: обновляем результаты и считаем сети.
# В BSSID всегда есть ':', у заголовка таблицы ':' нет.
scan_check() {
    cmd wifi start-scan >/dev/null 2>&1
    sleep 10
    SCAN_N=$(cmd wifi list-scan-results 2>/dev/null | grep -c ':')
    [ -z "$SCAN_N" ] && SCAN_N=0
    if [ "$SCAN_N" -gt 0 ] 2>/dev/null; then
        if [ "$SCAN_DEAD" -gt 0 ]; then
            log "SCAN OK ($SCAN_N сетей) — счётчик смерти сканера сброшен"
        fi
        SCAN_DEAD=0
        SCANFIX=0
    else
        SCAN_DEAD=$((SCAN_DEAD + 1))
        log "SCAN DEAD (подряд $SCAN_DEAD): 0 сетей при живом соединении — предвестник гибели драйвера"
        # Действуем со второго подряд обнаружения (первое может быть гонкой скана)
        if [ "$SCAN_DEAD" -ge 2 ]; then
            if [ "$SCANFIX" -lt "$MAX_SCANFIX" ]; then
                SCANFIX=$((SCANFIX + 1))
                log "SCAN FIX: предупредительный рестарт Wi-Fi ($SCANFIX/$MAX_SCANFIX)"
                wifi_restart
            elif [ "$REBOOTS" -lt "$MAX_REBOOTS" ]; then
                REBOOTS=$((REBOOTS + 1))
                echo "$REBOOTS" > "$COUNTER_FILE"
                log "SCAN FIX не помог. REBOOT # $REBOOTS"
                /system/bin/reboot
                sleep 60
            else
                log "SCAN DEAD: лимит ребутов исчерпан, ждём"
                SCAN_DEAD=0
            fi
        fi
    fi
}

while true; do
    CYCLES=$((CYCLES + 1))
    if ping -c 1 -W 5 "$GW" >/dev/null 2>&1; then
        if [ "$ERRORS" -gt 0 ] || [ "$REBOOTS" -gt 0 ]; then
            log "PING OK ($GW) — счётчики сброшены (было errors=$ERRORS reboots=$REBOOTS)"
        fi
        ERRORS=0
        WIFIX=0
        REBOOTS=0
        rm -f "$COUNTER_FILE"
        # Раз в час контролируем сканер (только при живом соединении)
        [ $((CYCLES % SCAN_EVERY)) -eq 0 ] && scan_check
        # WAN недоступен при живом шлюзе — не авария экрана: контент
        # локальный, ребутить нельзя. Только запись в журнал.
        ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1 || log "WAN недоступен (шлюз $GW жив) — без ребута"
    else
        ERRORS=$((ERRORS + 1))
        log "GW FAIL ($GW) errors=$ERRORS/$MAX_ERRORS reboots=$REBOOTS/$MAX_REBOOTS"
        if [ "$ERRORS" -ge "$MAX_ERRORS" ]; then
            if [ "$WIFIX" -lt "$MAX_WIFIX" ]; then
                WIFIX=$((WIFIX + 1))
                log "WIFI-RESTART попытка $WIFIX/$MAX_WIFIX"
                wifi_restart
                ERRORS=0
            elif [ "$REBOOTS" -lt "$MAX_REBOOTS" ]; then
                REBOOTS=$((REBOOTS + 1))
                echo "$REBOOTS" > "$COUNTER_FILE"
                log "REBOOT # $REBOOTS"
                /system/bin/reboot
                sleep 60
            else
                log "ЛИМИТ РЕБУТОВ. Ждём появления сети, перезагрузок больше не будет."
                ERRORS=0
            fi
        fi
    fi
    sleep 30
done
