@echo off
chcp 65001 >nul
title Windows 360 Cleaner - Remove
echo This permanently removes only CONFIRMED 360/Qihoo targets.
echo Items marked ReviewOnly will not be deleted.
echo Browser profiles are preserved by default to protect bookmarks and user data.
echo A third-party WinToolBox may lose functions that depend on confirmed 360 DLLs.
echo Locked files will not trigger forced closure of normal programs or ACL takeover by default.
echo.
choice /C YN /N /M "Continue? [Y/N]: "
if errorlevel 255 (
  echo Invalid or unavailable input. Nothing was changed.
  exit /b 64
)
if errorlevel 2 (
  echo Cancelled. Nothing was changed.
  exit /b 2
)
set "CONFIRM_TEXT="
set /p "CONFIRM_TEXT=Type REMOVE-360 to confirm: "
if /I not "%CONFIRM_TEXT%"=="REMOVE-360" (
  echo Confirmation phrase did not match. Nothing was changed.
  exit /b 3
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-360Cleanup.ps1" -Mode Remove -ConfirmRemoval -ConfirmationPhrase REMOVE-CONFIRMED-360
set "RESULT=%ERRORLEVEL%"
echo.
pause
exit /b %RESULT%

