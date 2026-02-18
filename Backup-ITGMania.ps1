#Requires -Version 5.1
<#
.SYNOPSIS
  Runs one ITGMania backup: clone backup repo into staging, copy selected paths, force-push. Never backs up Songs.
.DESCRIPTION
  Reads config from ProgramData\ITGManiaBackup\config.json (or script dir). Clones BackupRepoUrl into staging,
  copies Install path (whitelist) and both Save locations (SavePortable, SaveAppData) when present.
  Skips files over 100 MB and reports them. On push failure shows a dismissible toast and logs.
.NOTES
  Staging directory is removed after successful push. Config contains secrets; do not commit real tokens.
#>

param(
    [string]$ConfigPath = $null,
    [switch]$RepairDigests,
    [string]$DigestsPath = $null
)

$ErrorActionPreference = 'Stop'
$MaxFileSizeBytes = 100 * 1024 * 1024   # 100 MB (GitHub limit)

# Resolve install root (where config and scripts live): ProgramData or LocalAppData when installed without admin
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProgramDataRoot = Join-Path $env:ProgramData "ITGManiaBackup"
$LocalAppDataRoot = Join-Path $env:LOCALAPPDATA "ITGManiaBackup"
# If no -ConfigPath was passed, use config.json in the script directory if it exists
if (-not $ConfigPath) {
    $scriptLevelConfig = Join-Path $ScriptDir "config.json"
    if (Test-Path -LiteralPath $scriptLevelConfig) { $ConfigPath = $scriptLevelConfig }
}
if ($ConfigPath -and (Test-Path $ConfigPath)) {
    $InstallRoot = Split-Path -Parent $ConfigPath
} elseif (Test-Path (Join-Path $ProgramDataRoot "config.json")) {
    $InstallRoot = $ProgramDataRoot
} elseif (Test-Path (Join-Path $ScriptDir "config.json")) {
    $InstallRoot = $ScriptDir
} elseif (Test-Path (Join-Path $LocalAppDataRoot "config.json")) {
    $InstallRoot = $LocalAppDataRoot
} else {
    $InstallRoot = $ProgramDataRoot
}
$LogDir = Join-Path $InstallRoot "Logs"
$StagingDir = Join-Path $InstallRoot "repo"
$BackupRepoGitignoreName = "BackupRepo.gitignore"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    if ($null -eq $Message) { $Message = "" }
    $date = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logFile = Join-Path $LogDir ("Backup_{0:yyyy-MM-dd}.log" -f (Get-Date))
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $line = "$date [$Level] $Message"
    Add-Content -Path $logFile -Value $line
    if ($Level -eq "ERROR") { Write-Host $line -ForegroundColor Red } else { Write-Host $line }
}

function Get-GitExe {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) { return $git.Source }
    $paths = @(
        "$env:LOCALAPPDATA\Programs\Git\bin\git.exe",
        "C:\Program Files\Git\bin\git.exe"
    )
    foreach ($p in $paths) { if (Test-Path $p) { return $p } }
    throw "Git not found. Install Git for Windows and ensure it is on PATH or in a standard location."
}

function Get-Config {
    $path = $ConfigPath
    if (-not $path) {
        $path = Join-Path $InstallRoot "config.json"
    }
    if (-not (Test-Path $path)) { throw "Config not found at $path. Run the installer first or place config.json in script directory." }
    $json = Get-Content -Raw -Path $path
    $config = $json | ConvertFrom-Json
    if (-not $config.BackupRepoUrl) { throw "Config must contain BackupRepoUrl." }
    if (-not $config.InstallPath)   { throw "Config must contain InstallPath." }
    return $config
}

function Get-CloneUrlWithToken {
    param([string]$Url, [string]$Token)
    if (-not $Token) { return $Url }
    if ($Url -match '^https://([^@]+@)?([^/]+)/(.+)$') {
        return "https://${Token}@$($matches[2])/$($matches[3])"
    }
    if ($Url -match '^https://([^/]+)/(.+)$') {
        return "https://${Token}@$($matches[1])/$($matches[2])"
    }
    return $Url
}


function Copy-DirWithSizeFilter {
    param(
        [string]$SourceRoot,
        [string]$DestRoot,
        [string[]]$ExcludeDirs = @(),
        [scriptblock]$FileFilter = { $true }
    )
    $skipped = [System.Collections.ArrayList]::new()
    $sourceRootNorm = $SourceRoot.TrimEnd('\') + '\'
    Get-ChildItem -Path $SourceRoot -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = $_.FullName.Replace($sourceRootNorm, '').Replace('/', '\')
        $excluded = $ExcludeDirs | Where-Object { $rel -like "$_*" -or $rel -like "*\$_\*" }
        if ($excluded) { return }
        if (-not (& $FileFilter $_.FullName)) {
            [void]$skipped.Add($_.FullName)
            return
        }
        $destFile = Join-Path $DestRoot $rel
        $destParent = Split-Path -Parent $destFile
        if (-not (Test-Path $destParent)) { New-Item -ItemType Directory -Path $destParent -Force | Out-Null }
        Copy-Item -Path $_.FullName -Destination $destFile -Force
    }
    return @{ Skipped = $skipped }
}

function Get-SongsPackListMarkdown {
    param(
        [string]$RootPath,
        [string]$SectionTitle
    )
    if (-not (Test-Path $RootPath)) { return "*(folder not present)*" }
    $rootNorm = $RootPath.TrimEnd('\') + '\'
    $files = Get-ChildItem -Path $RootPath -Recurse -File -ErrorAction SilentlyContinue
    $tree = @{}
    foreach ($f in $files) {
        $rel = $f.FullName.Replace($rootNorm, '').Replace('/', '\')
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        $parts = $rel -split '\\'
        $current = $tree
        for ($i = 0; $i -lt $parts.Length - 1; $i++) {
            $dir = $parts[$i]
            if (-not $current.ContainsKey($dir)) { $current[$dir] = @{} }
            $current = $current[$dir]
        }
        $current[$parts[-1]] = $true
    }
    $lineList = [System.Collections.ArrayList]::new()
    function Add-TreeLines {
        param($node, [int]$indent, [System.Collections.ArrayList]$list)
        $prefix = (" " * $indent) + "- "
        $folderKeys = @($node.Keys | Where-Object { $node[$_] -is [hashtable] } | Sort-Object)
        $fileKeys = @($node.Keys | Where-Object { $node[$_] -eq $true } | Sort-Object)
        foreach ($k in $folderKeys) {
            [void]$list.Add("$prefix**$k**")
            Add-TreeLines -node $node[$k] -indent ($indent + 2) -list $list
        }
        foreach ($k in $fileKeys) {
            [void]$list.Add("$prefix$k")
        }
    }
    Add-TreeLines -node $tree -indent 0 -list $lineList
    return $lineList -join "`n"
}

function Test-CronPartMatch {
    param([string]$Part, [int]$Value, [int]$Min, [int]$Max)
    if ($Part -eq '*') { return $true }
    if ($Part -match '^\d+$') { return [int]$Part -eq $Value }
    if ($Part -match '^\*/(\d+)$') { $step = [int]$Matches[1]; return ($Value % $step) -eq 0 }
    if ($Part -match '^(\d+)-(\d+)$') { $a = [int]$Matches[1]; $b = [int]$Matches[2]; return $Value -ge $a -and $Value -le $b }
    return $false
}

function Get-NextCronRun {
    param([string]$Cron, [string]$Timezone)
    if ([string]::IsNullOrWhiteSpace($Cron)) { return $null }
    $parts = $Cron -split '\s+'
    if ($parts.Count -lt 5) { return $null }
    $tzName = if ([string]::IsNullOrWhiteSpace($Timezone)) { "Pacific Standard Time" } else { $Timezone }
    try {
        $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($tzName)
    } catch {
        return $null
    }
    $nowUtc = (Get-Date).ToUniversalTime()
    $nowInTz = [System.TimeZoneInfo]::ConvertTimeFromUtc($nowUtc, $tz)
    $maxMinutes = 8 * 24 * 60
    for ($m = 1; $m -le $maxMinutes; $m++) {
        $candidate = $nowInTz.AddMinutes($m)
        $minuteMatch = Test-CronPartMatch -Part $parts[0] -Value $candidate.Minute -Min 0 -Max 59
        $hourMatch = Test-CronPartMatch -Part $parts[1] -Value $candidate.Hour -Min 0 -Max 23
        $dayMatch = Test-CronPartMatch -Part $parts[2] -Value $candidate.Day -Min 1 -Max 31
        $monthMatch = Test-CronPartMatch -Part $parts[3] -Value $candidate.Month -Min 1 -Max 12
        $dow = [int]$candidate.DayOfWeek
        $dowMatch = Test-CronPartMatch -Part $parts[4] -Value $dow -Min 0 -Max 7
        if (-not $dowMatch -and $dow -eq 0 -and $parts[4] -eq '7') { $dowMatch = $true }
        if ($minuteMatch -and $hourMatch -and $dayMatch -and $monthMatch -and $dowMatch) {
            return $candidate
        }
    }
    return $null
}

function Get-SongDisplayNameFromDir {
    param([string]$SongDir)
    if ([string]::IsNullOrWhiteSpace($SongDir)) { return @{ SongTitle = ""; Pack = "" } }
    $trimmed = $SongDir.TrimEnd('/').TrimEnd('\')
    $parts = $trimmed -split '/' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($parts.Count -eq 0) { return @{ SongTitle = ""; Pack = "" } }
    $songTitle = $parts[-1]
    $pack = if ($parts.Count -gt 1) { $parts[-2] } else { "" }
    return @{ SongTitle = $songTitle; Pack = $pack }
}

function Get-NewScoreEntriesFromStatsDiff {
    param([string]$DiffText)
    $entries = [System.Collections.ArrayList]::new()
    if ([string]::IsNullOrWhiteSpace($DiffText)) { return @($entries) }
    $lines = $DiffText -split "`r?`n"
    $plusLines = @($lines | Where-Object { $_ -match '^\+' -and $_ -notmatch '^\+\+\+ ' })
    $contentLines = @($plusLines | ForEach-Object {
        $s = $_.ToString()
        if ($s.Length -gt 0 -and $s[0] -eq '+') { $s.Substring(1) } else { $s }
    })
    $i = 0
    while ($i -lt $contentLines.Count) {
        $line = $contentLines[$i]
        if ($line -match "^\s*<Song\s+Dir=(['\""])(.+?)\1\s*>") {
            $songDir = $matches[2]
            $display = Get-SongDisplayNameFromDir -SongDir $songDir
            $songTitle = $display.SongTitle
            $pack = $display.Pack
            $difficulty = ""
            $stepsType = ""
            $blockEnd = $i
            $inSong = $true
            $j = $i + 1
            while ($j -lt $contentLines.Count -and $inSong) {
                $cl = $contentLines[$j]
                if ($cl -match "^\s*</Song>\s*$") { $blockEnd = $j; $inSong = $false; $j++; break }
                if ($cl -match "^\s*<Steps\s+Difficulty=(['\""])([^'\""]+)\1\s+StepsType=(['\""])([^'\""]+)\3") {
                    $difficulty = $matches[2]
                    $stepsType = $matches[4]
                }
                if ($cl -match "^\s*<HighScore>\s*$") {
                    $hsStart = $j
                    $name = ""; $dateTime = ""; $percentDp = ""; $grade = ""
                    $j++
                    while ($j -lt $contentLines.Count) {
                        $hl = $contentLines[$j]
                        if ($hl -match "^\s*</HighScore>\s*$") { $j++; break }
                        if ($hl -match "^\s*<Name>([^<]*)</Name>\s*$") { $name = $matches[1].Trim() }
                        if ($hl -match "^\s*<DateTime>([^<]*)</DateTime>\s*$") { $dateTime = $matches[1].Trim() }
                        if ($hl -match "^\s*<PercentDP>([^<]*)</PercentDP>\s*$") { $percentDp = $matches[1].Trim() }
                        if ($hl -match "^\s*<Grade>([^<]*)</Grade>\s*$") { $grade = $matches[1].Trim() }
                        $j++
                    }
                    if (-not [string]::IsNullOrWhiteSpace($name) -or -not [string]::IsNullOrWhiteSpace($percentDp) -or -not [string]::IsNullOrWhiteSpace($dateTime)) {
                        $pctDisplay = ""
                        if (-not [string]::IsNullOrWhiteSpace($percentDp)) {
                            $pctNum = 0.0
                            if ([double]::TryParse($percentDp, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$pctNum)) {
                                $pctDisplay = ([math]::Round($pctNum * 100, 2)).ToString("0.00") + "% DP"
                            } else { $pctDisplay = $percentDp + " DP" }
                        }
                        $dateDisplay = ""
                        if (-not [string]::IsNullOrWhiteSpace($dateTime)) {
                            if ($dateTime -match '^(\d{4}-\d{2}-\d{2})') { $dateDisplay = " on " + $matches[1] }
                            else { $dateDisplay = " on " + $dateTime }
                        }
                        $packPart = if ([string]::IsNullOrWhiteSpace($pack)) { "" } else { " (" + $pack + ")" }
                        $nameDisplay = if ([string]::IsNullOrWhiteSpace($name)) { "Player" } else { $name }
                        $entry = "**" + [string]$nameDisplay + "**" + " set a new score for **" + [string]$songTitle + "**" + $packPart + " - " + [string]$difficulty + ", " + [string]$stepsType
                        if (-not [string]::IsNullOrWhiteSpace($pctDisplay)) { $entry += " - " + $pctDisplay }
                        $entry += $dateDisplay + "."
                        [void]$entries.Add($entry)
                    }
                    continue
                }
                $j++
            }
            $i = $blockEnd + 1
            continue
        }
        $i++
    }
    return @($entries)
}

function Format-SecondsToPlayTime {
    param([long]$Seconds)
    if ($Seconds -le 0) { return "0m 0s" }
    $h = [Math]::Floor($Seconds / 3600)
    $m = [Math]::Floor(($Seconds % 3600) / 60)
    $s = $Seconds % 60
    $parts = [System.Collections.ArrayList]::new()
    if ($h -gt 0) { [void]$parts.Add("$h" + "h") }
    [void]$parts.Add("$m" + "m")
    [void]$parts.Add("$s" + "s")
    return $parts -join " "
}

function Get-PlayTimeDeltaFromStatsDiff {
    param([string]$DiffText, [string]$RelPath)
    $result = [System.Collections.ArrayList]::new()
    if ([string]::IsNullOrWhiteSpace($DiffText)) { return @($result) }
    $lines = $DiffText -split "`r?`n"
    $oldSeconds = $null
    $newSeconds = $null
    foreach ($line in $lines) {
        if ($line -match '^-\s*<TotalGameplaySeconds>(\d+)</TotalGameplaySeconds>') { $oldSeconds = [long]$matches[1] }
        if ($line -match '^\+\s*<TotalGameplaySeconds>(\d+)</TotalGameplaySeconds>') { $newSeconds = [long]$matches[1] }
    }
    $delta = 0
    if ($null -ne $newSeconds -and $null -ne $oldSeconds) { $delta = $newSeconds - $oldSeconds }
    if ($delta -le 0) { return @($result) }
    $playerName = "Player"
    $plusLines = @($lines | Where-Object { $_ -match '^\+' -and $_ -notmatch '^\+\+\+ ' })
    foreach ($pl in $plusLines) {
        $content = if ($pl.Length -gt 0 -and $pl[0] -eq '+') { $pl.Substring(1) } else { $pl }
        if ($content -match "^\s*<Name>([^<]*)</Name>\s*$") {
            $playerName = $matches[1].Trim()
            if (-not [string]::IsNullOrWhiteSpace($playerName)) { break }
        }
    }
    if ([string]::IsNullOrWhiteSpace($playerName)) {
        if ($RelPath -match 'LocalProfiles[/\\]([^/\\]+)[/\\]') { $playerName = "Profile " + $matches[1] }
    }
    [void]$result.Add(@{ PlayerName = $playerName; DeltaSeconds = $delta })
    return @($result)
}

function Parse-PlayTimeLine {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    if ($Line -match 'Time in songs this run:\s*\*\*([^*]+)\*\*') {
        $playerName = $matches[1].Trim()
    } else { return $null }
    $rest = $Line -replace '^Time in songs this run:\s*\*\*[^*]+\*\*\s*', ''
    $h = 0; $m = 0; $s = 0
    if ($rest -match '(\d+)h') { $h = [int]$matches[1] }
    if ($rest -match '(\d+)m') { $m = [int]$matches[1] }
    if ($rest -match '(\d+)s') { $s = [int]$matches[1] }
    $seconds = $h * 3600 + $m * 60 + $s
    return @{ PlayerName = $playerName; Seconds = $seconds }
}

$Script:SongLikeExtensions = @('.ogg', '.mp3')

function Test-PackListLineIsSongFile {
    param([string]$FileName)
    if ([string]::IsNullOrWhiteSpace($FileName)) { return $false }
    $ext = [System.IO.Path]::GetExtension($FileName).ToLowerInvariant()
    return $Script:SongLikeExtensions -contains $ext
}

function Get-PackListDiffSummary {
    param([string]$DiffText)
    $added = @{}
    $removed = @{}
    if ([string]::IsNullOrWhiteSpace($DiffText)) { return @{ Added = $added; Removed = $removed } }
    $lines = $DiffText -split "`r?`n"
    $currentAddedPack = $null
    $currentRemovedPack = $null
    foreach ($line in $lines) {
        if ($line -match '^\+(.*)$' -and $line -notmatch '^\+\+\+') {
            $content = $matches[1]
            if ($content -match '^\s*$' -or $content -match '^# Pack list' -or $content -match '^## Songs' -or $content -match '^## AdditionalSongs' -or $content -match 'Generated from InstallPath on ') { continue }
            $indent = 0; if ($content -match '^(\s+)') { $indent = $matches[1].Length }
            $level = [Math]::Floor($indent / 2)
            if ($content -match '^\s*-\s+\*\*(.+)\*\*\s*$') {
                $name = $matches[1].Trim()
                if ($level -eq 0) {
                    $currentAddedPack = $name
                    if (-not $added.ContainsKey($currentAddedPack)) { $added[$currentAddedPack] = [System.Collections.ArrayList]::new() }
                } else {
                    $pack = $currentAddedPack; if ([string]::IsNullOrWhiteSpace($pack)) { $pack = "(root)" }
                    if (-not $added.ContainsKey($pack)) { $added[$pack] = [System.Collections.ArrayList]::new() }
                    if (-not $added[$pack].Contains($name)) { [void]$added[$pack].Add($name) }
                }
                continue
            }
        }
        if ($line -match '^-(.*)$' -and $line -notmatch '^--- ') {
            $content = $matches[1]
            if ($content -match '^\s*$' -or $content -match '^# Pack list' -or $content -match '^## Songs' -or $content -match '^## AdditionalSongs' -or $content -match 'Generated from InstallPath on ') { continue }
            $indent = 0; if ($content -match '^(\s+)') { $indent = $matches[1].Length }
            $level = [Math]::Floor($indent / 2)
            if ($content -match '^\s*-\s+\*\*(.+)\*\*\s*$') {
                $name = $matches[1].Trim()
                if ($level -eq 0) {
                    $currentRemovedPack = $name
                    if (-not $removed.ContainsKey($currentRemovedPack)) { $removed[$currentRemovedPack] = [System.Collections.ArrayList]::new() }
                } else {
                    $pack = $currentRemovedPack; if ([string]::IsNullOrWhiteSpace($pack)) { $pack = "(root)" }
                    if (-not $removed.ContainsKey($pack)) { $removed[$pack] = [System.Collections.ArrayList]::new() }
                    if (-not $removed[$pack].Contains($name)) { [void]$removed[$pack].Add($name) }
                }
                continue
            }
        }
    }
    return @{ Added = $added; Removed = $removed }
}

function Format-PackListDiffAsMarkdown {
    param($Summary)
    $added = $Summary.Added
    $removed = $Summary.Removed
    $out = [System.Collections.ArrayList]::new()
    [void]$out.Add("<details>")
    [void]$out.Add("<summary>Pack and song changes</summary>")
    [void]$out.Add("")
    [void]$out.Add("#### Pack and song changes")
    [void]$out.Add("")
    if ($added.Keys.Count -gt 0) {
        [void]$out.Add("**Added**")
        foreach ($pack in ($added.Keys | Sort-Object)) {
            [void]$out.Add("- **$pack**")
            foreach ($song in ($added[$pack] | Sort-Object)) {
                [void]$out.Add("-- $song")
            }
        }
        [void]$out.Add("")
    }
    if ($removed.Keys.Count -gt 0) {
        [void]$out.Add("**Removed**")
        foreach ($pack in ($removed.Keys | Sort-Object)) {
            [void]$out.Add("- **$pack**")
            foreach ($song in ($removed[$pack] | Sort-Object)) {
                [void]$out.Add("-- $song")
            }
        }
    }
    [void]$out.Add("")
    [void]$out.Add("</details>")
    return ($out -join "`n").TrimEnd()
}

function Format-PackListDiffAsCollapsibleMarkdown {
    param($AddedFinal, $RemovedFinal)
    $out = [System.Collections.ArrayList]::new()
    [void]$out.Add("<details>")
    [void]$out.Add("<summary><strong>Pack and song changes (last 30 days)</strong></summary>")
    [void]$out.Add("")
    if ($AddedFinal.Keys.Count -gt 0) {
        [void]$out.Add("**Added**")
        [void]$out.Add("")
        foreach ($pack in ($AddedFinal.Keys | Sort-Object)) {
            [void]$out.Add("<details>")
            [void]$out.Add("<summary>$($pack -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')</summary>")
            [void]$out.Add("")
            foreach ($song in ($AddedFinal[$pack] | Sort-Object)) {
                [void]$out.Add("-- $song")
            }
            [void]$out.Add("")
            [void]$out.Add("</details>")
            [void]$out.Add("")
        }
    }
    if ($RemovedFinal.Keys.Count -gt 0) {
        [void]$out.Add("**Removed**")
        [void]$out.Add("")
        foreach ($pack in ($RemovedFinal.Keys | Sort-Object)) {
            [void]$out.Add("<details>")
            [void]$out.Add("<summary>$($pack -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')</summary>")
            [void]$out.Add("")
            foreach ($song in ($RemovedFinal[$pack] | Sort-Object)) {
                [void]$out.Add("-- $song")
            }
            [void]$out.Add("")
            [void]$out.Add("</details>")
            [void]$out.Add("")
        }
    }
    [void]$out.Add("</details>")
    return ($out -join "`n").TrimEnd()
}

function Parse-DigestFilePackBlock {
    param([string]$DigestContent)
    $added = @{}
    $removed = @{}
    $lines = $DigestContent -split "`r?`n"
    $inBlock = $false
    $inAdded = $false
    $inRemoved = $false
    $currentPack = $null
    foreach ($line in $lines) {
        if ($line -match '^\s*#### Pack and song changes\s*$') { $inBlock = $true; $inAdded = $false; $inRemoved = $false; continue }
        if (-not $inBlock) { continue }
        if ($line -match '^\s*#### \d' -or $line -match '^\s*#### [A-Za-z]') {
            if ($line -notmatch 'Pack and song changes') { $inBlock = $false; break }
        }
        if ($line -match '^\s*\*\*Added\*\*' -or $line -match '<summary>\s*\*\*Added\*\*') { $inAdded = $true; $inRemoved = $false; $currentPack = $null; continue }
        if ($line -match '^\s*\*\*Removed\*\*' -or $line -match '<summary>\s*\*\*Removed\*\*') { $inRemoved = $true; $inAdded = $false; $currentPack = $null; continue }
        if ($line -match '^\s*</details>\s*$' -or $line -match '^\s*<details>' -or $line -match '^\s*<summary>') { continue }
        if ($line -match '^\s*-\s+(.+)\s+-\s+(\d+)\s+Song?s?\s*$') {
            $packName = $matches[1].Trim()
            $n = [int]$matches[2]
            if ($n -gt 0) {
                $list = [System.Collections.ArrayList]::new()
                for ($i = 0; $i -lt $n; $i++) { [void]$list.Add("$packName|$i") }
                if ($inAdded) { $added[$packName] = $list }
                if ($inRemoved) { $removed[$packName] = $list }
            }
            continue
        }
        if ($line -match '^\s*-\s+\*\*(.+)\*\*\s*$') {
            $packName = $matches[1].Trim()
            $currentPack = $packName
            if ($inAdded) { if (-not $added.ContainsKey($packName)) { $added[$packName] = [System.Collections.ArrayList]::new() } }
            if ($inRemoved) { if (-not $removed.ContainsKey($packName)) { $removed[$packName] = [System.Collections.ArrayList]::new() } }
            continue
        }
        if ($line -match '^\s*\*\*(.+)\*\*\s*$') {
            $packName = $matches[1].Trim()
            if ($packName -ne 'Added' -and $packName -ne 'Removed') {
                $currentPack = $packName
                if ($inAdded) { if (-not $added.ContainsKey($packName)) { $added[$packName] = [System.Collections.ArrayList]::new() } }
                if ($inRemoved) { if (-not $removed.ContainsKey($packName)) { $removed[$packName] = [System.Collections.ArrayList]::new() } }
            }
            continue
        }
        if ($line -match '^\s+-\s+(.+)$') {
            $songName = $matches[1].Trim()
            $pack = $currentPack; if ([string]::IsNullOrWhiteSpace($pack)) { $pack = "(root)" }
            if ($inAdded) { if (-not $added.ContainsKey($pack)) { $added[$pack] = [System.Collections.ArrayList]::new() }; if (-not $added[$pack].Contains($songName)) { [void]$added[$pack].Add($songName) } }
            if ($inRemoved) { if (-not $removed.ContainsKey($pack)) { $removed[$pack] = [System.Collections.ArrayList]::new() }; if (-not $removed[$pack].Contains($songName)) { [void]$removed[$pack].Add($songName) } }
            continue
        }
        if ($line -match '^\s*--\s+(.+)$') {
            $songName = $matches[1].Trim()
            $pack = $currentPack; if ([string]::IsNullOrWhiteSpace($pack)) { $pack = "(root)" }
            if ($inAdded) { if (-not $added.ContainsKey($pack)) { $added[$pack] = [System.Collections.ArrayList]::new() }; if (-not $added[$pack].Contains($songName)) { [void]$added[$pack].Add($songName) } }
            if ($inRemoved) { if (-not $removed.ContainsKey($pack)) { $removed[$pack] = [System.Collections.ArrayList]::new() }; if (-not $removed[$pack].Contains($songName)) { [void]$removed[$pack].Add($songName) } }
        }
    }
    return @{ Added = $added; Removed = $removed }
}

function Get-SongToPackMap {
    param([string]$InstallPath)
    $map = @{}
    if ([string]::IsNullOrWhiteSpace($InstallPath) -or -not (Test-Path $InstallPath)) { return $map }
    $songsRoot = Join-Path $InstallPath "Songs"
    $additionalRoot = Join-Path $InstallPath "AdditionalSongs"
    foreach ($root in @($songsRoot, $additionalRoot)) {
        if (-not (Test-Path $root)) { continue }
        $packs = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue
        foreach ($packDir in $packs) {
            $packName = $packDir.Name
            $songDirs = Get-ChildItem -Path $packDir.FullName -Directory -ErrorAction SilentlyContinue
            foreach ($songDir in $songDirs) {
                $map[$songDir.Name] = $packName
            }
        }
    }
    return $map
}

function Repair-DigestPackBlocks {
    param([string]$DigestsDir, [string]$InstallPath = $null)
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    $songToPack = $null
    if (-not [string]::IsNullOrWhiteSpace($InstallPath)) {
        $songToPack = Get-SongToPackMap -InstallPath $InstallPath
        if ($songToPack.Keys.Count -gt 0) {
            Write-Host "Using Songs at $InstallPath as source of truth ($($songToPack.Keys.Count) songs in map)."
        }
    }
    $files = @(Get-ChildItem -Path $DigestsDir -Filter "*.md" -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        $path = $f.FullName
        $content = [System.IO.File]::ReadAllText($path, $utf8NoBom)
        $lines = $content -split "`r?`n"
        $startIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*#### Pack and song changes\s*$') {
                $startIdx = $i
                for ($j = $i - 1; $j -ge 0; $j--) {
                    if ($lines[$j] -match '^\s*<details>\s*$') { $startIdx = $j; break }
                    if ($lines[$j] -match '^\s*<summary>' -or $lines[$j] -match '^\s*$') { continue }
                    break
                }
                break
            }
        }
        if ($startIdx -lt 0) { continue }
        $endIdx = $lines.Count - 1
        for ($i = $startIdx + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*####\s+' -and $lines[$i] -notmatch 'Pack and song changes') { $endIdx = $i - 1; break }
            if ($lines[$i] -match '^\s*</details>\s*$') { $endIdx = $i; break }
        }
        $blockLines = $lines[$startIdx..$endIdx]
        $blockContent = $blockLines -join "`n"
        $parsed = Parse-DigestFilePackBlock -DigestContent $blockContent
        if ($parsed.Added.Keys.Count -eq 0 -and $parsed.Removed.Keys.Count -eq 0) { continue }
        if ($null -ne $songToPack -and $songToPack.Keys.Count -gt 0) {
            $regroupedAdded = @{}
            foreach ($key in $parsed.Added.Keys) {
                $songs = $parsed.Added[$key]
                if ($songToPack.ContainsKey($key)) {
                    $pack = $songToPack[$key]
                    if (-not $regroupedAdded.ContainsKey($pack)) { $regroupedAdded[$pack] = [System.Collections.ArrayList]::new() }
                    if (-not $regroupedAdded[$pack].Contains($key)) { [void]$regroupedAdded[$pack].Add($key) }
                } else {
                    if (-not $regroupedAdded.ContainsKey($key)) { $regroupedAdded[$key] = [System.Collections.ArrayList]::new() }
                    foreach ($s in $songs) { if (-not $regroupedAdded[$key].Contains($s)) { [void]$regroupedAdded[$key].Add($s) } }
                }
            }
            $regroupedRemoved = @{}
            foreach ($key in $parsed.Removed.Keys) {
                $songs = $parsed.Removed[$key]
                if ($songToPack.ContainsKey($key)) {
                    $pack = $songToPack[$key]
                    if (-not $regroupedRemoved.ContainsKey($pack)) { $regroupedRemoved[$pack] = [System.Collections.ArrayList]::new() }
                    if (-not $regroupedRemoved[$pack].Contains($key)) { [void]$regroupedRemoved[$pack].Add($key) }
                } else {
                    if (-not $regroupedRemoved.ContainsKey($key)) { $regroupedRemoved[$key] = [System.Collections.ArrayList]::new() }
                    foreach ($s in $songs) { if (-not $regroupedRemoved[$key].Contains($s)) { [void]$regroupedRemoved[$key].Add($s) } }
                }
            }
            $parsed = @{ Added = $regroupedAdded; Removed = $regroupedRemoved }
        }
        $newBlock = Format-PackListDiffAsMarkdown -Summary $parsed
        $before = if ($startIdx -eq 0) { "" } else { ($lines[0..($startIdx - 1)] -join "`n") + "`n" }
        $after = if ($endIdx -ge $lines.Count - 1) { "" } else { "`n" + ($lines[($endIdx + 1)..($lines.Count - 1)] -join "`n") }
        $newContent = $before + $newBlock + $after
        [System.IO.File]::WriteAllText($path, $newContent, $utf8NoBom)
        Write-Host "Repaired: $($f.Name)"
    }
}

function Invoke-Backup {
    $config = Get-Config
    $gitExe = Get-GitExe
    $installPath = $config.InstallPath.TrimEnd('\')
    $savePortable = if ($config.SavePathPortable) { $config.SavePathPortable } else { Join-Path $installPath "Save" }
    $saveAppData  = if ($config.SavePathAppData)  { $config.SavePathAppData } else { Join-Path $env:APPDATA "ITGmania\Save" }
    $cloneUrl = Get-CloneUrlWithToken -Url $config.BackupRepoUrl -Token $config.BackupRepoAccessToken
    $installSubdirs = if ($config.InstallDirSubdirs) { $config.InstallDirSubdirs } else { @("Themes", "NoteSkins", "BGAnimations", "Characters", "Courses", "Logs") }
    $targetSubpath = "ITGMania"
    if ($config.Tasks -and $config.Tasks.Count -gt 0 -and $config.Tasks[0].TargetSubpath) {
        $targetSubpath = $config.Tasks[0].TargetSubpath
    }

    # Never include Songs
    $excludeDirs = @("Songs", "AdditionalSongs", "Cache", "Program", "Downloads")
    if (-not $config.BackupSongs) {
        $excludeDirs += "Songs", "AdditionalSongs"
    }

    Write-Log "Starting backup. InstallPath=$installPath"

    if (Test-Path $StagingDir) {
        Write-Log "Removing existing staging directory..."
        $stagingToRemove = $StagingDir.TrimEnd('\')
        Remove-Item -LiteralPath $stagingToRemove -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $stagingToRemove) {
            cmd /c "rmdir /s /q `"$stagingToRemove`""
        }
        if (Test-Path -LiteralPath $stagingToRemove) {
            Write-Log "Standard delete failed. Using robocopy mirror to clear staging dir." -Level INFO
            $emptyDir = Join-Path $env:TEMP "ITGManiaBackupEmpty_$(Get-Random)"
            New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
            try {
                $null = & robocopy $emptyDir $stagingToRemove /mir /r:2 /w:2 /nfl /ndl /njh /njs 2>&1
                Start-Sleep -Seconds 1
                Remove-Item -LiteralPath $stagingToRemove -Recurse -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $stagingToRemove) {
                    cmd /c "rmdir /s /q `"$stagingToRemove`""
                }
                if (Test-Path -LiteralPath $stagingToRemove) {
                    Start-Sleep -Seconds 2
                    $null = & robocopy $emptyDir $stagingToRemove /mir /r:2 /w:2 /nfl /ndl /njh /njs 2>&1
                    cmd /c "rmdir /s /q `"$stagingToRemove`""
                }
            } finally {
                if (Test-Path $emptyDir) { Remove-Item -Path $emptyDir -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
        if (Test-Path -LiteralPath $stagingToRemove) {
            throw "Could not remove staging directory (e.g. junction/symlink inside). Manually delete: $StagingDir"
        }
    }
    New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null

    try {
        # Clone (depth 1). If repo is empty (no commits), clone fails; then init and add remote.
        Write-Log "Cloning backup repo..."
        # Use Continue so git's stderr (progress lines) never triggers terminating error.
        $prevErrPref = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $out = & $gitExe clone --depth 1 $cloneUrl $StagingDir 2>&1
            foreach ($line in $out) { $m = if ($null -eq $line) { "" } else { try { "$line" } catch { "(output)" } }; Write-Log $m }
        } finally {
            $ErrorActionPreference = $prevErrPref
        }
        if ($LASTEXITCODE -ne 0) {
            $stagingToRemove = $StagingDir.TrimEnd('\')
            Remove-Item -LiteralPath $stagingToRemove -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $stagingToRemove) {
                cmd /c "rmdir /s /q `"$stagingToRemove`""
            }
            if (Test-Path -LiteralPath $stagingToRemove) {
                $emptyDir = Join-Path $env:TEMP "ITGManiaBackupEmpty_$(Get-Random)"
                New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
                try {
                    $null = & robocopy $emptyDir $stagingToRemove /mir /r:2 /w:2 /nfl /ndl /njh /njs 2>&1
                    Start-Sleep -Seconds 1
                    Remove-Item -LiteralPath $stagingToRemove -Recurse -Force -ErrorAction SilentlyContinue
                    if (Test-Path -LiteralPath $stagingToRemove) { cmd /c "rmdir /s /q `"$stagingToRemove`"" }
                } finally {
                    if (Test-Path $emptyDir) { Remove-Item -Path $emptyDir -Recurse -Force -ErrorAction SilentlyContinue }
                }
            }
            New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null
            Push-Location $StagingDir
            try {
                $ErrorActionPreference = 'Continue'
                $out2 = & $gitExe init 2>&1
                foreach ($line in $out2) { $m = if ($null -eq $line) { "" } else { try { "$line" } catch { "(output)" } }; Write-Log $m }
                $out3 = & $gitExe remote add origin $cloneUrl 2>&1
                foreach ($line in $out3) { $m = if ($null -eq $line) { "" } else { try { "$line" } catch { "(output)" } }; Write-Log $m }
            } finally {
                $ErrorActionPreference = $prevErrPref
                Pop-Location
            }
        }

        # Copy BackupRepo.gitignore into staging as .gitignore
        $gitignoreSrc = Join-Path $InstallRoot $BackupRepoGitignoreName
        if (Test-Path $gitignoreSrc) {
            Copy-Item -Path $gitignoreSrc -Destination (Join-Path $StagingDir ".gitignore") -Force
        }

        $allSkipped = [System.Collections.ArrayList]::new()
        $fileFilter = { param($fp) (Get-Item $fp).Length -le $MaxFileSizeBytes }

        # Install dir (whitelist subdirs only)
        $installDest = Join-Path (Join-Path $StagingDir $targetSubpath) "Install"
        foreach ($sub in $installSubdirs) {
            $src = Join-Path $installPath $sub
            if (-not (Test-Path $src)) { continue }
            $dest = Join-Path $installDest $sub
            if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
            $result = Copy-DirWithSizeFilter -SourceRoot $src -DestRoot $dest -ExcludeDirs $excludeDirs -FileFilter $fileFilter
            $result.Skipped | ForEach-Object { [void]$allSkipped.Add($_) }
        }

        # SavePortable
        if (Test-Path $savePortable) {
            $dest = Join-Path (Join-Path $StagingDir $targetSubpath) "SavePortable"
            $result = Copy-DirWithSizeFilter -SourceRoot $savePortable -DestRoot $dest -ExcludeDirs @("Songs", "Cache") -FileFilter $fileFilter
            $result.Skipped | ForEach-Object { [void]$allSkipped.Add($_) }
        }

        # SaveAppData
        if (Test-Path $saveAppData) {
            $dest = Join-Path (Join-Path $StagingDir $targetSubpath) "SaveAppData"
            $result = Copy-DirWithSizeFilter -SourceRoot $saveAppData -DestRoot $dest -ExcludeDirs @("Songs", "Cache") -FileFilter $fileFilter
            $result.Skipped | ForEach-Object { [void]$allSkipped.Add($_) }
        }

        # PACK_LIST.md under ITGMania: markdown tree of Songs (and AdditionalSongs), filenames only
        $songsRoot = Join-Path $installPath "Songs"
        $additionalSongsRoot = Join-Path $installPath "AdditionalSongs"
        $packListPath = Join-Path (Join-Path $StagingDir $targetSubpath) "PACK_LIST.md"
        $packListDir = Split-Path -Parent $packListPath
        if (-not (Test-Path $packListDir)) { New-Item -ItemType Directory -Path $packListDir -Force | Out-Null }
        $packListLines = @(
            "# Pack list",
            "",
            "Generated from InstallPath on $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Filenames only; contents not backed up.",
            ""
        )
        if ((Test-Path $songsRoot) -or (Test-Path $additionalSongsRoot)) {
            if (Test-Path $songsRoot) {
                $packListLines += "## Songs"
                $packListLines += ""
                $packListLines += (Get-SongsPackListMarkdown -RootPath $songsRoot -SectionTitle "Songs") -split "`n"
                $packListLines += ""
            } else {
                $packListLines += "## Songs"
                $packListLines += ""
                $packListLines += "*(folder not present)*"
                $packListLines += ""
            }
            if (Test-Path $additionalSongsRoot) {
                $packListLines += "## AdditionalSongs"
                $packListLines += ""
                $packListLines += (Get-SongsPackListMarkdown -RootPath $additionalSongsRoot -SectionTitle "AdditionalSongs") -split "`n"
                $packListLines += ""
            } else {
                $packListLines += "## AdditionalSongs"
                $packListLines += ""
                $packListLines += "*(folder not present)*"
                $packListLines += ""
            }
        } else {
            $packListLines += "No Songs or AdditionalSongs folders found."
        }
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllLines($packListPath, $packListLines, $utf8NoBom)
        Write-Log "Wrote PACK_LIST.md"

        if ($allSkipped.Count -gt 0) {
            $reportPath = Join-Path $LogDir ("SkippedFiles_{0:yyyy-MM-dd_HH-mm-ss}.txt" -f (Get-Date))
            $allSkipped | Set-Content -Path $reportPath
            Write-Log "Skipped $($allSkipped.Count) file(s) over 100 MB. Report: $reportPath"
        }

        # Git add, commit, push --force
        Push-Location $StagingDir
        try {
            & $gitExe config user.email "itgmania-backup@local"
            & $gitExe config user.name "ITGMania Backup"
            & $gitExe config core.autocrlf true
            & $gitExe config core.longpaths true
            $ErrorActionPreference = 'Continue'
            $addOut = & $gitExe add -A 2>&1
            $crlfWarnCount = 0
            foreach ($line in $addOut) {
                $m = if ($null -eq $line) { "" } else { try { [string]$line } catch { "(output)" } }
                if ($m -match 'LF will be replaced by CRLF') { $crlfWarnCount++ } else { Write-Log $m }
            }
            if ($crlfWarnCount -gt 0) { Write-Log "Git normalized line endings for $crlfWarnCount file(s)." }
            if ($LASTEXITCODE -ne 0) {
                Write-Log "git add -A failed (e.g. missing file or path too long). Retrying with add . only." -Level INFO
                Set-Location -LiteralPath $StagingDir
                $null = & $gitExe reset HEAD 2>&1
                $addOut2 = & $gitExe add . 2>&1
                foreach ($line in $addOut2) {
                    $m = if ($null -eq $line) { "" } else { try { [string]$line } catch { "" } }
                    if ([string]::IsNullOrEmpty($m) -or $m -match 'LF will be replaced by CRLF') { continue }
                    Write-Log $m
                }
                if ($LASTEXITCODE -ne 0) { throw "Git add failed. Check log for path or permission errors." }
            }

            # README.md at repo root: timestamp + per-file diff with explanations
            $hasHead = $false
            $revOut = & $gitExe rev-parse HEAD 2>&1
            if ($LASTEXITCODE -eq 0) { $hasHead = $true }
            $nameOnlyOut = if ($hasHead) { & $gitExe diff --cached --name-only HEAD 2>&1 } else { & $gitExe diff --cached --name-only 2>&1 }
            $changedFiles = @()
            if ($null -ne $nameOnlyOut) {
                $changedFiles = @($nameOnlyOut | ForEach-Object { $x = ""; if ($null -ne $_) { try { $x = [string]$_.Trim() } catch { } }; $x } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            }
            # Predefined path pattern -> explanation (first match wins; order matters)
            $fileExplanationPairs = @(
                @('*Preferences.ini', 'Game preferences (theme, options, etc.).'),
                @('*MachineProfile*', 'Machine-level profile and stats.'),
                @('*LocalProfiles*Stats.xml', 'Per-profile stats and score history.'),
                @('*LocalProfiles*', 'Per-profile save data.'),
                @('*SL-Scores*', 'Simply Love score exports (JSON).'),
                @('*Screenshots*', 'Game screenshots.'),
                @('*Upload*', 'Replay/upload queue.'),
                @('*Themes*', 'Theme files.'),
                @('*NoteSkins*', 'Note skin assets.'),
                @('*Logs*', 'Log files.'),
                @('*PACK_LIST.md', 'Manifest of Songs folder structure (filenames only).'),
                @('README.md', 'This file; backup timestamp and change summary.')
            )
            $defaultExplanation = 'Backed up file.'
            $readmePath = Join-Path $StagingDir "README.md"
            $backupDateTime = Get-Date
            $backupTimeDisplay = $backupDateTime.ToString("MMM d, yyyy 'at' h:mm tt")
            if ([string]::IsNullOrWhiteSpace($backupTimeDisplay)) { $backupTimeDisplay = "unknown" }
            $nextRun = Get-NextCronRun -Cron $config.ScheduleCron -Timezone $config.ScheduleTimezone
            $nextBackupDisplay = if ($nextRun) { $nextRun.ToString("MMM d, yyyy 'at' h:mm tt") } else { "unknown" }
            # Collect digest entries and play-time deltas from LocalProfiles Stats.xml diffs
            $digestEntries = [System.Collections.ArrayList]::new()
            $playTimeDeltas = [System.Collections.ArrayList]::new()
            $statsXmlFiles = @($changedFiles | Where-Object { $_ -like '*LocalProfiles*Stats.xml' })
            foreach ($relPath in $statsXmlFiles) {
                $perFileDiffOut = if ($hasHead) { & $gitExe diff --cached HEAD -- $relPath 2>&1 } else { & $gitExe diff --cached -- $relPath 2>&1 }
                $perFileDiffParts = [System.Collections.ArrayList]::new()
                if ($null -ne $perFileDiffOut) { foreach ($o in $perFileDiffOut) { $t = ""; if ($null -ne $o) { try { $t = [string]$o } catch { } }; if ($null -eq $t) { $t = "" }; [void]$perFileDiffParts.Add($t) } }
                $perFileDiffText = ($perFileDiffParts | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) -join "`n"
                $entries = Get-NewScoreEntriesFromStatsDiff -DiffText $perFileDiffText
                foreach ($e in $entries) { [void]$digestEntries.Add($e) }
                $deltas = Get-PlayTimeDeltaFromStatsDiff -DiffText $perFileDiffText -RelPath $relPath
                foreach ($d in $deltas) { [void]$playTimeDeltas.Add($d) }
            }
            $packListDigestBlock = ""
            $packListPath = $changedFiles | Where-Object { $_ -like '*PACK_LIST.md' } | Select-Object -First 1
            if ($packListPath) {
                $packDiffOut = if ($hasHead) { & $gitExe diff --cached HEAD -- $packListPath 2>&1 } else { & $gitExe diff --cached -- $packListPath 2>&1 }
                $packDiffParts = [System.Collections.ArrayList]::new()
                if ($null -ne $packDiffOut) { foreach ($o in $packDiffOut) { $t = ""; if ($null -ne $o) { try { $t = [string]$o } catch { } }; if ($null -eq $t) { $t = "" }; [void]$packDiffParts.Add($t) } }
                $packDiffText = ($packDiffParts | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) -join "`n"
                $packSkipDateOnly = $false
                if (-not [string]::IsNullOrWhiteSpace($packDiffText) -and $packDiffText -ne "(no diff)") {
                    $packDiffLines = ($packDiffText -split "`r?`n")
                    $packMinusLines = @($packDiffLines | Where-Object { $_ -match '^-' -and $_ -notmatch '^--- ' })
                    $packPlusLines = @($packDiffLines | Where-Object { $_ -match '^\+' -and $_ -notmatch '^\+\+\+ ' })
                    $packOnlyDateMinus = ($packMinusLines.Count -eq 1) -and ($packMinusLines[0] -match 'Generated from InstallPath on .+\.')
                    $packOnlyDatePlus = ($packPlusLines.Count -eq 1) -and ($packPlusLines[0] -match 'Generated from InstallPath on .+\.')
                    if ($packOnlyDateMinus -and $packOnlyDatePlus) { $packSkipDateOnly = $true }
                }
                if (-not $packSkipDateOnly -and -not [string]::IsNullOrWhiteSpace($packDiffText)) {
                    $packSummary = Get-PackListDiffSummary -DiffText $packDiffText
                    if (($packSummary.Added.Keys.Count -gt 0) -or ($packSummary.Removed.Keys.Count -gt 0)) {
                        $packListDigestBlock = Format-PackListDiffAsMarkdown -Summary $packSummary
                    }
                }
            }
            # Write this run's digest file to digests/ only when there's something to report
            $digestsDir = Join-Path $StagingDir "digests"
            $utf8WithBom = New-Object System.Text.UTF8Encoding $true
            $hasDigestContent = ($digestEntries.Count -gt 0) -or ($playTimeDeltas.Count -gt 0) -or ($packListDigestBlock -ne "")
            if ($hasDigestContent) {
                if (-not (Test-Path $digestsDir)) { New-Item -ItemType Directory -Path $digestsDir -Force | Out-Null }
                $digestFileName = $backupDateTime.ToString("yyyy-MM-dd_HH-mm") + ".md"
                $digestFilePath = Join-Path $digestsDir $digestFileName
                $digestContent = "#### " + [string]$backupTimeDisplay + "`n`n"
                if ($playTimeDeltas.Count -gt 0) {
                    foreach ($pt in $playTimeDeltas) {
                        $digestContent += "Time in songs this run: **" + [string]$pt.PlayerName + "** " + (Format-SecondsToPlayTime -Seconds $pt.DeltaSeconds) + ".`n"
                    }
                    $digestContent += "`n"
                }
                if ($digestEntries.Count -gt 0) {
                    foreach ($e in $digestEntries) { $digestContent += "- " + [string]$e + "`n" }
                }
                if ($packListDigestBlock -ne "") {
                    $digestContent += $packListDigestBlock + "`n`n"
                }
                [System.IO.File]::WriteAllText($digestFilePath, $digestContent, $utf8WithBom)
                # Prune digests to 30 files (delete and git rm oldest)
                $allDigests = @(Get-ChildItem -Path $digestsDir -Filter "*.md" -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
                if ($allDigests.Count -gt 30) {
                    $toRemove = $allDigests[30..($allDigests.Count - 1)]
                    foreach ($f in $toRemove) {
                        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                        $relPath = "digests\" + $f.Name
                        & $gitExe rm --cached --ignore-unmatch $relPath 2>&1 | Out-Null
                    }
                }
            }
            if (Test-Path $digestsDir) {
                Repair-DigestPackBlocks -DigestsDir $digestsDir -InstallPath $installPath
            }
            $fence = '```'
            if ([string]::IsNullOrEmpty([string]$fence)) { $fence = '```' }
            $readmeLines = New-Object System.Collections.ArrayList
            if ($null -eq $readmeLines) { $readmeLines = [System.Collections.ArrayList]::new() }
            [void]$readmeLines.Add("# ITGMania Backup")
            [void]$readmeLines.Add("")
            [void]$readmeLines.Add("#### Last backup: " + [string]$backupTimeDisplay)
            [void]$readmeLines.Add("")
            [void]$readmeLines.Add("#### Next backup: " + [string]$nextBackupDisplay)
            [void]$readmeLines.Add("")
            [void]$readmeLines.Add("## 30-day digest")
            [void]$readmeLines.Add("")
            $digestFilesForReadme = @(Get-ChildItem -Path $digestsDir -Filter "*.md" -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
            if ($digestFilesForReadme.Count -eq 0) {
                [void]$readmeLines.Add("No digest history yet.")
            } else {
                $take = [Math]::Min(30, $digestFilesForReadme.Count)
                $thirtyDayPlayTime = @{}
                for ($idx = 0; $idx -lt $take; $idx++) {
                    $df = $digestFilesForReadme[$idx]
                    $dc = [System.IO.File]::ReadAllText($df.FullName, [System.Text.Encoding]::UTF8).TrimEnd()
                    foreach ($dl in ($dc -split "`r?`n")) {
                        $parsed = Parse-PlayTimeLine -Line $dl
                        if ($null -ne $parsed) {
                            $pn = $parsed.PlayerName
                            if (-not $thirtyDayPlayTime.ContainsKey($pn)) { $thirtyDayPlayTime[$pn] = 0 }
                            $thirtyDayPlayTime[$pn] += $parsed.Seconds
                        }
                    }
                }
                if ($thirtyDayPlayTime.Count -gt 0) {
                    [void]$readmeLines.Add("### 30-day play time (in songs)")
                    [void]$readmeLines.Add("")
                    foreach ($pn in ($thirtyDayPlayTime.Keys | Sort-Object)) {
                        [void]$readmeLines.Add("- **" + $pn + "** " + (Format-SecondsToPlayTime -Seconds $thirtyDayPlayTime[$pn]))
                    }
                    [void]$readmeLines.Add("")
                }
                for ($idx = 0; $idx -lt $take; $idx++) {
                    $df = $digestFilesForReadme[$idx]
                    $dc = [System.IO.File]::ReadAllText($df.FullName, [System.Text.Encoding]::UTF8).TrimEnd()
                    foreach ($dl in ($dc -split "`r?`n")) { [void]$readmeLines.Add($dl) }
                    [void]$readmeLines.Add("")
                }
                # Merge pack/song changes from last 30 digest files for summary (last item in 30-day digest)
                $mergedAdded = @{}
                $mergedRemoved = @{}
                for ($idx = 0; $idx -lt $take; $idx++) {
                    $df = $digestFilesForReadme[$idx]
                    $dc = [System.IO.File]::ReadAllText($df.FullName, [System.Text.Encoding]::UTF8).TrimEnd()
                    $parsed = Parse-DigestFilePackBlock -DigestContent $dc
                    foreach ($pack in $parsed.Added.Keys) {
                        if (-not $mergedAdded.ContainsKey($pack)) { $mergedAdded[$pack] = [System.Collections.ArrayList]::new() }
                        foreach ($s in $parsed.Added[$pack]) { if (-not $mergedAdded[$pack].Contains($s)) { [void]$mergedAdded[$pack].Add($s) } }
                    }
                    foreach ($pack in $parsed.Removed.Keys) {
                        if (-not $mergedRemoved.ContainsKey($pack)) { $mergedRemoved[$pack] = [System.Collections.ArrayList]::new() }
                        foreach ($s in $parsed.Removed[$pack]) { if (-not $mergedRemoved[$pack].Contains($s)) { [void]$mergedRemoved[$pack].Add($s) } }
                    }
                }
                $addedSet = @{}
                foreach ($pack in $mergedAdded.Keys) { foreach ($s in $mergedAdded[$pack]) { $addedSet["$pack|$s"] = $true } }
                $removedSet = @{}
                foreach ($pack in $mergedRemoved.Keys) { foreach ($s in $mergedRemoved[$pack]) { $removedSet["$pack|$s"] = $true } }
                $addedFinal = @{}
                foreach ($pack in $mergedAdded.Keys) {
                    $list = [System.Collections.ArrayList]::new()
                    foreach ($s in $mergedAdded[$pack]) { if (-not $removedSet.ContainsKey("$pack|$s")) { [void]$list.Add($s) } }
                    if ($list.Count -gt 0) { $addedFinal[$pack] = $list }
                }
                $removedFinal = @{}
                foreach ($pack in $mergedRemoved.Keys) {
                    $list = [System.Collections.ArrayList]::new()
                    foreach ($s in $mergedRemoved[$pack]) { if (-not $addedSet.ContainsKey("$pack|$s")) { [void]$list.Add($s) } }
                    if ($list.Count -gt 0) { $removedFinal[$pack] = $list }
                }
                if ($addedFinal.Keys.Count -gt 0 -or $removedFinal.Keys.Count -gt 0) {
                    $collapsibleBlock = Format-PackListDiffAsCollapsibleMarkdown -AddedFinal $addedFinal -RemovedFinal $removedFinal
                    foreach ($cl in ($collapsibleBlock -split "`r?`n")) { [void]$readmeLines.Add($cl) }
                    [void]$readmeLines.Add("")
                }
            }
            [void]$readmeLines.Add("## Changes since last backup")
            [void]$readmeLines.Add("")
            if ($changedFiles.Count -eq 0) {
                [void]$readmeLines.Add("No file changes since last backup.")
            } else {
                foreach ($relPath in $changedFiles) {
                    $perFileDiffOut = if ($hasHead) { & $gitExe diff --cached HEAD -- $relPath 2>&1 } else { & $gitExe diff --cached -- $relPath 2>&1 }
                    $perFileDiffParts = [System.Collections.ArrayList]::new()
                    if ($null -ne $perFileDiffOut) { foreach ($o in $perFileDiffOut) { $t = ""; if ($null -ne $o) { try { $t = [string]$o } catch { } }; if ($null -eq $t) { $t = "" }; [void]$perFileDiffParts.Add($t) } }
                    $perFileDiffText = ($perFileDiffParts | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) -join "`n"
                    if ([string]::IsNullOrWhiteSpace($perFileDiffText)) { $perFileDiffText = "(no diff)" }
                    # Omit PACK_LIST.md entirely when the only change is the "Generated from InstallPath on DATE" line
                    $skipEntireSection = $false
                    if ($relPath -like '*PACK_LIST.md' -and -not [string]::IsNullOrWhiteSpace($perFileDiffText) -and $perFileDiffText -ne "(no diff)") {
                        $diffLines = ($perFileDiffText -split "`r?`n")
                        $minusLines = @($diffLines | Where-Object { $_ -match '^-' -and $_ -notmatch '^--- ' })
                        $plusLines = @($diffLines | Where-Object { $_ -match '^\+' -and $_ -notmatch '^\+\+\+ ' })
                        $onlyDateMinus = ($minusLines.Count -eq 1) -and ($minusLines[0] -match 'Generated from InstallPath on .+\.')
                        $onlyDatePlus = ($plusLines.Count -eq 1) -and ($plusLines[0] -match 'Generated from InstallPath on .+\.')
                        if ($onlyDateMinus -and $onlyDatePlus) { $skipEntireSection = $true }
                    }
                    if ($skipEntireSection) { continue }
                    $explanation = $defaultExplanation
                    foreach ($pair in $fileExplanationPairs) {
                        if ($relPath -like $pair[0]) { $explanation = $pair[1]; break }
                    }
                    [void]$readmeLines.Add("### " + [string]$relPath)
                    [void]$readmeLines.Add("")
                    [void]$readmeLines.Add([string]$explanation)
                    [void]$readmeLines.Add("")
                    [void]$readmeLines.Add([string]$fence + "diff")
                    $perFileDiffLines = ([string]$perFileDiffText) -split "`n"
                    foreach ($ln in $perFileDiffLines) {
                        $lineToAdd = ""
                        if ($null -ne $ln) { try { $lineToAdd = [string]$ln } catch { } }
                        if ([string]::IsNullOrEmpty($lineToAdd)) { $lineToAdd = "" }
                        [void]$readmeLines.Add($lineToAdd)
                    }
                    [void]$readmeLines.Add($fence)
                    [void]$readmeLines.Add("")
                }
            }
            $safeLines = @()
            if ($readmeLines) {
                foreach ($item in $readmeLines) {
                    $s = ""
                    if ($null -ne $item) { try { $s = [string]$item } catch { } }
                    if ($null -eq $s) { $s = "" }
                    $safeLines += $s
                }
            }
            $utf8WithBomReadme = New-Object System.Text.UTF8Encoding $true
            [System.IO.File]::WriteAllLines($readmePath, $safeLines, $utf8WithBomReadme)
            & $gitExe add README.md 2>&1 | Out-Null
            & $gitExe add digests/ 2>&1 | Out-Null
            Write-Log "Wrote README.md"

            $commitOut = & $gitExe commit -m "Backup $(Get-Date -Format 'yyyy-MM-dd HH:mm')" 2>&1
            foreach ($line in $commitOut) {
                $m = ""
                if ($null -ne $line) { try { $m = [string]$line } catch { $m = "(output)" } }
                Write-Log $m
            }
            if ($LASTEXITCODE -ne 0) { Write-Log "Nothing to commit or commit failed." }
            $pushOut = & $gitExe push --force origin HEAD 2>&1
            foreach ($line in $pushOut) {
                $m = ""
                if ($null -ne $line) { try { $m = [string]$line } catch { $m = "(output)" } }
                Write-Log $m
            }
            $ErrorActionPreference = $prevErrPref
            if ($LASTEXITCODE -ne 0) { throw "Git push failed." }
        } finally {
            Pop-Location
        }

        Write-Log "Backup completed successfully."
        Remove-Item -Path $StagingDir -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        $errMsg = "Unknown error"
        if ($null -ne $_ -and $_.Exception -and $null -ne $_.Exception.Message) {
            $errMsg = $_.Exception.Message
        }
        if ([string]::IsNullOrEmpty([string]$errMsg)) { $errMsg = "Unknown error" }
        $logMsg = "Backup failed: " + $errMsg
        try { Write-Log $logMsg -Level ERROR } catch { Write-Log "Backup failed." -Level ERROR }
        if ($null -ne $_ -and $_.ScriptStackTrace) {
            foreach ($traceLine in ($_.ScriptStackTrace -split "`n")) { try { Write-Log "  $traceLine" -Level ERROR } catch { } }
        }
        # Dismissible toast: use MessageBox so user must close it
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
            [System.Windows.Forms.MessageBox]::Show(
                "ITGMania backup failed. Check logs at $LogDir",
                "ITGMania Backup Failed",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
        } catch {
            Write-Host "Backup failed. Check logs at $LogDir"
        }
        exit 1
    }
}

if ($RepairDigests) {
    $digestsDir = $DigestsPath
    if (-not $digestsDir) { $digestsDir = Join-Path $StagingDir "digests" }
    if (-not (Test-Path $digestsDir)) {
        Write-Error "Digests path not found: $digestsDir. Use -DigestsPath to point to the digests folder (e.g. path to backup repo's digests/ folder)."
        exit 1
    }
    $installPathForRepair = $null
    try {
        $config = Get-Config
        if ($config -and $config.InstallPath) { $installPathForRepair = $config.InstallPath.TrimEnd('\') }
    } catch { }
    Repair-DigestPackBlocks -DigestsDir $digestsDir -InstallPath $installPathForRepair
    exit 0
}

Invoke-Backup
