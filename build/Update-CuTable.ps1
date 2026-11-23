<#
    Refreshes src/cu-table.json, the table of Windows Server cumulative updates
    (build and update revision to KB number, release date, update type), from
    Microsoft's "Windows Server release information" page (#267, #459).

    Only facts are kept: build, UBR, KB number, date and update type. Run by the
    "CU table" workflow after Patch Tuesday; a maintainer reviews the pull request.
    Windows Server 2012 R2 is not on that page, so the table does not cover it
    and the assessment reports it as "not in the table" (INFO).

    Dot-source with -LibraryOnly to load the functions without fetching (tests).
#>
[CmdletBinding()]
param(
    [string]$Path = 'src/cu-table.json',
    [string]$Url = 'https://learn.microsoft.com/en-us/windows/release-health/windows-server-release-info',
    # Read the page from a file instead of fetching it (tests, offline use).
    [string]$InputFile = '',
    [switch]$LibraryOnly
)

$ErrorActionPreference = 'Stop'

function ConvertFrom-ReleaseHealthMarkdown {
    # Pure: the markdown of the release information page -> the table object
    # (schema IPU-CuTable/1). A row is a table line with an availability date,
    # a build with its UBR (20348.5870) and a KB link. The update type comes
    # from the "2026-11 B" or "2026.01 B" label in the same line (B monthly,
    # OOB out of band, C and D previews, A and E the other labels the page
    # uses). Rows without a KB number or an update type are left out. Hotpatch
    # rows are included: a server can be on one. Sorted, so a refresh with no
    # change gives the same text.
    param([string]$Markdown, [datetime]$Today = (Get-Date), [string]$Source = '')
    $releases = @{}
    foreach ($line in ($Markdown -split "`r?`n")) {
        if ($line -notmatch '^\|') { continue }
        if ($line -notmatch '\|\s*(\d{4}-\d{2}-\d{2})\s*\|\s*(\d{4,5})\.(\d{1,6})\s*\|[^|]*?(KB\d{6,8})') { continue }
        $date = $Matches[1]; $build = $Matches[2]; $ubr = [int]$Matches[3]; $kb = $Matches[4]
        if ($line -notmatch '\b\d{4}[-.]\d{2}\s+(B|OOB|C|D|A|E)\b') { continue }
        $type = $Matches[1]
        if (-not $releases.ContainsKey($build)) { $releases[$build] = @{} }
        if (-not $releases[$build].ContainsKey($ubr)) { $releases[$build][$ubr] = [pscustomobject]@{ ubr = $ubr; kb = $kb; released = $date; type = $type } }
    }
    $sorted = [ordered]@{}
    foreach ($build in @($releases.Keys | Sort-Object { [int]$_ })) {
        $sorted[$build] = @($releases[$build].Values | Sort-Object ubr)
    }
    return [pscustomobject][ordered]@{
        schema   = 'IPU-CuTable/1'
        asOf     = $Today.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        source   = $Source
        note     = 'Facts only (build, update revision, KB number, release date, update type) read from Microsoft Learn, Windows Server release information. Windows Server 2012 R2 is not on that page and is not covered.'
        releases = [pscustomobject]$sorted
    }
}

function ConvertTo-CuDay {
    # A date as yyyy-MM-dd text; ConvertFrom-Json gives a [datetime] on PowerShell 7.
    param($Value)
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
    return [string]$Value
}

function Get-CuTableRowKey {
    # Pure: every row as one comparable text line, whatever the date type.
    param($Table)
    $keys = @()
    foreach ($p in @($Table.releases.PSObject.Properties)) {
        foreach ($r in @($p.Value)) { $keys += ($p.Name + '.' + $r.ubr + '|' + $r.kb + '|' + (ConvertTo-CuDay $r.released) + '|' + $r.type) }
    }
    return @($keys | Sort-Object)
}

function ConvertTo-CuTableJson {
    # Pure: the table object as JSON text, one row per line so a pull request
    # shows only the rows that changed. ASCII, LF line endings.
    param($Table)
    $lines = @('{')
    $lines += '  "schema": "' + $Table.schema + '",'
    $lines += '  "asOf": "' + (ConvertTo-CuDay $Table.asOf) + '",'
    $lines += '  "source": "' + $Table.source + '",'
    $lines += '  "note": "' + $Table.note + '",'
    $lines += '  "releases": {'
    $builds = @($Table.releases.PSObject.Properties)
    for ($b = 0; $b -lt $builds.Count; $b++) {
        $lines += '    "' + $builds[$b].Name + '": ['
        $rows = @($builds[$b].Value)
        for ($r = 0; $r -lt $rows.Count; $r++) {
            $comma = ','; if ($r -eq $rows.Count - 1) { $comma = '' }
            $lines += '      { "ubr": ' + $rows[$r].ubr + ', "kb": "' + $rows[$r].kb + '", "released": "' + (ConvertTo-CuDay $rows[$r].released) + '", "type": "' + $rows[$r].type + '" }' + $comma
        }
        $comma = ','; if ($b -eq $builds.Count - 1) { $comma = '' }
        $lines += '    ]' + $comma
    }
    $lines += '  }'
    $lines += '}'
    return (($lines -join "`n") + "`n")
}

function Get-CuTableRefreshDecision {
    # Pure: is the freshly read table worth a pull request? Only when the rows
    # changed; the date alone does not make a pull request. Fewer rows than the
    # current table is an error, never a refresh: a changed page layout must not
    # silently shrink the table.
    param($Current, $Fetched)
    $count = { param($t) $n = 0; foreach ($p in @($t.releases.PSObject.Properties)) { $n += @($p.Value).Count }; $n }
    $now = & $count $Fetched
    if ($now -eq 0) { return [pscustomobject]@{ Action = 'Fail'; Reason = 'No rows were read from the page; its layout may have changed.' } }
    if ($null -eq $Current) { return [pscustomobject]@{ Action = 'PullRequest'; Reason = ('First table: ' + $now + ' rows.') } }
    $before = & $count $Current
    if ($now -lt $before) { return [pscustomobject]@{ Action = 'Fail'; Reason = ('The page gave ' + $now + ' rows, the table has ' + $before + '. Not replaced; check the page layout.') } }
    $a = (Get-CuTableRowKey $Current) -join "`n"
    $b = (Get-CuTableRowKey $Fetched) -join "`n"
    if ($a -eq $b) { return [pscustomobject]@{ Action = 'None'; Reason = ('No new update; the table has ' + $before + ' rows.') } }
    return [pscustomobject]@{ Action = 'PullRequest'; Reason = ('The table grows from ' + $before + ' to ' + $now + ' rows, or its rows changed.') }
}

if (-not $LibraryOnly) {
    if ($InputFile) {
        $markdown = [IO.File]::ReadAllText($InputFile)
    } else {
        $response = Invoke-WebRequest -Uri $Url -Headers @{ Accept = 'text/markdown' } -UseBasicParsing
        $markdown = [string]$response.Content
        if ($response.Content -is [byte[]]) { $markdown = [Text.Encoding]::UTF8.GetString($response.Content) }
    }
    $fetched = ConvertFrom-ReleaseHealthMarkdown -Markdown $markdown -Today (Get-Date) -Source $Url
    $current = $null
    if (Test-Path -LiteralPath $Path) { $current = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    $decision = Get-CuTableRefreshDecision -Current $current -Fetched $fetched
    Write-Output ('CU table: ' + $decision.Action + ' - ' + $decision.Reason)
    if ($env:GITHUB_OUTPUT) {
        'action=' + $decision.Action | Out-File -Append -FilePath $env:GITHUB_OUTPUT -Encoding utf8
        'reason=' + $decision.Reason | Out-File -Append -FilePath $env:GITHUB_OUTPUT -Encoding utf8
    }
    if ($decision.Action -eq 'Fail') { throw $decision.Reason }
    if ($decision.Action -eq 'PullRequest') {
        [IO.File]::WriteAllText((Join-Path (Get-Location) $Path), (ConvertTo-CuTableJson $fetched), (New-Object System.Text.UTF8Encoding($false)))
    }
}
