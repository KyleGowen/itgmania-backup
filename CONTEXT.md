# ITGMania Backup – Project Context

This context is loaded automatically by Cursor via `.cursor/rules/project-context.mdc` (`alwaysApply: true`). Edit that rule file to update what the AI sees.

## Project overview

**ITGMania Backup** is a Windows PowerShell tool that backs up an ITGMania (StepMania) install and save data to a GitHub repo on a configurable schedule. Songs are never backed up (too large for GitHub). The backup destination repo is separate from this code repo and configured via `config.json`.

## Tech stack

- **PowerShell 5.1+**
- **Git for Windows**
- **Windows Task Scheduler** (cron)

## Key files

| File | Purpose |
|------|---------|
| `Backup-ITGMania.ps1` | Main backup script: clone, copy, commit, force-push |
| `Install-ITGManiaBackup.ps1` | Installer wizard; creates scheduled task and config |
| `Install-ITGManiaBackup.bat` | Launcher for installer (no PowerShell association needed) |
| `CronRunner.ps1` | Evaluates cron expression and runs backup when due |
| `config.json` | User config (gitignored); contains GitHub PAT |
| `config.example.json` | Example config structure |
| `BackupRepo.gitignore` | Applied to the cloned backup repo before commit |

## Directory structure

- **`repo/`** – Staging directory for the cloned backup repo (created during backup)
- **`Logs/`** – Backup logs (when run from script dir)
- **`backup-repo-clone/`** – Likely a local clone of the backup destination (not part of the backup flow)

## Important constraints

1. **Never backup Songs** – Excluded by design; do not enable for GitHub.
2. **Force-push** – Backup is unidirectional; remote is overwritten.
3. **100 MB limit** – Files over 100 MB are skipped and reported.
4. **Config contains secrets** – `BackupRepoAccessToken` must never be committed.

## Config resolution order

1. `-ConfigPath` (if provided)
2. `config.json` in script directory
3. `%ProgramData%\ITGManiaBackup\config.json`
4. `%LOCALAPPDATA%\ITGManiaBackup\config.json`

## What gets backed up

- **Install path (whitelist):** Themes, NoteSkins, BGAnimations, Characters, Courses, Logs
- **Save (portable):** `InstallPath\Save` → `SavePortable/`
- **Save (AppData):** `%APPDATA%\ITGmania\Save` → `SaveAppData/`

Excluded: Songs, Cache, Program, Downloads.

## Digest (score history)

Digest entries show new scores from Stats.xml diffs. Difficulty includes numeric meter when available (e.g. `Challenge (12)`). `Get-MeterFromSongChart` reads `.ssc`/`.sm` from the song folder at InstallPath; meter lookup only works when backup runs on the machine with the full install. For songs in `AdditionalSongs/`, paths from Preferences.ini `AdditionalSongFolders` and config `AdditionalSongFolderPaths` are also tried. When direct path fails, pack-song search fallback finds the folder by Pack/SongFolder name. The `.sm` parser supports both standard format (with description line) and compact format. `Repair-DigestMeters` adds meters to existing digest lines that lack them.

## 30-day meter tables

Per-player tables show songs played at each numeric level in the last 30 days. **Data flow:** Upload (all plays) → Stats.xml (top scores per chart) → Digests (new high scores only). `Get-MeterTallyFromUploadFolder` parses `Save/Upload/` XML files (one per play) for `HighScoreForASongAndSteps`, filters by `DateTime >= cutoff`, and counts ALL plays. Falls back to `Get-MeterTallyFromStatsXml` (Stats.xml) when Upload is empty; `Get-MeterTallyFromDigests` when both are empty.

## See also

- `.cursor/rules/digest-and-stats.mdc` – Detailed technical reference for digest, meter lookup, and Stats.xml parsing
- `Tests/Fixtures/README.md` – Test fixture structure and usage
