@echo off
REM LanKvm - Windows receiver.
REM
REM Run as administrator once to configure this private LAN. It:
REM   1. uses the prebuilt LanKvm.exe, or compiles it from LanKvm.cs
REM   2. opens the firewall for ports 7681 and 7682
REM   Then run LanKvm from Explorer with ordinary user permissions.
REM
REM No installer, no .NET SDK, no PowerShell needed.

setlocal
set HERE=%~dp0
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe

echo.
echo   LanKvm - Windows receiver
echo   -------------------------
echo.

if exist "%HERE%LanKvm.exe" goto :firewall

echo   LanKvm.exe is missing - compiling it from source ...
if not exist "%CSC%" (
  echo.
  echo   Could not find the .NET Framework C# compiler on this PC.
  echo   Windows 10 and 11 include it by default.
  echo.
  pause
  exit /b 1
)

"%CSC%" /nologo /target:winexe /out:"%HERE%LanKvm.exe" ^
  /reference:System.Windows.Forms.dll ^
  /reference:System.Drawing.dll ^
  /reference:System.Web.Extensions.dll ^
  "%HERE%LanKvm.cs"

if errorlevel 1 (
  echo.
  echo   Compilation failed.
  echo.
  pause
  exit /b 1
)

:firewall
echo   Opening the firewall for ports 7681 and 7682 ...
netsh advfirewall firewall delete rule name="LanKvm" >nul 2>&1
netsh advfirewall firewall add rule name="LanKvm" dir=in action=allow protocol=TCP localport=7681,7682 profile=private remoteip=localsubnet >nul
if errorlevel 1 (
  echo Firewall rule was not installed. Run install.bat as administrator on your private LAN.
  pause
  exit /b 1
)

echo   Firewall configured for the local subnet on private networks.
echo   Close this window. Double-click run-lankvm.bat from Explorer to start LanKvm.
echo   The receiver window shows the address and pairing token.
pause
