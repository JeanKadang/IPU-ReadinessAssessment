<#
    Lists issues that were closed as completed while their task list still has
    unchecked boxes (#263). A closed-as-completed issue with an open criterion
    is either unfinished work or a box nobody ticked; both are easy to miss.
    The scheduled "Closure gate" workflow runs it weekly and keeps one issue up
    to date with the result. Issues closed as not planned or as a duplicate are
    ignored: their open boxes are expected.

    -InputPath reads the issues from a JSON file (the output of
    gh issue list --state closed --json number,title,body,stateReason,closedAt,
    url) instead of calling gh; the tests use it.
#>
[CmdletBinding()]
param(
    [string]$InputPath,
    [string]$ReportPath,
    [int]$Limit = 1000
)

function Get-UncheckedCriterion {
    # Pure: the unchecked task-list lines of an issue body. Boxes inside a code
    # fence (an example in the text) are not criteria.
    param([AllowNull()][string]$Body)
    if (-not $Body) { return @() }
    $plain = [regex]::Replace($Body, '(?s)(```|~~~).*?(\1|\z)', '')
    return @([regex]::Matches($plain, '(?m)^[ \t]*[-*][ \t]+\[ \][ \t]+(\S.*?)[ \t]*\r?$') | ForEach-Object { $_.Groups[1].Value })
}

function Find-UncheckedClosedIssue {
    # Pure: closed-as-completed issues that still have unchecked criteria,
    # oldest closure first. An issue closed with no recorded reason (older
    # data) counts as completed.
    param([object[]]$Issues)
    $rows = foreach ($i in @($Issues)) {
        if ($i.stateReason -and $i.stateReason -ne 'COMPLETED') { continue }
        $open = @(Get-UncheckedCriterion $i.body)
        if ($open.Count -eq 0) { continue }
        [pscustomobject]@{
            Number    = [int]$i.number
            Title     = [string]$i.title
            Closed    = $(if ($i.closedAt -is [datetime]) { $i.closedAt.ToUniversalTime().ToString('s') } else { [string]$i.closedAt })
            Url       = [string]$i.url
            Unchecked = $open
        }
    }
    return @($rows | Sort-Object Closed, Number)
}

function Format-UncheckedClosedReport {
    # Pure: the markdown body of the tracking issue.
    param([object[]]$Rows)
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('Issues closed as completed while their task list still has unchecked boxes. Tick the box if the work is done, or reopen the issue, or move the open item to a new issue and tick it with a link. This list is rewritten every week by the "Closure gate" workflow; when it is empty this issue closes itself.')
    $lines.Add('')
    foreach ($r in @($Rows)) {
        $day = if ($r.Closed.Length -ge 10) { $r.Closed.Substring(0, 10) } else { $r.Closed }
        $lines.Add(('- #{0} {1} (closed {2}, {3} unchecked)' -f $r.Number, $r.Title, $day, @($r.Unchecked).Count))
        foreach ($u in @($r.Unchecked | Select-Object -First 5)) { $lines.Add('  - ' + $u) }
        if (@($r.Unchecked).Count -gt 5) { $lines.Add(('  - ... and {0} more' -f (@($r.Unchecked).Count - 5))) }
    }
    return ($lines -join "`n")
}

if ($MyInvocation.InvocationName -eq '.') { return }

$ErrorActionPreference = 'Stop'
if ($InputPath) {
    $issues = @(Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json)
} else {
    $json = & gh issue list --state closed --limit $Limit --json 'number,title,body,stateReason,closedAt,url'
    if ($LASTEXITCODE -ne 0) { throw 'gh issue list failed' }
    $issues = @($json | ConvertFrom-Json)
}
$rows = @(Find-UncheckedClosedIssue $issues)
Write-Output ('{0} closed issue(s) checked, {1} completed with unchecked boxes.' -f $issues.Count, $rows.Count)
if ($ReportPath) { [IO.File]::WriteAllText($ReportPath, (Format-UncheckedClosedReport $rows) + "`n", (New-Object Text.UTF8Encoding($false))) }
foreach ($r in $rows) { Write-Output ('#{0} {1}' -f $r.Number, $r.Title) }
if ($env:GITHUB_OUTPUT) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value ('count=' + $rows.Count) }
