@echo off
REM ==================================================
REM  Общий выбор устройства для всех BAT-скриптов
REM  Поддерживает:
REM    script.bat                 -> меню USB/Wi-Fi
REM    script.bat 192.168.1.2      -> Wi-Fi порт 5555
REM    script.bat 192.168.1.2:5555 -> Wi-Fi указанный порт
REM    script.bat usb             -> первое USB-устройство
REM    script.bat SERIAL          -> конкретный USB serial
REM
REM  На выходе задаёт:
REM    ADB_EXE
REM    MODE = usb / wifi
REM    DEV
REM    ADB
REM    IP
REM    PORT
REM ==================================================

REM === Автопоиск adb.exe ===
set "ADB_EXE="
if exist "%~dp0adb.exe" set "ADB_EXE=%~dp0adb.exe"
if not defined ADB_EXE if exist "%~dp0..\adb.exe" set "ADB_EXE=%~dp0..\adb.exe"

if not defined ADB_EXE (
    where adb >nul 2>nul
    if not errorlevel 1 set "ADB_EXE=adb"
)

if not defined ADB_EXE (
    echo ОШИБКА: adb.exe не найден!
    exit /b 1
)

REM v2.2: каталог adb добавляем первым в PATH процесса. Это позволяет в
REM for /f вызывать adb БЕЗ кавычек вокруг пути: cmd /c внутри for /f
REM срезает крайние кавычки, и команда вида '"C:\...\adb.exe" -s "DEV"'
REM (4 кавычки) ломается с ошибкой "The filename, directory name, or
REM volume label syntax is incorrect". Голый `adb` в for /f работает
REM всегда; прямые вызовы с кавычками (вне for /f) не трогаем.
if not "%ADB_EXE%"=="adb" for %%i in ("%ADB_EXE%") do set "PATH=%%~dpi;%PATH%"

set "ARG=%~1"
set "MODE="
set "DEV="
set "IP="
set "PORT=5555"
set "SERIAL="

if "%ARG%"=="" goto ASK_MODE
if /I "%ARG%"=="usb" goto USB_AUTO
if /I "%ARG%"=="wifi" goto ASK_IP

REM Если есть двоеточие — считаем Wi-Fi IP:PORT
echo %ARG%|find ":" >nul
if not errorlevel 1 goto WIFI_PARSE

REM Если есть точка — считаем IP без порта
echo %ARG%|find "." >nul
if not errorlevel 1 goto WIFI_NO_PORT

REM Иначе считаем USB serial
goto USB_SERIAL

:ASK_MODE
echo.
echo ========================================
echo  Выберите способ подключения
echo ========================================
echo   1. Wi-Fi
echo   2. USB
echo.
set /p CHOICE=Ваш выбор (1 или 2): 

if "%CHOICE%"=="1" goto ASK_IP
if "%CHOICE%"=="2" goto USB_AUTO

echo ОШИБКА: неверный выбор.
exit /b 1

:ASK_IP
set /p IP=Введите IP-адрес устройства (можно с портом, напр. 192.168.1.4:5555): 
if "%IP%"=="" (
    echo ОШИБКА: IP не указан.
    exit /b 1
)

echo %IP%|find ":" >nul
if errorlevel 1 (
    set "PORT=5555"
    set "DEV=%IP%:5555"
) else (
    for /f "tokens=1,2 delims=:" %%a in ("%IP%") do (
        set "IP=%%a"
        set "PORT=%%b"
    )
    set "DEV=%IP%:%PORT%"
)

set "MODE=wifi"
set ADB="%ADB_EXE%" -s "%DEV%"

echo Подключение по Wi-Fi: %DEV%
"%ADB_EXE%" connect "%DEV%" >nul 2>&1
%ADB% wait-for-device
%ADB% shell id >nul 2>&1
if errorlevel 1 (
    echo ОШИБКА: не удалось подключиться к %DEV%
    exit /b 1
)

exit /b 0

:WIFI_NO_PORT
set "IP=%ARG%"
set "PORT=5555"
set "DEV=%IP%:%PORT%"
set "MODE=wifi"
set ADB="%ADB_EXE%" -s "%DEV%"

echo Подключение по Wi-Fi: %DEV%
"%ADB_EXE%" connect "%DEV%" >nul 2>&1
%ADB% wait-for-device
%ADB% shell id >nul 2>&1
if errorlevel 1 (
    echo ОШИБКА: не удалось подключиться к %DEV%
    exit /b 1
)

exit /b 0

:WIFI_PARSE
for /f "tokens=1,2 delims=:" %%a in ("%ARG%") do (
    set "IP=%%a"
    set "PORT=%%b"
)
set "DEV=%IP%:%PORT%"
set "MODE=wifi"
set ADB="%ADB_EXE%" -s "%DEV%"

echo Подключение по Wi-Fi: %DEV%
"%ADB_EXE%" connect "%DEV%" >nul 2>&1
%ADB% wait-for-device
%ADB% shell id >nul 2>&1
if errorlevel 1 (
    echo ОШИБКА: не удалось подключиться к %DEV%
    exit /b 1
)

exit /b 0

:USB_AUTO
echo.
echo Поиск USB-устройств...
"%ADB_EXE%" devices
echo.

REM === v2.2: поиск USB — голый adb (без кавычек в for /f) ===
for /f "tokens=1" %%a in ('adb devices ^| findstr /v "List" ^| findstr "device$"') do (
    if not defined SERIAL set "SERIAL=%%a"
)

if not defined SERIAL (
    echo ОШИБКА: USB-устройство не найдено.
    echo Подключите кабель и разрешите отладку.
    exit /b 1
)

set "DEV=%SERIAL%"
set "MODE=usb"
set ADB="%ADB_EXE%" -s "%DEV%"

echo Найдено USB-устройство: %DEV%
%ADB% wait-for-device
exit /b 0

:USB_SERIAL
set "DEV=%ARG%"
set "MODE=usb"
set ADB="%ADB_EXE%" -s "%DEV%"

echo Используется USB-устройство: %DEV%
%ADB% wait-for-device
%ADB% shell id >nul 2>&1
if errorlevel 1 (
    echo ОШИБКА: USB-устройство %DEV% недоступно.
    exit /b 1
)

exit /b 0
