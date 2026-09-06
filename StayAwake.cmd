@echo off
setlocal EnableExtensions
chcp 65001 >nul 2>&1

rem Double-click entry point for StayAwake.ps1 (double-clicking a .ps1 opens an
rem editor instead of running it, which is the only reason this file exists).
rem
rem This launcher deliberately does NOT decide whether elevation is needed.
rem Batch can only string-match the command line to guess, that guess drifts from
rem the real parameter-set parsing in the script, and piping the argument list
rem through `echo` lets shell metacharacters in an argument run as commands.
rem StayAwake.ps1 checks WindowsPrincipal directly and re-launches itself
rem elevated when required.
rem
rem Note: `rem` does not protect metacharacters either, so no line in this file
rem may contain an ampersand or a pipe, not even inside a comment.
rem
rem Set STAYAWAKE_NO_PAUSE=1 to skip the trailing pause (used by CI).

set "PS1=%~dp0StayAwake.ps1"

if not exist "%PS1%" (
    echo [ERROR] StayAwake.ps1 not found next to this launcher: "%PS1%"
    if not defined STAYAWAKE_NO_PAUSE pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"

if not defined STAYAWAKE_NO_PAUSE (
    echo.
    pause
)
exit /b %RC%
