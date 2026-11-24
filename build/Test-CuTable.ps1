<#
    Checks src/cu-table.json before it ships (#267, #459). The release workflow
    runs it with -CheckAge, so a table older than -MaxAgeMonths stops the release:
    with newer monthly updates than the table knows, "months behind" is understated.
    Exit code 1 and a GitHub error annotation on any problem.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'GitHub workflow commands must be written to the host stream.')]
[CmdletBinding()]
param(
    [string]$Path = 'src/cu-table.json',
    [switch]$CheckAge,
    [int]$MaxAgeMonths = 3
)

$ErrorActionPreference = 'Stop'
$env:IPU_ASSESSMENT_LIBRARY_ONLY = '1'
. (Join-Path $PSScriptRoot '..\src\Windows-IPU-Readiness-Assessment.ps1')
$problems = @()
$table = $null
try { $table = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { $problems += ('The table could not be read: ' + $_.Exception.Message) }
if ($table) {
    $problems += @(Test-CuTableContent $table)
    $asOf = ConvertTo-CuDateText $table.asOf
    if ($CheckAge -and $asOf) {
        $date = [datetime]::ParseExact($asOf, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        if ($date.AddMonths($MaxAgeMonths) -lt (Get-Date)) {
            $problems += ('The cumulative update table is dated ' + $asOf + ', older than ' + $MaxAgeMonths + ' months. Refresh it: run the "CU table" workflow or build/Update-CuTable.ps1, then merge the pull request.')
        }
    }
}
if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Host ('::error title=CU table::' + $p) }
    exit 1
}
Write-Host ('CU table is fine: dated ' + (ConvertTo-CuDateText $table.asOf))
