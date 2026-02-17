@echo off
REM Launcher for ITGMania Backup installer. Double-click to run (no .ps1 association needed).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-ITGManiaBackup.ps1"
if errorlevel 1 pause
