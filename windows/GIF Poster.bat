@echo off
rem Double-click launcher for gifposter.ps1. Arguments are passed through.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gifposter.ps1" %*
if errorlevel 1 pause
