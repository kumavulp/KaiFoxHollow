@echo off
rem Kai Stardew gate. Close this window and Kai can no longer reach this computer.
chcp 65001 >nul
title Kai Stardew Gate
cd /d "%~dp0"
set PYTHONIOENCODING=utf-8
where py >nul 2>nul
if %errorlevel%==0 (py -3 kai_gate.py) else (python kai_gate.py)
pause
