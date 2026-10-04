@echo off
rem Double-click launcher for steamcheck.ps1. An optional workshop id is passed through.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0steamcheck.ps1" %*
pause
