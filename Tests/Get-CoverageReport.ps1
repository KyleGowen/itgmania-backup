#Requires -Version 5.1
<#
.SYNOPSIS
  Runs Pester tests with code coverage and outputs a coverage report by directory and file.
.DESCRIPTION
  Invokes Pester with CodeCoverage enabled, then parses the JaCoCo coverage.xml
  to produce a report grouped by file with coverage percentage.
#>

param(
    [string]$CoverageXmlPath = "coverage.xml",
    [switch]$RunTestsOnly
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$coveragePaths = @(
    (Join-Path $projectRoot "Backup-ITGMania.ps1"),
    (Join-Path $projectRoot "CronRunner.ps1"),
    (Join-Path $projectRoot "Install-ITGManiaBackup.ps1")
)

# Run Pester with coverage (support Pester 3 and 5)
$pesterVersion = (Get-Module Pester -ListAvailable | Select-Object -First 1).Version
if ($pesterVersion.Major -ge 5) {
    $config = New-PesterConfiguration
    $config.Run.Path = $PSScriptRoot
    $config.Run.PassThru = $true
    $config.CodeCoverage.Enabled = $true
    $config.CodeCoverage.Path = $coveragePaths
    $config.CodeCoverage.OutputFormat = "JaCoCo"
    $config.CodeCoverage.OutputPath = Join-Path $projectRoot $CoverageXmlPath
    $config.Output.Verbosity = "Normal"
    $result = Invoke-Pester -Configuration $config
} else {
    $result = Invoke-Pester -Path $PSScriptRoot -CodeCoverage $coveragePaths -PassThru
}

# Parse coverage and build report
$coveragePath = Join-Path $projectRoot $CoverageXmlPath
$reportLines = [System.Collections.ArrayList]::new()
$fileStats = [System.Collections.ArrayList]::new()
$totalCovered = 0
$totalMissed = 0

# Pester 3: use CodeCoverage from result; Pester 5: use coverage.xml
if ($result.CodeCoverage -and $result.CodeCoverage.NumberOfCommandsAnalyzed -gt 0) {
    $cc = $result.CodeCoverage
    $pct = if ($cc.NumberOfCommandsAnalyzed -gt 0) {
        [math]::Round(100.0 * $cc.NumberOfCommandsExecuted / $cc.NumberOfCommandsAnalyzed, 1)
    } else { 0 }
    [void]$fileStats.Add([PSCustomObject]@{
        File = "All scripts"
        ShortName = "All scripts"
        Covered = $cc.NumberOfCommandsExecuted
        Missed = $cc.NumberOfCommandsAnalyzed - $cc.NumberOfCommandsExecuted
        Total = $cc.NumberOfCommandsAnalyzed
        Percent = $pct
    })
    $totalCovered = $cc.NumberOfCommandsExecuted
    $totalMissed = $cc.NumberOfCommandsAnalyzed - $cc.NumberOfCommandsExecuted
} elseif (Test-Path $coveragePath) {

    [xml]$xml = Get-Content -Path $coveragePath -Raw
    $packages = $xml.report.package
if (-not $packages) { $packages = @($xml.SelectNodes("//package")) }
foreach ($pkg in $packages) {
    $pkgName = $pkg.name
    $sourceFiles = $pkg.sourcefile
    if (-not $sourceFiles) { $sourceFiles = @($pkg.SelectNodes("sourcefile")) }
    foreach ($sf in $sourceFiles) {
        $fileName = $sf.name
        $fullName = if ($pkgName) { "$pkgName/$fileName" } else { $fileName }
        $covered = 0
        $missed = 0
        $counters = $sf.counter
        if (-not $counters) { $counters = @($sf.SelectNodes("counter")) }
        foreach ($c in $counters) {
            if ($c.type -eq 'INSTRUCTION') {
                $covered = [int]$c.covered
                $missed = [int]$c.missed
                break
            }
        }
        $total = $covered + $missed
        $pct = if ($total -gt 0) { [math]::Round(100.0 * $covered / $total, 1) } else { 100.0 }
        [void]$fileStats.Add([PSCustomObject]@{
            File = $fullName
            ShortName = $fileName
            Covered = $covered
            Missed = $missed
            Total = $total
            Percent = $pct
        })
        $totalCovered += $covered
        $totalMissed += $missed
    }
}

    # Also check for package-less sourcefiles at report level
$topSourceFiles = $xml.report.sourcefile
if ($topSourceFiles) {
    foreach ($sf in $topSourceFiles) {
        $fileName = $sf.name
        $covered = 0
        $missed = 0
        foreach ($c in $sf.counter) {
            if ($c.type -eq 'INSTRUCTION') {
                $covered = [int]$c.covered
                $missed = [int]$c.missed
                break
            }
        }
        $total = $covered + $missed
        $pct = if ($total -gt 0) { [math]::Round(100.0 * $covered / $total, 1) } else { 100.0 }
        [void]$fileStats.Add([PSCustomObject]@{
            File = $fileName
            ShortName = $fileName
            Covered = $covered
            Missed = $missed
            Total = $total
            Percent = $pct
        })
        $totalCovered += $covered
        $totalMissed += $missed
    }
}
} else {
    [void]$reportLines.Add("Coverage file not found: $coveragePath (Pester 5 required for per-file coverage)")
}

# Build report output
[void]$reportLines.Add("")
[void]$reportLines.Add("Coverage Report")
[void]$reportLines.Add("==============")
[void]$reportLines.Add("")
[void]$reportLines.Add("By File")
[void]$reportLines.Add("--------")

$grandTotal = $totalCovered + $totalMissed
$grandPct = if ($grandTotal -gt 0) { [math]::Round(100.0 * $totalCovered / $grandTotal, 1) } else { 0 }

foreach ($s in ($fileStats | Sort-Object ShortName)) {
    $line = ("{0,-35} | {1,5}% | {2,3}/{3} commands" -f $s.ShortName, $s.Percent, $s.Covered, $s.Total)
    [void]$reportLines.Add($line)
}

[void]$reportLines.Add("")
[void]$reportLines.Add(("Total{0,30} | {1,5}% | {2,3}/{3} commands" -f "", $grandPct, $totalCovered, $grandTotal))
[void]$reportLines.Add("")

$reportText = $reportLines -join "`n"
Write-Host $reportText

exit $result.FailedCount
