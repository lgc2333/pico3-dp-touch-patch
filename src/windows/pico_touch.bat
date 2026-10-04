@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\pico_touch.ps1" %*
set "RC=%errorlevel%"
pause
exit /b %RC%
