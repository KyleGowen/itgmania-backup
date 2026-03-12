#Requires -Version 5.1

$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $projectRoot 'Install-ITGManiaBackup.ps1'
$fixturesDir = Join-Path $PSScriptRoot 'Fixtures'
$configPath = (Resolve-Path (Join-Path $fixturesDir 'config.json')).Path

Describe 'Install-ITGManiaBackup config resolution' {
    It 'uses -ConfigPath when provided and path exists' {
        Mock Read-Host { return 'N' }
        $tempRoot = Join-Path $env:TEMP "ITGManiaBackupConfigTest_$(Get-Random)"
        $origProgramData = $env:ProgramData
        $env:ProgramData = $tempRoot
        try {
            $output = & $scriptPath -ConfigPath $configPath 2>&1 | Out-String
            $output | Should Contain 'Found config'
        } finally {
            $env:ProgramData = $origProgramData
            Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Install-ITGManiaBackup obscure logic' {
    It 'obscures BackupRepoAccessToken when displaying config' {
        $tempRoot = Join-Path $env:TEMP "ITGManiaBackupObscure_$(Get-Random)"
        $origProgramData = $env:ProgramData
        $env:ProgramData = $tempRoot
        New-Item -ItemType Directory -Path (Join-Path $tempRoot "ITGManiaBackup") -Force | Out-Null
        try {
            Mock Read-Host { return 'N' }
            Mock Copy-Item { }
            Mock Set-Content { }
            Mock New-ScheduledTaskAction { return $null }
            Mock New-ScheduledTaskTrigger { return $null }
            Mock New-ScheduledTaskSettingsSet { return $null }
            Mock Register-ScheduledTask { return $null }
            Mock Unregister-ScheduledTask { }
            $shortcutMock = [PSCustomObject]@{ TargetPath = ''; Arguments = ''; WorkingDirectory = ''; Description = '' }
            $shortcutMock | Add-Member -MemberType ScriptMethod -Name Save -Value { }
            Mock New-Object -ParameterFilter { $ComObject -eq 'WScript.Shell' } { return [PSCustomObject]@{ CreateShortcut = { $shortcutMock } } }

            $output = & $scriptPath -ConfigPath $configPath 2>&1 | Out-String
            $output | Should Match 'BackupRepoAccessToken'
            $output | Should Match '\*\*\*\*\*\*'
        } finally {
            $env:ProgramData = $origProgramData
            Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Install-ITGManiaBackup with mocked side effects' {
    BeforeEach {
        $tempInstallRoot = Join-Path $env:TEMP "ITGManiaBackupTest_$(Get-Random)"
        $origProgramData = $env:ProgramData
        $env:ProgramData = $tempInstallRoot
        New-Item -ItemType Directory -Path (Join-Path $tempInstallRoot "ITGManiaBackup") -Force | Out-Null
    }
    AfterEach {
        $env:ProgramData = $origProgramData
        Remove-Item -Path $tempInstallRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'runs without error when config exists and side effects are mocked' {
        Mock Copy-Item { }
        Mock Set-Content { }
        Mock New-ScheduledTaskAction { return $null }
        Mock New-ScheduledTaskTrigger { return $null }
        Mock New-ScheduledTaskSettingsSet { return $null }
        Mock Register-ScheduledTask { return $null }
        Mock Unregister-ScheduledTask { }
        Mock Read-Host { return 'N' }
        $shortcutMock = [PSCustomObject]@{
            TargetPath = ''
            Arguments = ''
            WorkingDirectory = ''
            Description = ''
        }
        $shortcutMock | Add-Member -MemberType ScriptMethod -Name Save -Value { }
        Mock New-Object -ParameterFilter { $ComObject -eq 'WScript.Shell' } { return [PSCustomObject]@{ CreateShortcut = { $shortcutMock } } }

        { & $scriptPath -ConfigPath $configPath } | Should Not Throw
    }
}
