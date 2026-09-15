@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul
title Windows 360 Cleaner - Verify
REM Opens the guided window on the read-only verification page. Verification never removes anything.
REM Beginners can also double-click Start-Check.cmd in the package root.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Select-360Cleanup.ps1" -StartPage Verify
set "RESULT=%ERRORLEVEL%"
echo.
pause
exit /b %RESULT%
