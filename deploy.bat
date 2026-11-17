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
echo  Универсальная установка LED-экрана
echo ========================================
echo  Устройство: %DEV%
echo  Режим: %MODE%
echo ========================================
echo.
echo Этапы:
echo   1. install.bat
echo   2. check.bat
echo   3. harden.bat
echo.
pause

echo.
echo ========================================
echo  ЭТАП 1: установка
echo ========================================
call "%~dp0install.bat" "%DEV%"
if errorlevel 1 (
    echo ОШИБКА: install.bat завершился с ошибкой.
    pause
    exit /b 1
)

REM Если install.bat сохранил новый адрес после перезагрузки — читаем его
if exist "%TEMP%\led_setup_last_target.txt" (
    set /p NEW_TARGET=<"%TEMP%\led_setup_last_target.txt"
    if not "!NEW_TARGET!"=="" set "DEV=!NEW_TARGET!"
)

echo.
echo ========================================
echo  ЭТАП 2: проверка
echo ========================================
call "%~dp0check.bat" "%DEV%"

echo.
echo Применить отключение сетевого ADB сейчас? ^(Y/N^)
set /p CONFIRM=

if /I not "%CONFIRM%"=="Y" (
    echo Защита вручную не применена.
    echo После следующей перезагрузки led_startup.sh сам отключит ADB,
    echo если установлена версия с маркером первого запуска.
    pause
    exit /b 0
)

echo.
echo ========================================
echo  ЭТАП 3: отключение сетевого ADB
echo ========================================
call "%~dp0harden.bat" "%DEV%"

echo.
echo ========================================
echo  ГОТОВО
echo ========================================
echo.
pause
exit /b 0