<#
    Checks data/eol-snapshot.json before it ships. The release workflow runs
    it with -CheckAge, so a snapshot older than -MaxAgeMonths stops the
    release (#285). Exit code 1 and a GitHub error annotation on any problem.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'GitHub workflow commands must be written to the host stream.')]
[CmdletBinding()]
param(
    [string]$Path = 'data/eol-snapshot.json',
    [switch]$CheckAge,
    [int]$MaxAgeMonths = 6
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\src\Get-IPUEolStatus.ps1')
$r = Test-EolSnapshotFile -Path $Path -Today (Get-Date) -MaxAgeMonths $MaxAgeMonths
$problems = @($r.Problems)
if ($CheckAge -and $r.Age.State -ne 'Fresh') {
    $problems += ($r.Age.Text + ' Refresh it: run the "EOL snapshot" workflow or Get-IPUEolStatus.ps1 -Update, then merge the pull request.')
}
if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Host ('::error title=EOL snapshot::' + $p) }
    exit 1
}
Write-Host ('EOL snapshot is fine: ' + $r.Age.Text)
