# ==============================================================================
# End-of-life core (ADR 0003). One source part, built into BOTH the assessment
# and Get-IPUEolStatus.ps1 (ADR 0002 allows shared parts), so the two cannot
# drift apart. Pure functions and data only: no file, network or host access.
# ==============================================================================
$script:EolAttribution = 'End-of-life data from endoflife.date (https://endoflife.date), MIT License, Copyright 2020 endoflife.date contributors.'

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
    $result.EolDate = $eol.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
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
        $result.Text = $name + ' ' + $result.Cycle + ' gets security fixes only since ' + $support.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) + '; end of life is ' + $result.EolDate + '.'
        return [pscustomobject]$result
    }
    $result.State = 'Supported'; $result.Status = 'OK'
    $result.Text = $name + ' ' + $result.Cycle + ' is supported until ' + $result.EolDate + ' (' + $days + ' days).'
    return [pscustomobject]$result
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
        return [pscustomobject]@{ State = 'Stale'; Months = $months; Text = ('The snapshot is from ' + $d.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) + ' (' + $months + ' months old, limit ' + $MaxAgeMonths + ').') }
    }
    return [pscustomobject]@{ State = 'Fresh'; Months = $months; Text = ('The snapshot is from ' + $d.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) + '.') }
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

function Get-EolCandidateVerdict {
    # Pure (#275): one detected product + the parsed snapshot + today -> the
    # verdict row. The same rules as Get-IPUEolStatus.ps1 (shared core): past
    # end of life is WARNING, ending soon and security-fixes-only are INFO,
    # supported is OK. A product the snapshot has no releases for, a version
    # that matches no release, or a snapshot too old to confirm support is
    # MANUAL: never "supported" by silence.
    param($Candidate, $Snapshot, [datetime]$Today, [int]$WarnDays = 180, [int]$MaxAgeMonths = 6)
    $product = [string]$Candidate.Product
    $name = $product
    if ($script:EolProducts.Contains($product)) { $name = [string]$script:EolProducts[$product] }
    $cycles = $null
    if ($Snapshot -and $Snapshot.products) {
        $p = $Snapshot.products.PSObject.Properties[$product]
        if ($p) { $cycles = @($p.Value) }
    }
    if ($null -eq $cycles -or $cycles.Count -eq 0) {
        return [pscustomobject]@{ Product = $product; Name = $name; Version = [string]$Candidate.Version; Cycle = ''; State = 'Unknown'; Status = 'MANUAL'; EolDate = ''; DaysLeft = $null; Text = ('No lifecycle data for ' + $name + ' in the snapshot. Check the vendor lifecycle page.') }
    }
    $d = Get-EolDecision -Product $product -Version ([string]$Candidate.Version) -Cycles $cycles -Today $Today -WarnDays $WarnDays
    $asOf = $Snapshot.asOf
    if ($asOf -is [datetime]) { $asOf = $asOf.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
    return (ConvertTo-EolStaleDecision $d (Get-EolSnapshotAge -AsOf ([string]$asOf) -Today $Today -MaxAgeMonths $MaxAgeMonths))
}

function Get-EolRecommendation {
    # Pure (#275): the advice for a verdict, the same in the assessment's rows
    # and in the fleet overview.
    param($Verdict)
    $what = ([string]$Verdict.Name + ' ' + [string]$Verdict.Cycle).Trim()
    switch ($Verdict.State) {
        'EndOfLife'   { return ('Plan the upgrade or replacement of ' + $what + ' with its owner; it gets no regular security fixes. Do it before or together with the operating system upgrade.') }
        'EndingSoon'  { return ('Plan the upgrade of ' + $what + ' before ' + $Verdict.EolDate + '.') }
        'Unconfirmed' { return ('The snapshot is too old to confirm that ' + $what + ' is still supported. Use the snapshot from the latest release, or check the vendor lifecycle page.') }
        'Unknown'     { return ('Check the lifecycle of ' + $Verdict.Name + ' ' + $Verdict.Version + ' on the vendor page.') }
        default       { return '' }
    }
}

function Get-EolResultKind {
    # Pure (#275): how a verdict counts in the report. Past end of life and
    # anything that could not be confirmed are findings; ending soon and
    # security-fixes-only are observations; supported is evidence.
    param($Verdict)
    switch ($Verdict.State) {
        'EndOfLife'    { return 'Finding' }
        'Unconfirmed'  { return 'Finding' }
        'Unknown'      { return 'Finding' }
        'EndingSoon'   { return 'Observation' }
        'SecurityOnly' { return 'Observation' }
        default        { return 'Evidence' }
    }
}
