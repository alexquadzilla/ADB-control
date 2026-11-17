@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

call "%~dp0_adb_target.bat" "%~1"
if errorlevel 1 (
    pause
    exit /b 1
)

echo Используем adb: %ADB_EXE%
echo.
echo ========================================
echo  Установка скриптов на LED-экран
echo ========================================
echo  Устройство: %DEV%
echo  Режим: %MODE%
echo ========================================
echo.

echo [1/6] Подключение...
if "%MODE%"=="wifi" (
    call :connect_retry "%DEV%" 3
    if errorlevel 1 goto :fail
) else (
    %ADB% wait-for-device
    echo   OK: подключено
)

echo [2/6] Получение root...
%ADB% root
timeout /t 3 /nobreak >nul

if "%MODE%"=="wifi" (
    call :connect_retry "%DEV%" 3
    if errorlevel 1 goto :fail
) else (
    %ADB% wait-for-device
)

%ADB% shell id | find "uid=0" >nul
if errorlevel 1 (
    echo ОШИБКА: не удалось получить root
    goto :fail
)
echo   OK: uid=0 root

echo [3/6] Монтирование /vendor в режим записи...
%ADB% shell "mount -o rw,remount /vendor"
%ADB% shell "mount | grep ' /vendor '" | find "rw" >nul
if errorlevel 1 goto :verity_needed

echo   OK: /vendor доступен для записи
goto :upload_scripts

:verity_needed
echo   ВНИМАНИЕ: /vendor остался в режиме ro
echo   Пробуем отключить verity...
"%ADB_EXE%" -s "%DEV%" disable-verity
timeout /t 3 /nobreak >nul

echo.
echo ========================================
echo  ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА УСТРОЙСТВА
echo ========================================
echo.
echo Сейчас устройство перезагрузится.
echo.

if "%MODE%"=="wifi" (
    echo ПОСЛЕ перезагрузки IP-адрес может измениться!
    echo Вам нужно будет узнать новый IP.
) else (
    echo После перезагрузки USB-устройство определится автоматически.
)

echo.
echo Нажмите любую клавишу для перезагрузки...
pause >nul

%ADB% reboot
echo.
echo Ожидание перезагрузки 50 секунд...
timeout /t 50 /nobreak >nul

if "%MODE%"=="wifi" goto :ask_new_ip
goto :wait_usb

:ask_new_ip
echo.
echo ========================================
echo  Введите НОВЫЙ IP-адрес устройства
echo ========================================
echo.
echo Узнайте новый IP:
echo   - На экране: Настройки - О планшете - Статус - IP-адрес
echo   - Или посмотрите в списке клиентов вашего роутера
echo.
set /p NEW_IP=Новый IP-адрес: 
if "!NEW_IP!"=="" (
    echo ОШИБКА: IP не указан
    pause
    exit /b 1
)
echo !NEW_IP!|find ":" >nul
if errorlevel 1 set "NEW_IP=!NEW_IP!:5555"
set "DEV=!NEW_IP!"
set "ADB=%ADB_EXE% -s !DEV!"

echo Подключаемся к новому адресу !DEV!...
call :connect_retry "!DEV!" 3
if errorlevel 1 goto :fail

echo.
echo Ожидание полной загрузки adbd (10 сек)...
timeout /t 10 /nobreak >nul
goto :reconnect_after_reboot

:wait_usb
echo.
echo Ожидание подключения USB-устройства...
"%ADB_EXE%" wait-for-device
echo   OK: устройство подключено
echo.
echo Ожидание полной загрузки adbd (10 сек)...
timeout /t 10 /nobreak >nul

:reconnect_after_reboot
%ADB% root
timeout /t 3 /nobreak >nul

if "%MODE%"=="wifi" (
    call :connect_retry "!DEV!" 3
    if errorlevel 1 goto :fail
) else (
    %ADB% wait-for-device
)

echo.
echo Повторное монтирование /vendor...
%ADB% shell "mount -o rw,remount /vendor"
timeout /t 2 /nobreak >nul

%ADB% shell "mount | grep ' /vendor '" | find "rw" >nul
if errorlevel 1 (
    echo ОШИБКА: не удалось смонтировать /vendor в rw
    pause
    exit /b 1
)

:upload_scripts
echo   OK: /vendor доступен для записи

echo [4/6] Загрузка скриптов...
%ADB% shell "mkdir -p /data/local/tmp/scripts"

%ADB% shell "touch /data/local/tmp/scripts/.first_run_after_install"

"%ADB_EXE%" -s "!DEV!" push "%~dp0network_watchdog.sh" /data/local/tmp/scripts/
"%ADB_EXE%" -s "!DEV!" push "%~dp0cache_cleaner.sh" /data/local/tmp/scripts/
"%ADB_EXE%" -s "!DEV!" push "%~dp0led_startup.sh" /vendor/etc/init/
"%ADB_EXE%" -s "!DEV!" push "%~dp0led_monitor.rc" /vendor/etc/init/

echo.
echo   Конвертация CRLF в LF...
%ADB% shell "sed -i 's/\r$//' /data/local/tmp/scripts/network_watchdog.sh"
%ADB% shell "sed -i 's/\r$//' /data/local/tmp/scripts/cache_cleaner.sh"
%ADB% shell "sed -i 's/\r$//' /vendor/etc/init/led_startup.sh"
%ADB% shell "sed -i 's/\r$//' /vendor/etc/init/led_monitor.rc"
echo   OK: конвертация завершена

%ADB% shell "chmod 755 /data/local/tmp/scripts/*.sh /vendor/etc/init/led_startup.sh"
%ADB% shell "chmod 644 /vendor/etc/init/led_monitor.rc"

echo [5/6] Проверка файлов...
%ADB% shell "ls -l /vendor/etc/init/led_monitor.rc"
%ADB% shell "ls -l /vendor/etc/init/led_startup.sh"

echo.
echo   Проверка формата файлов:
%ADB% shell "od -c /vendor/etc/init/led_startup.sh | head -1"
%ADB% shell "od -c /data/local/tmp/scripts/network_watchdog.sh | head -1"

echo.
echo [6/6] Перезагрузка для регистрации сервиса...
%ADB% reboot
echo   OK: устройство перезагружается
echo.
echo ========================================
echo  Ожидание загрузки устройства
echo ========================================
echo.
echo Ждите 50 секунд...
echo.
timeout /t 50 /nobreak
echo.
echo Загрузка завершена! Подключаемся...
echo.

if "%MODE%"=="wifi" (
    call :connect_retry "!DEV!" 3
    if errorlevel 1 goto :ask_ip_after_final_reboot
    goto :final_check
)

"%ADB_EXE%" wait-for-device
echo   OK: устройство подключено
goto :final_check

:ask_ip_after_final_reboot
echo.
echo ========================================
echo  Введите НОВЫЙ IP-адрес устройства
echo ========================================
echo.
set /p NEW_IP=Новый IP-адрес: 
if "!NEW_IP!"=="" (
    echo ОШИБКА: IP не указан
    pause
    exit /b 1
)
echo !NEW_IP!|find ":" >nul
if errorlevel 1 set "NEW_IP=!NEW_IP!:5555"
set "DEV=!NEW_IP!"
set "ADB=%ADB_EXE% -s !DEV!"
call :connect_retry "!DEV!" 3
if errorlevel 1 goto :fail

:final_check
echo.
echo ========================================
echo  Готово: !DEV!
echo ========================================
echo.
echo Проверка процессов:
%ADB% shell "echo -n 'Watchdog: '; pgrep -f network_watchdog.sh || echo 'Не запущен'"
%ADB% shell "echo -n 'Cleaner: '; pgrep -f cache_cleaner.sh || echo 'Не запущен'"
echo.
echo Статус сервиса init:
%ADB% shell "getprop init.svc.led_monitor"
echo.
echo Логи watchdog:
%ADB% shell "tail -5 /data/local/tmp/scripts/watchdog.log 2>/dev/null || echo 'Лог отсутствует'"
echo.

if "%MODE%"=="wifi" (
    echo ========================================
    echo  РЕКОМЕНДАЦИЯ: Настройте статический IP
    echo ========================================
    echo.
    echo Чтобы IP не менялся после перезагрузки,
    echo настройте статический IP через настройки Wi-Fi.
    echo.
)

echo !DEV!>"%TEMP%\led_setup_last_target.txt"

REM === Проверка PID-файлов (через временные файлы) ===
echo.
echo Проверка PID-файлов...

%ADB% root >nul 2>&1
timeout /t 3 /nobreak >nul
if "%MODE%"=="wifi" "%ADB_EXE%" connect "!DEV!" >nul 2>&1
%ADB% wait-for-device

%ADB_EXE% -s !DEV! shell "if [ -f /data/local/tmp/scripts/watchdog.pid ]; then PID=$(cat /data/local/tmp/scripts/watchdog.pid); if kill -0 $PID 2>/dev/null; then echo ALIVE:$PID; else echo DEAD:$PID; fi; else echo MISSING; fi" > "%TEMP%\led_wd_check.txt" 2>nul
set /p WD_STATUS=<"%TEMP%\led_wd_check.txt"
del "%TEMP%\led_wd_check.txt" >nul 2>&1

%ADB_EXE% -s !DEV! shell "if [ -f /data/local/tmp/scripts/cache_cleaner.pid ]; then PID=$(cat /data/local/tmp/scripts/cache_cleaner.pid); if kill -0 $PID 2>/dev/null; then echo ALIVE:$PID; else echo DEAD:$PID; fi; else echo MISSING; fi" > "%TEMP%\led_cl_check.txt" 2>nul
set /p CL_STATUS=<"%TEMP%\led_cl_check.txt"
del "%TEMP%\led_cl_check.txt" >nul 2>&1

echo   Watchdog: !WD_STATUS!
echo   Cleaner:  !CL_STATUS!

if "!WD_STATUS!"=="DEAD" (
    echo.
    echo   Watchdog мёртв. Перезапускаем...
    %ADB% shell "rm -f /data/local/tmp/scripts/watchdog.pid"
    %ADB% shell "nohup /system/bin/sh /data/local/tmp/scripts/network_watchdog.sh >/dev/null 2>&1 </dev/null &"
    timeout /t 2 /nobreak >nul
    echo   OK: перезапущен
)

if "!CL_STATUS!"=="DEAD" (
    echo.
    echo   Cleaner мёртв. Перезапускаем...
    %ADB% shell "rm -f /data/local/tmp/scripts/cache_cleaner.pid"
    %ADB% shell "nohup /system/bin/sh /data/local/tmp/scripts/cache_cleaner.sh >/dev/null 2>&1 </dev/null &"
    timeout /t 2 /nobreak >nul
    echo   OK: перезапущен
)

echo.
echo Финальная проверка PID-файлов:
%ADB% shell "echo -n '  watchdog.pid: '; cat /data/local/tmp/scripts/watchdog.pid 2>/dev/null || echo 'отсутствует'"
%ADB% shell "echo -n '  cache_cleaner.pid: '; cat /data/local/tmp/scripts/cache_cleaner.pid 2>/dev/null || echo 'отсутствует'"

goto :end

:connect_retry
set "TARGET=%~1"
set "MAX=%~2"
set "ATTEMPT=0"

:retry_loop
set /a ATTEMPT+=1
echo   Попытка подключения %ATTEMPT%/%MAX%...
"%ADB_EXE%" connect %TARGET% >nul 2>&1
timeout /t 2 /nobreak >nul
"%ADB_EXE%" -s %TARGET% shell id >nul 2>&1
if not errorlevel 1 (
    echo   OK: подключено
    exit /b 0
)
if %ATTEMPT% lss %MAX% (
    timeout /t 3 /nobreak >nul
    goto :retry_loop
)
echo   ОШИБКА: не удалось подключиться после %MAX% попыток
exit /b 1

:fail
echo.
echo ОШИБКА: установка не удалась.
pause
exit /b 1

:end
pause
exit /b 0