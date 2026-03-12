#Requires -Version 5.1

$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $projectRoot 'Backup-ITGMania.ps1'
$fixturesDir = Join-Path $PSScriptRoot 'Fixtures'
$configPath = Join-Path $fixturesDir 'config.json'
. $scriptPath -ConfigPath $configPath

Describe 'Get-CloneUrlWithToken' {
    It 'returns URL unchanged when token is empty' {
        Get-CloneUrlWithToken -Url 'https://github.com/user/repo.git' -Token '' | Should Be 'https://github.com/user/repo.git'
        Get-CloneUrlWithToken -Url 'https://github.com/user/repo.git' -Token $null | Should Be 'https://github.com/user/repo.git'
    }
    It 'injects token into https URL' {
        Get-CloneUrlWithToken -Url 'https://github.com/user/repo.git' -Token 'abc123' | Should Be 'https://abc123@github.com/user/repo.git'
    }
    It 'replaces existing user in URL' {
        Get-CloneUrlWithToken -Url 'https://user@github.com/owner/repo.git' -Token 'token' | Should Be 'https://token@github.com/owner/repo.git'
    }
}

Describe 'Test-CronPartMatch' {
    It 'matches asterisk to any value' {
        Test-CronPartMatch -Part '*' -Value 5 -Min 0 -Max 59 | Should Be $true
        Test-CronPartMatch -Part '*' -Value 0 -Min 0 -Max 23 | Should Be $true
    }
    It 'matches exact number' {
        Test-CronPartMatch -Part '15' -Value 15 -Min 0 -Max 59 | Should Be $true
        Test-CronPartMatch -Part '15' -Value 14 -Min 0 -Max 59 | Should Be $false
    }
    It 'matches step expression */N' {
        Test-CronPartMatch -Part '*/5' -Value 0 -Min 0 -Max 59 | Should Be $true
        Test-CronPartMatch -Part '*/5' -Value 5 -Min 0 -Max 59 | Should Be $true
        Test-CronPartMatch -Part '*/5' -Value 3 -Min 0 -Max 59 | Should Be $false
    }
    It 'matches range A-B' {
        Test-CronPartMatch -Part '10-20' -Value 15 -Min 0 -Max 59 | Should Be $true
        Test-CronPartMatch -Part '10-20' -Value 10 -Min 0 -Max 59 | Should Be $true
        Test-CronPartMatch -Part '10-20' -Value 20 -Min 0 -Max 59 | Should Be $true
        Test-CronPartMatch -Part '10-20' -Value 9 -Min 0 -Max 59 | Should Be $false
    }
    It 'returns false for invalid part' {
        Test-CronPartMatch -Part 'invalid' -Value 5 -Min 0 -Max 59 | Should Be $false
    }
}

Describe 'Get-NextCronRun' {
    It 'returns DateTime for valid cron' {
        $result = Get-NextCronRun -Cron '0 * * * *' -Timezone 'Pacific Standard Time'
        $result | Should Not Be $null
        $result | Should BeOfType [DateTime]
    }
    It 'returns null for empty cron' {
        Get-NextCronRun -Cron '' -Timezone 'Pacific Standard Time' | Should Be $null
        Get-NextCronRun -Cron $null -Timezone 'Pacific Standard Time' | Should Be $null
    }
    It 'returns null for invalid cron (too few parts)' {
        Get-NextCronRun -Cron '0 * * *' -Timezone 'Pacific Standard Time' | Should Be $null
    }
    It 'uses Pacific Standard Time when timezone is empty' {
        $result = Get-NextCronRun -Cron '0 * * * *' -Timezone ''
        $result | Should Not Be $null
    }
}

Describe 'Get-SongDisplayNameFromDir' {
    It 'returns empty for null or whitespace' {
        $r = Get-SongDisplayNameFromDir -SongDir $null
        $r.SongTitle | Should Be ''
        $r.Pack | Should Be ''
        Get-SongDisplayNameFromDir -SongDir '' | ForEach-Object { $_.SongTitle | Should Be '' }
    }
    It 'extracts pack and song from path' {
        $r = Get-SongDisplayNameFromDir -SongDir 'TestPack/TestSong'
        $r.SongTitle | Should Be 'TestSong'
        $r.Pack | Should Be 'TestPack'
    }
    It 'returns song only when no pack' {
        $res = Get-SongDisplayNameFromDir -SongDir 'OnlySong'
        $res.SongTitle | Should Be 'OnlySong'
        $res.Pack | Should Be ''
    }
}

    Describe 'Format-SecondsToPlayTime' {
    It 'returns 0m 0s for zero or negative' {
        Format-SecondsToPlayTime -Seconds 0 | Should Be '0m 0s'
        Format-SecondsToPlayTime -Seconds -1 | Should Be '0m 0s'
    }
    It 'formats seconds only' {
        Format-SecondsToPlayTime -Seconds 45 | Should Be '0m 45s'
    }
    It 'formats minutes and seconds' {
        Format-SecondsToPlayTime -Seconds 125 | Should Be '2m 5s'
    }
    It 'formats hours' {
        Format-SecondsToPlayTime -Seconds 3665 | Should Be '1h 1m 5s'
    }
}

Describe 'Parse-PlayTimeLine' {
    It 'parses valid line' {
        $r = Parse-PlayTimeLine -Line 'Time in songs this run: **TestPlayer** 1h 2m 30s'
        $r | Should Not Be $null
        $r.PlayerName | Should Be 'TestPlayer'
        $r.Seconds | Should Be 3750
    }
    It 'returns null for invalid line' {
        Parse-PlayTimeLine -Line 'invalid' | Should Be $null
        Parse-PlayTimeLine -Line '' | Should Be $null
        Parse-PlayTimeLine -Line $null | Should Be $null
    }
}

    Describe 'Parse-DigestScoreLine' {
    It 'parses valid score line' {
        $r = Parse-DigestScoreLine -Line '**TestPlayer** set a new score for **Song** (TestPack) - Challenge (12), dance-single on 2024-01-15.'
        $r | Should Not Be $null
        $r.PlayerName | Should Be 'TestPlayer'
        $r.Meter | Should Be 12
        $r.Date.Year | Should Be 2024
        $r.Date.Month | Should Be 1
        $r.Date.Day | Should Be 15
    }
    It 'parses line with leading dash' {
        $r = Parse-DigestScoreLine -Line '- **Player** ... (8) ... on 2024-02-20.'
        $r | Should Not Be $null
        $r.Meter | Should Be 8
    }
    It 'returns null for invalid line' {
        Parse-DigestScoreLine -Line 'no bold' | Should Be $null
        Parse-DigestScoreLine -Line '**Player** no meter' | Should Be $null
        Parse-DigestScoreLine -Line '' | Should Be $null
    }
}

Describe 'Format-MeterTallyForPlayerAsMarkdown' {
    It 'returns empty for null or empty tally' {
        Format-MeterTallyForPlayerAsMarkdown -PlayerName 'P' -MeterTally $null | Should Be ''
        Format-MeterTallyForPlayerAsMarkdown -PlayerName 'P' -MeterTally @{} | Should Be ''
    }
    It 'formats single meter' {
        $tally = @{ 12 = 5 }
        $result = Format-MeterTallyForPlayerAsMarkdown -PlayerName 'P' -MeterTally $tally
        $result | Should Match '\| 12 \|'
        $result | Should Match '\| Total \|'
        $result | Should Match '\| 5 \|'
    }
    It 'formats multiple meters' {
        $tally = @{ 8 = 2; 12 = 3 }
        $result = Format-MeterTallyForPlayerAsMarkdown -PlayerName 'P' -MeterTally $tally
        $result | Should Match '8'
        $result | Should Match '12'
        $result | Should Match '5'
    }
}

Describe 'Test-PackListLineIsSongFile' {
    It 'returns true for .ogg and .mp3' {
        Test-PackListLineIsSongFile -FileName 'song.ogg' | Should Be $true
        Test-PackListLineIsSongFile -FileName 'song.mp3' | Should Be $true
    }
    It 'returns false for other extensions' {
        Test-PackListLineIsSongFile -FileName 'song.txt' | Should Be $false
        Test-PackListLineIsSongFile -FileName 'song.ssc' | Should Be $false
    }
    It 'returns false for empty' {
        Test-PackListLineIsSongFile -FileName '' | Should Be $false
    }
}

Describe 'Get-PackListDiffSummary' {
    It 'returns empty for null or empty diff' {
        $r = Get-PackListDiffSummary -DiffText $null
        $r.Added.Count | Should Be 0
        $r.Removed.Count | Should Be 0
        Get-PackListDiffSummary -DiffText '' | ForEach-Object { $_.Added.Count | Should Be 0 }
    }
    It 'parses added and removed packs from diff' {
        $diff = @"
--- a/PACK_LIST.md
+++ b/PACK_LIST.md
+- **NewPack**
+  - **NewSub**
+    - x.ogg
+- **AddedPack**
- - **RemovedPack**
-   - **RemovedSub**
-     - y.ogg
"@
        $r = Get-PackListDiffSummary -DiffText $diff
        $r.Added.Keys -contains 'NewPack' | Should Be $true
        $r.Added.Keys -contains 'AddedPack' | Should Be $true
        $r.Removed.Keys -contains 'RemovedPack' | Should Be $true
    }
}

Describe 'Format-PackListDiffAsMarkdown' {
    It 'formats summary to markdown' {
        $summary = @{
            Added = @{ Pack1 = [System.Collections.ArrayList]@('s1.ogg'); Pack2 = [System.Collections.ArrayList]@() }
            Removed = @{ OldPack = [System.Collections.ArrayList]@('old.ogg') }
        }
        $result = Format-PackListDiffAsMarkdown -Summary $summary
        $result | Should Match '<details>'
        $result | Should Match 'Pack1'
        $result | Should Match 'OldPack'
    }
}

Describe 'Format-PackListDiffAsCollapsibleMarkdown' {
    It 'formats added and removed to collapsible HTML' {
        $added = @{ Pack = [System.Collections.ArrayList]@('song.ogg') }
        $removed = @{}
        $result = Format-PackListDiffAsCollapsibleMarkdown -AddedFinal $added -RemovedFinal $removed
        $result | Should Match '<details>'
        $result | Should Match 'Pack'
    }
}

Describe 'Parse-DigestFilePackBlock' {
    It 'parses Added and Removed sections' {
        $content = @"

#### Pack and song changes

**Added**
- **NewPack**
  - newsong.ogg

**Removed**
- **OldPack**
  - oldsong.ogg
"@
        $r = Parse-DigestFilePackBlock -DigestContent $content
        $r.Added.Keys -contains 'NewPack' | Should Be $true
        $r.Added['NewPack'] -contains 'newsong.ogg' | Should Be $true
        $r.Removed.Keys -contains 'OldPack' | Should Be $true
    }
}

Describe 'Get-PlayTimeDeltaFromStatsDiff' {
    It 'returns empty for null or empty diff' {
        $r = Get-PlayTimeDeltaFromStatsDiff -DiffText $null -RelPath 'x'
        $r.Count | Should Be 0
    }
    It 'extracts delta and player name' {
        $diff = @"
- <TotalGameplaySeconds>100</TotalGameplaySeconds>
+ <TotalGameplaySeconds>250</TotalGameplaySeconds>
+ <Name>TestPlayer</Name>
"@
        $r = Get-PlayTimeDeltaFromStatsDiff -DiffText $diff -RelPath 'LocalProfiles/00000000/Stats.xml'
        $r.Count | Should Be 1
        $r[0].PlayerName | Should Be 'TestPlayer'
        $r[0].DeltaSeconds | Should Be 150
    }
    It 'returns empty when delta is zero or negative' {
        $diff = @"
- <TotalGameplaySeconds>100</TotalGameplaySeconds>
+ <TotalGameplaySeconds>100</TotalGameplaySeconds>
"@
        (Get-PlayTimeDeltaFromStatsDiff -DiffText $diff -RelPath 'x').Count | Should Be 0
    }
}

Describe 'Get-NewScoreEntriesFromStatsDiff' {
    It 'returns empty for null diff' {
        (Get-NewScoreEntriesFromStatsDiff -DiffText $null -InstallPath '').Count | Should Be 0
    }
    It 'parses score entries from Stats.xml diff' {
        $fixturesPath = Join-Path $PSScriptRoot 'Fixtures'
        $diffPath = Join-Path $fixturesPath 'sample-stats-diff.txt'
        $diff = Get-Content -Raw -LiteralPath $diffPath
        $entries = Get-NewScoreEntriesFromStatsDiff -DiffText $diff -InstallPath ''
        $entries.Count -ge 1 | Should Be $true
        $entries[0].ToString().Contains('TestPlayer') | Should Be $true
        $entries[0].ToString().Contains('TestSong') | Should Be $true
    }
}

Describe 'Get-MeterFromSongChart' {
    It 'returns empty for empty InstallPath or SongDir' {
        Get-MeterFromSongChart -InstallPath '' -SongDir 'x' -Difficulty 'Challenge' -StepsType 'dance-single' | Should Be ''
        Get-MeterFromSongChart -InstallPath 'C:\x' -SongDir '' -Difficulty 'Challenge' -StepsType 'dance-single' | Should Be ''
    }
    It 'returns meter from .ssc file when song folder exists' {
        $fixturesDir = Join-Path $PSScriptRoot 'Fixtures'
        $installPath = $fixturesDir
        $songDir = 'Songs\TestPack\TestSong'
        $meter = Get-MeterFromSongChart -InstallPath $installPath -SongDir $songDir -Difficulty 'Challenge' -StepsType 'dance-single'
        $meter | Should Be '12'
    }
    It 'returns empty when song folder does not exist' {
        Get-MeterFromSongChart -InstallPath 'C:\nonexistent' -SongDir 'Songs\X\Y' -Difficulty 'Challenge' -StepsType 'dance-single' | Should Be ''
    }
}

Describe 'Get-SongsPackListMarkdown' {
    It 'returns placeholder when path does not exist' {
        Get-SongsPackListMarkdown -RootPath 'C:\nonexistent\path' -SectionTitle 'Songs' | Should Be '*(folder not present)*'
    }
    It 'builds tree from existing folder' {
        $songsPath = Join-Path (Join-Path $PSScriptRoot 'Fixtures') 'Songs'
        if (Test-Path $songsPath) {
            $result = Get-SongsPackListMarkdown -RootPath $songsPath -SectionTitle 'Songs'
            $result | Should Match 'TestPack'
            $result | Should Match 'TestSong'
            $result | Should Match 'test\.ssc'
        }
    }
}

Describe 'Copy-DirWithSizeFilter' {
    It 'copies files and respects exclude dirs' {
        $tempBase = [System.IO.Path]::GetTempPath()
        $src = Join-Path $tempBase "ITGManiaBackupTestSrc_$(Get-Random)"
        $dest = Join-Path $tempBase "ITGManiaBackupTestDest_$(Get-Random)"
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        'test' | Set-Content -Path (Join-Path $src 'keep.txt')
        $excludeDir = Join-Path $src 'ExcludeMe'
        New-Item -ItemType Directory -Path $excludeDir -Force | Out-Null
        'x' | Set-Content -Path (Join-Path $excludeDir 'skip.txt')
        try {
            $r = Copy-DirWithSizeFilter -SourceRoot $src -DestRoot $dest -ExcludeDirs @('ExcludeMe')
            Test-Path (Join-Path $dest 'keep.txt') | Should Be $true
            (Test-Path (Join-Path $dest 'ExcludeMe')) | Should Be $false
        } finally {
            Remove-Item -Path $src -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $dest -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'skips files that fail filter and reports them' {
        $src = Join-Path $env:TEMP "ITGManiaBackupTestSrc2_$(Get-Random)"
        $dest = Join-Path $env:TEMP "ITGManiaBackupTestDest2_$(Get-Random)"
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        'small' | Set-Content -Path (Join-Path $src 'small.txt')
        try {
            $r = Copy-DirWithSizeFilter -SourceRoot $src -DestRoot $dest -FileFilter { (Get-Item $args[0]).Length -gt 1000 }
            $r.Skipped.Count | Should Be 1
        } finally {
            Remove-Item -Path $src -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $dest -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-Config' {
    It 'returns config when valid file exists' {
        $config = Get-Config
        $config | Should Not Be $null
        $config.BackupRepoUrl | Should Not BeNullOrEmpty
        $config.InstallPath | Should Not BeNullOrEmpty
    }
    It 'throws when config file missing' {
        $origPath = $ConfigPath
        try {
            $ConfigPath = 'C:\nonexistent\config.json'
            { Get-Config } | Should Throw
        } finally {
            $ConfigPath = $origPath
        }
    }
}

Describe 'Get-GitExe' {
    It 'returns path to git when available' {
        $git = Get-GitExe
        $git | Should Not BeNullOrEmpty
        $git | Should Match 'git\.exe'
    }
}
