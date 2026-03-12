#Requires -Version 5.1

$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $projectRoot 'CronRunner.ps1'
$fixturesDir = Join-Path $PSScriptRoot 'Fixtures'
$configPath = Join-Path $fixturesDir 'config.json'
$backupScriptDest = Join-Path $fixturesDir 'Backup-ITGMania.ps1'
Copy-Item -Path (Join-Path $projectRoot 'Backup-ITGMania.ps1') -Destination $backupScriptDest -Force
try {
    . $scriptPath -ConfigPath $configPath
} finally {
    Remove-Item -Path $backupScriptDest -Force -ErrorAction SilentlyContinue
}

Describe 'Test-CronPart' {
    It 'matches asterisk to any value' {
        Test-CronPart -Part '*' -Value 5 -Min 0 -Max 59 | Should Be $true
    }
    It 'matches exact number' {
        Test-CronPart -Part '15' -Value 15 -Min 0 -Max 59 | Should Be $true
        Test-CronPart -Part '15' -Value 14 -Min 0 -Max 59 | Should Be $false
    }
    It 'matches step expression */N' {
        Test-CronPart -Part '*/5' -Value 0 -Min 0 -Max 59 | Should Be $true
        Test-CronPart -Part '*/5' -Value 5 -Min 0 -Max 59 | Should Be $true
        Test-CronPart -Part '*/5' -Value 3 -Min 0 -Max 59 | Should Be $false
    }
    It 'matches range A-B' {
        Test-CronPart -Part '10-20' -Value 15 -Min 0 -Max 59 | Should Be $true
        Test-CronPart -Part '10-20' -Value 9 -Min 0 -Max 59 | Should Be $false
    }
    It 'returns false for invalid part' {
        Test-CronPart -Part 'invalid' -Value 5 -Min 0 -Max 59 | Should Be $false
    }
}
