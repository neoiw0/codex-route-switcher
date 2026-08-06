@echo off
setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Codex-RouteSwitcher-Friend.ps1"
set "exit_code=%ERRORLEVEL%"

if not "%exit_code%"=="0" (
    echo.
    echo Switch failed - Codex was not started.
    pause
)

endlocal & exit /b %exit_code%
