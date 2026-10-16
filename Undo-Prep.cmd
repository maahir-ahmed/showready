@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Prep.ps1" -Undo latest %*
if %ERRORLEVEL% NEQ 0 pause
