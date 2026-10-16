@echo off
setlocal
title ShowReady LAN partner (iperf3 server, port 5201)
echo.
echo ==========================================================================
echo   ShowReady LAN partner - run this on a SOURCE PC (a PC that sends a feed)
echo ==========================================================================
echo.
if not exist "%~dp0bin\iperf3.exe" (
  echo bin\iperf3.exe is missing. Copy the whole ShowReady folder to this PC and try again.
  echo.
  pause
  exit /b 1
)
echo This PC's addresses:
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | Sort-Object InterfaceAlias | ForEach-Object { '    ' + $_.IPAddress.PadRight(17) + $_.InterfaceAlias }"
echo.
echo Pick the address on the network that carries the NDI/OMT feeds. On the show PC, run:
echo.
echo     Run-ShowReady.cmd -Skip load -LanHosts ^<that address^>
echo.
echo If Windows Firewall asks about iperf3: tick "Private networks" and click "Allow access".
echo That needs an administrator password. If you click Cancel instead, Windows blocks iperf3
echo on this network and the show PC cannot connect; ask IT to allow TCP and UDP port 5201.
echo.
echo Waiting for the show PC on port 5201. Leave this window open and close it when the test is done.
echo --------------------------------------------------------------------------
cd /d "%TEMP%"
"%~dp0bin\iperf3.exe" -s -p 5201
echo.
echo iperf3 stopped.
pause
