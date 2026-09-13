@echo off
chcp 65001 >nul
title Windows 360 Cleaner - Scan
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Select-360Cleanup.ps1"
echo.
pause

