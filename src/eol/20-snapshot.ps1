# The MIT licence asks that its notice travels with copies of the data, so it is written into every snapshot.
$script:EolLicenseNotice = @(
    'Copyright 2020 endoflife.date contributors'
    'Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:'
    'The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.'
    'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.'
) -join "`n`n"


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
    if ($asOf -is [datetime]) { $asOf = $asOf.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
    return [pscustomobject]@{ Cycles = @($p.Value); Source = 'snapshot'; AsOf = [string]$asOf }
}

function Get-EolOnlineRelease {
    # Analysis machines with internet access only; never called from the
    # assessment script. Old Windows Server defaults to TLS 1.0.
    param([string]$Product)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $r = Invoke-RestMethod -Uri ('https://endoflife.date/api/' + $Product + '.json') -Method Get -TimeoutSec 15 -ErrorAction Stop
    return [pscustomobject]@{ Cycles = @($r); Source = 'endoflife.date'; AsOf = (Get-Date).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
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
    $snapshot = New-EolSnapshotObject -Products $products -AsOf $Today.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
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
    if ($asOf -is [datetime]) { $asOf = $asOf.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
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
    if ($asOf -is [datetime]) { $asOf = $asOf.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
    $d = ConvertTo-EolDate ([string]$asOf)
    if ($null -eq $d -or $d.AddDays($KeepDays) -lt $Today.Date) { return [pscustomobject]@{ Action = 'PullRequest'; Reason = ('The data is unchanged, but the snapshot is older than ' + $KeepDays + ' days; renew its date.') } }
    return [pscustomobject]@{ Action = 'None'; Reason = 'The data is unchanged.' }
}
