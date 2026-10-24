# =============================================================================
# 5. CHECKS
# =============================================================================
function Register-AssessmentCheck {

# ---------------------------------------------------------------------------
Register-Check -Id 'baseline' -Name 'Baseline inventory' -Script {
    $script:Data.OS       = @(Get-CimRequired 'Win32_OperatingSystem') | Select-Object -First 1
    $script:Data.CS       = @(Get-CimRequired 'Win32_ComputerSystem') | Select-Object -First 1
    $script:Data.BIOS     = @(Get-CimSafe 'Win32_BIOS') | Select-Object -First 1
    $script:Data.CPU      = @(Get-CimSafe 'Win32_Processor')
    $script:Data.Services = @(Get-CimRequired 'Win32_Service')
    $script:Data.Apps     = @(Get-InstalledApplication)
    $script:Data.CV       = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $script:Data.Features = $null
    $featureInventoryError = ''
    if (Test-CommandAvailable 'Get-WindowsFeature') {
        # Fill a local table and keep it only when the whole list was read:
        # an empty or partial table would read as "not installed" (#238).
        try {
            $featureTable = @{}
            foreach ($f in @(Get-WindowsFeature -ErrorAction Stop)) { $featureTable[$f.Name] = [bool]$f.Installed }
            $script:Data.Features = $featureTable
        } catch { $featureInventoryError = $_.Exception.Message }
    }
    # Drivers: file-system filter drivers (fltmc) and running kernel drivers.
    # Used to recognise AV/EDR/security products independently of their names.
    $flt = Invoke-NativeCapture (Join-Path $env:windir 'System32\fltMC.exe') @('filters') 60
    $script:Data.FilterDrivers = @($flt.Lines | Where-Object { $_ -match '^\s*([A-Za-z0-9_.-]+)\s+\d+\s+' } | ForEach-Object { ($_ -split '\s+' | Where-Object { $_ })[0] })
    $script:Data.KernelDrivers = @(Get-CimSafe 'Win32_SystemDriver' "State='Running'")
    $script:Data.DriverNames = @(@($script:Data.FilterDrivers) + @($script:Data.KernelDrivers | ForEach-Object { [string]$_.Name }) | Sort-Object -Unique)

    $platform = Get-PlatformClassification $script:Data.CS.Manufacturer $script:Data.CS.Model
    $script:Data.Platform = $platform
    $script:Data.IsClustered = $false

    # Snapshot used for the post-upgrade comparison (stored in the JSON).
    $script:Data.Snapshot = @{
        Services = @($script:Data.Services | ForEach-Object { [pscustomobject]@{ Name=[string]$_.Name; State=[string]$_.State; StartMode=[string]$_.StartMode } })
        Apps     = @($script:Data.Apps | ForEach-Object { [pscustomobject]@{ Name=$_.Name; Version=$_.Version } })
        Features = @()
        Ports = @(); Routes = @(); IPv4 = @(); Dns = @(); Adapters = @(); Hosts = @(); Tasks = @()
        Printers = @(); PrinterPorts = @(); PrinterDrivers = @()
    }
    if ($script:Data.Features) { $script:Data.Snapshot.Features = @($script:Data.Features.Keys | Where-Object { $script:Data.Features[$_] } | Sort-Object) }

    if ($featureInventoryError) {
        Add-Result 'ASSESSMENT' 'FeatureInventory' 'MANUAL' 'Get-WindowsFeature failed' $featureInventoryError -Recommendation 'List the installed roles and features by hand (Server Manager, or Get-WindowsFeature in an elevated session). Until then the cluster, IIS and RDS rows are MANUAL, not "not installed".' -Source 'ServerManager'
    }
    if (-not $script:NumberCultureResolved.Known) {
        Add-Result 'ASSESSMENT' 'NumberCulture' 'INFO' ('Number format ''' + $NumberCultureName + ''' is not a culture on this server') 'Numbers use the invariant format (1,234.5).' -Recommendation 'Give -NumberCultureName a culture name that exists, for example da-DK or en-US.' -Source 'NumberCultureName'
    }
    Add-Result 'ASSESSMENT' 'CollectorVersion' 'INFO' $script:CollectorVersion 'Restructured 4.x edition' -Source 'Script constant'
    Add-Result 'ASSESSMENT' 'Target' 'INFO' (Get-ReleaseDisplayName $TargetServerVersion) ('MediaLanguage=' + $(if ($TargetMediaLanguage) { $TargetMediaLanguage } else { 'not set' })) -Source 'SETTINGS'
    Add-Result 'ASSESSMENT' 'ExecutionContext' 'INFO' ('Identity=' + [Security.Principal.WindowsIdentity]::GetCurrent().Name) @(('PowerShell=' + $PSVersionTable.PSVersion),('LanguageMode=' + $ExecutionContext.SessionState.LanguageMode)) -Source 'Runtime'
    if ($script:Is32BitHost) {
        Add-Result 'COLLECTOR' '32-bit PowerShell host' 'ACTION' 'Running in 32-bit PowerShell on 64-bit Windows and could not relaunch as 64-bit' -Recommendation 'Registry and System32 reads are redirected, so application, SQL and tool results are unreliable. Run the script as a file under 64-bit PowerShell and re-assess.' -Source 'Environment.Is64BitProcess'
    }
    Add-Result 'ASSESSMENT' 'ReportDestination' 'INFO' $ReportDirectory @(('Evidence copies (unredacted): ' + $EvidenceRoot), ('Policy evidence: ' + $(if ($EnableRDPPolicyEvidence) { Get-EvidenceFolderPath $EvidenceRoot 'Policy' $PolicyEvidenceRoot } else { 'disabled' }))) -Source 'SETTINGS'
    $folderState = $script:OutputFolderState
    if (-not $folderState) { $folderState = 'Existing' }
    $readers = @()
    if ($folderState -eq 'Existing') { $readers = @(Get-BroadFolderReader $ReportDirectory) }
    $access = Get-OutputFolderAccessDecision $folderState $readers $ReportDirectory
    if ($access.PSObject.Properties['Command'] -and $access.Command) {
        Add-Result 'ASSESSMENT' 'OutputFolderAccess' $access.Status $ReportDirectory $access.Text -Kind $access.Kind -Source 'Get-Acl' -Command $access.Command -CommandKind 'Change'
    } else {
        Add-Result 'ASSESSMENT' 'OutputFolderAccess' $access.Status $ReportDirectory $access.Text -Kind $access.Kind -Source 'Get-Acl'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'upgradepath' -Name 'Upgrade path, edition and media' -Script {
    $os = $script:Data.OS; $cv = $script:Data.CV
    $buildText = [string]$os.BuildNumber
    if ($cv.UBR) { $buildText += '.' + $cv.UBR }
    $source = Get-WindowsServerRelease $os.BuildNumber $os.Caption
    $script:Data.SourceRelease = $source
    Add-Result 'UPGRADE_PATH' 'CurrentOS' 'INFO' $os.Caption @(('Build=' + $buildText),('Release=' + (Get-ReleaseDisplayName $source)),('Architecture=' + $os.OSArchitecture)) -Source 'Win32_OperatingSystem'
    $life = Get-SupportLifecycleDecision $source (Get-Date)
    $script:Data.SourceSupport = $life
    $lifeKind = ''; if ($life.Status -eq 'WARNING') { $lifeKind = 'Observation' }
    Add-Result 'UPGRADE_PATH' 'SourceEndOfSupport' $life.Status $life.Value ('EndOfExtendedSupport=' + $life.EndDate) -Recommendation $life.Text -Kind $lifeKind -Source 'Microsoft Lifecycle (fixed dates in the script)' -Link $script:DocLinks.Lifecycle.Url -LinkTitle $script:DocLinks.Lifecycle.Title

    # The cluster check runs later; read membership here directly so the path
    # decision already knows about it.
    $clustered = $false
    if ((Get-FeatureState 'Failover-Clustering') -eq $true) {
        $clusSvc = @($script:Data.Services | Where-Object { $_.Name -eq 'ClusSvc' -and $_.StartMode -ne 'Disabled' })
        $clusterKey = Test-Path 'HKLM:\Cluster'
        if ($clusSvc.Count -gt 0 -and $clusterKey) { $clustered = $true }
    }
    $script:Data.IsClustered = $clustered
    $path = Get-UpgradePathDecision $source $TargetServerVersion $clustered
    if ($AssessmentMode -eq 'Post' -and $source -and $source -eq $TargetServerVersion -and -not $clustered) {
        $path = [pscustomobject]@{ Status = 'INFO'; Text = ('Now ' + (Get-ReleaseDisplayName $source) + ' (post-upgrade run).') }
    }
    Add-Result 'UPGRADE_PATH' 'TargetUpgradePath' $path.Status $path.Text ('Target=' + (Get-ReleaseDisplayName $TargetServerVersion)) -Source 'Microsoft supported upgrade paths (installation media)' -Link $script:DocLinks.InPlaceUpgrade.Url -LinkTitle $script:DocLinks.InPlaceUpgrade.Title

    $edition = Get-EditionDecision $cv.EditionID $cv.InstallationType $TargetServerVersion
    $script:Data.Edition = $edition
    $mediaText = $edition.MediaImage
    if (-not $mediaText) { $mediaText = 'Not determined' }
    Add-Result 'UPGRADE_PATH' 'EditionAndInstallationType' $edition.Status ('Edition=' + $edition.Edition + ', ' + $edition.Variant) @(('EditionID=' + $cv.EditionID),('InstallationType=' + $cv.InstallationType)) -Recommendation $edition.Text -Source 'HKLM CurrentVersion'

    # Install language (what Setup compares), not the system locale.
    $installLang = ConvertFrom-LanguageId (Get-RegistryValueSafe 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language' 'InstallLanguage').Value 16
    if (-not $installLang) { $installLang = ConvertFrom-LanguageId ([string]$os.OSLanguage) 10 }
    $uiLang = ConvertFrom-LanguageId (Get-RegistryValueSafe 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language' 'Default').Value 16
    $systemLocale = ''
    try { if (Test-CommandAvailable 'Get-WinSystemLocale') { $systemLocale = (Get-WinSystemLocale).Name } } catch { Write-Swallowed $_ }
    $script:Data.InstallLanguage = $installLang
    $langDetails = @(('DefaultUILanguage=' + $uiLang),('SystemLocale=' + $systemLocale + ' (not relevant for media)'))
    if (-not $installLang) {
        Add-Result 'UPGRADE_PATH' 'InstallLanguage' 'MANUAL' 'Install language could not be determined' $langDetails -Recommendation 'Confirm the installed OS language; IPU cannot change language.' -Source 'Nls\Language InstallLanguage'
    } elseif ($TargetMediaLanguage -and $TargetMediaLanguage -ne $installLang) {
        Add-Result 'UPGRADE_PATH' 'InstallLanguage' 'BLOCKER' ('Installed=' + $installLang + ', TargetMedia=' + $TargetMediaLanguage) $langDetails -Recommendation ('Changing language during IPU is not supported. Use ' + $installLang + ' installation media.') -Source 'Nls\Language InstallLanguage'
    } else {
        Add-Result 'UPGRADE_PATH' 'InstallLanguage' 'OK' ('Installed=' + $installLang) $langDetails -Recommendation ('Installation media must be ' + $installLang + '.') -Source 'Nls\Language InstallLanguage'
    }
    $mediaLine = $mediaText
    if ($installLang) { $mediaLine += ' - ' + $installLang + ' media' }
    $script:Data.RecommendedMedia = $mediaLine
    Add-Result 'UPGRADE_PATH' 'RecommendedInstallationImage' 'INFO' $mediaLine 'Select exactly this image in Setup.' -Source 'Derived from edition, installation type and install language'

    # Boot from VHD
    if (Test-CommandAvailable 'Get-Partition') {
        try {
            $cp = Get-Partition -DriveLetter C -ErrorAction Stop
            $disk = Get-Disk -Number $cp.DiskNumber -ErrorAction Stop
            if ([string]$disk.BusType -match 'File Backed Virtual') {
                Add-Result 'UPGRADE_PATH' 'BootFromVHD' 'BLOCKER' ('BusType=' + $disk.BusType) -Recommendation 'In-place upgrade of Windows Server booted from VHD is not supported.' -Source 'Get-Disk'
            }
        } catch { Write-Swallowed $_ }
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'licensing' -Name 'Windows activation' -Script {
    $statusNames = @{ 0='Unlicensed'; 1='Licensed'; 2='OOBGrace'; 3='OOTGrace'; 4='NonGenuineGrace'; 5='Notification'; 6='ExtendedGrace' }
    $products = @()
    $queryError = ''
    try {
        $products = @(Get-CimInstance -Query "SELECT Name,Description,LicenseStatus,PartialProductKey,ProductKeyChannel,GracePeriodRemaining,DiscoveredKeyManagementServiceMachineName,DiscoveredKeyManagementServiceMachinePort,KeyManagementServiceMachine,KeyManagementServicePort FROM SoftwareLicensingProduct WHERE ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -ErrorAction Stop |
            Where-Object { $_.Name -match '^Windows' })
    } catch {
        # Older builds do not expose ProductKeyChannel; retry with all columns.
        try {
            $products = @(Get-CimInstance -Query "SELECT * FROM SoftwareLicensingProduct WHERE ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" -ErrorAction Stop |
                Where-Object { $_.PartialProductKey -and $_.Name -match '^Windows' })
        } catch { $queryError = $_.Exception.Message }
    }
    $spp = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform' -ErrorAction SilentlyContinue
    $kms = 'Not set on this server (a KMS client finds its host via DNS)'
    if ($spp.KeyManagementServiceName) { $kms = [string]$spp.KeyManagementServiceName; if ($spp.KeyManagementServicePort) { $kms += ':' + $spp.KeyManagementServicePort } }
    $script:Data.KmsEndpoint = $kms

    if ($queryError) {
        Add-Result 'LICENSING' 'CurrentActivation' 'MANUAL' 'Activation state could not be queried' @($queryError,('KMS=' + $kms)) -Recommendation 'Validate activation manually (slmgr /dlv). A query failure does not prove Windows is unlicensed.' -Source 'SoftwareLicensingProduct'
        return
    }
    $primary = @($products | Sort-Object @{Expression={ if ([int]$_.LicenseStatus -eq 1) { 0 } else { 1 } }},Name) | Select-Object -First 1
    if (-not $primary) {
        Add-Result 'LICENSING' 'CurrentActivation' 'ACTION' 'No installed Windows license with a product key was returned' ('KMS=' + $kms) -Recommendation 'Resolve Windows activation before IPU.' -Source 'SoftwareLicensingProduct'
        return
    }
    $state = $statusNames[[int]$primary.LicenseStatus]; if (-not $state) { $state = 'Unknown(' + $primary.LicenseStatus + ')' }
    $channel = [string]$primary.ProductKeyChannel
    if (-not $channel) {
        $d = [string]$primary.Description
        if ($d -match 'VOLUME_KMSCLIENT') { $channel = 'Volume:GVLK (KMS client)' } elseif ($d -match 'VOLUME_MAK') { $channel = 'Volume:MAK' } elseif ($d -match 'OEM') { $channel = 'OEM' } elseif ($d -match 'RETAIL') { $channel = 'Retail' } else { $channel = 'Unknown' }
    }
    $script:Data.ActivationKind = Get-ActivationChannelKind $channel ([string]$primary.Description)
    # What actually activated the server (#171): the KMS host the client
    # found (via DNS) or the one set on the server, and the days until the
    # activation must be renewed.
    $discHost = [string](Get-OptionalProperty $primary 'DiscoveredKeyManagementServiceMachineName')
    $discPort = [string](Get-OptionalProperty $primary 'DiscoveredKeyManagementServiceMachinePort')
    $confHost = [string](Get-OptionalProperty $primary 'KeyManagementServiceMachine')
    $confPort = [string](Get-OptionalProperty $primary 'KeyManagementServicePort')
    if (-not $confHost -and $spp.KeyManagementServiceName) { $confHost = [string]$spp.KeyManagementServiceName; $confPort = [string]$spp.KeyManagementServicePort }
    $grace = $null; if ($null -ne $primary.GracePeriodRemaining) { $grace = [int64]$primary.GracePeriodRemaining }
    $act = Get-ActivationDecision $script:Data.ActivationKind ([int]$primary.LicenseStatus) $state $channel $grace $discHost $discPort $confHost $confPort
    if ($act.KmsHost) { foreach ($h in @($act.KmsHost, ($act.KmsHost -split '\.')[0]) | Select-Object -Unique) { Add-RedactionLiteral $h 'HOST' }; $script:Data.KmsEndpoint = $act.KmsEndpoint } elseif ($script:Data.ActivationKind -eq 'KMS') { $script:Data.KmsEndpoint = 'found via DNS' }
    $script:Data.ActivationSummary = $act.Value
    $details = @(('Channel=' + $channel), ('PartialProductKey=' + $primary.PartialProductKey)) + @($act.Details)
    Add-Result 'LICENSING' 'CurrentActivation' $act.Status $act.Value $details -Recommendation $act.Text -Source 'SoftwareLicensingProduct (only the last 5 key characters are read)'
    if ($channel -match 'OEM') {
        Add-Result 'LICENSING' 'OEMLicense' 'WARNING' $channel -Recommendation 'An OEM licence is tied to the original hardware and release. Confirm the target licence/key before IPU.' -Source 'SoftwareLicensingProduct'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'pendingreboot' -Name 'Pending reboot and uptime' -Script {
    $hard = @(); $soft = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $hard += 'CBS RebootPending' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending') { $hard += 'CBS PackagesPending' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $hard += 'Windows Update RebootRequired' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Updates\UpdateExeVolatile') {
        $v = Get-RegistryValueSafe 'HKLM:\SOFTWARE\Microsoft\Updates\UpdateExeVolatile' 'Flags'
        if ($v.Exists -and [int]$v.Value -ne 0) { $hard += 'UpdateExeVolatile' }
    }
    $active = (Get-RegistryValueSafe 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' 'ComputerName').Value
    $pending = (Get-RegistryValueSafe 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' 'ComputerName').Value
    if ($active -and $pending -and $active -ne $pending) { $hard += ('Pending computer rename ' + $active + ' -> ' + $pending) }
    if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\JoinDomain') { $hard += 'Pending domain join' }
    $renamePaths = @()
    foreach ($name in @('PendingFileRenameOperations','PendingFileRenameOperations2')) {
        $v = Get-RegistryValueSafe 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' $name
        if ($v.Exists -and @($v.Value | Where-Object { $_ }).Count -gt 0) { $soft += $name; $renamePaths += @($v.Value) }
    }
    $renameShown = ConvertTo-PendingRenamePath $renamePaths 5
    try {
        $ccm = Invoke-CimMethod -Namespace 'root\ccm\ClientSDK' -ClassName CCM_ClientUtilities -MethodName DetermineIfRebootPending -ErrorAction Stop
        if ($ccm -and ($ccm.RebootPending -or $ccm.IsHardRebootPending)) { $hard += 'ConfigMgr client reboot pending' }
    } catch { Write-Swallowed $_ }

    if ($hard.Count -gt 0) {
        Add-Result 'WINDOWS_HEALTH' 'PendingReboot' 'ACTION' ($hard -join ' | ') (@($soft) + @($renameShown)) -Recommendation 'Reboot, then re-run the assessment before starting the IPU.' -Source 'CBS, Windows Update, ComputerName, Netlogon, ConfigMgr' -Command (Get-RecommendationCommand 'Restart').Command -CommandKind 'Change'
    } elseif ($soft.Count -gt 0 -and $AssessmentMode -eq 'Post' -and (Test-PendingRenameHarmless $renamePaths)) {
        Add-Result 'WINDOWS_HEALTH' 'PendingReboot' 'INFO' ($soft -join ' | ') (@('Files waiting to be replaced: ') + @($renameShown)) -Recommendation 'Only installer leftovers (MSI rollback files, Edge updater): cleared at the next reboot. Expected after an upgrade with agent updates.' -Source 'Session Manager'
    } elseif ($soft.Count -gt 0) {
        Add-Result 'WINDOWS_HEALTH' 'PendingReboot' 'WARNING' ($soft -join ' | ') (@('Files waiting to be replaced: ') + @($renameShown)) -Recommendation 'The paths show which product left the pending rename (often AV or an agent update). Reboot in the pre-change window; if the same entries come back, ask that product''s owner.' -Source 'Session Manager' -Command (Get-RecommendationCommand 'PendingRename').Command -CommandKind 'Check'
    } else {
        Add-Result 'WINDOWS_HEALTH' 'PendingReboot' 'OK' 'No pending-reboot indicators detected' -Source 'CBS, Windows Update, Session Manager, ComputerName, Netlogon'
    }

    $boot = ConvertTo-DateTimeValue $script:Data.OS.LastBootUpTime
    if (-not $boot) { throw ('LastBootUpTime could not be read: ' + $script:Data.OS.LastBootUpTime) }
    $days = [math]::Floor(((Get-Date) - $boot).TotalDays)
    if ($days -ge $UptimeWarningDays) {
        Add-Result 'WINDOWS_HEALTH' 'Uptime' 'WARNING' ('UptimeDays=' + $days) ('LastBoot=' + $boot.ToString('yyyy-MM-dd HH:mm')) -Recommendation 'Do a controlled reboot before the change window and re-run the assessment. A long-unrebooted server can hide reboot-time problems that would otherwise surface mid-upgrade.' -Source 'Win32_OperatingSystem'
    } else {
        Add-Result 'WINDOWS_HEALTH' 'Uptime' 'OK' ('UptimeDays=' + $days) ('LastBoot=' + $boot.ToString('yyyy-MM-dd HH:mm')) -Source 'Win32_OperatingSystem'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'patchlevel' -Name 'Patch level' -Script {
    $fixes = @(Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn })
    $latest = $null
    foreach ($f in $fixes) { try { $d = [datetime]$f.InstalledOn; if (-not $latest -or $d -gt $latest.Date) { $latest = [pscustomobject]@{ Date=$d; Id=$f.HotFixID } } } catch { Write-Swallowed $_ } }
    if (-not $latest) {
        Add-Result 'WINDOWS_HEALTH' 'LatestUpdate' 'MANUAL' 'No dated update history returned' -Recommendation 'Confirm the server has the latest cumulative and servicing stack updates before IPU.' -Source 'Get-HotFix'
        return
    }
    $age = [math]::Floor(((Get-Date) - $latest.Date).TotalDays)
    $value = 'LatestInstalled=' + $latest.Date.ToString('yyyy-MM-dd') + ' (' + $latest.Id + ')'
    $patchDetails = @('AgeDays=' + $age)
    $patchAdvice = 'Install the latest cumulative update before IPU; Setup and Dynamic Update are most reliable on a current source OS.'
    if ($script:Data.SourceSupport -and $script:Data.SourceSupport.Ended) {
        $patchDetails += ('SourceOutOfSupportSince=' + $script:Data.SourceSupport.EndDate)
        $patchAdvice += ' The source OS is out of support since ' + $script:Data.SourceSupport.EndDate + ', so without ESU no newer updates exist; install the last available ones.'
    }
    if ($age -gt $MaxPatchAgeDays) {
        Add-Result 'WINDOWS_HEALTH' 'LatestUpdate' 'WARNING' $value $patchDetails -Recommendation $patchAdvice -Source 'Get-HotFix'
    } else {
        Add-Result 'WINDOWS_HEALTH' 'LatestUpdate' 'OK' $value ('AgeDays=' + $age) -Source 'Get-HotFix'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'history' -Name 'Previous upgrade history' -Script {
    $found = $false
    foreach ($key in @(Get-ChildItem 'HKLM:\SYSTEM\Setup' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'Source OS*' } | Sort-Object PSChildName)) {
        $p = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
        $found = $true
        $installed = ''
        if ($p.InstallDate) { try { $installed = (New-Object DateTime 1970,1,1,0,0,0,([DateTimeKind]::Utc)).AddSeconds([int64]$p.InstallDate).ToLocalTime().ToString('yyyy-MM-dd') } catch { Write-Swallowed $_ } }
        Add-Result 'UPGRADE_HISTORY' $key.PSChildName 'INFO' ('Product=' + $p.ProductName) @(('Build=' + $p.CurrentBuild),('InstallDate=' + $installed)) -Source $key.Name
    }
    # Only Source OS registry keys and C:\Windows.old show a completed
    # upgrade. C:\Windows\Panther\setupact.log exists on every server (the
    # original installation writes it), so it is shown as the OS install trace
    # only. C:\$WINDOWS.~BT is left by an aborted setup or a compatibility scan.
    $upgradeHints = @()
    if (Test-Path 'C:\Windows.old') { $upgradeHints += 'C:\Windows.old exists' }
    $osInstall = ''
    $installDate = ConvertTo-DateTimeValue $script:Data.OS.InstallDate
    if ($installDate) { $osInstall = $installDate.ToString('yyyy-MM-dd') }
    Add-Result 'UPGRADE_HISTORY' 'OSInstallDate' 'INFO' $osInstall 'Date of the current OS installation (or of the last in-place upgrade).' -Source 'Win32_OperatingSystem.InstallDate'
    if ($found -or $upgradeHints.Count -gt 0) {
        if ($AssessmentMode -eq 'Post') {
            Add-Result 'UPGRADE_HISTORY' 'PreviousUpgradeEvidence' 'INFO' ('PriorOSRecords=' + $found) $upgradeHints -Recommendation 'Expected in a post-upgrade run: this server has just been upgraded.' -Kind 'Observation' -Source 'HKLM\SYSTEM\Setup, C:\Windows.old'
        } else {
            Add-Result 'UPGRADE_HISTORY' 'PreviousUpgradeEvidence' 'WARNING' ('PriorOSRecords=' + $found) $upgradeHints -Recommendation 'This server has been upgraded in place before. Stacked upgrades carry older settings and drivers along; pay extra attention to the Setup compatibility result and test thoroughly afterwards.' -Kind 'Observation' -Source 'HKLM\SYSTEM\Setup, C:\Windows.old'
        }
    } else {
        Add-Result 'UPGRADE_HISTORY' 'PreviousUpgradeEvidence' 'INFO' 'No previous in-place upgrade recorded' 'Cleanup can remove this evidence; absence does not prove the server was never upgraded.' -Source 'HKLM\SYSTEM\Setup, C:\Windows.old'
    }
    $btLog = 'C:\$WINDOWS.~BT\Sources\Panther\setupact.log'
    if (Test-Path -LiteralPath 'C:\$WINDOWS.~BT') {
        $btDate = ''
        if (Test-Path -LiteralPath $btLog) { $btDate = 'setupact.log LastWrite=' + (Get-Item -LiteralPath $btLog).LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
        Add-Result 'UPGRADE_HISTORY' 'SetupWorkingFolder' 'INFO' 'C:\$WINDOWS.~BT exists' $btDate -Recommendation 'Left by an earlier Setup run: a compatibility scan or an aborted upgrade. If no scan was run, read the Panther logs to see why an upgrade stopped.' -Kind 'Observation' -Source 'C:\$WINDOWS.~BT'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'domain' -Name 'Domain role and access' -Script {
    $cs = $script:Data.CS
    $role = [int]$cs.DomainRole
    $roleNames = @{ 0='Workgroup computer (standalone)'; 1='Member workstation'; 2='Workgroup server (standalone)'; 3='Member server'; 4='Backup domain controller'; 5='Primary domain controller' }
    $script:Data.DomainRoleText = Get-DomainRoleText $role ([string]$cs.Domain)
    if ($role -ge 4) {
        $status = 'WARNING'; $rec = 'Domain controller: follow the AD DS upgrade guidance (adprep, FSMO, replication health) and engage the AD team.'
        # With -BlockDomainControllerIPU (the default) a domain controller is
        # SPECIAL (#152): the SPECIAL section carries the plan; this row is
        # evidence only.
        if ($BlockDomainControllerIPU) { $status = 'INFO'; $rec = 'Domain controller: not a standard in-place upgrade (site policy) - see the SPECIAL section.' }
        Add-Result 'DOMAIN_CONTROLLER' 'DomainController' $status $roleNames[$role] ('Domain=' + $cs.Domain) -Recommendation $rec -Source 'Win32_ComputerSystem.DomainRole'
    }

    if ($cs.PartOfDomain) {
        Add-Result 'ACCESS' 'DomainMembership' 'INFO' ('Domain=' + $cs.Domain) ('Role=' + $roleNames[$role]) -Source 'Win32_ComputerSystem'
        if ($role -lt 4) {
            $secure = $null
            if (Test-CommandAvailable 'Test-ComputerSecureChannel') { try { $secure = Test-ComputerSecureChannel -ErrorAction Stop } catch { Write-Swallowed $_ } }
            if ($secure -eq $true) { Add-Result 'ACCESS' 'DomainSecureChannel' 'OK' 'Secure channel verified' -Source 'Test-ComputerSecureChannel' }
            elseif ($secure -eq $false) { Add-Result 'ACCESS' 'DomainSecureChannel' 'ACTION' 'Secure channel test failed' -Recommendation 'Repair the domain trust before IPU; a broken trust can leave you without domain logon after the upgrade.' -Source 'Test-ComputerSecureChannel' }
            else { Add-Result 'ACCESS' 'DomainSecureChannel' 'MANUAL' 'Secure channel could not be tested' -Recommendation 'Verify domain logon manually before the change.' -Source 'Test-ComputerSecureChannel' }
        }
    } else {
        Add-Result 'ACCESS' 'DomainMembership' 'WARNING' ('Workgroup=' + $cs.Domain) ('Role=' + $script:Data.DomainRoleText) -Recommendation 'Workgroup server: confirm it is onboarded in CyberArk/PAM and that local fallback credentials work before IPU.' -Source 'Win32_ComputerSystem'
    }

    # User Account Control (#75). Information, not a finding: UAC does not
    # block an in-place upgrade.
    $uacKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $uacValues = @{}
    foreach ($n in @('EnableLUA','ConsentPromptBehaviorAdmin','PromptOnSecureDesktop','FilterAdministratorToken')) { $uacValues[$n] = (Get-RegistryValueSafe $uacKey $n).Value }
    $uac = Get-UacDecision $uacValues.EnableLUA $uacValues.ConsentPromptBehaviorAdmin $uacValues.PromptOnSecureDesktop $uacValues.FilterAdministratorToken
    $script:Data.UacSummary = $uac.Text
    if ($script:Data.Snapshot) { $script:Data.Snapshot.Uac = $uac.Text }
    Add-Result 'ACCESS' 'UAC' 'INFO' $uac.Text (@($uacValues.Keys | Sort-Object | ForEach-Object { $_ + '=' + $(if ($null -eq $uacValues[$_]) { '(default)' } else { [string]$uacValues[$_] }) }) -join ', ') -Source ($uacKey -replace '^HKLM:','HKLM')

    # On a domain controller "local" accounts are the domain's accounts, and
    # listing them can take minutes (#241): skip the lookup there. Elsewhere
    # ask for the one account by SID instead of listing all of them.
    $rid500 = $null
    if ($script:Data.CS -and [int]$script:Data.CS.DomainRole -ge 4) {
        Add-Result 'ACCESS' 'BuiltInAdministrator' 'INFO' 'Not looked up on a domain controller' 'Its accounts are the domain accounts; the domain Administrator account is the one to record.' -Source 'Win32_ComputerSystem'
    } else {
        $rid500 = @(Get-CimSafe 'Win32_UserAccount' "LocalAccount=True AND SID LIKE '%-500'") | Where-Object { $_.SID -match '-500$' } | Select-Object -First 1
    }
    if ($rid500) {
        Add-Result 'ACCESS' 'BuiltInAdministrator' 'INFO' ('Name=' + $rid500.Name) @(('Disabled=' + $rid500.Disabled),('SID=' + $rid500.SID)) -Recommendation 'Record the (possibly renamed) built-in Administrator and confirm PAM/console fallback.' -Source 'Win32_UserAccount'
    }
    $admins = Get-LocalGroupMembersBySid 'S-1-5-32-544'
    foreach ($member in $admins) { Add-Result 'ACCESS' 'LocalAdministratorsMember' 'INFO' $member -Source 'Local group S-1-5-32-544' }
    if ($admins.Count -eq 0) { Add-Result 'ACCESS' 'LocalAdministratorsMember' 'MANUAL' 'No members returned' -Recommendation 'Enumerate local Administrators manually.' -Kind 'Finding' -Source 'Local group S-1-5-32-544' }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'grouppolicy' -Name 'Group Policy and AD groups' -Script {
    # #80: which GPOs apply, which are filtered out and why, WMI filters on the
    # Windows version (they can stop or start matching after the upgrade),
    # the computer's AD groups, and when policy last applied.
    $domainMember = [bool]$script:Data.CS.PartOfDomain
    $gp = $null; $gpError = ''
    try { $gp = ConvertFrom-GpResultXml (Get-GpResultXml) } catch { $gpError = $_.Exception.Message; Write-Swallowed $_ }
    # gpresult run as SYSTEM can answer "does not have RSoP data" on 2012 R2
    # to 2019 (#160). The Group Policy service's own record of the applied
    # GPOs is the fallback; MANUAL stays only when both fail.
    $gpSource = 'gpresult'
    if (-not $gp -and $domainMember) {
        $fbEntries = 0; $fbNamed = 0; $fbError = ''; $fbMissing = $false
        try {
            $entries = Get-GpoListRegistryEntry
            $fbEntries = @($entries | Where-Object { $_ }).Count
            $fallback = ConvertFrom-GpoListEntry @($entries)
            $fbNamed = @($fallback.Gpos).Count
            if ($fbNamed -gt 0) { $gp = $fallback; $gpSource = 'registry' }
        } catch {
            $fbError = $_.Exception.Message
            $fbMissing = ($_.Exception -is [System.Management.Automation.ItemNotFoundException])
            Write-Swallowed $_
        }
        # Say what the fallback found, so a MANUAL row can be followed up (#215).
        if (-not $gp) { $gpError = ($gpError + ' | ' + (Get-GpoFallbackNote $fbEntries $fbNamed $fbError $fbMissing)).Trim(' |') }
    }
    $groups = @(); $filters = @{}; $adError = ''; $adRead = $true
    if ($domainMember) {
        try {
            # Assign first: the function returns the list as one object.
            $groups = Get-AdComputerGroup
            $groups = @($groups | Where-Object { $_ })
            if ($gp) { $filters = Get-WmiFilterQuery @($gp.Gpos | ForEach-Object { $_.Guid }) }
        } catch { $adRead = $false; $adError = $_.Exception.Message; Write-Swallowed $_ }
    }
    # Where the computer object is in AD (#99): the OU decides which GPOs link.
    $dn = ''
    if ($domainMember -and $adRead) {
        try { $dn = Get-AdComputerDn } catch { Write-Swallowed $_ }
    }
    if ($dn) {
        $script:Data.AdLocation = ConvertTo-AdLocation $dn
        Add-Result 'GROUP_POLICY' 'ComputerOU' 'INFO' $script:Data.AdLocation ('DistinguishedName=' + $dn) -Source 'AD computer object (distinguishedName)'
        if ($script:Data.Snapshot) { $script:Data.Snapshot.Ou = $dn }
    } elseif (-not $domainMember) {
        $script:Data.AdLocation = 'Not applicable (workgroup)'
    } elseif ($adRead) {
        $script:Data.AdLocation = 'Not readable'
    } else {
        $script:Data.AdLocation = 'Not readable (domain not reachable)'
    }
    $last = $null
    if ($domainMember) { $last = Get-GroupPolicyLastApplied }
    foreach ($row in (Get-GroupPolicyDecision $domainMember ($null -ne $gp) $adRead $last (Get-Date) $GroupPolicyMaxAgeDays $gpError $adError)) {
        Add-Result 'GROUP_POLICY' $row.Item $row.Status $row.Value $row.Details -Recommendation $row.Recommendation -Kind $row.Kind -Source 'gpresult, Active Directory, Group Policy state'
    }
    if ($gpSource -eq 'registry') {
        Add-Result 'GROUP_POLICY' 'GroupPolicySource' 'INFO' 'Applied GPOs read from the Group Policy state in the registry' @('gpresult: ' + $gpError, 'Only applied GPOs are recorded there: GPOs filtered out (and why) are not listed.') -Source 'HKLM\...\Group Policy\State\Machine\GPO-List'
    }
    if ($gp) {
        $target = Get-ReleaseDisplayName $TargetServerVersion
        foreach ($g in @($gp.Gpos)) {
            Add-RedactionLiteral $g.Name 'GPO'
            if ($g.FilterName) { Add-RedactionLiteral $g.FilterName 'NAME' }
            $state = 'Applied'; if (-not $g.Applied) { $state = $g.Reason }
            $details = @(('Linked at ' + (@($g.Links) -join '; ')))
            $filter = $filters[$g.Guid]
            if ($filter) {
                Add-RedactionLiteral $filter.Name 'NAME'
                $details += ('WMI filter: ' + $filter.Name)
                foreach ($q in @($filter.Queries)) { $details += ('Query: ' + $q.Query) }
            } elseif ($g.FilterName) { $details += ('WMI filter: ' + $g.FilterName) }
            $osDependent = $filter -and @($filter.Queries | Where-Object { Test-WmiFilterOsDependent $_.Query }).Count -gt 0
            if ($osDependent) {
                Add-Result 'GROUP_POLICY' ('GPO: ' + $g.Name) 'WARNING' ($state + ' - WMI filter depends on the Windows version') $details -Recommendation ('After the upgrade the server reports ' + $target + '. Check that this filter still matches (or still excludes) it as intended, before the change.') -Source 'gpresult, WMI filter in AD'
            } else {
                Add-Result 'GROUP_POLICY' ('GPO: ' + $g.Name) 'INFO' $state $details -Source $gpSource
            }
        }
        if (-not $domainMember) {
            Add-Result 'GROUP_POLICY' 'ADGroup' 'INFO' 'Not applicable (workgroup)' -Source 'Win32_ComputerSystem'
        }
        if ($script:Data.Snapshot) {
            $script:Data.Snapshot.Gpos = @($gp.Gpos | Where-Object { $_.Applied } | ForEach-Object { $_.Name } | Sort-Object -Unique)
        }
    } elseif (-not $domainMember) {
        # Workgroup server and gpresult failed: still only local policy.
        Add-Result 'GROUP_POLICY' 'LocalPolicy' 'MANUAL' 'Could not list the local policy (gpresult)' $gpError -Recommendation (Get-LocalPolicyAdvice (Test-LgpoAvailable) $EnableRDPPolicyEvidence) -Kind 'Finding' -Source 'gpresult'
    }
    # The AD groups come from AD, not gpresult: list them even when no GPO
    # list could be read (#160).
    if ($domainMember -and $adRead) {
        foreach ($n in $groups) { Add-Result 'GROUP_POLICY' 'ADGroup' 'INFO' $n -Source 'AD tokenGroups (nested groups included)' }
        if ($script:Data.Snapshot) { $script:Data.Snapshot.Groups = @($groups) }
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'rdp' -Name 'RDP access, policy and evidence' -Script {
    Invoke-RdpPolicyAssessment
}

# ---------------------------------------------------------------------------
Register-Check -Id 'platform' -Name 'Platform and hardware' -Script {
    $cs = $script:Data.CS; $bios = $script:Data.BIOS
    $platform = $script:Data.Platform
    if ($platform.Type -eq 'Virtual') {
        Add-Result 'PLATFORM' 'PhysicalOrVirtual' 'OK' ('Virtual (' + $platform.Hypervisor + ')') @(('Manufacturer=' + $cs.Manufacturer),('Model=' + $cs.Model)) -Source 'Win32_ComputerSystem'
        if ($platform.Hypervisor -match 'AWS|Google|Azure') {
            Add-Result 'PLATFORM' 'CloudProvider' 'MANUAL' $platform.Hypervisor -Recommendation 'Microsoft defers cloud IPU support to the provider. Follow the provider''s documented in-place upgrade procedure and licensing rules.' -Source 'Platform classification'
        }
        return
    }
    if ($platform.Type -eq 'Unknown') {
        Add-Result 'PLATFORM' 'PhysicalOrVirtual' 'MANUAL' 'Could not be determined' -Recommendation 'Confirm the platform manually.' -Source 'Win32_ComputerSystem'
        return
    }
    Add-Result 'PLATFORM' 'PhysicalOrVirtual' 'MANUAL' 'Physical' @(('Manufacturer=' + $cs.Manufacturer),('Model=' + $cs.Model)) -Recommendation ('Validate model, firmware, storage controller and NIC driver support for ' + (Get-ReleaseDisplayName $TargetServerVersion) + ' with the OEM, and confirm a bare-metal recovery path.') -Source 'Local inventory cannot prove OEM certification'

    $product = @(Get-CimSafe 'Win32_ComputerSystemProduct') | Select-Object -First 1
    $board = @(Get-CimSafe 'Win32_BaseBoard') | Select-Object -First 1
    Add-Result 'HARDWARE' 'SystemIdentification' 'INFO' ('Model=' + $cs.Model) @(('SerialOrServiceTag=' + $bios.SerialNumber),('SKU=' + $cs.SystemSKUNumber),('Product=' + $product.Name + ' ' + $product.Version)) -Source 'Win32_ComputerSystem, Win32_BIOS'
    if ($board) { Add-Result 'HARDWARE' 'BaseBoard' 'INFO' ('Manufacturer=' + $board.Manufacturer) @(('Product=' + $board.Product),('Version=' + $board.Version)) -Source 'Win32_BaseBoard' }
    if ($bios) {
        $biosDate = [string]$bios.ReleaseDate
        $releaseDate = ConvertTo-DateTimeValue $bios.ReleaseDate
        if ($releaseDate) { $biosDate = $releaseDate.ToString('yyyy-MM-dd') }
        Add-Result 'HARDWARE' 'BIOS' 'INFO' ('Version=' + $bios.SMBIOSBIOSVersion) @(('Manufacturer=' + $bios.Manufacturer),('ReleaseDate=' + $biosDate)) -Source 'Win32_BIOS'
    }
    $firmware = 'Legacy BIOS or undetermined'
    if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State') { $firmware = 'UEFI' }
    Add-Result 'HARDWARE' 'FirmwareMode' 'INFO' $firmware -Source 'SecureBoot registry presence'
    $i = 0
    foreach ($cpu in $script:Data.CPU) { $i++; Add-Result 'HARDWARE' ('CPU-' + $i) 'INFO' $cpu.Name @(('Cores=' + $cpu.NumberOfCores),('Logical=' + $cpu.NumberOfLogicalProcessors)) -Source 'Win32_Processor' }

    $netDrivers = @(Get-CimSafe 'Win32_PnPSignedDriver' "DeviceClass='NET'")
    foreach ($nic in @(Get-CimSafe 'Win32_NetworkAdapter' | Where-Object { $_.PhysicalAdapter -eq $true })) {
        $drv = @($netDrivers | Where-Object { $_.DeviceID -eq $nic.PNPDeviceID }) | Select-Object -First 1
        $drvText = 'Driver not correlated'
        if ($drv) { $drvText = 'Provider=' + $drv.DriverProviderName + ', Version=' + $drv.DriverVersion + ', Date=' + $drv.DriverDate }
        Add-Result 'HARDWARE' ('NIC: ' + $nic.Name) 'INFO' ('MAC=' + $nic.MACAddress) $drvText -Source 'Win32_NetworkAdapter, Win32_PnPSignedDriver'
    }
    $storageDrivers = @(Get-CimSafe 'Win32_PnPSignedDriver' "DeviceClass='SCSIAdapter'") + @(Get-CimSafe 'Win32_PnPSignedDriver' "DeviceClass='HDC'")
    foreach ($drv in @($storageDrivers | Sort-Object DeviceName,DriverVersion -Unique)) {
        Add-Result 'HARDWARE' ('Storage controller: ' + $drv.DeviceName) 'INFO' ('Provider=' + $drv.DriverProviderName) @(('Version=' + $drv.DriverVersion),('Date=' + $drv.DriverDate)) -Source 'Win32_PnPSignedDriver'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'performance' -Name 'CPU and memory' -Script {
    $cs = $script:Data.CS
    $logical = [int]$cs.NumberOfLogicalProcessors
    if ($logical -le 1) { Add-Result 'PERFORMANCE' 'LogicalProcessors' 'ACTION' $logical -Recommendation 'Add CPU before IPU; setup on a single logical CPU is very slow.' -Source 'Win32_ComputerSystem' }
    elseif ($logical -eq 2) { Add-Result 'PERFORMANCE' 'LogicalProcessors' 'WARNING' $logical -Recommendation 'Setup will be noticeably slower on 2 logical CPUs; consider adding CPU temporarily for the change window.' -Source 'Win32_ComputerSystem' }
    else { Add-Result 'PERFORMANCE' 'LogicalProcessors' 'OK' $logical -Source 'Win32_ComputerSystem' }
    $ramGB = [math]::Round(([double]$cs.TotalPhysicalMemory / 1GB),2)
    if ($ramGB -lt $MinimumMemoryGB) { Add-Result 'PERFORMANCE' 'MemoryGB' 'WARNING' (Format-Number $ramGB) -Recommendation ('Below the project threshold of ' + $MinimumMemoryGB + ' GB; consider adding memory before IPU.') -Source 'Win32_ComputerSystem' }
    else { Add-Result 'PERFORMANCE' 'MemoryGB' 'OK' (Format-Number $ramGB) -Source 'Win32_ComputerSystem' }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'cluster' -Name 'Failover clustering' -Script {
    $clusSvcPresent = @($script:Data.Services | Where-Object { $_.Name -eq 'ClusSvc' -and $_.StartMode -ne 'Disabled' }).Count -gt 0
    $feature = Resolve-ClusterFeatureState (Get-FeatureState 'Failover-Clustering') $clusSvcPresent ([bool](Test-Path 'HKLM:\Cluster'))
    if ($null -eq $feature) { Add-Result 'CLUSTER' 'FailoverClustering' 'MANUAL' 'Feature state unknown: the role inventory failed' -Recommendation 'Confirm by hand whether this server is a cluster node (Get-Cluster, the Cluster service) before planning an IPU.' -Source 'Get-WindowsFeature'; return }
    if ($feature -ne $true) { Add-Result 'CLUSTER' 'FailoverClustering' 'OK' 'Feature not installed' -Source 'Get-WindowsFeature'; return }
    if (-not (Test-CommandAvailable 'Get-Cluster')) {
        Add-Result 'CLUSTER' 'FailoverClustering' 'ACTION' 'Feature installed; cluster cmdlets unavailable' -Recommendation 'Confirm cluster membership before planning an IPU.' -Source 'Get-WindowsFeature'
        return
    }
    $cluster = $null
    try { $cluster = Get-Cluster -ErrorAction Stop } catch { Write-Swallowed $_ }
    if (-not $cluster) {
        Add-Result 'CLUSTER' 'FailoverClustering' 'WARNING' 'Feature installed but no cluster membership found' -Recommendation 'Remove the feature if unused, or confirm the node is not part of a cluster.' -Source 'Get-Cluster'
        return
    }
    $script:Data.IsClustered = $true
    # Reported as SPECIAL with its own plan (#152); names are site data.
    Add-RedactionLiteral ([string]$cluster.Name) 'HOST'
    $script:Data.ClusterName = [string]$cluster.Name
    Add-Result 'CLUSTER' 'ClusterMembership' 'INFO' ('Cluster=' + $cluster.Name) -Recommendation 'Cluster node: not a standard in-place upgrade - see the SPECIAL section.' -Source 'Get-Cluster'
    foreach ($n in @(Get-ClusterNode -ErrorAction SilentlyContinue)) { Add-RedactionLiteral ([string]$n.Name) 'HOST'; Add-Result 'CLUSTER' ('Node: ' + $n.Name) 'INFO' ('State=' + $n.State) -Source 'Get-ClusterNode' }
    foreach ($g in @(Get-ClusterGroup -ErrorAction SilentlyContinue | Sort-Object Name)) { Add-Result 'CLUSTER' ('Group: ' + $g.Name) 'INFO' ('State=' + $g.State) ('Owner=' + $g.OwnerNode) -Source 'Get-ClusterGroup' }
    $q = Get-ClusterQuorum -ErrorAction SilentlyContinue
    if ($q) { Add-Result 'CLUSTER' 'Quorum' 'INFO' ('Type=' + $q.QuorumType) ('Resource=' + $q.QuorumResource) -Source 'Get-ClusterQuorum' }
    foreach ($csv in @(Get-ClusterSharedVolume -ErrorAction SilentlyContinue)) { Add-Result 'CLUSTER' ('CSV: ' + $csv.Name) 'INFO' ('State=' + $csv.State) ('Owner=' + $csv.OwnerNode) -Source 'Get-ClusterSharedVolume' }
    foreach ($r in @(Get-ClusterResource -ErrorAction SilentlyContinue | Where-Object { [string]$_.ResourceType -eq 'Physical Disk' })) { Add-Result 'CLUSTER' ('Disk: ' + $r.Name) 'INFO' ('State=' + $r.State) ('Group=' + $r.OwnerGroup) -Source 'Get-ClusterResource' }
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
Register-Check -Id 'special' -Name 'SPECIAL server (cluster node, domain controller)' -Script {
    # #152: a cluster node or a domain controller is not a standard IPU. The
    # main flow has decided the kind after the baseline; this check writes
    # the SPECIAL row and what the report tells the project and the customer.
    $kind = [string]$script:Data.SpecialKind
    if (-not $kind) { return }
    if ($kind -eq 'Undecided') {
        Add-Result 'SPECIAL' 'ClusterMembership' 'MANUAL' 'Cluster membership could not be decided' 'The Failover Clustering feature is installed, but the cluster service and the cluster registry key disagree.' -Recommendation 'Check in Failover Cluster Manager whether this server is a cluster node. A cluster node is not a standard in-place upgrade.' -Source 'Get-WindowsFeature, Win32_Service, HKLM:\Cluster'
        return
    }
    $content = Get-SpecialServerContent $kind ([string]$script:Data.SourceRelease) $TargetServerVersion
    $facts = Get-SpecialServerFact $kind
    $content | Add-Member -NotePropertyName Facts -NotePropertyValue @($facts) -Force
    $script:Data.Special = $content
    $first = @($content.Options | Where-Object { $_.Url }) | Select-Object -First 1
    Add-Result 'SPECIAL' $content.Title 'SPECIAL' 'Not a standard in-place upgrade: expensive and risky' @($facts) -Recommendation 'Separate plan needed. Tell the project and the customer. See the SPECIAL section for the risks and the options.' -Source 'Domain role, cluster' -Link $first.Url -LinkTitle $first.Title
}

# ---------------------------------------------------------------------------
Register-Check -Id 'storage' -Name 'Storage' -Script {
    $c = @(Get-CimRequired 'Win32_LogicalDisk' "DeviceID='C:'") | Select-Object -First 1
    $sizeGB = [math]::Round(([double]$c.Size / 1GB),2)
    $freeGB = [math]::Round(([double]$c.FreeSpace / 1GB),2)
    $script:Data.CSummary = 'Size ' + (Format-Number $sizeGB) + ' GB, free ' + (Format-Number $freeGB) + ' GB'
    if ($freeGB -lt $MinimumCFreeGB) {
        $needed = [math]::Ceiling(($MinimumCFreeGB - $freeGB) / $ExtendBlockGB) * $ExtendBlockGB
        Add-Result 'STORAGE' 'CFreeSpace' 'ACTION' $script:Data.CSummary ('RequiredExpansionGB=' + $needed) -Recommendation ('Extend C: by at least ' + $needed + ' GB to reach the ' + $MinimumCFreeGB + ' GB free-space target.') -Source 'Win32_LogicalDisk' -Command (Get-RecommendationCommand 'CFreeSpace').Command -CommandKind 'Check'
    } else {
        Add-Result 'STORAGE' 'CFreeSpace' 'OK' $script:Data.CSummary -Source 'Win32_LogicalDisk'
    }

    if (-not (Test-CommandAvailable 'Get-Disk')) {
        foreach ($d in @(Get-CimSafe 'Win32_DiskDrive' | Sort-Object Index)) { Add-Result 'STORAGE' ('Disk' + $d.Index) 'INFO' ('SizeGB=' + (Format-Number ($d.Size/1GB))) ('Model=' + $d.Model) -Source 'Win32_DiskDrive' }
        return
    }
    $cp = Get-Partition -DriveLetter C
    $after = @(Get-Partition -DiskNumber $cp.DiskNumber | Where-Object { $_.Offset -gt $cp.Offset } | Sort-Object Offset)
    if ($after.Count -gt 0) {
        $desc = @($after | ForEach-Object { 'P' + $_.PartitionNumber + ':' + [math]::Round($_.Size/1MB) + 'MB:' + $_.Type })
        Add-Result 'STORAGE' 'PartitionAfterC' 'WARNING' 'Yes' $desc -Recommendation 'A partition after C: (often WinRE) blocks simple extension of C:. Plan the layout change before the window if C: needs to grow.' -Source 'Get-Partition'
    } else {
        Add-Result 'STORAGE' 'PartitionAfterC' 'OK' 'No' -Source 'Get-Partition'
    }
    # Recovery partition layout (#161): reagentc /info is read-only.
    $winRe = $null
    $ra = Invoke-NativeCapture (Join-Path $env:windir 'System32\reagentc.exe') @('/info') 60
    if ($ra.TimedOut -or $ra.Error -or ($null -ne $ra.ExitCode -and [int]$ra.ExitCode -ne 0)) {
        Add-Result 'STORAGE' 'WinREStatus' 'MANUAL' 'reagentc /info failed' ([string]$ra.Error + ' ExitCode=' + $ra.ExitCode) -Recommendation 'Run "reagentc /info" as administrator to see where WinRE is before changing partitions.' -Kind 'Finding' -Source 'reagentc /info'
    } else {
        $winRe = ConvertFrom-ReagentcInfo $ra.Output
        if ($null -ne $winRe.Partition -or $null -ne $winRe.Enabled) {
            $where = 'Location not reported'; if ($null -ne $winRe.Partition) { $where = 'Disk' + $winRe.Disk + ' P' + $winRe.Partition }
            $state = 'Unknown'; if ($winRe.Enabled -eq $true) { $state = 'Enabled' } elseif ($winRe.Enabled -eq $false) { $state = 'Disabled' }
            Add-Result 'STORAGE' 'WinREStatus' 'INFO' ($state + ', ' + $where) -Source 'reagentc /info'
        }
    }
    # The first Get-Partition of this check (without SilentlyContinue) already stops the check when the layout cannot be read; it is then reported as not completed.
    $layout = @(Get-Partition -DiskNumber $cp.DiskNumber -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{ PartitionNumber = $_.PartitionNumber; Offset = [double]$_.Offset; SizeMB = [double]$_.Size / 1MB; IsRecovery = (([string]$_.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}') -or ([string]$_.Type -eq 'Recovery') -or ([int]$_.MbrType -eq 39)) }
    })
    $wrePart = $null; if ($winRe -and $winRe.Disk -eq $cp.DiskNumber) { $wrePart = $winRe.Partition }
    $rd = Get-RecoveryPartitionDecision $layout ([int]$cp.PartitionNumber) $wrePart $AssessmentMode
    if ($rd.Kind -eq 'AfterC') {
        Add-Result 'STORAGE' 'RecoveryPartitionAfterC' $rd.Status $rd.Value -Recommendation $rd.Text -Source 'Get-Partition, reagentc /info' -Command (Get-RecommendationCommand 'RemoveRecoveryPartition' @{ Disk = $cp.DiskNumber; Partition = $rd.PartitionNumber }).Command -CommandKind 'Change' -Link $script:DocLinks.WinReResize.Url -LinkTitle $script:DocLinks.WinReResize.Title
    } elseif ($rd.Kind -eq 'LikelyNew') {
        Add-Result 'STORAGE' 'RecoveryPartitionAfterC' $rd.Status $rd.Value -Recommendation $rd.Text -Source 'Get-Partition' -Command (Get-RecommendationCommand 'SetupNoRecoveryPartition').Command -CommandKind 'Change' -Link $script:DocLinks.SetupOptions.Url -LinkTitle $script:DocLinks.SetupOptions.Title
    } else {
        Add-Result 'STORAGE' 'RecoveryPartitionAfterC' 'OK' $rd.Value -Source 'Get-Partition'
    }
    try {
        # Worked out from the partition layout: Get-PartitionSupportedSize
        # computes the shrink size too and can take minutes on a large volume (#241).
        $diskSize = [double](Get-Disk -Number $cp.DiskNumber -ErrorAction Stop).Size
        $spaceAfterC = Get-SpaceAfterPartition ([double]$cp.Offset) ([double]$cp.Size) @($layout | ForEach-Object { $_.Offset }) $diskSize
        Add-Result 'STORAGE' 'CExtendableNowGB' 'INFO' (Format-Number ($spaceAfterC / 1GB)) 'Currently available contiguous space only.' -Source 'Get-Partition, Get-Disk'
    } catch { Write-Swallowed $_ }

    $total = 0
    $recoveryGuid = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
    foreach ($d in @(Get-Disk | Sort-Object Number)) {
        $total += [double]$d.Size
        $parts = @()
        # SilentlyContinue: a disk without partitions (raw, offline) is normal; the disk row below still lists it.
        foreach ($p in @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Sort-Object Offset)) {
            $vol = $null; $volError = ''
            try { $vol = $p | Get-Volume -ErrorAction Stop } catch { $volError = $_.Exception.Message; Write-Swallowed $_ }
            $t = 'P' + $p.PartitionNumber + ':' + $p.Type + ':' + [math]::Round($p.Size/1MB) + 'MB'
            if ($p.DriveLetter) { $t += ':' + $p.DriveLetter + ':' }
            $paths = @($p.AccessPaths | Where-Object { $_ -and $_ -notmatch '^\\\\\?\\Volume' -and $_ -notmatch '^[A-Z]:\\$' })
            if ($paths.Count -gt 0) { $t += ':MountedAt=' + ($paths -join ',') }
            if ($vol -and $vol.FileSystemLabel) { $t += ':Label=' + $vol.FileSystemLabel }
            if ($vol -and $vol.FileSystem) { $t += ':' + $vol.FileSystem }
            $parts += $t

            # System partition (EFI or System Reserved) and WinRE recovery
            # partition free space - Setup writes boot files and WinRE to them.
            $isRecovery = ([string]$p.GptType -eq $recoveryGuid) -or ([string]$p.Type -eq 'Recovery') -or ([int]$p.MbrType -eq 39)
            if (($p.IsSystem -or $isRecovery) -and -not $vol) {
                # Free space is what Setup needs here; a partition whose volume cannot be read is not "fine" (#242).
                $unreadName = 'SystemPartition'
                if ($isRecovery) { $unreadName = 'RecoveryPartition' }
                Add-Result 'STORAGE' $unreadName 'MANUAL' ('Disk' + $d.Number + ' P' + $p.PartitionNumber + ': free space not readable') $volError -Recommendation 'Check the free space of this partition by hand (diskpart, or mountvol) before the change; Setup writes boot files and WinRE to it.' -Kind 'Finding' -Source 'Get-Partition, Get-Volume'
            }
            if (($p.IsSystem -or $isRecovery) -and $vol -and $vol.Size -gt 0) {
                $freeMB = [math]::Round($vol.SizeRemaining/1MB)
                $kindName = 'SystemPartition'; $limit = $SystemPartitionMinFreeMB
                $rec = 'Free space on the system (EFI/System Reserved) partition is below the project threshold of ' + $SystemPartitionMinFreeMB + ' MB. Setup writes boot files here; a full system partition is a known cause of upgrade failure. Free space or enlarge it before IPU.'
                if ($isRecovery) { $kindName = 'RecoveryPartition'; $limit = $RecoveryPartitionMinFreeMB; $rec = 'Less than ' + $RecoveryPartitionMinFreeMB + ' MB free on the WinRE recovery partition, the space Microsoft asks for when servicing WinRE. Not an IPU blocker by itself, but WinRE updates may fail.' }
                $value = 'Disk' + $d.Number + ' P' + $p.PartitionNumber + ': ' + [math]::Round($vol.Size/1MB) + ' MB, free ' + $freeMB + ' MB'
                if ($freeMB -lt $limit) {
                    if ($isRecovery) { Add-Result 'STORAGE' $kindName 'WARNING' $value '' -Recommendation $rec -Kind 'Observation' -Source 'Get-Partition, Get-Volume' }
                    else { Add-Result 'STORAGE' $kindName 'WARNING' $value '' -Recommendation $rec -Source 'Get-Partition, Get-Volume' }
                } else {
                    Add-Result 'STORAGE' $kindName 'OK' $value -Source 'Get-Partition, Get-Volume'
                }
            }
        }
        Add-Result 'STORAGE' ('Disk' + $d.Number) 'INFO' ('SizeGB=' + (Format-Number ($d.Size/1GB))) @(('BusType=' + $d.BusType),('Style=' + $d.PartitionStyle),('Offline=' + $d.IsOffline),($parts -join ' | ')) -Source 'Get-Disk, Get-Partition, Get-Volume'
    }
    Add-Result 'STORAGE' 'AllocatedDiskCapacity' 'INFO' ('TotalGB=' + (Format-Number ($total/1GB))) 'Rough indication of VM snapshot exposure; growth depends on changed blocks.' -Source 'Get-Disk'
}

# ---------------------------------------------------------------------------
Register-Check -Id 'network' -Name 'Network, teaming, hosts and routes' -Script {
    # VLAN IDs come from the NetAdapter module (optional, #94), by MAC (#149).
    $vlanByMac = @{}
    if (Test-CommandAvailable 'Get-NetAdapter') {
        try {
            foreach ($na in @(Get-NetAdapter -ErrorAction Stop)) {
                if ($na -and $na.MacAddress) { $vlanByMac[(ConvertTo-MacKey ([string]$na.MacAddress))] = $na.VlanID }
            }
        } catch { Write-Swallowed $_ }
    }
    foreach ($n in @(Get-CimRequired 'Win32_NetworkAdapterConfiguration' 'IPEnabled=True')) {
        $a = @(Get-CimSafe 'Win32_NetworkAdapter' ('Index=' + $n.Index)) | Select-Object -First 1
        $name = [string]$a.NetConnectionID; if (-not $name) { $name = [string]$n.Description }
        $rec = ConvertTo-NetworkAdapterRecord $n $name $vlanByMac[(ConvertTo-MacKey ([string]$n.MACAddress))]
        $script:Data.Snapshot.IPv4 += $rec.IPv4
        $script:Data.Snapshot.Dns += $rec.Dns
        $script:Data.Snapshot.Adapters += $rec
        Add-Result 'NETWORK' $name 'INFO' ('IPv4=' + ($rec.IPv4 -join ',') + ' / ' + ($rec.Mask -join ',')) (Get-NetworkAdapterDetail $rec) -Source 'Win32_NetworkAdapterConfiguration'
    }

    # A local copy of the full network configuration (#149), for the network
    # team if the upgrade resets an adapter. Read-only commands.
    if ($EnableNetworkEvidence) {
        try {
            $dest = Join-Path (Initialize-EvidenceFolder 'Network') ($script:SafeComputerName + '-IPU-Network-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
            $copy = Save-NetworkEvidence -Destination $dest -Zip $CreatePolicyEvidenceZip
            $script:Data.NetworkEvidence = $copy.Location
            $keep = 'Copy it off the server before the change: it holds the full IP configuration, is not redacted and must not be shared outside the team. netsh-interface-dump.txt is a netsh script that can put the configuration back (read it first; see the user guide).'
            if (@($copy.Failed).Count -gt 0) {
                Add-Result 'NETWORK' 'NetworkEvidence' 'MANUAL' $copy.Location (@(('Saved=' + ($copy.Files -join ', '))) + @($copy.Failed | ForEach-Object { 'Failed: ' + $_ })) -Recommendation ('Run the failed commands by hand and keep their output with the file. ' + $keep) -Kind 'Finding' -Source 'ipconfig, route, netsh (read-only)'
            } else {
                Add-Result 'NETWORK' 'NetworkEvidence' 'OK' $copy.Location ('Files=' + ($copy.Files -join ', ')) -Recommendation $keep -Source 'ipconfig, route, netsh (read-only)'
            }
        } catch {
            Add-Result 'NETWORK' 'NetworkEvidence' 'MANUAL' 'Could not save the network configuration' $_.Exception.Message -Recommendation 'Before the change, save the output of "ipconfig /all", "route print" and "netsh -c interface dump" by hand and keep it off the server.' -Kind 'Finding' -Source 'ipconfig, route, netsh'
        }
    } else {
        Add-Result 'NETWORK' 'NetworkEvidence' 'INFO' 'Not taken (EnableNetworkEvidence is off)' -Source 'SETTINGS'
    }

    # NIC teaming. Microsoft: disable LBFO teaming before IPU and re-enable
    # after. An LBFO team bound to a Hyper-V vSwitch is not supported on
    # Windows Server 2022/2025 Hyper-V - convert to Switch Embedded Teaming.
    $vSwitchDescriptions = @()
    if (Test-CommandAvailable 'Get-VMSwitch') {
        try { $vSwitchDescriptions = @(Get-VMSwitch -ErrorAction Stop | Where-Object { $_.NetAdapterInterfaceDescription } | ForEach-Object { [string]$_.NetAdapterInterfaceDescription }) } catch { Write-Swallowed $_ }
        try {
            foreach ($set in @(Get-VMSwitchTeam -ErrorAction Stop)) {
                Add-Result 'NETWORK' ('SET: ' + $set.Name) 'INFO' 'Switch Embedded Teaming' ('Members=' + (@($set.NetAdapterInterfaceDescription) -join ', ')) -Source 'Get-VMSwitchTeam'
            }
        } catch { Write-Swallowed $_ }
    }
    $teams = @(); $lbfoError = ''
    if (Test-CommandAvailable 'Get-NetLbfoTeam') {
        try { $teams = @(Get-NetLbfoTeam -ErrorAction Stop) }
        catch { if (-not (Test-NotFoundError $_)) { $lbfoError = $_.Exception.Message; Write-Swallowed $_ } }
    } else { $lbfoError = 'Get-NetLbfoTeam is not available (NetLbfo module)' }
    foreach ($t in $teams) {
        # SilentlyContinue: only decides whether the team is bound to a vSwitch; no adapter means "not bound".
        $teamNic = Get-NetAdapter -Name $t.Name -ErrorAction SilentlyContinue
        $boundToVSwitch = ($teamNic -and $vSwitchDescriptions -contains [string]$teamNic.InterfaceDescription)
        $details = @(('Mode=' + $t.TeamingMode),('LoadBalancing=' + $t.LoadBalancingAlgorithm),('Members=' + (@($t.Members) -join ',')))
        if ($boundToVSwitch) {
            Add-Result 'NETWORK' ('LBFO team: ' + $t.Name) 'ACTION' 'LBFO team bound to a Hyper-V virtual switch' $details -Recommendation 'LBFO under a Hyper-V vSwitch is not supported on Windows Server 2022/2025. Convert to Switch Embedded Teaming (SET) as a separate, planned change before IPU.' -Source 'Get-NetLbfoTeam, Get-VMSwitch' -Command (Get-RecommendationCommand 'LbfoTeams').Command -CommandKind 'Check'
        } else {
            Add-Result 'NETWORK' ('LBFO team: ' + $t.Name) 'ACTION' ('Status=' + $t.Status) $details -Recommendation 'Microsoft requires NIC Teaming to be disabled before IPU and re-enabled afterwards. Plan console access - the team carries the server''s IP configuration.' -Source 'Get-NetLbfoTeam' -Command (Get-RecommendationCommand 'LbfoTeams').Command -CommandKind 'Check'
        }
    }
    if ($lbfoError) {
        # An LBFO team that was not seen is an upgrade blocker; never report "none" when the query failed (#242).
        Add-Result 'NETWORK' 'NICTeaming' 'MANUAL' 'LBFO teams could not be read' $lbfoError -Recommendation 'Run Get-NetLbfoTeam (or look in Server Manager > NIC Teaming) by hand. Microsoft requires NIC Teaming to be disabled before IPU.' -Kind 'Finding' -Source 'Get-NetLbfoTeam'
    } elseif ($teams.Count -eq 0) { Add-Result 'NETWORK' 'NICTeaming' 'OK' 'No LBFO team detected' -Source 'Get-NetLbfoTeam' }

    # Hosts file - active (non-comment) entries.
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $entries = 0; $lineNo = 0
    $hostsLines = @()
    if (Test-Path -LiteralPath $hostsPath) { $hostsLines = @(Get-Content -LiteralPath $hostsPath) }
    foreach ($line in $hostsLines) {
        $lineNo++
        $active = (([string]$line -split '#',2)[0]).Trim()
        if (-not $active) { continue }
        $entries++
        $script:Data.Snapshot.Hosts += ($active -replace '\s+',' ')
        $tokens = @($active -split '\s+')
        Add-Result 'NETWORK_DEPENDENCY' ('Hosts line ' + $lineNo) 'INFO' ('Address=' + $tokens[0]) ('Names=' + (@($tokens | Select-Object -Skip 1) -join ',')) -Source $hostsPath
    }
    if ($entries -gt 0) {
        Add-Result 'NETWORK_DEPENDENCY' 'HostsFile' 'MANUAL' ('ActiveEntries=' + $entries) $hostsPath -Recommendation 'Confirm owner and purpose of each hosts entry and test the affected name resolution after IPU.' -Source 'hosts file'
    } else {
        Add-Result 'NETWORK_DEPENDENCY' 'HostsFile' 'OK' 'No active entries' -Source $hostsPath
    }

    # Static routes - persistent and active manual (NetMgmt), excluding defaults.
    if (-not (Test-CommandAvailable 'Get-NetRoute')) {
        Add-Result 'NETWORK_DEPENDENCY' 'StaticRoutes' 'MANUAL' 'Get-NetRoute unavailable' -Recommendation 'Run "route print" and document persistent routes manually.' -Source 'NetTCPIP'
        return
    }
    $seen = @{}; $routes = @(); $routeError = ''
    # No persistent route (or none matching) is an ObjectNotFound answer: empty, not failed (#242).
    $persistentRoutes = @()
    try { $persistentRoutes = @(Get-NetRoute -PolicyStore PersistentStore -ErrorAction Stop) }
    catch { if (-not (Test-NotFoundError $_)) { $routeError = $_.Exception.Message; Write-Swallowed $_ } }
    $activeRoutes = @()
    try { $activeRoutes = @(Get-NetRoute -ErrorAction Stop | Where-Object { [string]$_.Protocol -eq 'NetMgmt' }) }
    catch { if (-not (Test-NotFoundError $_)) { $routeError = $_.Exception.Message; Write-Swallowed $_ } }
    foreach ($r in $persistentRoutes) {
        if ($r.DestinationPrefix -in @('0.0.0.0/0','::/0')) { continue }
        $k = [string]$r.DestinationPrefix + '|' + $r.NextHop + '|' + $r.InterfaceIndex
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $routes += [pscustomobject]@{ R=$r; Source='Persistent' } }
    }
    foreach ($r in $activeRoutes) {
        if ($r.DestinationPrefix -in @('0.0.0.0/0','::/0')) { continue }
        $k = [string]$r.DestinationPrefix + '|' + $r.NextHop + '|' + $r.InterfaceIndex
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $routes += [pscustomobject]@{ R=$r; Source='ActiveOnly' } }
    }
    foreach ($x in $routes) {
        $script:Data.Snapshot.Routes += ([string]$x.R.DestinationPrefix + ' via ' + $x.R.NextHop)
        Add-Result 'NETWORK_DEPENDENCY' ('Route ' + $x.R.DestinationPrefix) 'INFO' ('NextHop=' + $x.R.NextHop) @(('Interface=' + $x.R.InterfaceAlias),('Metric=' + $x.R.RouteMetric),('Source=' + $x.Source)) -Source 'Get-NetRoute'
    }
    if ($routeError) {
        # The routes list is left out of the snapshot: the post-upgrade comparison then names it as not compared (#239).
        $script:Data.Snapshot.Remove('Routes')
        Add-Result 'NETWORK_DEPENDENCY' 'StaticRoutes' 'MANUAL' 'Static routes could not be read completely' @($routeError, ('Routes found=' + $routes.Count)) -Recommendation 'Run "route print" and Get-NetRoute -PolicyStore PersistentStore by hand and document the persistent routes.' -Kind 'Finding' -Source 'Get-NetRoute'
    } elseif ($routes.Count -gt 0) {
        $activeOnly = @($routes | Where-Object { $_.Source -eq 'ActiveOnly' }).Count
        Add-Result 'NETWORK_DEPENDENCY' 'StaticRoutes' 'MANUAL' ('Routes=' + $routes.Count) ('ActiveOnly(non-persistent)=' + $activeOnly) -Recommendation 'Confirm each static route is still needed and test it after IPU. Active-only routes are lost at reboot; persistent routes break if the interface index changes (teaming/driver changes).' -Source 'Get-NetRoute'
    } else {
        Add-Result 'NETWORK_DEPENDENCY' 'StaticRoutes' 'OK' 'No non-default persistent or manual routes' -Source 'Get-NetRoute'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'exchange' -Name 'Exchange Server' -Script {
    $exchangeServices = @($script:Data.Services | Where-Object { $_.Name -match '^MSExchange(IS|Transport|FrontEndTransport|ServiceHost|ADTopology|EdgeSync|MailboxAssistants|RPC)$' })
    $setupKeys = @()
    foreach ($v in @('v15','v14','v8.0')) {
        $k = 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\' + $v + '\Setup'
        $p = Get-RegistryValueSafe $k 'MsiInstallPath'
        if ($p.Exists) { $setupKeys += ($v + ': ' + $p.Value) }
    }
    if ($exchangeServices.Count -gt 0) {
        Add-Result 'EXCHANGE' 'ExchangeServerRole' 'BLOCKER' ('Exchange services: ' + (@($exchangeServices | ForEach-Object { $_.Name }) -join ', ')) $setupKeys -Recommendation 'Microsoft does not support an in-place OS upgrade on a server with Exchange installed. Build a new Exchange server on the target OS and migrate.' -Source 'Win32_Service, ExchangeServer\Setup'
    } elseif ($setupKeys.Count -gt 0) {
        Add-Result 'EXCHANGE' 'ExchangeComponents' 'ACTION' 'Exchange setup registration found without Exchange server services' $setupKeys -Recommendation 'Probably Exchange Management Tools only. Confirm with the messaging team; if a server role is installed, IPU is not supported.' -Source 'ExchangeServer\Setup'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'sql' -Name 'SQL Server' -Script {
    $instances = @()
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server','HKLM:\SOFTWARE\Wow6432Node\Microsoft\Microsoft SQL Server')) {
        foreach ($type in @('SQL','RS','OLAP')) {
            $names = Get-ItemProperty (Join-Path $root ('Instance Names\' + $type)) -ErrorAction SilentlyContinue
            if (-not $names) { continue }
            foreach ($prop in @($names.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })) {
                $setup = Get-ItemProperty (Join-Path $root ([string]$prop.Value + '\Setup')) -ErrorAction SilentlyContinue
                $version = [string]$setup.Version
                if (-not $version) { $version = [string]$setup.PatchLevel }
                $instances += [pscustomobject]@{ Instance=$prop.Name; Type=$type; Id=[string]$prop.Value; Version=$version; Edition=[string]$setup.Edition; Root=$root }
            }
        }
    }
    $instances = @($instances | Sort-Object Type,Instance,Id -Unique)
    $script:Data.SqlSummary = ''
    if ($instances.Count -eq 0) { return }
    # Named instances are often named after the application or the customer (#195).
    foreach ($i in $instances) { if ($script:SqlDefaultInstanceNames -notcontains $i.Instance) { Add-RedactionLiteral $i.Instance 'NAME'; Add-RedactionLiteral $i.Id 'NAME' } }
    $summary = @()
    foreach ($i in $instances) {
        $major = 0
        [void][int]::TryParse((($i.Version -split '\.')[0]), [ref]$major)
        $typeName = @{ SQL='Database Engine'; RS='Reporting Services'; OLAP='Analysis Services' }[$i.Type]
        if ($major -le 0) {
            Add-Result 'SQL' ($typeName + ': ' + $i.Instance) 'MANUAL' 'Version not found' ('InstanceId=' + $i.Id) -Recommendation 'Determine the SQL Server version and check it against the target OS support matrix.' -Source ($i.Root + '\Instance Names')
            continue
        }
        $d = Get-SqlSupportDecision $major $TargetServerVersion
        $summary += ($i.Instance + '=' + $d.Release)
        Add-Result 'SQL' ($typeName + ': ' + $i.Instance) $d.Status $d.Release @(('Version=' + $i.Version),('Edition=' + $i.Edition),('InstanceId=' + $i.Id)) -Recommendation $d.Text -Source 'SQL Server instance registry; Microsoft SQL Server / Windows compatibility matrix'
    }
    $script:Data.SqlSummary = ($summary -join ', ')
}

# ---------------------------------------------------------------------------
Register-Check -Id 'workloads' -Name 'Roles and workloads' -Script {
    if ($null -eq $script:Data.Features) {
        Add-Result 'ROLES' 'Inventory' 'MANUAL' 'Get-WindowsFeature unavailable' -Recommendation 'List installed roles/features manually.' -Kind 'Finding' -Source 'ServerManager'
    } else {
        foreach ($name in @($script:Data.Features.Keys | Where-Object { $script:Data.Features[$_] } | Sort-Object)) {
            Add-Result 'ROLES' $name 'INFO' 'Installed' -Source 'Get-WindowsFeature'
        }
    }
    $roleChecks = @(
        @{ Name='DNS';        Label='DNS Server';  Rec='Confirm DNS zones are AD-integrated or replicated, and that clients can use another DNS server during the window.' },
        @{ Name='DHCP';       Label='DHCP Server'; Rec='Back up DHCP (Export-DhcpServer) and confirm failover/partner coverage for the change window.' },
        @{ Name='Print-Server'; Label='Print Server'; Rec='See the Print server section: printers, ports, drivers and the PrintBrm backup.' },
        @{ Name='Hyper-V';    Label='Hyper-V host'; Rec='All guests are affected. Plan guest shutdown/migration and confirm vSwitch teaming is SET, not LBFO.' },
        @{ Name='FS-DFS-Replication'; Label='DFS Replication'; Rec='Confirm DFSR health and backlog before IPU; plan to monitor replication afterwards.' },
        @{ Name='WDS';        Label='Windows Deployment Services'; Rec='Validate WDS/PXE dependencies with the deployment team.' },
        @{ Name='UpdateServices'; Label='WSUS'; Rec='Back up the WSUS database/content and confirm the upgrade method with the patch team.' },
        @{ Name='ADFS-Federation'; Label='AD FS'; Rec='AD FS farms are normally upgraded by adding new servers to the farm. Engage the identity team.' },
        @{ Name='NPAS';       Label='Network Policy Server'; Rec='Export the NPS configuration before IPU.' },
        @{ Name='FS-FileServer'; Label='File Server'; Rec='Document shares and permissions; confirm users are informed of the outage.' }
    )
    foreach ($rc in $roleChecks) {
        if ((Get-FeatureState $rc.Name) -eq $true) { Add-Result 'WORKLOAD' $rc.Label 'WARNING' 'Installed' -Recommendation $rc.Rec -Source 'Get-WindowsFeature' }
    }

    # Application workloads (pattern table in section 2), matched on names
    # and service names only - not executable paths - to avoid false positives.
    foreach ($m in (Find-DetectionMatch $script:DetectionPatterns.Workloads $script:Data.Apps $script:Data.Services)) {
        Add-Result 'WORKLOAD' $m.Label 'WARNING' ('Applications=' + @($m.Apps).Count + ', Services=' + @($m.Services).Count) (Get-DetectionEvidence $m) -Recommendation ('Engage the application owner and confirm ' + $m.Label + ' supports ' + (Get-ReleaseDisplayName $TargetServerVersion) + '.') -Source 'Uninstall registry and Win32_Service names'
    }

    # Features removed or no longer developed in the target release.
    if ($null -ne $script:Data.Features) {
        $installed = @($script:Data.Features.Keys | Where-Object { $script:Data.Features[$_] })
        foreach ($f in (Get-FeatureLifecycleFinding $installed $TargetServerVersion)) {
            Add-Result 'FEATURE_LIFECYCLE' $f.Name $f.Status ('Feature ' + $f.Feature + ' is installed') '' -Recommendation $f.Text -Kind $f.Kind -Source 'Microsoft: features removed or no longer developed'
        }
    }
    $browser = @($script:Data.Services | Where-Object { $_.Name -eq 'Browser' -and $_.State -eq 'Running' })
    if ($browser.Count -gt 0) {
        Add-Result 'FEATURE_LIFECYCLE' 'Computer Browser service' 'WARNING' 'Running' '' -Recommendation 'The Computer Browser protocol is no longer developed by Microsoft. Find out what depends on network browsing (often old SMB1 clients).' -Kind 'Observation' -Source 'Win32_Service'
    }
    foreach ($a in $script:Data.Apps) {
        Add-Result 'APPLICATIONS' $a.Name 'INFO' ('Version=' + $a.Version) @(('Publisher=' + $a.Publisher),('InstallDate=' + $a.InstallDate)) -Source 'Uninstall registry (no Win32_Product)'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'fileshares' -Name 'File shares' -Script {
    # #95: what is shared, from where and to whom, so owners can plan and
    # test, and the post-upgrade run can report a share that is gone.
    $role = Get-FeatureState 'FS-FileServer'
    if (-not (Test-CommandAvailable 'Get-SmbShare')) {
        if ($role -eq $true) { Add-Result 'FILE_SHARES' 'FileShares' 'MANUAL' 'Get-SmbShare is not available' -Recommendation 'List the shares manually (net share) and record their share permissions before the change.' -Kind 'Finding' -Source 'SmbShare module' }
        return
    }
    $printing = (Get-FeatureState 'Print-Server') -eq $true
    $shares = @(Get-SmbShare -ErrorAction Stop | Where-Object { -not $_.Special -and ($printing -or $_.Name -ne 'print$') } | Sort-Object Name)
    if ($shares.Count -eq 0) {
        $note = 'No shares besides the default administrative shares'
        if ($role -eq $true) { Add-Result 'FILE_SHARES' 'FileShares' 'INFO' $note 'The File Server role is installed but shares nothing.' -Source 'Get-SmbShare' }
        else { Add-Result 'FILE_SHARES' 'FileShares' 'INFO' $note -Source 'Get-SmbShare' }
        return
    }
    Add-Result 'FILE_SHARES' 'FileShares' 'WARNING' ('Count=' + $shares.Count) (@($shares | ForEach-Object { $_.Name }) -join ', ') -Recommendation 'Shared folders must be reachable again right after the upgrade. Test access from a client with the share owners, and keep this list (with permissions) for the comparison afterwards.' -Source 'Get-SmbShare'
    foreach ($sh in $shares) {
        Add-RedactionLiteral ([string]$sh.Name) 'NAME'
        if ($sh.Description) { Add-RedactionLiteral ([string]$sh.Description) 'NAME' }
        $access = @()
        if (Test-CommandAvailable 'Get-SmbShareAccess') {
            try {
                $access = @(Get-SmbShareAccess -Name $sh.Name -ErrorAction Stop | ForEach-Object { [string]$_.AccountName + ': ' + [string]$_.AccessRight + $(if ([string]$_.AccessControlType -eq 'Deny') { ' (Deny)' } else { '' }) })
            } catch { Write-Swallowed $_ }
        }
        $details = @(('Path=' + $sh.Path))
        if ($sh.Description) { $details += ('Description=' + $sh.Description) }
        $details += ('Share permissions: ' + $(if ($access.Count) { $access -join '; ' } else { 'not readable' }))
        Add-Result 'FILE_SHARES' ('Share: ' + $sh.Name) 'INFO' ([string]$sh.Path) $details -Source 'Get-SmbShare, Get-SmbShareAccess'
    }
    if ($script:Data.Snapshot) { $script:Data.Snapshot.Shares = @($shares | ForEach-Object { [string]$_.Name }) }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'printers' -Name 'Print server: printers, ports and drivers' -Script {
    # #148: what a print server holds, so it can be checked after the
    # upgrade and the driver work planned. Read-only.
    $role = (Get-FeatureState 'Print-Server') -eq $true
    $script:Data.PrintServer = $false
    try { $inv = Get-PrinterInventory }
    catch {
        $spooler = @($script:Data.Services | Where-Object { $_.Name -eq 'Spooler' }) | Select-Object -First 1
        $startMode = ''; if ($spooler) { $startMode = [string]$spooler.StartMode }
        if ((Get-PrinterReadFailureDecision $role $startMode ($null -ne $spooler)) -eq 'Manual') {
            Add-Result 'PRINTING' 'Printers' 'MANUAL' 'Could not read the printers' $_.Exception.Message -Recommendation 'Check that the Print Spooler service runs, and list printers, ports and drivers in Print Management before the change.' -Kind 'Finding' -Source 'PrintManagement, Win32_Printer'
        } else {
            Add-Result 'PRINTING' 'PrintServer' 'OK' 'Not a print server' 'Print Server role not installed and the Print Spooler service is disabled or missing' -Source 'Win32_Service'
        }
        return
    }
    $printers = @($inv.Printers | Where-Object { $_ -and [string]$_.DriverName -notmatch $script:VirtualPrinterDrivers } | Sort-Object Name)
    $shared = @($printers | Where-Object { $_.Shared })
    if (-not $role -and $shared.Count -eq 0) {
        Add-Result 'PRINTING' 'PrintServer' 'OK' 'Not a print server' ('Print Server role not installed, shared printers=0, local printers=' + $printers.Count) -Source $inv.Source
        return
    }
    $script:Data.PrintServer = $true
    $target = Get-ReleaseDisplayName $TargetServerVersion
    Add-Result 'PRINTING' 'Printers' 'WARNING' ('Count=' + $printers.Count + ', shared=' + $shared.Count) ('Print Server role=' + $role) -Recommendation 'Keep the PrintBrm backup and this list. After the upgrade, print a test page on each shared printer and test from a client; the post-upgrade run reports printers and ports that are gone.' -Source $inv.Source
    foreach ($p in $printers) { Add-RedactionLiteral $p.Name 'NAME'; if ($p.ShareName) { Add-RedactionLiteral $p.ShareName 'NAME' } }
    foreach ($p in $printers) {
        $details = @(('Share=' + $(if ($p.Shared -and $p.ShareName) { $p.ShareName } else { '(not shared)' })), ('Published in AD=' + $p.Published))
        Add-Result 'PRINTING' ('Printer: ' + $p.Name) 'INFO' ('Driver=' + $p.DriverName + '; Port=' + $p.PortName) $details -Source $inv.Source
    }

    # Ports in use by a printer, and every LPR port.
    $usedNames = @($printers | ForEach-Object { @(([string]$_.PortName) -split ',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $ports = @($inv.Ports | Where-Object { $_ -and ($usedNames -contains [string]$_.Name -or (Get-PrinterPortKind $_.Description $_.Monitor $_.Protocol) -eq 'LPR port monitor') } | Sort-Object Name)
    foreach ($pt in $ports) { Add-RedactionLiteral $pt.Name 'NAME'; if ($pt.Address -and $pt.Address -notmatch '^[0-9.:]+$') { Add-RedactionLiteral $pt.Address 'HOST' } }
    foreach ($pt in $ports) {
        $kind = Get-PrinterPortKind $pt.Description $pt.Monitor $pt.Protocol
        $details = @()
        if ($pt.Address) { $details += ('Address=' + $pt.Address + $(if ($pt.PortNumber) { ':' + $pt.PortNumber } else { '' })) }
        if ($pt.Queue) { $details += ('Queue=' + $pt.Queue) }
        if ($pt.Monitor) { $details += ('Monitor=' + $pt.Monitor) }
        if ($kind -eq 'LPR port monitor') {
            Add-Result 'PRINTING' ('Port: ' + $pt.Name) 'WARNING' $kind $details -Recommendation 'Microsoft deprecated LPR/LPD and plans to remove it. Move the printer to a Standard TCP/IP port (RAW, or LPR protocol on the standard port) and test before the upgrade.' -Kind 'Observation' -Source 'Get-PrinterPort' -Link 'https://learn.microsoft.com/en-us/windows/whats-new/deprecated-features' -LinkTitle 'Deprecated Windows features'
        } else {
            Add-Result 'PRINTING' ('Port: ' + $pt.Name) 'INFO' $kind $details -Source 'Get-PrinterPort'
        }
    }
    if ((Get-FeatureState 'Print-LPD-Service') -eq $true) {
        Add-Result 'PRINTING' 'LPD Service' 'WARNING' 'Installed' 'UNIX and other clients can print to this server over LPD.' -Recommendation 'Microsoft deprecated LPR/LPD and plans to remove it. Find the clients that use it and move them to IPP or a Standard TCP/IP port.' -Kind 'Observation' -Source 'Get-WindowsFeature' -Link 'https://learn.microsoft.com/en-us/windows/whats-new/deprecated-features' -LinkTitle 'Deprecated Windows features'
    }

    # Drivers.
    foreach ($r in @(Get-PrinterDriverDecision $inv.Drivers $target $TargetServerVersion)) {
        if ($r.Item -eq 'PrinterDrivers' -and $r.Status -eq 'WARNING') { Add-Result 'PRINTING' $r.Item $r.Status $r.Value $r.Details -Recommendation $r.Recommendation -Source $inv.Source -Link $script:PrinterDriverDocUrl -LinkTitle 'End of servicing plan for third-party printer drivers' }
        else { Add-Result 'PRINTING' $r.Item $r.Status $r.Value $r.Details -Recommendation $r.Recommendation -Source $inv.Source }
    }

    # Port monitors and print processors.
    try {
        foreach ($r in @(Get-PrintComponentDecision (Get-PrintMonitorInventory) $target)) {
            Add-Result 'PRINTING' $r.Item $r.Status $r.Value $r.Details -Recommendation $r.Recommendation -Source 'HKLM\SYSTEM\CurrentControlSet\Control\Print'
        }
    } catch {
        Add-Result 'PRINTING' 'PrintComponents' 'MANUAL' 'Could not read the port monitors and print processors' $_.Exception.Message -Recommendation 'Check Print Management > Print Servers > Ports and the registry key HKLM\SYSTEM\CurrentControlSet\Control\Print\Monitors for monitors that are not from Microsoft.' -Kind 'Finding' -Source 'HKLM\SYSTEM\CurrentControlSet\Control\Print'
    }

    if ($script:Data.Snapshot) {
        $script:Data.Snapshot.Printers = @($printers | ForEach-Object { [string]$_.Name })
        $script:Data.Snapshot.PrinterPorts = @($ports | ForEach-Object { [string]$_.Name })
        $script:Data.Snapshot.PrinterDrivers = @($printers | ForEach-Object { [pscustomobject]@{ Printer = [string]$_.Name; Driver = [string]$_.DriverName } })
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'iis' -Name 'IIS' -Script {
    $iisState = Get-FeatureState 'Web-Server'
    if ($null -eq $iisState) { Add-Result 'IIS' 'Web-Server' 'MANUAL' 'Feature state unknown: the role inventory failed' -Recommendation 'Check by hand whether IIS is installed (Get-WindowsFeature Web-Server, or the W3SVC service).' -Source 'Get-WindowsFeature'; return }
    if ($iisState -ne $true) { Add-Result 'IIS' 'Web-Server' 'OK' 'Not installed' -Source 'Get-WindowsFeature'; return }
    Add-Result 'IIS' 'Web-Server' 'WARNING' 'Installed' -Recommendation 'Immediately before the IPU, run the appcmd.exe add backup command shown (the copy in this report is from assessment time), and keep site, binding and certificate documentation.' -Source 'Get-WindowsFeature' -Command (Get-RecommendationCommand 'IisBackup').Command -CommandKind 'Change' -Link $script:DocLinks.AppCmd.Url -LinkTitle $script:DocLinks.AppCmd.Title
    if ($EnableIISConfigEvidence) {
        try {
            $dest = Join-Path (Initialize-EvidenceFolder 'IIS') ($script:SafeComputerName + '-IPU-IIS-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
            $copy = Save-IISConfigEvidence -Destination $dest -Zip $CreatePolicyEvidenceZip
            $script:Data.IISConfigEvidence = $copy.Location
            Add-Result 'IIS' 'ConfigurationCopy' 'OK' $copy.Location @(('Files=' + ($copy.Files -join ', ')), ('applicationHost.config SHA256=' + $copy.ApplicationHostSha256)) -Recommendation 'Restore: copy the files back to %windir%\System32\inetsrv\config, or put them in a folder under inetsrv\backup and run "appcmd restore backup <folder>". See the user guide.' -Source 'inetsrv\config (copied, not changed)'
            if ($copy.SharedConfigPath) {
                Add-Result 'IIS' 'SharedConfiguration' 'WARNING' ('Enabled: ' + $copy.SharedConfigPath) 'The local files only point to the shared location.' -Recommendation 'Back up the shared configuration at that path as well, and confirm every server that uses it before the change.' -Kind 'Observation' -Source 'redirection.config'
            }
        } catch {
            Add-Result 'IIS' 'ConfigurationCopy' 'MANUAL' 'Could not copy the IIS configuration' $_.Exception.Message -Recommendation 'Back up the IIS configuration manually before the change: appcmd add backup PreIPU, or copy %windir%\System32\inetsrv\config.' -Kind 'Finding' -Source 'inetsrv\config'
        }
    } else {
        Add-Result 'IIS' 'ConfigurationCopy' 'INFO' 'Not taken (EnableIISConfigEvidence is off)' -Source 'SETTINGS'
    }
    $iisManual = 'List the sites and bindings by hand (appcmd list site, or IIS Manager) before the change.'
    if (-not (Get-Module -ListAvailable WebAdministration)) {
        Add-Result 'IIS' 'Sites' 'MANUAL' 'Sites and bindings not listed (WebAdministration module missing)' -Recommendation $iisManual -Kind 'Finding' -Source 'WebAdministration'
        return
    }
    $sites = @()
    try { Import-Module WebAdministration -ErrorAction Stop; $sites = @(Get-Website -ErrorAction Stop) }
    catch {
        Write-Swallowed $_
        Add-Result 'IIS' 'Sites' 'MANUAL' 'Sites and bindings could not be read' $_.Exception.Message -Recommendation $iisManual -Kind 'Finding' -Source 'WebAdministration'
        return
    }
    foreach ($site in $sites) {
        $bindings = @($site.Bindings.Collection | ForEach-Object { $_.protocol + ':' + $_.bindingInformation }) -join ' | '
        Add-Result 'IIS' ('Site: ' + $site.Name) 'INFO' ('State=' + $site.State) @(('Path=' + $site.PhysicalPath),('Bindings=' + $bindings)) -Source 'WebAdministration'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'rds' -Name 'Remote Desktop Services roles' -Script {
    $rdsh = Get-FeatureState 'RDS-RD-Server'
    $rdlic = Get-FeatureState 'RDS-Licensing'
    if ($null -eq $rdsh -or $null -eq $rdlic) { Add-Result 'RDS' 'RDSRoles' 'MANUAL' 'Feature state unknown: the role inventory failed' -Recommendation 'Check by hand whether the Remote Desktop Session Host and Licensing roles are installed (Get-WindowsFeature RDS-*).' -Source 'Get-WindowsFeature'; return }
    if ($rdsh -eq $true) { Add-Result 'RDS' 'RDSessionHost' 'ACTION' 'Installed' -Recommendation ('Plan a longer IPU window, record the licensing configuration, and confirm RDS CALs are valid for ' + (Get-ReleaseDisplayName $TargetServerVersion) + ' (CALs must be the same or newer release as the server).') -Source 'Get-WindowsFeature' }
    else { Add-Result 'RDS' 'RDSessionHost' 'OK' 'Not installed' -Source 'Get-WindowsFeature' }
    if ($rdlic -eq $true) { Add-Result 'RDS' 'RDLicensingServer' 'ACTION' 'Installed' -Recommendation 'This is an RD Licensing server. Upgrading it affects every RDS host that uses it; confirm installed CALs and the order of upgrades with the RDS owner.' -Source 'Get-WindowsFeature' }
    if ($rdsh -eq $true -or $rdlic -eq $true) {
        $ts = @(Get-CimSafe 'Win32_TerminalServiceSetting' '' 'root\cimv2\TerminalServices') | Select-Object -First 1
        if ($ts) {
            $mode = @{ 2='PerDevice'; 4='PerUser'; 5='NotConfigured' }[[int]$ts.LicensingType]
            $servers = @()
            try { $servers = @((Invoke-CimMethod -InputObject $ts -MethodName GetSpecifiedLicenseServerList -ErrorAction Stop).SpecifiedLSList) } catch { Write-Swallowed $_ }
            Add-Result 'RDS' 'LicensingConfiguration' 'INFO' ('Mode=' + $mode) ('LicenseServers=' + ($servers -join ',')) -Source 'Win32_TerminalServiceSetting'
        }
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'pki' -Name 'PKI, certificates and TLS bindings' -Script {
    $adcs = @()
    foreach ($f in @('ADCS-Cert-Authority','ADCS-Web-Enrollment','ADCS-Enroll-Web-Pol','ADCS-Enroll-Web-Svc','ADCS-Device-Enrollment','ADCS-Online-Cert')) {
        if ((Get-FeatureState $f) -eq $true) { $adcs += $f }
    }
    $certSvc = @($script:Data.Services | Where-Object { $_.Name -eq 'CertSvc' }) | Select-Object -First 1
    if ($adcs -contains 'ADCS-Cert-Authority' -or $certSvc) {
        Add-Result 'PKI' 'CertificationAuthority' 'ACTION' 'Certification Authority detected' $adcs -Recommendation 'Engage the PKI team: verify CA database and private-key backup, AIA/CDP dependencies, and a tested recovery procedure before IPU.' -Source 'Get-WindowsFeature, CertSvc'
        $active = (Get-RegistryValueSafe 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' 'Active').Value
        if ($active) {
            $ca = $null
            try { $ca = Get-ItemProperty ('HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\' + $active) -ErrorAction Stop } catch { Write-Swallowed $_ }
            $type = ''; if ($ca) { $type = Get-CaTypeName $ca.CAType }
            if ($type) {
                Add-Result 'PKI' ('CA: ' + $active) 'INFO' ('Type=' + $type) @(('DB=' + $ca.DBDirectory),('Log=' + $ca.DBLogDirectory)) -Source 'CertSvc configuration'
            } else {
                # An unreadable configuration must not look like an enterprise root CA (#242).
                Add-Result 'PKI' ('CA: ' + $active) 'MANUAL' 'The CA configuration or its type could not be read' -Recommendation 'Check the CA type, database and log folders by hand (certutil -getreg CA) before the change.' -Kind 'Finding' -Source 'CertSvc configuration'
            }
        }
    } elseif ($adcs.Count -gt 0) {
        Add-Result 'PKI' 'ADCSRoleServices' 'ACTION' ($adcs -join ', ') -Recommendation 'Engage the PKI team and confirm configuration/recovery requirements before IPU.' -Source 'Get-WindowsFeature'
    }

    # Certificate index across the stores that services bind from.
    $index = @{}
    foreach ($store in @('My','Remote Desktop','WebHosting')) {
        # SilentlyContinue: the WebHosting and Remote Desktop stores do not exist until used; a missing store is empty.
        foreach ($cert in @(Get-ChildItem ('Cert:\LocalMachine\' + $store) -ErrorAction SilentlyContinue)) {
            $thumb = ConvertTo-NormalizedThumbprint $cert.Thumbprint
            if ($index.ContainsKey($thumb)) { continue }
            $index[$thumb] = [pscustomobject]@{ Cert=$cert; Store=$store }
            $days = [math]::Floor(($cert.NotAfter - (Get-Date)).TotalDays)
            Add-Result 'CERTIFICATES' $thumb 'INFO' ('Subject=' + $cert.Subject) @(('Store=' + $store),('Issuer=' + $cert.Issuer),('NotAfter=' + $cert.NotAfter.ToString('yyyy-MM-dd')),('HasPrivateKey=' + $cert.HasPrivateKey)) -Source ('Cert:\LocalMachine\' + $store)
            if ($days -lt 0) {
                Add-Result 'CERTIFICATES' ('Expired: ' + $thumb) 'WARNING' ('ExpiredDaysAgo=' + [math]::Abs($days)) ('Subject=' + $cert.Subject) -Recommendation 'Determine whether it is still bound; renew/remove through the owning team.' -Kind 'Observation' -Source ('Cert:\LocalMachine\' + $store)
            } elseif ($days -le $CertificateWarningDays) {
                Add-Result 'CERTIFICATES' ('Expiring: ' + $thumb) 'WARNING' ('ExpiresInDays=' + $days) ('Subject=' + $cert.Subject) -Recommendation 'Confirm ownership and renewal plan. Bound certificates are evaluated separately below.' -Kind 'Observation' -Source ('Cert:\LocalMachine\' + $store)
            }
        }
    }

    # IIS HTTPS bindings.
    $httpsBindings = @()
    if ((Get-FeatureState 'Web-Server') -eq $true) {
        $bindingsManual = 'Check the HTTPS bindings and their certificates by hand (IIS Manager, or netsh http show sslcert) before the change.'
        if (-not (Get-Module -ListAvailable WebAdministration)) {
            Add-Result 'CERTIFICATES' 'IIS https bindings' 'MANUAL' 'HTTPS bindings not listed (WebAdministration module missing)' -Recommendation $bindingsManual -Kind 'Finding' -Source 'WebAdministration'
        } else {
            try { Import-Module WebAdministration -ErrorAction Stop; $httpsBindings = @(Get-WebBinding -Protocol https -ErrorAction Stop) }
            catch {
                if (-not (Test-NotFoundError $_)) {
                    Write-Swallowed $_
                    Add-Result 'CERTIFICATES' 'IIS https bindings' 'MANUAL' 'HTTPS bindings could not be read' $_.Exception.Message -Recommendation $bindingsManual -Kind 'Finding' -Source 'Get-WebBinding'
                }
            }
        }
    }
    if ($httpsBindings.Count -gt 0) {
        foreach ($b in $httpsBindings) {
            $thumb = ConvertTo-NormalizedThumbprint $b.certificateHash
            $entry = $null
            if ($thumb -and $index.ContainsKey($thumb)) { $entry = $index[$thumb] }
            $item = 'IIS https ' + $b.bindingInformation
            if (-not $thumb) {
                Add-Result 'CERTIFICATES' $item 'MANUAL' 'No certificate hash on binding (possibly Centralized Certificate Store)' ('Store=' + $b.certificateStoreName) -Recommendation 'Verify the binding certificate manually.' -Source 'Get-WebBinding'
            } elseif (-not $entry) {
                Add-Result 'CERTIFICATES' $item 'ACTION' ('Thumbprint=' + $thumb) ('BindingStore=' + $b.certificateStoreName) -Recommendation 'The bound certificate is not in My, WebHosting or Remote Desktop. Fix the binding before IPU.' -Source 'Get-WebBinding'
            } else {
                $days = [math]::Floor(($entry.Cert.NotAfter - (Get-Date)).TotalDays)
                $details = @(('Subject=' + $entry.Cert.Subject),('Store=' + $entry.Store),('DaysLeft=' + $days))
                if ($days -lt 0) { Add-Result 'CERTIFICATES' $item 'ACTION' ('Thumbprint=' + $thumb) $details -Recommendation 'IIS binding uses an expired certificate. Resolve with the application owner before IPU.' -Source 'Get-WebBinding' }
                elseif ($days -le $CertificateWarningDays) { Add-Result 'CERTIFICATES' $item 'WARNING' ('Thumbprint=' + $thumb) $details -Recommendation 'Renew soon and verify the binding after IPU.' -Source 'Get-WebBinding' }
                else { Add-Result 'CERTIFICATES' $item 'OK' ('Thumbprint=' + $thumb) $details -Source 'Get-WebBinding' }
            }
        }
    }

    # RDP listener certificate.
    $rdp = @(Get-CimSafe 'Win32_TSGeneralSetting' "TerminalName='RDP-tcp'" 'root\cimv2\TerminalServices') | Select-Object -First 1
    if ($rdp) {
        $thumb = ConvertTo-NormalizedThumbprint $rdp.SSLCertificateSHA1Hash
        if ($thumb -and $index.ContainsKey($thumb)) {
            $c = $index[$thumb].Cert
            $st = 'OK'; if ($c.NotAfter -lt (Get-Date)) { $st = 'WARNING' }
            Add-Result 'CERTIFICATES' 'RDP-Tcp certificate' $st ('Thumbprint=' + $thumb) @(('Subject=' + $c.Subject),('NotAfter=' + $c.NotAfter.ToString('yyyy-MM-dd'))) -Recommendation 'Verify RDP connects after IPU.' -Kind 'Observation' -Source 'Win32_TSGeneralSetting'
        } elseif ($thumb) {
            Add-Result 'CERTIFICATES' 'RDP-Tcp certificate' 'MANUAL' ('Thumbprint=' + $thumb) 'Not found in My, Remote Desktop or WebHosting' -Recommendation 'Verify the RDP certificate configuration.' -Kind 'Finding' -Source 'Win32_TSGeneralSetting'
        }
    }

    # WinRM HTTPS listeners.
    foreach ($listener in @(Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue)) {
        $keys = @{}; foreach ($k in $listener.Keys) { if ($k -match '^(\w+)=(.*)$') { $keys[$matches[1]] = $matches[2] } }
        if ($keys['Transport'] -eq 'HTTPS') {
            $thumb = ''
            try { $thumb = ConvertTo-NormalizedThumbprint (Get-Item (Join-Path $listener.PSPath 'CertificateThumbprint') -ErrorAction Stop).Value } catch { Write-Swallowed $_ }
            Add-Result 'CERTIFICATES' ('WinRM HTTPS ' + $keys['Address']) 'INFO' ('Thumbprint=' + $thumb) -Recommendation 'Confirm WinRM HTTPS still works after IPU if it is used for management.' -Source 'WSMan:\localhost\Listener'
        }
    }

    # HTTP.sys SSL bindings - preserved verbatim as evidence.
    $netsh = Invoke-NativeCapture (Join-Path $env:windir 'System32\netsh.exe') @('http','show','sslcert') 60
    $block = @(); $n = 0
    foreach ($line in @($netsh.Output -split '\r?\n') + @('')) {
        if ($line.Trim()) { $block += $line.Trim() }
        elseif ($block.Count -gt 0) {
            if (Test-HttpSysBindingBlock $block) { $n++; Add-Result 'CERTIFICATES' ('HTTP.sys binding ' + $n) 'INFO' ($block -join ' | ') -Source 'netsh http show sslcert' }
            $block = @()
        }
        else { $block = @() }
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'agents' -Name 'Management agents (OpenText)' -Script {
    $matches_ = Find-DetectionMatch $script:DetectionPatterns.Agents $script:Data.Apps $script:Data.Services
    foreach ($pattern in $script:DetectionPatterns.Agents) {
        $m = @($matches_ | Where-Object { $_.Label -eq $pattern.Label }) | Select-Object -First 1
        if (-not $m) {
            Add-Result 'AGENTS' $pattern.Label 'MANUAL' 'Not identified' '' -Recommendation 'Confirm in the backend whether this agent is expected on this server. If it is installed under another name, add the name to the detection patterns.' -Kind 'Observation' -Source 'Uninstall registry, Win32_Service'
            continue
        }
        foreach ($app in $m.Apps) { Add-Result 'AGENTS' $pattern.Label 'INFO' $app.Name ('Version=' + $app.Version) -Source 'Uninstall registry' }
        foreach ($svc in $m.Services) {
            $st = 'OK'; if ($svc.State -ne 'Running') { $st = 'WARNING' }
            Add-Result 'AGENTS' ($pattern.Label + ' service') $st $svc.DisplayName @(('State=' + $svc.State),('StartMode=' + $svc.StartMode)) -Recommendation 'A stopped agent will not report after IPU either; investigate before the change.' -Kind 'Observation' -Source 'Win32_Service'
        }
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'antivirus' -Name 'Antivirus, EDR and security tools' -Script {
    $target = Get-ReleaseDisplayName $TargetServerVersion
    $protected = $false

    # Microsoft Defender Antivirus. Record WHY its state could not be read
    # instead of silently treating it as absent.
    $defenderService = @($script:Data.Services | Where-Object { $_.Name -eq 'WinDefend' }) | Select-Object -First 1
    if (-not $defenderService) {
        Add-Result 'ANTIVIRUS' 'Microsoft Defender Antivirus' 'INFO' 'Not installed (WinDefend service absent)' -Source 'Win32_Service'
    } elseif (-not (Test-CommandAvailable 'Get-MpComputerStatus')) {
        Add-Result 'ANTIVIRUS' 'Microsoft Defender Antivirus' 'INFO' ('Service ' + $defenderService.State + '; status cmdlet not available on this OS') -Source 'Win32_Service'
    } else {
        try {
            $mp = Get-MpComputerStatus -ErrorAction Stop
            $age = $null
            if ($mp.AntivirusSignatureLastUpdated) { $age = [math]::Floor(((Get-Date) - $mp.AntivirusSignatureLastUpdated).TotalDays) }
            $mode = ''
            if ($mp.PSObject.Properties['AMRunningMode']) { $mode = ', Mode=' + $mp.AMRunningMode }
            $value = 'AVEnabled=' + $mp.AntivirusEnabled + ', RealTime=' + $mp.RealTimeProtectionEnabled + $mode
            if ($mp.AntivirusEnabled -and $mp.RealTimeProtectionEnabled) {
                $protected = $true
                if ($null -ne $age -and $age -le $AVMaxAgeDays) { Add-Result 'ANTIVIRUS' 'Microsoft Defender Antivirus' 'OK' $value ('SignatureAgeDays=' + $age) -Source 'Get-MpComputerStatus' }
                else { Add-Result 'ANTIVIRUS' 'Microsoft Defender Antivirus' 'WARNING' $value ('SignatureAgeDays=' + $age) -Recommendation 'Update Defender signatures before IPU.' -Source 'Get-MpComputerStatus' }
            } else {
                Add-Result 'ANTIVIRUS' 'Microsoft Defender Antivirus' 'INFO' $value 'Passive or disabled - expected when another product is primary.' -Source 'Get-MpComputerStatus'
            }
        } catch {
            Write-Swallowed $_
            Add-Result 'ANTIVIRUS' 'Microsoft Defender Antivirus' 'INFO' ('Service ' + $defenderService.State + ', ' + $defenderService.StartMode) ('Status not readable: ' + $_.Exception.Message) -Recommendation 'Usually means Defender is disabled because another product is primary.' -Source 'Get-MpComputerStatus'
        }
    }

    # Third-party AV/EDR by product name, service and driver.
    $epp = Find-DetectionMatch $script:DetectionPatterns.EndpointProtection $script:Data.Apps $script:Data.Services $script:Data.DriverNames
    $products = @()
    foreach ($m in $epp) {
        $running = @($m.Services | Where-Object { $_.State -eq 'Running' }).Count
        $val = 'Applications=' + @($m.Apps).Count + ', Services=' + @($m.Services).Count + ' (' + $running + ' running), Drivers=' + @($m.Drivers).Count
        if ($m.Label -like 'Microsoft Defender for Endpoint*') {
            $sense = @($m.Services | Where-Object { $_.Name -eq 'Sense' }) | Select-Object -First 1
            $senseState = 'absent'; if ($sense) { $senseState = [string]$sense.State }
            $onboarding = (Get-RegistryValueSafe 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status' 'OnboardingState').Value
            $d = Get-DefenderEndpointDecision $senseState $onboarding
            if (-not $d.Active) {
                Add-Result 'ANTIVIRUS' $m.Label 'INFO' $d.Text (Get-DetectionEvidence $m) -Source 'Win32_Service, Windows Advanced Threat Protection\Status'
                continue
            }
            $val = $d.Text
        }
        $protected = $true
        $products += (Get-DetectionProductName $m)
        Add-Result 'ANTIVIRUS' $m.Label 'WARNING' $val (Get-DetectionEvidence $m) -Recommendation ('Confirm this version supports ' + $target + ' and get the vendor''s IPU procedure. Many AV/EDR agents must be upgraded before, or paused during, Setup; their drivers are a common cause of rollback.') -Source 'Uninstall registry, Win32_Service, drivers' -Link $m.Link -LinkTitle $m.LinkTitle
    }
    $script:Data.EndpointProducts = $products
    if (-not $protected) {
        Add-Result 'ANTIVIRUS' 'EndpointProtection' 'MANUAL' 'No active antivirus or EDR recognised' '' -Recommendation 'Verify endpoint protection manually. If a product is installed under an unknown name, add it to the detection patterns.' -Source 'Get-MpComputerStatus, uninstall registry, services, drivers'
    }

    foreach ($m in (Find-DetectionMatch $script:DetectionPatterns.SecurityTools $script:Data.Apps $script:Data.Services $script:Data.DriverNames)) {
        $tool = Get-SecurityToolDecision @($m.Drivers) $target
        Add-Result 'SECURITY' $m.Label 'WARNING' ('Applications=' + @($m.Apps).Count + ', Services=' + @($m.Services).Count + ', Drivers=' + @($m.Drivers).Count) (Get-DetectionEvidence $m) -Recommendation $tool.Recommendation -Kind $tool.Kind -Source 'Uninstall registry, Win32_Service, drivers'
    }

    if (Test-CommandAvailable 'Get-AppLockerPolicy') {
        try {
            $policy = Get-AppLockerPolicy -Effective -ErrorAction Stop
            $count = 0; foreach ($c in $policy.RuleCollections) { $count += [int]$c.Count }
            if ($count -gt 0) { Add-Result 'SECURITY' 'AppLocker' 'WARNING' ('EffectiveRules=' + $count) '' -Recommendation 'Confirm Windows Setup ($WINDOWS.~BT) and post-upgrade binaries are allowed.' -Source 'Get-AppLockerPolicy' }
            else { Add-Result 'SECURITY' 'AppLocker' 'INFO' 'No effective rules' -Source 'Get-AppLockerPolicy' }
        } catch { Write-Swallowed $_; Add-Result 'SECURITY' 'AppLocker' 'MANUAL' 'The effective AppLocker policy could not be read' $_.Exception.Message -Recommendation 'Check Local Security Policy > Application Control Policies by hand: Setup and the new binaries must be allowed.' -Kind 'Finding' -Source 'Get-AppLockerPolicy' }
    }
    if (Test-CommandAvailable 'Get-BitLockerVolume') {
        try {
            $bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
            if ([string]$bl.ProtectionStatus -eq 'On') { Add-Result 'SECURITY' 'BitLocker C:' 'WARNING' ('Protection=On, Method=' + $bl.EncryptionMethod) '' -Recommendation 'Confirm the recovery key is escrowed and retrievable before IPU.' -Source 'Get-BitLockerVolume' }
            else { Add-Result 'SECURITY' 'BitLocker C:' 'INFO' ('Protection=' + $bl.ProtectionStatus) -Source 'Get-BitLockerVolume' }
        } catch { Write-Swallowed $_; Add-Result 'SECURITY' 'BitLocker C:' 'MANUAL' 'The BitLocker state of C: could not be read' $_.Exception.Message -Recommendation 'Run manage-bde -status C: by hand; confirm the recovery key is escrowed if protection is on.' -Kind 'Finding' -Source 'Get-BitLockerVolume' }
    }
    if (Test-CommandAvailable 'Confirm-SecureBootUEFI') {
        try { Add-Result 'SECURITY' 'SecureBoot' 'INFO' ('Enabled=' + (Confirm-SecureBootUEFI -ErrorAction Stop)) -Source 'Confirm-SecureBootUEFI' }
        catch {
            $sb = Get-SecureBootDecision $_.Exception.GetType().Name $_.Exception.Message
            if ($sb.Kind -eq 'LegacyBios') { Add-Result 'SECURITY' 'SecureBoot' $sb.Status $sb.Value -Source 'Confirm-SecureBootUEFI' }
            else { Write-Swallowed $_; Add-Result 'SECURITY' 'SecureBoot' $sb.Status $sb.Value $_.Exception.Message -Recommendation 'Run Confirm-SecureBootUEFI in an elevated session by hand.' -Kind 'Finding' -Source 'Confirm-SecureBootUEFI' }
        }
    }
    if (Test-CommandAvailable 'Get-Tpm') {
        try { $tpm = Get-Tpm -ErrorAction Stop; Add-Result 'SECURITY' 'TPM' 'INFO' ('Present=' + $tpm.TpmPresent) ('Ready=' + $tpm.TpmReady) -Source 'Get-Tpm' } catch { Write-Swallowed $_; Add-Result 'SECURITY' 'TPM' 'MANUAL' 'The TPM state could not be read' $_.Exception.Message -Recommendation 'Run Get-Tpm (or tpm.msc) by hand.' -Kind 'Finding' -Source 'Get-Tpm' }
    }
    if (@($script:Data.FilterDrivers).Count -gt 0) {
        Add-Result 'SECURITY' 'FileSystemFilterDrivers' 'INFO' ('Count=' + @($script:Data.FilterDrivers).Count) (@($script:Data.FilterDrivers) -join ', ') -Recommendation 'If a previous IPU failed with 0xC1900101 (driver), review the non-Microsoft filter drivers.' -Source 'fltmc filters'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'backup' -Name 'Backup and VSS' -Script {
    $backup = Find-DetectionMatch $script:DetectionPatterns.Backup $script:Data.Apps $script:Data.Services
    foreach ($m in $backup) {
        Add-Result 'BACKUP' $m.Label 'INFO' ('Applications=' + @($m.Apps).Count + ', Services=' + @($m.Services).Count) (Get-DetectionEvidence $m) -Source 'Uninstall registry, Win32_Service'
    }
    if ($backup.Count -eq 0) {
        Add-Result 'BACKUP' 'GuestBackupAgent' 'INFO' 'No recognized in-guest backup agent' 'VM-level backup is invisible from inside the guest; this does not mean the server is unprotected.' -Source 'Uninstall registry, Win32_Service'
    }

    $vss = Invoke-NativeCapture (Join-Path $env:windir 'System32\vssadmin.exe') @('list','writers') 120
    $writers = ConvertFrom-VssWriterOutput $vss.Lines
    if ($vss.TimedOut -or $writers.Count -eq 0) {
        Add-Result 'BACKUP' 'VSSWriters' 'MANUAL' 'VSS writer state could not be read' @(('TimedOut=' + $vss.TimedOut),$vss.Error) -Recommendation 'Run "vssadmin list writers" manually; failed writers break application-consistent backups and snapshots.' -Kind 'Finding' -Source 'vssadmin list writers'
    }
    $failed = 0
    foreach ($w in $writers) {
        $st = Get-VssWriterStatus $w
        if ($st -eq 'ACTION') { $failed++ }
        Add-Result 'BACKUP' ('VSS writer: ' + $w.Name) $st ('[' + $w.StateCode + '] ' + $w.StateText) $w.LastError -Kind 'Evidence' -Source 'vssadmin list writers'
    }
    if ($failed -gt 0) {
        Add-Result 'BACKUP' 'VSSWriters' 'ACTION' ('FailedWriters=' + $failed) -Recommendation 'Resolve VSS writer errors (often fixed by restarting the owning service) so the pre-change backup/snapshot is application-consistent.' -Source 'vssadmin list writers'
    }
    foreach ($prov in @(Get-CimSafe 'Win32_ShadowProvider')) {
        $st = 'OK'; $rec = ''
        if ($prov.Name -notmatch '^Microsoft (Software|File Share) Shadow Copy provider') { $st = 'WARNING'; $rec = 'Third-party VSS provider: confirm it supports the target OS.' }
        Add-Result 'BACKUP' ('VSS provider: ' + $prov.Name) $st ('Version=' + $prov.Version) -Recommendation $rec -Kind 'Observation' -Source 'Win32_ShadowProvider'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'services' -Name 'Services' -Script {
    $auto = @($script:Data.Services | Where-Object { $_.StartMode -eq 'Auto' })
    $autoStopped = @($auto | Where-Object { $_.State -ne 'Running' })
    Add-Result 'SERVICES' 'AutomaticServices' 'INFO' ('Total=' + $auto.Count) ('NotRunning=' + $autoStopped.Count) -Recommendation 'Save this list. After IPU, compare which Automatic services are running to spot what did not come back.' -Source 'Win32_Service'
    foreach ($s in @($script:Data.Services | Where-Object { $_.StartName })) { Add-RedactionLiteral ([string]$s.StartName) 'ACCOUNT' }
    foreach ($s in @($script:Data.Services | Where-Object { $_.StartMode -in @('Auto','Manual') } | Sort-Object StartMode,DisplayName)) {
        Add-Result 'SERVICES' $s.Name 'INFO' $s.DisplayName @(('State=' + $s.State),('StartMode=' + $s.StartMode),('LogOnAs=' + $s.StartName)) -Source 'Win32_Service'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'vmware' -Name 'VMware guest readiness' -Script {
    if ($script:Data.Platform.Hypervisor -ne 'VMware') {
        Add-Result 'VMWARE' 'Applicability' 'INFO' ('Not a VMware VM (' + $script:Data.Platform.Type + ')') -Source 'Platform classification'
        return
    }
    $tools = @($script:Data.Apps | Where-Object { $_.Name -eq 'VMware Tools' }) | Select-Object -First 1
    $version = ''
    if ($tools) { $version = [string]$tools.Version }
    else {
        $exe = Join-Path $env:ProgramFiles 'VMware\VMware Tools\vmtoolsd.exe'
        if (Test-Path -LiteralPath $exe) { $version = [string](Get-Item -LiteralPath $exe).VersionInfo.ProductVersion }
    }
    $decision = Get-VMwareToolsDecision $version $TargetServerVersion
    $toolsSvc = @($script:Data.Services | Where-Object { $_.Name -eq 'VMTools' }) | Select-Object -First 1
    $svcText = 'VMTools service not found'
    if ($toolsSvc) { $svcText = 'VMTools service ' + $toolsSvc.State + ', ' + $toolsSvc.StartMode }
    Add-Result 'VMWARE' 'VMwareTools' $decision.Status ('Version=' + $version) $svcText -Recommendation $decision.Text -Source 'Uninstall registry / vmtoolsd.exe'

    $firmware = 'BIOS'
    if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State') { $firmware = 'EFI' }
    Add-Result 'VMWARE' 'VMFirmware' 'INFO' $firmware ('BIOS version=' + $script:Data.BIOS.SMBIOSBIOSVersion) -Recommendation 'BIOS-firmware VMs upgrade in place; Secure Boot and vTPM need EFI firmware.' -Source 'SecureBoot registry, Win32_BIOS'

    foreach ($drv in @($script:Data.KernelDrivers | Where-Object { $_.Name -match '^(pvscsi|vmxnet3|vmxnet3ndis6|vsepflt|vnetflt|vnetWFP|vmci|vsock|vm3dmp|vmmemctl|vmhgfs|vmrawdsk|vmusbmouse|vmmouse|glxgi)' } | Sort-Object Name)) {
        $fileVersion = ''
        $path = ([string]$drv.PathName -replace '^\\\?\?\\','' -replace '^\\SystemRoot', $env:windir -replace '^(?i)system32', (Join-Path $env:windir 'System32'))
        try { if ($path -and (Test-Path -LiteralPath $path)) { $fileVersion = (Get-Item -LiteralPath $path).VersionInfo.FileVersion } } catch { Write-Swallowed $_ }
        Add-Result 'VMWARE' ('Driver: ' + $drv.Name) 'INFO' $drv.DisplayName ('FileVersion=' + $fileVersion) -Source 'Win32_SystemDriver'
    }

    $hostText = 'Confirm the ESXi host version supports ' + (Get-ReleaseDisplayName $TargetServerVersion) + ' guests (VMware Compatibility Guide).'
    if ($TargetServerVersion -eq '2025') { $hostText = 'Windows Server 2025 is certified on vSphere 7.0 U3 and 8.0.x. Confirm the host (and any vMotion/DRS target) runs one of these.' }
    Add-Result 'CHECKLIST' 'VMware host version' 'MANUAL' 'Not visible from inside the guest' '' -Recommendation $hostText -Kind 'Checklist'
    Add-Result 'CHECKLIST' 'VMware guest OS setting' 'MANUAL' 'After the upgrade' '' -Recommendation ('After IPU, power off the VM and change its Guest OS version to Microsoft Windows Server ' + $TargetServerVersion + ' (64-bit), as Broadcom''s IPU KB 374927 instructs.') -Kind 'Checklist'
    Add-Result 'VMWARE' 'BroadcomGuidance' 'INFO' 'Broadcom KB 374927' 'Broadcom recommends a new VM with a clean install over an in-place upgrade of the guest OS.' -Recommendation 'Company decision; listed so the choice to do an IPU is made knowingly.' -Kind 'Observation' -Source 'knowledge.broadcom.com/external/article/374927'
}

# ---------------------------------------------------------------------------
Register-Check -Id 'drivers' -Name 'Non-Microsoft drivers' -Script {
    $unsigned = @()
    $pnp = @(); $pnpError = ''
    try { $pnp = @(Get-CimRequired 'Win32_PnPSignedDriver' | Where-Object { $_.DeviceName -and $_.DriverProviderName -and $_.DriverProviderName -notmatch '^Microsoft' }) }
    catch {
        $pnpError = $_.Exception.Message; Write-Swallowed $_
        Add-Result 'DRIVERS' 'DeviceDrivers' 'MANUAL' 'The device driver list could not be read' $pnpError -Recommendation 'List the third-party drivers by hand (driverquery /v, or Device Manager) before the change; old drivers are the most common cause of IPU rollback.' -Kind 'Finding' -Source 'Win32_PnPSignedDriver'
    }
    foreach ($d in @($pnp | Sort-Object DeviceName,DriverVersion -Unique)) {
        $date = [string]$d.DriverDate
        $driverDate = ConvertTo-DateTimeValue $d.DriverDate
        if ($driverDate) { $date = $driverDate.ToString('yyyy-MM-dd') }
        Add-Result 'DRIVERS' ('Device: ' + $d.DeviceName) 'INFO' ('Provider=' + $d.DriverProviderName) @(('Version=' + $d.DriverVersion),('Date=' + $date),('Class=' + $d.DeviceClass),('Signed=' + $d.IsSigned)) -Source 'Win32_PnPSignedDriver'
        if ($d.IsSigned -eq $false) { $unsigned += $d.DeviceName }
    }
    $kernelCount = 0
    foreach ($drv in @($script:Data.KernelDrivers | Sort-Object Name)) {
        $path = ([string]$drv.PathName -replace '^\\\?\?\\','' -replace '^\\SystemRoot', $env:windir -replace '^(?i)system32', (Join-Path $env:windir 'System32'))
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }
        $info = $null
        try { $info = (Get-Item -LiteralPath $path).VersionInfo } catch { Write-Swallowed $_; continue }
        if ($info.CompanyName -and $info.CompanyName -notmatch 'Microsoft') {
            $kernelCount++
            Add-Result 'DRIVERS' ('Kernel driver: ' + $drv.Name) 'INFO' ('Company=' + $info.CompanyName) @(('FileVersion=' + $info.FileVersion),('Path=' + $path)) -Source 'Win32_SystemDriver'
        }
    }
    $devicesText = 'NonMicrosoftDevices=' + @($pnp | Sort-Object DeviceName -Unique).Count
    if ($pnpError) { $devicesText = 'NonMicrosoftDevices=unknown' }
    Add-Result 'DRIVERS' 'Summary' 'INFO' ($devicesText + ', NonMicrosoftKernelDrivers=' + $kernelCount) -Recommendation 'Old third-party drivers are the most common cause of IPU rollback (0xC1900101). Update them, especially storage, network and security drivers, before IPU.' -Source 'Win32_PnPSignedDriver, Win32_SystemDriver'
    if ($unsigned.Count -gt 0) {
        Add-Result 'DRIVERS' 'UnsignedDrivers' 'WARNING' ('Count=' + $unsigned.Count) ($unsigned -join ', ') -Recommendation 'Unsigned drivers may not load after the upgrade. Replace them with signed versions before IPU.' -Source 'Win32_PnPSignedDriver'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'ports' -Name 'Listening ports' -Script {
    if (-not (Test-CommandAvailable 'Get-NetTCPConnection')) {
        $script:Data.Snapshot.Remove('Ports')
        Add-Result 'PORTS' 'ListeningPorts' 'MANUAL' 'Get-NetTCPConnection unavailable' -Recommendation 'List the listening ports by hand (netstat -ano) for the post-upgrade test plan.' -Kind 'Finding' -Source 'NetTCPIP'
        return
    }
    $procNames = @{}
    # SilentlyContinue: process names only label the owners; a process that ended meanwhile is normal.
    foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue)) { $procNames[[int]$proc.Id] = $proc.ProcessName }
    $svcByPid = @{}
    foreach ($svc in $script:Data.Services) {
        if ($svc.ProcessId -and [int]$svc.ProcessId -gt 0) {
            $key = [int]$svc.ProcessId
            if (-not $svcByPid.ContainsKey($key)) { $svcByPid[$key] = @() }
            $svcByPid[$key] += [string]$svc.Name
        }
    }
    $owners = @{}
    $endpoints = @()
    # A failed query stops the check (reported as not completed); only "nothing found" is an empty list (#242).
    $tcpListeners = @()
    try { $tcpListeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop) } catch { if (-not (Test-NotFoundError $_)) { throw } }
    foreach ($c in $tcpListeners) { $endpoints += [pscustomobject]@{ Key=('TCP:' + $c.LocalPort); Port=[int]$c.LocalPort; ProcessId=[int]$c.OwningProcess } }
    if (Test-CommandAvailable 'Get-NetUDPEndpoint') {
        $udpEndpoints = @()
        try { $udpEndpoints = @(Get-NetUDPEndpoint -ErrorAction Stop) } catch { if (-not (Test-NotFoundError $_)) { throw } }
        foreach ($u in $udpEndpoints) { $endpoints += [pscustomobject]@{ Key=('UDP:' + $u.LocalPort); Port=[int]$u.LocalPort; ProcessId=[int]$u.OwningProcess } }
    }
    # Ports from the Windows dynamic range (49152+) change between boots and
    # are left out so the before/after comparison stays meaningful.
    foreach ($ep in @($endpoints | Where-Object { $_.Port -lt 49152 })) {
        $owner = ''
        if ($svcByPid.ContainsKey($ep.ProcessId)) { $owner = 'Service ' + (@($svcByPid[$ep.ProcessId]) -join '/') }
        elseif ($procNames.ContainsKey($ep.ProcessId)) { $owner = 'Process ' + $procNames[$ep.ProcessId] }
        if (-not $owners.ContainsKey($ep.Key)) { $owners[$ep.Key] = @() }
        if ($owner -and $owners[$ep.Key] -notcontains $owner) { $owners[$ep.Key] += $owner }
    }
    foreach ($k in @($owners.Keys | Sort-Object { [int](($_ -split ':')[1]) }, { $_ })) {
        Add-Result 'PORTS' $k 'INFO' (@($owners[$k]) -join ', ') -Source 'Get-NetTCPConnection, Get-NetUDPEndpoint'
    }
    $script:Data.Snapshot.Ports = @($owners.Keys | Sort-Object)
    # Who opened each port, so the comparison can pair a closed port with a
    # disabled service (#158).
    $po = [ordered]@{}; foreach ($k in @($owners.Keys | Sort-Object)) { $po[$k] = (@($owners[$k]) -join ', ') }
    $script:Data.Snapshot.PortOwners = $po
    Add-Result 'PORTS' 'Summary' 'INFO' ('ListeningPorts=' + $owners.Count) 'Use this list for the post-upgrade test plan. Dynamic ports (49152+) are not listed.' -Source 'Get-NetTCPConnection, Get-NetUDPEndpoint'
}

# ---------------------------------------------------------------------------
Register-Check -Id 'tasks' -Name 'Scheduled tasks' -Script {
    if (-not (Test-CommandAvailable 'Get-ScheduledTask')) {
        Add-Result 'TASKS' 'ScheduledTasks' 'INFO' 'Get-ScheduledTask unavailable' -Source 'ScheduledTasks module'
        return
    }
    $builtIn = '^(SYSTEM|NT AUTHORITY\\.*|LOCAL SERVICE|NETWORK SERVICE|S-1-5-(18|19|20)|INTERACTIVE|Users|Administrators|BUILTIN\\.*|Everyone)$'
    $named = @(); $perUser = 0
    foreach ($t in @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } | Sort-Object TaskPath,TaskName)) {
        $user = [string]$t.Principal.UserId
        if (-not $user) { $user = [string]$t.Principal.GroupId }
        $actions = @($t.Actions | ForEach-Object { (([string]$_.Execute) + ' ' + ([string]$_.Arguments)).Trim() } | Where-Object { $_ }) -join '; '
        $fullName = $t.TaskPath + $t.TaskName
        if ($user -and $user -notmatch $builtIn) { Add-RedactionLiteral $user 'ACCOUNT' }
        $script:Data.Snapshot.Tasks += $fullName
        # Windows' own per-user feed tasks: one line for all of them (#214).
        if (Test-WindowsPerUserTask $fullName) { $perUser++; continue }
        Add-Result 'TASKS' $fullName 'INFO' ('RunAs=' + $user) @(('State=' + $t.State),('Action=' + $actions)) -Source 'Get-ScheduledTask'
        if ($user -and $user -notmatch $builtIn) { $named += ($fullName + ' (' + $user + ')') }
    }
    if ($perUser -gt 0) {
        Add-Result 'TASKS' 'WindowsPerUserTasks' 'INFO' ('Count=' + $perUser) 'User_Feed_Synchronization-{GUID}: created by Windows for each user who signed in; they run as that user.' -Recommendation 'Not relevant for the upgrade.' -Source 'Get-ScheduledTask'
    }
    if ($named.Count -gt 0) {
        Add-Result 'TASKS' 'TasksWithNamedAccounts' 'WARNING' ('Count=' + $named.Count) $named -Recommendation 'These tasks run as named accounts with stored credentials. Confirm the passwords are known/managed and test the tasks after IPU.' -Kind 'Observation' -Source 'Get-ScheduledTask'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'checklist' -Name 'Standard change checklist' -Script {
    $isVM = ($script:Data.Platform.Type -eq 'Virtual')
    $fallback = 'Confirm a tested bare-metal recovery path and a recent successful backup.'
    if ($isVM) { $fallback = 'Confirm a recent successful backup externally, snapshot eligibility (' + $script:Data.Platform.Hypervisor + ') and the approved snapshot procedure.' }
    Add-Result 'CHECKLIST' 'Backup and fallback' 'MANUAL' 'Cannot be proven from inside the guest' -Recommendation $fallback -Kind 'Checklist'
    Add-Result 'CHECKLIST' 'Credentials and console access' 'MANUAL' 'Not provable by an unattended inventory' -Recommendation 'Validate domain logon, PAM checkout and local fallback credentials, plus console (vCenter/iLO/iDRAC) access in case network logon fails.' -Kind 'Checklist'
    $lic = Get-TargetLicensingDecision ([string]$script:Data.ActivationKind) ([string]$script:Data.KmsEndpoint) $TargetServerVersion
    Add-Result 'CHECKLIST' 'Target licensing' 'MANUAL' $lic.Value -Recommendation $lic.Text -Kind 'Checklist'
    $media = $script:Data.RecommendedMedia; if (-not $media) { $media = 'See Upgrade path section' }
    Add-Result 'CHECKLIST' 'Installation media' 'MANUAL' $media -Recommendation 'Use media with the exact edition, installation type and language listed. Start Setup with /ResizeRecoveryPartition Disable, so Setup does not shrink C: to add a recovery partition after it (#161). Optional pre-flight: setup.exe /auto upgrade /compat scanonly with the same media.' -Kind 'Checklist' -Command (Get-RecommendationCommand 'SetupNoRecoveryPartition').Command -CommandKind 'Change' -Link $script:DocLinks.SetupOptions.Url -LinkTitle $script:DocLinks.SetupOptions.Title
    Add-Result 'CHECKLIST' 'Application owner sign-off' 'MANUAL' 'Required for every listed workload' -Recommendation 'Get sign-off from each workload owner, including a post-upgrade test plan.' -Kind 'Checklist'
    Add-Result 'CHECKLIST' 'Monitoring and management agents' 'MANUAL' 'Backend communication cannot be proven locally' -Recommendation 'Confirm SA, UD and Operations agents are reporting in the backend before the change; verify again afterwards.' -Kind 'Checklist'
}

# ---------------------------------------------------------------------------
# SLOW CHECKS (time-boxed, run after the checkpoint report is written)
# ---------------------------------------------------------------------------
Register-Check -Id 'printbackup' -Name 'Print server backup (PrintBrm)' -Phase 'Slow' -Script {
    # #148: PrintBrm -B exports printers, ports, drivers and queues into one
    # file. It only reads the spooler configuration. The file is not redacted
    # and is never part of the report.
    if ($AssessmentMode -eq 'Post') { $script:CurrentCheckMessage = 'Not applicable: not needed after the upgrade'; $script:CurrentCheckOutcome = 'Skipped'; return }
    if (-not $script:Data.PrintServer) { $script:CurrentCheckMessage = 'Not applicable: not a print server'; $script:CurrentCheckOutcome = 'Skipped'; return }
    $cmd = Get-PrintBackupCommand
    if (-not $EnablePrintBackup) {
        Add-Result 'PRINTING' 'PrintBackup' 'MANUAL' 'Not taken (EnablePrintBackup is off)' -Recommendation 'Export the print configuration before the change, to a drive with enough free space, and keep the file off the server.' -Kind 'Finding' -Source 'SETTINGS' -Command $cmd -CommandKind 'Check'
        return
    }
    $brm = Join-Path $env:windir 'System32\spool\tools\PrintBrm.exe'
    if (-not (Test-Path -LiteralPath $brm -PathType Leaf)) {
        Add-Result 'PRINTING' 'PrintBackup' 'MANUAL' 'PrintBrm.exe not found' $brm -Recommendation 'Export the printers with Print Management (Export printers to a file) before the change, and keep the file off the server.' -Kind 'Finding' -Source 'PrintBrm.exe'
        return
    }
    $root = [IO.Path]::GetPathRoot($EvidenceRoot).TrimEnd('\')
    $disk = @(Get-CimRequired 'Win32_LogicalDisk' ("DeviceID='" + $root + "'")) | Select-Object -First 1
    if (-not $disk -or $null -eq $disk.FreeSpace) { throw ('Could not read the free space of ' + $root) }
    $space = Get-PrintBackupSpaceDecision (Get-PrintDriverStoreSize) ([long]$disk.FreeSpace)
    if (-not $space.Proceed) {
        Add-Result 'PRINTING' 'PrintBackup' 'MANUAL' ('Skipped: not enough free space on ' + $root) $space.Text -Recommendation 'Run the export to a drive or share with enough free space before the change, and keep the file off the server.' -Kind 'Finding' -Source 'spool\drivers, Win32_LogicalDisk' -Command $cmd -CommandKind 'Check'
        return
    }
    $timeout = [math]::Min($PrintBackupTimeoutMinutes * 60, $script:SlowSecondsLeft)
    $dest = Join-Path (Initialize-EvidenceFolder 'Printers') ($script:SafeComputerName + '-IPU-Print-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $null = Initialize-OutputFolder $dest
    $file = Join-Path $dest ($script:SafeComputerName + '-printers.printerExport')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-NativeCapture $brm @('-B', '-F', $file) $timeout
    $sw.Stop()
    $duration = 'Duration=' + (Format-Duration $sw.Elapsed)
    if ($r.TimedOut) {
        # A cut-off export is not a backup; remove this run's partial file.
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
        Add-Result 'PRINTING' 'PrintBackup' 'MANUAL' ('Stopped after ' + [math]::Round($timeout / 60) + ' minutes') @($duration, $space.Text) -Recommendation 'Run the export by hand outside the SA job, before the change, and keep the file off the server.' -Kind 'Finding' -Source 'PrintBrm.exe -B' -Command $cmd -CommandKind 'Check'
        $script:CurrentCheckOutcome = 'TimedOut'; return
    }
    if ($r.Error) { throw $r.Error }
    if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $file -PathType Leaf)) {
        Add-Result 'PRINTING' 'PrintBackup' 'MANUAL' ('PrintBrm failed (exit code ' + $r.ExitCode + ')') @($duration, (@($r.Lines | Select-Object -Last 3) -join ' | ')) -Recommendation 'Read the PrintBrm output and the PrintBrm event log (Applications and Services Logs > Microsoft > Windows > PrintBRM), then export by hand before the change.' -Kind 'Finding' -Source 'PrintBrm.exe -B' -Command $cmd -CommandKind 'Check'
        return
    }
    $size = [math]::Round(([double](Get-Item -LiteralPath $file).Length / 1MB), 1)
    $script:Data.PrintBackup = $file
    Add-Result 'PRINTING' 'PrintBackup' 'OK' $file @(('SizeMB=' + $size), $duration, $space.Text) -Recommendation 'Copy the file off the server before the change: a backup on C: does not survive a failed upgrade that needs a rebuild. It holds the full print configuration and is not redacted. Restore: PrintBrm -R -F <file> (see the user guide).' -Source 'PrintBrm.exe -B (reads the spooler configuration)'
}

Register-Check -Id 'dism' -Name 'DISM component store scan' -Phase 'Slow' -Script {
    if (-not $RunDISMScanHealth) {
        Add-Result 'WINDOWS_HEALTH' 'DISM ScanHealth' 'MANUAL' 'Skipped by configuration' -Recommendation 'Run the read-only scan before final IPU approval.'
        $script:CurrentCheckMessage = 'Not configured: switched off with -RunDISMScanHealth $false'
        $script:CurrentCheckOutcome = 'Skipped'; return
    }
    $timeout = [math]::Min($DISMTimeoutMinutes * 60, $script:SlowSecondsLeft)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-NativeCapture (Join-Path $env:windir 'System32\dism.exe') @('/English','/Online','/Cleanup-Image','/ScanHealth') $timeout
    $sw.Stop()
    $duration = 'Duration=' + (Format-Duration $sw.Elapsed)
    if ($r.TimedOut) {
        Add-Result 'WINDOWS_HEALTH' 'DISM ScanHealth' 'MANUAL' ('Stopped after ' + [math]::Round($timeout/60) + ' minutes') $duration -Recommendation 'Run "DISM /Online /Cleanup-Image /ScanHealth" manually outside the SA job.' -Source 'dism.exe'
        $script:CurrentCheckOutcome = 'TimedOut'; return
    }
    if ($r.Error) { throw $r.Error }
    $verdict = Get-DismVerdict $r.Output $r.ExitCode
    $summary = @($r.Lines | Where-Object { $_ -notmatch '^\[=*' -and $_ -notmatch '%' } | Select-Object -Last 3) -join ' | '
    Add-Result 'WINDOWS_HEALTH' 'DISM ScanHealth' $verdict.Status ('ExitCode=' + $r.ExitCode) @($duration,$summary,('Basis=' + $verdict.Basis)) -Recommendation $verdict.Recommendation -Source 'dism.exe /English /Online /Cleanup-Image /ScanHealth'
}

Register-Check -Id 'sfc' -Name 'SFC protected file verification' -Phase 'Slow' -Script {
    if (-not $RunSFCVerifyOnly) {
        Add-Result 'WINDOWS_HEALTH' 'SFC VerifyOnly' 'MANUAL' 'Skipped by configuration' -Recommendation 'Run the read-only verification before final IPU approval.'
        $script:CurrentCheckMessage = 'Not configured: switched off with -RunSFCVerifyOnly $false'
        $script:CurrentCheckOutcome = 'Skipped'; return
    }
    $timeout = [math]::Min($SFCTimeoutMinutes * 60, $script:SlowSecondsLeft)
    $started = Get-Date
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-NativeCapture (Join-Path $env:windir 'System32\sfc.exe') @('/verifyonly') $timeout
    $sw.Stop()
    $duration = 'Duration=' + (Format-Duration $sw.Elapsed)
    if ($r.TimedOut) {
        Add-Result 'WINDOWS_HEALTH' 'SFC VerifyOnly' 'MANUAL' ('Stopped after ' + [math]::Round($timeout/60) + ' minutes') $duration -Recommendation 'Run "sfc /verifyonly" manually outside the SA job.' -Source 'sfc.exe'
        $script:CurrentCheckOutcome = 'TimedOut'; return
    }
    if ($r.Error) { throw $r.Error }
    $cbs = @()
    $stamp = $started.AddMinutes(-1).ToString('yyyy-MM-dd HH:mm')
    foreach ($line in (Read-FileTail (Join-Path $env:windir 'Logs\CBS\CBS.log'))) {
        if ($line.Length -ge 16 -and $line.Substring(0,16) -ge $stamp) { $cbs += $line }
    }
    $verdict = Get-SfcVerdict $r.Output $cbs
    $summary = @($r.Lines | Where-Object { $_ -notmatch '\d{1,3}\s*%' } | Select-Object -Last 2) -join ' | '
    $rec = @{ OK=''; ACTION='Resolve protected-file integrity violations (DISM /RestoreHealth, then sfc /scannow in a change) and re-run before IPU.'; WARNING='SFC did not check anything: a Windows repair is waiting for a reboot (see the pending-reboot row). Reboot, then re-run the assessment. This is not evidence of damaged files.'; MANUAL='Result could not be classified; review the output and CBS.log.' }[$verdict.Status]
    Add-Result 'WINDOWS_HEALTH' 'SFC VerifyOnly' $verdict.Status ('ExitCode=' + $r.ExitCode + ', Basis=' + $verdict.Basis) @($duration,$summary) -Recommendation $rec -Source 'sfc.exe /verifyonly, CBS.log'
}

Register-Check -Id 'compatscan' -Name 'Setup compatibility scan' -Phase 'Slow' -Script {
    if ($AssessmentMode -eq 'Post') { $script:CurrentCheckMessage = 'Not applicable after the upgrade'; $script:CurrentCheckOutcome = 'Skipped'; return }
    if (-not $TargetMediaPath) {
        Add-Result 'COMPAT_SCAN' 'SetupCompatibilityScan' 'INFO' 'Not run - no installation media given' ('Optional. To let Windows Setup check this server with Microsoft''s own compatibility rules, run again with -TargetMediaPath set to the ' + (Get-ReleaseDisplayName $TargetServerVersion) + ' ISO, or a folder or share with the installation files.') -Source 'SETTINGS' -Link $script:DocLinks.SetupOptions.Url -LinkTitle $script:DocLinks.SetupOptions.Title
        $script:CurrentCheckMessage = 'Not configured: no installation media given (-TargetMediaPath)'
        $script:CurrentCheckOutcome = 'Skipped'; return
    }
    $timeout = [math]::Min($CompatScanTimeoutMinutes * 60, $script:SlowSecondsLeft)
    $mountedIso = $null
    try {
        $mediaRoot = $TargetMediaPath
        if ($TargetMediaPath -match '\.iso$') {
            if (-not (Test-Path -LiteralPath $TargetMediaPath)) { throw ('ISO not found: ' + $TargetMediaPath) }
            $mountedIso = Mount-DiskImage -ImagePath $TargetMediaPath -PassThru -ErrorAction Stop
            $letter = ($mountedIso | Get-Volume -ErrorAction Stop).DriveLetter
            if (-not $letter) { throw 'The mounted ISO received no drive letter.' }
            $mediaRoot = $letter + ':\'
        }
        $setupExe = Join-Path $mediaRoot 'setup.exe'
        if (-not (Test-Path -LiteralPath $setupExe)) { throw ('setup.exe not found in ' + $mediaRoot) }

        # Pick the image that matches this server's edition and installation
        # type; a mismatch is itself a finding (wrong media).
        $imageFile = @('sources\install.wim','sources\install.esd') | ForEach-Object { Join-Path $mediaRoot $_ } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $imageFile) { throw 'No install.wim or install.esd found in the media.' }
        $wantEdition = ([string]$script:Data.CV.EditionID -replace '(Core|Cor)$','')
        $wantType = [string]$script:Data.CV.InstallationType
        $index = 0; $imageNames = @(); $imageLanguages = ''
        foreach ($img in @(Get-WindowsImage -ImagePath $imageFile -ErrorAction Stop)) {
            $detail = Get-WindowsImage -ImagePath $imageFile -Index $img.ImageIndex -ErrorAction Stop
            $imageNames += ('[' + $img.ImageIndex + '] ' + $img.ImageName)
            if (-not $index -and [string]$detail.EditionId -eq $wantEdition -and [string]$detail.InstallationType -eq $wantType) {
                $index = [int]$img.ImageIndex; $imageLanguages = (@($detail.Languages) -join ',')
            }
        }
        if (-not $index) {
            Add-Result 'COMPAT_SCAN' 'MatchingImage' 'ACTION' ('No image for ' + $wantEdition + ' / ' + $wantType + ' in the media') $imageNames -Recommendation 'The media does not contain an image matching this server''s edition and installation type. Use the correct media; IPU cannot switch edition down or between Core and Desktop Experience.' -Source $imageFile
            return
        }
        Add-Result 'COMPAT_SCAN' 'MatchingImage' 'OK' ('Index ' + $index) @(('Languages=' + $imageLanguages),($imageNames -join ' | ')) -Source $imageFile
        if ($script:Data.InstallLanguage -and $imageLanguages -and (@($imageLanguages -split ',') -notcontains $script:Data.InstallLanguage)) {
            Add-Result 'COMPAT_SCAN' 'MediaLanguage' 'BLOCKER' ('Media=' + $imageLanguages + ', Installed=' + $script:Data.InstallLanguage) '' -Recommendation 'Changing language during IPU is not supported. Use media in the installed language.' -Source $imageFile
        }

        $arguments = @('/auto','upgrade','/quiet','/compat','scanonly','/imageindex',[string]$index,'/dynamicupdate','disable')
        if ($TargetServerVersion -eq '2025') { $arguments += @('/eula','accept') }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-NativeCapture $setupExe $arguments $timeout
        $sw.Stop()
        if ($r.TimedOut) {
            Add-Result 'COMPAT_SCAN' 'SetupCompatibilityScan' 'MANUAL' ('Stopped after ' + [math]::Round($timeout/60) + ' minutes') ('Duration=' + (Format-Duration $sw.Elapsed)) -Recommendation 'Run the scan manually: setup.exe /auto upgrade /quiet /compat scanonly /imageindex <n>.' -Source 'setup.exe'
            $script:CurrentCheckOutcome = 'TimedOut'; return
        }
        if ($r.Error) { throw $r.Error }
        $decision = Get-CompatScanDecision $r.ExitCode

        # Keep Setup's CompatData XML and list the hard blocks it names.
        $evidence = Join-Path $ReportDirectory ($script:SafeComputerName + '-CompatData')
        $blocks = @()
        $panther = 'C:\$WINDOWS.~BT\Sources\Panther'
        $xmlFiles = @(Get-ChildItem -LiteralPath $panther -Filter 'CompatData*.xml' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge (Get-Date).AddSeconds(-1 * ($sw.Elapsed.TotalSeconds + 60)) })
        if ($xmlFiles.Count -gt 0) {
            $null = Initialize-OutputFolder $evidence
            foreach ($x in $xmlFiles) {
                Copy-Item -LiteralPath $x.FullName -Destination $evidence -Force
                try {
                    [xml]$doc = Get-Content -LiteralPath $x.FullName -Raw
                    foreach ($node in @($doc.SelectNodes('//*[@BlockingType="Hard"]'))) {
                        $owner = $node.ParentNode
                        $label = @($owner.Attributes['Name'],$owner.Attributes['Title'],$owner.Attributes['Id'] | Where-Object { $_ } | ForEach-Object { $_.Value }) | Select-Object -First 1
                        if (-not $label) { $label = $owner.LocalName }
                        $blocks += $label
                    }
                } catch { Write-Swallowed $_ }
            }
        }
        $details = @(('Duration=' + (Format-Duration $sw.Elapsed)),('ImageIndex=' + $index))
        if ($blocks.Count -gt 0) { $details += ('Hard blocks: ' + (@($blocks | Sort-Object -Unique) -join ', ')) }
        if ($xmlFiles.Count -gt 0) { $details += ('CompatData copied to ' + $evidence) }
        Add-Result 'COMPAT_SCAN' 'SetupCompatibilityScan' $decision.Status ($decision.Code + ' - ' + $decision.Text) $details -Recommendation $(if ($decision.Status -eq 'OK') { '' } else { 'Read the CompatData XML (and Panther setuperr.log) to see exactly what Setup objects to, fix it, and re-run the scan.' }) -Source ('setup.exe /compat scanonly from ' + $TargetMediaPath)
    } finally {
        if ($mountedIso) { try { Dismount-DiskImage -ImagePath $TargetMediaPath -ErrorAction Stop | Out-Null } catch { Write-Swallowed $_ } }
    }
}

} # end Register-AssessmentCheck


# ---------------------------------------------------------------------------
# RDP access / policy evidence (called by the 'rdp' check)
# ---------------------------------------------------------------------------
function Invoke-RdpPolicyAssessment {
    if (-not $EnableRDPPolicyEvidence) {
        Add-Result 'RDP' 'RDPAccessReadiness' 'MANUAL' 'REVIEW' 'Policy evidence disabled in SETTINGS' -Recommendation 'Test RDP end-to-end before relying on it during the change.'
        $script:Data.RdpSummary = 'REVIEW (not assessed)'; $script:Data.DriveRedirection = 'Not assessed'
        return
    }
    $hard = New-Object System.Collections.Generic.List[string]
    $review = New-Object System.Collections.Generic.List[string]
    $driveBlock = New-Object System.Collections.Generic.List[string]

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $root = Join-Path (Get-EvidenceFolderPath $EvidenceRoot 'Policy' $PolicyEvidenceRoot) ($script:SafeComputerName + '-IPU-Policy-' + $stamp)
    $lgpoRoot = Join-Path $root 'LGPO-Backup'
    $zip = $root + '.zip'
    $script:Data.PolicyEvidence = $root
    $folderOk = $true
    try {
        $null = Initialize-EvidenceFolder 'Policy'
        $null = Initialize-OutputFolder $root
        New-Item -ItemType Directory -Path $lgpoRoot -Force | Out-Null
    }
    catch { $folderOk = $false; $review.Add('Evidence folder could not be created'); Add-Result 'POLICY_EVIDENCE' 'EvidenceFolder' 'MANUAL' $root $_.Exception.Message -Recommendation 'Make the evidence folder writable and re-run.' -Kind 'Finding' }

    if ($folderOk) {
        # LGPO backup (local policy only; never imports).
        # An empty -LgpoExe skips LGPO on purpose (#150). Windows PowerShell
        # rejects Test-Path with an empty path, so test for it first.
        if (-not $LgpoExe) {
            Add-Result 'POLICY_EVIDENCE' 'LocalGroupPolicyBackup' 'INFO' 'LGPO disabled (-LgpoExe is empty) - local policy backup skipped' -Source 'Parameter'
        } elseif (Test-Path -LiteralPath $LgpoExe -PathType Leaf) {
            $r = Invoke-NativeCapture $LgpoExe @('/b',$lgpoRoot,'/n',('Pre-IPU-' + $stamp)) 120
            $r.Output | Out-File -LiteralPath (Join-Path $root 'LGPO-Backup-Output.txt') -Encoding UTF8
            if ($r.ExitCode -eq 0) { Add-Result 'POLICY_EVIDENCE' 'LocalGroupPolicyBackup' 'OK' $lgpoRoot -Source 'LGPO.exe /b' }
            else { Add-Result 'POLICY_EVIDENCE' 'LocalGroupPolicyBackup' 'MANUAL' ('ExitCode=' + $r.ExitCode) $r.Error -Recommendation 'Review the LGPO output if a restorable local-policy copy is required.' -Kind 'Finding' -Source 'LGPO.exe /b' }
            foreach ($pol in @(
                @{ Scope='Machine'; Mode='/m'; Path=(Join-Path $env:windir 'System32\GroupPolicy\Machine\Registry.pol') },
                @{ Scope='User'; Mode='/u'; Path=(Join-Path $env:windir 'System32\GroupPolicy\User\Registry.pol') })) {
                if (Test-Path -LiteralPath $pol.Path) {
                    $parsed = Join-Path $root ('Local-Policy-' + $pol.Scope + '-RegistryPol.txt')
                    (Invoke-NativeCapture $LgpoExe @('/parse',$pol.Mode,$pol.Path) 60).Output | Out-File -LiteralPath $parsed -Encoding UTF8
                    Add-Result 'POLICY_EVIDENCE' ('LocalRegistryPolicy-' + $pol.Scope) 'INFO' $parsed -Source 'LGPO.exe /parse'
                }
            }
        } else {
            Add-Result 'POLICY_EVIDENCE' 'LocalGroupPolicyBackup' 'INFO' 'LGPO.exe not present - local policy backup skipped' $LgpoExe -Recommendation 'Optional: place LGPO.exe at this path to keep a restorable local-policy backup.' -Source 'File check'
        }

        # Resultant Set of Policy.
        $gpresult = Join-Path $env:windir 'System32\gpresult.exe'
        $gpText = Invoke-NativeCapture $gpresult @('/Scope','Computer','/Z') 180
        $gpText.Output | Out-File -LiteralPath (Join-Path $root 'GPResult-Computer.txt') -Encoding UTF8
        $gpHtml = Invoke-NativeCapture $gpresult @('/Scope','Computer','/H',(Join-Path $root 'GPResult-Computer.html'),'/F') 180
        if ($gpText.ExitCode -eq 0 -or $gpHtml.ExitCode -eq 0) { Add-Result 'POLICY_EVIDENCE' 'ComputerRSoP' 'OK' (Join-Path $root 'GPResult-Computer.html') -Source 'gpresult' }
        else { $review.Add('gpresult did not return computer policy'); Add-Result 'POLICY_EVIDENCE' 'ComputerRSoP' 'MANUAL' ('Exit=' + $gpText.ExitCode + '/' + $gpHtml.ExitCode) -Recommendation 'Collect RSoP manually.' -Kind 'Finding' -Source 'gpresult' }
    }

    $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    $tsPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    $tcpPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'

    $polDeny = Get-RegistryValueSafe $policyPath 'fDenyTSConnections'
    $effDeny = Get-RegistryValueSafe $tsPath 'fDenyTSConnections'
    if ($polDeny.Exists -and [int]$polDeny.Value -eq 1) { $hard.Add('Group Policy disables incoming RDP') }
    if ($effDeny.Exists -and [int]$effDeny.Value -ne 0) { $hard.Add('Incoming RDP is disabled (fDenyTSConnections)') }
    if (-not $effDeny.Exists) { $review.Add('RDP enablement value not found') }
    Add-Result 'RDP' 'RemoteConnections' 'INFO' ('Policy=' + $(if ($polDeny.Exists) { $polDeny.Value } else { 'NotConfigured' })) ('Effective=' + $(if ($effDeny.Exists) { $effDeny.Value } else { 'Unknown' })) -Source 'Terminal Services registry'

    $port = 3389
    $portValue = Get-RegistryValueSafe $tcpPath 'PortNumber'
    if ($portValue.Exists) { $port = [int]$portValue.Value }
    $nla = Get-RegistryValueSafe $tcpPath 'UserAuthentication'
    $script:Data.NlaState = 'Unknown'
    if ($nla.Exists) { $script:Data.NlaState = $(if ([int]$nla.Value -eq 0) { 'Off' } else { 'On' }) }
    if ($nla.Exists -and $script:Data.Snapshot) { $script:Data.Snapshot.Nla = $script:Data.NlaState }
    Add-Result 'RDP' 'Listener' 'INFO' ('Port=' + $port) ('NLA=' + $(if ($nla.Exists) { $nla.Value } else { 'Unknown' })) -Source 'RDP-Tcp registry'
    if ($nla.Exists -and [int]$nla.Value -eq 0) {
        $nlaPolicy = Get-RegistryValueSafe $policyPath 'UserAuthentication'
        if ($nlaPolicy.Exists) {
            Add-Result 'RDP' 'NetworkLevelAuthentication' 'WARNING' 'Disabled' 'Not an IPU blocker - a security observation. Set by Group Policy.' -Recommendation 'RDP accepts connections before the user is authenticated. NLA is set by Group Policy: change the GPO (Require user authentication for remote connections by using Network Level Authentication), not the server.' -Kind 'Observation' -Source 'Terminal Services policy UserAuthentication'
        } else {
            Add-Result 'RDP' 'NetworkLevelAuthentication' 'WARNING' 'Disabled' 'Not an IPU blocker - a security observation.' -Recommendation 'RDP accepts connections before the user is authenticated. Enable NLA unless a documented client requirement prevents it.' -Kind 'Observation' -Source 'RDP-Tcp UserAuthentication' -Command (Get-RecommendationCommand 'EnableNla').Command -CommandKind 'Change'
        }
    }

    $svc = @($script:Data.Services | Where-Object { $_.Name -eq 'TermService' }) | Select-Object -First 1
    if (-not $svc) { $hard.Add('TermService not found') }
    elseif ($svc.StartMode -eq 'Disabled') { $hard.Add('TermService is disabled') }
    elseif ($svc.State -ne 'Running') { $review.Add('TermService is not running') }

    $listening = $false; $listenerUnknown = $false
    if (Test-CommandAvailable 'Get-NetTCPConnection') {
        try { $listening = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction Stop).Count -gt 0 }
        catch {
            # No listener raises ObjectNotFound; any other error means the query failed, which says nothing about the port (#242).
            if (-not (Test-NotFoundError $_)) { $listenerUnknown = $true; Write-Swallowed $_; $review.Add('The listener query failed: ' + $_.Exception.Message) }
        }
    }
    if (-not $listening -and -not $listenerUnknown) { $hard.Add('Nothing listening on TCP/' + $port) }

    # Firewall: only relevant when at least one profile is enabled.
    if (Test-CommandAvailable 'Get-NetFirewallRule') {
        try {
            $enabledProfiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop | Where-Object { [string]$_.Enabled -eq 'True' })
            if ($enabledProfiles.Count -eq 0) {
                Add-Result 'RDP' 'FirewallRDPAllow' 'INFO' 'Windows Firewall disabled on all profiles' -Source 'Get-NetFirewallProfile'
            } else {
                $rules = @(Get-NetFirewallRule -PolicyStore ActiveStore -ErrorAction Stop | Where-Object { [string]$_.Direction -eq 'Inbound' -and [string]$_.Enabled -eq 'True' -and [string]$_.Action -eq 'Allow' -and ($_.Name -like 'RemoteDesktop*' -or $_.DisplayGroup -match 'Remote Desktop') })
                if ($rules.Count -gt 0) { Add-Result 'RDP' 'FirewallRDPAllow' 'OK' ('EnabledAllowRules=' + $rules.Count) -Source 'Get-NetFirewallRule' }
                else { $review.Add('No enabled standard Remote Desktop firewall rule (a custom rule may exist)'); Add-Result 'RDP' 'FirewallRDPAllow' 'WARNING' 'No enabled standard RDP allow rule' -Recommendation 'Check for a custom rule and upstream firewalls.' -Kind 'Observation' -Source 'Get-NetFirewallRule' }
            }
        } catch { $review.Add('Firewall rules could not be read') }
    }

    # User rights. A populated Deny right is normal hardening and is recorded
    # as evidence only; an empty Allow right is a real problem.
    if ($folderOk) {
        $inf = Join-Path $root 'Effective-User-Rights.inf'
        $null = Invoke-NativeCapture (Join-Path $env:windir 'System32\secedit.exe') @('/export','/cfg',$inf,'/areas','USER_RIGHTS','/quiet') 120
        if (Test-Path -LiteralPath $inf) {
            $lines = @(Get-Content -LiteralPath $inf)
            foreach ($right in @('SeRemoteInteractiveLogonRight','SeDenyRemoteInteractiveLogonRight')) {
                $line = @($lines | Where-Object { $_ -match ('^\s*' + $right + '\s*=') }) | Select-Object -First 1
                $accounts = @()
                if ($line) { foreach ($a in @(((($line -split '=',2)[1]).Trim()) -split ',' | Where-Object { $_.Trim() })) { $accounts += (Resolve-PolicyAccountName $a) } }
                if ($right -eq 'SeRemoteInteractiveLogonRight' -and $accounts.Count -eq 0) { $hard.Add('Nobody holds "Allow log on through Remote Desktop Services"') }
                $text = 'No identities'; if ($accounts.Count -gt 0) { $text = $accounts -join ' | ' }
                Add-Result 'RDP' $right 'INFO' $text -Recommendation 'Check the change engineer''s account (and nested groups) against Allow and Deny.' -Source 'secedit /export'
            }
        } else { $review.Add('User rights could not be exported') }
    }
    $rdu = Get-LocalGroupMembersBySid 'S-1-5-32-555'
    Add-Result 'RDP' 'RemoteDesktopUsersGroup' 'INFO' $(if ($rdu.Count -gt 0) { $rdu -join ' | ' } else { 'No members' }) -Source 'Local group S-1-5-32-555'

    # Drive redirection (machine policy, listener, loaded user policies).
    $polCdm = Get-RegistryValueSafe $policyPath 'fDisableCdm'
    $tcpCdm = Get-RegistryValueSafe $tcpPath 'fDisableCdm'
    if ($polCdm.Exists -and [int]$polCdm.Value -eq 1) { $driveBlock.Add('Machine policy fDisableCdm=1') }
    if ($tcpCdm.Exists -and [int]$tcpCdm.Value -eq 1) { $driveBlock.Add('RDP-Tcp fDisableCdm=1') }
    foreach ($sid in @(Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } | ForEach-Object { $_.PSChildName })) {
        $u = Get-RegistryValueSafe ('Registry::HKEY_USERS\' + $sid + '\Software\Policies\Microsoft\Windows NT\Terminal Services') 'fDisableCdm'
        if ($u.Exists -and [int]$u.Value -eq 1) { $driveBlock.Add('User ' + (Resolve-PolicyAccountName $sid) + ' fDisableCdm=1') }
    }

    if ($hard.Count -gt 0) {
        $script:Data.RdpSummary = 'NO-GO: ' + ($hard -join '; ')
        Add-Result 'RDP' 'RDPAccessReadiness' 'ACTION' 'NO-GO' @(($hard -join ' | '),($review -join ' | ')) -Recommendation 'Fix the local RDP block and test an end-to-end logon, or plan console-only access for the change.' -Source 'Registry, service, listener, user rights'
    } elseif ($review.Count -gt 0) {
        $script:Data.RdpSummary = 'REVIEW: ' + ($review -join '; ')
        Add-Result 'RDP' 'RDPAccessReadiness' 'MANUAL' 'REVIEW' ($review -join ' | ') -Recommendation 'Test an end-to-end RDP logon with the account that will be used in the change window.' -Source 'Registry, service, listener, firewall'
    } else {
        $script:Data.RdpSummary = 'GO (no local blocker)'
        Add-Result 'RDP' 'RDPAccessReadiness' 'OK' 'GO' 'No local RDP blocker detected' -Recommendation 'Upstream firewalls, PAM and credentials are outside this check.' -Source 'Registry, service, listener, firewall'
    }
    if ($driveBlock.Count -gt 0) {
        $script:Data.DriveRedirection = 'BLOCKED: ' + ($driveBlock -join '; ')
        Add-Result 'RDP' 'DriveRedirection' 'WARNING' 'BLOCKED' ($driveBlock -join ' | ') -Recommendation 'If you plan to copy media or tools over an RDP-mapped drive, use another route (SA file transfer, share, mounted ISO).' -Source 'Terminal Services policy'
    } else {
        $script:Data.DriveRedirection = 'Allowed locally'
        Add-Result 'RDP' 'DriveRedirection' 'OK' 'ALLOWED LOCALLY' 'Destination/client policy not tested' -Source 'Terminal Services policy'
    }

    if ($folderOk) {
        try {
            @($script:Results | Where-Object { $_.Area -in @('RDP','POLICY_EVIDENCE') }) | Export-Csv -LiteralPath (Join-Path $root 'RDP-Policy-Assessment.csv') -Delimiter ';' -NoTypeInformation -Encoding UTF8
        } catch { Write-Swallowed $_ }
        if ($CreatePolicyEvidenceZip) {
            try {
                if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
                New-ZipFromFolder $root $zip
                $script:Data.PolicyEvidence = $zip
            } catch { Add-Result 'POLICY_EVIDENCE' 'EvidenceArchive' 'MANUAL' 'ZIP creation failed' $_.Exception.Message -Recommendation 'Retrieve the folder directly.' -Kind 'Finding' }
        }
        Add-Result 'POLICY_EVIDENCE' 'EvidenceLocation' 'INFO' $script:Data.PolicyEvidence $root -Source 'Local filesystem'
    }
}


