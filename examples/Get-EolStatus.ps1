<#
.SYNOPSIS
    Queries endoflife.date API or local cache for application and runtime support lifecycle status.
.DESCRIPTION
    Proof-of-concept function implementing Option 3 offline snapshot evaluation with online fallback
    for the curated whitelist of enterprise runtimes:
    - Microsoft .NET (dotnet)
    - PowerShell (powershell)
    - Java Temurin / OpenJDK (temurin)
    - Python (python)
    - Node.js (nodejs)

    Attribution Notice:
    End-of-life data sourced from endoflife.date under CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/).
.PARAMETER Product
    The product identifier from the curated whitelist.
.PARAMETER Version
    The installed semantic or release version to match against lifecycle cycles.
.PARAMETER CachePath
    Optional path to an offline JSON cache file.
.EXAMPLE
    Get-EolStatus -Product "dotnet" -Version "6.0.25"
#>
function Get-EolStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('dotnet', 'powershell', 'temurin', 'python', 'nodejs')]
        [string]$Product,

        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $false)]
        [string]$CachePath
    )

    $normalizedVersion = $Version.Trim()
    $cycles = $null

    # 1. Attempt offline cache lookup if specified
    if (-not [string]::IsNullOrEmpty($CachePath) -and (Test-Path -Path $CachePath)) {
        try {
            $rawJson = Get-Content -Path $CachePath -Raw -ErrorAction Stop
            $cache = ConvertFrom-Json -InputObject $rawJson
            if ($cache.PSObject.Properties[$Product]) {
                $cycles = $cache.$Product
            }
        }
        catch {
            Write-Verbose "Failed to read offline cache: $_"
        }
    }

    # 2. Fall back to online query if allowed and cache missed
    if ($null -eq $cycles) {
        $uri = "https://endoflife.date/api/$Product.json"
        try {
            $response = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 10 -Headers @{ "Accept" = "application/json" } -ErrorAction Stop
            $cycles = $response
        }
        catch {
            return [PSCustomObject]@{
                Product         = $Product
                Version         = $Version
                Cycle           = $null
                EolDate         = $null
                IsEol           = $null
                SupportStatus   = "LookupFailed"
                ErrorMessage    = $_.Exception.Message
                Attribution     = "endoflife.date (CC BY 4.0)"
            }
        }
    }

    # 3. Match installed version to lifecycle cycle
    # Normalize version string to major.minor
    $versionParts = $normalizedVersion.Split('.')
    $majorMinor = if ($versionParts.Count -ge 2) { "$($versionParts[0]).$($versionParts[1])" } else { $normalizedVersion }

    $matchedCycle = $cycles | Where-Object {
        $_.cycle -eq $majorMinor -or $_.cycle -eq $versionParts[0] -or $normalizedVersion.StartsWith($_.cycle)
    } | Select-Object -First 1

    if ($null -eq $matchedCycle) {
        return [PSCustomObject]@{
            Product         = $Product
            Version         = $Version
            Cycle           = $null
            EolDate         = $null
            IsEol           = $null
            SupportStatus   = "UnknownVersion"
            ErrorMessage    = "Version $Version does not match any recognized lifecycle release."
            Attribution     = "endoflife.date (CC BY 4.0)"
        }
    }

    # 4. Evaluate EOL date
    $isEol = $false
    $eolValue = $matchedCycle.eol
    if ($eolValue -is [bool]) {
        $isEol = $eolValue
    }
    elseif ($eolValue -is [string]) {
        $parsedDate = [datetime]::MinValue
        if ([datetime]::TryParse($eolValue, [ref]$parsedDate)) {
            $isEol = ([datetime]::UtcNow.Date -gt $parsedDate.Date)
        }
    }

    return [PSCustomObject]@{
        Product         = $Product
        Version         = $Version
        Cycle           = $matchedCycle.cycle
        ReleaseDate     = $matchedCycle.releaseDate
        EolDate         = $eolValue
        IsEol           = $isEol
        SupportStatus   = if ($isEol) { "EndOfLife" } else { "Supported" }
        ErrorMessage    = $null
        Attribution     = "endoflife.date (CC BY 4.0)"
    }
}
