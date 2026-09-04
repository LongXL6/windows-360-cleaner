@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul
title Windows 360 Cleaner - Remove
echo This permanently removes only CONFIRMED targets from an approved Scan report.
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
set "APPROVED_REPORT="
set /p "APPROVED_REPORT=Drag the approved Scan JSON here, then press Enter: "
if not defined APPROVED_REPORT (
  echo No approved Scan report was provided. Nothing was changed.
  exit /b 4
)
set "APPROVED_REPORT=%APPROVED_REPORT:"=%"
if not exist "%APPROVED_REPORT%" (
  echo The approved Scan report does not exist. Nothing was changed.
  exit /b 4
)
for %%I in ("%APPROVED_REPORT%") do if /I not "%%~xI"==".json" (
  echo The approved Scan report must be a JSON file. Nothing was changed.
  exit /b 4
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-360Cleanup.ps1" -Mode Remove -ConfirmRemoval -ConfirmationPhrase REMOVE-CONFIRMED-360 -ApprovedReport "%APPROVED_REPORT%"
set "RESULT=%ERRORLEVEL%"
echo.
pause
exit /b %RESULT%
