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

    End-of-life data sourced from endoflife.date under CC BY 4.0
    (https://creativecommons.org/licenses/by/4.0/).
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
.EXAMPLE
    .\Get-IPUEolStatus.ps1 -Product php -Version 8.2.12 -SnapshotPath .\eol-snapshot.json
#>
[CmdletBinding()]
param(
    [string]$Product,
    [string]$Version,
    [string]$SnapshotPath,
    [switch]$Online,
    [int]$WarnDays = 180
)

$script:EolAttribution = 'End-of-life data sourced from endoflife.date under CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/).'

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
        $result.Text = $name + ' ' + $result.Cycle + ' reached end of life on ' + $result.EolDate + '. It gets no security fixes; plan an upgrade to a supported release.'
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

function Get-EolSnapshotRelease {
    # Reads one product from a snapshot file. $null when the file or the
    # product is missing; the caller decides what that means.
    param([string]$Product, [string]$SnapshotPath)
    if (-not $SnapshotPath -or -not (Test-Path -LiteralPath $SnapshotPath)) { return $null }
    $snap = Get-Content -LiteralPath $SnapshotPath -Raw -ErrorAction Stop | ConvertFrom-Json
    $p = $snap.products.PSObject.Properties[$Product]
    if ($null -eq $p) { return $null }
    return [pscustomobject]@{ Cycles = @($p.Value); Source = 'snapshot'; AsOf = [string]$snap.asOf }
}

function Get-EolOnlineRelease {
    # Analysis machines with internet access only; never called from the
    # assessment script. Old Windows Server defaults to TLS 1.0.
    param([string]$Product)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $r = Invoke-RestMethod -Uri ('https://endoflife.date/api/' + $Product + '.json') -Method Get -TimeoutSec 15 -ErrorAction Stop
    return [pscustomobject]@{ Cycles = @($r); Source = 'endoflife.date'; AsOf = (Get-Date -Format 'yyyy-MM-dd') }
}

# Dot-sourcing (tests) loads the functions only.
if ($MyInvocation.InvocationName -ne '.') {
    if (-not $Product -or -not $Version) { throw 'Give -Product and -Version.' }
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
    $d | Add-Member -NotePropertyName Source -NotePropertyValue $data.Source -PassThru |
        Add-Member -NotePropertyName AsOf -NotePropertyValue $data.AsOf -PassThru |
        Add-Member -NotePropertyName Attribution -NotePropertyValue $script:EolAttribution -PassThru
}
