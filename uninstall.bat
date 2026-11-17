@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

set "RESET_ADB=0"
set "CONNECT_TARGET=%~1"

if "%CONNECT_TARGET%"=="--reset-adb" (
    set "RESET_ADB=1"
    set "CONNECT_TARGET=%~2"
)
if "%~2"=="--reset-adb" set "RESET_ADB=1"

call "%~dp0_adb_target.bat" "%CONNECT_TARGET%"
if errorlevel 1 (
    pause
    exit /b 1
)

echo.
echo ========================================
echo  Полное удаление LED-скриптов
echo ========================================
echo  Устройство: %DEV%
echo  Режим: %MODE%
echo  Сброс ADB: %RESET_ADB%
echo ========================================
echo.
echo Будет удалено:
echo   /vendor/etc/init/led_monitor.rc
echo   /vendor/etc/init/led_startup.sh
echo   /data/local/tmp/scripts/
echo.
echo Продолжить? ^(Y/N^)
set /p CONFIRM=
if /I not "%CONFIRM%"=="Y" goto :cancelled

echo.
echo [1/5] Получение root...
%ADB% root
timeout /t 3 /nobreak >nul
if "%MODE%"=="wifi" (
    "%ADB_EXE%" connect "%DEV%" >nul 2>&1
)
%ADB% wait-for-device
%ADB% shell id | findstr /C:"uid=0" >nul
if errorlevel 1 (
    echo ОШИБКА: root не получен.
    pause
    exit /b 1
)
echo   OK: root получен

echo.
echo [2/5] Остановка сервиса...
%ADB% shell "setprop ctl.stop led_monitor" 2>nul
timeout /t 2 /nobreak >nul

echo.
echo [3/5] Остановка процессов...
%ADB% shell "pkill -9 -f network_watchdog.sh" 2>nul
%ADB% shell "pkill -9 -f cache_cleaner.sh" 2>nul

echo.
echo [4/5] Удаление файлов...
%ADB% shell "mount -o rw,remount /vendor"
%ADB% shell "rm -f /vendor/etc/init/led_monitor.rc"
%ADB% shell "rm -f /vendor/etc/init/led_startup.sh"
%ADB% shell "rm -rf /data/local/tmp/scripts"

echo.
echo Проверка удаления:
%ADB% shell "ls -la /vendor/etc/init/led_monitor.rc 2>/dev/null || echo 'led_monitor.rc удалён'"
%ADB% shell "ls -la /vendor/etc/init/led_startup.sh 2>/dev/null || echo 'led_startup.sh удалён'"
%ADB% shell "ls -la /data/local/tmp/scripts 2>/dev/null || echo 'scripts удалён'"

echo.
if "%RESET_ADB%"=="1" (
    echo [5/5] Сброс настроек ADB...
    if "%MODE%"=="wifi" (
        set "RESET_PORT=%PORT%"
    ) else (
        set "RESET_PORT=5555"
    )
    %ADB% shell "setprop persist.adb.tcp.port !RESET_PORT!"
    %ADB% shell "setprop service.adb.tcp.port !RESET_PORT!"
    %ADB% shell "settings put global adb_wifi_enabled 1"
    echo.
    echo Сейчас adbd будет перезапущен.
    echo Соединение может разорваться.
    pause
    %ADB% shell "setprop ctl.restart adbd" >nul 2>&1
    echo.
    echo Сетевой ADB включён на порт !RESET_PORT!.
) else (
    echo [5/5] Настройки ADB не изменялись.
)

echo.
echo ========================================
echo  УДАЛЕНИЕ ЗАВЕРШЕНО
echo ========================================
echo.
pause
exit /b 0

:cancelled
echo Отменено.
pause
exit /b 0