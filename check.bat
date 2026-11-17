@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

call "%~dp0_adb_target.bat" "%~1"
if errorlevel 1 (
    pause
    exit /b 1
)

echo.
echo ========================================
echo  Статус: %DEV%
echo  Режим: %MODE%
echo ========================================
echo.

echo [0] Получение root...
%ADB% root
timeout /t 3 /nobreak >nul
if "%MODE%"=="wifi" (
    "%ADB_EXE%" connect "%DEV%" >nul 2>&1
)
%ADB% wait-for-device
%ADB% shell id | find "uid=0" >nul
if errorlevel 1 (
    echo ВНИМАНИЕ: root не получен.
) else (
    echo   OK: root получен
)

echo.
echo [1] Проверка PID-файлов:
%ADB% shell "echo -n '  watchdog.pid: '; cat /data/local/tmp/scripts/watchdog.pid 2>/dev/null || echo 'отсутствует'"
%ADB% shell "echo -n '  cache_cleaner.pid: '; cat /data/local/tmp/scripts/cache_cleaner.pid 2>/dev/null || echo 'отсутствует'"

echo.
echo [2] Проверка живости процессов:
%ADB% shell "if [ -f /data/local/tmp/scripts/watchdog.pid ]; then PID=$(cat /data/local/tmp/scripts/watchdog.pid); if kill -0 $PID 2>/dev/null; then echo '  Watchdog: жив (PID '$PID')'; else echo '  Watchdog: мёртв (PID '$PID')'; fi; else echo '  Watchdog: PID-файл отсутствует'; fi"
%ADB% shell "if [ -f /data/local/tmp/scripts/cache_cleaner.pid ]; then PID=$(cat /data/local/tmp/scripts/cache_cleaner.pid); if kill -0 $PID 2>/dev/null; then echo '  Cleaner: жив (PID '$PID')'; else echo '  Cleaner: мёртв (PID '$PID')'; fi; else echo '  Cleaner: PID-файл отсутствует'; fi"

echo.
echo [3] Watchdog log:
%ADB% shell "tail -n 10 /data/local/tmp/scripts/watchdog.log 2>/dev/null || echo 'Лог отсутствует'"

echo.
echo [4] Cleaner log:
%ADB% shell "tail -n 5 /data/local/tmp/scripts/cache_cleaner.log 2>/dev/null || echo 'Лог отсутствует'"

echo.
echo [5] Счётчик ребутов:
%ADB% shell "cat /data/local/tmp/scripts/reboot_counter.txt 2>/dev/null || echo '0'"

echo.
echo [6] Последняя очистка кэша:
%ADB% shell "cat /data/local/tmp/scripts/last_clean_day.txt 2>/dev/null || echo 'Не выполнялась'"

echo.
echo [7] Статус сервиса:
%ADB% shell "getprop init.svc.led_monitor"

echo.
echo [8] Сетевой ADB:
%ADB% shell "echo -n '  persist.adb.tcp.port: '; getprop persist.adb.tcp.port"
%ADB% shell "echo -n '  service.adb.tcp.port: '; getprop service.adb.tcp.port"
%ADB% shell "echo -n '  adb_wifi_enabled: '; settings get global adb_wifi_enabled"

echo.
echo [9] SELinux:
%ADB% shell "getenforce"

echo.
pause
exit /b 0