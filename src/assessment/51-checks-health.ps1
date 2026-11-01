# Chapter: Upgrade path, licensing and Windows health (docs/checks.md). The slow checks of this chapter run after the checkpoint report.
# Each check is one function; Register-AssessmentCheck (50-checks.ps1) lists them in run order.

function Invoke-BaselineCheck {
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

    # Snapshot used for the post-upgrade comparison (stored in the JSON).
    $script:Data.Snapshot = @{
        Services = @($script:Data.Services | ForEach-Object { [pscustomobject]@{ Name=[string]$_.Name; State=[string]$_.State; StartMode=[string]$_.StartMode } })
        Apps     = @($script:Data.Apps | ForEach-Object { [pscustomobject]@{ Name=$_.Name; Version=$_.Version } })
        Ports = @(); Routes = @(); IPv4 = @(); Dns = @(); Adapters = @(); Hosts = @(); Tasks = @()
        Printers = @(); PrinterPorts = @(); PrinterDrivers = @()
    }
    # The list is added only when the inventory was read (#361). A list that was
    # not read is left out, not stored as empty, so the post-upgrade comparison
    # names it as not compared instead of reading it as "no features".
    if ($null -ne $script:Data.Features) { $script:Data.Snapshot.Features = @($script:Data.Features.Keys | Where-Object { $script:Data.Features[$_] } | Sort-Object) }

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

function Invoke-UpgradePathCheck {
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
    # A PKI server never gets a target its site policy rules out (#322).
    $pkiAllowed = @()
    if (Test-PkiServer (Get-FeatureState 'ADCS-Cert-Authority') @($script:Data.Services | ForEach-Object { [string]$_.Name })) { $pkiAllowed = ConvertTo-ReleaseList $PkiAllowedTargets }
    $path = Get-UpgradePathDecision $source $TargetServerVersion $clustered -AllowedTargets $pkiAllowed
    if ($AssessmentMode -eq 'Post' -and $source -and $source -eq $TargetServerVersion -and -not $clustered) {
        $path = [pscustomobject]@{ Status = 'INFO'; Text = ('Now ' + (Get-ReleaseDisplayName $source) + ' (post-upgrade run).') }
    }
    Add-Result 'UPGRADE_PATH' 'TargetUpgradePath' $path.Status $path.Text ('Target=' + (Get-ReleaseDisplayName $TargetServerVersion)) -Source 'Microsoft supported upgrade paths (installation media)' -Link $script:DocLinks.InPlaceUpgrade.Url -LinkTitle $script:DocLinks.InPlaceUpgrade.Title

    $edition = Get-EditionDecision $cv.EditionID $cv.InstallationType $TargetServerVersion
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

function Invoke-LicensingCheck {
    $statusNames = @{ 0='Unlicensed'; 1='Licensed'; 2='OOBGrace'; 3='OOTGrace'; 4='NonGenuineGrace'; 5='Notification'; 6='ExtendedGrace' }
    $products = @()
    $queryError = ''
    try {
        $products = @(Get-CimInstance -Query "SELECT Name,Description,LicenseStatus,LicenseIsAddon,PartialProductKey,ProductKeyChannel,GracePeriodRemaining,DiscoveredKeyManagementServiceMachineName,DiscoveredKeyManagementServiceMachinePort,KeyManagementServiceMachine,KeyManagementServicePort FROM SoftwareLicensingProduct WHERE ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -ErrorAction Stop)
    } catch {
        # Older builds do not expose ProductKeyChannel; retry with all columns.
        try {
            $products = @(Get-CimInstance -Query "SELECT * FROM SoftwareLicensingProduct WHERE ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" -ErrorAction Stop |
                Where-Object { $_.PartialProductKey })
        } catch { $queryError = $_.Exception.Message }
    }
    # SilentlyContinue: Optional: no KMS host set on the server is the normal case (DNS discovery).
    $spp = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform' -ErrorAction SilentlyContinue
    $kms = 'Not set on this server (a KMS client finds its host via DNS)'
    if ($spp.KeyManagementServiceName) { $kms = [string]$spp.KeyManagementServiceName; if ($spp.KeyManagementServicePort) { $kms += ':' + $spp.KeyManagementServicePort } }
    $script:Data.KmsEndpoint = $kms

    if ($queryError) {
        Add-Result 'LICENSING' 'CurrentActivation' 'MANUAL' 'Activation state could not be queried' @($queryError,('KMS=' + $kms)) -Recommendation 'Validate activation manually (slmgr /dlv). A query failure does not prove Windows is unlicensed.' -Source 'SoftwareLicensingProduct'
        return
    }
    $os = Select-OsLicenseProduct $products
    $primary = $os.Primary
    # An ESU licence is its own row, never the OS licence (#248).
    foreach ($addOn in @($os.AddOns)) {
        $addOnState = $statusNames[[int]$addOn.LicenseStatus]; if (-not $addOnState) { $addOnState = 'Unknown(' + $addOn.LicenseStatus + ')' }
        Add-Result 'LICENSING' ('Add-on licence: ' + [string]$addOn.Name) 'INFO' $addOnState ('PartialProductKey=' + $addOn.PartialProductKey) -Recommendation 'An add-on licence (for example Extended Security Updates) is not the Windows licence. Confirm what happens to it on the target release.' -Kind 'Observation' -Source 'SoftwareLicensingProduct'
    }
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
    $act = Get-ActivationDecision $script:Data.ActivationKind ([int]$primary.LicenseStatus) $state $channel $grace $discHost $discPort $confHost $confPort $KmsRenewWarnDays
    if ($act.KmsHost) { foreach ($h in @($act.KmsHost, ($act.KmsHost -split '\.')[0]) | Select-Object -Unique) { Add-RedactionLiteral $h 'HOST' }; $script:Data.KmsEndpoint = $act.KmsEndpoint } elseif ($script:Data.ActivationKind -eq 'KMS') { $script:Data.KmsEndpoint = 'found via DNS' }
    $script:Data.ActivationSummary = $act.Value
    $details = @(('Channel=' + $channel), ('PartialProductKey=' + $primary.PartialProductKey)) + @($act.Details)
    Add-Result 'LICENSING' 'CurrentActivation' $act.Status $act.Value $details -Recommendation $act.Text -Source 'SoftwareLicensingProduct (only the last 5 key characters are read)'
    if ($channel -match 'OEM') {
        Add-Result 'LICENSING' 'OEMLicense' 'WARNING' $channel -Recommendation 'An OEM licence is tied to the original hardware and release. Confirm the target licence/key before IPU.' -Source 'SoftwareLicensingProduct'
    }
}

function Invoke-PendingRebootCheck {
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
        Add-Result 'WINDOWS_HEALTH' 'Uptime' 'WARNING' ('UptimeDays=' + $days) ('LastBoot=' + $boot.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)) -Recommendation 'Do a controlled reboot before the change window and re-run the assessment. A long-unrebooted server can hide reboot-time problems that would otherwise surface mid-upgrade.' -Source 'Win32_OperatingSystem'
    } else {
        Add-Result 'WINDOWS_HEALTH' 'Uptime' 'OK' ('UptimeDays=' + $days) ('LastBoot=' + $boot.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)) -Source 'Win32_OperatingSystem'
    }
}

function Invoke-PatchLevelCheck {
    # SilentlyContinue: An empty or failed list is reported as MANUAL below ('No dated update history').
    $fixes = @(Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn })
    $latest = $null
    foreach ($f in $fixes) { try { $d = [datetime]$f.InstalledOn; if (-not $latest -or $d -gt $latest.Date) { $latest = [pscustomobject]@{ Date=$d; Id=$f.HotFixID } } } catch { Write-Swallowed $_ } }
    if (-not $latest) {
        Add-Result 'WINDOWS_HEALTH' 'LatestUpdate' 'MANUAL' 'No dated update history returned' -Recommendation 'Confirm the server has the latest cumulative and servicing stack updates before IPU.' -Source 'Get-HotFix'
        return
    }
    $age = [math]::Floor(((Get-Date) - $latest.Date).TotalDays)
    $value = 'LatestInstalled=' + $latest.Date.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) + ' (' + $latest.Id + ')'
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

function Invoke-HistoryCheck {
    $found = $false
    # HKLM\SYSTEM\Setup always exists: a failed read fails the check (#306),
    # it must not look like a server that was never upgraded.
    foreach ($key in @(Get-ChildItem 'HKLM:\SYSTEM\Setup' -ErrorAction Stop | Where-Object { $_.PSChildName -like 'Source OS*' } | Sort-Object PSChildName)) {
        $p = Get-ItemProperty $key.PSPath -ErrorAction Stop
        $found = $true
        $installed = ''
        if ($p.InstallDate) { try { $installed = (New-Object DateTime 1970,1,1,0,0,0,([DateTimeKind]::Utc)).AddSeconds([int64]$p.InstallDate).ToLocalTime().ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) } catch { Write-Swallowed $_ } }
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
    if ($installDate) { $osInstall = $installDate.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
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
        if (Test-Path -LiteralPath $btLog) { $btDate = 'setupact.log LastWrite=' + (Get-Item -LiteralPath $btLog).LastWriteTime.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture) }
        Add-Result 'UPGRADE_HISTORY' 'SetupWorkingFolder' 'INFO' 'C:\$WINDOWS.~BT exists' $btDate -Recommendation 'Left by an earlier Setup run: a compatibility scan or an aborted upgrade. If no scan was run, read the Panther logs to see why an upgrade stopped.' -Kind 'Observation' -Source 'C:\$WINDOWS.~BT'
    }
}

function Invoke-DismCheck {
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
        Add-Result 'WINDOWS_HEALTH' 'DISM ScanHealth' 'MANUAL' ('Stopped after ' + [math]::Round($timeout/60) + ' minutes') @($duration, (Get-StopFailureText $r.StillRunning)) -Recommendation 'Run "DISM /Online /Cleanup-Image /ScanHealth" manually outside the SA job.' -Source 'dism.exe'
        $script:CurrentCheckOutcome = 'TimedOut'; return
    }
    if ($r.Error) { throw $r.Error }
    $verdict = Get-DismVerdict $r.Output $r.ExitCode
    $summary = @($r.Lines | Where-Object { $_ -notmatch '^\[=*' -and $_ -notmatch '%' } | Select-Object -Last 3) -join ' | '
    Add-Result 'WINDOWS_HEALTH' 'DISM ScanHealth' $verdict.Status ('ExitCode=' + $r.ExitCode) @($duration,$summary,('Basis=' + $verdict.Basis)) -Recommendation $verdict.Recommendation -Source 'dism.exe /English /Online /Cleanup-Image /ScanHealth'
}

function Invoke-SfcCheck {
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
        Add-Result 'WINDOWS_HEALTH' 'SFC VerifyOnly' 'MANUAL' ('Stopped after ' + [math]::Round($timeout/60) + ' minutes') @($duration, (Get-StopFailureText $r.StillRunning)) -Recommendation 'Run "sfc /verifyonly" manually outside the SA job.' -Source 'sfc.exe'
        $script:CurrentCheckOutcome = 'TimedOut'; return
    }
    if ($r.Error) { throw $r.Error }
    $cbs = @()
    $stamp = $started.AddMinutes(-1).ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    foreach ($line in (Read-FileTail (Join-Path $env:windir 'Logs\CBS\CBS.log'))) {
        if ($line.Length -ge 16 -and $line.Substring(0,16) -ge $stamp) { $cbs += $line }
    }
    $verdict = Get-SfcVerdict $r.Output $cbs
    $summary = @($r.Lines | Where-Object { $_ -notmatch '\d{1,3}\s*%' } | Select-Object -Last 2) -join ' | '
    $rec = @{ OK=''; ACTION='Resolve protected-file integrity violations (DISM /RestoreHealth, then sfc /scannow in a change) and re-run before IPU.'; WARNING='SFC did not check anything: a Windows repair is waiting for a reboot (see the pending-reboot row). Reboot, then re-run the assessment. This is not evidence of damaged files.'; MANUAL='Result could not be classified; review the output and CBS.log.' }[$verdict.Status]
    Add-Result 'WINDOWS_HEALTH' 'SFC VerifyOnly' $verdict.Status ('ExitCode=' + $r.ExitCode + ', Basis=' + $verdict.Basis) @($duration,$summary) -Recommendation $rec -Source 'sfc.exe /verifyonly, CBS.log'
}

function Invoke-CompatScanCheck {
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
        if ($script:Data.InstallLanguage -and $imageLanguages -and -not (Test-MediaLanguageMatch @($imageLanguages -split ',') $script:Data.InstallLanguage)) {
            Add-Result 'COMPAT_SCAN' 'MediaLanguage' 'BLOCKER' ('Media=' + $imageLanguages + ', Installed=' + $script:Data.InstallLanguage) '' -Recommendation 'Changing language during IPU is not supported. Use media in the installed language.' -Source $imageFile
        }

        $arguments = @('/auto','upgrade','/quiet','/compat','scanonly','/imageindex',[string]$index,'/dynamicupdate','disable')
        if ($TargetServerVersion -eq '2025') { $arguments += @('/eula','accept') }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-NativeCapture $setupExe $arguments $timeout
        $sw.Stop()
        if ($r.TimedOut) {
            Add-Result 'COMPAT_SCAN' 'SetupCompatibilityScan' 'MANUAL' ('Stopped after ' + [math]::Round($timeout/60) + ' minutes') @(('Duration=' + (Format-Duration $sw.Elapsed)), (Get-StopFailureText $r.StillRunning)) -Recommendation 'Run the scan manually: setup.exe /auto upgrade /quiet /compat scanonly /imageindex <n>.' -Source 'setup.exe'
            $script:CurrentCheckOutcome = 'TimedOut'; return
        }
        if ($r.Error) { throw $r.Error }
        $decision = Get-CompatScanDecision $r.ExitCode

        # Keep Setup's CompatData XML and list the hard blocks it names.
        $evidence = Join-Path $ReportDirectory ($script:SafeComputerName + '-CompatData')
        $blocks = @()
        $panther = 'C:\$WINDOWS.~BT\Sources\Panther'
        # SilentlyContinue: Setup writes no CompatData file when it finds nothing; the verdict comes from the exit code.
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
