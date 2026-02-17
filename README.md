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

Config is JSON. It contains your **BackupRepoAccessToken** (GitHub PAT)—do not commit or share the file. `config.json` is listed in `.gitignore`.

### Where config can live

| Style | Location | Used by |
|-------|----------|--------|
| **Script-level** | `config.json` in the **same folder** as `Backup-ITGMania.ps1` (e.g. `Desktop\ITGMania Backup\config.json`) | Backup script (when no `-ConfigPath` is passed). Installer copies it to the install root if found there. |
| **Install root** | `%ProgramData%\ITGManiaBackup\config.json` or `%LOCALAPPDATA%\ITGManiaBackup\config.json` | Backup script and scheduled task. This is where the installer writes config. |
| **Explicit path** | Any path you pass on the command line | Backup script only: `.\Backup-ITGMania.ps1 -ConfigPath "D:\MyConfigs\backup.json"` |

**Backup script resolution order** (when you don’t pass `-ConfigPath`):

1. `-ConfigPath` (if provided)
2. `config.json` in the backup script’s directory
3. `config.json` in ProgramData, then script dir, then LocalAppData

**Installer behavior:**

- If the installer finds `config.json` in the install root or in its own folder, it **does not prompt** for install path, repo URL, token, or schedule. It prefers the install root config when both exist so "Configuration in use" matches what the task and shortcut use. It shows **“Found config: &lt;path&gt;”**, prints the configuration in use (with **BackupRepoAccessToken** and any token/secret/password fields shown as `******`), then continues to copy scripts and create the task/shortcut.
- If no config is found, it runs the full wizard and writes `config.json` to the install root.

**Changing the schedule:** The scheduled task and shortcut read **only** the config in the install root (`%ProgramData%\ITGManiaBackup\config.json` or `%LOCALAPPDATA%\ITGManiaBackup\config.json`). To change `ScheduleCron` or `ScheduleTimezone`, edit that file and save. To push an updated schedule from the script folder, run the installer again with the updated `config.json` there (if install root has no config, the installer will copy it).

### Config structure

Copy `config.example.json` to `config.json` and fill in your paths and token. Required: `InstallPath`, `BackupRepoUrl`. Optional: `BackupRepoAccessToken` (for private repos or to avoid auth prompts).

| Key | Description |
|-----|-------------|
| `InstallPath` | ITGMania install directory (e.g. `C:\Games\ITGMania`) |
| `BackupRepoUrl` | Backup destination repo, HTTPS (e.g. `https://github.com/You/YourBackup.git`) |
| `BackupRepoAccessToken` | GitHub PAT with repo push permission. **Obscured when the installer displays config.** |
| `ScheduleCron` | 5-field cron: minute hour day-of-month month weekday (e.g. `0 2 * * *` = 2am daily) |
| `ScheduleTimezone` | e.g. `Pacific Standard Time` |
| `SavePathPortable`, `SavePathAppData` | Usually `null`; script derives save paths from `InstallPath` and `%APPDATA%` |
| `BackupSongs` | `false`; do not set to `true` for GitHub |
| `InstallDirSubdirs` | Whitelist from install: Themes, NoteSkins, BGAnimations, Characters, Courses, Logs. **Songs are never included.** |
| `Tasks` | List of `{ "Name": "ITGMania", "TargetSubpath": "ITGMania" }` for mapping into the backup repo |

Example (see `config.example.json`):

```json
{
  "InstallPath": "C:\\Games\\ITGMania",
  "BackupRepoUrl": "https://github.com/You/YourBackup.git",
  "BackupRepoAccessToken": "YOUR_GITHUB_PAT",
  "ScheduleCron": "0 2 * * *",
  "ScheduleTimezone": "Pacific Standard Time",
  "BackupSongs": false,
  "InstallDirSubdirs": ["Themes", "NoteSkins", "BGAnimations", "Characters", "Courses", "Logs"],
  "Tasks": [{ "Name": "ITGMania", "TargetSubpath": "ITGMania" }]
}
```

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
