@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\patch_driver.ps1" %*
set "RC=%errorlevel%"
if not "%RC%"=="0" pause
exit /b %RC%
