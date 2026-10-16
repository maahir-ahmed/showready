@echo off
title ShowReady - observer PC
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ShowReady.ps1" -Role observer %*
pause
