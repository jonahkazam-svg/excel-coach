@echo off
title Install Excel Coach
echo.
echo  Installing Excel Coach (downloads the latest version, sets up your key,
echo  and adds a Desktop shortcut). This needs an internet connection.
echo.
echo  If Windows shows a blue "protected your PC" box, click More info then Run anyway.
echo.
pause
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/jonahkazam-svg/excel-coach/main/quick-install.ps1 | iex"
echo.
echo  Done. You can close this window. Look for the "Excel Coach" icon on your Desktop.
echo.
pause
