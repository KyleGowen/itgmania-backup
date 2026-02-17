@echo off
REM Launcher for ITGMania Backup installer. Double-click to run (no .ps1 association needed).
REM If config.json exists in this folder, it is used and copied to the install location.
if exist "%~dp0config.json" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-ITGManiaBackup.ps1" -ConfigPath "%~dp0config.json"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-ITGManiaBackup.ps1"
)
if errorlevel 1 pause
