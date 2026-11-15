@echo off
setlocal
cd /d "%~dp0"
if not exist "build\Release\CirrusEngine.exe" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "scripts\build.ps1"
  if errorlevel 1 exit /b 1
)
start "CirrusEngine" "build\Release\CirrusEngine.exe" %*
