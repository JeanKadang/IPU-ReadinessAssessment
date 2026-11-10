<#
    Compares docs/roadmap.md with the open issues (#395). The page is a
    hand-written copy of the open issues per milestone, with priority and
    owner; it went stale three times (#302, #347, #395). The scheduled
    "Roadmap drift" workflow runs this weekly and keeps one issue up to date
    with the differences.

    Compared per issue: listed or not, milestone, priority label (P0 to P3)
    and owner (an assignee). Titles are not compared: the page may shorten
    them. Open issues without a milestone are not expected on the page.

    -InputPath reads the issues from a JSON file (the output of
    gh issue list --state open --json number,title,labels,assignees,milestone,
    url) instead of calling gh; the tests use it.
#>
[CmdletBinding()]
param(
    [string]$RoadmapPath,
    [string]$InputPath,
    [string]$ReportPath,
    [int]$Limit = 1000
)

function ConvertFrom-RoadmapPage {
    # Pure: the issue rows of the roadmap page. A row belongs to the "## "
    # heading above it (the milestone). Row shape:
    # | [#12](url) | P2 | owner | title |
    param([AllowNull()][string]$Text)
    $rows = New-Object Collections.Generic.List[object]
    if (-not $Text) { return @() }
    $milestone = ''
    foreach ($line in ($Text -split '\r?\n')) {
        $h = [regex]::Match($line, '^##[ \t]+(.+?)[ \t]*$')
        if ($h.Success) { $milestone = $h.Groups[1].Value; continue }
        $r = [regex]::Match($line, '^\|[ \t]*\[#(\d+)\]\([^)]*\)[ \t]*\|([^|]*)\|([^|]*)\|')
        if (-not $r.Success) { continue }
        $rows.Add([pscustomobject]@{
                Number    = [int]$r.Groups[1].Value
                Milestone = $milestone
                Priority  = $r.Groups[2].Value.Trim()
                Owner     = $r.Groups[3].Value.Trim()
            })
    }
    return @($rows.ToArray())
}

function Find-RoadmapDrift {
    # Pure: one row per difference between the page and the open issues,
    # by issue number. An open issue without a milestone is ignored.
    param([object[]]$PageRows, [object[]]$Issues)
    $open = @{}
    foreach ($i in @($Issues)) { if ($null -ne $i) { $open[[int]$i.number] = $i } }
    $listed = @{}
    $out = New-Object Collections.Generic.List[object]
    foreach ($p in @($PageRows)) {
        if ($null -eq $p) { continue }
        if ($listed.ContainsKey($p.Number)) {
            $out.Add([pscustomobject]@{ Number = $p.Number; Problem = 'Listed more than once on the page' })
            continue
        }
        $listed[$p.Number] = $true
        if (-not $open.ContainsKey($p.Number)) {
            $out.Add([pscustomobject]@{ Number = $p.Number; Problem = ('Listed under "' + $p.Milestone + '", but the issue is not open') })
            continue
        }
        $i = $open[$p.Number]
        $milestone = ''
        if ($i.milestone) { $milestone = [string]$i.milestone.title }
        if ($milestone -ne $p.Milestone) {
            $where = 'no milestone'
            if ($milestone) { $where = 'milestone "' + $milestone + '"' }
            $out.Add([pscustomobject]@{ Number = $p.Number; Problem = ('Listed under "' + $p.Milestone + '"; the issue has ' + $where) })
        }
        $priority = @(@($i.labels) | ForEach-Object { [string]$_.name } | Where-Object { $_ -match '^P[0-3]$' } | Sort-Object)
        if ($priority.Count -ne 1 -or $priority[0] -ne $p.Priority) {
            $label = 'no priority label'
            if ($priority.Count -gt 0) { $label = 'the label ' + ($priority -join ', ') }
            $out.Add([pscustomobject]@{ Number = $p.Number; Problem = ('Priority on the page is "' + $p.Priority + '"; the issue has ' + $label) })
        }
        $owners = @(@($i.assignees) | ForEach-Object { [string]$_.login } | Where-Object { $_ })
        $pageOwner = $p.Owner
        if ($pageOwner -eq '-') { $pageOwner = '' }
        $same = ($owners.Count -eq 0 -and -not $pageOwner) -or ($pageOwner -and ($owners -contains $pageOwner))
        if (-not $same) {
            $who = 'nobody'
            if ($owners.Count -gt 0) { $who = $owners -join ', ' }
            $out.Add([pscustomobject]@{ Number = $p.Number; Problem = ('Owner on the page is "' + $p.Owner + '"; the issue is assigned to ' + $who) })
        }
    }
    foreach ($n in @($open.Keys)) {
        $i = $open[$n]
        if ($listed.ContainsKey($n) -or -not $i.milestone) { continue }
        $out.Add([pscustomobject]@{ Number = $n; Problem = ('Open in milestone "' + [string]$i.milestone.title + '", but not on the page') })
    }
    return @($out.ToArray() | Sort-Object Number, Problem)
}

function Format-RoadmapDriftReport {
    # Pure: the markdown body of the tracking issue.
    param([object[]]$Rows)
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('`docs/roadmap.md` differs from the open issues. Correct the page (or the issue, when the page is right) in a pull request. This list is rewritten every week by the "Roadmap drift" workflow; when it is empty this issue closes itself.')
    $lines.Add('')
    foreach ($r in @($Rows)) { $lines.Add(('- #{0}: {1}' -f $r.Number, $r.Problem)) }
    return ($lines -join "`n")
}

if ($MyInvocation.InvocationName -eq '.') { return }

$ErrorActionPreference = 'Stop'
if (-not $RoadmapPath) { $RoadmapPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs/roadmap.md' }
$page = @(ConvertFrom-RoadmapPage ([IO.File]::ReadAllText($RoadmapPath)))
if ($page.Count -eq 0) { throw ('No issue rows found in ' + $RoadmapPath + '. Has the table format changed?') }
if ($InputPath) {
    $issues = @(Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json)
} else {
    $json = & gh issue list --state open --limit $Limit --json 'number,title,labels,assignees,milestone,url'
    if ($LASTEXITCODE -ne 0) { throw 'gh issue list failed' }
    $issues = @($json | ConvertFrom-Json)
}
$rows = @(Find-RoadmapDrift $page $issues)
Write-Output ('{0} row(s) on the page, {1} open issue(s), {2} difference(s).' -f $page.Count, $issues.Count, $rows.Count)
if ($ReportPath) { [IO.File]::WriteAllText($ReportPath, (Format-RoadmapDriftReport $rows) + "`n", (New-Object Text.UTF8Encoding($false))) }
foreach ($r in $rows) { Write-Output ('#{0}: {1}' -f $r.Number, $r.Problem) }
if ($env:GITHUB_OUTPUT) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value ('count=' + $rows.Count) }
