#Requires -Version 5.1
<#
.SYNOPSIS
  Evaluates ScheduleCron from config and runs Backup-ITGMania.ps1 when the current time matches.
  Intended to be run every minute by Task Scheduler.
#>

$ProgramDataRoot = Join-Path $env:ProgramData "ITGManiaBackup"
$LocalAppDataRoot = Join-Path $env:LOCALAPPDATA "ITGManiaBackup"
if (Test-Path (Join-Path $ProgramDataRoot "config.json")) {
    $InstallRoot = $ProgramDataRoot
} elseif (Test-Path (Join-Path $LocalAppDataRoot "config.json")) {
    $InstallRoot = $LocalAppDataRoot
} else {
    exit 0
}
$ConfigPath = Join-Path $InstallRoot "config.json"
$BackupScript = Join-Path $InstallRoot "Backup-ITGMania.ps1"
if (-not (Test-Path $BackupScript)) { exit 0 }

$config = Get-Content -Raw $ConfigPath | ConvertFrom-Json
$cron = $config.ScheduleCron
if (-not $cron) { exit 0 }

$tzName = if ($config.ScheduleTimezone) { $config.ScheduleTimezone } else { "Pacific Standard Time" }
try {
    $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($tzName)
    $now = [System.TimeZoneInfo]::ConvertTimeFromUtc((Get-Date).ToUniversalTime(), $tz)
} catch {
    $now = Get-Date
}

$parts = $cron -split '\s+'
if ($parts.Count -lt 5) { exit 0 }
$minutePart = $parts[0]
$hourPart = $parts[1]
$dayPart = $parts[2]
$monthPart = $parts[3]
$dowPart = $parts[4]

function Test-CronPart {
    param([string]$Part, [int]$Value, [int]$Min, [int]$Max)
    if ($Part -eq '*') { return $true }
    if ($Part -match '^\d+$') { return [int]$Part -eq $Value }
    if ($Part -match '^\*/(\d+)$') {
        $step = [int]$Matches[1]
        return ($Value % $step) -eq 0
    }
    if ($Part -match '^(\d+)-(\d+)$') {
        $a = [int]$Matches[1]; $b = [int]$Matches[2]
        return $Value -ge $a -and $Value -le $b
    }
    return $false
}

$minuteMatch = Test-CronPart -Part $minutePart -Value $now.Minute -Min 0 -Max 59
$hourMatch   = Test-CronPart -Part $hourPart   -Value $now.Hour   -Min 0 -Max 23
$dayMatch    = Test-CronPart -Part $dayPart    -Value $now.Day    -Min 1 -Max 31
$monthMatch  = Test-CronPart -Part $monthPart  -Value $now.Month  -Min 1 -Max 12
# PowerShell: DayOfWeek Sunday=0, Monday=1, ... Saturday=6. Cron: 0 or 7 = Sunday, 1-6 = Mon-Sat.
$dow = [int]$now.DayOfWeek
$dowMatch = Test-CronPart -Part $dowPart -Value $dow -Min 0 -Max 7
if (-not $dowMatch -and $dow -eq 0 -and $dowPart -eq '7') { $dowMatch = $true }

if ($minuteMatch -and $hourMatch -and $dayMatch -and $monthMatch -and $dowMatch) {
    & $BackupScript -ConfigPath $ConfigPath
}
