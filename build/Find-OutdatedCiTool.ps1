<#
    Compares the CI tool versions pinned in .github/workflows/ci.yml (Pester,
    PSScriptAnalyzer) with the newest stable release in the PowerShell Gallery
    (#262). The pins keep a new release from changing results unnoticed; this
    keeps them from ageing silently. The monthly "CI tool versions" workflow
    runs it and keeps ONE issue up to date.

    Fails safe: when the Gallery cannot be read, nothing is reported as outdated
    and the output says ok=false, so the workflow neither opens an issue nor
    closes the open one on a bad day.

    -LatestPath reads the newest versions from a JSON file
    ({ "Pester": "5.8.0", "PSScriptAnalyzer": "1.24.0" }) instead of the
    Gallery; the tests use it.
#>
[CmdletBinding()]
param(
    [string]$WorkflowPath = (Join-Path (Split-Path -Parent $PSScriptRoot) '.github/workflows/ci.yml'),
    [string]$LatestPath,
    [string]$ReportPath
)

$script:CiTools = @(
    [pscustomobject]@{ Name = 'Pester'; Variable = 'PESTER_VERSION' }
    [pscustomobject]@{ Name = 'PSScriptAnalyzer'; Variable = 'PSSA_VERSION' }
)

function Get-CiToolPin {
    # Pure: the pinned version of each CI tool, read from the workflow text.
    param([string]$WorkflowText)
    foreach ($tool in $script:CiTools) {
        $m = [regex]::Match($WorkflowText, '(?m)^\s*' + [regex]::Escape($tool.Variable) + ':\s*([0-9][0-9.]*)\s*$')
        if (-not $m.Success) { throw ('{0} is not set in .github/workflows/ci.yml' -f $tool.Variable) }
        [pscustomobject]@{ Name = $tool.Name; Variable = $tool.Variable; Pinned = $m.Groups[1].Value }
    }
}

function Compare-CiToolVersion {
    # Pure: the tools whose pin is older than the newest release. A tool with no
    # newest version, or a version that does not parse, is left out (nothing is
    # claimed that was not read).
    param([object[]]$Pin, [hashtable]$Latest)
    foreach ($p in @($Pin)) {
        $newest = $Latest[$p.Name]
        if (-not $newest) { continue }
        $a = $null; $b = $null
        if (-not [version]::TryParse([string]$p.Pinned, [ref]$a) -or -not [version]::TryParse([string]$newest, [ref]$b)) { continue }
        if ($b -gt $a) { [pscustomobject]@{ Name = $p.Name; Variable = $p.Variable; Pinned = $p.Pinned; Latest = [string]$newest } }
    }
}

function Format-OutdatedCiToolReport {
    # Pure: the markdown body of the tracking issue.
    param([object[]]$Row)
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('The CI tools are pinned in `.github/workflows/ci.yml` so a new release cannot change results unnoticed. These pins are behind the newest stable release in the PowerShell Gallery:')
    $lines.Add('')
    foreach ($r in @($Row)) { $lines.Add(('- {0}: pinned {1}, newest {2} (`{3}`)' -f $r.Name, $r.Pinned, $r.Latest, $r.Variable)) }
    $lines.Add('')
    $lines.Add('To update: change the value in `ci.yml` on a branch, run `build/Invoke-Local.ps1 -Task All` and let CI run. Read the release notes of the tool first. This list is rewritten every month by the "CI tool versions" workflow; when every pin is current this issue closes itself.')
    return ($lines -join "`n")
}

if ($MyInvocation.InvocationName -eq '.') { return }

$ErrorActionPreference = 'Stop'
$pins = @(Get-CiToolPin (Get-Content -LiteralPath $WorkflowPath -Raw))
$latest = @{}
$ok = $true
if ($LatestPath) {
    $json = Get-Content -LiteralPath $LatestPath -Raw | ConvertFrom-Json
    foreach ($p in $pins) { if ($json.PSObject.Properties[$p.Name]) { $latest[$p.Name] = [string]$json.($p.Name) } }
} else {
    foreach ($p in $pins) {
        try {
            $found = Find-Module -Name $p.Name -Repository PSGallery -ErrorAction Stop
            $latest[$p.Name] = [string]$found.Version
        } catch {
            $ok = $false
            Write-Warning ('Could not read {0} from the PowerShell Gallery: {1}' -f $p.Name, $_.Exception.Message)
        }
    }
}
# A tool whose newest version was not read makes the whole run unknown.
if (@($pins | Where-Object { -not $latest[$_.Name] }).Count -gt 0) { $ok = $false }
$rows = @()
if ($ok) { $rows = @(Compare-CiToolVersion -Pin $pins -Latest $latest) }
foreach ($p in $pins) { Write-Output ('{0}: pinned {1}, newest {2}' -f $p.Name, $p.Pinned, $(if ($latest[$p.Name]) { $latest[$p.Name] } else { 'unknown' })) }
if (-not $ok) { Write-Output 'The Gallery could not be read; nothing is reported.' }
elseif ($rows.Count -eq 0) { Write-Output 'Every pin is current.' }
if ($ReportPath -and $ok) { [IO.File]::WriteAllText($ReportPath, (Format-OutdatedCiToolReport $rows) + "`n", (New-Object Text.UTF8Encoding($false))) }
if ($env:GITHUB_OUTPUT) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value @(('ok=' + $ok.ToString().ToLowerInvariant()), ('count=' + $rows.Count)) }
