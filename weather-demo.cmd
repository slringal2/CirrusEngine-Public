@echo off
if exist "%~dp0CirrusEngine.exe" (
    start "CirrusEngine Weather" /D "%~dp0" "%~dp0CirrusEngine.exe" --weather-demo --quality medium %*
    exit /b
)
call "%~dp0start.cmd" --weather-demo --quality medium %*
