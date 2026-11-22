@echo off
REM LanKvm - build LanKvm.exe from source.
REM
REM Only needed when you change LanKvm.cs. The shipped package already contains
REM a compiled LanKvm.exe, so ordinary users never run this.

setlocal
set HERE=%~dp0
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe

if not exist "%CSC%" (
  echo Could not find the .NET Framework C# compiler.
  pause
  exit /b 1
)

"%CSC%" /nologo /target:winexe /out:"%HERE%LanKvm.exe" ^
  /reference:System.Windows.Forms.dll ^
  /reference:System.Drawing.dll ^
  /reference:System.Web.Extensions.dll ^
  "%HERE%LanKvm.cs"

if errorlevel 1 (
  echo Build failed.
  pause
  exit /b 1
)

echo Built: %HERE%LanKvm.exe
pause