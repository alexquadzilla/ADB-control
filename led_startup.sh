#!/system/bin/sh

FIRST_RUN_MARKER="/data/local/tmp/scripts/.first_run_after_install"

if [ -f "$FIRST_RUN_MARKER" ]; then
    rm -f "$FIRST_RUN_MARKER"
else
    setprop persist.adb.tcp.port 0
    setprop service.adb.tcp.port 0
    settings put global adb_wifi_enabled 0
    setprop ctl.restart adbd
fi

sleep 90

nohup /system/bin/sh /data/local/tmp/scripts/network_watchdog.sh >/dev/null 2>&1 </dev/null &
nohup /system/bin/sh /data/local/tmp/scripts/cache_cleaner.sh >/dev/null 2>&1 </dev/null &

while true; do
    sleep 3600
done