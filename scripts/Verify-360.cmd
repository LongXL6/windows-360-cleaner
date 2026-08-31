@echo off
chcp 65001 >nul
title Windows 360 Cleaner - Verify
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-360Cleanup.ps1" -Mode Verify
echo.
pause

