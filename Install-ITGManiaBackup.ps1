#Requires -Version 5.1
<#
.SYNOPSIS
  Installs ITGMania Backup: wizard to configure, then deploys scripts and creates scheduled task + "Run backup now" shortcut.
.DESCRIPTION
  Prompts for install path, backup repo URL, access token, cron schedule, and timezone.
  Copies Backup-ITGMania.ps1, CronRunner.ps1, and BackupRepo.gitignore to the install root
  (ProgramData\ITGManiaBackup if writable, else %LOCALAPPDATA%\ITGManiaBackup).
  Creates a user-level scheduled task (CronRunner every minute) and a desktop shortcut for "Run backup now".
.NOTES
  No administrator required. The backup destination repo is separate from the repo containing this code. Do not commit config with real tokens.
#>

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- Resolve install root (no admin required) ---
$ProgramDataRoot = Join-Path $env:ProgramData "ITGManiaBackup"
$LocalAppDataRoot = Join-Path $env:LOCALAPPDATA "ITGManiaBackup"
try {
    if (-not (Test-Path $ProgramDataRoot)) {
        New-Item -ItemType Directory -Path $ProgramDataRoot -Force -ErrorAction Stop | Out-Null
    }
    $InstallRoot = $ProgramDataRoot
} catch {
    $InstallRoot = $LocalAppDataRoot
}

$TaskName = "ITGManiaBackup"
$ShortcutName = "ITGMania Backup Now.lnk"

# --- Wizard ---
Write-Host "=== ITGMania Backup Installer ===" -ForegroundColor Cyan
Write-Host "Install location: $InstallRoot`n" -ForegroundColor Gray

$installPath = Read-Host "ITGMania install path (default: C:\Games\ITGMania)"
if ([string]::IsNullOrWhiteSpace($installPath)) { $installPath = "C:\Games\ITGMania" }
$installPath = $installPath.TrimEnd('\')

$defaultRepoUrl = "https://github.com/KyleGowen/Thraximundar-Backup.git"
$backupRepoUrl = Read-Host "Backup destination repo URL (default: $defaultRepoUrl)"
if ([string]::IsNullOrWhiteSpace($backupRepoUrl)) { $backupRepoUrl = $defaultRepoUrl }
if (-not $backupRepoUrl.EndsWith(".git")) {
    $backupRepoUrl = $backupRepoUrl.TrimEnd('/') + ".git"
}

$token = Read-Host "GitHub access token (PAT) for push - will be stored in config" -AsSecureString
$tokenPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($token))

$scheduleCron = Read-Host "Schedule (cron 5-field, default: */10 * * * * = every 10 min)"
if ([string]::IsNullOrWhiteSpace($scheduleCron)) { $scheduleCron = "*/10 * * * *" }

$scheduleTz = Read-Host "Timezone (default: Pacific Standard Time)"
if ([string]::IsNullOrWhiteSpace($scheduleTz)) { $scheduleTz = "Pacific Standard Time" }

# --- Write config ---
$config = @{
    InstallPath           = $installPath
    SavePathPortable      = $null
    SavePathAppData       = $null
    BackupRepoUrl         = $backupRepoUrl
    BackupRepoAccessToken = $tokenPlain
    ScheduleCron          = $scheduleCron
    ScheduleTimezone      = $scheduleTz
    BackupSongs           = $false
    InstallDirSubdirs     = @("Themes", "NoteSkins", "BGAnimations", "Characters", "Courses", "Logs")
    Tasks                 = @(@{ Name = "ITGMania"; TargetSubpath = "ITGMania" })
}
$configJson = $config | ConvertTo-Json -Depth 4

New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
$configPath = Join-Path $InstallRoot "config.json"
Set-Content -Path $configPath -Value $configJson -Encoding UTF8
Write-Host "`nConfig written to $configPath" -ForegroundColor Green

# --- Copy scripts ---
$files = @("Backup-ITGMania.ps1", "CronRunner.ps1", "BackupRepo.gitignore")
foreach ($f in $files) {
    $src = Join-Path $ScriptDir $f
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination (Join-Path $InstallRoot $f) -Force
        Write-Host "Copied $f"
    } else {
        Write-Warning "Not found: $src"
    }
}

# --- Scheduled task (user-level: runs CronRunner every minute, no popup window) ---
$cronRunnerPath = Join-Path $InstallRoot "CronRunner.ps1"
$vbsPath = Join-Path $InstallRoot "RunCronRunner.vbs"
$vbsContent = @"
Set shell = CreateObject("WScript.Shell")
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$cronRunnerPath""", 0, False
"@
Set-Content -Path $vbsPath -Value $vbsContent -Encoding ASCII
Write-Host "Created RunCronRunner.vbs (hidden launcher)."
$action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "//B `"$vbsPath`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval ([TimeSpan]::FromMinutes(1)) -RepetitionDuration ([TimeSpan]::FromDays(3650))
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings | Out-Null
Write-Host "Scheduled task '$TaskName' created (every minute; user-level)." -ForegroundColor Green

# --- Desktop shortcut: Run backup now ---
$backupScriptPath = Join-Path $InstallRoot "Backup-ITGMania.ps1"
$desktop = [Environment]::GetFolderPath("Desktop")
$shortcutPath = Join-Path $desktop $ShortcutName
$wsh = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut($shortcutPath)
$shortcut.TargetPath = "powershell.exe"
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -File `"$backupScriptPath`""
$shortcut.WorkingDirectory = $InstallRoot
$shortcut.Description = "Run ITGMania backup now"
$shortcut.Save()
[Runtime.Interopservices.Marshal]::ReleaseComObject($wsh) | Out-Null
Write-Host "Shortcut '$ShortcutName' created on desktop." -ForegroundColor Green

# --- Optional: run first backup ---
$runNow = Read-Host "`nRun first backup now? (y/N)"
if ($runNow -eq 'y' -or $runNow -eq 'Y') {
    & $backupScriptPath -ConfigPath $configPath
}

Write-Host "`nInstallation complete." -ForegroundColor Cyan
Write-Host "Config (contains token) is at: $configPath" -ForegroundColor Yellow
Write-Host "Do not commit or share the config file." -ForegroundColor Yellow
