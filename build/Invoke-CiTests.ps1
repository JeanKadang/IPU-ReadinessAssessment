<#
    Runs the Pester suite in CI. Works under Windows PowerShell 5.1 and
    PowerShell 7. Every failed test and failed block is also written as a
    GitHub annotation, so failures are readable from the checks API without
    downloading the full log.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'GitHub workflow commands must be written to the host stream.')]
[CmdletBinding()]
param(
    [string]$Path = './tests',
    [switch]$Coverage,
    # With -Coverage (#127): fail below this share of src/*.ps1 commands, and
    # fail when a function in src/ has no executed command at all.
    [ValidateRange(0, 100)][double]$MinimumCoverage = 0
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath 'src/Windows-IPU-Readiness-Assessment.ps1')) {
    Write-Host '::error title=Missing script::src/Windows-IPU-Readiness-Assessment.ps1 not found'
    exit 1
}
Import-Module Pester -MinimumVersion 5.5.0 -Force

function Write-Annotation([string]$Level, [string]$Title, [string]$Message) {
    $t = ($Title -replace '[\r\n]+', ' ' -replace ':', '%3A' -replace ',', '%2C')
    $m = ($Message -replace '%', '%25' -replace '\r?\n', '%0A')
    Write-Host ('::{0} title={1}::{2}' -f $Level, $t, $m)
}

$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
if ($Coverage) {
    $config.CodeCoverage.Enabled = $true
    $config.CodeCoverage.Path = @('src/*.ps1')
    $config.CodeCoverage.OutputPath = 'coverage.xml'
}
$result = Invoke-Pester -Configuration $config

foreach ($t in @($result.Failed)) {
    $msg = (@($t.ErrorRecord) | ForEach-Object { $_.Exception.Message }) -join ' | '
    Write-Annotation 'error' ($t.ExpandedPath) $msg
}
foreach ($b in @($result.FailedBlocks)) {
    $msg = (@($b.ErrorRecord) | ForEach-Object { $_.Exception.Message }) -join ' | '
    Write-Annotation 'error' ('Block ' + $b.ExpandedPath) $msg
}
foreach ($c in @($result.FailedContainers)) {
    $msg = (@($c.ErrorRecord) | ForEach-Object { $_.Exception.Message }) -join ' | '
    Write-Annotation 'error' ('Container ' + $c.Item) $msg
}
Write-Annotation 'notice' ('Pester on PowerShell ' + $PSVersionTable.PSVersion) ('Passed {0}, Failed {1}, Skipped {2}, NotRun {3}' -f $result.PassedCount, $result.FailedCount, $result.SkippedCount, $result.NotRunCount)
$lines = @('### Pester on PowerShell ' + $PSVersionTable.PSVersion, '', ('Passed {0}, failed {1}, skipped {2}.' -f $result.PassedCount, $result.FailedCount, $result.SkippedCount))
$gateFailed = $false
if ($Coverage -and -not $result.CodeCoverage) {
    Write-Annotation 'error' 'Code coverage' 'Coverage was requested but Pester returned no coverage data.'
    $gateFailed = $true
}
if ($Coverage -and $result.CodeCoverage) {
    $pct = [math]::Round($result.CodeCoverage.CoveragePercent, 1)
    $lines += ('Code coverage of src/*.ps1: **{0}%** ({1} of {2} commands).' -f $pct, $result.CodeCoverage.CommandsExecutedCount, $result.CodeCoverage.CommandsAnalyzedCount)
    Write-Annotation 'notice' 'Code coverage' ('{0}% of src/*.ps1 commands executed' -f $pct)
    # Functions of which not a single command ran (#33): the list should stay
    # empty. Code outside functions (the main block) is not counted.
    $ran = @($result.CodeCoverage.CommandsExecuted | Where-Object { $_.Function } | ForEach-Object { (Split-Path $_.File -Leaf) + ': ' + $_.Function } | Sort-Object -Unique)
    $untested = @($result.CodeCoverage.CommandsMissed | Where-Object { $_.Function } | ForEach-Object { (Split-Path $_.File -Leaf) + ': ' + $_.Function } | Sort-Object -Unique | Where-Object { $ran -notcontains $_ })
    $untestedText = 'none'
    if ($untested.Count -gt 0) { $untestedText = $untested -join ', ' }
    Write-Annotation 'notice' 'Functions without any executed command' ('{0} of {1} functions: {2}' -f $untested.Count, ($ran.Count + $untested.Count), $untestedText)
    $lines += ('Functions without any executed command: {0} of {1} ({2}).' -f $untested.Count, ($ran.Count + $untested.Count), $untestedText)
    # The floor (#127). Raise MinimumCoverage in ci.yml as coverage grows.
    if ($MinimumCoverage -gt 0 -and $result.CodeCoverage.CoveragePercent -lt $MinimumCoverage) {
        Write-Annotation 'error' 'Coverage below the floor' ('{0}% of src/*.ps1 commands executed; the floor is {1}%. Add tests for the new code.' -f $pct, $MinimumCoverage)
        $lines += ('**Coverage {0}% is below the floor of {1}%.**' -f $pct, $MinimumCoverage)
        $gateFailed = $true
    }
    if ($MinimumCoverage -gt 0 -and $untested.Count -gt 0) {
        Write-Annotation 'error' 'Functions without tests' ('No command ran in: {0}. Every function in src/ needs at least one test that runs it.' -f $untestedText)
        $gateFailed = $true
    }
}
if ($env:GITHUB_STEP_SUMMARY) { $lines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8 }
if ($result.Result -ne 'Passed' -or $gateFailed) { exit 1 }
