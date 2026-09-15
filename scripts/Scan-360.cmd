@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul
title Windows 360 Cleaner - Scan
REM Opens the guided window and starts a read-only scan. Nothing is removed unless you tick items
REM in the window and confirm. Beginners can also double-click Start-Check.cmd in the package root.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Select-360Cleanup.ps1" -StartPage Scan
set "RESULT=%ERRORLEVEL%"
echo.
pause
exit /b %RESULT%
