<#
    Runs PSScriptAnalyzer over src/, build/ and tests/ with the repository
    settings, writes every finding as a GitHub annotation and a job-summary
    table, and fails when a finding at or above -FailOn remains.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'GitHub workflow commands must be written to the host stream.')]
[CmdletBinding()]
param([ValidateSet('Error', 'Warning', 'Information')][string]$FailOn = 'Error')

$ErrorActionPreference = 'Stop'
Import-Module PSScriptAnalyzer
$findings = @()
foreach ($p in 'src', 'build', 'tests') {
    $findings += @(Invoke-ScriptAnalyzer -Path $p -Recurse -Settings ./PSScriptAnalyzerSettings.psd1)
}
# Windows Server 2012 R2 / Windows PowerShell 4.0 compatibility of the
# scripts that run on servers (#94). CI itself has no PowerShell 4.0.
$findings += @(Invoke-ScriptAnalyzer -Path src -Recurse -Settings ./PSScriptAnalyzerSettings.PS4.psd1)
foreach ($f in $findings) {
    $level = 'notice'
    if ([string]$f.Severity -eq 'Error') { $level = 'error' } elseif ([string]$f.Severity -eq 'Warning') { $level = 'warning' }
    $file = (Resolve-Path -LiteralPath $f.ScriptPath -Relative) -replace '^\.[\\/]', '' -replace '\\', '/'
    Write-Host ('::{0} file={1},line={2},title={3}::{4}' -f $level, $file, $f.Line, $f.RuleName, ($f.Message -replace '\r?\n', ' '))
}
$order = @{ Information = 0; Warning = 1; Error = 2 }
$failing = @($findings | Where-Object { $order[[string]$_.Severity] -ge $order[$FailOn] })
$summary = @('### PSScriptAnalyzer', '', '| Rule | Severity | Count |', '|---|---|---|')
foreach ($g in @($findings | Group-Object RuleName, Severity | Sort-Object Count -Descending)) {
    $parts = $g.Name -split ', '
    $summary += ('| {0} | {1} | {2} |' -f $parts[0], $parts[1], $g.Count)
}
$summary += ''
$summary += ('Findings: {0}. Failing at or above {1}: {2}.' -f $findings.Count, $FailOn, $failing.Count)
if ($env:GITHUB_STEP_SUMMARY) { $summary -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8 }
Write-Host ('::notice title=PSScriptAnalyzer::Findings {0}, failing at or above {1}: {2}' -f $findings.Count, $FailOn, $failing.Count)
if ($failing.Count -gt 0) { exit 1 }
