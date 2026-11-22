@echo off
REM LanKvm - start the Windows receiver.
REM Double-click this file. No setup and no compiler needed.

setlocal
set HERE=%~dp0

if not exist "%HERE%LanKvm.exe" (
  echo.
  echo LanKvm.exe was not found next to this file.
  echo Run install.bat once to compile it, or re-download the package.
  echo.
  pause
  exit /b 1
)

start "" "%HERE%LanKvm.exe"
exit /b 0