@echo off
chcp 65001 >nul
title Windows 360 Cleaner - Remove
echo This permanently removes only CONFIRMED 360/Qihoo targets.
echo Items marked ReviewOnly will not be deleted.
echo A third-party WinToolBox may lose functions that depend on confirmed 360 DLLs.
echo.
choice /C YN /N /M "Continue? [Y/N]: "
if errorlevel 2 exit /b 0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-360Cleanup.ps1" -Mode Remove -ConfirmRemoval
echo.
pause

