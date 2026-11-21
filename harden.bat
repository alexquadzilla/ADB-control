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
echo  Защита устройства LED-экрана (v2.4)
echo ========================================
echo  Устройство: %DEV%
echo  Режим: %MODE%
echo ========================================
echo.

REM === Получение root ===
echo [1/7] Получение root...
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

REM === Проверка watchdog через PID-файл + cmdline ===
echo.
echo [2/7] Проверка watchdog...
%ADB_EXE% -s %DEV% shell "if [ -f /data/local/tmp/scripts/watchdog.pid ]; then PID=$(cat /data/local/tmp/scripts/watchdog.pid); if kill -0 $PID 2>/dev/null && grep -q network_watchdog /proc/$PID/cmdline 2>/dev/null; then echo ALIVE:$PID; else echo DEAD:$PID; fi; else echo MISSING; fi" > "%TEMP%\led_wd_check.txt" 2>nul
set /p WD_STATUS=<"%TEMP%\led_wd_check.txt"
del "%TEMP%\led_wd_check.txt" >nul 2>&1

if "!WD_STATUS!"=="MISSING" (
    echo   ВНИМАНИЕ: watchdog не запущен - PID-файл отсутствует
    echo   Перед отключением ADB он будет перезапущен на шаге 6.
    set "WD_OK=0"
) else (
    for /f "tokens=1,2 delims=:" %%a in ("!WD_STATUS!") do (
        set "WD_STATE=%%a"
        set "WD_PID=%%b"
    )
    if "!WD_STATE!"=="ALIVE" (
        echo   OK: watchdog жив, PID !WD_PID!
        set "WD_OK=1"
    ) else (
        echo   ВНИМАНИЕ: watchdog мёртв, PID !WD_PID!
        echo   Перед отключением ADB он будет перезапущен на шаге 6.
        set "WD_OK=0"
    )
)

REM === Проверка cleaner через PID-файл + cmdline ===
echo.
echo [3/7] Проверка cleaner...
%ADB_EXE% -s %DEV% shell "if [ -f /data/local/tmp/scripts/cache_cleaner.pid ]; then PID=$(cat /data/local/tmp/scripts/cache_cleaner.pid); if kill -0 $PID 2>/dev/null && grep -q cache_cleaner /proc/$PID/cmdline 2>/dev/null; then echo ALIVE:$PID; else echo DEAD:$PID; fi; else echo MISSING; fi" > "%TEMP%\led_cl_check.txt" 2>nul
set /p CL_STATUS=<"%TEMP%\led_cl_check.txt"
del "%TEMP%\led_cl_check.txt" >nul 2>&1

if "!CL_STATUS!"=="MISSING" (
    echo   ВНИМАНИЕ: cleaner не запущен - PID-файл отсутствует
    set "CL_OK=0"
) else (
    for /f "tokens=1,2 delims=:" %%a in ("!CL_STATUS!") do (
        set "CL_STATE=%%a"
        set "CL_PID=%%b"
    )
    if "!CL_STATE!"=="ALIVE" (
        echo   OK: cleaner жив, PID !CL_PID!
        set "CL_OK=1"
    ) else (
        echo   ВНИМАНИЕ: cleaner мёртв, PID !CL_PID!
        set "CL_OK=0"
    )
)

REM === Проверка led_startup.sh ===
echo.
echo [4/7] Проверка led_startup.sh...
%ADB_EXE% -s %DEV% shell "if [ -f /vendor/etc/init/led_startup.sh ]; then if grep -q 'persist.adb.tcp.port 0' /vendor/etc/init/led_startup.sh; then echo OK; else echo NO_ADB_DISABLE; fi; else echo MISSING; fi" > "%TEMP%\led_startup_check.txt" 2>nul
set /p STARTUP_STATUS=<"%TEMP%\led_startup_check.txt"
del "%TEMP%\led_startup_check.txt" >nul 2>&1

if "!STARTUP_STATUS!"=="MISSING" (
    echo   ВНИМАНИЕ: led_startup.sh отсутствует!
    echo   После перезагрузки защита НЕ будет работать.
    echo   Выполните install.bat для установки.
    set "STARTUP_OK=0"
) else if "!STARTUP_STATUS!"=="NO_ADB_DISABLE" (
    echo   ВНИМАНИЕ: led_startup.sh не содержит отключение ADB!
    echo   После перезагрузки ADB останется включённым.
    echo   Обновите led_startup.sh через install.bat.
    set "STARTUP_OK=0"
) else (
    echo   OK: led_startup.sh содержит отключение ADB
    set "STARTUP_OK=1"
)

REM === Проверка led_monitor.rc ===
echo.
echo [5/7] Проверка led_monitor.rc...
%ADB_EXE% -s %DEV% shell "if [ -f /vendor/etc/init/led_monitor.rc ]; then echo OK; else echo MISSING; fi" > "%TEMP%\led_rc_check.txt" 2>nul
set /p RC_STATUS=<"%TEMP%\led_rc_check.txt"
del "%TEMP%\led_rc_check.txt" >nul 2>&1

if "!RC_STATUS!"=="MISSING" (
    echo   ВНИМАНИЕ: led_monitor.rc отсутствует!
    echo   Сервис автозапуска не будет работать.
    set "RC_OK=0"
) else (
    echo   OK: led_monitor.rc установлен
    set "RC_OK=1"
)

REM === Итоговая проверка готовности ===
echo.
echo ========================================
echo  Итоговая проверка
echo ========================================
echo.
if "!WD_OK!"=="1" (echo   [OK] Watchdog запущен) else (echo   [!!] Watchdog НЕ запущен)
if "!CL_OK!"=="1" (echo   [OK] Cleaner запущен) else (echo   [!!] Cleaner НЕ запущен)
if "!STARTUP_OK!"=="1" (echo   [OK] led_startup.sh настроен) else (echo   [!!] led_startup.sh НЕ настроен)
if "!RC_OK!"=="1" (echo   [OK] led_monitor.rc установлен) else (echo   [!!] led_monitor.rc НЕ установлен)
echo.

if "!WD_OK!"=="0" if "!STARTUP_OK!"=="0" (
    echo КРИТИЧЕСКАЯ ОШИБКА: ни watchdog, ни led_startup.sh не настроены!
    echo После отключения ADB устройство останется без защиты.
    echo.
    echo Сначала выполните: install.bat
    pause
    exit /b 1
)

if "!STARTUP_OK!"=="0" (
    echo ВНИМАНИЕ: led_startup.sh не настроен.
    echo После перезагрузки ADB останется включённым.
    echo Рекомендуется выполнить: install.bat
    echo.
)

echo Ждите 10 секунд
echo.
timeout /t 10 /nobreak
echo.
echo Применяем защиту...
echo.

REM === v2: [6/7] Гарантируем живость watchdog и cleaner ДО отключения ADB.
REM Если скрипт умер — перезапускаем СЕЙЧАС, пока соединение ещё доступно:
REM после ctl.restart adbd в wifi-режиме до устройства уже не достучаться.
echo [6/7] Проверка/перезапуск watchdog и cleaner перед отключением...
call :ensure_alive watchdog watchdog.pid network_watchdog.sh
call :ensure_alive cleaner  cache_cleaner.pid cache_cleaner.sh

REM === [7/7] Отключение сетевого ADB + перезапуск adbd ===
echo.
echo [7/7] Отключение сетевого ADB...
echo.
echo ВНИМАНИЕ:
if "%MODE%"=="wifi" (
    echo   Сейчас подключение по Wi-Fi будет разорвано.
    echo   Это нормально — защита активирована.
) else (
    echo   Сейчас adbd перезапустится.
    echo   USB-соединение может кратко переподключиться.
)
echo.
%ADB% shell "setprop persist.adb.tcp.port 0"
%ADB% shell "setprop service.adb.tcp.port 0"
%ADB% shell "settings put global adb_wifi_enabled 0"
echo   OK: настройки применены (persist.adb.tcp.port=0, service.adb.tcp.port=0, adb_wifi_enabled=0)

%ADB% shell "setprop ctl.restart adbd" >nul 2>&1

REM === Ждём 5 секунд ===
timeout /t 5 /nobreak >nul

REM === v2: Контроль процессов после перезапуска adbd.
REM В wifi-режиме невозможен: сетевой ADB только что выключен.
REM В usb-режиме при необходимости перезапускаем (ensure_alive).
if "%MODE%"=="usb" (
    echo.
    echo Контроль процессов после перезапуска adbd...
    call :ensure_alive watchdog watchdog.pid network_watchdog.sh
    call :ensure_alive cleaner  cache_cleaner.pid cache_cleaner.sh
)

echo.
echo ========================================
echo  ЗАЩИТА АКТИВИРОВАНА
echo ========================================
echo.
echo Что сделано:
echo   - watchdog и cleaner работают (перезапущены при необходимости)
echo   - persist.adb.tcp.port = 0
echo   - service.adb.tcp.port = 0
echo   - adb_wifi_enabled = 0
echo   - adbd перезапущен
echo.
if "%MODE%"=="wifi" (
    echo Соединение по Wi-Fi разорвано.
    echo Устройство больше недоступно по сети.
    echo.
    echo Для будущего обслуживания:
    echo   1. Подключите USB-кабель
    echo   2. Запустите: enable_network_adb.bat usb
) else (
    echo Сетевой ADB отключён.
    echo.
    echo Для будущего обслуживания:
    echo   enable_network_adb.bat usb
    echo или:
    echo   enable_network_adb.bat
)
echo.
echo После следующей перезагрузки led_startup.sh
echo автоматически отключит ADB снова.
echo.
pause
exit /b 0

REM === v2: Подпрограмма: убедиться, что скрипт жив; при необходимости перезапустить.
REM Использование: call :ensure_alive watchdog watchdog.pid network_watchdog.sh
REM Проверка сверяет cmdline процесса — lone kill -0 даёт ложное "жив"
REM при переиспользовании номера PID после перезагрузки.
:ensure_alive
set "EA_KIND=%~1"
set "EA_PIDFILE=/data/local/tmp/scripts/%~2"
set "EA_SCRIPT=%~3"
%ADB_EXE% -s %DEV% shell "if [ -f %EA_PIDFILE% ]; then PID=$(cat %EA_PIDFILE%); if kill -0 $PID 2>/dev/null && grep -q %EA_SCRIPT% /proc/$PID/cmdline 2>/dev/null; then echo ALIVE:$PID; else echo DEAD:$PID; fi; else echo MISSING; fi" > "%TEMP%\led_ea_check.txt" 2>nul
set /p EA_RES=<"%TEMP%\led_ea_check.txt"
del "%TEMP%\led_ea_check.txt" >nul 2>&1
echo   %EA_KIND%: !EA_RES!
if not "!EA_RES:~0,5!"=="ALIVE" (
    echo   %EA_KIND% не жив — перезапускаем...
    %ADB% shell "rm -f %EA_PIDFILE%; nohup /system/bin/sh /data/local/tmp/scripts/%EA_SCRIPT% >/dev/null 2>&1 </dev/null &"
    timeout /t 2 /nobreak >nul
    echo   OK: %EA_KIND% перезапущен
)
exit /b 0
