@echo off
net session >nul 2>&1 || (echo Run as admin. & pause & exit /b 1)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
pause
