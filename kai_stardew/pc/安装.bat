@echo off
rem Kai Stardew - one-time setup. Runs setup_pc.ps1 next to this file.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_pc.ps1"
echo.
pause
