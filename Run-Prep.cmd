@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Prep.ps1" %*
if %ERRORLEVEL% NEQ 0 pause
