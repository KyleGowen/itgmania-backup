# ITGMania Backup

Backs up ITGMania install and save data to a GitHub repo on a configurable schedule (cron). **Songs are never backed up** (too large for GitHub). The repo that receives backups is **not** this repo—you configure a separate backup destination repo.

## Features

- **Packaged installer** – Double-click `Install-ITGManiaBackup.bat` to run the wizard (no need to associate .ps1 with PowerShell). Or run `Install-ITGManiaBackup.ps1` from PowerShell. No administrator required; uses a user-level scheduled task.
- **Scheduled backup** – Task runs every minute and evaluates your cron expression (default `*/10 * * * *` = every 10 min; e.g. `0 2 * * *` = 2am daily, `*/5 * * * 6` = every 5 minutes on Saturdays).
- **Run backup now** – Desktop shortcut runs a backup on demand.
- **Two save locations** – Backs up both `InstallPath\Save` (portable) and `%APPDATA%\ITGmania\Save` (AppData) when present, into `SavePortable/` and `SaveAppData/` in the backup repo.
- **File size** – Skips files over 100 MB (GitHub limit) and writes a report of skipped files to the log directory.
- **On failure** – Dismissible message box and log entry.

## Requirements

- Windows (PowerShell 5.1+)
- Git for Windows (installed and on PATH or in a standard location)
- A GitHub repo to use as the **backup destination** (not this code repo). Create one empty or with a README; the script will force-push.

## Quick start

1. **Run the installer**  
   Double-click **`Install-ITGManiaBackup.bat`** (Windows will run it as a script).  
   Or from PowerShell: `.\Install-ITGManiaBackup.ps1`
2. Enter your ITGMania install path (e.g. `C:\Games\ITGMania`), backup repo URL (e.g. `https://github.com/You/YourBackupRepo.git`), and a GitHub Personal Access Token with repo push permission.
3. Enter schedule (cron) and timezone, or accept defaults (every 10 min, Pacific).
4. Use the desktop shortcut **"ITGMania Backup Now"** to run a backup anytime, or wait for the scheduled run.

## Config

After install, config is at `%ProgramData%\ITGManiaBackup\config.json`. It contains your **access token**—do not commit or share this file. You can edit it to change paths, cron, or add tasks.

Example structure (see `config.example.json`):

- `InstallPath` – ITGMania install directory
- `BackupRepoUrl` – Backup destination repo (HTTPS)
- `BackupRepoAccessToken` – GitHub PAT for push
- `ScheduleCron` – 5-field cron (minute hour day month weekday)
- `ScheduleTimezone` – e.g. "Pacific Standard Time"
- `InstallDirSubdirs` – Whitelist from install (Themes, NoteSkins, Logs, etc.). **Songs are never included.**

## What gets backed up

- **From install path:** Themes, NoteSkins, BGAnimations, Characters, Courses, Logs (whitelist). Songs, Cache, Program, Downloads are excluded.
- **From Save (portable):** `InstallPath\Save` → `ITGMania/SavePortable/` when present.
- **From Save (AppData):** `%APPDATA%\ITGmania\Save` → `ITGMania/SaveAppData/` when present.
- Screenshots and Save/Upload are included. Cache under Save is excluded. Files over 100 MB are skipped and listed in a report.

## Logs and reports

- Logs: `%ProgramData%\ITGManiaBackup\Logs\` (rotated by date).
- Skipped-files report (over 100 MB): same folder, `SkippedFiles_*.txt`.

## Important

- **Never backup Songs** – They are excluded by design. Do not enable backup of Songs for GitHub.
- **Backup destination repo** – This code lives in one repo; your backup data goes to a different repo you configure.
- **Force-push** – Backup is unidirectional; the script always force-pushes so the backup state overwrites the remote. Previous commit history on the remote is kept for fallback.

## Packaging as .exe (optional)

To distribute a single .exe installer, use [ps2exe](https://github.com/MScholtes/PS2EXE) or similar to convert `Install-ITGManiaBackup.ps1`.
