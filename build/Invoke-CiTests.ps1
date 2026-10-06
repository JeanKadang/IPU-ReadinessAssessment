<#
    Runs the Pester suite in CI. Works under Windows PowerShell 5.1 and
    PowerShell 7. Every failed test and failed block is also written as a
    GitHub annotation, so failures are readable from the checks API without
    downloading the full log.
#>
[CmdletBinding()]
param([string]$Path = './tests')

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath 'src/Windows-IPU-Readiness-Assessment.ps1')) {
    Write-Host '::error title=Missing script::src/Windows-IPU-Readiness-Assessment.ps1 not found'
    exit 1
}
Import-Module Pester -MinimumVersion 5.5.0

function Write-Annotation([string]$Level, [string]$Title, [string]$Message) {
    $t = ($Title -replace '[\r\n]+', ' ' -replace ':', '%3A' -replace ',', '%2C')
    $m = ($Message -replace '%', '%25' -replace '\r?\n', '%0A')
    Write-Host ('::{0} title={1}::{2}' -f $Level, $t, $m)
}

$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
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
if ($result.Result -ne 'Passed') { exit 1 }
