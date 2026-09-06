@echo off
setlocal EnableExtensions
chcp 65001 >nul 2>&1

rem StayAwake launcher: elevates to Administrator, then runs StayAwake.ps1.
rem Usage:  StayAwake.cmd [-Status | -Restore | -Guard | -DisableLockScreen]
rem Double-click with no arguments to apply the default preset.

set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%StayAwake.ps1"

if not exist "%PS1%" (
    echo [ERROR] StayAwake.ps1 not found next to this launcher: "%PS1%"
    goto :fail
)

rem -Status and -Guard do not need elevation; everything else does.
set "NEEDS_ADMIN=1"
echo %* | findstr /I /C:"-Status" >nul && set "NEEDS_ADMIN=0"
echo %* | findstr /I /C:"-Guard"  >nul && set "NEEDS_ADMIN=0"

if "%NEEDS_ADMIN%"=="1" (
    fltmc >nul 2>&1
    if errorlevel 1 (
        echo Requesting Administrator privileges...
        powershell -NoProfile -ExecutionPolicy Bypass -Command ^
            "Start-Process -FilePath 'cmd.exe' -ArgumentList '/c','\"%~f0\" %*' -Verb RunAs"
        if errorlevel 1 goto :fail
        exit /b 0
    )
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"

if "%NEEDS_ADMIN%"=="1" (
    echo.
    pause
)
exit /b %RC%

:fail
echo.
pause
exit /b 1
