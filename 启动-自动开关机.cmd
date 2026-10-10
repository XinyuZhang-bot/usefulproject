@echo off
rem ===========================================================================
rem  AutoPowerPro - launcher
rem ---------------------------------------------------------------------------
rem  IMPORTANT: this file must stay pure ASCII. Do not paste non-ASCII text in.
rem  It only launches AutoPowerPro.ps1, which elevates itself when needed.
rem  If the UAC prompt does not appear, right-click this file and pick
rem  "Run as administrator".
rem ===========================================================================
setlocal
title AutoPowerPro

set "PS1=%~dp0AutoPowerPro.ps1"

if not exist "%PS1%" (
  echo.
  echo   [ERROR] AutoPowerPro.ps1 was not found in this folder:
  echo           %~dp0
  echo.
  echo   Keep all three files of this package together in one folder.
  echo.
  pause
  exit /b 1
)

echo.
echo   Starting AutoPowerPro ...
echo   If a UAC window pops up, click "Yes".
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
set "RC=%errorlevel%"

if not "%RC%"=="0" (
  echo.
  echo   [WARN] PowerShell exited with code %RC%.
  echo   If the window closed too fast, run this file as administrator
  echo   and read the message in the new window.
  echo.
  pause
)

endlocal
exit /b 0
