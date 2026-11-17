@echo off
setlocal
title Signage Logs Tool (merged)
REM v2: логи всегда рядом со скриптом, а не в текущем каталоге cmd (см. Инструкция 6.6)
cd /d "%~dp0"
REM ================= БАЗОВЫЕ ПЕРЕМЕННЫЕ =================
set "ADB=adb"
set "OUT="
set /p "OUT=Enter log folder name: "
if not defined OUT set "OUT=logs"
mkdir "%OUT%" 2>nul
mkdir "%OUT%\incidents" 2>nul
set "RINGDIR=/data/local/tmp/diag"
set "CONNTYPE=net"
set "PORT=5555"
REM ================= ВЫБОР ПОДКЛЮЧЕНИЯ (сразу после запуска) =================
:conn_choice
echo.
echo =====================================================
echo Select connection type:
echo 1. USB
echo 2. Network (IP:port)
echo =====================================================
set "CC="
set /p "CC=Select: "
if "%CC%"=="1" set "CONNTYPE=usb"& goto :usb_try
if "%CC%"=="2" set "CONNTYPE=net"& goto :ask_serial
echo Wrong choice.
goto :conn_choice
REM ================= USB-ПОДКЛЮЧЕНИЕ =================
:usb_try
echo.
echo Searching USB devices...
"%ADB%" devices > "%OUT%\devices_usb.txt" 2>&1
type "%OUT%\devices_usb.txt"
set "SERIAL="
for /f "tokens=1,2" %%A in ('"%ADB%" devices 2^>nul') do (
echo %%A| findstr /C:":" >nul
if errorlevel 1 if /I "%%B"=="device" if not defined SERIAL set "SERIAL=%%A"
)
if defined SERIAL goto :usb_ok
echo [FAIL] No USB devices found. Check cable / driver / adb on device.
set "R="
set /p "R=Retry? (Enter = retry, 0 = network, q = exit): "
if "%R%"=="0" goto :ask_serial
if /I "%R%"=="q" goto :quit
goto :usb_try
:usb_ok
echo [OK] USB device: %SERIAL%
goto :connected
REM ================= СЕТЕВОЕ ПОДКЛЮЧЕНИЕ =================
:ask_serial
set "IP="
set /p "IP=Enter device IP (or IP:port): "
echo %IP%| findstr /C:":" >nul
if not errorlevel 1 for /f "tokens=1,2 delims=:" %%A in ("%IP%") do set "IP=%%A"& set "PORT=%%B"
if not defined PORT set "PORT=5555"
:connect_try
set "SERIAL=%IP%:%PORT%"
echo.
echo Connecting to %SERIAL% ...
"%ADB%" connect %SERIAL% > "%OUT%\connect_result.txt" 2>&1
type "%OUT%\connect_result.txt"
findstr /I /C:"connected to" "%OUT%\connect_result.txt" >nul
if not errorlevel 1 goto :check_state
:ask_port
echo.
echo [FAIL] Connect failed on port %PORT%.
set "PORT="
set /p "PORT=Enter another port (Enter = 5555, 0 = exit): "
if "%PORT%"=="0" goto :quit
if "%PORT%"=="" set "PORT=5555"
goto :connect_try
:check_state
set "STATE="
for /f "tokens=1,2" %%A in ('"%ADB%" devices') do if /I "%%A"=="%SERIAL%" set "STATE=%%B"
if /I "%STATE%"=="device" goto :connected
echo [FAIL] Device state: [%STATE%]
if /I "%STATE%"=="unauthorized" echo Accept RSA key dialog on the panel screen.
goto :ask_port
:connected
"%ADB%" devices > "%OUT%\devices.txt" 2>&1
echo [OK] Connected: %SERIAL% (%CONNTYPE%)
REM ================= ADB ROOT =================
echo.
echo Requesting root (adb root)...
"%ADB%" -s "%SERIAL%" root > "%OUT%\adb_root.txt" 2>&1
type "%OUT%\adb_root.txt"
timeout /t 3 /nobreak >nul
set /a TRY=0
:wait_loop
set /a TRY+=1
REM v2: connect перенесён ВНУТРЬ цикла ожидания — adb root перезапускает adbd,
REM и единственный connect до цикла мог попасть на момент перезапуска,
REM после чего все 10 попыток shell падали и скрипт выходил с ошибкой
if /I "%CONNTYPE%"=="net" "%ADB%" connect %SERIAL% >nul 2>&1
"%ADB%" -s "%SERIAL%" shell echo ready >nul 2>&1
if not errorlevel 1 goto :root_stage
if %TRY% GEQ 10 (
echo [ERROR] No response after adb root.
pause
exit /b 1
)
timeout /t 1 /nobreak >nul
goto :wait_loop
:root_stage
echo.
echo Checking id...
"%ADB%" -s "%SERIAL%" shell id > "%OUT%\id_plain.txt" 2>&1
type "%OUT%\id_plain.txt"
set "SHPREFIX="
findstr /C:"uid=0" "%OUT%\id_plain.txt" >nul 2>&1
if not errorlevel 1 (
echo [INFO] Root via adb root.
goto :devinfo
)
REM ================= SU FALLBACK (from 1.bat) =================
set "SU="
echo === TEST SU: su 0 id ===
"%ADB%" -s "%SERIAL%" shell "su 0 id" > "%OUT%\su_test_0.txt" 2>&1
type "%OUT%\su_test_0.txt"
findstr /C:"uid=0" "%OUT%\su_test_0.txt" >nul 2>&1
if not errorlevel 1 set "SU=su 0"
if defined SU goto :su_done
echo === TEST SU: su root id ===
"%ADB%" -s "%SERIAL%" shell "su root id" > "%OUT%\su_test_root.txt" 2>&1
type "%OUT%\su_test_root.txt"
findstr /C:"uid=0" "%OUT%\su_test_root.txt" >nul 2>&1
if not errorlevel 1 set "SU=su root"
if defined SU goto :su_done
echo === TEST SU: su 0:0 id ===
"%ADB%" -s "%SERIAL%" shell "su 0:0 id" > "%OUT%\su_test_0_0.txt" 2>&1
type "%OUT%\su_test_0_0.txt"
findstr /C:"uid=0" "%OUT%\su_test_0_0.txt" >nul 2>&1
if not errorlevel 1 set "SU=su 0:0"
:su_done
if defined SU (
set "SHPREFIX=%SU%"
echo [INFO] Root via: %SU%
)
:devinfo
"%ADB%" -s "%SERIAL%" shell "getprop ro.build.display.id; getprop ro.serialno; getprop ro.vendor.wifi_hal_legacy" > "%OUT%\devinfo.txt" 2>&1
REM ================= MENU =================
:menu
echo.
echo =====================================================
echo 1. Save dmesg (dmesg -T ^> dmesg_time.txt)
echo 2. START ring: logcat+kernel rotation on device + trigger monitor (incidents)
echo 3. STOP ring + pull device ring to %OUT%\device_ring
echo 4. Dump logcat (logcat -d ^> log.txt)
echo 5. Thermal snapshot (thermal_snapshot_fixed.txt)
echo 6. FULL SNAPSHOT (wifi deep + reboots/crashes + storage + system/thermal/power)
echo 7. Disconnect and exit
echo 8. SEQUENCE 1+4+5+6 (dmesg, logcat dump, thermal, FULL SNAPSHOT)
echo =====================================================
set "CHOICE="
set /p "CHOICE=Select: "
if "%CHOICE%"=="1" goto :opt1
if "%CHOICE%"=="2" goto :opt2
if "%CHOICE%"=="3" goto :opt3
if "%CHOICE%"=="4" goto :opt4
if "%CHOICE%"=="5" goto :opt5
if "%CHOICE%"=="6" goto :opt6
if "%CHOICE%"=="7" goto :quit
if "%CHOICE%"=="8" goto :opt8
echo Wrong choice.
goto :menu
:opt1
echo.
echo Saving dmesg...
"%ADB%" -s "%SERIAL%" shell "%SHPREFIX% dmesg -T" > "%OUT%\dmesg_time.txt" 2>&1
echo [OK] %OUT%\dmesg_time.txt
goto :menu
REM ---- 2. Кольцевые буферы с ротацией НА УСТРОЙСТВЕ + триггер-монитор НА НОУТБУКЕ ----
:opt2
echo.
echo Starting rings on device + trigger monitor...
"%ADB%" -s "%SERIAL%" shell "mkdir -p %RINGDIR%" >nul 2>&1
start "RING_MAIN" "%ADB%" -s "%SERIAL%" shell "logcat -b main,system,crash,events -v threadtime -f %RINGDIR%/ring_main.log -r 4096 -n 8"
start "RING_KERNEL" "%ADB%" -s "%SERIAL%" shell "logcat -b kernel -v threadtime -f %RINGDIR%/ring_kernel.log -r 2048 -n 6"
start "TRIG_MONITOR" powershell -NoProfile -ExecutionPolicy Bypass -Command "$pat='cmd queue crashed|RSSI:0|NL80211_CMD_TRIGGER_SCAN failed|meson-gx-mmc|Fatal signal|ANR in|watchdog|tombstone|oom_reaper|lowmemorykiller|disconnect failed'; $dir='%OUT%\incidents'; $buf=[System.Collections.Generic.Queue[string]]::new(); $last=(Get-Date).AddMinutes(-10); $cur=''; $post=-1; & '%ADB%' -s '%SERIAL%' logcat -b main,system,crash,events,kernel -v threadtime | ForEach-Object { $buf.Enqueue($_); if($buf.Count -gt 4000){[void]$buf.Dequeue()}; if($post -ge 0){ Add-Content -Encoding UTF8 $cur $_; $post++; if($post -gt 800){$post=-1} }; if($_ -match $pat){ Add-Content -Encoding UTF8 ($dir+'\triggers_live.log') $_; $now=Get-Date; if(($now-$last).TotalSeconds -gt 60){ $last=$now; $cur=$dir+'\incident_'+$now.ToString('yyyyMMdd_HHmmss')+'.log'; $buf.ToArray() | Set-Content -Encoding UTF8 $cur; $post=0 } } }"
echo [OK] Rings started. Windows: RING_MAIN, RING_KERNEL, TRIG_MONITOR
goto :menu
:opt3
echo.
echo Stopping rings and pulling...
taskkill /f /fi "WINDOWTITLE eq RING_MAIN*" >nul 2>&1
taskkill /f /fi "WINDOWTITLE eq RING_KERNEL*" >nul 2>&1
taskkill /f /fi "WINDOWTITLE eq TRIG_MONITOR*" >nul 2>&1
"%ADB%" -s "%SERIAL%" shell "pkill -f 'logcat -b' 2>/dev/null" >nul 2>&1
"%ADB%" -s "%SERIAL%" pull %RINGDIR% "%OUT%\device_ring" >nul 2>&1
echo [OK] Pulled to %OUT%\device_ring
goto :menu
:opt4
echo.
echo Dumping logcat...
"%ADB%" -s "%SERIAL%" logcat -d > "%OUT%\log.txt" 2>&1
echo [OK] %OUT%\log.txt
goto :menu
:opt5
echo.
echo Reading thermal zones...
"%ADB%" -s "%SERIAL%" shell "sh -c 'for z in /sys/class/thermal/thermal_zone*; do [ -d $z ]|| continue; echo === $z ===; cat $z/type 2>/dev/null; cat $z/temp 2>/dev/null; done'" > "%OUT%\thermal_snapshot_fixed.txt" 2>&1
echo [OK] %OUT%\thermal_snapshot_fixed.txt
goto :menu
REM ---- 6. FULL SNAPSHOT ----
:opt6
echo.
echo [SNAPSHOT] start...
call :snapshot_block
echo [SNAPSHOT] done: %OUT%
goto :menu
REM ---- 8. ПОСЛЕДОВАТЕЛЬНОСТЬ 1 + 4 + 5 + 6 ----
:opt8
echo.
echo [SEQ] Running sequence: 1, 4, 5, 6 ...
echo.
echo Saving dmesg...
"%ADB%" -s "%SERIAL%" shell "%SHPREFIX% dmesg -T" > "%OUT%\dmesg_time.txt" 2>&1
echo [OK] %OUT%\dmesg_time.txt
echo.
echo Dumping logcat...
"%ADB%" -s "%SERIAL%" logcat -d > "%OUT%\log.txt" 2>&1
echo [OK] %OUT%\log.txt
echo.
echo Reading thermal zones...
"%ADB%" -s "%SERIAL%" shell "sh -c 'for z in /sys/class/thermal/thermal_zone*; do [ -d $z ]|| continue; echo === $z ===; cat $z/type 2>/dev/null; cat $z/temp 2>/dev/null; done'" > "%OUT%\thermal_snapshot_fixed.txt" 2>&1
echo [OK] %OUT%\thermal_snapshot_fixed.txt
echo.
echo [SNAPSHOT] start...
call :snapshot_block
echo [SNAPSHOT] done: %OUT%
echo.
echo [SEQ] Sequence 1, 4, 5, 6 complete: %OUT%
goto :menu
REM ---- v2: блок снимка вынесен в подпрограмму (раньше дублировался в п.6 и п.8) ----
REM ---- dumpsys dhcp удалён: сервиса не существует, файл всегда был пуст ----
:snapshot_block
REM --- Блок: Wi-Fi углублённо ---
"%ADB%" -s "%SERIAL%" shell "cmd wifi status" > "%OUT%\wifi_status.txt" 2>&1
"%ADB%" -s "%SERIAL%" shell "cmd wifi list-scan-results" > "%OUT%\wifi_scan.txt" 2>&1
"%ADB%" -s "%SERIAL%" shell "dumpsys wifi" > "%OUT%\wifi_dumpsys.txt" 2>&1
"%ADB%" -s "%SERIAL%" shell "dumpsys connectivity" > "%OUT%\connectivity.txt" 2>&1
"%ADB%" -s "%SERIAL%" shell "iw dev wlan0 link" > "%OUT%\iw_link.txt" 2>&1
"%ADB%" -s "%SERIAL%" shell "cat /proc/net/wireless; cat /proc/net/dev" > "%OUT%\net_dev.txt" 2>&1
"%ADB%" -s "%SERIAL%" shell "ip -s link show wlan0; ip addr show wlan0; ip route" > "%OUT%\ip_stats.txt" 2>&1
"%ADB%" -s "%SERIAL%" shell "%SHPREFIX% sh -c 'cat /proc/net/rwnx/* 2>/dev/null; cat /sys/kernel/debug/aicwf/* 2>/dev/null'" > "%OUT%\wifi_driver_dbg.txt" 2>&1
REM --- Блок: причины ребутов и крашей ---
"%ADB%" -s "%SERIAL%" shell "getprop ro.boot.bootreason; cat /proc/uptime" > "%OUT%\boot_reason.txt" 2>&1
"%ADB%" -s "%SERIAL%" shell "%SHPREFIX% sh -c 'ls -l /data/tombstones /data/anr 2>/dev/null'" > "%OUT%\crash_list.txt" 2>&1
"%ADB%" -s "%SERIAL%" shell "dumpsys dropbox --print data_app_crash,system_server_crash,system_server_watchdog,lastkmsg" > "%OUT%\dropbox.txt" 2>&1
"%ADB%" -s "%SERIAL%" shell "%SHPREFIX% sh -c 'mkdir -p /data/local/tmp/diag/pstore; cp /sys/fs/pstore/* /data/local/tmp/diag/pstore/ 2>/dev/null'" >nul 2>&1
"%ADB%" -s "%SERIAL%" pull /data/local/tmp/diag/pstore "%OUT%\pstore" >nul 2>&1
for /f "delims=" %%f in ('"%ADB%" -s "%SERIAL%" shell "ls -t /data/tombstones/tombstone_* 2>/dev/null | head -2"') do "%ADB%" -s "%SERIAL%" pull "%%f" "%OUT%\" >nul 2>&1
REM --- Блок: накопители ---
"%ADB%" -s "%SERIAL%" shell "df -h" > "%OUT%\df.txt" 2>&1
"%ADB%" -s "%SERIAL%" shell "cat /proc/diskstats" > "%OUT%\diskstats.txt" 2>&1
"%ADB%" -s "%SERIAL%" shell "cat /sys/class/mmc_host/mmc0/mmc0:0001/life_time /sys/class/mmc_host/mmc0/mmc0:0001/pre_eol_info 2>/dev/null" > "%OUT%\emmc_health.txt" 2>&1
REM --- Блок: система / тепло / питание (батареи нет: dumpsys battery = состояние внешнего БП/AC) ---
"%ADB%" -s "%SERIAL%" shell "getprop" > "%OUT%\getprop.txt" 2>&1
"%ADB%" -s "%SERIAL%" shell "cat /proc/loadavg; cat /proc/meminfo; cat /proc/swaps" > "%OUT%\memory.txt" 2>&1
"%ADB%" -s "%SERIAL%" shell "sh -c 'for z in /sys/class/thermal/thermal_zone*; do [ -d $z ]|| continue; echo === $z ===; cat $z/type 2>/dev/null; cat $z/temp 2>/dev/null; done'" > "%OUT%\thermal_snapshot.txt" 2>&1
"%ADB%" -s "%SERIAL%" shell "%SHPREFIX% sh -c 'cat /sys/kernel/mm/ksm/run /sys/kernel/mm/ksm/full_scans 2>/dev/null'" > "%OUT%\ksm.txt" 2>&1
"%ADB%" -s "%SERIAL%" shell "sh -c 'top -b -n 1 | head -60'" > "%OUT%\top.txt" 2>&1
"%ADB%" -s "%SERIAL%" shell "ps -A -T -o PID,TID,STAT,PCPU,PMEM,NAME" > "%OUT%\threads.txt" 2>&1
"%ADB%" -s "%SERIAL%" shell "%SHPREFIX% sh -c 'cat /sys/kernel/debug/usb/devices 2>/dev/null'" > "%OUT%\usb_devices.txt" 2>&1
"%ADB%" -s "%SERIAL%" shell "dumpsys battery" > "%OUT%\power_ac.txt" 2>&1
exit /b 0
:quit
echo.
if /I "%CONNTYPE%"=="net" "%ADB%" disconnect %SERIAL% >nul 2>&1
echo Logs: %OUT%
pause
exit /b 0
