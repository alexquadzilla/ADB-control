@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

call "%~dp0_adb_target.bat" "%~1"
if errorlevel 1 (
    pause
    exit /b 1
)

REM === Проверка обязательных файлов и формата строк (LF) ===
REM Конвертация CRLF->LF на устройстве удалена: файлы должны быть в LF изначально,
REM иначе init не сможет разобрать led_monitor.rc, а shell сломает shebang в .sh
set "LOCAL_FAIL=0"
for %%F in (network_watchdog.sh cache_cleaner.sh led_startup.sh led_monitor.rc) do (
    if not exist "%~dp0%%F" (
        echo ОШИБКА: отсутствует файл %%F
        set "LOCAL_FAIL=1"
    ) else (
        call :check_lf "%~dp0%%F"
        if errorlevel 1 set "LOCAL_FAIL=1"
    )
)
if "%LOCAL_FAIL%"=="1" goto :fail

echo Используем adb: %ADB_EXE%
echo.
echo ========================================
echo  Установка скриптов на LED-экран (v2.2)
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

REM === findstr вместо find: в PATH Windows есть GNU find, который ломает проверку ===
%ADB% shell id | findstr /C:"uid=0" >nul
if errorlevel 1 (
    echo ОШИБКА: не удалось получить root
    goto :fail
)
echo   OK: uid=0 root

echo [3/6] Монтирование /vendor в режим записи...
%ADB% shell "mount -o rw,remount /vendor"
REM v2: проверка через /proc/mounts — grep работает на устройстве, findstr на хосте.
REM Прежний "mountpoint -w /vendor" всегда падал: флага -w в toybox нет,
REM а конвейер "mount | grep | find" ломался от GNU find из PATH.
%ADB% shell "grep ' /vendor ' /proc/mounts" | findstr /C:" rw," >nul 2>&1
if errorlevel 1 goto :verity_needed

echo   OK: /vendor доступен для записи
goto :upload_scripts

:verity_needed
echo   ВНИМАНИЕ: /vendor остался в режиме ro
echo   Текущее состояние монтирования:
%ADB% shell "grep ' /vendor ' /proc/mounts"
echo   Пробуем отключить verity...
"%ADB_EXE%" -s "%DEV%" disable-verity
if errorlevel 1 echo   Предупреждение: disable-verity вернул ошибку, пробуем перезагрузку всё равно
timeout /t 3 /nobreak >nul

echo.
echo ========================================
echo  ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА УСТРОЙСТВА
echo ========================================
echo.
echo Сейчас устройство перезагрузится.
echo.

if "%MODE%"=="wifi" (
    echo ПОСЛЕ перезагрузки IP-адрес может измениться —
    echo скрипт попробует найти устройство сам: прежний IP,
    echo затем поиск по MAC в подсети, и только потом спросит вас.
) else (
    echo После перезагрузки USB-устройство определится автоматически.
)

echo.
echo Нажмите любую клавишу для перезагрузки...
pause >nul

call :save_reconnect_info
set "FIND_NEXT=reconnect_after_reboot"
%ADB% reboot
echo.
echo Ожидание перезагрузки устройства...
REM v2.1: даём устройству реально уйти в ребут, иначе wait_boot может
REM ответить "успех" по ещё живому соединению до фактического ребута
timeout /t 8 /nobreak >nul
call :wait_boot 180
if not errorlevel 1 goto :reconnect_after_reboot
REM таймаут: в wifi это штатный случай "IP сменился" — ищем устройство сами
if "%MODE%"=="wifi" goto :find_new_ip
echo ОШИБКА: устройство не загрузилось за 180 секунд
goto :fail

:wait_usb
echo.
echo Ожидание подключения USB-устройства...
REM v2: без wait-for-device — он висит вечно, если устройство не вернётся
REM (или флапает FUNCTIONFS_BIND); опрашиваем тем же wait_boot
call :wait_boot 180
if errorlevel 1 (
    echo ОШИБКА: USB-устройство не вернулось после перезагрузки
    echo Если USB-adbd не поднимается, используйте Wi-Fi: install.bat IP:5555
    goto :fail
)

:reconnect_after_reboot
%ADB% root >nul 2>&1
timeout /t 3 /nobreak >nul

if "%MODE%"=="wifi" (
    call :connect_retry "!DEV!" 3
    if errorlevel 1 goto :fail
) else (
    REM v2.1: wait-for-device висит вечно при флапающем USB-транспорте
    REM (FUNCTIONFS_BIND) — ждём через wait_boot с таймаутом
    call :wait_boot 60
    if errorlevel 1 goto :fail
)

echo.
echo Повторное монтирование /vendor...
%ADB% shell "mount -o rw,remount /vendor"
%ADB% shell "grep ' /vendor ' /proc/mounts" | findstr /C:" rw," >nul 2>&1
if errorlevel 1 (
    echo ОШИБКА: не удалось смонтировать /vendor в rw
    echo Состояние:
    %ADB% shell "grep ' /vendor ' /proc/mounts"
    pause
    exit /b 1
)

:upload_scripts
echo   OK: /vendor доступен для записи

echo [4/6] Загрузка скриптов...
%ADB% shell "mkdir -p /data/local/tmp/scripts"

REM Маркер первого запуска создаём СРАЗУ (до долгого push), чтобы led_startup.sh
REM не отключил сетевой ADB во время установки. Существующий маркер НЕ удаляем:
REM это защита от случайного повторного запуска install.bat на боевом устройстве.
%ADB% shell "touch /data/local/tmp/scripts/.first_run_after_install"
if errorlevel 1 goto :fail

call :push_one "%~dp0network_watchdog.sh" /data/local/tmp/scripts/ || goto :fail
call :push_one "%~dp0cache_cleaner.sh" /data/local/tmp/scripts/ || goto :fail
call :push_one "%~dp0led_startup.sh" /vendor/etc/init/ || goto :fail
call :push_one "%~dp0led_monitor.rc" /vendor/etc/init/ || goto :fail

REM Финальная проверка формата загруженных файлов на устройстве (страховка).
REM v2: ОДИН обратный слэш в printf '\015' — toybox-printf раскрывает октальный
REM код в байт CR. Прежние '\\015' давали литеральный текст "\015", grep его
REM не находил ни в одном файле — проверка была мёртвой и всегда "проходила".
REM Внутренних двойных кавычек нет специально: cmd разбирает их как границы аргументов.
%ADB% shell "CR=$(printf '\015'); for f in /data/local/tmp/scripts/network_watchdog.sh /data/local/tmp/scripts/cache_cleaner.sh /vendor/etc/init/led_startup.sh /vendor/etc/init/led_monitor.rc; do grep -q $CR $f && echo BAD:$f; done" > "%TEMP%\led_cr_check.txt" 2>nul
findstr /C:"BAD:" "%TEMP%\led_cr_check.txt" >nul 2>&1
if not errorlevel 1 (
    echo ОШИБКА: эти файлы на устройстве содержат символы CR:
    type "%TEMP%\led_cr_check.txt"
    del "%TEMP%\led_cr_check.txt" >nul 2>&1
    goto :fail
)
del "%TEMP%\led_cr_check.txt" >nul 2>&1
echo   OK: формат файлов проверен ^(LF^)

%ADB% shell "chmod 755 /data/local/tmp/scripts/*.sh /vendor/etc/init/led_startup.sh"
if errorlevel 1 goto :fail
%ADB% shell "chmod 644 /vendor/etc/init/led_monitor.rc"
if errorlevel 1 goto :fail

echo [5/6] Проверка файлов...
%ADB% shell "ls -l /vendor/etc/init/led_monitor.rc" || goto :fail
%ADB% shell "ls -l /vendor/etc/init/led_startup.sh" || goto :fail
%ADB% shell "ls -l /data/local/tmp/scripts/network_watchdog.sh /data/local/tmp/scripts/cache_cleaner.sh" || goto :fail

REM Гарантируем наличие маркера непосредственно перед перезагрузкой
%ADB% shell "touch /data/local/tmp/scripts/.first_run_after_install"
if errorlevel 1 goto :fail

echo.
echo [6/6] Перезагрузка для регистрации сервиса...
call :save_reconnect_info
set "FIND_NEXT=final_check"
%ADB% reboot
echo   OK: устройство перезагружается
echo.
echo ========================================
echo  Ожидание загрузки устройства
echo ========================================
echo.
timeout /t 8 /nobreak >nul
call :wait_boot 180
if not errorlevel 1 goto :final_check
if "%MODE%"=="wifi" goto :find_new_ip
echo ОШИБКА: устройство не загрузилось за 180 секунд
goto :fail

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
REM Если сервис не running — init скорее всего не разобрал/не принял led_monitor.rc
%ADB% shell "getprop init.svc.led_monitor" | findstr /C:"running" >nul
if errorlevel 1 echo   ВНИМАНИЕ: сервис led_monitor не в состоянии running - проверьте led_monitor.rc и режим SELinux (getenforce)
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

REM v2: сверка cmdline — lone kill -0 даёт ложное "жив" при переиспользовании PID после ребута
%ADB_EXE% -s !DEV! shell "if [ -f /data/local/tmp/scripts/watchdog.pid ]; then PID=$(cat /data/local/tmp/scripts/watchdog.pid); if kill -0 $PID 2>/dev/null && grep -q network_watchdog /proc/$PID/cmdline 2>/dev/null; then echo ALIVE:$PID; else echo DEAD:$PID; fi; else echo MISSING; fi" > "%TEMP%\led_wd_check.txt" 2>nul
set /p WD_STATUS=<"%TEMP%\led_wd_check.txt"
del "%TEMP%\led_wd_check.txt" >nul 2>&1

%ADB_EXE% -s !DEV! shell "if [ -f /data/local/tmp/scripts/cache_cleaner.pid ]; then PID=$(cat /data/local/tmp/scripts/cache_cleaner.pid); if kill -0 $PID 2>/dev/null && grep -q cache_cleaner /proc/$PID/cmdline 2>/dev/null; then echo ALIVE:$PID; else echo DEAD:$PID; fi; else echo MISSING; fi" > "%TEMP%\led_cl_check.txt" 2>nul
set /p CL_STATUS=<"%TEMP%\led_cl_check.txt"
del "%TEMP%\led_cl_check.txt" >nul 2>&1

REM Сервис стартует скрипты через ~90 секунд после boot_completed:
REM статус MISSING ожидаем активно, DEAD не ждём (сразу перезапускаем ниже)
for /f "tokens=1 delims=:" %%a in ("!WD_STATUS!") do set "WD_STATE=%%a"
if "!WD_STATE!"=="MISSING" (
    call :wait_pid ALIVE "!WD_STATUS!" watchdog.pid 150
    set "WD_STATUS=!_RES!"
)
for /f "tokens=1 delims=:" %%a in ("!CL_STATUS!") do set "CL_STATE=%%a"
if "!CL_STATE!"=="MISSING" (
    call :wait_pid ALIVE "!CL_STATUS!" cache_cleaner.pid 150
    set "CL_STATUS=!_RES!"
)

echo   Watchdog: !WD_STATUS!
echo   Cleaner:  !CL_STATUS!

REM === Сравнение с DEAD:<pid>, разбор через for /f (как в harden.bat) ===
for /f "tokens=1 delims=:" %%a in ("!WD_STATUS!") do set "WD_STATE=%%a"
if "!WD_STATE!"=="DEAD" (
    echo.
    echo   Watchdog мёртв. Перезапускаем...
    %ADB% shell "rm -f /data/local/tmp/scripts/watchdog.pid"
    %ADB% shell "nohup /system/bin/sh /data/local/tmp/scripts/network_watchdog.sh >/dev/null 2>&1 </dev/null &"
    timeout /t 2 /nobreak >nul
    echo   OK: перезапущен
)

for /f "tokens=1 delims=:" %%a in ("!CL_STATUS!") do set "CL_STATE=%%a"
if "!CL_STATE!"=="DEAD" (
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

REM === v2.1: запоминаем адрес/подсеть/MAC и делаем порт adbd постоянным ===
REM Нужно, чтобы после ребута найти устройство, если DHCP сменил IP.
REM adb tcpip-порт слетает после ребута без persist (требует root; у нас он
REM уже получен). led_startup.sh на следующих загрузках снова отключит ADB,
REM так что безопасности это не ломает.
:save_reconnect_info
if /i "%MODE%"=="wifi" (
    for /f "tokens=1,2 delims=:" %%a in ("%DEV%") do (set "OLD_IP=%%a"& set "OLD_PORT=%%b")
    if not defined OLD_PORT set "OLD_PORT=%PORT%"
    for /f "tokens=1-3 delims=." %%a in ("!OLD_IP!") do set "SUBNET=%%a.%%b.%%c"
    set "DEV_MAC="
    REM v2.2: adb в for /f — БЕЗ кавычек вокруг пути (PATH добавлен в
    REM _adb_target.bat). Раньше здесь был путь в кавычках: cmd /c внутри
    REM for /f срезает крайние кавычки, и команда с 4 кавычками падала
    REM с "The filename, directory name, or volume label syntax is incorrect".
    for /f "delims=" %%a in ('adb -s "%DEV%" shell cat /sys/class/net/wlan0/address 2^>nul') do set "DEV_MAC=%%a"
    REM MAC из sysfs: 74:24:ca:41:8e:bd -> формат arp -a (74-24-ca-...):
    set "DEV_MAC=!DEV_MAC:~0,17!"
    set "DEV_MAC=!DEV_MAC::=-!"
    if not "!DEV_MAC:~2,1!"=="-" set "DEV_MAC="
    %ADB% shell setprop persist.adb.tcp.port %PORT% >nul 2>&1
)
exit /b 0

REM === v2.1: автоопределение адреса после ребута ===
REM Порядок: прежний IP (DHCP чаще выдаёт тот же) -> поиск в подсети /24
REM по MAC (ping-sweep + arp -a) -> ручной ввод.
REM FIND_NEXT задаёт, куда идти после успешного подключения:
REM reconnect_after_reboot (после первого ребута) или final_check (после финального).
:find_new_ip
echo.
echo Пробуем прежний адрес !OLD_IP!:!OLD_PORT! ...
call :connect_retry "!OLD_IP!:!OLD_PORT!" 1
if not errorlevel 1 (
    set "DEV=!OLD_IP!:!OLD_PORT!"
    set "ADB=%ADB_EXE% -s !DEV!"
    goto :%FIND_NEXT%
)
if not defined DEV_MAC goto :ask_new_ip
if not defined SUBNET  goto :ask_new_ip
echo Поиск в сети !SUBNET!.0/24 по MAC !DEV_MAC! (займёт ~3 сек) ...
set "FOUND_IP="
for /f "usebackq delims=" %%a in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$s='!SUBNET!'; $m='!DEV_MAC!'; $t=@(); 1..254 | ForEach-Object { $t += (New-Object System.Net.NetworkInformation.Ping).SendPingAsync($s+'.'+$_,500) }; [System.Threading.Tasks.Task]::WaitAll($t); Start-Sleep -Milliseconds 400; (arp -a) -match $m | ForEach-Object { $_.Trim().Split(' ')[0] }"`) do set "FOUND_IP=%%a"
if not defined FOUND_IP goto :ask_new_ip
echo Устройство найдено: !FOUND_IP!
set "NEW_IP=!FOUND_IP!"
goto :apply_new_ip

:ask_new_ip
echo.
echo ========================================
echo  Введите НОВЫЙ IP-адрес устройства
echo ========================================
echo Автоопределение не сработало. Узнайте IP:
echo   - Настройки - О планшете - Статус - IP-адрес
echo   - Список клиентов вашего роутера
echo.
set "NEW_IP="
set /p NEW_IP=Новый IP-адрес (можно с портом, напр. 192.168.1.4:5555): 
if "!NEW_IP!"=="" (
    echo ОШИБКА: IP не указан
    goto :fail
)

:apply_new_ip
echo !NEW_IP!|findstr /C:":" >nul
if errorlevel 1 set "NEW_IP=!NEW_IP!:!PORT!"
set "DEV=!NEW_IP!"
set "ADB=%ADB_EXE% -s !DEV!"
echo Подключаемся к !DEV! ...
call :connect_retry "!DEV!" 3
if errorlevel 1 goto :fail
goto :%FIND_NEXT%

REM === push с проверкой кода возврата: при ошибке сразу выходим из подпрограммы ===
:push_one
"%ADB_EXE%" -s "%DEV%" push %1 "%~2"
if errorlevel 1 (
    echo ОШИБКА: не удалось отправить %~nx1 ^(%DEV% -^> %2^)
    exit /b 1
)
echo   OK: %~nx1 -^> %2
exit /b 0

REM === v2.1: Активное ожидание загрузки — опрос sys.boot_completed.
REM Сначала дешёвый опрос `adb devices`: он НЕ блокируется даже при
REM флапающем USB-транспорте (FUNCTIONFS_BIND), в отличие от wait-for-device
REM и shell-вызовов по недоступному серийнику — оба висят вечно, и таймаут
REM был бы недостижим. getprop зовём только когда устройство видно
REM в состоянии device; adb shell по отсутствующему серийнику мгновенно
REM завершается ошибкой, поэтому цикл укладывается в таймаут.
REM Возврат: 0 — загрузилась, 2 — нет ответа за таймаут.
:wait_boot
set "WB_TIMEOUT=%~1"
set /a WB_ELAPSED=0
:wb_loop
set "BOOT_V="
if "%MODE%"=="wifi" "%ADB_EXE%" connect "%DEV%" >nul 2>&1
set "DEV_SEEN="
REM v2.2: adb в for /f — БЕЗ кавычек вокруг пути. Обе прежние строки
REM ('"%ADB_EXE%" devices ...' и '%ADB% shell getprop ...') содержали
REM цитированный путь: cmd /c внутри for /f срезает крайние кавычки,
REM первая строка падала с "The filename ... is incorrect", вторая
REM молча возвращала пустоту (wait_boot был слеп, install всегда
REM досиживал таймаут и просил IP вручную). PATH с каталогом adb
REM добавляется в _adb_target.bat.
for /f "tokens=1,2" %%A in ('adb devices 2^>nul ^| findstr /V /C:"List of"') do if /I "%%A"=="%DEV%" set "DEV_SEEN=%%B"
if /I "!DEV_SEEN!"=="device" for /f "tokens=1 delims= " %%V in ('adb -s "%DEV%" shell getprop sys.boot_completed 2^>nul') do set "BOOT_V=%%V"
REM adb shell присылает CRLF — сравниваем первый символ, хвост не важен
if "!BOOT_V:~0,1!"=="1" (
    echo   OK: устройство загрузилось ^(!WB_ELAPSED! сек^)
    exit /b 0
)
if %WB_ELAPSED% geq %WB_TIMEOUT% (
    echo   TIMEOUT: нет ответа от устройства за %WB_TIMEOUT% сек
    exit /b 2
)
set /a WB_ELAPSED+=5
timeout /t 5 /nobreak >nul
goto :wb_loop

REM === Активное ожидание нужного статуса PID-файла ===
REM Использование: call :wait_pid ALIVE "<текущий статус>" watchdog.pid 150
REM Результат в переменной _RES
:wait_pid
set "_WANT=%~1"
set "_RES=%~2"
set "_PIDSUF=%~3"
set "WP_TIMEOUT=%~4"
set /a WP_ELAPSED=0
:wp_loop
if "!_RES:~0,6!"=="!_WANT!" exit /b 0
if %WP_ELAPSED% geq %WP_TIMEOUT% exit /b 0
set /a WP_ELAPSED+=5
timeout /t 5 /nobreak >nul
%ADB_EXE% -s !DEV! shell "if [ -f /data/local/tmp/scripts/%_PIDSUF% ]; then PID=$(cat /data/local/tmp/scripts/%_PIDSUF%); if kill -0 $PID 2>/dev/null; then echo ALIVE:$PID; else echo DEAD:$PID; fi; else echo MISSING; fi" > "%TEMP%\led_wp_check.txt" 2>nul
set /p _RES=<"%TEMP%\led_wp_check.txt"
del "%TEMP%\led_wp_check.txt" >nul 2>&1
goto :wp_loop

REM === Проверка файла на переводы строк CRLF (PowerShell читает байты: CR=13) ===
:check_lf
set "LF_FILE=%~1"
set "LF_FILE_Q=!LF_FILE:'=''!"
powershell -NoProfile -Command "$t=[IO.File]::ReadAllBytes('!LF_FILE_Q!'); foreach($b in $t){ if($b -eq 13){ exit 1 } }; exit 0" >nul 2>&1
if not errorlevel 1 exit /b 0
echo ОШИБКА: %~nx1 содержит Windows-переводы строк CRLF (или PowerShell недоступен). Сохраните файл в формате LF.
exit /b 1

:connect_retry
set "TARGET=%~1"
set "MAX=%~2"
set "ATTEMPT=0"

:retry_loop
set /a ATTEMPT+=1
echo   Попытка подключения !ATTEMPT!/!MAX!...
"%ADB_EXE%" connect "%TARGET%" >nul 2>&1
timeout /t 2 /nobreak >nul
"%ADB_EXE%" -s "%TARGET%" shell id >nul 2>&1
if not errorlevel 1 (
    echo   OK: подключено
    exit /b 0
)
if !ATTEMPT! lss !MAX! (
    timeout /t 3 /nobreak >nul
    goto :retry_loop
)
echo   ОШИБКА: не удалось подключиться после !MAX! попыток
exit /b 1

:fail
echo.
echo ОШИБКА: установка не удалась.
pause
exit /b 1

:end
pause
exit /b 0
