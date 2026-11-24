# =============================================================================
# 4b. CUMULATIVE UPDATE TABLE (#267, #457)
# =============================================================================
# The table maps a build and its update revision (UBR) to the monthly
# cumulative update: KB number, release date, months behind the newest one.
# It is a data file next to the script (cu-table.json), read like
# eol-snapshot.json, so the monthly refresh needs no script release. Pure
# functions only; reading the file and the registry is done by the check.

function ConvertTo-CuDateText {
    # A date as yyyy-MM-dd text. ConvertFrom-Json gives a [datetime] on
    # PowerShell 7 and a string on Windows PowerShell 5.1, so both are handled.
    # Returns '' for anything that is not a calendar date.
    param($Value)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd', $inv) }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParseExact([string]$Value, 'yyyy-MM-dd', $inv, [Globalization.DateTimeStyles]::None, [ref]$parsed)) { return $parsed.ToString('yyyy-MM-dd', $inv) }
    return ''
}

function Get-CuTableSearchPath {
    # Pure: where the assessment looks for cu-table.json. An explicit
    # -CuTablePath comes first (a folder gets the file name added), then the
    # script's folder, then the report folder. Same order as the EOL snapshot.
    param([string]$Explicit, [string]$ScriptFolder, [string]$ReportFolder)
    $paths = @()
    if ($Explicit) {
        if ($Explicit -match '\.json$') { $paths += $Explicit } else { $paths += [IO.Path]::Combine($Explicit, 'cu-table.json') }
    }
    foreach ($folder in @($ScriptFolder, $ReportFolder)) {
        if ($folder) { $paths += [IO.Path]::Combine($folder, 'cu-table.json') }
    }
    return @($paths | Select-Object -Unique)
}

function Test-CuTableContent {
    # Pure: what is wrong with a table that was read from cu-table.json.
    # Returns the problems as text; an empty list means usable. A table with a
    # row that cannot be used is rejected as a whole, never half read: a
    # missing row would otherwise look like a server that is not in the table.
    param($Table)
    $problems = @()
    if ($null -eq $Table) { return @('The table is empty.') }
    if ([string]$Table.schema -ne 'IPU-CuTable/1') { $problems += ('Unknown schema "' + [string]$Table.schema + '", expected IPU-CuTable/1.') }
    if (-not (ConvertTo-CuDateText $Table.asOf)) { $problems += 'asOf is not a date (yyyy-MM-dd).' }
    if (-not $Table.releases) { return @($problems + 'There is no releases list.') }
    foreach ($release in @($Table.releases.PSObject.Properties)) {
        if ($release.Name -notmatch '^\d{4,5}$') { $problems += ('"' + $release.Name + '" is not a build number.'); continue }
        $rows = @($release.Value)
        if ($rows.Count -eq 0) { $problems += ('Build ' + $release.Name + ' has no rows.'); continue }
        $seen = @{}
        foreach ($row in $rows) {
            $ubr = 0
            $ubrText = [string]$row.ubr
            if ($ubrText -notmatch '^\d{1,6}$' -or -not [int]::TryParse($ubrText, [ref]$ubr)) { $problems += ('Build ' + $release.Name + ': ubr "' + $ubrText + '" is not a number.'); continue }
            $label = 'Build ' + $release.Name + '.' + $ubr
            if ($seen.ContainsKey($ubr)) { $problems += ($label + ' is listed twice.') }
            $seen[$ubr] = $true
            if ([string]$row.kb -notmatch '^KB\d{6,8}$') { $problems += ($label + ': kb "' + [string]$row.kb + '" is not like KB1234567.') }
            if (-not (ConvertTo-CuDateText $row.released)) { $problems += ($label + ': released is not a date (yyyy-MM-dd).') }
            if ($row.PSObject.Properties['type'] -and @('B', 'OOB', 'C', 'D', 'A', 'E') -notcontains [string]$row.type) { $problems += ($label + ': type "' + [string]$row.type + '" is not B, OOB, C, D, A or E.') }
        }
    }
    return @($problems)
}

function Get-CumulativeUpdateLookup {
    # Pure (#267): the build and UBR of the server against the table.
    #   $Table     the table read from cu-table.json, or $null when there is none
    #   $BuildText "<build>.<ubr>", e.g. 20348.2113, as the patch level check builds it
    # Kind says what was found:
    #   Found       the build and UBR are in the table; Kb, Released, Month and
    #               MonthsBehind (calendar months to the newest monthly release in
    #               the table for the same build; 0 = the newest) are set
    #   UnknownUbr  the build is in the table, the UBR is not: MANUAL, never OK
    #   NoRelease   the table has no rows for this build (2012 R2, a preview
    #               build, a release the table does not cover): INFO, the update
    #               date from Get-HotFix stays the only age
    #   BadBuild    the build text cannot be read: MANUAL
    #   NoTable     there is no table: INFO
    #   BadTable    the table fails Test-CuTableContent: MANUAL
    # A row type of C or D (preview) or OOB is a release too, so a server on
    # one is Found, but only type B (or no type) counts as "the newest".
    param($Table, [string]$BuildText)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $result = { param($Kind, $Status, $Value, $Details, $Advice) [pscustomobject]@{ Kind = $Kind; Status = $Status; Value = $Value; Details = @($Details); Recommendation = $Advice; Kb = ''; Released = ''; Month = ''; MonthsBehind = $null; NewestKb = ''; NewestUbr = $null; TableDate = '' } }
    if ($null -eq $Table) { return (& $result 'NoTable' 'INFO' 'No cumulative update table found; the cumulative update is not identified' @() 'Copy cu-table.json from the release next to the script (or give -CuTablePath) to have the installed cumulative update identified.') }
    $problems = @(Test-CuTableContent $Table)
    if ($problems.Count -gt 0) { return (& $result 'BadTable' 'MANUAL' 'The cumulative update table could not be used' $problems 'Replace cu-table.json with the copy from the release.') }
    $tableDate = ConvertTo-CuDateText $Table.asOf
    if ($BuildText -notmatch '^(\d{4,5})\.(\d{1,6})$') { return (& $result 'BadBuild' 'MANUAL' 'The build and update revision could not be read' @(('Build=' + $BuildText)) 'Check the installed cumulative update by hand: Settings, Windows Update, Update history, or winver.') }
    $build = $Matches[1]; $ubr = [int]$Matches[2]
    $rowsProperty = $Table.releases.PSObject.Properties[$build]
    if (-not $rowsProperty) {
        $r = & $result 'NoRelease' 'INFO' ('Build ' + $build + ' is not in the cumulative update table') @(('Build=' + $BuildText), ('TableDate=' + $tableDate)) ''
        $r.TableDate = $tableDate
        return $r
    }
    $rows = @($rowsProperty.Value | ForEach-Object { [pscustomobject]@{ Ubr = [int][string]$_.ubr; Kb = [string]$_.kb; Released = (ConvertTo-CuDateText $_.released); Type = $(if ($_.PSObject.Properties['type']) { [string]$_.type } else { 'B' }) } })
    $row = @($rows | Where-Object { $_.Ubr -eq $ubr }) | Select-Object -First 1
    if (-not $row) {
        $r = & $result 'UnknownUbr' 'MANUAL' ('Update revision ' + $BuildText + ' is not in the cumulative update table') @(('Build=' + $BuildText), ('TableDate=' + $tableDate)) 'The table may be older than the update, or the server runs a build that is not a monthly cumulative update. Identify the installed update by hand and compare it with the Microsoft update history.'
        $r.TableDate = $tableDate
        return $r
    }
    $monthly = @($rows | Where-Object { $_.Type -eq 'B' } | Sort-Object Released -Descending)
    $newest = $monthly | Select-Object -First 1
    if (-not $newest -or $newest.Released -lt $row.Released) { $newest = $row }
    $monthIndex = { param([string]$Date) ([int]$Date.Substring(0, 4)) * 12 + ([int]$Date.Substring(5, 2)) }
    $behind = (& $monthIndex $newest.Released) - (& $monthIndex $row.Released)
    $r = & $result 'Found' 'OK' ($row.Kb + ' released ' + $row.Released.Substring(0, 7)) @(('Build=' + $BuildText), ('KB=' + $row.Kb), ('Released=' + $row.Released), ('MonthsBehind=' + $behind.ToString($inv)), ('NewestInTable=' + $newest.Kb + ' (' + $newest.Released + ')'), ('TableDate=' + $tableDate)) ''
    $r.Kb = $row.Kb; $r.Released = $row.Released; $r.Month = $row.Released.Substring(0, 7); $r.MonthsBehind = $behind
    $r.NewestKb = $newest.Kb; $r.NewestUbr = $newest.Ubr; $r.TableDate = $tableDate
    return $r
}

function Get-CumulativeUpdateDecision {
    # Pure (#267, #458): the lookup -> the row to show. A server more than
    # $MaxMonthsBehind monthly releases behind the newest one in the table is a
    # WARNING; an update that cannot be identified is MANUAL; no table, or a
    # build the table does not cover, is only INFO (the update date from
    # Get-HotFix still gives the age). A table older than 60 days says so,
    # because "months behind" is measured against the newest row in it.
    param($Lookup, [int]$MaxMonthsBehind, [datetime]$Now)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $details = @($Lookup.Details)
    $advice = [string]$Lookup.Recommendation
    switch ($Lookup.Kind) {
        'Found' {
            $status = 'OK'; $kind = 'Observation'
            $value = $Lookup.Value
            if ($Lookup.MonthsBehind -gt $MaxMonthsBehind) {
                $status = 'WARNING'; $kind = 'Finding'
                $value = $Lookup.Value + ', ' + $Lookup.MonthsBehind.ToString($inv) + ' months behind'
                $advice = 'Install the latest cumulative update (' + $Lookup.NewestKb + ' or newer) before IPU; Setup and Dynamic Update are most reliable on a current source OS.'
            } elseif ($Lookup.MonthsBehind -gt 0) {
                $value = $Lookup.Value + ', ' + $Lookup.MonthsBehind.ToString($inv) + ' month(s) behind'
            }
            $result = [pscustomobject]@{ Status = $status; Kind = $kind; Value = $value; Details = $details; Recommendation = $advice }
        }
        'NoRelease' { $result = [pscustomobject]@{ Status = 'INFO'; Kind = 'Observation'; Value = $Lookup.Value; Details = $details; Recommendation = 'The age of the patch level comes from the update dates only. Compare the build with the Microsoft update history by hand.' } }
        'NoTable'   { $result = [pscustomobject]@{ Status = 'INFO'; Kind = 'Observation'; Value = $Lookup.Value; Details = $details; Recommendation = $advice } }
        default     { $result = [pscustomobject]@{ Status = $Lookup.Status; Kind = 'Finding'; Value = $Lookup.Value; Details = $details; Recommendation = $advice } }
    }
    if ($Lookup.TableDate -and @('Found', 'NoRelease', 'UnknownUbr') -contains $Lookup.Kind) {
        $tableDay = [datetime]::ParseExact($Lookup.TableDate, 'yyyy-MM-dd', $inv)
        $age = [int][math]::Floor(($Now.Date - $tableDay).TotalDays)
        if ($age -gt 60) { $result.Details = @($result.Details) + ('The table is dated ' + $Lookup.TableDate + ' (' + $age + ' days old); a newer cumulative update than the table knows may exist. Copy cu-table.json from the newest release.') }
    }
    return $result
}
