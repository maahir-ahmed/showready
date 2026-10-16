@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Upload-Results.ps1" %*
pause
