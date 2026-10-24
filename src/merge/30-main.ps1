$ErrorActionPreference = 'Stop'
if (-not $OutputFolder) { $OutputFolder = $InputFolder }
# The overview combines findings from every server (#128). A folder created
# here is limited to SYSTEM, Administrators and the current user (the merge
# runs on a workstation). An existing folder is never changed; a warning
# names the broad groups that can read it.
function New-MergeFolderSecurity {
    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $sids = @('S-1-5-18', 'S-1-5-32-544', [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    foreach ($sid in ($sids | Select-Object -Unique)) {
        $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, [System.Security.AccessControl.FileSystemRights]::FullControl, $inherit, [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)
    }
    return $security
}
function Get-BroadFolderReader {
    param([string]$Path)
    $broad = @{ 'S-1-1-0' = 'Everyone'; 'S-1-5-11' = 'Authenticated Users'; 'S-1-5-32-545' = 'Users' }
    $found = @()
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        foreach ($rule in @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
            $sid = [string]$rule.IdentityReference
            if ($broad.ContainsKey($sid) -and [string]$rule.AccessControlType -eq 'Allow' -and ([int]$rule.FileSystemRights -band [int][System.Security.AccessControl.FileSystemRights]::ReadData)) {
                if ($found -notcontains $broad[$sid]) { $found += $broad[$sid] }
            }
        }
    } catch { Write-Verbose ('Could not read the permissions of ' + $Path + ': ' + $_.Exception.Message) }
    return $found
}
if (-not (Test-Path -LiteralPath $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    try { Set-Acl -LiteralPath $OutputFolder -AclObject (New-MergeFolderSecurity) -ErrorAction Stop }
    catch { Write-Warning ('Could not limit access to ' + $OutputFolder + ': ' + $_.Exception.Message + '. The overview combines findings from every server; restrict the folder by hand.') }
} else {
    $readers = @(Get-BroadFolderReader $OutputFolder)
    if ($readers.Count -gt 0) { Write-Warning ('The output folder ' + $OutputFolder + ' can be read by ' + ($readers -join ', ') + '. The overview combines findings from every server; use a folder only the team can read.') }
}

# SPECIAL (assessment 4.5.0, #152): a cluster node or domain controller with
# its own plan - listed first.
$rank = @{ SPECIAL=0; BLOCKER=1; ACTION=2; WARNING=3; MANUAL=4; OK=5 }
function Encode([object]$v) { if ($null -eq $v) { return '' }; return [System.Net.WebUtility]::HtmlEncode([string]$v) }

# CSV cells are opened in Excel. A value taken from a server (application
# name, task, hostname) that starts with = + - @ or a tab/CR would be run as
# a formula, so it is prefixed with an apostrophe (OWASP CSV injection).
function Get-CompletedUtc {
    # Completed is local time on the server. With the UtcOffset the collector
    # writes (+02:00) it becomes UTC, so results from servers in different time
    # zones sort as dates. Older files have no offset: their local time is
    # compared as it is, as before. An unreadable time sorts oldest.
    param([string]$Completed, [string]$UtcOffset)
    $dt = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($Completed, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dt)) { return [datetime]::MinValue }
    if ($UtcOffset -match '^[+-]\d{2}:\d{2}$') {
        $offset = [TimeSpan]::Parse($UtcOffset.TrimStart('+'))
        return (New-Object DateTimeOffset($dt, $offset)).UtcDateTime
    }
    return $dt
}

function Save-CsvFile {
    # UTF-8 with a byte-order mark on every host: Export-Csv -Encoding UTF8
    # writes one on Windows PowerShell 5.1 but not on PowerShell 7, and Excel
    # then reads the file as ANSI and garbles the Danish letters (#252).
    param($Rows, [string]$Path, [string]$Delimiter)
    # No rows (for example no findings) gives an empty file, as Export-Csv did.
    $lines = @()
    $list = @($Rows | Where-Object { $null -ne $_ })
    if ($list.Count -gt 0) { $lines = @($list | ConvertTo-Csv -Delimiter $Delimiter -NoTypeInformation) }
    [IO.File]::WriteAllLines($Path, $lines, (New-Object System.Text.UTF8Encoding($true)))
}

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
$eolBySource = @{}
foreach ($f in $files) {
    try { $r = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { $unreadable += $f.Name; continue }
    if ($r.Schema -ne 'IPU-Assessment/1') { $unreadable += ($f.Name + ' (unknown schema)'); continue }
    if ($Mode -ne 'All' -and $r.Mode -ne $Mode) { continue }

    $top = @($r.Results | Where-Object { $_.Kind -eq 'Finding' -and $_.Status -in @('SPECIAL','BLOCKER','ACTION') } |
        Sort-Object @{Expression={ $rank[[string]$_.Status] }},Item | ForEach-Object { $_.Status + ': ' + $_.Item })
    # The products with an end-of-life date that the server found (#286) and the EOL rows its own report already has (#275).
    $eolCandidates = @(); if ($r.PSObject.Properties['EolCandidates']) { $eolCandidates = @($r.EolCandidates) }
    $eolBySource[$f.Name] = [pscustomobject]@{ ComputerName = $r.ComputerName; Candidates = $eolCandidates; Items = @($r.Results | Where-Object { [string]$_.Item -like 'EOL: *' } | ForEach-Object { [string]$_.Item }) }
    $notCompleted = @($r.CheckRuns | Where-Object { $_.Outcome -ne 'Completed' -and $_.Outcome -ne 'Skipped' } | ForEach-Object { $_.Name + ' (' + $_.Outcome + ')' })
    $servers.Add([pscustomobject][ordered]@{
        ComputerName     = $r.ComputerName
        Mode             = $r.Mode
        Overall          = $r.Overall
        Special          = $(if ($r.Counts.PSObject.Properties['SPECIAL']) { [int]$r.Counts.SPECIAL } else { 0 })
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
        Nla              = $(if ($r.Facts.PSObject.Properties['Nla']) { [string]$r.Facts.Nla } else { '' })
        TopIssues        = ($top -join ' | ')
        NotAssessed      = ($notCompleted -join ' | ')
        Partial          = [bool]$r.Partial
        Redacted         = [bool]$r.Redacted
        Completed        = $r.Completed
        UtcOffset        = $(if ($r.PSObject.Properties['UtcOffset']) { [string]$r.UtcOffset } else { '' })
        CollectorVersion = $r.CollectorVersion
        SourceFile       = $f.Name
    })
    foreach ($x in @($r.Results | Where-Object { $_.Kind -eq 'Finding' -and $_.Status -in @('SPECIAL','BLOCKER','ACTION','WARNING','MANUAL') })) {
        $findings.Add([pscustomobject][ordered]@{
            ComputerName = $r.ComputerName; Mode = $r.Mode; Status = $x.Status; Area = $x.Area; Item = $x.Item
            Value = $x.Value; Details = $x.Details; Recommendation = $x.Recommendation; Command = [string]$x.Command; Link = [string]$x.Link; SourceFile = $f.Name
        })
    }
}

# A redacted copy (-RedactExisting, -RedactReport) carries placeholder names
# (HOST-1), so it cannot be matched to the original it was made from, and
# next to that original it would show the same server twice (#138). When the
# folder has original results, redacted copies are skipped and counted;
# -IncludeRedacted keeps them. A folder with only redacted results (copies sent
# in by someone else) is used as it is.
$skippedRedacted = 0
$redactedResults = @($servers | Where-Object { $_.Redacted })
if (-not $IncludeRedacted -and $redactedResults.Count -gt 0 -and $redactedResults.Count -lt $servers.Count) {
    $skippedRedacted = $redactedResults.Count
    $servers = New-Object System.Collections.Generic.List[object] (, @($servers | Where-Object { -not $_.Redacted }))
}

# If a server has several results for the same mode, keep the newest.
# Redacted results all carry placeholder names (HOST-1), so each redacted
# file is kept as its own row instead of being merged with others.
$latest = @($servers | Group-Object { if ($_.Redacted) { 'redacted|' + $_.SourceFile } else { $_.ComputerName + '|' + $_.Mode } } | ForEach-Object { $_.Group | Sort-Object @{Expression={ Get-CompletedUtc $_.Completed $_.UtcOffset }} -Descending | Select-Object -First 1 })
$latest = @($latest | Sort-Object @{Expression={ $rank[[string]$_.Overall] }},ComputerName)
# Findings come only from the result each server/mode row was taken from,
# never from an older, superseded result for the same server.
$keep = @{}; foreach ($s in $latest) { $keep[$s.SourceFile] = $true }
$fleetFindings = @($findings | Where-Object { $keep.ContainsKey($_.SourceFile) } | Sort-Object @{Expression={ $rank[[string]$_.Status] }},ComputerName,Item)

# End-of-life verdicts (#275, ADR 0003): the products the servers found, compared with a
# local snapshot. Without a readable snapshot they are listed as not checked, never as supported.
$today = Get-Date
$eolSnapshotPath = Find-EolSnapshotFile $EolSnapshot @($PSScriptRoot, $InputFolder)
$eolData = $null; $eolNote = ''; $eolAsOf = ''
if ($eolSnapshotPath) {
    try {
        $eolData = Get-Content -LiteralPath $eolSnapshotPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $eolAsOf = $eolData.asOf
        if ($eolAsOf -is [datetime]) { $eolAsOf = $eolAsOf.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
        $eolAsOf = [string]$eolAsOf
        $eolAge = Get-EolSnapshotAge -AsOf $eolAsOf -Today $today -MaxAgeMonths 6
        if ($eolAge.State -ne 'Fresh') { $eolNote = $eolAge.Text + ' A snapshot this old cannot confirm that a product is still supported (MANUAL); end-of-life verdicts still show.' }
    } catch { $eolData = $null; $eolNote = 'The end-of-life snapshot ' + $eolSnapshotPath + ' could not be read: ' + $_.Exception.Message + ' The products are listed but not checked.' }
} else {
    $eolNote = 'No eol-snapshot.json found (looked next to this script and in the input folder; -EolSnapshot names one). The products are listed but not checked.'
}
$eolServers = @(); foreach ($s in $latest) { if ($eolBySource.ContainsKey($s.SourceFile)) { $eolServers += $eolBySource[$s.SourceFile] } }
$eolRows = @(Get-EolFleetRow $eolServers $eolData $today)
foreach ($s in $latest) {
    $e = $eolBySource[$s.SourceFile]
    $s | Add-Member -NotePropertyName EndOfLifeProducts -NotePropertyValue (Get-EolServerSummary $e.Candidates $eolData $today) -Force
    # Findings the server's own report did not already have (it had no snapshot on the server).
    foreach ($x in @(Get-EolServerFinding $e.Candidates $e.Items $eolData $today)) {
        $fleetFindings += [pscustomobject][ordered]@{ ComputerName = $s.ComputerName; Mode = $s.Mode; Status = $x.Status; Area = $x.Area; Item = $x.Item; Value = $x.Value; Details = $x.Details; Recommendation = $x.Recommendation; Command = ''; Link = ''; SourceFile = $s.SourceFile }
    }
}
$fleetFindings = @($fleetFindings | Sort-Object @{Expression={ $rank[[string]$_.Status] }},ComputerName,Item)

$serversCsv = Join-Path $OutputFolder 'IPU-Fleet-Servers.csv'
$findingsCsv = Join-Path $OutputFolder 'IPU-Fleet-Findings.csv'
$eolCsv = Join-Path $OutputFolder 'IPU-Fleet-Eol.csv'
$htmlPath = Join-Path $OutputFolder 'IPU-Fleet-Overview.html'
# UtcOffset is for sorting only; a leading + would be shown as an apostrophe-prefixed cell.
Save-CsvFile ($latest | Select-Object -Property * -ExcludeProperty UtcOffset | ConvertTo-CsvSafeRow) $serversCsv $Delimiter
Save-CsvFile ($fleetFindings | ConvertTo-CsvSafeRow) $findingsCsv $Delimiter
Save-CsvFile ($eolRows | ConvertTo-CsvSafeRow) $eolCsv $Delimiter

# Most common blocking/action items across the fleet.
$common = @($fleetFindings | Where-Object { $_.Status -in @('SPECIAL','BLOCKER','ACTION') } | Group-Object Status,Item | Sort-Object @{Expression={ $rank[[string]$_.Group[0].Status] }},@{Expression='Count';Descending=$true} | Select-Object -First 15)
$overallCounts = @{}; foreach ($k in @('SPECIAL','BLOCKER','ACTION','WARNING','MANUAL','OK')) { $overallCounts[$k] = @($latest | Where-Object { $_.Overall -eq $k }).Count }

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>IPU Fleet Overview</title>')
[void]$sb.AppendLine(@'
<style>
:root{--ink:#16202e;--muted:#5d6a79;--line:#dde3ea;--bg:#f3f5f8;--navy:#16365f;--special:#0f4c5c;--blocker:#7a1717;--action:#b42318;--warning:#9a5800;--manual:#5b47a0;--ok:#17703a}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:13px/1.45 "Segoe UI",Arial,sans-serif}
.wrap{max-width:1600px;margin:auto;padding:24px 16px}h1{margin:0 0 4px;font-size:22px;color:#fff}.hero{background:var(--navy);color:#d5e1ee;padding:20px 24px;border-radius:12px}
.cards{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:10px;margin:14px 0}.card{background:#fff;border:1px solid var(--line);border-radius:10px;padding:10px 14px}.card b{display:block;font-size:22px}.card small{color:var(--muted);text-transform:uppercase;font-size:11px;letter-spacing:.04em}
section{background:#fff;border:1px solid var(--line);border-radius:10px;margin:14px 0;padding:16px 18px}h2{margin:0 0 10px;font-size:17px;color:var(--navy)}
.scroll{overflow-x:auto}table{border-collapse:collapse;width:100%;min-width:1100px}th,td{text-align:left;vertical-align:top;border-bottom:1px solid var(--line);padding:6px 8px}th{background:#eef2f7;font-size:11px;text-transform:uppercase;letter-spacing:.04em;color:#30475f}
.badge{display:inline-block;color:#fff;font-weight:700;font-size:11px;padding:2px 8px;border-radius:999px}.s-special{background:var(--special)}.s-blocker{background:var(--blocker)}.s-action{background:var(--action)}.s-warning{background:var(--warning)}.s-manual{background:var(--manual)}.s-ok{background:var(--ok)}
.muted{color:var(--muted)}.nw{white-space:nowrap}
@media(max-width:900px){.cards{grid-template-columns:repeat(2,1fr)}}
</style></head><body><div class="wrap">
'@)
[void]$sb.AppendLine('<div class="hero"><h1>IPU Fleet Overview</h1><p>' + $latest.Count + ' servers &nbsp;|&nbsp; Generated ' + (Get-Date).ToString('yyyy-MM-dd HH:mm') + ' &nbsp;|&nbsp; Source: ' + (Encode $InputFolder) + '</p></div>')
[void]$sb.AppendLine('<div class="cards">')
foreach ($k in @('SPECIAL','BLOCKER','ACTION','WARNING','MANUAL','OK')) { if ($k -eq 'SPECIAL' -and $overallCounts[$k] -eq 0) { continue }; [void]$sb.AppendLine('<div class="card"><small>Overall ' + $k + '</small><b>' + $overallCounts[$k] + '</b></div>') }
[void]$sb.AppendLine('</div>')
if ($unreadable.Count -gt 0) { [void]$sb.AppendLine('<section><h2>Files not read</h2><p>' + (Encode ($unreadable -join ', ')) + '</p></section>') }

[void]$sb.AppendLine('<section><h2>Servers (worst first)</h2><div class="scroll"><table><thead><tr><th>Server</th><th>Mode</th><th>Overall</th><th>B/A/W/M</th><th>Current OS</th><th>Target</th><th>Media</th><th>Platform</th><th>RDP NLA</th><th>SQL</th><th>Top issues</th><th>Not assessed</th><th>Completed</th></tr></thead><tbody>')
foreach ($s in $latest) {
    $badge = '<span class="badge s-' + ([string]$s.Overall).ToLowerInvariant() + '">' + (Encode $s.Overall) + '</span>'
    if ($s.Partial) { $badge += ' <span class="muted">partial</span>' }
    if ($s.Redacted) { $badge += ' <span class="muted">redacted</span>' }
    [void]$sb.AppendLine('<tr><td class="nw"><b>' + (Encode $s.ComputerName) + '</b></td><td>' + (Encode $s.Mode) + '</td><td class="nw">' + $badge + '</td><td class="nw">' + $s.Blocker + '/' + $s.Action + '/' + $s.Warning + '/' + $s.Manual + '</td><td>' + (Encode $s.CurrentOS) + '</td><td class="nw">' + (Encode $s.Target) + '</td><td>' + (Encode $s.InstallationMedia) + '</td><td>' + (Encode $s.Platform) + '</td><td class="nw">' + (Encode $s.Nla) + '</td><td>' + (Encode $s.SqlServer) + '</td><td>' + (Encode $s.TopIssues) + '</td><td>' + (Encode $s.NotAssessed) + '</td><td class="nw muted">' + (Encode $s.Completed) + '</td></tr>')
}
[void]$sb.AppendLine('</tbody></table></div></section>')

# End-of-life products (#275): the verdict per product and version, the snapshot date and the attribution (ADR 0003).
[void]$sb.AppendLine('<section><h2>End-of-life products</h2>')
if ($eolRows.Count -eq 0) {
    [void]$sb.AppendLine('<p class="muted">No server reported a product with an end-of-life date. Servers assessed before version 4.6.0 do not report them, and a product that is not found is not listed.</p>')
} else {
    [void]$sb.AppendLine('<div class="scroll"><table><thead><tr><th>Status</th><th>Product</th><th>Version</th><th>Release</th><th>End of life</th><th>Servers</th><th>Which</th><th>Verdict</th></tr></thead><tbody>')
    foreach ($row in $eolRows) {
        [void]$sb.AppendLine('<tr><td><span class="badge s-' + ([string]$row.Status).ToLowerInvariant() + '">' + (Encode $row.Status) + '</span></td><td>' + (Encode $row.Product) + '</td><td>' + (Encode $row.Version) + '</td><td>' + (Encode $row.Release) + '</td><td class="nw">' + (Encode $row.EndOfLife) + '</td><td>' + $row.ServerCount + '</td><td>' + (Encode $row.Servers) + '</td><td>' + (Encode $row.Text) + '</td></tr>')
    }
    [void]$sb.AppendLine('</tbody></table></div>')
}
if ($eolNote) { [void]$sb.AppendLine('<p><b>Note:</b> ' + (Encode $eolNote) + '</p>') }
if ($eolData) { [void]$sb.AppendLine('<p class="muted">Snapshot from ' + (Encode $eolAsOf) + '. ' + (Encode $script:EolAttribution) + '</p>') }
[void]$sb.AppendLine('</section>')

if ($common.Count -gt 0) {
    [void]$sb.AppendLine('<section><h2>Most common SPECIAL/BLOCKER/ACTION items</h2><div class="scroll"><table><thead><tr><th>Status</th><th>Item</th><th>Servers</th><th>Which</th></tr></thead><tbody>')
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
if ($skippedRedacted -gt 0) { 'Redacted files skipped: {0} (the folder has the original results; use -IncludeRedacted to keep them)' -f $skippedRedacted }
'Written: ' + $htmlPath
'Written: ' + $serversCsv
'Written: ' + $findingsCsv
'Written: ' + $eolCsv
if ($eolNote) { 'End-of-life: ' + $eolNote }
