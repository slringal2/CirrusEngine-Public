@echo off
setlocal
cd /d "%~dp0"
if exist "%~dp0CirrusEngine.exe" (
  start "CirrusEngine" "%~dp0CirrusEngine.exe" %*
  exit /b
)
if not exist "build\Release\CirrusEngine.exe" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "scripts\build.ps1"
  if errorlevel 1 exit /b 1
)
start "CirrusEngine" "build\Release\CirrusEngine.exe" %*
