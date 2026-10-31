<#
    Installs a pinned PowerShell module for CI (and for build/Invoke-Local.ps1),
    retrying a failed download (#141). A truncated Gallery download ("End of
    Central Directory record could not be found") once failed a required check
    with no test run; a short pause and a second try is enough.

    Every attempt is one log line, the pinned version is never changed, and the
    last failure is thrown unchanged so the real cause stays visible. On
    Windows PowerShell 5.1 the NuGet provider is installed first, with the same
    retry. A module that is already installed in the pinned version is left alone.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Retry progress belongs in the job log.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$RequiredVersion,
    [ValidateSet('CurrentUser', 'AllUsers')][string]$Scope = 'CurrentUser',
    [switch]$SkipPublisherCheck,
    [ValidateRange(1, 10)][int]$Attempts = 3,
    [ValidateRange(0, 120)][int]$DelaySeconds = 5
)

function Invoke-WithRetry {
    # Runs $Action up to $Attempts times. A failed attempt that is not the last
    # is reported through $Report and followed by $Sleep for the delay; the
    # last failure is thrown as it came. Returns the number of the attempt that
    # worked. $Report and $Sleep are parameters so the tests need no real wait.
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Label,
        [int]$Attempts = 3,
        [int]$DelaySeconds = 5,
        [scriptblock]$Report = { param($Line) Write-Host $Line },
        [scriptblock]$Sleep = { param($Seconds) Start-Sleep -Seconds $Seconds }
    )
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        & $Report ('{0}: attempt {1} of {2}' -f $Label, $attempt, $Attempts)
        try {
            & $Action
            return $attempt
        } catch {
            if ($attempt -ge $Attempts) { throw }
            & $Report ('{0}: attempt {1} failed ({2}); trying again in {3} s' -f $Label, $attempt, ($_.Exception.Message -replace '\s+', ' '), $DelaySeconds)
            & $Sleep $DelaySeconds
        }
    }
}

function Test-ModuleInstalled {
    # Pure: is the exact version among the installed module versions?
    param([object[]]$Installed, [string]$RequiredVersion)
    foreach ($m in @($Installed)) { if ([string]$m.Version -eq $RequiredVersion) { return $true } }
    return $false
}

if ($MyInvocation.InvocationName -eq '.') { return }

$ErrorActionPreference = 'Stop'
if (Test-ModuleInstalled -Installed @(Get-Module -ListAvailable -Name $Name) -RequiredVersion $RequiredVersion) {
    Write-Host ('{0} {1} is already installed' -f $Name, $RequiredVersion)
    return
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if ($PSVersionTable.PSVersion.Major -lt 6) {
    $null = Invoke-WithRetry -Label 'Install NuGet provider' -Attempts $Attempts -DelaySeconds $DelaySeconds -Action {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope $Scope | Out-Null
    }
}
$installParams = @{ Name = $Name; RequiredVersion = $RequiredVersion; Scope = $Scope; Force = $true; ErrorAction = 'Stop' }
if ($SkipPublisherCheck) { $installParams.SkipPublisherCheck = $true }
$null = Invoke-WithRetry -Label ('Install {0} {1}' -f $Name, $RequiredVersion) -Attempts $Attempts -DelaySeconds $DelaySeconds -Action {
    Install-Module @installParams
}
