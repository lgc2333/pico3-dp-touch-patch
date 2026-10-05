@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\downgrade_streaming.ps1" %*
set "RC=%errorlevel%"
pause
exit /b %RC%
