@echo off
cd /d "%~dp0"
if exist "%~dp0CirrusEngine.exe" (
    start "CirrusEngine Formations" /D "%~dp0" "%~dp0CirrusEngine.exe" --formation-file config/formations.clouds --camera formations --weather overcast %*
    exit /b
)
call "%~dp0start.cmd" --formation-file config/formations.clouds --camera formations --weather overcast %*
