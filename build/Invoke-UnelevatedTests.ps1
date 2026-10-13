<#
    CI only (#126): runs the Pester suite as a standard, unelevated local
    user, the way a contributor's first "Invoke-Pester" runs on a
    workstation. Run as an administrator on a throwaway CI machine: it
    creates a temporary local user, lets it log on as a batch job, installs
    Pester for all users, copies the repository to a folder the user owns,
    runs build/Invoke-CiTests.ps1 through a scheduled task with the limited
    token (Windows PowerShell 5.1), prints the output and returns its exit
    code. The user and the task are removed afterwards.

    Never run this on a real server or workstation.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'CI console output.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Random throwaway password for a temporary CI user.')]
[CmdletBinding()]
param(
    [string]$PesterVersion = $env:PESTER_VERSION,
    [int]$TimeoutMinutes = 40
)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'CI only: this script creates a local user. Do not run it outside GitHub Actions.' }
$repo = Split-Path -Parent $PSScriptRoot
$work = 'C:\ipu-unelevated'
$name = 'ipu-tester'
$task = 'IPU-Pester-Unelevated'
$chars = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
$plain = (-join (1..20 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })) + '!7a'
$secure = ConvertTo-SecureString $plain -AsPlainText -Force

$exitCode = 1
try {
    New-LocalUser -Name $name -Password $secure -PasswordNeverExpires -AccountNeverExpires -Description 'Temporary CI user for unelevated tests' | Out-Null
    Add-LocalGroupMember -Group (Get-LocalGroup -SID 'S-1-5-32-545') -Member $name
    $sid = (Get-LocalUser -Name $name).SID.Value

    # A standard user may not log on as a batch job by default; grant it.
    $inf = Join-Path $env:TEMP 'ipu-rights.inf'
    $db = Join-Path $env:TEMP 'ipu-rights.sdb'
    & secedit.exe /export /cfg $inf /areas USER_RIGHTS | Out-Null
    $lines = @(Get-Content -LiteralPath $inf)
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^SeBatchLogonRight\s*=') { $lines[$i] = $lines[$i] + ',*' + $sid; $found = $true }
    }
    if (-not $found) { $lines += ('SeBatchLogonRight = *' + $sid) }
    Set-Content -LiteralPath $inf -Value $lines -Encoding Unicode
    & secedit.exe /configure /db $db /cfg $inf /areas USER_RIGHTS | Out-Null

    # Pester for every user, the repository in a folder the user owns.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    Install-Module Pester -RequiredVersion $PesterVersion -Scope AllUsers -Force -SkipPublisherCheck
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    Copy-Item -LiteralPath $repo -Destination $work -Recurse
    & icacls.exe $work /grant ('*' + $sid + ':(OI)(CI)M') /T /Q | Out-Null

    $log = Join-Path $work 'pester-unelevated.log'
    $codeFile = Join-Path $work 'pester-unelevated.exit'
    $command = "Set-Location '$work'; & .\build\Invoke-CiTests.ps1 *> '$log'; Set-Content -LiteralPath '$codeFile' -Value `$LASTEXITCODE"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -Command "' + $command + '"') -WorkingDirectory $work
    Register-ScheduledTask -TaskName $task -Action $action -User $name -Password $plain -RunLevel Limited | Out-Null
    Start-ScheduledTask -TaskName $task
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do { Start-Sleep -Seconds 15 } while ((Get-ScheduledTask -TaskName $task).State -eq 'Running' -and (Get-Date) -lt $deadline)
    $info = Get-ScheduledTaskInfo -TaskName $task
    if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | ForEach-Object { Write-Host $_ } }
    if (Test-Path -LiteralPath $codeFile) { $exitCode = [int](Get-Content -LiteralPath $codeFile | Select-Object -First 1) }
    else { Write-Host ('::error title=Unelevated run::The test run did not finish (task result ' + $info.LastTaskResult + ').') }
} finally {
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    Remove-LocalUser -Name $name -ErrorAction SilentlyContinue
}
exit $exitCode
