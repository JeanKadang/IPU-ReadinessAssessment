<#
.SYNOPSIS
    End-of-life status of a product version, from an endoflife.date snapshot.
.DESCRIPTION
    Runs on an analysis machine, never on an assessed server (ADR 0003). It
    matches an installed product version to a lifecycle release and says
    whether that release is supported, only gets security fixes, ends soon or
    has ended.

    The decision (Get-EolDecision) is a pure function: release data and today's
    date in, verdict out. Reading a snapshot file and fetching from
    endoflife.date are kept apart from it, so the verdict is tested without
    network access.

    Based on the proof of concept from pull request #271 (ayushkrsingh946).

    The data comes from endoflife.date, which is released under the MIT
    License (Copyright 2020 endoflife.date contributors). The notice is kept in
    the snapshot file.
.PARAMETER Product
    endoflife.date product identifier, for example mssqlserver or php.
    See $script:EolProducts for the supported list.
.PARAMETER Version
    Installed version, for example 8.2.12 or 13.0.6300.2.
.PARAMETER SnapshotPath
    JSON snapshot: asOf, source and products.<slug> = list of releases.
.PARAMETER Online
    Fetch the releases from endoflife.date when the snapshot has none. For
    analysis machines with internet access only.
.PARAMETER WarnDays
    A release that ends within this many days is reported as ending soon.
.PARAMETER Update
    Fetch every supported product from endoflife.date and write one snapshot
    file to -SnapshotPath. Run it on a machine with internet access, then copy
    the file to where the verdicts are made. Nothing on an assessed server
    does this.
.PARAMETER MaxAgeMonths
    A snapshot older than this is too old to confirm that a release is still
    supported: that verdict becomes MANUAL. End-of-life and ending-soon verdicts
    are still shown, because end dates rarely move earlier.
.EXAMPLE
    .\Get-IPUEolStatus.ps1 -Update -SnapshotPath .\eol-snapshot.json
.EXAMPLE
    .\Get-IPUEolStatus.ps1 -Product php -Version 8.2.12 -SnapshotPath .\eol-snapshot.json
#>
[CmdletBinding()]
param(
    [string]$Product,
    [string]$Version,
    [string]$SnapshotPath,
    [switch]$Online,
    [switch]$Update,
    [int]$WarnDays = 180,
    [int]$MaxAgeMonths = 6
)

$script:EolAttribution = 'End-of-life data from endoflife.date (https://endoflife.date), MIT License, Copyright 2020 endoflife.date contributors.'
# The MIT licence asks that its notice travels with copies of the data, so it is written into every snapshot.
$script:EolLicenseNotice = @(
    'Copyright 2020 endoflife.date contributors'
    'Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:'
    'The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.'
    'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.'
) -join "`n`n"

# endoflife.date identifiers (checked against https://endoflife.date/api/all.json,
# 2026-10-23) and the name shown in a report. Add a product here only after
# checking that its release names are numbers the installed version can match.
$script:EolProducts = [ordered]@{
    'windows-server'             = 'Windows Server'
    'mssqlserver'                = 'Microsoft SQL Server'
    'mysql'                      = 'MySQL'
    'mariadb'                    = 'MariaDB'
    'postgresql'                 = 'PostgreSQL'
    'mongodb'                    = 'MongoDB'
    'oracle-database'            = 'Oracle Database'
    'ibm-db2'                    = 'IBM Db2'
    'redis'                      = 'Redis'
    'apache-http-server'         = 'Apache HTTP Server'
    'tomcat'                     = 'Apache Tomcat'
    'nginx'                      = 'nginx'
    'php'                        = 'PHP'
    'dotnet'                     = '.NET'
    'dotnetfx'                   = '.NET Framework'
    'powershell'                 = 'PowerShell'
    'python'                     = 'Python'
    'nodejs'                     = 'Node.js'
    'eclipse-temurin'            = 'Eclipse Temurin (Java)'
    'oracle-jdk'                 = 'Oracle JDK (Java)'
    'amazon-corretto'            = 'Amazon Corretto (Java)'
    'microsoft-build-of-openjdk' = 'Microsoft Build of OpenJDK (Java)'
    'openssl'                    = 'OpenSSL'
}

# Windows Server build number -> endoflife.date release name. 2008 and
# 2008 R2 are listed there by service pack (the last one Microsoft supported).
$script:EolWindowsBuilds = @{
    '6001' = '2008-sp2'; '6002' = '2008-sp2'; '6003' = '2008-sp2'; '7600' = '2008-r2-sp1'; '7601' = '2008-r2-sp1'
    '9200' = '2012'; '9600' = '2012-r2'; '14393' = '2016'; '17763' = '2019'; '20348' = '2022'; '26100' = '2025'
}
# The names the assessment script uses for a release (Get-WindowsServerRelease).
$script:EolWindowsNames = @{ '2008' = '2008-sp2'; '2008R2' = '2008-r2-sp1'; '2012R2' = '2012-r2' }

function ConvertTo-EolSegment {
    # Pure: "13.0-sp3" -> 13, 0. A release name or version is compared
    # segment by segment, so 1.1 never matches 1.10.
    param([string]$Text)
    if (-not $Text) { return @() }
    $t = $Text.Trim().TrimStart('v', 'V')
    $dash = $t.IndexOf('-')
    if ($dash -ge 0) { $t = $t.Substring(0, $dash) }
    return @($t.Split('.') | Where-Object { $_ -ne '' })
}

function ConvertTo-EolWindowsRelease {
    # Pure: 10.0.20348 (or a bare build number) -> 2022; the script's own
    # names 2008, 2008R2 and 2012R2 -> the endoflife.date names. Anything else
    # is returned unchanged, so a name such as 2022 passes through.
    param([string]$Version)
    if ($script:EolWindowsNames.ContainsKey($Version)) { return $script:EolWindowsNames[$Version] }
    if ($Version -match '^\d+\.\d+\.(\d+)') { $build = $Matches[1] }
    elseif ($Version -match '^\d{4,5}$' -and $script:EolWindowsBuilds.ContainsKey($Version)) { $build = $Version }
    else { return $Version }
    if ($script:EolWindowsBuilds.ContainsKey($build)) { return $script:EolWindowsBuilds[$build] }
    return $Version
}

function Get-EolCycleMatch {
    # Pure: the release whose number is the longest prefix of the version.
    # 8.2.12 matches release 8.2 (not 8); 1.10.3 matches 1.10 (not 1.1).
    param($Cycles, [string]$Version)
    $v = @(ConvertTo-EolSegment $Version)
    $best = $null; $bestLen = 0
    foreach ($c in @($Cycles)) {
        $s = @(ConvertTo-EolSegment ([string]$c.cycle))
        if ($s.Count -eq 0 -or $v.Count -lt $s.Count) { continue }
        $same = $true
        for ($i = 0; $i -lt $s.Count; $i++) { if ($s[$i] -ne $v[$i]) { $same = $false; break } }
        if ($same -and $s.Count -gt $bestLen) { $best = $c; $bestLen = $s.Count }
    }
    return $best
}

function ConvertTo-EolDate {
    # Pure: a snapshot date as text, a DateTime (PowerShell 7 parses
    # ISO dates in JSON itself) or a boolean -> a date, or $null.
    param($Value)
    if ($Value -is [datetime]) { return $Value.Date }
    if ($Value -is [string]) {
        $d = [datetime]::MinValue
        if ([datetime]::TryParseExact($Value, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }
    }
    return $null
}

function Get-EolDecision {
    # Pure: lifecycle releases + installed version + today -> verdict.
    #   State  Supported | SecurityOnly | EndingSoon | EndOfLife | Unknown
    #   Status OK | INFO | WARNING | MANUAL (the report's words)
    # Support runs through the listed day, as in Get-SupportLifecycleDecision.
    # eol=false means no end date is published, which is not "supported
    # forever": the text says so.
    param([string]$Product, [string]$Version, $Cycles, [datetime]$Today, [int]$WarnDays = 180)
    $name = $Product
    if ($script:EolProducts.Contains($Product)) { $name = $script:EolProducts[$Product] }
    $lookup = $Version
    if ($Product -eq 'windows-server') { $lookup = ConvertTo-EolWindowsRelease $Version }
    $result = [ordered]@{ Product = $Product; Name = $name; Version = $Version; Cycle = ''; State = 'Unknown'; Status = 'MANUAL'; EolDate = ''; DaysLeft = $null; Text = '' }
    # Windows Server releases are matched by name: 2012 and 2012-r2 are
    # different releases that a number comparison would not tell apart.
    if ($Product -eq 'windows-server') { $c = @(@($Cycles) | Where-Object { [string]$_.cycle -eq $lookup }) | Select-Object -First 1 }
    else { $c = Get-EolCycleMatch $Cycles $lookup }
    if ($null -eq $c) {
        $result.Text = $name + ' ' + $Version + ' matches no known release. Check the vendor lifecycle page.'
        return [pscustomobject]$result
    }
    $result.Cycle = [string]$c.cycle
    $eol = ConvertTo-EolDate $c.eol
    if ($c.eol -is [bool] -and $c.eol) {
        $result.State = 'EndOfLife'; $result.Status = 'WARNING'
        $result.Text = $name + ' ' + $result.Cycle + ' has reached end of life.'
        return [pscustomobject]$result
    }
    if ($null -eq $eol) {
        $result.State = 'Supported'; $result.Status = 'OK'
        $result.Text = $name + ' ' + $result.Cycle + ': no end-of-life date is published (that is not a promise of support).'
        return [pscustomobject]$result
    }
    $result.EolDate = $eol.ToString('yyyy-MM-dd')
    $days = [int][math]::Floor(($eol - $Today.Date).TotalDays)
    $result.DaysLeft = $days
    if ($Today.Date -gt $eol) {
        $result.State = 'EndOfLife'; $result.Status = 'WARNING'
        $result.Text = $name + ' ' + $result.Cycle + ' reached end of life on ' + $result.EolDate + '. It gets no regular security fixes (paid extended updates may exist); plan an upgrade to a supported release.'
        return [pscustomobject]$result
    }
    if ($days -le $WarnDays) {
        $result.State = 'EndingSoon'; $result.Status = 'INFO'
        $result.Text = $name + ' ' + $result.Cycle + ' reaches end of life on ' + $result.EolDate + ' (' + $days + ' days).'
        return [pscustomobject]$result
    }
    $support = ConvertTo-EolDate $c.support
    if ($null -ne $support -and $Today.Date -gt $support) {
        $result.State = 'SecurityOnly'; $result.Status = 'INFO'
        $result.Text = $name + ' ' + $result.Cycle + ' gets security fixes only since ' + $support.ToString('yyyy-MM-dd') + '; end of life is ' + $result.EolDate + '.'
        return [pscustomobject]$result
    }
    $result.State = 'Supported'; $result.Status = 'OK'
    $result.Text = $name + ' ' + $result.Cycle + ' is supported until ' + $result.EolDate + ' (' + $days + ' days).'
    return [pscustomobject]$result
}

function New-EolSnapshotObject {
    # Pure: product -> releases and a date -> the snapshot document. The
    # attribution and the MIT notice travel with the data (ADR 0003).
    param([hashtable]$Products, [string]$AsOf)
    $byProduct = [ordered]@{}
    foreach ($k in ($Products.Keys | Sort-Object)) { $byProduct[$k] = @($Products[$k]) }
    return [ordered]@{
        asOf        = $AsOf
        source      = 'https://endoflife.date'
        license     = 'MIT'
        licenseNotice = $script:EolLicenseNotice
        attribution = $script:EolAttribution
        products    = $byProduct
    }
}

function Get-EolSnapshotAge {
    # Pure: snapshot date + today -> Fresh, Stale or Unknown (no usable date,
    # which counts as too old).
    param([string]$AsOf, [datetime]$Today, [int]$MaxAgeMonths = 6)
    $d = ConvertTo-EolDate $AsOf
    if ($null -eq $d) { return [pscustomobject]@{ State = 'Unknown'; Months = $null; Text = 'The snapshot has no usable date.' } }
    $months = ($Today.Year - $d.Year) * 12 + ($Today.Month - $d.Month)
    if ($Today.Day -lt $d.Day) { $months-- }
    if ($months -lt 0) { $months = 0 }
    if ($d.AddMonths($MaxAgeMonths) -lt $Today.Date) {
        return [pscustomobject]@{ State = 'Stale'; Months = $months; Text = ('The snapshot is from ' + $d.ToString('yyyy-MM-dd') + ' (' + $months + ' months old, limit ' + $MaxAgeMonths + ').') }
    }
    return [pscustomobject]@{ State = 'Fresh'; Months = $months; Text = ('The snapshot is from ' + $d.ToString('yyyy-MM-dd') + '.') }
}

function ConvertTo-EolStaleDecision {
    # Pure: a verdict + the snapshot age -> the verdict to show. An old
    # snapshot cannot confirm that a release is still supported, so
    # Supported and SecurityOnly become MANUAL; EndOfLife, EndingSoon and
    # Unknown stand, with the age added.
    param($Decision, $Age)
    if ($Age.State -eq 'Fresh') { return $Decision }
    $out = [ordered]@{}
    foreach ($prop in $Decision.PSObject.Properties) { $out[$prop.Name] = $prop.Value }
    if (@('Supported', 'SecurityOnly') -contains $Decision.State) {
        $out.State = 'Unconfirmed'; $out.Status = 'MANUAL'
        $out.Text = $Decision.Text + ' ' + $Age.Text + ' Check the vendor lifecycle page before relying on this.'
    } else {
        $out.Text = $Decision.Text + ' ' + $Age.Text
    }
    return [pscustomobject]$out
}

function Get-EolSnapshotRelease {
    # Reads one product from a snapshot file. $null when the file or the
    # product is missing; the caller decides what that means.
    param([string]$Product, [string]$SnapshotPath)
    if (-not $SnapshotPath -or -not (Test-Path -LiteralPath $SnapshotPath)) { return $null }
    $snap = Get-Content -LiteralPath $SnapshotPath -Raw -ErrorAction Stop | ConvertFrom-Json
    $p = $snap.products.PSObject.Properties[$Product]
    if ($null -eq $p) { return $null }
    # PowerShell 7 turns an ISO date in JSON into a DateTime; keep the text form.
    $asOf = $snap.asOf
    if ($asOf -is [datetime]) { $asOf = $asOf.ToString('yyyy-MM-dd') }
    return [pscustomobject]@{ Cycles = @($p.Value); Source = 'snapshot'; AsOf = [string]$asOf }
}

function Get-EolOnlineRelease {
    # Analysis machines with internet access only; never called from the
    # assessment script. Old Windows Server defaults to TLS 1.0.
    param([string]$Product)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $r = Invoke-RestMethod -Uri ('https://endoflife.date/api/' + $Product + '.json') -Method Get -TimeoutSec 15 -ErrorAction Stop
    return [pscustomobject]@{ Cycles = @($r); Source = 'endoflife.date'; AsOf = (Get-Date -Format 'yyyy-MM-dd') }
}

function Save-EolSnapshot {
    # Analysis machines with internet access only. One product that cannot
    # be fetched is named and left out; the rest is written. A verdict for
    # a missing product is MANUAL.
    param([string]$Path, [datetime]$Today)
    # A folder is accepted: the snapshot goes into it under a fixed name.
    if (Test-Path -LiteralPath $Path -PathType Container) { $Path = Join-Path $Path 'eol-snapshot.json' }
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw ('The folder does not exist: ' + $parent) }
    $products = @{}; $failed = @()
    foreach ($slug in $script:EolProducts.Keys) {
        try { $products[$slug] = @((Get-EolOnlineRelease -Product $slug).Cycles) }
        catch { $failed += ($slug + ': ' + $_.Exception.Message) }
    }
    if ($products.Count -eq 0) { throw 'No product could be fetched from endoflife.date; no snapshot was written.' }
    $snapshot = New-EolSnapshotObject -Products $products -AsOf $Today.ToString('yyyy-MM-dd')
    $json = ConvertTo-Json -InputObject $snapshot -Depth 6
    # A failed write must stop the script: never report a snapshot that is not there.
    try { [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false))) }
    catch { throw ('Could not write the snapshot to ' + $Path + ': ' + $_.Exception.Message) }
    return [pscustomobject]@{ Path = $Path; Written = @($products.Keys | Sort-Object); Failed = $failed; AsOf = $snapshot.asOf }
}

function Test-EolSnapshotFile {
    # Checks a snapshot file before it ships (release, CI). Problems is empty
    # when the file can be read, carries the MIT notice and has releases for
    # every supported product. Age is Fresh, Stale or Unknown; the release
    # refuses anything but Fresh, CI only checks the structure.
    param([string]$Path, [datetime]$Today = (Get-Date), [int]$MaxAgeMonths = 6)
    $problems = @()
    $age = [pscustomobject]@{ State = 'Unknown'; Months = $null; Text = 'The snapshot could not be read.' }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Problems = @('The snapshot file does not exist: ' + $Path); Age = $age }
    }
    try { $snap = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { return [pscustomobject]@{ Ok = $false; Problems = @('The snapshot is not valid JSON: ' + $_.Exception.Message); Age = $age } }
    $asOf = $snap.asOf
    if ($asOf -is [datetime]) { $asOf = $asOf.ToString('yyyy-MM-dd') }
    $age = Get-EolSnapshotAge -AsOf ([string]$asOf) -Today $Today -MaxAgeMonths $MaxAgeMonths
    if ($age.State -eq 'Unknown') { $problems += 'The snapshot has no usable asOf date.' }
    if ($snap.license -ne 'MIT') { $problems += 'The snapshot does not say license MIT.' }
    if (-not $snap.licenseNotice) { $problems += 'The snapshot has no MIT licence notice (ADR 0003).' }
    if (-not $snap.attribution) { $problems += 'The snapshot has no attribution.' }
    if ($null -eq $snap.products) { $problems += 'The snapshot has no products.' }
    else {
        foreach ($slug in $script:EolProducts.Keys) {
            $p = $snap.products.PSObject.Properties[$slug]
            if ($null -eq $p -or @($p.Value).Count -eq 0) { $problems += ('No releases for ' + $slug + '.') }
        }
    }
    return [pscustomobject]@{ Ok = ($problems.Count -eq 0); Problems = $problems; Age = $age }
}

function Get-EolRefreshDecision {
    # Pure: the committed snapshot + a freshly fetched one + today -> whether
    # the monthly workflow opens a pull request. Unchanged data does nothing,
    # unless the committed date is older than KeepDays: then the date is
    # renewed, or the release age gate (6 months) would close on data that is
    # still right.
    param($Current, $Fetched, [datetime]$Today, [int]$KeepDays = 90)
    if ($null -eq $Current -or $null -eq $Current.products) { return [pscustomobject]@{ Action = 'PullRequest'; Reason = 'There is no usable snapshot yet.' } }
    $a = ConvertTo-Json -InputObject $Current.products -Depth 8 -Compress
    $b = ConvertTo-Json -InputObject $Fetched.products -Depth 8 -Compress
    if ($a -ne $b) { return [pscustomobject]@{ Action = 'PullRequest'; Reason = 'The lifecycle data changed.' } }
    $asOf = $Current.asOf
    if ($asOf -is [datetime]) { $asOf = $asOf.ToString('yyyy-MM-dd') }
    $d = ConvertTo-EolDate ([string]$asOf)
    if ($null -eq $d -or $d.AddDays($KeepDays) -lt $Today.Date) { return [pscustomobject]@{ Action = 'PullRequest'; Reason = ('The data is unchanged, but the snapshot is older than ' + $KeepDays + ' days; renew its date.') } }
    return [pscustomobject]@{ Action = 'None'; Reason = 'The data is unchanged.' }
}

# Dot-sourcing (tests) loads the functions only.
if ($MyInvocation.InvocationName -ne '.') {
    if ($Update) {
        if (-not $SnapshotPath) { throw 'Give -SnapshotPath: the file to write the snapshot to.' }
        $saved = Save-EolSnapshot -Path $SnapshotPath -Today (Get-Date)
        $saved | Add-Member -NotePropertyName Attribution -NotePropertyValue $script:EolAttribution -PassThru
        return
    }
    if (-not $Product -or -not $Version) { throw ('Give -Product and -Version, or -Update with -SnapshotPath to create the snapshot. See: Get-Help "' + $PSCommandPath + '" -Full') }
    if (-not $script:EolProducts.Contains($Product)) { throw ('Unsupported product ' + $Product + '. Supported: ' + ($script:EolProducts.Keys -join ', ')) }
    $data = Get-EolSnapshotRelease -Product $Product -SnapshotPath $SnapshotPath
    if ($null -eq $data -and $Online) { $data = Get-EolOnlineRelease -Product $Product }
    if ($null -eq $data) {
        # No data is MANUAL, never a clean result.
        [pscustomobject][ordered]@{ Product = $Product; Version = $Version; Cycle = ''; State = 'Unknown'; Status = 'MANUAL'; EolDate = ''; DaysLeft = $null
            Text = 'No lifecycle data for ' + $Product + ' in the snapshot. Update the snapshot or use -Online.'; Source = ''; AsOf = ''; Attribution = $script:EolAttribution }
        return
    }
    $d = Get-EolDecision -Product $Product -Version $Version -Cycles $data.Cycles -Today (Get-Date) -WarnDays $WarnDays
    $d = ConvertTo-EolStaleDecision $d (Get-EolSnapshotAge -AsOf $data.AsOf -Today (Get-Date) -MaxAgeMonths $MaxAgeMonths)
    $d | Add-Member -NotePropertyName Source -NotePropertyValue $data.Source -PassThru |
        Add-Member -NotePropertyName AsOf -NotePropertyValue $data.AsOf -PassThru |
        Add-Member -NotePropertyName Attribution -NotePropertyValue $script:EolAttribution -PassThru
}
