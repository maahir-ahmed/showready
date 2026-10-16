@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ShowReady.ps1" -Mode full %*
pause
