@echo off
chcp 65001 >nul
cd /d "%~dp0bridge"

node src\bridge.mjs pair

echo.
echo Run this again if the code expired (valid for 120 seconds).
pause >nul
