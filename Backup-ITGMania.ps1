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
    [string]$ConfigPath = $null
)

$ErrorActionPreference = 'Stop'
$MaxFileSizeBytes = 100 * 1024 * 1024   # 100 MB (GitHub limit)

# Resolve install root (where config and scripts live): ProgramData or LocalAppData when installed without admin
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProgramDataRoot = Join-Path $env:ProgramData "ITGManiaBackup"
$LocalAppDataRoot = Join-Path $env:LOCALAPPDATA "ITGManiaBackup"
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
        Remove-Item -Path $StagingDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $StagingDir) {
            cmd /c "rmdir /s /q `"$StagingDir`""
        }
        if (Test-Path $StagingDir) {
            throw "Could not remove staging directory (e.g. junction/symlink inside). Manually delete: $StagingDir"
        }
    }
    New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null

    try {
        # Clone (depth 1). If repo is empty (no commits), clone fails; then init and add remote.
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
            Remove-Item -Path $StagingDir -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $StagingDir) { cmd /c "rmdir /s /q `"$StagingDir`"" }
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

            # README.md at repo root: timestamp + diff since last backup
            $hasHead = $false
            $revOut = & $gitExe rev-parse HEAD 2>&1
            if ($LASTEXITCODE -eq 0) { $hasHead = $true }
            if ($hasHead) {
                $diffOut = & $gitExe diff --cached HEAD 2>&1
                $diffParts = [System.Collections.ArrayList]::new()
                if ($null -ne $diffOut) { foreach ($o in $diffOut) { $t = ""; if ($null -ne $o) { try { $t = [string]$o } catch { } }; if ($null -eq $t) { $t = "" }; [void]$diffParts.Add($t) } }
                $diffText = ($diffParts | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) -join "`n"
                if ([string]::IsNullOrWhiteSpace($diffText)) { $diffText = "No file changes since last backup." }
            } else {
                $diffStat = & $gitExe diff --cached --stat 2>&1
                $statParts = [System.Collections.ArrayList]::new()
                if ($null -ne $diffStat) { foreach ($o in $diffStat) { $t = ""; if ($null -ne $o) { try { $t = [string]$o } catch { } }; if ($null -eq $t) { $t = "" }; [void]$statParts.Add($t) } }
                $statPart = ($statParts | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) -join "`n"
                $diffText = "Initial backup.`n" + [string]$statPart
                if ([string]::IsNullOrWhiteSpace([string]$diffText)) { $diffText = "Initial backup." }
            }
            if ($null -eq $diffText) { $diffText = "No file changes since last backup." }
            $readmePath = Join-Path $StagingDir "README.md"
            $backupTime = Get-Date -Format 'yyyy-MM-dd HH:mm'
            if ([string]::IsNullOrEmpty([string]$backupTime)) { $backupTime = "unknown" }
            $fence = '```'
            if ([string]::IsNullOrEmpty([string]$fence)) { $fence = '```' }
            $readmeLines = New-Object System.Collections.ArrayList
            if ($null -eq $readmeLines) { $readmeLines = [System.Collections.ArrayList]::new() }
            [void]$readmeLines.Add("# ITGMania Backup")
            [void]$readmeLines.Add("")
            [void]$readmeLines.Add("Last backup: " + [string]$backupTime)
            [void]$readmeLines.Add("")
            [void]$readmeLines.Add("## Changes since last backup")
            [void]$readmeLines.Add("")
            [void]$readmeLines.Add([string]$fence + "diff")
            $diffText = [string]$diffText
            if ([string]::IsNullOrEmpty($diffText)) { $diffLines = @() } else { $diffLines = $diffText -split "`n" }
            foreach ($ln in $diffLines) {
                $lineToAdd = ""
                if ($null -ne $ln) { try { $lineToAdd = [string]$ln } catch { } }
                if ([string]::IsNullOrEmpty($lineToAdd)) { $lineToAdd = "" }
                [void]$readmeLines.Add($lineToAdd)
            }
            [void]$readmeLines.Add($fence)
            $safeLines = @()
            if ($readmeLines) {
                foreach ($item in $readmeLines) {
                    $s = ""
                    if ($null -ne $item) { try { $s = [string]$item } catch { } }
                    if ($null -eq $s) { $s = "" }
                    $safeLines += $s
                }
            }
            $utf8NoBomReadme = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::WriteAllLines($readmePath, $safeLines, $utf8NoBomReadme)
            & $gitExe add README.md 2>&1 | Out-Null
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

Invoke-Backup
