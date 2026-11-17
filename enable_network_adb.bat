@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

call "%~dp0_adb_target.bat" "%~1"
if errorlevel 1 (
    pause
    exit /b 1
)

if "%PORT%"=="" set "PORT=5555"

echo.
echo ========================================
echo  Включение сетевого ADB
echo ========================================
echo  Устройство: %DEV%
echo  Режим: %MODE%
echo  Порт: %PORT%
echo ========================================
echo.

echo [1/3] Получение root...
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
echo [2/3] Включаем сетевой ADB...
%ADB% shell "setprop persist.adb.tcp.port %PORT%"
%ADB% shell "setprop service.adb.tcp.port %PORT%"
%ADB% shell "settings put global adb_wifi_enabled 1"

echo [3/3] Перезапускаем adbd...
%ADB% shell "setprop ctl.restart adbd"
timeout /t 5 /nobreak >nul

if "%MODE%"=="wifi" (
    "%ADB_EXE%" connect "%IP%:%PORT%" >nul 2>&1
    set "DEV=%IP%:%PORT%"
    set ADB="%ADB_EXE%" -s "%DEV%"
) else (
    %ADB% wait-for-device
)

echo.
echo ========================================
echo  ГОТОВО
echo ========================================
echo.

if "%MODE%"=="usb" (
    echo Сетевой ADB включён.
    echo.
    echo IP-адрес устройства:
    %ADB% shell "ip addr show wlan0 2>/dev/null | grep 'inet ' || echo 'Не удалось определить IP'"
    echo.
    echo После определения IP используйте:
    echo   check.bat IP:%PORT%
) else (
    echo Сетевой ADB включён:
    echo   %IP%:%PORT%
    echo.
    echo Проверка:
    echo   check.bat %IP%:%PORT%
)

echo.
echo После обслуживания можно отключить ADB:
echo   harden.bat %DEV%
echo.
pause