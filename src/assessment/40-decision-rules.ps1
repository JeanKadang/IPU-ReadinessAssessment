# =============================================================================
# 4. DECISION RULES (pure functions - no system access; unit-tested)
# =============================================================================
# Where each dated fact in this section (and the feature list in section 2)
# comes from, and when it was last checked against that source (#132). A
# test fails when a check is older than six months, so outdated facts show
# up in CI instead of as confident, wrong answers. To re-verify: open the
# source, update the table if it changed, and set Verified to the day you
# checked (CONTRIBUTING, "Dated facts").
$script:FactSources = [ordered]@{
    SupportedUpgradePaths  = @{ Verified = '2026-10-13'; Source = 'https://learn.microsoft.com/en-us/windows-server/get-started/install-upgrade-migrate' }
    SqlSupportedOnTarget   = @{ Verified = '2026-10-13'; Source = 'https://learn.microsoft.com/en-us/troubleshoot/sql/general/use-sql-server-in-windows' }
    ReleaseEndOfSupport    = @{ Verified = '2026-10-13'; Source = 'https://learn.microsoft.com/en-us/lifecycle/products/windows-server-2025' }
    # FeatureLifecycle: the page has one tab per release. SMTP Server, the IIS 6 console and PowerShell 2.0 are removed on the 2025 tab only; the 2022 tab removes iSNS and nothing else (#187). A row lists only the targets whose tab names it (#232).
    FeatureLifecycle       = @{ Verified = '2026-10-22'; Source = 'https://learn.microsoft.com/en-us/windows-server/get-started/removed-deprecated-features-windows-server-2025' }
    PerUserServices        = @{ Verified = '2026-10-23'; Source = 'https://learn.microsoft.com/en-us/windows/application-management/per-user-services-in-windows' }
    VMwareToolsMinimum     = @{ Verified = '2026-10-13'; Source = 'https://blogs.vmware.com/cloud-foundation/2024/11/07/vmware-tools-12-5-0-is-ready-for-the-latest-windows-operating-systems/' }
    # ExpectedWindowsChanges: live runs (#158); AzureArcSetup per learn.microsoft.com/en-us/azure/azure-arc/servers/onboard-windows-server (#197).
    ExpectedWindowsChanges = @{ Verified = '2026-10-14'; Source = 'https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/158' }
    WinReMinPartitionMB    = @{ Verified = '2026-10-13'; Source = 'https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/161' }
    DocLinks               = @{ Verified = '2026-10-13'; Source = 'https://learn.microsoft.com/en-us/windows-server/get-started/perform-in-place-upgrade' }
}

function Get-StaleFactSource {
    # Pure (#132): the fact tables whose last check is older than MaxAgeDays
    # (or has no valid date or source), as text naming what to recheck.
    param([System.Collections.IDictionary]$Sources, [datetime]$Today, [int]$MaxAgeDays = 183)
    $stale = @()
    foreach ($name in @($Sources.Keys)) {
        $e = $Sources[$name]
        $date = [datetime]::MinValue
        $ok = [datetime]::TryParseExact([string]$e.Verified, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)
        if (-not $ok -or [string]$e.Source -notmatch '^https://') { $stale += ($name + ': no valid Verified date (yyyy-MM-dd) or https Source'); continue }
        if (($Today.Date - $date.Date).TotalDays -gt $MaxAgeDays) { $stale += ($name + ': last verified ' + $e.Verified + ', recheck against ' + $e.Source) }
    }
    return $stale
}

$script:ReleaseOrder = @('2012','2012R2','2016','2019','2022','2025')

# Microsoft "Supported in-place upgrade paths" (installation media).
# Verified: see $script:FactSources.SupportedUpgradePaths.
$script:SupportedUpgradePaths = @{
    '2022' = @('2016','2019')
    '2025' = @('2012R2','2016','2019','2022')
}

# SQL Server major version -> Windows Server support (Microsoft "Using SQL
# Server in Windows" compatibility matrix).
# Verified: see $script:FactSources.SqlSupportedOnTarget.
$script:SqlReleaseNames = @{ 9='2005'; 10='2008 / 2008 R2'; 11='2012'; 12='2014'; 13='2016'; 14='2017'; 15='2019'; 16='2022'; 17='2025' }
# Default instance names: product names, kept readable in redacted reports (#195).
$script:SqlDefaultInstanceNames = @('MSSQLSERVER','SQLEXPRESS','SSRS','PBIRS')
$script:SqlSupportedOnTarget = @{
    '2022' = @(14,15,16,17)
    '2025' = @(15,16,17)
}

function Get-ReleaseDisplayName {
    param([string]$Release)
    if ($Release -eq '2012R2') { return 'Windows Server 2012 R2' }
    if ($Release) { return ('Windows Server ' + $Release) }
    return 'Unknown'
}

function Get-WindowsServerRelease {
    # Build numbers are language independent; the caption is a fallback.
    param([string]$BuildNumber, [string]$Caption)
    $build = 0
    [void][int]::TryParse((([string]$BuildNumber) -split '\.')[0], [ref]$build)
    switch ($build) {
        9200  { return '2012' }
        9600  { return '2012R2' }
        14393 { return '2016' }
        17763 { return '2019' }
        20348 { return '2022' }
        26100 { return '2025' }
    }
    if ($Caption -match '2012 R2') { return '2012R2' }
    foreach ($r in @('2025','2022','2019','2016','2012')) { if ($Caption -match $r) { return $r } }
    return ''
}

# End of extended support per source release (Microsoft Lifecycle, fixed
# policy). Support runs through the listed day.
# Verified: see $script:FactSources.ReleaseEndOfSupport.
$script:ReleaseEndOfSupport = @{
    '2012'   = '2023-10-10'
    '2012R2' = '2023-10-10'
    '2016'   = '2027-01-12'
    '2019'   = '2029-01-09'
    '2022'   = '2031-10-14'
    '2025'   = '2034-11-14'
}

function Get-SupportLifecycleDecision {
    # Pure: release + today -> INFO while supported, WARNING once extended
    # support has ended (the day after the end date). An unknown release is
    # INFO here; the upgrade path row already reports it as MANUAL.
    param([string]$Release, [datetime]$Today)
    $name = Get-ReleaseDisplayName $Release
    if (-not $Release -or -not $script:ReleaseEndOfSupport.ContainsKey($Release)) {
        return [pscustomobject]@{ Status='INFO'; Ended=$false; EndDate=''; Value='End of support not known for this release'; Text='Check the Microsoft Lifecycle page for this release.' }
    }
    $end = [datetime]::ParseExact($script:ReleaseEndOfSupport[$Release], 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $endText = $end.ToString('yyyy-MM-dd')
    if ($Today.Date -gt $end) {
        return [pscustomobject]@{ Status='WARNING'; Ended=$true; EndDate=$endText; Value=($name + ': out of support since ' + $endText)
            Text='Microsoft no longer ships security updates for this release unless Extended Security Updates (ESU, for example through Azure Arc) are in place. This is why the newest update can be old, and it adds urgency to the upgrade.' }
    }
    $days = [int][math]::Floor(($end - $Today.Date).TotalDays)
    return [pscustomobject]@{ Status='INFO'; Ended=$false; EndDate=$endText; Value=($name + ': supported until ' + $endText + ' (' + $days + ' days)'); Text='' }
}

function Get-SpaceAfterPartition {
    # Pure: bytes of unallocated space directly after a partition, up to the
    # next partition or the end of the disk. Does not subtract the reserved
    # GPT tail (about 1 MB). Offsets are those of every partition on the disk.
    param([double]$PartitionOffset, [double]$PartitionSize, [double[]]$PartitionOffsets, [double]$DiskSize)
    $end = $PartitionOffset + $PartitionSize
    $limit = $DiskSize
    foreach ($o in @($PartitionOffsets)) { if ($o -ge $end -and $o -lt $limit) { $limit = $o } }
    if ($limit -le $end) { return [double]0 }
    return [double]($limit - $end)
}

function Resolve-ClusterFeatureState {
    # Pure: the feature table says installed or not; when the inventory failed
    # ($null) the Cluster service together with HKLM:\Cluster is the evidence,
    # and without it the state stays unknown ($null), never "not installed" (#238).
    param($FeatureState, [bool]$ClusterService, [bool]$ClusterKey)
    if ($null -ne $FeatureState) { return [bool]$FeatureState }
    if ($ClusterService -and $ClusterKey) { return $true }
    return $null
}

function Get-ActivationChannelKind {
    # Pure: SoftwareLicensingProduct channel/description -> KMS, MAK, AVMA, OEM, Retail or Unknown.
    param([string]$Channel, [string]$Description)
    $all = $Channel + ' ' + $Description
    if ($all -match 'VIRTUAL_MACHINE_ACTIVATION|AVMA') { return 'AVMA' }
    if ($all -match 'GVLK|KMSCLIENT|KMS client') { return 'KMS' }
    if ($all -match 'MAK') { return 'MAK' }
    if ($all -match 'OEM') { return 'OEM' }
    if ($all -match 'Retail') { return 'Retail' }
    return 'Unknown'
}

function Get-TargetLicensingDecision {
    # Pure: activation channel kind -> checklist value and what the target release needs.
    param([string]$Kind, [string]$KmsEndpoint, [string]$Target)
    $t = Get-ReleaseDisplayName $Target
    switch ($Kind) {
        'KMS'    { return [pscustomobject]@{ Value=('KMS client (GVLK), KMS: ' + $KmsEndpoint); Text=('Confirm the KMS host or Active Directory-based activation holds a host key (CSVLK) that activates ' + $t + '. Setup installs the ' + $t + ' GVLK; activation follows once the host can serve it.') } }
        'MAK'    { return [pscustomobject]@{ Value='MAK (Multiple Activation Key)'; Text=('The current MAK does not activate ' + $t + '. Have a ' + $t + ' MAK with free activations ready (or switch to KMS/ADBA), and activate right after the upgrade.') } }
        'AVMA'   { return [pscustomobject]@{ Value='AVMA (Automatic Virtual Machine Activation)'; Text=('The Hyper-V host must run Datacenter at a release that can activate ' + $t + ' guests (host release at least the guest release). Use the ' + $t + ' AVMA key after the upgrade.') } }
        'OEM'    { return [pscustomobject]@{ Value='OEM licence'; Text=('An OEM licence is tied to the original hardware and release. A ' + $t + ' licence and key (volume or retail) are needed.') } }
        'Retail' { return [pscustomobject]@{ Value='Retail licence'; Text=('A retail ' + $t + ' licence and key for the same edition are needed.') } }
    }
    return [pscustomobject]@{ Value=('Channel not determined, KMS: ' + $KmsEndpoint); Text=('Confirm licence entitlement for ' + $t + ' and that the KMS host/ADBA, MAK or AVMA host can activate it.') }
}

function Get-UpgradePathDecision {
    param([string]$Source, [string]$Target, [bool]$Clustered = $false)
    $make = { param($s,$t) [pscustomobject]@{ Status=$s; Text=$t } }
    if ($Clustered) {
        # Reported as SPECIAL with its own plan (#152); not a second finding here.
        return (& $make 'INFO' 'Clustered node: not a standard in-place upgrade - see the SPECIAL section.')
    }
    if (-not $Source) { return (& $make 'MANUAL' 'The source Windows Server release was not recognized.') }
    if (-not $script:SupportedUpgradePaths.ContainsKey($Target)) {
        return (& $make 'MANUAL' ("Target '" + $Target + "' is not a configured target. Use 2025 or 2022."))
    }
    if ($Source -eq $Target) { return (& $make 'INFO' ('Source is already ' + (Get-ReleaseDisplayName $Target) + '.')) }
    if ($script:ReleaseOrder.IndexOf($Source) -gt $script:ReleaseOrder.IndexOf($Target)) {
        return (& $make 'BLOCKER' ('Source (' + (Get-ReleaseDisplayName $Source) + ') is newer than the target. Downgrade is not possible.'))
    }
    if ($script:SupportedUpgradePaths[$Target] -contains $Source) {
        return (& $make 'OK' ('Supported in-place upgrade path: ' + (Get-ReleaseDisplayName $Source) + ' to ' + (Get-ReleaseDisplayName $Target) + '.'))
    }
    $alternatives = @()
    foreach ($t in @($script:SupportedUpgradePaths.Keys | Sort-Object)) {
        if ($script:SupportedUpgradePaths[$t] -contains $Source) { $alternatives += (Get-ReleaseDisplayName $t) }
    }
    $hint = ''
    if ($alternatives.Count -gt 0) { $hint = ' Supported direct target(s) from this source: ' + ($alternatives -join ', ') + '.' }
    return (& $make 'BLOCKER' ('Microsoft does not support a direct in-place upgrade from ' + (Get-ReleaseDisplayName $Source) + ' to ' + (Get-ReleaseDisplayName $Target) + '.' + $hint))
}

function Get-EditionDecision {
    # Edition is retained (Standard may move up to Datacenter, never down),
    # and Server Core <-> Desktop Experience cannot change during IPU. The
    # result names the exact image to select in Setup.
    param([string]$EditionId, [string]$InstallationType, [string]$Target)
    $targetName = Get-ReleaseDisplayName $Target
    $variant = ''
    if ($InstallationType -eq 'Server Core') { $variant = 'Server Core' }
    elseif ($InstallationType -eq 'Server') { $variant = 'Desktop Experience' }
    $suffix = ''
    if ($variant -eq 'Desktop Experience') { $suffix = ' (Desktop Experience)' }
    $out = [pscustomobject]@{ Status='MANUAL'; Edition=''; Variant=$variant; MediaImage=''; Text='' }
    if (-not $variant) {
        $out.Text = "Installation type '" + $InstallationType + "' was not recognized; the Server Core / Desktop Experience choice cannot be determined."
        return $out
    }
    $id = [string]$EditionId
    if ($id -match 'Eval') {
        $out.Status = 'BLOCKER'; $out.Edition = 'Evaluation'
        $out.Text = 'Evaluation edition. Convert it to a licensed edition (DISM /Set-Edition) or rebuild before planning a licensed IPU.'
    } elseif ($id -match '^ServerStorage') {
        $out.Status = 'BLOCKER'; $out.Edition = 'Storage Server'
        $out.Text = 'In-place upgrade from Windows Storage Server editions is not supported.'
    } elseif ($id -match '^ServerStandard(Core|Cor)?$') {
        $out.Status = 'OK'; $out.Edition = 'Standard'
        $out.MediaImage = $targetName + ' Standard' + $suffix
        $out.Text = 'Standard is retained by default (Datacenter is also allowed as an upgrade). Select the ' + $variant + ' image; switching between Server Core and Desktop Experience during IPU is not supported.'
    } elseif ($id -match '^ServerDatacenter(Core|Cor)?$') {
        $out.Status = 'OK'; $out.Edition = 'Datacenter'
        $out.MediaImage = $targetName + ' Datacenter' + $suffix
        $out.Text = 'Datacenter must stay Datacenter (downgrade to Standard is not supported). Select the ' + $variant + ' image.'
    } elseif ($id -match '^ServerTurbine') {
        $out.Edition = 'Datacenter: Azure Edition'
        $out.Text = 'Datacenter: Azure Edition has its own upgrade/hotpatch servicing model. Validate the upgrade method separately.'
    } elseif ($id -match 'Solution|Essentials') {
        $out.Edition = 'Essentials'
        $out.Text = 'Essentials edition: validate upgrade support and licensing separately.'
    } else {
        $out.Edition = $id
        $out.Text = "Edition ID '" + $id + "' is not recognized by the assessment. Validate the matching installation image manually."
    }
    return $out
}

function ConvertFrom-LanguageId {
    # InstallLanguage in the registry is hexadecimal (e.g. 0409); WMI
    # OSLanguage is decimal (e.g. 1033).
    param([string]$LanguageId, [int]$Base = 16)
    if (-not $LanguageId) { return '' }
    try {
        $lcid = [Convert]::ToInt32($LanguageId.Trim(), $Base)
        return (New-Object Globalization.CultureInfo($lcid)).Name
    } catch { return '' }
}

function Get-PlatformClassification {
    param([string]$Manufacturer, [string]$Model)
    $m = [string]$Manufacturer; $mo = [string]$Model
    $h = ''
    if (-not $m -and -not $mo) { return [pscustomobject]@{ Type='Unknown'; Hypervisor='' } }
    if ($m -match 'VMware' -or $mo -match 'VMware') { $h = 'VMware' }
    elseif ($m -match 'Amazon EC2') { $h = 'AWS EC2' }
    elseif ($m -match '^Google' -or $mo -match 'Google Compute Engine') { $h = 'Google Cloud' }
    elseif ($m -match 'Nutanix' -or $mo -match '^AHV') { $h = 'Nutanix AHV' }
    elseif ($m -match 'Microsoft Corporation' -and $mo -match 'Virtual Machine') { $h = 'Hyper-V / Azure' }
    elseif ($m -match 'QEMU|Red Hat|oVirt|OpenStack' -or $mo -match 'KVM|OpenStack|RHEV|oVirt') { $h = 'KVM-based' }
    elseif ($m -match 'Xen' -or $mo -match 'HVM domU') { $h = 'Xen' }
    elseif ($mo -match 'VirtualBox') { $h = 'VirtualBox' }
    elseif ($m -match 'Parallels') { $h = 'Parallels' }
    if ($h) { return [pscustomobject]@{ Type='Virtual'; Hypervisor=$h } }
    return [pscustomobject]@{ Type='Physical'; Hypervisor='' }
}

function Get-SqlSupportDecision {
    param([int]$Major, [string]$Target)
    $name = $script:SqlReleaseNames[$Major]
    if (-not $name) { $name = 'major version ' + $Major }
    $label = 'SQL Server ' + $name
    if (-not $script:SqlSupportedOnTarget.ContainsKey($Target)) {
        return [pscustomobject]@{ Status='MANUAL'; Release=$label; Text=('No SQL support matrix configured for target ' + $Target + '.') }
    }
    if ($script:SqlSupportedOnTarget[$Target] -contains $Major) {
        return [pscustomobject]@{ Status='OK'; Release=$label; Text=($label + ' is supported on ' + (Get-ReleaseDisplayName $Target) + '. Confirm the latest CU is installed and engage the DBA.') }
    }
    $alternatives = @()
    foreach ($t in @($script:SqlSupportedOnTarget.Keys | Sort-Object)) {
        if ($t -ne $Target -and $script:SqlSupportedOnTarget[$t] -contains $Major) { $alternatives += (Get-ReleaseDisplayName $t) }
    }
    $hint = ' Upgrade SQL Server first, or migrate the databases.'
    if ($alternatives.Count -gt 0) { $hint = ' ' + ($alternatives -join ', ') + ' supports this SQL version - choose that target, or upgrade SQL Server first.' }
    return [pscustomobject]@{ Status='BLOCKER'; Release=$label; Text=($label + ' is not supported on ' + (Get-ReleaseDisplayName $Target) + '.' + $hint) }
}

function Get-DismVerdict {
    param([string]$OutputText, $ExitCode)
    if ($OutputText -match 'No component store corruption detected') { return 'OK' }
    if ($OutputText -match 'component store is repairable|component store cannot be repaired') { return 'ACTION' }
    if ($null -ne $ExitCode -and [int]$ExitCode -ne 0) { return 'ACTION' }
    return 'MANUAL'
}

function Get-SfcVerdict {
    # SFC's console text is localized; CBS.log is always English. Use the
    # console text when it is English, otherwise the CBS.log lines written
    # during this run.
    param([string]$OutputText, [string[]]$CbsLines = @())
    # A repair waiting for a reboot stops SFC before it checks anything
    # (#159). That is not evidence of violations: reboot and run again.
    if ($OutputText -match 'system repair pending|requires reboot to complete') { return [pscustomobject]@{ Status='WARNING'; Basis='Repair pending reboot' } }
    if ($OutputText -match 'did not find any integrity violations') { return [pscustomobject]@{ Status='OK'; Basis='SFC output' } }
    if ($OutputText -match 'found integrity violations|found corrupt files|could not perform the requested operation') { return [pscustomobject]@{ Status='ACTION'; Basis='SFC output' } }
    $sr = @($CbsLines | Where-Object { $_ -match '\[SR\]|CSI' })
    if (@($sr | Where-Object { $_ -match 'corrupt|do not match actual file|Cannot repair|Cannot verify|manifest is damaged' }).Count -gt 0) {
        return [pscustomobject]@{ Status='ACTION'; Basis='CBS.log' }
    }
    if (@($sr | Where-Object { $_ -match '\[SR\] Verify complete' }).Count -gt 0) {
        return [pscustomobject]@{ Status='OK'; Basis='CBS.log' }
    }
    return [pscustomobject]@{ Status='MANUAL'; Basis='Unclassified' }
}

function ConvertFrom-VssWriterOutput {
    # Label-independent parsing: a quoted name starts a writer block, the
    # "[n] Text" line is the state, and the next line is the last error.
    param([string[]]$Lines)
    $writers = @()
    $current = $null
    $expectError = $false
    foreach ($line in $Lines) {
        if ($line -match "^\s*[^'\{\[]+:\s*'(.+)'\s*$") {
            if ($current) { $writers += $current }
            $current = [pscustomobject]@{ Name=$matches[1]; StateCode=$null; StateText=''; LastError='' }
            $expectError = $false
            continue
        }
        if (-not $current) { continue }
        if ($line -match '^\s*[^:]+:\s*\[(\d+)\]\s*(.*)$') {
            $current.StateCode = [int]$matches[1]; $current.StateText = $matches[2].Trim(); $expectError = $true
            continue
        }
        if ($expectError -and $line.Trim()) {
            $current.LastError = (($line -split ':',2)[-1]).Trim(); $expectError = $false
        }
    }
    if ($current) { $writers += $current }
    return ,$writers
}

function Get-VssWriterStatus {
    param($Writer)
    if ($null -ne $Writer.StateCode -and $Writer.StateCode -ne 1) { return 'ACTION' }
    if ($Writer.LastError -match '^\s*No error\s*$') { return 'OK' }
    if ($Writer.LastError -match 'error|fail|timeout|retryable') { return 'ACTION' }
    if ($Writer.StateCode -eq 1) { return 'MANUAL' }
    return 'MANUAL'
}

function Get-VMwareToolsDecision {
    # Broadcom: VMware Tools 12.5.0 is the release whose drivers are certified
    # for Windows Server 2025; Broadcom's IPU KB says to update Tools first.
    # Verified: see $script:FactSources.VMwareToolsMinimum.
    param([string]$Version, [string]$Target)
    if (-not $Version) {
        return [pscustomobject]@{ Status='ACTION'; Text='VMware Tools not found. Install current VMware Tools before IPU (PVSCSI/VMXNET3 and other VMware drivers).' }
    }
    $parsed = $null
    $clean = ([regex]::Match($Version, '^\d+(\.\d+){1,3}')).Value
    if (-not $clean -or -not [version]::TryParse($clean, [ref]$parsed)) {
        return [pscustomobject]@{ Status='MANUAL'; Text=("VMware Tools version '" + $Version + "' could not be parsed. Confirm it is current.") }
    }
    # [version]'12.5' has no build part (-1) and so sorts below '12.5.0'; compare with three parts (#253).
    if ($parsed.Build -lt 0) { $parsed = New-Object System.Version $parsed.Major, $parsed.Minor, 0 }
    if ($Target -eq '2025' -and $parsed -lt [version]'12.5.0') {
        return [pscustomobject]@{ Status='ACTION'; Text=('VMware Tools ' + $clean + ' predates 12.5.0, the first release with drivers certified for Windows Server 2025. Update VMware Tools before IPU.') }
    }
    return [pscustomobject]@{ Status='OK'; Text=('VMware Tools ' + $clean + '. Update to the latest release before IPU, as Broadcom recommends.') }
}

function Get-FeatureLifecycleFinding {
    param([string[]]$InstalledFeatures, [string]$Target)
    $out = @()
    foreach ($f in $script:FeatureLifecycle) {
        if ($f.Targets -notcontains $Target) { continue }
        if ($InstalledFeatures -notcontains $f.Feature) { continue }
        if ($f.State -eq 'Removed') {
            $out += [pscustomobject]@{ Status='ACTION'; Kind='Finding'; Feature=$f.Feature; Name=$f.Name
                Text=($f.Name + ' is removed in ' + (Get-ReleaseDisplayName $Target) + '. Find out what uses it and plan a replacement before IPU; it will not be available afterwards.') }
        } else {
            $out += [pscustomobject]@{ Status='WARNING'; Kind='Observation'; Feature=$f.Feature; Name=$f.Name
                Text=($f.Name + ' is no longer developed by Microsoft. It still works after IPU; plan a replacement.') }
        }
    }
    return ,$out
}

function Get-CompatScanDecision {
    # Exit codes documented for setup.exe /Compat ScanOnly.
    param([object]$ExitCode)
    if ($null -eq $ExitCode) { return [pscustomobject]@{ Status='MANUAL'; Code=''; Text='Setup returned no exit code.' } }
    $n = [int64]$ExitCode
    if ($n -lt 0) { $n += 4294967296 }   # signed Int32 exit code -> unsigned
    $hex = '0x' + $n.ToString('X8')
    switch ($hex) {
        '0xC1900210' { return [pscustomobject]@{ Status='OK';      Code=$hex; Text='Setup found no compatibility issues.' } }
        '0xC1900208' { return [pscustomobject]@{ Status='ACTION';  Code=$hex; Text='Setup found compatibility issues (typically an incompatible application or driver). See the CompatData XML.' } }
        '0xC1900204' { return [pscustomobject]@{ Status='BLOCKER'; Code=$hex; Text='Setup reports that an upgrade keeping files and apps is not available with this media (edition, installation type or language mismatch).' } }
        '0xC1900200' { return [pscustomobject]@{ Status='BLOCKER'; Code=$hex; Text='Setup reports that this server is not eligible for the target version.' } }
        '0xC190020E' { return [pscustomobject]@{ Status='ACTION';  Code=$hex; Text='Setup reports insufficient free disk space.' } }
        '0xC1900215' { return [pscustomobject]@{ Status='MANUAL';  Code=$hex; Text='Setup needs an image index; no matching image was selected.' } }
        '0xC190010E' { return [pscustomobject]@{ Status='MANUAL';  Code=$hex; Text='Setup needs EULA acceptance for unattended use.' } }
    }
    return [pscustomobject]@{ Status='MANUAL'; Code=$hex; Text=('Unexpected Setup result ' + $hex + '. Review the Panther logs.') }
}

function Test-PendingRenameHarmless {
    # Pure (#158): true when every pending rename is an installer leftover -
    # MSI rollback files in C:\Config.Msi or the Edge updater folder.
    param([object[]]$Values)
    $paths = @($Values | Where-Object { $_ } | ForEach-Object { ([string]$_ -replace '^!','' -replace '^\\\?\?\\','').Trim() } | Where-Object { $_ })
    if ($paths.Count -eq 0) { return $false }
    return (@($paths | Where-Object { $_ -notmatch '\\Config\.Msi(\\[^\\]+\.rb[fs])?\\?$' -and $_ -notmatch '\\Microsoft\\EdgeUpdate\\' }).Count -eq 0)
}

function ConvertTo-PendingRenamePath {
    # PendingFileRenameOperations holds pairs (source, destination); show the
    # first few sources so the owning product is recognisable.
    param([object[]]$Values, [int]$Max = 5)
    $paths = @()
    foreach ($v in @($Values)) {
        # A destination prefixed with '!' means "replace the existing file";
        # strip it with the \??\ prefix so both forms show the same path.
        $p = ([string]$v -replace '^!','' -replace '^\\\?\?\\','').Trim()
        if ($p -and $paths -notcontains $p) { $paths += $p }
    }
    $shown = @($paths | Select-Object -First $Max)
    if ($paths.Count -gt $Max) { $shown += ('... and ' + ($paths.Count - $Max) + ' more') }
    return ,$shown
}

# Changes Microsoft makes during an upgrade (#158), so the post-upgrade
# comparison can call them expected instead of reporting them as problems.
# Verified: see $script:FactSources.ExpectedWindowsChanges.
# Services that newer Windows starts on demand (trigger start, Manual):
$script:ExpectedManualServices = @('IKEEXT','NlaSvc')
# Services and features removed or renamed in newer Windows Server releases:
$script:ExpectedRemovedServices = @('tiledatamodelsvc')
# AzureArcSetup is a Feature on Demand (a capability) from Windows Server
# 2025 on, so it is no longer listed as a feature after the upgrade (#197).
$script:ExpectedRemovedFeatures = @('PowerShell-V2','PowerShell-ISE','Windows-Defender-Features','Windows-Defender-Gui','AzureArcSetup')
# Well-known Windows ports and the service that opens them, for baselines
# without port owners (4.3.0 and older).
$script:KnownPortServices = @{ 'UDP:500' = 'IKEEXT'; 'UDP:4500' = 'IKEEXT'; 'UDP:1900' = 'SSDPSRV'; 'TCP:2869' = 'SSDPSRV'; 'TCP:5357' = 'FDResPub'; 'UDP:3702' = 'FDResPub' }

# Windows' per-user service templates; each signed-in user gets an instance
# named <template>_<LUID>. Verified: see $script:FactSources.PerUserServices.
$script:PerUserServiceTemplates = @(
    'AarSvc','BluetoothUserService','CaptureService','cbdhsvc','CloudBackupRestoreSvc','CDPUserSvc','ConsentUxUserSvc',
    'PimIndexMaintenanceSvc','CredentialEnrollmentManagerUserSvc','DeviceAssociationBrokerSvc','DevicePickerUserSvc',
    'DevicesFlowUserSvc','BcastDVRUserService','MessagingService','NPSMSvc','P9RdrService','PenService','PrintWorkflowUserSvc',
    'OneSyncSvc','UdkUserSvc','UserDataSvc','UnistoreSvc','webthreatdefusersvc','WpnUserService'
)

function ConvertTo-ServiceBaseName {
    # Pure (#158, #247): per-user services carry a random suffix that changes
    # (CDPUserSvc_1a2b3c), so compare them by their base name. Only a name
    # that starts with a known Windows template is a per-user service: a
    # service such as AppSvc_DB01 or Backup_2016 keeps its full name.
    param([string]$Name)
    if ($Name -match '^(.+)_[0-9a-fA-F]{4,}$' -and $script:PerUserServiceTemplates -contains $Matches[1]) { return $Matches[1] }
    return $Name
}

function Test-WindowsPerUserTask {
    # Pure (#214): the RSS feed synchronisation task Windows creates at the
    # root of the task library for each user who signs in.
    param([string]$FullName)
    return ($FullName -match '^\\User_Feed_Synchronization-\{[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$')
}

function ConvertTo-TaskBaseName {
    # Pure (#196): some updaters put their version and a GUID in the task
    # name and rename the task when they update
    # (\Vendor\UpdaterTaskSystem1.2.3.4{GUID}). Compare tasks without them.
    param([string]$Name)
    $n = $Name -replace '\{[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$', ''
    return ($n -replace '\d+(\.\d+){1,3}$', '')
}

function Get-NetBiosSettingText {
    # Pure (#149): Win32_NetworkAdapterConfiguration.TcpipNetbiosOptions in words.
    param($Option)
    switch ([string]$Option) {
        '0' { return 'Default (set by DHCP)' }
        '1' { return 'Enabled' }
        '2' { return 'Disabled' }
        default { return 'Unknown' }
    }
}

function ConvertTo-NetworkAdapterRecord {
    # Pure (#149): one enabled adapter's IP configuration as a plain record
    # for the report row, the snapshot and the per-adapter comparison. The
    # MAC address is the key, because Setup can rename adapters.
    param($Config, [string]$Name, $VlanId = $null)
    $addresses = @($Config.IPAddress | Where-Object { $_ })
    $ipv4 = @($addresses | Where-Object { [string]$_ -match '^\d+\.\d+\.\d+\.\d+$' } | ForEach-Object { [string]$_ })
    $ipv6 = @($addresses | Where-Object { [string]$_ -match ':' } | ForEach-Object { [string]$_ })
    $masks = @($Config.IPSubnet | Where-Object { [string]$_ -match '^\d+\.\d+\.\d+\.\d+$' } | ForEach-Object { [string]$_ })
    $wins = @(@($Config.WINSPrimaryServer, $Config.WINSSecondaryServer) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $vlan = ''
    if ($null -ne $VlanId -and [string]$VlanId -ne '' -and [string]$VlanId -ne '0') { $vlan = [string]$VlanId }
    $metric = ''
    if ($null -ne $Config.IPConnectionMetric) { $metric = [string]$Config.IPConnectionMetric }
    return [pscustomobject]@{
        Name          = $Name
        Mac           = (([string]$Config.MACAddress).ToUpperInvariant() -replace '-', ':')
        IPv4          = $ipv4
        Mask          = $masks
        IPv6          = $ipv6
        Gateway       = @($Config.DefaultIPGateway | Where-Object { $_ } | ForEach-Object { [string]$_ })
        Dns           = @($Config.DNSServerSearchOrder | Where-Object { $_ } | ForEach-Object { [string]$_ })
        Suffix        = [string]$Config.DNSDomain
        SuffixSearch  = @($Config.DNSDomainSuffixSearchOrder | Where-Object { $_ } | ForEach-Object { [string]$_ })
        RegisterInDns = [bool]$Config.FullDNSRegistrationEnabled
        RegisterSuffix = [bool]$Config.DomainDNSRegistrationEnabled
        Wins          = $wins
        NetBios       = Get-NetBiosSettingText $Config.TcpipNetbiosOptions
        Metric        = $metric
        Dhcp          = [bool]$Config.DHCPEnabled
        Vlan          = $vlan
    }
}

function ConvertTo-MacKey {
    # Pure (#149): 00-50-56-AA-00-01 and 00:50:56:aa:00:01 are the same adapter.
    param([string]$Mac)
    return (($Mac -replace '[^0-9A-Fa-f]', '').ToUpperInvariant())
}

function Get-NetworkAdapterDetail {
    # Pure (#149): the report details of one adapter record.
    param($Adapter)
    $onOff = { param($b) if ($b) { 'Yes' } else { 'No' } }
    $d = @(
        ('Gateway=' + (@($Adapter.Gateway) -join ',')),
        ('DNS=' + (@($Adapter.Dns) -join ',')),
        ('DHCP=' + [bool]$Adapter.Dhcp),
        ('MAC=' + [string]$Adapter.Mac)
    )
    if (@($Adapter.IPv6).Count -gt 0) { $d += ('IPv6=' + (@($Adapter.IPv6) -join ',')) }
    $d += ('DNS suffix=' + $(if ($Adapter.Suffix) { [string]$Adapter.Suffix } else { '(none)' }))
    if (@($Adapter.SuffixSearch).Count -gt 0) { $d += ('Suffix search list=' + (@($Adapter.SuffixSearch) -join ',')) }
    $d += ('Register in DNS=' + (& $onOff $Adapter.RegisterInDns) + ', with suffix=' + (& $onOff $Adapter.RegisterSuffix))
    $d += ('WINS=' + $(if (@($Adapter.Wins).Count -gt 0) { @($Adapter.Wins) -join ',' } else { '(none)' }))
    $d += ('NetBIOS over TCP/IP=' + [string]$Adapter.NetBios)
    if ($Adapter.Metric) { $d += ('Metric=' + [string]$Adapter.Metric) }
    if ($Adapter.Vlan) { $d += ('VLAN=' + [string]$Adapter.Vlan) }
    return ,$d
}

function Compare-NetworkAdapter {
    # Pure (#149): compares the adapters before and after the upgrade, matched
    # by MAC address (Setup can rename adapters). One row per changed adapter,
    # with every difference in the details and the worst status. Addresses
    # lost on a static adapter are an ACTION; on DHCP a WARNING (a new lease).
    param($Before, $After)
    $rows = @()
    $make = { param($st,$item,$val,$det,$rec) [pscustomobject]@{ Status=$st; Item=$item; Value=$val; Details=$det; Recommendation=$rec } }
    $list = { param($v) $x = @($v | Where-Object { $_ } | ForEach-Object { [string]$_ }); if ($x.Count -eq 0) { '(none)' } else { $x -join ',' } }
    $set = { param($v) (@($v | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique) -join ',') }
    $rank = { param($s) $script:StatusOrder.IndexOf($s) }
    $restore = 'Compare with the network evidence file saved before the upgrade (ipconfig /all, netsh interface dump) and put back what should not have changed. Test name resolution and access from a client.'
    $now = @{}
    foreach ($a in @($After | Where-Object { $_ -and $_.Mac })) { $now[(ConvertTo-MacKey ([string]$a.Mac))] = $a }
    $seen = @{}
    foreach ($b in @($Before | Where-Object { $_ -and $_.Mac })) {
        $key = ConvertTo-MacKey ([string]$b.Mac)
        $seen[$key] = $true
        if (-not $now.ContainsKey($key)) {
            if (@($b.IPv4 | Where-Object { $_ }).Count -gt 0) {
                $rows += (& $make 'ACTION' ('Network adapter missing after upgrade: ' + $b.Name) ('MAC=' + [string]$b.Mac) ('Before: IPv4=' + (& $list $b.IPv4) + '; Gateway=' + (& $list $b.Gateway) + '; DNS=' + (& $list $b.Dns) + '; DHCP=' + [bool]$b.Dhcp) ('No enabled adapter has this MAC address now. Check Device Manager and the virtual hardware, then restore the IP configuration on the right adapter. ' + $restore))
            }
            continue
        }
        $a = $now[$key]
        # A list and a hashtable, so the helper below (a child scope) can add to them.
        $changes = New-Object System.Collections.Generic.List[string]
        $state = @{ Worst = 'INFO' }
        $staticNow = (-not [bool]$b.Dhcp -or -not [bool]$a.Dhcp)
        $addrStatus = $(if ($staticNow) { 'ACTION' } else { 'WARNING' })
        $add = {
            param($st, $text)
            $changes.Add([string]$text)
            if ((& $rank $st) -lt (& $rank $state.Worst)) { $state.Worst = $st }
        }
        if ([bool]$b.Dhcp -ne [bool]$a.Dhcp) { & $add 'ACTION' ('DHCP: before ' + [bool]$b.Dhcp + ', now ' + [bool]$a.Dhcp) }
        $lost4 = @(@($b.IPv4) | Where-Object { $_ -and @($a.IPv4) -notcontains $_ })
        if ($lost4.Count -gt 0) { & $add $addrStatus ('IPv4: before ' + (& $list $b.IPv4) + ', now ' + (& $list $a.IPv4)) }
        if ((& $set $b.Gateway) -ne (& $set $a.Gateway)) { & $add $addrStatus ('Gateway: before ' + (& $list $b.Gateway) + ', now ' + (& $list $a.Gateway)) }
        # DNS server order matters for resolution, so the lists are compared in order.
        if ((& $list $b.Dns) -ne (& $list $a.Dns)) { & $add 'WARNING' ('DNS servers: before ' + (& $list $b.Dns) + ', now ' + (& $list $a.Dns)) }
        $global6 = { param($v) @($v | Where-Object { $_ -and [string]$_ -notmatch '^fe80:' }) }
        $lost6 = @(& $global6 $b.IPv6 | Where-Object { @($a.IPv6) -notcontains $_ })
        if ($lost6.Count -gt 0) { & $add 'WARNING' ('IPv6: before ' + (& $list (& $global6 $b.IPv6)) + ', now ' + (& $list (& $global6 $a.IPv6))) }
        if ([string]$b.Suffix -ne [string]$a.Suffix) { & $add 'WARNING' ('DNS suffix: before ' + (& $list $b.Suffix) + ', now ' + (& $list $a.Suffix)) }
        if ((& $list $b.SuffixSearch) -ne (& $list $a.SuffixSearch)) { & $add 'WARNING' ('Suffix search list: before ' + (& $list $b.SuffixSearch) + ', now ' + (& $list $a.SuffixSearch)) }
        if ([bool]$b.RegisterInDns -ne [bool]$a.RegisterInDns) { & $add 'WARNING' ('Register in DNS: before ' + [bool]$b.RegisterInDns + ', now ' + [bool]$a.RegisterInDns) }
        if ((& $set $b.Wins) -ne (& $set $a.Wins)) { & $add 'WARNING' ('WINS: before ' + (& $list $b.Wins) + ', now ' + (& $list $a.Wins)) }
        if ($b.NetBios -and $a.NetBios -and [string]$b.NetBios -ne [string]$a.NetBios) { & $add 'WARNING' ('NetBIOS over TCP/IP: before ' + $b.NetBios + ', now ' + $a.NetBios) }
        if ([string]$b.Vlan -ne [string]$a.Vlan) { & $add 'ACTION' ('VLAN: before ' + (& $list $b.Vlan) + ', now ' + (& $list $a.Vlan)) }
        if ($b.Metric -and $a.Metric -and [string]$b.Metric -ne [string]$a.Metric) { & $add 'INFO' ('Metric: before ' + $b.Metric + ', now ' + $a.Metric) }
        if ([string]$b.Name -ne [string]$a.Name) { & $add 'INFO' ('Name: before ' + $b.Name + ', now ' + $a.Name) }
        $worst = $state.Worst
        if ($changes.Count -eq 0) { continue }
        $rec = $restore
        if ($worst -eq 'INFO') { $rec = 'Only the name or metric changed. Update scripts or monitoring that use the adapter name.' }
        $rows += (& $make $worst ('Network adapter changed: ' + $a.Name) ('MAC=' + [string]$a.Mac) (@($changes) -join '; ') $rec)
    }
    $new = @(@($After | Where-Object { $_ -and $_.Mac }) | Where-Object { -not $seen.ContainsKey((ConvertTo-MacKey ([string]$_.Mac))) })
    if ($new.Count -gt 0) {
        $rows += (& $make 'INFO' 'Network adapters new after upgrade' ('Count=' + $new.Count) ((@($new | ForEach-Object { [string]$_.Name + ' (MAC=' + [string]$_.Mac + ')' })) -join ', ') 'Adapters with a MAC address not seen before the upgrade. Expected when virtual hardware was changed; otherwise check that the IP configuration is on the right adapter.')
    }
    # Plain output (not ,$rows): callers wrap it in @(), and no rows is no output.
    return $rows
}

# Print servers (#148). Inbox virtual printers that every server has; they
# are not print-server work and are left out of the inventory.
$script:VirtualPrinterDrivers = '^(Microsoft Print To PDF|Microsoft XPS Document Writer( v4)?|Microsoft Shared Fax Driver|Send to Microsoft OneNote.*|Microsoft Software Printer Driver|Remote Desktop Easy Print)$'
$script:PrinterDriverDocUrl = 'https://learn.microsoft.com/en-us/windows-hardware/drivers/print/end-of-servicing-plan-for-third-party-printer-drivers-on-windows'

function ConvertFrom-GpoListKeyName {
    # Pure (#223): the position of a GPO-List subkey. Names are hexadecimal
    # numbers; anything else sorts last instead of failing.
    param([string]$Name)
    $n = 0
    if ([int]::TryParse($Name, [Globalization.NumberStyles]::HexNumber, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return $n }
    return [int]::MaxValue
}

function Get-GpoFallbackNote {
    # Pure (#215): what the registry fallback for the applied GPOs found,
    # for the details of the MANUAL Group Policy row.
    param([int]$EntryCount, [int]$NamedCount, [string]$ErrorMessage = '', [bool]$KeyMissing = $false)
    $key = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\GPO-List'
    if ($KeyMissing) { return ('Registry fallback: the key ' + $key + ' does not exist') }
    if ($ErrorMessage) { return ('Registry fallback failed: ' + $ErrorMessage) }
    if ($EntryCount -eq 0) { return ('Registry fallback: ' + $key + ' has no entries') }
    if ($NamedCount -eq 0) { return ('Registry fallback: ' + $EntryCount + ' entries in ' + $key + ', none with a GPO name') }
    return ('Registry fallback: ' + $NamedCount + ' GPOs read')
}

function Get-EvidenceFolderPath {
    # Pure (#198): the folder for one evidence topic. PolicyEvidenceRoot,
    # when set, keeps the policy evidence where a site already has it.
    param([string]$Root, [string]$Topic, [string]$PolicyOverride = '')
    if ($Topic -eq 'Policy' -and $PolicyOverride) { return $PolicyOverride }
    return (Join-Path $Root $Topic)
}

function Get-EvidenceReadmeText {
    # Pure (#198): the README written into the evidence root.
    $lines = @(
        'IPU readiness assessment - evidence copies',
        '',
        'Written by Windows-IPU-Readiness-Assessment.ps1. Read-only copies; nothing on this server was changed.',
        '',
        '  Policy\    RDP and Group Policy evidence, LGPO backup of the local policy',
        '  IIS\       IIS configuration files (appcmd backup format)',
        '  Network\   ipconfig /all, route print, netsh interface configuration',
        '  Printers\  PrintBrm export of printers, ports and drivers',
        '',
        'These files are NOT redacted: they hold names, addresses and configuration of this server.',
        'Do not share them outside the team. Copy them off the server before the upgrade:',
        'a copy on C: does not survive a failed upgrade that needs a rebuild.',
        'See the user guide of the assessment for how to restore from each copy.'
    )
    return (($lines -join "`r`n") + "`r`n")
}

function Get-PrinterPortKind {
    # Pure (#148): the kind of a printer port, from its description, its
    # port monitor and (for Standard TCP/IP ports) the protocol.
    param([string]$Description, [string]$Monitor, [string]$Protocol)
    $t = $Description + ' ' + $Monitor
    if ($t -match 'LPR Port|LPRMON') { return 'LPR port monitor' }
    if ($t -match 'Standard TCP/IP|TCPMON') {
        if ($Protocol -match '^(2|LPR)$') { return 'Standard TCP/IP (LPR protocol)' }
        return 'Standard TCP/IP (RAW)'
    }
    if ($t -match 'WSD') { return 'WSD' }
    if ($t -match 'USB') { return 'USB' }
    if ($t -match 'Internet Port|IPP|inetpp') { return 'Internet (IPP)' }
    if ($t -match 'Local Port|Local Monitor|localspl') { return 'Local' }
    if ($Description) { return ('Other: ' + $Description) }
    return 'Other'
}

function Get-PrintComponentDecision {
    # Pure (#148): port monitors and print processors that are not from
    # Microsoft. They load into the spooler and are a common cause of failed
    # upgrades and of a spooler that crashes afterwards.
    param($Items, [string]$TargetName)
    $rows = @()
    $make = { param($st,$item,$val,$det,$rec) [pscustomobject]@{ Status=$st; Item=$item; Value=$val; Details=$det; Recommendation=$rec } }
    $third = @($Items | Where-Object { $_ -and [string]$_.Company -notmatch '^Microsoft' })
    foreach ($i in $third) {
        $label = $(if ($i.Type -eq 'PrintProcessor') { 'Print processor: ' } else { 'Port monitor: ' }) + $i.Name
        $company = $(if ($i.Company) { [string]$i.Company } else { 'unknown (file not found or no version information)' })
        $rows += (& $make 'WARNING' $label ('Driver=' + $i.Driver) ('Company=' + $company) ('Not from Microsoft. Get the vendor''s version for ' + $TargetName + ' and update it before the upgrade, or remove it after confirming no printer uses it. Third-party port monitors and print processors are a common cause of failed upgrades and spooler crashes afterwards.'))
    }
    if ($third.Count -eq 0) { $rows += (& $make 'OK' 'PrintComponents' 'Only Windows port monitors and print processors' ('Checked=' + @($Items | Where-Object { $_ }).Count) '') }
    return $rows
}

function Get-PrinterDriverDecision {
    # Pure (#148): the driver summary row. Third-party drivers need the
    # vendor's confirmation for the target; Windows Server 2025 gets no new
    # third-party printer drivers from Windows Update (installed ones keep
    # working). Drivers only for 32-bit clients are named, not a problem.
    param($Drivers, [string]$TargetName, [string]$TargetRelease)
    $rows = @()
    $make = { param($st,$item,$val,$det,$rec) [pscustomobject]@{ Status=$st; Item=$item; Value=$val; Details=$det; Recommendation=$rec } }
    $all = @($Drivers | Where-Object { $_ -and $_.Name -and [string]$_.Name -notmatch $script:VirtualPrinterDrivers })
    $x64 = @($all | Where-Object { [string]$_.Environment -match 'x64' })
    $third = @($x64 | Where-Object { [string]$_.Manufacturer -notmatch '^Microsoft' -and [string]$_.Name -notmatch '^Microsoft ' })
    $x64Names = @($x64 | ForEach-Object { [string]$_.Name })
    $x86Only = @($all | Where-Object { [string]$_.Environment -match 'x86' -and $x64Names -notcontains [string]$_.Name } | ForEach-Object { [string]$_.Name } | Sort-Object -Unique)
    $note = ''
    if ($TargetRelease -eq '2025') { $note = ' From 15 January 2026 Microsoft no longer publishes new third-party printer drivers to Windows Update for Windows Server 2025; installed drivers keep working, so keep the vendor packages.' }
    if ($third.Count -gt 0) {
        $names = @($third | ForEach-Object { [string]$_.Name + ' (v' + $_.Major + $(if ($_.Manufacturer) { ', ' + $_.Manufacturer } else { '' }) + ')' } | Sort-Object -Unique)
        $rows += (& $make 'WARNING' 'PrinterDrivers' ('Third-party=' + $third.Count + ' of ' + $x64.Count + ' (x64)') ($names -join ', ') ('Confirm with each vendor that the driver supports ' + $TargetName + ', and have the driver packages at hand in case the upgrade drops one.' + $note))
    } else {
        $rows += (& $make 'OK' 'PrinterDrivers' ('Windows drivers only (' + $x64.Count + ' x64)') '' '')
    }
    if ($x86Only.Count -gt 0) {
        $rows += (& $make 'INFO' 'PrinterDriversX86Only' ('Count=' + $x86Only.Count) ($x86Only -join ', ') 'Drivers for 32-bit clients only (Point and Print). Not used by the server itself; check they are still needed.')
    }
    return $rows
}

function Get-PrintBackupSpaceDecision {
    # Pure (#148): PrintBrm exports every driver package, so the export can
    # be a few MB or several GB. It runs only when the drive has 1.5 times
    # the size of spool\drivers plus 1 GB free.
    param([long]$DriverBytes, [long]$FreeBytes)
    $required = [long][math]::Ceiling($DriverBytes * 1.5) + [long]1GB
    $gb = { param($b) [math]::Round(([double]$b / 1GB), 2) }
    return [pscustomobject]@{
        Proceed = ($FreeBytes -ge $required)
        EstimateBytes = $DriverBytes
        RequiredBytes = $required
        FreeBytes = $FreeBytes
        Text = ('Estimate ' + (& $gb $DriverBytes) + ' GB (spool\drivers), needs ' + (& $gb $required) + ' GB free, ' + (& $gb $FreeBytes) + ' GB free')
    }
}

function Get-PrintBackupCommand {
    # Pure (#148): the export command shown when the backup is not taken here.
    param([string]$Folder = 'D:\PrintBackup', [string]$Computer = '%COMPUTERNAME%')
    return ('%windir%\System32\spool\tools\PrintBrm.exe -B -F ' + $Folder.TrimEnd('\') + '\' + $Computer + '-printers.printerExport')
}

function Compare-PrinterDriver {
    # Pure (#148): printers that still exist after the upgrade but use
    # another driver. Lists of {Printer; Driver}.
    param($Before, $After)
    $now = @{}
    foreach ($a in @($After | Where-Object { $_ -and $_.Printer })) { $now[[string]$a.Printer] = [string]$a.Driver }
    $changed = @()
    foreach ($b in @($Before | Where-Object { $_ -and $_.Printer })) {
        $p = [string]$b.Printer
        if ($now.ContainsKey($p) -and $now[$p] -ne [string]$b.Driver) { $changed += ($p + ': ' + $b.Driver + ' -> ' + $now[$p]) }
    }
    return ,$changed
}

function Compare-IPUSnapshot {
    # Pure: compares the pre-upgrade snapshot with the current one and returns
    # the differences an engineer must look at after the upgrade.
    param($Before, $After)
    $diff = @()
    $make = { param($st,$item,$val,$det,$rec) [pscustomobject]@{ Status=$st; Item=$item; Value=$val; Details=$det; Recommendation=$rec } }

    $nowRunning = @{}
    foreach ($s in @($After.Services)) { $nowRunning[(ConvertTo-ServiceBaseName ([string]$s.Name))] = $s }
    $stopped = @(); $missing = @(); $disabled = @(); $expected = @()
    $explainedSvc = @()   # services whose ports are explained by the change
    foreach ($s in @($Before.Services | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -eq 'Running' })) {
        $base = ConvertTo-ServiceBaseName ([string]$s.Name)
        if (-not $nowRunning.ContainsKey($base)) {
            if ($script:ExpectedRemovedServices -contains $base) { $expected += ($base + ' (removed by Microsoft)'); $explainedSvc += $base }
            # A per-user service instance (name_suffix) exists only while a
            # user is signed in (#173).
            elseif ($base -ne [string]$s.Name) { $expected += ($base + ' (per-user service, exists only while a user is signed in)') }
            else { $missing += $base }
            continue
        }
        $now = $nowRunning[$base]
        if ($now.State -eq 'Running') { continue }
        $text = $base + ' (' + $now.State + ', ' + $now.StartMode + ')'
        if ([string]$now.StartMode -eq 'Disabled') { $disabled += $text; $explainedSvc += $base }
        elseif ([string]$now.StartMode -eq 'Manual' -and $script:ExpectedManualServices -contains $base) { $expected += ($text + ' - starts on demand in newer Windows'); $explainedSvc += $base }
        else { $stopped += $text }
    }
    if ($disabled.Count -gt 0) { $diff += (& $make 'WARNING' 'Automatic services now disabled' ('Count=' + $disabled.Count) ($disabled -join ', ') 'These ran before the upgrade and are now disabled, often by hardening applied after the upgrade. Confirm each one is disabled on purpose and that no application needs it.') }
    if ($expected.Count -gt 0) { $diff += (& $make 'INFO' 'Service changes made by Windows' ('Count=' + $expected.Count) ($expected -join ', ') 'Expected with the new Windows release; no action unless an application depends on them.') }
    if ($stopped.Count -gt 0) { $diff += (& $make 'ACTION' 'Automatic services no longer running' ('Count=' + $stopped.Count) ($stopped -join ', ') 'These ran before the upgrade. Start them, check their event logs, and confirm with the application owner.') }
    if ($missing.Count -gt 0) { $diff += (& $make 'WARNING' 'Services no longer present' ('Count=' + $missing.Count) ($missing -join ', ') 'These running services no longer exist. Expected for some Windows components; confirm none belongs to an application.') }

    $lists = @(
        @{ Name='Listening ports';   Prop='Ports';        Status='WARNING'; Rec='These ports listened before the upgrade. Confirm the owning service is running and test from a client.' },
        @{ Name='Static routes';     Prop='Routes';       Status='ACTION';  Rec='Re-create the missing routes (route -p add / New-NetRoute) and test the destinations.' },
        @{ Name='IPv4 addresses';    Prop='IPv4';         Status='ACTION';  Rec='Restore the IP configuration; check teaming and adapter names.' },
        @{ Name='DNS servers';       Prop='Dns';          Status='WARNING'; Rec='Restore the DNS server configuration on the adapter.' },
        @{ Name='Hosts file entries';Prop='Hosts';        Status='WARNING'; Rec='Restore the missing hosts entries if still needed.' },
        @{ Name='Applications';      Prop='Apps';         Status='WARNING'; Rec='Applications that disappeared during the upgrade must be reinstalled or confirmed obsolete by the owner.' },
        @{ Name='Windows features';  Prop='Features';     Status='WARNING'; Rec='Features removed by Setup. Confirm nothing depends on them.' },
        @{ Name='Scheduled tasks';   Prop='Tasks';        Status='WARNING'; Rec='Re-create missing tasks and confirm their run-as credentials.' },
        @{ Name='Applied GPOs';      Prop='Gpos';         Status='WARNING'; Rec='These GPOs applied before the upgrade and no longer do. Check their WMI filters (often a Windows version filter) and security filtering.' },
        @{ Name='Printers';          Prop='Printers';     Status='ACTION';  Rec='These printers existed before the upgrade. Restore them from the PrintBrm backup (PrintBrm -R -F <file>) or re-create them, then print a test page and test from a client.' },
        @{ Name='Printer ports';     Prop='PrinterPorts'; Status='ACTION';  Rec='These printer ports existed before the upgrade. Re-create them (address and protocol are in the pre-upgrade report) or restore the PrintBrm backup.' },
        @{ Name='File shares';       Prop='Shares';       Status='ACTION';  Rec='These folders were shared before the upgrade. Re-create the shares with their permissions (see the pre-upgrade report) and test access from a client.' },
        @{ Name='AD groups';         Prop='Groups';       Status='WARNING'; Rec='The computer was in these groups before. Check the AD group memberships (patch rings, GPO filtering, certificate enrolment).' }
    )
    if ($Before.Ou -and $After.Ou -and [string]$Before.Ou -ne [string]$After.Ou) {
        $diff += (& $make 'WARNING' 'Computer object moved in AD' ([string]$After.Ou) ('Before: ' + [string]$Before.Ou) 'The computer object is in another OU than before the upgrade, so other GPOs may apply. Move it back or confirm the new location with the AD team.')
    }
    # A security setting weakened by the upgrade or the after-work (#158).
    if ([string]$Before.Nla -eq 'On' -and [string]$After.Nla -eq 'Off') {
        $diff += (& $make 'ACTION' 'RDP Network Level Authentication turned off' 'Off' 'Before: On' 'NLA was on before the upgrade and is off now: RDP accepts connections before the user is authenticated. Turn it back on (System Properties > Remote, or the RDP-Tcp UserAuthentication value) unless the change was intended, and find out what changed it (the upgrade, a hardening script, a GPO).')
    }
    if ($Before.Uac -and $After.Uac -and [string]$Before.Uac -ne [string]$After.Uac) {
        $diff += (& $make 'WARNING' 'UAC changed' ([string]$After.Uac) ('Before: ' + [string]$Before.Uac) 'User Account Control is set differently after the upgrade. Confirm the change is intended (usually set by Group Policy).')
    }
    # Per adapter, matched by MAC, when both runs have the adapter list
    # (#149, from 4.5.0); otherwise the flat address lists of older baselines.
    if (@($Before.Adapters | Where-Object { $_ }).Count -gt 0 -and $null -ne $After.Adapters) {
        foreach ($r in @(Compare-NetworkAdapter $Before.Adapters $After.Adapters)) { $diff += $r }
        $lists = @($lists | Where-Object { $_.Prop -ne 'IPv4' -and $_.Prop -ne 'Dns' })
    }
    foreach ($l in $lists) {
        $b = @($Before.($l.Prop) | Where-Object { $_ })
        $a = @($After.($l.Prop) | Where-Object { $_ })
        if ($l.Prop -eq 'Apps') { $b = @($b | ForEach-Object { [string]$_.Name }); $a = @($a | ForEach-Object { [string]$_.Name }) }
        if ($l.Prop -eq 'Tasks') {
            # A task renamed only by its version or GUID still exists (#196).
            $aBase = @($a | ForEach-Object { ConvertTo-TaskBaseName ([string]$_) })
            $lost = @($b | Where-Object { $a -notcontains $_ -and $aBase -notcontains (ConvertTo-TaskBaseName ([string]$_)) } | Sort-Object -Unique)
        } else {
            $lost = @($b | Where-Object { $a -notcontains $_ } | Sort-Object -Unique)
        }
        if ($l.Prop -eq 'Features') {
            # Removed or renamed by Microsoft: expected (#158). .NET 3.5 is
            # removed by the upgrade and often needed by applications.
            $known = @($lost | Where-Object { $script:ExpectedRemovedFeatures -contains $_ })
            if ($known.Count -gt 0) { $diff += (& $make 'INFO' 'Windows features removed or renamed by Microsoft' ('Count=' + $known.Count) ($known -join ', ') 'Expected with the new Windows release (PowerShell 2.0 is removed in Windows Server 2025; Defender features were renamed; Azure Arc Setup became a Feature on Demand). No action unless something depended on them.') }
            if ($lost -contains 'NET-Framework-Core') { $diff += (& $make 'WARNING' '.NET Framework 3.5 removed by the upgrade' 'NET-Framework-Core' 'Installed before the upgrade, not after.' 'Reinstall .NET Framework 3.5 if an application on this server needs it (from the sources\sxs folder of the installation media): Install-WindowsFeature NET-Framework-Core -Source <media>\sources\sxs') }
            $lost = @($lost | Where-Object { $script:ExpectedRemovedFeatures -notcontains $_ -and $_ -ne 'NET-Framework-Core' })
        }
        if ($l.Prop -eq 'Ports') {
            # A port whose service was disabled or changed on purpose is not a
            # second problem (#158).
            $owners = @{}
            if ($Before.PortOwners -is [System.Collections.IDictionary]) { foreach ($k in @($Before.PortOwners.Keys)) { $owners[[string]$k] = [string]$Before.PortOwners[$k] } }
            elseif ($Before.PortOwners) { foreach ($p in @($Before.PortOwners.PSObject.Properties)) { $owners[$p.Name] = [string]$p.Value } }
            # Also a port whose service no longer starts automatically and is
            # not running, whatever its start mode was before (#173).
            $quiet = @($After.Services | Where-Object { [string]$_.State -ne 'Running' -and [string]$_.StartMode -ne 'Auto' } | ForEach-Object { ConvertTo-ServiceBaseName ([string]$_.Name) })
            $candidates = @($explainedSvc) + $quiet
            $explainedPorts = @($lost | Where-Object {
                $o = $owners[$_]; if (-not $o) { $o = $script:KnownPortServices[$_] }
                $o -and @($candidates | Where-Object { $o -match ('(^|[ /,])' + [regex]::Escape($_) + '($|[ /,])') }).Count -gt 0
            })
            if ($explainedPorts.Count -gt 0) { $diff += (& $make 'INFO' 'Ports closed with their service' ('Count=' + $explainedPorts.Count) ($explainedPorts -join ', ') 'The service that opened these ports is now disabled or starts on demand (see the service rows above).') }
            $lost = @($lost | Where-Object { $explainedPorts -notcontains $_ })
        }
        if ($lost.Count -gt 0) { $diff += (& $make $l.Status ($l.Name + ' missing after upgrade') ('Count=' + $lost.Count) ($lost -join ', ') $l.Rec) }
    }
    # Printers that now use another driver (#148).
    if ($null -ne $Before.PrinterDrivers -and $null -ne $After.PrinterDrivers) {
        $changedDrivers = Compare-PrinterDriver $Before.PrinterDrivers $After.PrinterDrivers
        if (@($changedDrivers).Count -gt 0) { $diff += (& $make 'WARNING' 'Printer drivers changed' ('Count=' + @($changedDrivers).Count) (@($changedDrivers) -join ', ') 'The upgrade gave these printers another driver (often a Microsoft class driver). Print a test page and check trays, finishing and driver settings; reinstall the vendor driver if needed.') }
    }
    # Group Policy can also start applying after the upgrade (#80). Only
    # compared when the baseline has the list (4.2.0 and later).
    if ($null -ne $Before.Gpos -and $null -ne $After.Gpos) {
        $b = @($Before.Gpos | Where-Object { $_ }); $a = @($After.Gpos | Where-Object { $_ })
        $new = @($a | Where-Object { $b -notcontains $_ } | Sort-Object -Unique)
        if ($new.Count -gt 0) { $diff += (& $make 'WARNING' 'GPOs newly applied after upgrade' ('Count=' + $new.Count) ($new -join ', ') 'These GPOs did not apply before the upgrade. Confirm they are intended for this server (WMI filters on the Windows version often cause this).') }
    }
    return ,$diff
}

function ConvertFrom-GpResultXml {
    # Pure: parses "gpresult /scope computer /x" (RSoP XML) into the GPOs
    # that applied, the GPOs that were filtered out with the reason, and the
    # computer's security groups (#80). Namespace-agnostic, so it reads the
    # output of every supported Windows release.
    param([Parameter(Mandatory=$true)][string]$Xml)
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($Xml)
    $computer = $doc.SelectSingleNode("//*[local-name()='ComputerResults']")
    if (-not $computer) { throw 'No computer results in the gpresult output.' }
    $text = {
        param($Node, [string]$Name)
        $n = $Node.SelectSingleNode("*[local-name()='" + $Name + "']")
        if ($n) { return ([string]$n.InnerText).Trim() }
        return ''
    }
    $gpos = @()
    foreach ($g in @($computer.SelectNodes("*[local-name()='GPO']"))) {
        $name = & $text $g 'Name'
        $guid = ''
        $id = $g.SelectSingleNode("*[local-name()='Path']/*[local-name()='Identifier']")
        if ($id) { $guid = ([string]$id.InnerText).Trim() }
        $links = @()
        $appliedLink = $false
        foreach ($l in @($g.SelectNodes("*[local-name()='Link']"))) {
            $som = & $text $l 'SOMPath'
            $order = 0; [void][int]::TryParse((& $text $l 'AppliedOrder'), [ref]$order)
            $linkOn = ((& $text $l 'Enabled') -ne 'false')
            if ($som) { $links += $som }
            if ($linkOn -and $order -gt 0) { $appliedLink = $true }
        }
        $reason = ''
        if ((& $text $g 'AccessDenied') -eq 'true') { $reason = 'Denied (security filtering)' }
        elseif ((& $text $g 'FilterAllowed') -eq 'false') { $reason = 'Denied (WMI filter)' }
        elseif ((& $text $g 'Enabled') -eq 'false') { $reason = 'Disabled GPO' }
        elseif ((& $text $g 'IsValid') -eq 'false') { $reason = 'Not valid' }
        elseif (-not $appliedLink) { $reason = 'Not applied (link disabled or empty GPO)' }
        $gpos += [pscustomobject]@{
            Name = $name; Guid = $guid; Applied = (-not $reason); Reason = $reason
            Links = $links; FilterName = (& $text $g 'FilterName')
        }
    }
    $groups = @()
    foreach ($sg in @($computer.SelectNodes("*[local-name()='SecurityGroup']"))) {
        $n = & $text $sg 'Name'
        if (-not $n) { $n = & $text $sg 'SID' }
        if ($n) { $groups += $n }
    }
    return [pscustomobject]@{
        Domain = (& $text $computer 'Domain'); Site = (& $text $computer 'Site')
        Gpos = $gpos; Groups = @($groups | Sort-Object -Unique)
    }
}

function ConvertFrom-WmiFilterParm {
    # Pure: the queries stored in a WMI filter's msWMI-Parm2 attribute, for
    # example "1;3;10;66;WQL;root\CIMv2;SELECT * FROM Win32_OperatingSystem
    # WHERE Version LIKE '10.0.%';". Fields are separated by ";", and each
    # query is preceded by its length.
    param([string]$Parm)
    $queries = @()
    if (-not $Parm) { return ,$queries }
    $parts = $Parm -split ';'
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($parts[$i] -eq 'WQL' -and $i + 2 -lt $parts.Count) {
            $queries += [pscustomobject]@{ Namespace = $parts[$i + 1]; Query = $parts[$i + 2] }
            $i += 2
        }
    }
    return ,$queries
}

function Test-WmiFilterOsDependent {
    # Pure: true when a WMI filter selects on the Windows version, build or
    # caption - such a filter can stop or start matching after an in-place
    # upgrade. ProductType (server/DC) alone does not change with the upgrade.
    param([string]$Query)
    if (-not $Query) { return $false }
    return ($Query -match 'Win32_OperatingSystem' -and $Query -match '\b(Version|BuildNumber|Caption|OperatingSystemSKU)\b')
}

function Get-GroupPolicyDecision {
    # Pure: what the report says about Group Policy (#80), in three cases:
    # workgroup (only local policy, never MANUAL), domain member with the
    # data read, and domain member where gpresult or AD could not be read
    # (MANUAL, never an empty list that looks clean).
    param(
        [bool]$PartOfDomain,
        [bool]$GpResultRead,
        [bool]$AdRead,
        $LastApplied,
        [datetime]$Now,
        [int]$MaxAgeDays = 7,
        [string]$GpResultError = '',
        [string]$AdError = ''
    )
    $rows = @()
    if (-not $PartOfDomain) {
        $rows += [pscustomobject]@{ Item = 'GroupPolicyScope'; Status = 'INFO'; Kind = 'Evidence'; Value = 'Workgroup server: only local policy applies'; Details = 'No domain GPOs or AD groups apply to a workgroup server.'; Recommendation = '' }
        return ,$rows
    }
    if (-not $GpResultRead) {
        $rows += [pscustomobject]@{ Item = 'GroupPolicyScope'; Status = 'MANUAL'; Kind = 'Finding'; Value = 'Could not read the applied Group Policy (gpresult)'; Details = $GpResultError; Recommendation = 'The GPO list is missing - this is not evidence that no GPO applies. Run "gpresult /scope computer /h gp.html" as administrator and review it before the change.' }
    }
    if (-not $AdRead) {
        $rows += [pscustomobject]@{ Item = 'DomainLookup'; Status = 'MANUAL'; Kind = 'Finding'; Value = 'Could not reach the domain: WMI filters and AD groups are incomplete'; Details = $AdError; Recommendation = 'Check domain connectivity from this server, then re-run. Until then, review the WMI filters of the GPOs and the computer''s groups in Active Directory manually.' }
    }
    if ($null -eq $LastApplied) {
        $rows += [pscustomobject]@{ Item = 'GroupPolicyLastApplied'; Status = 'MANUAL'; Kind = 'Observation'; Value = 'Not readable'; Details = ''; Recommendation = 'Check "gpresult /r" for the last time Group Policy was applied.' }
    } else {
        $age = [math]::Floor(($Now - [datetime]$LastApplied).TotalDays)
        if ($age -gt $MaxAgeDays) {
            $rows += [pscustomobject]@{ Item = 'GroupPolicyLastApplied'; Status = 'WARNING'; Kind = 'Finding'; Value = ('This server has not received Group Policy since ' + ([datetime]$LastApplied).ToString('yyyy-MM-dd HH:mm') + ' (' + $age + ' days)'); Details = ('Limit: ' + $MaxAgeDays + ' days (GroupPolicyMaxAgeDays)'); Recommendation = 'Find out why (domain connectivity, secure channel, Group Policy errors in the System log), fix it and run "gpupdate /target:computer" before the change.' }
        } else {
            $rows += [pscustomobject]@{ Item = 'GroupPolicyLastApplied'; Status = 'OK'; Kind = 'Evidence'; Value = ([datetime]$LastApplied).ToString('yyyy-MM-dd HH:mm'); Details = ($age.ToString() + ' days ago'); Recommendation = '' }
        }
    }
    return ,$rows
}

function ConvertFrom-FileTimeValue {
    # Pure: a FILETIME stored as two DWORD registry values (high, low).
    param($High, $Low)
    if ($null -eq $High -or $null -eq $Low) { return $null }
    # Registry DWORDs arrive as Int32 (possibly negative): mask to 32 bits.
    $mask = [int64]4294967295
    $value = (([int64]$High -band $mask) -shl 32) -bor ([int64]$Low -band $mask)
    if ($value -le 0) { return $null }
    try { return [DateTime]::FromFileTime($value) } catch { return $null }
}

# Official pages linked from recommendations (#79). Only stable pages;
# the report text must make sense without them (servers are often offline).
# Verified (the Microsoft links open; the Trend Micro page was not reachable
# from the checking session): see $script:FactSources.DocLinks.
$script:DocLinks = @{
    Lifecycle      = @{ Url = 'https://learn.microsoft.com/en-us/lifecycle/products/?terms=windows%20server'; Title = 'Microsoft Lifecycle: Windows Server' }
    InPlaceUpgrade = @{ Url = 'https://learn.microsoft.com/en-us/windows-server/get-started/perform-in-place-upgrade'; Title = 'Microsoft: Perform an in-place upgrade of Windows Server' }
    SetupOptions   = @{ Url = 'https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-command-line-options'; Title = 'Microsoft: Windows Setup command-line options (/Compat ScanOnly)' }
    AppCmd         = @{ Url = 'https://learn.microsoft.com/en-us/iis/get-started/getting-started-with-iis/getting-started-with-appcmdexe'; Title = 'Microsoft: Getting started with AppCmd.exe (backups)' }
    WinReResize    = @{ Url = 'https://support.microsoft.com/en-us/topic/kb5028997-instructions-to-manually-resize-your-partition-to-install-the-winre-update-400faa27-9343-461c-ada9-24c8229763bf'; Title = 'Microsoft KB5028997: WinRE partition, reagentc and diskpart steps' }
    TrendAgents    = @{ Url = 'https://docs.trendmicro.com/en-us/documentation/article/trend-vision-one-agent-platform-compatibility'; Title = 'Trend Micro: agent platform compatibility' }
}

function Get-RecommendationCommand {
    # Pure: the exact command shown with a recommendation (#79). Every
    # command is built here, so each one has a test of its exact text.
    # The script never runs these commands.
    param([Parameter(Mandatory=$true)][string]$Id, [hashtable]$Values = @{})
    switch ($Id) {
        'PendingRename' { return [pscustomobject]@{ Kind = 'Check'; Command = "Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PendingFileRenameOperations" } }
        'Restart'       { return [pscustomobject]@{ Kind = 'Change'; Command = 'Restart-Computer' } }
        'IisBackup'     { return [pscustomobject]@{ Kind = 'Change'; Command = '& "$env:windir\system32\inetsrv\appcmd.exe" add backup "PreIPU"' } }
        'FolderAcl'     { return [pscustomobject]@{ Kind = 'Change'; Command = ('icacls "' + $Values.Path + '" /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F') } }
        'EnableNla'     { return [pscustomobject]@{ Kind = 'Change'; Command = 'Get-CimInstance -Namespace root\cimv2\TerminalServices -ClassName Win32_TSGeneralSetting -Filter "TerminalName=''RDP-tcp''" | Invoke-CimMethod -MethodName SetUserAuthenticationRequired -Arguments @{ UserAuthenticationRequired = 1 }' } }
        'LbfoTeams'     { return [pscustomobject]@{ Kind = 'Check'; Command = 'Get-NetLbfoTeam | Format-List Name, Status, TeamingMode, LoadBalancingAlgorithm, Members' } }
        'SetupNoRecoveryPartition' { return [pscustomobject]@{ Kind = 'Change'; Command = 'setup.exe /ResizeRecoveryPartition Disable' } }
        'RemoveRecoveryPartition' {
            # Run line by line; the diskpart lines go inside diskpart (#161).
            $lines = @('reagentc /info', 'reagentc /disable', 'diskpart', ('  select disk ' + $Values.Disk), ('  select partition ' + $Values.Partition), '  delete partition override', '  select volume c', '  extend', '  exit', 'reagentc /enable', 'reagentc /info')
            return [pscustomobject]@{ Kind = 'Change'; Command = ($lines -join [Environment]::NewLine) }
        }
        'CFreeSpace'    { return [pscustomobject]@{ Kind = 'Check'; Command = 'Get-Volume -DriveLetter C | Format-List DriveLetter, FileSystemLabel, @{ n = ''SizeGB''; e = { [math]::Round($_.Size / 1GB, 1) } }, @{ n = ''FreeGB''; e = { [math]::Round($_.SizeRemaining / 1GB, 1) } }' } }
    }
    throw ('Unknown recommendation command: ' + $Id)
}

# Smallest recovery partition that held the Windows Server 2025 WinRE in a
# live run (#161): Setup created 901 MB partitions with 147 MB free.
# Verified: see $script:FactSources.WinReMinPartitionMB.
$script:WinReMinPartitionMB = 900

function ConvertFrom-ReagentcInfo {
    # Pure (#161): status and location from "reagentc /info". The location
    # (\\?\GLOBALROOT\device\harddiskN\partitionM\...) is language
    # neutral; the status words are read in English only.
    param([string]$Text)
    $r = [pscustomobject]@{ Enabled = $null; Disk = $null; Partition = $null }
    if (-not $Text) { return $r }
    if ($Text -match 'harddisk(\d+)\\partition(\d+)') { $r.Disk = [int]$Matches[1]; $r.Partition = [int]$Matches[2] }
    if ($Text -match 'Windows RE status:\s*Enabled') { $r.Enabled = $true } elseif ($Text -match 'Windows RE status:\s*Disabled') { $r.Enabled = $false }
    return $r
}

function Get-RecoveryPartitionDecision {
    # Pure (#161). Partitions of the C: disk: PartitionNumber, Offset,
    # SizeMB, IsRecovery. A recovery partition after C: blocks extending C:
    # (Setup creates one when no recovery partition is big enough for the new
    # WinRE). Before the upgrade, predict that and point to the Setup switch.
    param([object[]]$Partitions, [int]$CPartitionNumber, $WinRePartition = $null, [string]$Mode = 'Pre')
    $c = @($Partitions | Where-Object { [int]$_.PartitionNumber -eq $CPartitionNumber }) | Select-Object -First 1
    $recovery = @($Partitions | Where-Object { $_.IsRecovery })
    $after = @($recovery | Where-Object { $c -and [double]$_.Offset -gt [double]$c.Offset } | Sort-Object Offset)
    if ($after.Count -gt 0) {
        $p = $after[0]
        if ($null -ne $WinRePartition) { $hit = @($after | Where-Object { [int]$_.PartitionNumber -eq [int]$WinRePartition }) | Select-Object -First 1; if ($hit) { $p = $hit } }
        $holds = ''; if ($null -ne $WinRePartition -and [int]$WinRePartition -eq [int]$p.PartitionNumber) { $holds = ' WinRE is on it.' }
        return [pscustomobject]@{ Status = 'WARNING'; Kind = 'AfterC'; PartitionNumber = [int]$p.PartitionNumber
            Value = ('Recovery partition P' + $p.PartitionNumber + ' (' + [math]::Round([double]$p.SizeMB) + ' MB) directly after C:')
            Text = ('This partition blocks extending C: later.' + $holds + ' If C: must be extendable, remove it in a change with a snapshot: move WinRE to C: first (reagentc /disable), delete only this partition, extend C:, then reagentc /enable. Never skip reagentc /disable: deleting the partition first deletes the only copy of WinRE. Leave a recovery partition at the start of the disk alone. See the user guide, "Recovery partition after an upgrade".') }
    }
    if ($Mode -eq 'Pre') {
        $big = @($recovery | Where-Object { [double]$_.SizeMB -ge $script:WinReMinPartitionMB })
        if ($big.Count -eq 0) {
            $what = 'No recovery partition'; if ($recovery.Count -gt 0) { $what = 'Recovery partition smaller than ' + $script:WinReMinPartitionMB + ' MB' }
            return [pscustomobject]@{ Status = 'WARNING'; Kind = 'LikelyNew'; PartitionNumber = $null
                Value = ($what + ': Setup will likely add one after C:')
                Text = 'Without a recovery partition big enough for the new WinRE, Setup shrinks C: and creates a new recovery partition directly after it, which blocks extending C: later. Start Setup with /ResizeRecoveryPartition Disable to prevent this.' }
        }
    }
    return [pscustomobject]@{ Status = 'INFO'; Kind = 'Fine'; PartitionNumber = $null; Value = 'No recovery partition after C:'; Text = '' }
}

function Test-LgpoAvailable {
    # True when -LgpoExe names an existing file (#150). An empty value means
    # LGPO is switched off; Test-Path cannot take an empty path on PS 4/5.1.
    if (-not $LgpoExe) { return $false }
    return [bool](Test-Path -LiteralPath $LgpoExe -PathType Leaf)
}

function Get-LocalPolicyAdvice {
    # Pure (#150): where to read the local policy when gpresult cannot list
    # it. Points to the LGPO backup only when this run will make one.
    param([bool]$LgpoAvailable, [bool]$EvidenceEnabled)
    $manual = 'Run "gpresult /scope computer /h gp.html" as administrator and review it before the change.'
    if ($LgpoAvailable -and $EvidenceEnabled) { return ('The local policy backup (LGPO) in the RDP policy evidence folder shows the settings. Or: ' + $manual) }
    return $manual
}

function Get-RdpAccessFact {
    # The Summary's "RDP access" line with NLA folded in (#174).
    $rdp = [string]$script:Data.RdpSummary
    if (-not $rdp) { $rdp = 'Not reported' }
    return ($rdp + ', ' + (Get-NlaFactText ([string]$script:Data.NlaState) ([string]$script:Data.NlaBefore)))
}

function Get-NlaFactText {
    # Pure (#174): RDP Network Level Authentication for the Summary. Unknown
    # is never shown as on; a change since the pre-upgrade run is named.
    param([string]$Now, [string]$Before = '')
    if ($Now -ne 'On' -and $Now -ne 'Off') { return 'NLA unknown' }
    $t = 'NLA ' + $Now.ToLowerInvariant()
    if (($Before -eq 'On' -or $Before -eq 'Off') -and $Before -ne $Now) { $t += ' (was ' + $Before.ToLowerInvariant() + ' before the upgrade)' }
    return $t
}

function Get-OptionalProperty {
    # A property that older Windows releases may not have; $null when absent.
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-ActivationDecision {
    # Pure (#171): the activation row per channel. KMS clients name the host
    # that activated them, how it was found and the days to renewal; MAK,
    # AVMA, OEM and retail get their own plain text, never KMS wording.
    param([string]$Kind, [int]$LicenseStatus, [string]$StateName, [string]$Channel, $GraceMinutes, [string]$DiscoveredHost, [string]$DiscoveredPort, [string]$ConfiguredHost, [string]$ConfiguredPort, [int]$RenewWarnDays = 30)
    $licensed = ($LicenseStatus -eq 1)
    $days = $null; if ($null -ne $GraceMinutes -and [int64]$GraceMinutes -gt 0) { $days = [int][math]::Floor([int64]$GraceMinutes / 1440) }
    $r = [pscustomobject]@{ Status = 'OK'; Value = ''; Details = @(); Text = ''; KmsHost = ''; KmsEndpoint = '' }
    switch ($Kind) {
        'KMS' {
            $hostName = $DiscoveredHost; $port = $DiscoveredPort; $how = 'found via DNS'
            if ($ConfiguredHost) { $hostName = $ConfiguredHost; $port = $ConfiguredPort; $how = 'set manually on this server' }
            if ($hostName) {
                $r.KmsHost = $hostName
                $r.KmsEndpoint = $hostName + $(if ($port) { ':' + $port } else { '' })
            }
            if ($licensed) {
                $r.Value = 'Licensed (KMS client)'
                if ($r.KmsEndpoint) { $r.Value += ', activated by ' + $r.KmsEndpoint + ', ' + $how } else { $r.Value += ', KMS host not reported' }
                if ($null -ne $days) {
                    $r.Value += '. Renewal due in ' + $days + ' days'
                    if ($days -lt $RenewWarnDays) { $r.Status = 'WARNING'; $r.Text = 'The activation has not been renewed recently: the server has not reached a KMS host for a while. Check that the KMS host is reachable (DNS SRV record _vlmcs._tcp, TCP 1688) before the upgrade.' }
                }
                $r.Details = @(('KMS host: ' + $(if ($r.KmsEndpoint) { $r.KmsEndpoint + ' (' + $how + ')' } else { 'not reported' })))
            } else {
                $r.Status = 'ACTION'
                $r.Value = 'Not activated (' + $StateName + ', KMS client)'
                $r.Text = 'The server could not activate with a KMS host. Check the DNS SRV record _vlmcs._tcp (or the host set with slmgr /skms) and that TCP 1688 to the KMS host is open, then run slmgr /ato. Resolve before the upgrade.'
            }
        }
        'MAK' {
            if ($licensed) { $r.Value = 'Licensed (MAK), activated permanently - no renewal needed' }
            else { $r.Status = 'ACTION'; $r.Value = 'Not activated (' + $StateName + ', MAK)'; $r.Text = 'Activate with the MAK (slmgr /ato, online or by phone) before the upgrade.' }
        }
        'AVMA' {
            if ($licensed) { $r.Value = 'Licensed (AVMA), activated through the Hyper-V host' }
            else { $r.Status = 'ACTION'; $r.Value = 'Not activated (' + $StateName + ', AVMA)'; $r.Text = 'AVMA needs a Hyper-V host running Datacenter that is itself activated. Check the host, then the guest.' }
        }
        default {
            $label = $Kind; if (-not $label -or $label -eq 'Unknown') { $label = $Channel }
            if ($licensed) { $r.Value = 'Licensed (' + $label + ')' }
            else { $r.Status = 'ACTION'; $r.Value = 'Not activated (' + $StateName + ', ' + $label + ')'; $r.Text = 'Resolve the activation before the upgrade (slmgr /dlv shows the details).' }
        }
    }
    return $r
}

function Get-DomainRoleText {
    # Pure (#98): the domain role in the words operators use. Win32 calls a
    # non-domain server "Standalone server"; most people say workgroup server.
    param([int]$DomainRole, [string]$DomainOrWorkgroup)
    switch ($DomainRole) {
        0 { $t = 'Workgroup computer (standalone)' }
        1 { $t = 'Member workstation' }
        2 { $t = 'Workgroup server (standalone)' }
        3 { $t = 'Member server' }
        4 { $t = 'Backup domain controller' }
        5 { $t = 'Primary domain controller' }
        default { $t = 'Unknown role (' + $DomainRole + ')' }
    }
    if ($DomainRole -in @(0, 2) -and $DomainOrWorkgroup) { $t += ', workgroup ' + $DomainOrWorkgroup }
    return $t
}

function Get-UacDecision {
    # Pure: User Account Control in plain words from the registry values
    # under HKLM\...\Policies\System (#75). Missing values mean the
    # Windows defaults (EnableLUA 1, ConsentPromptBehaviorAdmin 5,
    # PromptOnSecureDesktop 1, FilterAdministratorToken 0).
    param($EnableLua, $ConsentPromptBehaviorAdmin, $PromptOnSecureDesktop, $FilterAdministratorToken)
    $num = { param($v, [int]$Default) if ($null -eq $v -or [string]$v -eq '') { return $Default }; return [int]$v }
    $lua = & $num $EnableLua 1
    if ($lua -eq 0) {
        return [pscustomobject]@{ State = 'Off'; Text = 'Off - administrators run everything elevated without a prompt (EnableLUA=0)' }
    }
    $consent = & $num $ConsentPromptBehaviorAdmin 5
    $secure = & $num $PromptOnSecureDesktop 1
    $texts = @{ 0 = 'elevate without prompting'; 1 = 'prompt for credentials on the secure desktop'; 2 = 'prompt for consent on the secure desktop'; 3 = 'prompt for credentials'; 4 = 'prompt for consent'; 5 = 'prompt for consent for non-Windows programs (Windows default)' }
    $text = $texts[$consent]
    if (-not $text) { $text = 'unknown prompt behaviour (ConsentPromptBehaviorAdmin=' + $consent + ')' }
    if ($consent -ge 3 -and $consent -le 5 -and $secure -eq 0) { $text += ', not on the secure desktop' }
    $result = 'On - ' + $text
    if ((& $num $FilterAdministratorToken 0) -eq 1) { $result += '; built-in Administrator also gets prompts (Admin Approval Mode)' }
    return [pscustomobject]@{ State = 'On'; Text = $result }
}

function Get-OutputFolderAccessDecision {
    # Pure: what the report says about the output folder's permissions.
    param([string]$State, [string[]]$BroadReaders = @(), [string]$Path = '')
    $readers = @($BroadReaders | Where-Object { $_ })
    switch ($State) {
        'CreatedRestricted' {
            return [pscustomobject]@{ Status='OK'; Kind='Evidence'; Text='Created by this run; access limited to SYSTEM and Administrators.' }
        }
        'CreatedUnrestricted' {
            return [pscustomobject]@{ Status='WARNING'; Kind='Observation'; Text='Created by this run, but its permissions could not be restricted (see the log). Restrict access manually; the reports describe the server in detail.' }
        }
        'Created' {
            return [pscustomobject]@{ Status='INFO'; Kind='Evidence'; Text='Created by this run with inherited permissions (RestrictOutputAcl is off).' }
        }
    }
    if ($readers.Count -gt 0) {
        return [pscustomobject]@{ Status='WARNING'; Kind='Observation'
            Text=('Existing folder readable by ' + ($readers -join ', ') + '. The reports describe the server in detail. Restrict it with the command shown, or delete the folder so the next run recreates it restricted.')
            Command=(Get-RecommendationCommand 'FolderAcl' @{ Path = $Path }).Command }
    }
    return [pscustomobject]@{ Status='INFO'; Kind='Evidence'; Text='Existing folder; its permissions were left unchanged and do not grant read access to Everyone, Authenticated Users or Users.' }
}

function ConvertTo-RelaunchArgumentText {
    # Pure: turns the caller's bound parameters into PowerShell argument text
    # for the 64-bit relaunch (-Command). Strings are single-quoted with
    # embedded quotes doubled; booleans and switches keep their type. Any
    # other type throws, so a future parameter cannot be passed wrongly.
    param([System.Collections.IDictionary]$Parameters)
    $text = ''
    if ($null -eq $Parameters) { return $text }
    foreach ($key in @($Parameters.Keys | Sort-Object)) {
        $v = $Parameters[$key]
        if ($v -is [System.Management.Automation.SwitchParameter]) { $text += ' -' + $key + ':$' + ([bool]$v).ToString().ToLowerInvariant() }
        elseif ($v -is [bool]) { $text += ' -' + $key + ' $' + $v.ToString().ToLowerInvariant() }
        elseif ($v -is [int]) { $text += ' -' + $key + ' ' + $v.ToString([Globalization.CultureInfo]::InvariantCulture) }
        elseif ($v -is [string]) { $text += ' -' + $key + " '" + ($v -replace "'","''") + "'" }
        else {
            $typeName = '<null>'
            if ($null -ne $v) { $typeName = $v.GetType().FullName }
            throw ("Parameter '" + $key + "' has type " + $typeName + ", which the 64-bit relaunch cannot pass. Add support in ConvertTo-RelaunchArgumentText.")
        }
    }
    return $text
}

function Get-SlowCheckBudget {
    # Pure: DISM and SFC share SlowCheckBudgetMinutes; the optional Setup
    # compatibility scan adds its own timeout, but only when media is set and
    # the run is a pre-upgrade run (the scan does not run after the upgrade).
    param([int]$SlowCheckBudget, [int]$CompatScanTimeout, [string]$MediaPath, [string]$Mode)
    $minutes = $SlowCheckBudget
    if ($MediaPath -and $Mode -eq 'Pre') { $minutes += $CompatScanTimeout }
    return $minutes
}

function Get-SlowSecondsLeft {
    param([int]$BudgetMinutes, [double]$ElapsedSeconds)
    return [int](($BudgetMinutes * 60) - $ElapsedSeconds)
}

function Test-SlowCheckSkip {
    # Pure: a slow check needs at least one minute to be worth starting.
    param([int]$SecondsLeft)
    return ($SecondsLeft -lt 60)
}

function Add-SkippedSlowCheck {
    # Records a slow check that was not started because the budget ran out,
    # as a MANUAL finding and a Skipped run, so the gap is visible.
    param($Check, [int]$BudgetMinutes)
    $script:CurrentCheckId = $Check.Id
    Add-Result 'WINDOWS_HEALTH' $Check.Name 'MANUAL' 'Skipped - slow-check time budget used up' ('Budget=' + $BudgetMinutes + ' min') -Recommendation 'Run this check manually, or raise SlowCheckBudgetMinutes (and the SA job timeout).'
    $script:CheckRuns.Add([pscustomobject]@{ Id=$Check.Id; Name=$Check.Name; Phase='Slow'; Outcome='Skipped'; Duration='00:00:00'; Seconds=0; Message='Time budget used up' })
    $script:CurrentCheckId = 'core'
}

function Test-HttpSysBindingBlock {
    # Pure: true for a netsh "http show sslcert" block that describes a
    # binding. The header block ("SSL Certificate bindings:" and its dashes)
    # is not a binding. Labels stay English on localized Windows.
    param([string[]]$Lines)
    return (@($Lines | Where-Object { $_ -match '^\s*(IP:port|Hostname:port|Central Certificate Store)\s*:' }).Count -gt 0)
}

function Get-DefenderEndpointDecision {
    # Pure: the Defender for Endpoint sensor service (Sense) is part of
    # Windows Server 2019 and later even when the server was never
    # onboarded. Only an onboarded or running sensor is an EDR to plan for.
    param([string]$SenseState, $OnboardingState)
    if ([string]$OnboardingState -eq '1') { return [pscustomobject]@{ Status='WARNING'; Active=$true; Text='Onboarded (OnboardingState=1), service ' + $SenseState } }
    if ($SenseState -eq 'Running') { return [pscustomobject]@{ Status='WARNING'; Active=$true; Text='Sensor service running; onboarding state not readable' } }
    $state = 'not readable'; if ($null -ne $OnboardingState -and [string]$OnboardingState -ne '') { $state = [string]$OnboardingState }
    return [pscustomobject]@{ Status='INFO'; Active=$false; Text='Built-in sensor present, not onboarded (service ' + $SenseState + ', OnboardingState ' + $state + ')' }
}

function Get-SecurityToolDecision {
    # Pure: a security or monitoring tool with a kernel or filter driver can
    # break Windows Setup (a common cause of rollback), so it is a finding.
    # A user-mode tool without drivers rarely does; it is listed as an
    # observation to verify after the upgrade (#78).
    param([string[]]$Drivers = @(), [string]$Target = 'the target release')
    $drv = @($Drivers | Where-Object { $_ })
    if ($drv.Count -gt 0) {
        return [pscustomobject]@{ Kind = 'Finding'; Recommendation = ('Installs a driver (' + ($drv -join ', ') + '). Confirm this version supports ' + $Target + ' and whether the vendor wants it updated or stopped during Setup; drivers are a common cause of rollback.') }
    }
    return [pscustomobject]@{ Kind = 'Observation'; Recommendation = ('No driver found, so it rarely affects Setup. Check that it starts and reports again after the upgrade, and that the vendor supports ' + $Target + '.') }
}

function Get-DetectionProductName {
    # Pure: "<Label> <version>" from the first application that matched, so
    # the summary names the product and build that is installed.
    param($Match)
    $versions = @($Match.Apps | Where-Object { $_.Version } | ForEach-Object { ([string]$_.Version).Trim() } | Sort-Object -Unique)
    if ($versions.Count -gt 0) { return ($Match.Label + ' ' + ($versions -join '/')) }
    return [string]$Match.Label
}

function ConvertFrom-SiteDataJson {
    # Pure: parses the text of a site data file and checks its Schema field.
    # Throws a message meant for the report when the file cannot be used.
    param([string]$Text, [string]$Schema)
    if (-not $Text -or -not $Text.Trim()) { throw 'The file is empty.' }
    try { $obj = $Text | ConvertFrom-Json -ErrorAction Stop }
    catch { throw ('The file is not valid JSON: ' + $_.Exception.Message) }
    if ($null -eq $obj -or $obj -isnot [System.Management.Automation.PSCustomObject]) { throw 'The file must contain one JSON object.' }
    $found = $obj.PSObject.Properties | Where-Object { $_.Name -eq 'Schema' }
    if (-not $found -or [string]$found.Value -ne $Schema) { throw ('Schema must be "' + $Schema + '".') }
    return $obj
}

function Merge-DetectionPatternSet {
    # Pure: applies a pattern file (parsed JSON) to the built-in pattern table.
    # Per category, an entry whose Label matches a built-in entry replaces it,
    # Disabled = true removes it, and a new Label is added. Returns the merged
    # table, the changes made and the errors found; with errors, the caller
    # must keep the built-in table (nothing is applied in part).
    param([hashtable]$Default, $Override, [string[]]$Fields = $script:PatternFields)
    $errors = New-Object System.Collections.Generic.List[string]
    $changes = New-Object System.Collections.Generic.List[string]
    $merged = @{}
    foreach ($k in @($Default.Keys)) {
        $merged[$k] = @(foreach ($e in $Default[$k]) { $c = @{}; foreach ($f in @($e.Keys)) { $c[$f] = $e[$f] }; $c })
    }
    foreach ($prop in @($Override.PSObject.Properties)) {
        if ($prop.Name -eq 'Schema') { continue }
        $cat = @($Default.Keys | Where-Object { $_ -eq $prop.Name })
        if ($cat.Count -eq 0) { $errors.Add(('Unknown category "' + $prop.Name + '". Use: ' + ((@($Default.Keys) | Sort-Object) -join ', ') + '.')); continue }
        $cat = $cat[0]
        $entries = @($prop.Value)
        $n = 0
        foreach ($entry in $entries) {
            $n++
            $where = $cat + ' entry ' + $n
            if ($entry -isnot [System.Management.Automation.PSCustomObject]) { $errors.Add($where + ': must be an object.'); continue }
            $names = @($entry.PSObject.Properties | ForEach-Object { $_.Name })
            $unknown = @($names | Where-Object { $Fields -notcontains $_ })
            if ($unknown.Count -gt 0) { $errors.Add(($where + ': unknown field ' + ($unknown -join ', ') + '. Use: ' + ($Fields -join ', ') + '.')) ; continue }
            $label = [string]$entry.Label
            if (-not $label.Trim()) { $errors.Add($where + ': Label is required.'); continue }
            $where = $cat + ' "' + $label + '"'
            $idx = -1
            for ($i = 0; $i -lt $merged[$cat].Count; $i++) { if ($merged[$cat][$i].Label -ieq $label) { $idx = $i; break } }
            if ($names -contains 'Disabled') {
                if ($entry.Disabled -isnot [bool]) { $errors.Add($where + ': Disabled must be true or false.'); continue }
                if ($entry.Disabled) {
                    if ($idx -lt 0) { $errors.Add($where + ': cannot disable, there is no built-in entry with this Label.'); continue }
                    $merged[$cat] = @(for ($i = 0; $i -lt $merged[$cat].Count; $i++) { if ($i -ne $idx) { $merged[$cat][$i] } })
                    $changes.Add(($cat + ': disabled "' + $label + '"'))
                    continue
                }
            }
            $new = @{ Label = $label }
            $bad = $false
            foreach ($f in @('App','Service','Display','Driver')) {
                if ($names -notcontains $f) { continue }
                $value = $entry.$f
                if ($value -isnot [string] -or -not $value.Trim()) { $errors.Add($where + ': ' + $f + ' must be a non-empty text.'); $bad = $true; continue }
                try { $null = New-Object System.Text.RegularExpressions.Regex($value) }
                catch { $errors.Add(($where + ': ' + $f + ' is not a valid regular expression: ' + $_.Exception.InnerException.Message)); $bad = $true; continue }
                $new[$f] = $value
            }
            foreach ($f in @('Link','LinkTitle')) {
                if ($names -notcontains $f) { continue }
                $value = $entry.$f
                if ($value -isnot [string] -or -not $value.Trim()) { $errors.Add($where + ': ' + $f + ' must be a non-empty text.'); $bad = $true; continue }
                if ($f -eq 'Link' -and $value -notmatch '^https://[^\s"<>]+$') { $errors.Add($where + ': Link must be an https URL.'); $bad = $true; continue }
                $new[$f] = $value
            }
            if ($bad) { continue }
            if (@($new.Keys | Where-Object { @('App','Service','Display','Driver') -contains $_ }).Count -eq 0) { $errors.Add($where + ': needs at least one of App, Service, Display, Driver.'); continue }
            if ($idx -ge 0) { $merged[$cat][$idx] = $new; $changes.Add(($cat + ': replaced "' + $label + '"')) }
            else { $merged[$cat] = @($merged[$cat]) + @($new); $changes.Add(($cat + ': added "' + $label + '"')) }
        }
    }
    if ($changes.Count -eq 0 -and $errors.Count -eq 0) { $errors.Add('The file changes no pattern.') }
    return [pscustomobject]@{ Patterns = $merged; Changes = $changes.ToArray(); Errors = $errors.ToArray() }
}

function Get-ProfileSettingDecision {
    # Pure: checks a profile file (parsed JSON) against the settings it may
    # set. Each value is converted and validated with the parameter's own
    # attributes ($Attributes: name -> attribute list), so a profile cannot
    # set what the command line could not. Settings given as arguments
    # ($Bound) win and are listed as Ignored. With errors, apply nothing.
    param($Override, [hashtable]$Attributes, [string[]]$Allowed = $script:ProfileSettingNames, [string[]]$Bound = @())
    $errors = New-Object System.Collections.Generic.List[string]
    $ignored = New-Object System.Collections.Generic.List[string]
    $settings = [ordered]@{}
    foreach ($prop in @($Override.PSObject.Properties)) {
        if ($prop.Name -ne 'Schema' -and $prop.Name -ne 'Settings') { $errors.Add('Unknown field "' + $prop.Name + '". Use: Schema, Settings.') }
    }
    $block = $Override.PSObject.Properties | Where-Object { $_.Name -eq 'Settings' }
    if (-not $block -or $block.Value -isnot [System.Management.Automation.PSCustomObject]) {
        $errors.Add('Settings must be an object, for example "Settings": { "MinimumCFreeGB": 60 }.')
    } else {
        foreach ($s in @($block.Value.PSObject.Properties)) {
            $name = @($Allowed | Where-Object { $_ -eq $s.Name })
            if ($name.Count -eq 0) { $errors.Add(('"' + $s.Name + '" is not a profile setting. Use: ' + ($Allowed -join ', ') + '.')); continue }
            $name = $name[0]
            $attrs = New-Object 'System.Collections.ObjectModel.Collection[Attribute]'
            foreach ($a in @($Attributes[$name])) { if ($a -is [Attribute]) { $attrs.Add($a) } }
            try {
                $probe = New-Object System.Management.Automation.PSVariable($name, $s.Value, ([System.Management.Automation.ScopedItemOptions]::None), $attrs)
            } catch {
                $msg = $_.Exception.Message; if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
                $errors.Add(($name + ': value "' + [string]$s.Value + '" is not allowed. ' + $msg)); continue
            }
            if ($Bound -contains $name) { $ignored.Add($name); continue }
            $settings[$name] = $probe.Value
        }
    }
    if ($settings.Count -eq 0 -and $ignored.Count -eq 0 -and $errors.Count -eq 0) { $errors.Add('The file sets no setting.') }
    return [pscustomobject]@{ Settings = $settings; Ignored = $ignored.ToArray(); Errors = $errors.ToArray() }
}

function New-RedactionContext {
    # Holds the placeholder map for one run, so the same value always gets
    # the same placeholder (in the HTML, the JSON and both report writes).
    param([string]$ComputerName, [string]$DomainFqdn)
    $netbios = @()
    if ($DomainFqdn -and $DomainFqdn -match '\.') { $netbios += ($DomainFqdn -split '\.')[0] }
    if ($ComputerName) { $netbios += $ComputerName }
    return @{ Map = @{}; Counters = @{}; Originals = @{}; ComputerName = $ComputerName; DomainFqdn = $DomainFqdn; NetBios = $netbios; Literals = @{} }
}

# Names that never identify a site: built-in accounts and groups (#100).
$script:RedactionWellKnownNames = '^(SYSTEM|LocalSystem|LOCAL SERVICE|LocalService|NETWORK SERVICE|NetworkService|INTERACTIVE|Users|Administrators|Administrator|Everyone|Guest|Authenticated Users|Default Domain Policy|Default Domain Controllers Policy|Local Group Policy)$'
# Domain-relative RIDs of built-in domain accounts and groups (#156):
# Administrator, Guest, krbtgt, Domain Admins/Users/Guests/Computers/
# Controllers, Cert Publishers, Schema/Enterprise Admins, Group Policy
# Creator Owners, Read-only DCs, Cloneable DCs, Protected Users, Key Admins,
# Enterprise Key Admins, RAS and IAS Servers, Allowed/Denied RODC Password
# Replication Group.
$script:RedactionWellKnownRids = @(500,501,502,512,513,514,515,516,517,518,519,520,521,522,525,526,527,553,571,572)
# Public documentation and vendor domains kept in redacted reports (#100).
$script:RedactionKeepDomains = @('microsoft.com','windows.com','windowsupdate.com','trendmicro.com','broadcom.com','vmware.com','asp.net','microsoft.net','oracle.com','sap.com','citrix.com','apache.org','mysql.com','postgresql.org','ibm.com','veeam.com','commvault.com','crowdstrike.com','sentinelone.com','sophos.com','eset.com','kaspersky.com','trellix.com','mcafee.com','cisco.com','broadcom.net','tenable.com','nxlog.co','opentext.com')

function Add-RedactionLiteral {
    # Remembers a name seen during collection that must be replaced in a
    # redacted report wherever it appears (#100): accounts without a domain
    # prefix, GPO names, WMI filter names. Kept for every run (cheap).
    param([string]$Value, [ValidateSet('ACCOUNT','GPO','NAME','HOST')][string]$Kind)
    if (-not $Value) { return }
    $v = $Value.Trim()
    if ($Kind -eq 'ACCOUNT' -and $v -match '^(.+)\\(.+)$') {
        if ($Matches[1] -match '^(NT AUTHORITY|NT SERVICE|BUILTIN|IIS APPPOOL|NT VIRTUAL MACHINE|Window Manager|Font Driver Host)$') { return }
        $v = $Matches[2]
    }
    $v = $v.TrimStart('.').TrimStart('\\')
    if ($v.Length -lt 3 -or $v -match $script:RedactionWellKnownNames -or $v -match '^S-1-') { return }
    if (-not $script:Data.ContainsKey('RedactLiterals') -or $null -eq $script:Data.RedactLiterals) { $script:Data.RedactLiterals = @{} }
    $script:Data.RedactLiterals[$v] = $Kind
}

function Get-RedactionPlaceholder {
    param([hashtable]$Context, [string]$Kind, [string]$Value)
    $key = $Kind + '|' + $Value.ToLowerInvariant()
    if (-not $Context.Map.ContainsKey($key)) {
        $n = 1 + [int]$Context.Counters[$Kind]
        $Context.Counters[$Kind] = $n
        $Context.Map[$key] = $Kind + '-' + $n
        # The original, in its first-seen spelling, for the redaction key (#211).
        if ($Context.ContainsKey('Originals') -and $null -ne $Context.Originals) { $Context.Originals[$Kind + '-' + $n] = [pscustomobject]@{ Placeholder = ($Kind + '-' + $n); Kind = $Kind; Original = $Value } }
    }
    return $Context.Map[$key]
}

function ConvertTo-RedactionKeyLine {
    # Pure (#211): the lines of the redaction key, a ';' CSV with
    # Placeholder;Kind;Original, sorted by kind and number. A value that a
    # spreadsheet would run as a formula gets a leading apostrophe; values
    # with ';', quotes or line breaks are quoted.
    param([System.Collections.IDictionary]$Originals)
    $cell = {
        param([string]$v)
        if ($v -match '^[=+\-@\t\r]') { $v = "'" + $v }
        if ($v -match '[;"\r\n]') { $v = '"' + ($v -replace '"', '""') + '"' }
        return $v
    }
    $lines = @('Placeholder;Kind;Original')
    $rows = @($Originals.Values | Sort-Object @{ Expression = { [string]$_.Kind } }, @{ Expression = { [int](([string]$_.Placeholder) -replace '^.*-', '') } })
    foreach ($r in $rows) { $lines += ((& $cell ([string]$r.Placeholder)) + ';' + (& $cell ([string]$r.Kind)) + ';' + (& $cell ([string]$r.Original))) }
    return $lines
}

function Get-RedactionDomainKey {
    # One domain, one placeholder (#156): "CORP", "corp.example.test" and
    # "CORP.LOCALDOM" all map to the run's domain when their first label is
    # the domain's first label. Pure.
    param([hashtable]$Context, [string]$Name)
    if ($Context.DomainFqdn) {
        $first = ($Context.DomainFqdn -split '\.')[0]
        if ($Name -ieq $Context.DomainFqdn -or ($Name -split '\.')[0] -ieq $first) { return $Context.DomainFqdn }
    }
    return $Name
}

function Protect-ReportText {
    # Best-effort redaction of one text. Well-known names (BUILTIN, NT
    # AUTHORITY, S-1-5-32-*, 127.0.0.1, 0.0.0.0), versions and file paths are
    # kept. Pure apart from the shared placeholder map in $Context.
    param([string]$Text, [hashtable]$Context)
    if (-not $Text) { return $Text }
    $ctx = $Context
    $t = $Text
    $ic = [Text.RegularExpressions.RegexOptions]::IgnoreCase

    # Names collected during the run (#100), longest first so a GPO name is
    # replaced as a whole before word-level rules see its parts.
    if ($ctx.Literals) {
        foreach ($lit in @($ctx.Literals.Keys | Sort-Object { $_.Length } -Descending)) {
            $kind = $ctx.Literals[$lit]
            $t = [regex]::Replace($t, '(?<![\w.-])' + [regex]::Escape($lit) + '(?![\w-])', { param($m) Get-RedactionPlaceholder $ctx $kind $m.Value }, $ic)
        }
    }

    # Local group members: "name [WinNT://DOMAIN/name]"
    $t = [regex]::Replace($t, '([^\s|>\[\]][^|<>\[\]]*?) \[WinNT://([^/\]]+)/([^\]]+)\]', {
        param($m)
        $acct = Get-RedactionPlaceholder $ctx 'ACCOUNT' ($m.Groups[2].Value + '\' + $m.Groups[3].Value)
        $domKind = 'DOMAIN'; if ($m.Groups[2].Value -ieq $ctx.ComputerName) { $domKind = 'HOST' }
        $dom = Get-RedactionPlaceholder $ctx $domKind $m.Groups[2].Value
        return $acct + ' [WinNT://' + $dom + '/' + $acct + ']'
    })
    # Certificate thumbprints (40 hex characters)
    $t = [regex]::Replace($t, '(?<![0-9A-Fa-f])[0-9A-Fa-f]{40}(?![0-9A-Fa-f])', { param($m) Get-RedactionPlaceholder $ctx 'CERT' $m.Value })
    # Certificate subject and issuer names
    # Also locality, state, street, postal code, e-mail and serial number:
    # a city can identify a customer (#212). C= (country code) is kept.
    $t = [regex]::Replace($t, '\b(CN|OU|O|L|S|ST|STREET|PostalCode|E|EMAIL|SERIALNUMBER)=([^,|<>\]\r\n]*[^,|<>\]\r\n\s])', { param($m) $m.Groups[1].Value + '=' + (Get-RedactionPlaceholder $ctx 'NAME' $m.Groups[2].Value) })
    # Domain components of a distinguished name (#100, #99)
    # The DC= components together are the domain: one placeholder, the same
    # one the domain name gets elsewhere.
    $t = [regex]::Replace($t, '\bDC=[^,|<>\]\r\n\s]+(?:,DC=[^,|<>\]\r\n\s]+)*', {
        param($m)
        $fqdn = (@($m.Value -split ',' | ForEach-Object { $_.Substring(3) }) -join '.')
        return 'DC=' + (Get-RedactionPlaceholder $ctx 'DOMAIN' $fqdn)
    }, $ic)
    # MAC addresses
    $t = [regex]::Replace($t, '\b([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b', { param($m) Get-RedactionPlaceholder $ctx 'MAC' $m.Value })
    # Resolved user-rights entries "DOMAIN\Name [S-1-5-21-...]" (#156). The
    # name can contain spaces and the domain can be a full DNS name, so the
    # word rules below miss them. Well-known domain RIDs (Domain Admins,
    # Group Policy Creator Owners, ...) keep their name; the domain part is
    # always replaced.
    $t = [regex]::Replace($t, '(?<![^\s|>(,;])([^\s|<>\[\]\\(,;][^|<>\[\]\r\n\\]*?)\\([^|<>\[\]\r\n\\]+?) \[(S-1-5-21-\d+-\d+-\d+-(\d+))\]', {
        param($m)
        $d = $m.Groups[1].Value
        if ($d -match '^(NT AUTHORITY|BUILTIN|NT SERVICE)$') { return $m.Value }
        $domKind = 'DOMAIN'; if ($d -ieq $ctx.ComputerName) { $domKind = 'HOST' }
        $rid = [int64]$m.Groups[4].Value
        if ($script:RedactionWellKnownRids -contains $rid) { return (Get-RedactionPlaceholder $ctx $domKind (Get-RedactionDomainKey $ctx $d)) + '\' + $m.Groups[2].Value + ' [' + $m.Groups[3].Value + ']' }
        return (Get-RedactionPlaceholder $ctx 'ACCOUNT' ($d + '\' + $m.Groups[2].Value)) + ' [' + $m.Groups[3].Value + ']'
    })
    # Domain SIDs (well-known S-1-5-32-*, S-1-5-18 etc. are kept)
    $t = [regex]::Replace($t, '\bS-1-5-21(-\d+){3,4}\b', { param($m) Get-RedactionPlaceholder $ctx 'SID' $m.Value })
    # DOMAIN\user. Not after \ : or / (path segments). The domain part must be
    # a known NetBIOS name or an all-caps name that is not a well-known root.
    $skip = '^(BUILTIN|AUTHORITY|SERVICE|APPPOOL|HKLM|HKCU|HKU|HKCR|HKCC|SYSTEM|SOFTWARE)$'
    $t = [regex]::Replace($t, '(?<![\\:/\w.-])([A-Za-z0-9][A-Za-z0-9-]{1,14})\\([A-Za-z0-9._$-]{1,64})', {
        param($m)
        $d = $m.Groups[1].Value
        # Already handled by the user-rights rule (#156): a well-known name.
        if ($d -match '^(DOMAIN|HOST)-\d+$') { return $m.Value }
        if ($m.Groups[2].Value -match '^(ACCOUNT|HOST|DOMAIN|NAME|GPO)-\d+$') { return (Get-RedactionPlaceholder $ctx 'DOMAIN' $d) + '\' + $m.Groups[2].Value }
        $known = @($ctx.NetBios | Where-Object { $_ -and $_ -ieq $d }).Count -gt 0
        $caps = ($d -cmatch '^[A-Z0-9-]+$') -and ($d -notmatch $skip) -and ($d -match '[A-Z]')
        if ($known -or $caps) { return Get-RedactionPlaceholder $ctx 'ACCOUNT' $m.Value }
        return $m.Value
    })
    # UPN-style accounts and e-mail addresses
    $t = [regex]::Replace($t, '\b[\w.+-]+@[\w-]+(\.[\w-]+)+\b', { param($m) Get-RedactionPlaceholder $ctx 'ACCOUNT' $m.Value })
    # FQDNs in the server's domain, the domain itself, then the computer name
    if ($ctx.DomainFqdn) {
        $dom = [regex]::Escape($ctx.DomainFqdn)
        $t = [regex]::Replace($t, '\b[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.' + $dom + '\b', { param($m) Get-RedactionPlaceholder $ctx 'HOST' $m.Value }, $ic)
        # With any DNS suffix that follows (#156), so "CORP.LOCALDOM" is
        # replaced as a whole when only "corp" is known.
        $t = [regex]::Replace($t, '\b' + $dom + '(?:\.[A-Za-z0-9-]+)*\b', { param($m) Get-RedactionPlaceholder $ctx 'DOMAIN' (Get-RedactionDomainKey $ctx $m.Value) }, $ic)
    }
    # Any other host name with a public or internal top-level domain (#100),
    # except documentation and vendor domains used in report links.
    $tld = 'com|net|org|edu|gov|mil|int|info|biz|local|lan|corp|internal|intra|intranet|ad|home|cloud|online|dk|se|no|fi|is|de|nl|be|lu|fr|uk|ie|es|pt|it|ch|at|pl|cz|sk|hu|ee|lv|lt|eu|us|ca|au|nz|jp|cn|sg|hk|in'
    $t = [regex]::Replace($t, '(?<![\w.@-])(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+(?:' + $tld + ')(?![\w-]|\.[A-Za-z0-9])', {
        param($m)
        $v = $m.Value
        foreach ($keep in $script:RedactionKeepDomains) { if ($v -ieq $keep -or $v.EndsWith('.' + $keep, [StringComparison]::OrdinalIgnoreCase)) { return $v } }
        return Get-RedactionPlaceholder $ctx 'HOST' $v
    }, $ic)
    foreach ($n in @($ctx.NetBios)) {
        if (-not $n) { continue }
        $kind = 'DOMAIN'; if ($n -ieq $ctx.ComputerName) { $kind = 'HOST' }
        # A domain name takes its DNS suffix with it ("CORP.LOCALDOM" as a
        # whole), so no part of the real name is left behind (#156).
        $tail = ''; if ($kind -eq 'DOMAIN') { $tail = '(?:\.[A-Za-z0-9-]+)*' }
        $t = [regex]::Replace($t, '(?<![\w-])' + [regex]::Escape($n) + $tail + '(?![\w])', {
            param($m)
            if ($kind -eq 'HOST') { return Get-RedactionPlaceholder $ctx 'HOST' $m.Value }
            return Get-RedactionPlaceholder $ctx 'DOMAIN' (Get-RedactionDomainKey $ctx $m.Value)
        }, $ic)
    }
    # Group Policy link paths: every OU after the (already replaced) domain (#100)
    $t = [regex]::Replace($t, '(?<!WinNT://)\b(DOMAIN-\d+|HOST-\d+)((?:/[^/|;<>"\[\]\r\n]*[^/|;<>"\[\]\r\n\s])+)', {
        param($m)
        $parts = @($m.Groups[2].Value.Split('/') | Where-Object { $_ } | ForEach-Object {
            $c = $_.Trim()
            if ($c -match '^(ACCOUNT|HOST|DOMAIN|NAME|GPO)-\d+$') { $c } else { Get-RedactionPlaceholder $ctx 'NAME' $c }
        })
        return $m.Groups[1].Value + '/' + ($parts -join '/')
    })
    # IPv4 (not version numbers, masks, loopback or the any-address). A
    # number after "version" (any case) or alone as a folder in a path
    # (\4.0.2.39\, but not the UNC host \\10.1.2.3\) is a version (#194).
    $text = $t
    # Followed by "+" it is a version with a build suffix, 11.0.16.1+1 (#213).
    $t = [regex]::Replace($t, '(?<![\w.])(?<![Vv]ersion[=: ])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\w.+])', {
        param($m)
        $before = $(if ($m.Index -ge 1) { $text[$m.Index - 1] } else { [char]0 })
        $before2 = $(if ($m.Index -ge 2) { $text[$m.Index - 2] } else { [char]0 })
        $after = $(if ($m.Index + $m.Length -lt $text.Length) { $text[$m.Index + $m.Length] } else { [char]0 })
        if ($before -eq [char]'\' -and $before2 -ne [char]'\' -and $after -eq [char]'\') { return $m.Value }
        $o = @(1..4 | ForEach-Object { [int]$m.Groups[$_].Value })
        if (@($o | Where-Object { $_ -gt 255 }).Count -gt 0) { return $m.Value }
        if ($o[0] -eq 255 -or $m.Value -eq '0.0.0.0' -or $o[0] -eq 127) { return $m.Value }
        return Get-RedactionPlaceholder $ctx 'IP' $m.Value
    })
    # IPv6: contains '::' or at least five colons, and at least one hex letter or '::'
    $t = [regex]::Replace($t, '(?<![\w:.])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![\w:])', {
        param($m)
        $v = $m.Value
        $colons = ($v.ToCharArray() | Where-Object { $_ -eq ':' }).Count
        if ($v -eq '::' -or $v -eq '::1') { return $v }
        if (($v.Contains('::') -and $v.Length -gt 3) -or ($colons -ge 5 -and $v -match '[A-Fa-f]')) { return Get-RedactionPlaceholder $ctx 'IP' $v }
        return $v
    })
    return $t
}

function Protect-ReportObject {
    # Returns a redacted copy of strings, arrays, hashtables and objects.
    param($Value, [hashtable]$Context)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return (Protect-ReportText $Value $Context) }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($k in @($Value.Keys)) {
            if ([string]$k -match '^(Version|FileVersion|DriverVersion|DisplayVersion|ProductVersion)$' -and [string]$Value[$k] -match '^\d+(\.\d+){1,3}$') { $copy[$k] = $Value[$k]; continue }
            $copy[$k] = Protect-ReportObject $Value[$k] $Context
        }
        return $copy
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @(foreach ($i in $Value) { , (Protect-ReportObject $i $Context) })
        return ,$items
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $copy = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) {
            # A version field that holds only a version number is not an
            # address (#194).
            if ($p.Name -match '^(Version|FileVersion|DriverVersion|DisplayVersion|ProductVersion)$' -and [string]$p.Value -match '^\d+(\.\d+){1,3}$') { $copy[$p.Name] = $p.Value; continue }
            $copy[$p.Name] = Protect-ReportObject $p.Value $Context
        }
        return [pscustomobject]$copy
    }
    return $Value
}

# SPECIAL servers (#152): kinds that are never a standard in-place upgrade.
# Each kind has its risks and options here, so a new kind is new data.
$script:WindowsServerReleaseOrder = @('2012R2','2016','2019','2022','2025')

function Get-SpecialServerDecision {
    # Pure (#152): which SPECIAL kind a server is, from what the baseline
    # collected. 'Undecided' when the cluster signals disagree: the report
    # then says MANUAL, never a silent standard report.
    param([int]$DomainRole, [bool]$ClusterFeature, [bool]$ClusterServiceActive, [bool]$ClusterKey, [bool]$BlockDomainController = $true)
    if ($DomainRole -ge 4 -and $BlockDomainController) { return 'DomainController' }
    if ($ClusterFeature -and $ClusterServiceActive -and $ClusterKey) { return 'Cluster' }
    if ($ClusterFeature -and ($ClusterServiceActive -xor $ClusterKey)) { return 'Undecided' }
    return ''
}

function Get-SpecialServerCheckId {
    # Pure (#152): the checks a SPECIAL short report keeps - what is needed
    # to describe the server and choose a plan.
    return ,@('baseline','upgradepath','licensing','platform','performance','domain','cluster','special','storage')
}

function Get-SpecialServerContent {
    # Pure (#152): what the report tells the project and the customer about a
    # SPECIAL server - plain words, risks first, options to evaluate (not
    # instructions), each option with a Microsoft link.
    param([Parameter(Mandatory=$true)][string]$Kind, [string]$Source = '', [string]$Target = '')
    $t = Get-ReleaseDisplayName $Target
    $banner = 'Not a standard in-place upgrade. This server needs its own plan, extra time and coordination, and carries more risk: expensive and risky. Tell the project and the customer before planning the change.'
    switch ($Kind) {
        'Cluster' {
            $steps = -1
            $si = $script:WindowsServerReleaseOrder.IndexOf($Source); $ti = $script:WindowsServerReleaseOrder.IndexOf($Target)
            if ($si -ge 0 -and $ti -ge 0) { $steps = $ti - $si }
            $rolling = 'Cluster OS Rolling Upgrade: upgrade the nodes one at a time while the cluster keeps running. It moves one Windows Server version at a time.'
            if ($steps -gt 1) { $rolling += ' From ' + (Get-ReleaseDisplayName $Source) + ' to ' + $t + ' that means ' + $steps + ' rolling upgrades in a row, or a migration instead.' }
            return [pscustomobject]@{
                Kind = 'Cluster'; Title = 'Failover cluster node'; Banner = $banner
                Risks = @(
                    'Quorum: a node down for the upgrade plus one more failure can stop the whole cluster.',
                    'Mixed-version period: until every node is upgraded and the cluster functional level is raised, the cluster runs in a compatibility mode; plan to finish quickly.',
                    'Raising the cluster functional level cannot be undone.',
                    'Workload and vendor support: SQL Server failover cluster instances, Hyper-V, file server and Storage Spaces Direct each have their own rules and order of steps.',
                    'The way back is much harder than a VM snapshot: a snapshot of one node does not roll back the cluster.'
                )
                Options = @(
                    [pscustomobject]@{ Text = $rolling; Url = 'https://learn.microsoft.com/en-us/windows-server/failover-clustering/cluster-operating-system-rolling-upgrade'; Title = 'Microsoft: Cluster OS Rolling Upgrade' },
                    [pscustomobject]@{ Text = 'Build a new cluster on ' + $t + ' and migrate the roles to it (often simpler across several versions).'; Url = 'https://learn.microsoft.com/en-us/windows-server/failover-clustering/cluster-operating-system-rolling-upgrade'; Title = 'Microsoft: Cluster OS Rolling Upgrade (migration alternative)' },
                    [pscustomobject]@{ Text = 'Leave it on the current release for now (Extended Security Updates where available) and plan a replacement.'; Url = ''; Title = '' }
                )
            }
        }
        'DomainController' {
            return [pscustomobject]@{
                Kind = 'DomainController'; Title = 'Domain controller'; Banner = $banner
                Risks = @(
                    'Active Directory database and replication: a failed upgrade affects the whole domain, not just this server.',
                    'Roles on the same server (FSMO roles, global catalog, DNS, DHCP, certificate services) move or fail with it.',
                    'The way back: restoring a domain controller from a snapshot or image can cause a USN rollback that silently breaks replication. Virtualization safeguards reduce, but do not remove, this risk.',
                    'Clients and older servers may depend on protocols the new release no longer allows by default (SMB1, NTLMv1, older TLS).'
                )
                Options = @(
                    [pscustomobject]@{ Text = 'Microsoft''s recommended way: add a new domain controller on ' + $t + ' beside this one, move the roles, then demote and retire this one.'; Url = 'https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/deploy/upgrade-domain-controllers'; Title = 'Microsoft: Upgrade domain controllers to a newer version of Windows Server' },
                    [pscustomobject]@{ Text = 'In-place upgrade only as a planned, approved exception, with replication health, backups and a tested way back.'; Url = 'https://learn.microsoft.com/en-us/troubleshoot/windows-server/active-directory/detect-and-recover-from-usn-rollback'; Title = 'Microsoft: USN rollback (why snapshots are not a way back)' }
                )
            }
        }
    }
    throw ('Unknown SPECIAL kind: ' + $Kind)
}

function Get-OverallStatus {
    param([object[]]$Results)
    $findings = @($Results | Where-Object { $_.Kind -eq 'Finding' })
    foreach ($status in $script:FindingStatuses) {
        if (@($findings | Where-Object { $_.Status -eq $status }).Count -gt 0) { return $status }
    }
    return 'OK'
}

function Get-StatusRank {
    param([string]$Status)
    $i = $script:StatusOrder.IndexOf($Status)
    if ($i -lt 0) { return 99 }
    return $i
}


