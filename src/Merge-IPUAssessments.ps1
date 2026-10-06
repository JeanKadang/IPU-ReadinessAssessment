<#
===============================================================================
 SCRIPT NAME : Merge-IPUAssessments.ps1
 VERSION     : 1.0.2 (for Windows-IPU-Readiness-Assessment 4.0.1+)
 PURPOSE     : Combine the JSON results of many servers into one overview.
 RUNS ON     : Any Windows machine with Windows PowerShell 5.1 or PowerShell 7
               (an admin workstation or jump host - NOT on the assessed servers).
===============================================================================

.SYNOPSIS
    Reads every <Computer>-IPU-Assessment.json (and -IPU-PostUpgrade.json) in a
    folder and writes:
        IPU-Fleet-Overview.html   one row per server, worst first
        IPU-Fleet-Servers.csv     the same as a spreadsheet (opens in Excel)
        IPU-Fleet-Findings.csv    every BLOCKER/ACTION/WARNING/MANUAL finding,
                                  one row each, for filtering in Excel

.EXAMPLE
    .\Merge-IPUAssessments.ps1 -InputFolder 'D:\IPU\Results'
    .\Merge-IPUAssessments.ps1 -InputFolder 'D:\IPU\Results' -OutputFolder 'D:\IPU\Overview' -Mode Pre

.NOTES
    Collect the JSON files from the servers with the approved SA file-retrieval
    process into one folder first. Read-only for the input files.
    CSV files use ';' as separator so Excel with Danish regional settings
    opens them in columns directly.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InputFolder,
    [string]$OutputFolder = '',
    [ValidateSet('Pre','Post','All')][string]$Mode = 'All',
    [string]$Delimiter = ';'
)

$ErrorActionPreference = 'Stop'
if (-not $OutputFolder) { $OutputFolder = $InputFolder }
if (-not (Test-Path -LiteralPath $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null }

$rank = @{ BLOCKER=1; ACTION=2; WARNING=3; MANUAL=4; OK=5 }
function Encode([object]$v) { if ($null -eq $v) { return '' }; return [System.Net.WebUtility]::HtmlEncode([string]$v) }

# CSV cells are opened in Excel. A value taken from a server (application
# name, task, hostname) that starts with = + - @ or a tab/CR would be run as
# a formula, so it is prefixed with an apostrophe (OWASP CSV injection).
function ConvertTo-CsvSafeValue {
    param([object]$Value)
    if ($Value -is [string] -and $Value -match '^[=+\-@\t\r]') { return "'" + $Value }
    return $Value
}
function ConvertTo-CsvSafeRow {
    param([Parameter(ValueFromPipeline = $true)]$Row)
    process {
        $safe = [ordered]@{}
        foreach ($p in $Row.PSObject.Properties) { $safe[$p.Name] = ConvertTo-CsvSafeValue $p.Value }
        [pscustomobject]$safe
    }
}

$files = @(Get-ChildItem -LiteralPath $InputFolder -Filter '*-IPU-*.json' -File | Where-Object { $_.Name -match '-IPU-(Assessment|PostUpgrade)\.json$' })
if ($files.Count -eq 0) { throw ('No *-IPU-Assessment.json or *-IPU-PostUpgrade.json files found in ' + $InputFolder) }

$servers = New-Object System.Collections.Generic.List[object]
$findings = New-Object System.Collections.Generic.List[object]
$unreadable = @()
foreach ($f in $files) {
    try { $r = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { $unreadable += $f.Name; continue }
    if ($r.Schema -ne 'IPU-Assessment/1') { $unreadable += ($f.Name + ' (unknown schema)'); continue }
    if ($Mode -ne 'All' -and $r.Mode -ne $Mode) { continue }

    $top = @($r.Results | Where-Object { $_.Kind -eq 'Finding' -and $_.Status -in @('BLOCKER','ACTION') } |
        Sort-Object @{Expression={ $rank[[string]$_.Status] }},Item | ForEach-Object { $_.Status + ': ' + $_.Item })
    $notCompleted = @($r.CheckRuns | Where-Object { $_.Outcome -ne 'Completed' -and $_.Outcome -ne 'Skipped' } | ForEach-Object { $_.Name + ' (' + $_.Outcome + ')' })
    $servers.Add([pscustomobject][ordered]@{
        ComputerName     = $r.ComputerName
        Mode             = $r.Mode
        Overall          = $r.Overall
        Blocker          = [int]$r.Counts.BLOCKER
        Action           = [int]$r.Counts.ACTION
        Warning          = [int]$r.Counts.WARNING
        Manual           = [int]$r.Counts.MANUAL
        Target           = 'Windows Server ' + $r.TargetServerVersion
        CurrentOS        = $r.Facts.CurrentOS
        UpgradePath      = $r.Facts.UpgradePath
        InstallationMedia= $r.Facts.RecommendedMedia
        Platform         = $r.Facts.Platform
        DomainRole       = $r.Facts.DomainRole
        SqlServer        = $r.Facts.SqlServer
        CompatScan       = $r.Facts.CompatScan
        CDrive           = $r.Facts.CDrive
        Activation       = $r.Facts.Activation
        TopIssues        = ($top -join ' | ')
        NotAssessed      = ($notCompleted -join ' | ')
        Partial          = [bool]$r.Partial
        Completed        = $r.Completed
        CollectorVersion = $r.CollectorVersion
        SourceFile       = $f.Name
    })
    foreach ($x in @($r.Results | Where-Object { $_.Kind -eq 'Finding' -and $_.Status -in @('BLOCKER','ACTION','WARNING','MANUAL') })) {
        $findings.Add([pscustomobject][ordered]@{
            ComputerName = $r.ComputerName; Mode = $r.Mode; Status = $x.Status; Area = $x.Area; Item = $x.Item
            Value = $x.Value; Details = $x.Details; Recommendation = $x.Recommendation; SourceFile = $f.Name
        })
    }
}

# If a server has several results for the same mode, keep the newest.
$latest = @($servers | Group-Object ComputerName,Mode | ForEach-Object { $_.Group | Sort-Object Completed -Descending | Select-Object -First 1 })
$latest = @($latest | Sort-Object @{Expression={ $rank[[string]$_.Overall] }},ComputerName)
# Findings come only from the result each server/mode row was taken from,
# never from an older, superseded result for the same server.
$keep = @{}; foreach ($s in $latest) { $keep[$s.SourceFile] = $true }
$fleetFindings = @($findings | Where-Object { $keep.ContainsKey($_.SourceFile) } | Sort-Object @{Expression={ $rank[[string]$_.Status] }},ComputerName,Item)

$serversCsv = Join-Path $OutputFolder 'IPU-Fleet-Servers.csv'
$findingsCsv = Join-Path $OutputFolder 'IPU-Fleet-Findings.csv'
$htmlPath = Join-Path $OutputFolder 'IPU-Fleet-Overview.html'
$latest | ConvertTo-CsvSafeRow | Export-Csv -LiteralPath $serversCsv -Delimiter $Delimiter -NoTypeInformation -Encoding UTF8
$fleetFindings | ConvertTo-CsvSafeRow | Export-Csv -LiteralPath $findingsCsv -Delimiter $Delimiter -NoTypeInformation -Encoding UTF8

# Most common blocking/action items across the fleet.
$common = @($fleetFindings | Where-Object { $_.Status -in @('BLOCKER','ACTION') } | Group-Object Status,Item | Sort-Object @{Expression={ $rank[[string]$_.Group[0].Status] }},@{Expression='Count';Descending=$true} | Select-Object -First 15)
$overallCounts = @{}; foreach ($k in @('BLOCKER','ACTION','WARNING','MANUAL','OK')) { $overallCounts[$k] = @($latest | Where-Object { $_.Overall -eq $k }).Count }

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>IPU Fleet Overview</title>')
[void]$sb.AppendLine(@'
<style>
:root{--ink:#16202e;--muted:#5d6a79;--line:#dde3ea;--bg:#f3f5f8;--navy:#16365f;--blocker:#7a1717;--action:#b42318;--warning:#9a5800;--manual:#5b47a0;--ok:#17703a}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:13px/1.45 "Segoe UI",Arial,sans-serif}
.wrap{max-width:1600px;margin:auto;padding:24px 16px}h1{margin:0 0 4px;font-size:22px;color:#fff}.hero{background:var(--navy);color:#d5e1ee;padding:20px 24px;border-radius:12px}
.cards{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:10px;margin:14px 0}.card{background:#fff;border:1px solid var(--line);border-radius:10px;padding:10px 14px}.card b{display:block;font-size:22px}.card small{color:var(--muted);text-transform:uppercase;font-size:11px;letter-spacing:.04em}
section{background:#fff;border:1px solid var(--line);border-radius:10px;margin:14px 0;padding:16px 18px}h2{margin:0 0 10px;font-size:17px;color:var(--navy)}
.scroll{overflow-x:auto}table{border-collapse:collapse;width:100%;min-width:1100px}th,td{text-align:left;vertical-align:top;border-bottom:1px solid var(--line);padding:6px 8px}th{background:#eef2f7;font-size:11px;text-transform:uppercase;letter-spacing:.04em;color:#30475f}
.badge{display:inline-block;color:#fff;font-weight:700;font-size:11px;padding:2px 8px;border-radius:999px}.s-blocker{background:var(--blocker)}.s-action{background:var(--action)}.s-warning{background:var(--warning)}.s-manual{background:var(--manual)}.s-ok{background:var(--ok)}
.muted{color:var(--muted)}.nw{white-space:nowrap}
@media(max-width:900px){.cards{grid-template-columns:repeat(2,1fr)}}
</style></head><body><div class="wrap">
'@)
[void]$sb.AppendLine('<div class="hero"><h1>IPU Fleet Overview</h1><p>' + $latest.Count + ' servers &nbsp;|&nbsp; Generated ' + (Get-Date).ToString('yyyy-MM-dd HH:mm') + ' &nbsp;|&nbsp; Source: ' + (Encode $InputFolder) + '</p></div>')
[void]$sb.AppendLine('<div class="cards">')
foreach ($k in @('BLOCKER','ACTION','WARNING','MANUAL','OK')) { [void]$sb.AppendLine('<div class="card"><small>Overall ' + $k + '</small><b>' + $overallCounts[$k] + '</b></div>') }
[void]$sb.AppendLine('</div>')
if ($unreadable.Count -gt 0) { [void]$sb.AppendLine('<section><h2>Files not read</h2><p>' + (Encode ($unreadable -join ', ')) + '</p></section>') }

[void]$sb.AppendLine('<section><h2>Servers (worst first)</h2><div class="scroll"><table><thead><tr><th>Server</th><th>Mode</th><th>Overall</th><th>B/A/W/M</th><th>Current OS</th><th>Target</th><th>Media</th><th>Platform</th><th>SQL</th><th>Top issues</th><th>Not assessed</th><th>Completed</th></tr></thead><tbody>')
foreach ($s in $latest) {
    $badge = '<span class="badge s-' + ([string]$s.Overall).ToLowerInvariant() + '">' + (Encode $s.Overall) + '</span>'
    if ($s.Partial) { $badge += ' <span class="muted">partial</span>' }
    [void]$sb.AppendLine('<tr><td class="nw"><b>' + (Encode $s.ComputerName) + '</b></td><td>' + (Encode $s.Mode) + '</td><td class="nw">' + $badge + '</td><td class="nw">' + $s.Blocker + '/' + $s.Action + '/' + $s.Warning + '/' + $s.Manual + '</td><td>' + (Encode $s.CurrentOS) + '</td><td class="nw">' + (Encode $s.Target) + '</td><td>' + (Encode $s.InstallationMedia) + '</td><td>' + (Encode $s.Platform) + '</td><td>' + (Encode $s.SqlServer) + '</td><td>' + (Encode $s.TopIssues) + '</td><td>' + (Encode $s.NotAssessed) + '</td><td class="nw muted">' + (Encode $s.Completed) + '</td></tr>')
}
[void]$sb.AppendLine('</tbody></table></div></section>')

if ($common.Count -gt 0) {
    [void]$sb.AppendLine('<section><h2>Most common BLOCKER/ACTION items</h2><div class="scroll"><table><thead><tr><th>Status</th><th>Item</th><th>Servers</th><th>Which</th></tr></thead><tbody>')
    foreach ($g in $common) {
        $first = $g.Group[0]
        $names = @($g.Group | ForEach-Object ComputerName | Sort-Object -Unique)
        [void]$sb.AppendLine('<tr><td><span class="badge s-' + ([string]$first.Status).ToLowerInvariant() + '">' + (Encode $first.Status) + '</span></td><td>' + (Encode $first.Item) + '</td><td>' + $names.Count + '</td><td>' + (Encode ($names -join ', ')) + '</td></tr>')
    }
    [void]$sb.AppendLine('</tbody></table></div></section>')
}
[void]$sb.AppendLine('<p class="muted">Details per server: open its own HTML report. All findings in one sheet: IPU-Fleet-Findings.csv.</p></div></body></html>')
[IO.File]::WriteAllText($htmlPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

'Servers: {0} | Findings: {1} | Unreadable files: {2}' -f $latest.Count, $fleetFindings.Count, $unreadable.Count
'Written: ' + $htmlPath
'Written: ' + $serversCsv
'Written: ' + $findingsCsv
