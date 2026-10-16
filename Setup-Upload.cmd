@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-Upload.ps1" %*
pause
