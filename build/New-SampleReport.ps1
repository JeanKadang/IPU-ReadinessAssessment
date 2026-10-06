<#
    Builds the synthetic sample report in docs/samples/ (issue #16):
        sample-report.html   what a pre-upgrade report looks like
        sample-result.json   the matching JSON result (IPU-Assessment/1)
    The server, domain and values are fictional. Rows come from the script's
    own decision rules, so the sample follows the current wording. Runs on
    any machine (library mode, nothing is collected):
        pwsh ./build/New-SampleReport.ps1
#>
[CmdletBinding()]
param([string]$OutputFolder = (Join-Path (Split-Path -Parent $PSScriptRoot) 'docs/samples'))

$ErrorActionPreference = 'Stop'
$env:IPU_ASSESSMENT_LIBRARY_ONLY = '1'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Windows-IPU-Readiness-Assessment.ps1')
Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue

$script:ComputerName = 'SRV-APP01'
$script:SafeComputerName = 'SRV-APP01'
$script:JsonPath = 'C:\Temp\IPU-Assessment\SRV-APP01-IPU-Assessment.json'
$started = Get-Date -Year 2026 -Month 10 -Day 6 -Hour 9 -Minute 44 -Second 41
$completed = $started.AddMinutes(14)
$script:CollectionStarted = $started

function Add-Run([string]$Id, [string]$Name, [string]$Phase = 'Fast', [string]$Duration = '00:00:01') {
    $script:CheckRuns.Add([pscustomobject]@{ Id = $Id; Name = $Name; Phase = $Phase; Outcome = 'Completed'; Duration = $Duration; Seconds = 1; Message = '' })
}
function Set-Check([string]$Id) { $script:CurrentCheckId = $Id }

# --- upgrade path, edition, language
Set-Check 'upgradepath'
$script:Data.SourceRelease = Get-WindowsServerRelease '14393' ''
Add-Result 'UPGRADE_PATH' 'CurrentOS' 'INFO' 'Microsoft Windows Server 2016 Standard' @('Build=14393.7428', 'Release=Windows Server 2016', 'Architecture=64-bit') -Source 'Win32_OperatingSystem'
$path = Get-UpgradePathDecision '2016' '2025' $false
Add-Result 'UPGRADE_PATH' 'TargetUpgradePath' $path.Status $path.Text 'Target=Windows Server 2025' -Source 'Microsoft supported upgrade paths (installation media)'
$edition = Get-EditionDecision 'ServerStandard' 'Server' '2025'
Add-Result 'UPGRADE_PATH' 'EditionAndInstallationType' $edition.Status ('Edition=' + $edition.Edition + ', ' + $edition.Variant) @('EditionID=ServerStandard', 'InstallationType=Server') -Recommendation $edition.Text -Source 'HKLM CurrentVersion'
Add-Result 'UPGRADE_PATH' 'InstallLanguage' 'OK' 'Installed=en-US' @('DefaultUILanguage=en-US', 'SystemLocale=da-DK (not relevant for media)') -Recommendation 'Installation media must be en-US.' -Source 'Nls\Language InstallLanguage'
$script:Data.RecommendedMedia = $edition.MediaImage + ' - en-US media'
Add-Result 'UPGRADE_PATH' 'RecommendedInstallationImage' 'INFO' $script:Data.RecommendedMedia 'Select exactly this image in Setup.'
Add-Run 'upgradepath' 'Upgrade path, edition and media'

# --- activation, health
Set-Check 'licensing'
$script:Data.ActivationSummary = 'Status=Licensed, Channel=Volume:GVLK'
Add-Result 'LICENSING' 'CurrentActivation' 'OK' $script:Data.ActivationSummary @('PartialProductKey=ABCDE', 'KMS=kms.example.test:1688') -Source 'SoftwareLicensingProduct'
Add-Run 'licensing' 'Windows activation'
Set-Check 'pendingreboot'
Add-Result 'WINDOWS_HEALTH' 'PendingReboot' 'WARNING' 'PendingFileRenameOperations' @('Files waiting to be replaced:', 'C:\Program Files\Example EDR\driver.sys') -Recommendation 'The paths show which product left the pending rename (often AV or an agent update). Reboot in the pre-change window; if the same entries come back, ask that product''s owner.'
Add-Result 'WINDOWS_HEALTH' 'Uptime' 'OK' 'UptimeDays=7' 'LastBoot=2026-09-29 01:09'
Add-Run 'pendingreboot' 'Pending reboot and uptime'

# --- workloads
Set-Check 'sql'
$sql = Get-SqlSupportDecision 14 '2025'
$script:Data.SqlSummary = 'MSSQLSERVER=' + $sql.Release
Add-Result 'SQL' 'Database Engine: MSSQLSERVER' $sql.Status $sql.Release @('Version=14.0.3485.1', 'Edition=Standard Edition', 'InstanceId=MSSQL14.MSSQLSERVER') -Recommendation $sql.Text -Source 'SQL Server instance registry'
Add-Run 'sql' 'SQL Server'
Set-Check 'workloads'
Add-Result 'WORKLOAD' 'Java runtime' 'WARNING' 'Applications=1, Services=0' 'Eclipse Temurin JRE with Hotspot 17.0.12' -Recommendation 'Engage the application owner and confirm Java runtime supports Windows Server 2025.'
Add-Run 'workloads' 'Roles and workloads'

# --- platform, storage, network
Set-Check 'platform'
Add-Result 'PLATFORM' 'PhysicalOrVirtual' 'OK' 'Virtual (VMware)' @('Manufacturer=VMware, Inc.', 'Model=VMware7,1')
Add-Run 'platform' 'Platform and hardware'
Set-Check 'vmware'
$tools = Get-VMwareToolsDecision '12.3.5.22544099' '2025'
Add-Result 'VMWARE' 'VMwareTools' $tools.Status 'Version=12.3.5.22544099' 'VMTools service Running, Auto' -Recommendation $tools.Text
Add-Result 'CHECKLIST' 'VMware host version' 'MANUAL' 'Not visible from inside the guest' -Recommendation 'Windows Server 2025 is certified on vSphere 7.0 U3 and 8.0.x. Confirm the host (and any vMotion/DRS target) runs one of these.' -Kind 'Checklist'
Add-Run 'vmware' 'VMware guest readiness'
Set-Check 'performance'
Add-Result 'PERFORMANCE' 'LogicalProcessors' 'WARNING' 2 -Recommendation 'Setup will be noticeably slower on 2 logical CPUs; consider adding CPU temporarily for the change window.'
Add-Result 'PERFORMANCE' 'MemoryGB' 'OK' '16,00'
Add-Run 'performance' 'CPU and memory'
Set-Check 'storage'
$script:Data.CSummary = 'Size 100,00 GB, free 22,00 GB'
Add-Result 'STORAGE' 'CFreeSpace' 'ACTION' $script:Data.CSummary 'RequiredExpansionGB=20' -Recommendation 'Extend C: by at least 20 GB to reach the 40 GB free-space target.'
Add-Result 'STORAGE' 'PartitionAfterC' 'OK' 'No'
Add-Result 'STORAGE' 'Disk1' 'INFO' 'SizeGB=30,00' @('BusType=SAS', 'Style=GPT', 'Offline=False', 'P1:Basic:20480MB:D::Label=Data:NTFS | P2:Basic:10240MB:MountedAt=D:\Logs\:Label=Logs:NTFS')
Add-Run 'storage' 'Storage'
Set-Check 'network'
Add-Result 'NETWORK' 'Ethernet0' 'INFO' 'IPv4=10.20.30.40 / 255.255.255.0' @('Gateway=10.20.30.1', 'DNS=10.20.1.10,10.20.1.11', 'DHCP=False')
Add-Result 'NETWORK' 'NICTeaming' 'OK' 'No LBFO team detected'
Add-Result 'NETWORK_DEPENDENCY' 'HostsFile' 'MANUAL' 'ActiveEntries=1' 'C:\Windows\System32\drivers\etc\hosts' -Recommendation 'Confirm owner and purpose of each hosts entry and test the affected name resolution after IPU.'
Add-Run 'network' 'Network, teaming, hosts and routes'

# --- domain and compatibility scan
Set-Check 'domain'
$script:Data.DomainRoleText = 'Member server'
Add-Result 'ACCESS' 'DomainMembership' 'INFO' 'Domain=corp.example.test' 'Role=Member server'
Add-Result 'ACCESS' 'DomainSecureChannel' 'OK' 'Secure channel verified'
Add-Run 'domain' 'Domain role and access'

# --- access, security, backup
Set-Check 'rdp'
$script:Data.RdpSummary = 'GO (no local blocker)'; $script:Data.DriveRedirection = 'Allowed locally'
$script:Data.PolicyEvidence = 'C:\Temp\Tools\PolBackup\SRV-APP01-IPU-Policy-20261006-094454.zip'
Add-Result 'RDP' 'RDPAccessReadiness' 'OK' 'GO' 'No local RDP blocker detected' -Recommendation 'Upstream firewalls, PAM and credentials are outside this check.'
Add-Run 'rdp' 'RDP access, policy and evidence' 'Fast' '00:01:00'
Set-Check 'antivirus'
Add-Result 'ANTIVIRUS' 'Trend Micro / TrendAI Deep Security, Apex One, Vision One' 'WARNING' 'Applications=1, Services=1 (1 running), Drivers=2' @('Trend Micro Deep Security Agent 20.0', 'Service ds_agent (Running)', 'Drivers TmKmSnsr,tmeyes') -Recommendation 'Confirm this version supports Windows Server 2025 and get the vendor''s IPU procedure. Many AV/EDR agents must be upgraded before, or paused during, Setup; their drivers are a common cause of rollback.'
Add-Result 'SECURITY' 'Tenable Nessus agent' 'WARNING' 'Applications=1, Services=1, Drivers=0' 'Nessus Agent (x64) 11.2' -Recommendation 'Confirm Windows Server 2025 support and that it will not block Setup.'
Add-Run 'antivirus' 'Antivirus, EDR and security tools'
Set-Check 'backup'
Add-Result 'BACKUP' 'VSS writer: System Writer' 'OK' '[1] Stable' 'No error'
Add-Run 'backup' 'Backup and VSS'

# --- checklist
Set-Check 'checklist'
Add-Result 'CHECKLIST' 'Backup and fallback' 'MANUAL' 'Cannot be proven from inside the guest' -Recommendation 'Confirm a recent successful backup externally, snapshot eligibility (VMware) and the approved snapshot procedure.' -Kind 'Checklist'
Add-Result 'CHECKLIST' 'Credentials and console access' 'MANUAL' 'Not provable by an unattended inventory' -Recommendation 'Validate domain logon, PAM checkout and local fallback credentials, plus console (vCenter/iLO/iDRAC) access in case network logon fails.' -Kind 'Checklist'
Add-Result 'CHECKLIST' 'Installation media' 'MANUAL' $script:Data.RecommendedMedia -Recommendation 'Use media with the exact edition, installation type and language listed.' -Kind 'Checklist'
Add-Run 'checklist' 'Standard change checklist'

# --- slow checks
Set-Check 'dism'
Add-Result 'WINDOWS_HEALTH' 'DISM ScanHealth' (Get-DismVerdict 'No component store corruption detected.' 0) 'ExitCode=0' @('Duration=00:07:21', 'No component store corruption detected.')
Add-Run 'dism' 'DISM component store scan' 'Slow' '00:07:21'
Set-Check 'sfc'
Add-Result 'WINDOWS_HEALTH' 'SFC VerifyOnly' (Get-SfcVerdict 'Windows Resource Protection did not find any integrity violations.' @()).Status 'ExitCode=0, Basis=SFC output' 'Duration=00:04:18'
Add-Run 'sfc' 'SFC protected file verification' 'Slow' '00:04:18'
Set-Check 'compatscan'
$scan = Get-CompatScanDecision -1047526896
Add-Result 'COMPAT_SCAN' 'SetupCompatibilityScan' $scan.Status ($scan.Code + ' - ' + $scan.Text) @('Duration=00:11:05', 'ImageIndex=2') -Source 'setup.exe /compat scanonly from \\fileserver.example.test\media\WS2025'
Add-Run 'compatscan' 'Setup compatibility scan' 'Slow' '00:11:05'
$script:CurrentCheckId = 'core'

$results = $script:Results.ToArray()
$overall = Get-OverallStatus $results
New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
$html = New-IPUReportHtml -Results $results -CheckRuns $script:CheckRuns.ToArray() -OverallStatus $overall -CompletedTime $completed
$json = New-AssessmentJsonObject -Results $results -Overall $overall -Completed $completed | ConvertTo-Json -Depth 6
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $OutputFolder 'sample-report.html'), $html, $utf8)
[IO.File]::WriteAllText((Join-Path $OutputFolder 'sample-result.json'), $json, $utf8)
'Overall {0}, {1} rows, written to {2}' -f $overall, $results.Count, $OutputFolder
