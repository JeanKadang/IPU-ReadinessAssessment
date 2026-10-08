# Pester 5 tests for the Register-Check bodies (issue #17).
#
# The checks run against a FAKE SERVER: after the script is loaded in library
# mode, this file defines stand-ins for every system command the checks use
# (CIM, registry, native tools, storage/network/cluster/IIS cmdlets...). They
# read from $script:Fake, a fixture describing a healthy Windows Server 2016
# VMware member server. Each test changes only what it is about.
#
# Why stand-in functions instead of Pester Mock: Mock needs the real command
# to exist, and many of these cmdlets (failover clustering, Hyper-V, IIS) are
# not installed on CI runners. Functions shadow cmdlets for the script, while
# Pester's own module code is not affected.
#
# Stand-ins for core cmdlets (Test-Path, Get-ChildItem, Get-Item, Get-Content,
# Get-ItemProperty) only fake system paths; paths under the temp folder (where
# TestDrive lives) go to the real cmdlet, so file output still works.
#
# These tests need Windows (paths are built from $env:windir).

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'The fake server deliberately shadows system cmdlets for the script under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-ins mirror the parameters the script passes to the real cmdlets.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Stand-ins return fixture objects.')]
param()

BeforeAll {
    $env:IPU_ASSESSMENT_LIBRARY_ONLY = '1'
    . (Join-Path $PSScriptRoot '..\src\Windows-IPU-Readiness-Assessment.ps1')

    # ---------------------------------------------------------------- helpers
    $script:RealRoots = @([IO.Path]::GetTempPath(), $env:TEMP, $env:TMP) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') + '\' }
    if ($env:USERPROFILE) { $script:RealRoots += (Join-Path $env:USERPROFILE 'AppData\Local\Temp') + '\' }
    function Test-RealPath {
        # Paths under the temp folder (TestDrive) are real files; everything
        # else is part of the fake server.
        param([string]$P)
        if (-not $P) { return $false }
        $roots = @($script:RealRoots)
        if ($TestDrive) { $roots += (Split-Path -Path $TestDrive -Parent).TrimEnd('\') + '\' }
        foreach ($root in $roots) { if ($P.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
        return $false
    }
    function Get-PathArg { param($Path, $LiteralPath) if ($LiteralPath) { return [string]$LiteralPath } return [string]$Path }

    # ------------------------------------------------- script helper overrides
    function Get-CimRequired {
        param([string]$Class, [string]$Filter = '', [string]$Namespace = 'root\cimv2')
        if ($script:Fake.CimThrow -contains $Class) { throw ('Simulated CIM failure: ' + $Class) }
        $key = $Class + '|' + $Filter
        if ($script:Fake.Cim.ContainsKey($key)) { return @($script:Fake.Cim[$key]) }
        if ($script:Fake.Cim.ContainsKey($Class)) { return @($script:Fake.Cim[$Class]) }
        return @()
    }
    function Get-CimSafe {
        param([string]$Class, [string]$Filter = '', [string]$Namespace = 'root\cimv2')
        try { return @(Get-CimRequired $Class $Filter $Namespace) } catch { return @() }
    }
    function Get-RegistryValueSafe {
        param([string]$Path, [string]$Name)
        $key = $Path + '|' + $Name
        if ($script:Fake.Registry.ContainsKey($key)) { return New-Object PSObject -Property @{ Exists = $true; Value = $script:Fake.Registry[$key] } }
        return New-Object PSObject -Property @{ Exists = $false; Value = $null }
    }
    function Invoke-NativeCapture {
        param([string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutSeconds = 120)
        $leaf = [IO.Path]::GetFileName($FilePath).ToLowerInvariant()
        $script:Fake.NativeCalls += [pscustomobject]@{ Exe = $leaf; Args = @($ArgumentList) }
        $spec = $script:Fake.Native[$leaf]
        if ($spec -is [scriptblock]) { $spec = & $spec $ArgumentList }
        if (-not $spec) { $spec = @{} }
        $output = [string]$spec.Output
        return [pscustomobject]@{
            ExitCode = $(if ($spec.ContainsKey('ExitCode')) { $spec.ExitCode } else { 0 })
            Output   = $output
            Lines    = @($output -split '\r?\n' | Where-Object { $_ -ne '' })
            TimedOut = [bool]$spec.TimedOut
            Error    = [string]$spec.Error
        }
    }
    function Get-InstalledApplication { return @($script:Fake.Apps) }
    function Get-SmbShare { [CmdletBinding()] param() return @($script:Fake.Shares) }
    function Get-SmbShareAccess { [CmdletBinding()] param([string]$Name) return @($script:Fake.ShareAccess[$Name]) }
    function Get-GpResultXml {
        if ($script:Fake.GpResultError) { throw $script:Fake.GpResultError }
        if ($script:Fake.GpResultXml) { return $script:Fake.GpResultXml }
        if ($script:Fake.Cim['Win32_ComputerSystem'].PartOfDomain) { return (New-FakeGpXml) }
        return (New-FakeGpXml -Workgroup)
    }
    function Get-AdComputerGroup {
        if ($script:Fake.AdError) { throw $script:Fake.AdError }
        return ,@('CORP\Domain Computers', 'CORP\Patch Ring 2', 'CORP\Servers - All')
    }
    function Get-WmiFilterQuery {
        param([string[]]$GpoGuids)
        if ($script:Fake.AdError) { throw $script:Fake.AdError }
        return @{ '{11111111-1111-1111-1111-111111111111}' = @{ Name = 'Server 2016-2022 only'; Queries = @([pscustomobject]@{ Namespace = 'root\CIMv2'; Query = "SELECT * FROM Win32_OperatingSystem WHERE Version LIKE '10.0.14393%' OR Version LIKE '10.0.20348%'" }) } }
    }
    function Get-GroupPolicyLastApplied {
        if ($script:Fake.ContainsKey('GpLastApplied')) { return $script:Fake.GpLastApplied }
        return (Get-Date).AddHours(-3)
    }
    # Synthetic gpresult /x output in the RSoP format (fictional domain).
    function New-FakeGpXml {
        param([switch]$Workgroup)
        $t = 'xmlns="http://www.microsoft.com/GroupPolicy/Types"'
        if ($Workgroup) {
            return '<?xml version="1.0" encoding="utf-16"?><Rsop xmlns="http://www.microsoft.com/GroupPolicy/Rsop"><ComputerResults><Name>SRV01</Name><Domain>WORKGROUP</Domain>' +
                '<GPO><Name>Local Group Policy</Name><Path><Identifier ' + $t + '>LocalGPO</Identifier></Path><Enabled>true</Enabled><IsValid>true</IsValid><FilterAllowed>true</FilterAllowed><AccessDenied>false</AccessDenied><Link><SOMPath>Local</SOMPath><AppliedOrder>1</AppliedOrder><Enabled>true</Enabled></Link></GPO>' +
                '</ComputerResults></Rsop>'
        }
        return '<?xml version="1.0" encoding="utf-16"?><Rsop xmlns="http://www.microsoft.com/GroupPolicy/Rsop"><ReadTime>2026-10-07T10:00:00</ReadTime><ComputerResults><Name>CORP\SRV01$</Name><Domain>corp.example.test</Domain><Site>Site-A</Site>' +
            '<SecurityGroup><SID ' + $t + '>S-1-5-21-1-2-3-515</SID><Name ' + $t + '>CORP\Domain Computers</Name></SecurityGroup>' +
            '<SecurityGroup><SID ' + $t + '>S-1-5-21-1-2-3-4001</SID><Name ' + $t + '>CORP\Patch Ring 2</Name></SecurityGroup>' +
            '<GPO><Name>Server Baseline</Name><Path><Identifier ' + $t + '>{11111111-1111-1111-1111-111111111111}</Identifier><Domain ' + $t + '>corp.example.test</Domain></Path><Enabled>true</Enabled><IsValid>true</IsValid><FilterAllowed>true</FilterAllowed><AccessDenied>false</AccessDenied><Link><SOMPath>corp.example.test/Servers</SOMPath><SOMOrder>1</SOMOrder><AppliedOrder>2</AppliedOrder><LinkOrder>1</LinkOrder><Enabled>true</Enabled><NoOverride>false</NoOverride></Link><FilterName>Server 2016-2022 only</FilterName></GPO>' +
            '<GPO><Name>Default Domain Policy</Name><Path><Identifier ' + $t + '>{31B2F340-016D-11D2-945F-00C04FB984F9}</Identifier></Path><Enabled>true</Enabled><IsValid>true</IsValid><FilterAllowed>true</FilterAllowed><AccessDenied>false</AccessDenied><Link><SOMPath>corp.example.test</SOMPath><AppliedOrder>1</AppliedOrder><Enabled>true</Enabled></Link></GPO>' +
            '<GPO><Name>Workstation Settings</Name><Path><Identifier ' + $t + '>{22222222-2222-2222-2222-222222222222}</Identifier></Path><Enabled>true</Enabled><IsValid>true</IsValid><FilterAllowed>false</FilterAllowed><AccessDenied>false</AccessDenied><Link><SOMPath>corp.example.test</SOMPath><AppliedOrder>0</AppliedOrder><Enabled>true</Enabled></Link></GPO>' +
            '<GPO><Name>Admins Only</Name><Path><Identifier ' + $t + '>{33333333-3333-3333-3333-333333333333}</Identifier></Path><Enabled>true</Enabled><IsValid>true</IsValid><FilterAllowed>true</FilterAllowed><AccessDenied>true</AccessDenied><Link><SOMPath>corp.example.test/Servers</SOMPath><AppliedOrder>0</AppliedOrder><Enabled>true</Enabled></Link></GPO>' +
            '</ComputerResults></Rsop>'
    }
    function Save-IISConfigEvidence {
        param([string]$Destination, [string]$SourceFolder = '', [bool]$Zip = $true)
        if ($script:Fake.IISCopyError) { throw $script:Fake.IISCopyError }
        return [pscustomobject]@{ Location = ($Destination + '.zip'); Folder = $Destination; Files = @('administration.config', 'applicationHost.config', 'redirection.config'); ApplicationHostSha256 = ('AB' * 32); SharedConfigPath = [string]$script:Fake.IISShared }
    }
    function Get-LocalGroupMembersBySid { param([string]$Sid) return ,@($script:Fake.Groups[$Sid]) }
    function Read-FileTail { param([string]$Path, [int]$MaxBytes = 0) return ,@($script:Fake.CbsLines) }
    function Test-CommandAvailable { param([string]$Name) return ($script:Fake.MissingCommands -notcontains $Name) }

    # ------------------------------------------------- core cmdlet stand-ins
    function Test-Path {
        [CmdletBinding()] param([Parameter(Position = 0)][string]$Path, [string]$LiteralPath, [string]$PathType)
        $p = Get-PathArg $Path $LiteralPath
        if (Test-RealPath $p) {
            if ($PathType) { return Microsoft.PowerShell.Management\Test-Path -LiteralPath $p -PathType $PathType }
            return Microsoft.PowerShell.Management\Test-Path -LiteralPath $p
        }
        if ($script:Fake.Paths.ContainsKey($p)) { return [bool]$script:Fake.Paths[$p] }
        return $false
    }
    function Get-ItemProperty {
        [CmdletBinding()] param([Parameter(Position = 0)][string]$Path, [string]$LiteralPath)
        $p = Get-PathArg $Path $LiteralPath
        if (Test-RealPath $p) { return Microsoft.PowerShell.Management\Get-ItemProperty -LiteralPath $p }
        if ($script:Fake.ItemProperty.ContainsKey($p)) { return $script:Fake.ItemProperty[$p] }
        return $null
    }
    function Get-ChildItem {
        [CmdletBinding()] param([Parameter(Position = 0)][string]$Path, [string]$LiteralPath, [string]$Filter, [switch]$File, [switch]$Recurse)
        $p = Get-PathArg $Path $LiteralPath
        if (Test-RealPath $p) {
            if ($Filter) { return Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $p -Filter $Filter }
            return Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $p
        }
        $items = @($script:Fake.Children[$p])
        if ($Filter) { $items = @($items | Where-Object { $_ -and $_.Name -like $Filter }) }
        return $items | Where-Object { $null -ne $_ }
    }
    function Get-Item {
        [CmdletBinding()] param([Parameter(Position = 0)][string]$Path, [string]$LiteralPath)
        $p = Get-PathArg $Path $LiteralPath
        if (Test-RealPath $p) { return Microsoft.PowerShell.Management\Get-Item -LiteralPath $p }
        if ($script:Fake.Items.ContainsKey($p)) { return $script:Fake.Items[$p] }
        throw (New-Object System.Management.Automation.ItemNotFoundException ('Fake item not found: ' + $p))
    }
    function Get-Content {
        [CmdletBinding()] param([Parameter(Position = 0)][string]$Path, [string]$LiteralPath, [switch]$Raw, [string]$Encoding)
        $p = Get-PathArg $Path $LiteralPath
        if (Test-RealPath $p) {
            if ($Raw) { return Microsoft.PowerShell.Management\Get-Content -LiteralPath $p -Raw }
            return Microsoft.PowerShell.Management\Get-Content -LiteralPath $p
        }
        return @($script:Fake.Content[$p])
    }
    function Get-CimInstance {
        [CmdletBinding()] param([string]$Query, [string]$ClassName, [string]$Namespace, [string]$Filter)
        if ($Query -match 'SoftwareLicensingProduct') {
            if ($script:Fake.LicensingThrow) { throw 'Simulated licensing query failure' }
            return @($script:Fake.Licensing)
        }
        return @()
    }
    function Invoke-CimMethod {
        [CmdletBinding()] param([string]$Namespace, [string]$ClassName, [string]$MethodName, $InputObject)
        if ($script:Fake.CimMethod.ContainsKey($MethodName)) { return $script:Fake.CimMethod[$MethodName] }
        throw ('Simulated: method not available ' + $MethodName)
    }
    function Get-Process { [CmdletBinding()] param() return @($script:Fake.Processes) }
    function Get-Module { [CmdletBinding()] param([Parameter(Position = 0)][string]$Name, [switch]$ListAvailable) if ($script:Fake.Modules -contains $Name) { return [pscustomobject]@{ Name = $Name } } }
    function Import-Module { [CmdletBinding()] param([Parameter(Position = 0)][string]$Name) }

    # ------------------------------------------- Windows feature cmdlets
    function Get-WindowsFeature { [CmdletBinding()] param() foreach ($k in @($script:Fake.Features.Keys)) { [pscustomobject]@{ Name = $k; Installed = [bool]$script:Fake.Features[$k] } } }
    function Get-WinSystemLocale { [CmdletBinding()] param() [pscustomobject]@{ Name = $script:Fake.SystemLocale } }
    function Get-HotFix { [CmdletBinding()] param() return @($script:Fake.HotFixes) }
    function Test-ComputerSecureChannel { [CmdletBinding()] param() if ($null -eq $script:Fake.SecureChannel) { throw 'Simulated: domain unreachable' } return $script:Fake.SecureChannel }
    function Get-ScheduledTask { [CmdletBinding()] param() return @($script:Fake.Tasks) }
    function Get-MpComputerStatus { [CmdletBinding()] param() if ($null -eq $script:Fake.Mp) { throw 'Simulated: Defender status unavailable' } return $script:Fake.Mp }
    function Get-AppLockerPolicy { [CmdletBinding()] param([switch]$Effective) return $script:Fake.AppLocker }
    function Get-BitLockerVolume { [CmdletBinding()] param([string]$MountPoint) return $script:Fake.BitLocker }
    function Confirm-SecureBootUEFI { [CmdletBinding()] param() if ($null -eq $script:Fake.SecureBoot) { throw 'Simulated: not supported' } return $script:Fake.SecureBoot }
    function Get-Tpm { [CmdletBinding()] param() return $script:Fake.Tpm }

    # ------------------------------------------- storage cmdlets
    function Get-Partition {
        [CmdletBinding()] param([string]$DriveLetter, $DiskNumber)
        $all = @($script:Fake.Partitions)
        if ($DriveLetter) {
            $hit = @($all | Where-Object { [string]$_.DriveLetter -eq $DriveLetter }) | Select-Object -First 1
            if (-not $hit) { throw ('Simulated: no partition with drive letter ' + $DriveLetter) }
            return $hit
        }
        if ($null -ne $DiskNumber) { return @($all | Where-Object { $_.DiskNumber -eq [int]$DiskNumber }) }
        return $all
    }
    function Get-Disk {
        [CmdletBinding()] param($Number)
        if ($null -ne $Number) { return @($script:Fake.Disks | Where-Object { $_.Number -eq [int]$Number }) | Select-Object -First 1 }
        return @($script:Fake.Disks)
    }
    function Get-Volume {
        [CmdletBinding()] param([Parameter(ValueFromPipeline = $true)]$InputObject)
        process {
            $key = [string]$InputObject.DiskNumber + '-' + [string]$InputObject.PartitionNumber
            if ($script:Fake.Volumes.ContainsKey($key)) { return $script:Fake.Volumes[$key] }
            throw ('Simulated: no volume for partition ' + $key)
        }
    }
    function Get-PartitionSupportedSize { [CmdletBinding()] param([string]$DriveLetter) return $script:Fake.SupportedSize }

    # ------------------------------------------- network cmdlets
    function Get-NetLbfoTeam { [CmdletBinding()] param() return @($script:Fake.LbfoTeams) }
    function Get-NetAdapter { [CmdletBinding()] param([string]$Name) return @($script:Fake.NetAdapters | Where-Object { -not $Name -or $_.Name -eq $Name }) | Select-Object -First 1 }
    function Get-VMSwitch { [CmdletBinding()] param() return @($script:Fake.VMSwitches) }
    function Get-VMSwitchTeam { [CmdletBinding()] param() return @($script:Fake.VMSwitchTeams) }
    function Get-NetRoute {
        [CmdletBinding()] param([string]$PolicyStore)
        if ($PolicyStore -eq 'PersistentStore') { return @($script:Fake.RoutesPersistent) }
        return @($script:Fake.RoutesActive)
    }
    function Get-NetTCPConnection {
        [CmdletBinding()] param([string]$State, $LocalPort)
        return @($script:Fake.Tcp | Where-Object { $null -eq $LocalPort -or $_.LocalPort -eq [int]$LocalPort })
    }
    function Get-NetUDPEndpoint { [CmdletBinding()] param() return @($script:Fake.Udp) }
    function Get-NetFirewallProfile { [CmdletBinding()] param([string]$PolicyStore) return @($script:Fake.FirewallProfiles) }
    function Get-NetFirewallRule { [CmdletBinding()] param([string]$PolicyStore) return @($script:Fake.FirewallRules) }

    # ------------------------------------------- cluster, IIS, media cmdlets
    function Get-Cluster { [CmdletBinding()] param() if (-not $script:Fake.Cluster) { throw 'Simulated: not a cluster member' } return $script:Fake.Cluster }
    function Get-ClusterNode { [CmdletBinding()] param() return @($script:Fake.ClusterNodes) }
    function Get-ClusterGroup { [CmdletBinding()] param() return @($script:Fake.ClusterGroups) }
    function Get-ClusterQuorum { [CmdletBinding()] param() return $script:Fake.ClusterQuorum }
    function Get-ClusterSharedVolume { [CmdletBinding()] param() return @($script:Fake.ClusterCsv) }
    function Get-ClusterResource { [CmdletBinding()] param() return @($script:Fake.ClusterResources) }
    function Get-Website { [CmdletBinding()] param() return @($script:Fake.Websites) }
    function Get-WebBinding { [CmdletBinding()] param([string]$Protocol) return @($script:Fake.WebBindings) }
    function Get-WindowsImage {
        [CmdletBinding()] param([string]$ImagePath, $Index)
        if ($null -ne $Index) { return @($script:Fake.Images | Where-Object { $_.ImageIndex -eq [int]$Index }) | Select-Object -First 1 }
        return @($script:Fake.Images)
    }
    function Mount-DiskImage { [CmdletBinding()] param([string]$ImagePath, [switch]$PassThru) $script:Fake.Mounted = $ImagePath; return [pscustomobject]@{ ImagePath = $ImagePath; DiskNumber = 99; PartitionNumber = 1 } }
    function Dismount-DiskImage { [CmdletBinding()] param([string]$ImagePath) $script:Fake.Dismounted = $ImagePath }

    # ------------------------------------------------------------ the server
    function New-FakeService([string]$Name, [string]$State = 'Running', [string]$StartMode = 'Auto', [string]$DisplayName = '', [int]$ProcessId = 0) {
        if (-not $DisplayName) { $DisplayName = $Name }
        [pscustomobject]@{ Name = $Name; DisplayName = $DisplayName; State = $State; StartMode = $StartMode; StartName = 'LocalSystem'; ProcessId = $ProcessId }
    }
    function New-FakeMachine {
        $windir = $env:windir
        $hosts = 'C:\Windows\System32\drivers\etc\hosts'
        if ($env:SystemRoot) { $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts' }
        $f = @{
            NativeCalls = @(); CimThrow = @(); MissingCommands = @('Get-Cluster', 'Get-VMSwitch')
            Shares = @(); ShareAccess = @{}
            SystemLocale = 'en-US'
            Cim = @{
                'Win32_OperatingSystem' = [pscustomobject]@{ Caption = 'Microsoft Windows Server 2016 Standard'; BuildNumber = '14393'; OSArchitecture = '64-bit'; OSLanguage = 1033; LastBootUpTime = (Get-Date).AddDays(-5); InstallDate = (Get-Date -Year 2019 -Month 3 -Day 1) }
                'Win32_ComputerSystem'  = [pscustomobject]@{ Manufacturer = 'VMware, Inc.'; Model = 'VMware7,1'; DomainRole = 3; PartOfDomain = $true; Domain = 'corp.example.test'; NumberOfLogicalProcessors = 4; TotalPhysicalMemory = [double]16GB; SystemSKUNumber = '' }
                'Win32_BIOS'            = [pscustomobject]@{ SMBIOSBIOSVersion = 'VMW71.00V.1'; Manufacturer = 'VMware, Inc.'; ReleaseDate = (Get-Date -Year 2020 -Month 5 -Day 1); SerialNumber = 'VMware-00 00' }
                'Win32_Processor'       = @([pscustomobject]@{ Name = 'Intel Xeon Gold'; NumberOfCores = 4; NumberOfLogicalProcessors = 4 })
                'Win32_Service'         = @(
                    (New-FakeService 'WinDefend'), (New-FakeService 'TermService' 'Running' 'Manual' 'Remote Desktop Services' 1000),
                    (New-FakeService 'VMTools' 'Running' 'Auto' 'VMware Tools'), (New-FakeService 'OpswareAgent' 'Running' 'Auto' 'Opsware Agent'),
                    (New-FakeService 'UDAgent' 'Running' 'Auto' 'Universal Discovery Agent'), (New-FakeService 'OvCtrl' 'Running' 'Auto' 'HP OpenView Ctrl Service'),
                    (New-FakeService 'ds_agent' 'Running' 'Auto' 'Trend Micro Deep Security Agent'), (New-FakeService 'LanmanServer' 'Running' 'Auto' 'Server' 4),
                    (New-FakeService 'AppSvc' 'Stopped' 'Auto' 'Example App'))
                "Win32_SystemDriver|State='Running'" = @([pscustomobject]@{ Name = 'pvscsi'; DisplayName = 'pvscsi'; PathName = '\SystemRoot\System32\drivers\pvscsii.sys' }, [pscustomobject]@{ Name = 'vmxnet3ndis6'; DisplayName = 'vmxnet3 Ethernet Adapter'; PathName = 'System32\drivers\vmxnet3.sys' })
                "Win32_LogicalDisk|DeviceID='C:'" = [pscustomobject]@{ Size = [double]100GB; FreeSpace = [double]55GB }
                'Win32_NetworkAdapterConfiguration|IPEnabled=True' = [pscustomobject]@{ Index = 1; IPAddress = @('10.20.30.40', 'fe80::1'); IPSubnet = @('255.255.255.0', '64'); DefaultIPGateway = @('10.20.30.1'); DNSServerSearchOrder = @('10.20.1.10', '10.20.1.11'); DHCPEnabled = $false; MACAddress = '00:50:56:00:00:01'; Description = 'vmxnet3 Ethernet Adapter' }
                'Win32_NetworkAdapter|Index=1' = [pscustomobject]@{ NetConnectionID = 'Ethernet0' }
                'Win32_UserAccount|LocalAccount=True' = @([pscustomobject]@{ Name = 'LocalAdmin'; SID = 'S-1-5-21-1-2-3-500'; Disabled = $false }, [pscustomobject]@{ Name = 'Guest'; SID = 'S-1-5-21-1-2-3-501'; Disabled = $true })
                'Win32_PnPSignedDriver' = @(
                    [pscustomobject]@{ DeviceName = 'Microsoft Basic Display'; DriverProviderName = 'Microsoft'; DriverVersion = '10.0'; DriverDate = (Get-Date -Year 2016 -Month 6 -Day 21); DeviceClass = 'DISPLAY'; IsSigned = $true },
                    [pscustomobject]@{ DeviceName = 'vmxnet3 Ethernet Adapter'; DriverProviderName = 'VMware, Inc.'; DriverVersion = '1.9.2'; DriverDate = (Get-Date -Year 2023 -Month 1 -Day 1); DeviceClass = 'NET'; IsSigned = $true })
                'Win32_ShadowProvider' = @([pscustomobject]@{ Name = 'Microsoft Software Shadow Copy provider 1.0'; Version = '1.0.0.7' })
                "Win32_TSGeneralSetting|TerminalName='RDP-tcp'" = [pscustomobject]@{ SSLCertificateSHA1Hash = 'AA11BB22CC33DD44EE55FF6677889900AABBCCDD' }
            }
            Registry = @{
                'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language|InstallLanguage' = '0409'
                'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language|Default' = '0409'
                'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName|ComputerName' = 'SRV01'
                'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName|ComputerName' = 'SRV01'
                'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server|fDenyTSConnections' = 0
                'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp|PortNumber' = 3389
                'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp|UserAuthentication' = 1
            }
            ItemProperty = @{
                'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' = [pscustomobject]@{ EditionID = 'ServerStandard'; InstallationType = 'Server'; UBR = 7428 }
                'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform' = [pscustomobject]@{ KeyManagementServiceName = 'kms.example.test'; KeyManagementServicePort = '1688' }
            }
            Licensing = @([pscustomobject]@{ Name = 'Windows(R), ServerStandard edition'; Description = 'Windows(R) Operating System, VOLUME_KMSCLIENT channel'; LicenseStatus = 1; PartialProductKey = 'ABCDE'; ProductKeyChannel = 'Volume:GVLK'; GracePeriodRemaining = 0 })
            LicensingThrow = $false
            CimMethod = @{}
            Apps = @(
                [pscustomobject]@{ Name = 'SA Agent'; Version = '80.0'; Publisher = 'OpenText'; InstallDate = '20240101' },
                [pscustomobject]@{ Name = 'Universal Discovery Agent (x86)'; Version = '24.1'; Publisher = 'OpenText'; InstallDate = '20240101' },
                [pscustomobject]@{ Name = 'Operations-agent'; Version = '12.25'; Publisher = 'OpenText'; InstallDate = '20240101' },
                [pscustomobject]@{ Name = 'Trend Micro Deep Security Agent'; Version = '20.0'; Publisher = 'Trend Micro'; InstallDate = '20240101' },
                [pscustomobject]@{ Name = 'Nessus Agent (x64)'; Version = '11.2'; Publisher = 'Tenable'; InstallDate = '20240101' },
                [pscustomobject]@{ Name = 'VMware Tools'; Version = '12.5.0.24276846'; Publisher = 'Broadcom Inc.'; InstallDate = '20240101' })
            Groups = @{ 'S-1-5-32-544' = @('Administrator [WinNT://SRV01/Administrator]', 'Domain Admins [WinNT://CORP/Domain Admins]'); 'S-1-5-32-555' = @() }
            Features = @{ 'FileAndStorage-Services' = $true; 'FS-FileServer' = $true; 'Web-Server' = $false; 'Failover-Clustering' = $false; 'RDS-RD-Server' = $false; 'SMTP-Server' = $false }
            Native = @{
                'fltmc.exe'    = @{ Output = "Filter Name                     Num Instances    Altitude    Frame`r`n------------------------------  -------------  ------------  -----`r`ntmeyes                                  4       328520         0`r`nWdFilter                                5       328010         0" }
                'vssadmin.exe' = @{ Output = "Writer name: 'System Writer'`r`n   Writer Id: {e8132975}`r`n   State: [1] Stable`r`n   Last error: No error`r`nWriter name: 'Registry Writer'`r`n   Writer Id: {afbab4a2}`r`n   State: [1] Stable`r`n   Last error: No error" }
                'netsh.exe'    = @{ Output = "SSL Certificate bindings:`r`n----------------------------`r`n`r`n    IP:port                      : 0.0.0.0:443`r`n    Certificate Hash             : aa11bb22`r`n" }
                'dism.exe'     = @{ ExitCode = 0; Output = "Deployment Image Servicing and Management tool`r`nNo component store corruption detected.`r`nThe operation completed successfully." }
                'sfc.exe'      = @{ ExitCode = 0; Output = 'Windows Resource Protection did not find any integrity violations.' }
                'gpresult.exe' = @{ ExitCode = 0; Output = 'RSOP data' }
                'secedit.exe'  = { param($a) $cfg = $a[[array]::IndexOf($a, '/cfg') + 1]; Microsoft.PowerShell.Management\Set-Content -LiteralPath $cfg -Value @('[Privilege Rights]', 'SeRemoteInteractiveLogonRight = *S-1-5-32-544,*S-1-5-32-555', 'SeDenyRemoteInteractiveLogonRight = *S-1-5-32-546'); @{ ExitCode = 0 } }
            }
            CbsLines = @()
            Paths = @{ $hosts = $true }
            Content = @{ $hosts = @('# hosts file', '127.0.0.1 localhost', '10.1.1.5 legacy-app.example.test   # owner: app team') }
            Children = @{
                'Cert:\LocalMachine\My' = @([pscustomobject]@{ Thumbprint = 'AA11BB22CC33DD44EE55FF6677889900AABBCCDD'; Subject = 'CN=srv01.corp.example.test'; Issuer = 'CN=Example CA'; NotAfter = (Get-Date).AddDays(365); HasPrivateKey = $true })
            }
            Items = @{}
            ItemsDummy = $null
            HotFixes = @([pscustomobject]@{ HotFixID = 'KB5000001'; InstalledOn = (Get-Date).AddDays(-60) }, [pscustomobject]@{ HotFixID = 'KB5000002'; InstalledOn = (Get-Date).AddDays(-12) })
            SecureChannel = $true
            Tasks = @(
                [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Defrag\'; TaskName = 'ScheduledDefrag'; State = 'Ready'; Principal = [pscustomobject]@{ UserId = 'SYSTEM'; GroupId = '' }; Actions = @() },
                [pscustomobject]@{ TaskPath = '\Example\'; TaskName = 'Cleanup'; State = 'Ready'; Principal = [pscustomobject]@{ UserId = 'SYSTEM'; GroupId = '' }; Actions = @([pscustomobject]@{ Execute = 'C:\Tools\cleanup.exe'; Arguments = '/q' }) })
            Mp = [pscustomobject]@{ AntivirusEnabled = $true; RealTimeProtectionEnabled = $true; AntivirusSignatureLastUpdated = (Get-Date).AddDays(-1); AMRunningMode = 'Normal' }
            AppLocker = [pscustomobject]@{ RuleCollections = @() }
            BitLocker = [pscustomobject]@{ ProtectionStatus = 'Off'; EncryptionMethod = 'None' }
            SecureBoot = $true
            Tpm = [pscustomobject]@{ TpmPresent = $true; TpmReady = $true }
            Partitions = @(
                [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 1; DriveLetter = $null; Offset = 1MB; Size = 450MB; Type = 'Recovery'; GptType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'; MbrType = 0; IsSystem = $false; AccessPaths = @() },
                [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 2; DriveLetter = $null; Offset = 451MB; Size = 100MB; Type = 'System'; GptType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'; MbrType = 0; IsSystem = $true; AccessPaths = @() },
                [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 3; DriveLetter = 'C'; Offset = 600MB; Size = [double]99GB; Type = 'Basic'; GptType = ''; MbrType = 0; IsSystem = $false; AccessPaths = @('C:\', '\\?\Volume{c}\') },
                [pscustomobject]@{ DiskNumber = 1; PartitionNumber = 1; DriveLetter = 'D'; Offset = 1MB; Size = [double]20GB; Type = 'Basic'; GptType = ''; MbrType = 0; IsSystem = $false; AccessPaths = @('D:\', '\\?\Volume{d}\') },
                [pscustomobject]@{ DiskNumber = 1; PartitionNumber = 2; DriveLetter = $null; Offset = [double]21GB; Size = [double]10GB; Type = 'Basic'; GptType = ''; MbrType = 0; IsSystem = $false; AccessPaths = @('C:\Mounts\Logs\', '\\?\Volume{l}\') })
            Disks = @([pscustomobject]@{ Number = 0; Size = [double]100GB; BusType = 'SAS'; PartitionStyle = 'GPT'; IsOffline = $false }, [pscustomobject]@{ Number = 1; Size = [double]31GB; BusType = 'SAS'; PartitionStyle = 'GPT'; IsOffline = $false })
            Volumes = @{
                '0-1' = [pscustomobject]@{ Size = 450MB; SizeRemaining = 300MB; FileSystemLabel = ''; FileSystem = 'NTFS' }
                '0-2' = [pscustomobject]@{ Size = 100MB; SizeRemaining = 70MB; FileSystemLabel = ''; FileSystem = 'FAT32' }
                '0-3' = [pscustomobject]@{ Size = [double]99GB; SizeRemaining = [double]55GB; FileSystemLabel = 'OS'; FileSystem = 'NTFS' }
                '1-1' = [pscustomobject]@{ Size = [double]20GB; SizeRemaining = [double]10GB; FileSystemLabel = 'Data'; FileSystem = 'NTFS' }
                '1-2' = [pscustomobject]@{ Size = [double]10GB; SizeRemaining = [double]9GB; FileSystemLabel = 'Logs'; FileSystem = 'NTFS' }
            }
            SupportedSize = [pscustomobject]@{ SizeMin = [double]20GB; SizeMax = [double]99GB }
            LbfoTeams = @(); NetAdapters = @(); VMSwitches = @(); VMSwitchTeams = @()
            RoutesPersistent = @([pscustomobject]@{ DestinationPrefix = '10.50.0.0/16'; NextHop = '10.20.30.1'; InterfaceIndex = 1; InterfaceAlias = 'Ethernet0'; RouteMetric = 1; Protocol = 'NetMgmt' })
            RoutesActive = @([pscustomobject]@{ DestinationPrefix = '0.0.0.0/0'; NextHop = '10.20.30.1'; InterfaceIndex = 1; InterfaceAlias = 'Ethernet0'; RouteMetric = 0; Protocol = 'NetMgmt' })
            Tcp = @([pscustomobject]@{ LocalPort = 3389; OwningProcess = 1000 }, [pscustomobject]@{ LocalPort = 445; OwningProcess = 4 }, [pscustomobject]@{ LocalPort = 50000; OwningProcess = 2000 })
            Udp = @([pscustomobject]@{ LocalPort = 123; OwningProcess = 3000 })
            Processes = @([pscustomobject]@{ Id = 4; ProcessName = 'System' }, [pscustomobject]@{ Id = 1000; ProcessName = 'svchost' }, [pscustomobject]@{ Id = 3000; ProcessName = 'svchost' })
            FirewallProfiles = @([pscustomobject]@{ Name = 'Domain'; Enabled = 'True' })
            FirewallRules = @([pscustomobject]@{ Name = 'RemoteDesktop-UserMode-In-TCP'; DisplayGroup = 'Remote Desktop'; Direction = 'Inbound'; Enabled = 'True'; Action = 'Allow' })
            Cluster = $null; ClusterNodes = @(); ClusterGroups = @(); ClusterQuorum = $null; ClusterCsv = @(); ClusterResources = @()
            Modules = @(); Websites = @(); WebBindings = @()
            Images = @()
        }
        return $f
    }

    # ---------------------------------------------------------- run a check
    $script:Fake = New-FakeMachine
    Register-AssessmentCheck
    $script:AllChecks = @($script:Checks.ToArray())
    function Invoke-TestCheck {
        param([string]$Id)
        $check = @($script:AllChecks | Where-Object { $_.Id -eq $Id }) | Select-Object -First 1
        if (-not $check) { throw ('No check with id ' + $Id) }
        $script:Results.Clear(); $script:CheckRuns.Clear()
        Invoke-Check $check
        return $script:CheckRuns[-1]
    }
    function Get-Row {
        param([string]$Area, [string]$Item)
        return ,@($script:Results | Where-Object { $_.Area -eq $Area -and $_.Item -eq $Item })
    }
    function Reset-FakeServerKeep {
        # Re-runs the baseline after a test changed the fixture, keeping the change.
        $script:Data = @{}
        $run = Invoke-TestCheck 'baseline'
        if ($run.Outcome -ne 'Completed') { throw ('Baseline did not complete: ' + $run.Message) }
    }
    function Reset-FakeServer {
        $script:Fake = New-FakeMachine
        $script:Data = @{}
        $run = Invoke-TestCheck 'baseline'
        if ($run.Outcome -ne 'Completed') { throw ('Baseline did not complete: ' + $run.Message) }
    }
}

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'Check registry' {
    It 'registers 33 checks with unique ids' {
        $script:AllChecks.Count | Should -Be 33
        @($script:AllChecks | Group-Object Id | Where-Object { $_.Count -gt 1 }).Count | Should -Be 0
    }
    It 'docs/checks.md describes every registered check' {
        $doc = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\docs\checks.md'))
        foreach ($c in $script:AllChecks) { $doc | Should -Match ('`' + $c.Id + '`') -Because ('check ' + $c.Id + ' needs an entry in docs/checks.md') }
    }
    It 'the sample result matches docs/result-schema.json' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
        $json = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\docs\samples\sample-result.json'))
        $schema = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\docs\result-schema.json'))
        Microsoft.PowerShell.Utility\Test-Json -Json $json -Schema $schema | Should -BeTrue
    }
    It 'every registered check has a test in this file' {
        $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Checks.Tests.ps1'))
        foreach ($c in $script:AllChecks) { $text | Should -Match ("Invoke-TestCheck '" + $c.Id + "'") -Because ('check ' + $c.Id + ' needs a test') }
    }
}

Describe 'Checks on a fake server' -Skip:($env:OS -ne 'Windows_NT') {
    BeforeEach { Reset-FakeServer }

    Context 'baseline' {
        It 'collects the inventory and classifies the platform' {
            (Invoke-TestCheck 'baseline').Outcome | Should -Be 'Completed'
            $script:Data.Platform.Hypervisor | Should -Be 'VMware'
            $script:Data.FilterDrivers | Should -Contain 'tmeyes'
            $script:Data.DriverNames | Should -Contain 'pvscsi'
            $script:Data.Snapshot.Features | Should -Contain 'FS-FileServer'
            (Get-Row 'ASSESSMENT' 'CollectorVersion')[0].Value | Should -Be $script:CollectorVersion
        }
        It 'fails visibly when an essential query fails' {
            $script:Fake.CimThrow = @('Win32_OperatingSystem')
            $run = Invoke-TestCheck 'baseline'
            $run.Outcome | Should -Be 'Failed'
            (Get-Row 'COLLECTOR' 'Baseline inventory')[0].Status | Should -Be 'MANUAL'
        }
    }

    Context 'upgradepath' {
        It 'a healthy 2016 Standard server has a supported path and the right media' {
            (Invoke-TestCheck 'upgradepath').Outcome | Should -Be 'Completed'
            (Get-Row 'UPGRADE_PATH' 'TargetUpgradePath')[0].Status | Should -Be 'OK'
            (Get-Row 'UPGRADE_PATH' 'InstallLanguage')[0].Status | Should -Be 'OK'
            (Get-Row 'UPGRADE_PATH' 'RecommendedInstallationImage')[0].Value | Should -Be 'Windows Server 2025 Standard (Desktop Experience) - en-US media'
            (Get-Row 'UPGRADE_PATH' 'BootFromVHD').Count | Should -Be 0
            $script:Data.SourceRelease | Should -Be '2016'
        }
        It 'a different media language is a BLOCKER' {
            $script:Fake.Registry['HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language|InstallLanguage'] = '0406'
            $TargetMediaLanguage = 'en-US'
            $null = Invoke-TestCheck 'upgradepath'
            $r = (Get-Row 'UPGRADE_PATH' 'InstallLanguage')[0]
            $r.Status | Should -Be 'BLOCKER'
            $r.Value | Should -Match 'Installed=da-DK'
        }
        It 'a server booted from VHD is a BLOCKER' {
            $script:Fake.Disks[0].BusType = 'File Backed Virtual'
            $null = Invoke-TestCheck 'upgradepath'
            (Get-Row 'UPGRADE_PATH' 'BootFromVHD')[0].Status | Should -Be 'BLOCKER'
        }
        It 'a clustered node is a BLOCKER' {
            $script:Fake.Features['Failover-Clustering'] = $true
            $script:Fake.Paths['HKLM:\Cluster'] = $true
            $script:Fake.Cim['Win32_Service'] = @($script:Fake.Cim['Win32_Service']) + @(New-FakeService 'ClusSvc')
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'upgradepath'
            (Get-Row 'UPGRADE_PATH' 'TargetUpgradePath')[0].Status | Should -Be 'BLOCKER'
            $script:Data.IsClustered | Should -BeTrue
        }
    }

    Context 'licensing' {
        It 'a licensed KMS client is OK and records the KMS host' {
            (Invoke-TestCheck 'licensing').Outcome | Should -Be 'Completed'
            (Get-Row 'LICENSING' 'CurrentActivation')[0].Status | Should -Be 'OK'
            $script:Data.KmsEndpoint | Should -Be 'kms.example.test:1688'
        }
        It 'an unlicensed server is an ACTION' {
            $script:Fake.Licensing[0].LicenseStatus = 0
            $null = Invoke-TestCheck 'licensing'
            (Get-Row 'LICENSING' 'CurrentActivation')[0].Status | Should -Be 'ACTION'
        }
        It 'an OEM licence gets a WARNING' {
            $script:Fake.Licensing[0].ProductKeyChannel = 'OEM:DM'
            $null = Invoke-TestCheck 'licensing'
            (Get-Row 'LICENSING' 'OEMLicense')[0].Status | Should -Be 'WARNING'
        }
        It 'a failed query is MANUAL, never "unlicensed"' {
            $script:Fake.LicensingThrow = $true
            $null = Invoke-TestCheck 'licensing'
            (Get-Row 'LICENSING' 'CurrentActivation')[0].Status | Should -Be 'MANUAL'
        }
    }

    Context 'pendingreboot' {
        It 'a clean server is OK with a short uptime' {
            (Invoke-TestCheck 'pendingreboot').Outcome | Should -Be 'Completed'
            (Get-Row 'WINDOWS_HEALTH' 'PendingReboot')[0].Status | Should -Be 'OK'
            (Get-Row 'WINDOWS_HEALTH' 'Uptime')[0].Status | Should -Be 'OK'
        }
        It 'a CBS reboot flag is an ACTION' {
            $script:Fake.Paths['HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'] = $true
            $null = Invoke-TestCheck 'pendingreboot'
            (Get-Row 'WINDOWS_HEALTH' 'PendingReboot')[0].Status | Should -Be 'ACTION'
        }
        It 'pending file renames are a WARNING that names the file' {
            $script:Fake.Registry['HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager|PendingFileRenameOperations'] = @('\??\C:\Program Files\Example\agent.dll', '')
            $null = Invoke-TestCheck 'pendingreboot'
            $r = (Get-Row 'WINDOWS_HEALTH' 'PendingReboot')[0]
            $r.Status | Should -Be 'WARNING'
            $r.Details | Should -Match 'C:\\Program Files\\Example\\agent\.dll'
        }
        It 'a pending computer rename and a ConfigMgr reboot are reported' {
            $script:Fake.Registry['HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName|ComputerName'] = 'SRV02'
            $script:Fake.CimMethod['DetermineIfRebootPending'] = [pscustomobject]@{ RebootPending = $true; IsHardRebootPending = $false }
            $null = Invoke-TestCheck 'pendingreboot'
            $r = (Get-Row 'WINDOWS_HEALTH' 'PendingReboot')[0]
            $r.Value | Should -Match 'SRV01 -> SRV02'
            $r.Value | Should -Match 'ConfigMgr'
        }
        It 'a long uptime is a WARNING' {
            $script:Fake.Cim['Win32_OperatingSystem'].LastBootUpTime = (Get-Date).AddDays(-120)
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'pendingreboot'
            (Get-Row 'WINDOWS_HEALTH' 'Uptime')[0].Status | Should -Be 'WARNING'
        }
    }

    Context 'patchlevel' {
        It 'a recent update is OK and names the newest KB' {
            (Invoke-TestCheck 'patchlevel').Outcome | Should -Be 'Completed'
            $r = (Get-Row 'WINDOWS_HEALTH' 'LatestUpdate')[0]
            $r.Status | Should -Be 'OK'
            $r.Value | Should -Match 'KB5000002'
        }
        It 'old updates are a WARNING' {
            $script:Fake.HotFixes = @([pscustomobject]@{ HotFixID = 'KB4000001'; InstalledOn = (Get-Date).AddDays(-200) })
            $null = Invoke-TestCheck 'patchlevel'
            (Get-Row 'WINDOWS_HEALTH' 'LatestUpdate')[0].Status | Should -Be 'WARNING'
        }
        It 'no dated history is MANUAL' {
            $script:Fake.HotFixes = @()
            $null = Invoke-TestCheck 'patchlevel'
            (Get-Row 'WINDOWS_HEALTH' 'LatestUpdate')[0].Status | Should -Be 'MANUAL'
        }
    }

    Context 'history' {
        It 'no upgrade evidence on a clean install' {
            (Invoke-TestCheck 'history').Outcome | Should -Be 'Completed'
            (Get-Row 'UPGRADE_HISTORY' 'PreviousUpgradeEvidence')[0].Status | Should -Be 'INFO'
            (Get-Row 'UPGRADE_HISTORY' 'OSInstallDate')[0].Value | Should -Be '2019-03-01'
            (Get-Row 'UPGRADE_HISTORY' 'SetupWorkingFolder').Count | Should -Be 0
        }
        It 'Source OS keys show a previous upgrade' {
            $key = [pscustomobject]@{ PSChildName = 'Source OS (Updated on 1/2/2022 03:04:05)'; PSPath = 'HKLM:\SYSTEM\Setup\Source OS (Updated on 1/2/2022 03:04:05)'; Name = 'HKEY_LOCAL_MACHINE\SYSTEM\Setup\Source OS' }
            $script:Fake.Children['HKLM:\SYSTEM\Setup'] = @($key)
            $script:Fake.ItemProperty[$key.PSPath] = [pscustomobject]@{ ProductName = 'Windows Server 2012 R2 Standard'; CurrentBuild = '9600'; InstallDate = 1400000000 }
            $null = Invoke-TestCheck 'history'
            $r = (Get-Row 'UPGRADE_HISTORY' 'PreviousUpgradeEvidence')[0]
            $r.Status | Should -Be 'WARNING'
            $r.Kind | Should -Be 'Observation'
            (Get-Row 'UPGRADE_HISTORY' $key.PSChildName)[0].Value | Should -Match '2012 R2'
        }
        It 'a leftover Setup working folder is shown' {
            $script:Fake.Paths['C:\$WINDOWS.~BT'] = $true
            $null = Invoke-TestCheck 'history'
            (Get-Row 'UPGRADE_HISTORY' 'SetupWorkingFolder').Count | Should -Be 1
        }
    }

    Context 'grouppolicy' {
        It 'a domain member: GPOs with their state, an OS-version WMI filter as WARNING, groups and the snapshot (#80)' {
            (Invoke-TestCheck 'grouppolicy').Outcome | Should -Be 'Completed'
            $baseline = (Get-Row 'GROUP_POLICY' 'GPO: Server Baseline')[0]
            $baseline.Status | Should -Be 'WARNING'
            $baseline.Value | Should -Be 'Applied - WMI filter depends on the Windows version'
            $baseline.Details | Should -Match "Query: SELECT \* FROM Win32_OperatingSystem WHERE Version LIKE '10.0.14393%'"
            (Get-Row 'GROUP_POLICY' 'GPO: Default Domain Policy')[0].Status | Should -Be 'INFO'
            (Get-Row 'GROUP_POLICY' 'GPO: Workstation Settings')[0].Value | Should -Be 'Denied (WMI filter)'
            (Get-Row 'GROUP_POLICY' 'ADGroup').Count | Should -Be 3
            (Get-Row 'GROUP_POLICY' 'GroupPolicyLastApplied')[0].Status | Should -Be 'OK'
            ($script:Data.Snapshot.Gpos -join ',') | Should -Be 'Default Domain Policy,Server Baseline'
            $script:Data.Snapshot.Groups | Should -Contain 'CORP\Patch Ring 2'
        }
        It 'a workgroup server: local policy only, no MANUAL (#80)' {
            $script:Fake.Cim['Win32_ComputerSystem'].PartOfDomain = $false
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'grouppolicy'
            (Get-Row 'GROUP_POLICY' 'GroupPolicyScope')[0].Value | Should -Be 'Workgroup server: only local policy applies'
            (Get-Row 'GROUP_POLICY' 'GPO: Local Group Policy')[0].Value | Should -Be 'Applied'
            (Get-Row 'GROUP_POLICY' 'ADGroup')[0].Value | Should -Be 'Not applicable (workgroup)'
            @($script:Results | Where-Object { $_.Area -eq 'GROUP_POLICY' -and $_.Status -eq 'MANUAL' }).Count | Should -Be 0
        }
        It 'a domain member that cannot reach AD: MANUAL, GPO list still shown, groups not in the snapshot (#80)' {
            $script:Fake.AdError = 'The server is not operational.'
            $null = Invoke-TestCheck 'grouppolicy'
            (Get-Row 'GROUP_POLICY' 'DomainLookup')[0].Status | Should -Be 'MANUAL'
            (Get-Row 'GROUP_POLICY' 'GPO: Server Baseline')[0].Status | Should -Be 'INFO'
            (Get-Row 'GROUP_POLICY' 'ADGroup').Count | Should -Be 0
            $script:Data.Snapshot.ContainsKey('Groups') | Should -BeFalse
        }
        It 'gpresult failing on a domain member: MANUAL and no GPO list in the snapshot (#80)' {
            $script:Fake.GpResultError = 'gpresult wrote no result (exit 1)'
            $null = Invoke-TestCheck 'grouppolicy'
            (Get-Row 'GROUP_POLICY' 'GroupPolicyScope')[0].Status | Should -Be 'MANUAL'
            $script:Data.Snapshot.ContainsKey('Gpos') | Should -BeFalse
        }
        It 'Group Policy not applied for longer than GroupPolicyMaxAgeDays is a WARNING (#80)' {
            $script:Fake.GpLastApplied = (Get-Date).AddDays(-30)
            $null = Invoke-TestCheck 'grouppolicy'
            (Get-Row 'GROUP_POLICY' 'GroupPolicyLastApplied')[0].Status | Should -Be 'WARNING'
        }
    }

    Context 'domain' {
        It 'a member server with a working secure channel is OK' {
            (Invoke-TestCheck 'domain').Outcome | Should -Be 'Completed'
            (Get-Row 'ACCESS' 'DomainSecureChannel')[0].Status | Should -Be 'OK'
            (Get-Row 'ACCESS' 'BuiltInAdministrator')[0].Value | Should -Be 'Name=LocalAdmin'
            (Get-Row 'ACCESS' 'LocalAdministratorsMember').Count | Should -Be 2
            (Get-Row 'DOMAIN_CONTROLLER' 'DomainController').Count | Should -Be 0
        }
        It 'reports UAC in plain words, from the registry (#75)' {
            $script:Fake.Registry['HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System|EnableLUA'] = 1
            $script:Fake.Registry['HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System|ConsentPromptBehaviorAdmin'] = 2
            $null = Invoke-TestCheck 'domain'
            $row = (Get-Row 'ACCESS' 'UAC')[0]
            $row.Status | Should -Be 'INFO'
            $row.Value | Should -Be 'On - prompt for consent on the secure desktop'
            $script:Data.UacSummary | Should -Be $row.Value
            $script:Data.Snapshot.Uac | Should -Be $row.Value
        }
        It 'a domain controller is a BLOCKER by company policy' {
            $script:Fake.Cim['Win32_ComputerSystem'].DomainRole = 5
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'domain'
            (Get-Row 'DOMAIN_CONTROLLER' 'DomainController')[0].Status | Should -Be 'BLOCKER'
        }
        It 'a broken trust is an ACTION; an untestable one is MANUAL' {
            $script:Fake.SecureChannel = $false
            $null = Invoke-TestCheck 'domain'
            (Get-Row 'ACCESS' 'DomainSecureChannel')[0].Status | Should -Be 'ACTION'
            $script:Fake.MissingCommands += 'Test-ComputerSecureChannel'
            $null = Invoke-TestCheck 'domain'
            (Get-Row 'ACCESS' 'DomainSecureChannel')[0].Status | Should -Be 'MANUAL'
        }
        It 'a workgroup server is a WARNING' {
            $script:Fake.Cim['Win32_ComputerSystem'].PartOfDomain = $false
            $script:Fake.Cim['Win32_ComputerSystem'].DomainRole = 2
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'domain'
            (Get-Row 'ACCESS' 'DomainMembership')[0].Status | Should -Be 'WARNING'
        }
    }

    Context 'rdp' {
        BeforeEach { $script:EvidenceRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')) }
        It 'a reachable server is GO and evidence is written' {
            $PolicyEvidenceRoot = $script:EvidenceRoot
            (Invoke-TestCheck 'rdp').Outcome | Should -Be 'Completed'
            (Get-Row 'RDP' 'RDPAccessReadiness')[0].Value | Should -Be 'GO'
            (Get-Row 'RDP' 'DriveRedirection')[0].Status | Should -Be 'OK'
            (Get-Row 'RDP' 'SeRemoteInteractiveLogonRight')[0].Value | Should -Match 'S-1-5-32-544'
            $script:Data.PolicyEvidence | Should -Match '\.zip$'
            $script:Data.PolicyEvidence | Should -Exist
        }
        It 'RDP disabled is NO-GO' {
            $PolicyEvidenceRoot = $script:EvidenceRoot
            $script:Fake.Registry['HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server|fDenyTSConnections'] = 1
            $null = Invoke-TestCheck 'rdp'
            $r = (Get-Row 'RDP' 'RDPAccessReadiness')[0]
            $r.Status | Should -Be 'ACTION'
            $r.Value | Should -Be 'NO-GO'
        }
        It 'NLA off and blocked drive redirection are reported' {
            $PolicyEvidenceRoot = $script:EvidenceRoot
            $script:Fake.Registry['HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp|UserAuthentication'] = 0
            $script:Fake.Registry['HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services|fDisableCdm'] = 1
            $null = Invoke-TestCheck 'rdp'
            (Get-Row 'RDP' 'NetworkLevelAuthentication')[0].Kind | Should -Be 'Observation'
            (Get-Row 'RDP' 'DriveRedirection')[0].Status | Should -Be 'WARNING'
        }
        It 'evidence disabled gives REVIEW without writing files' {
            $EnableRDPPolicyEvidence = $false
            $PolicyEvidenceRoot = $script:EvidenceRoot
            $null = Invoke-TestCheck 'rdp'
            (Get-Row 'RDP' 'RDPAccessReadiness')[0].Status | Should -Be 'MANUAL'
            $script:EvidenceRoot | Should -Not -Exist
        }
    }

    Context 'platform' {
        It 'a VMware VM is OK' {
            (Invoke-TestCheck 'platform').Outcome | Should -Be 'Completed'
            (Get-Row 'PLATFORM' 'PhysicalOrVirtual')[0].Value | Should -Be 'Virtual (VMware)'
            (Get-Row 'HARDWARE' 'BIOS').Count | Should -Be 0
        }
        It 'a cloud VM needs the provider procedure' {
            $script:Fake.Cim['Win32_ComputerSystem'].Manufacturer = 'Amazon EC2'
            $script:Fake.Cim['Win32_ComputerSystem'].Model = 'm5.large'
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'platform'
            (Get-Row 'PLATFORM' 'CloudProvider')[0].Status | Should -Be 'MANUAL'
        }
        It 'a physical server lists hardware and needs OEM validation' {
            $script:Fake.Cim['Win32_ComputerSystem'].Manufacturer = 'Dell Inc.'
            $script:Fake.Cim['Win32_ComputerSystem'].Model = 'PowerEdge R740'
            $script:Fake.Cim['Win32_NetworkAdapter'] = @([pscustomobject]@{ Name = 'Broadcom NetXtreme'; MACAddress = '00:11:22:33:44:55'; PhysicalAdapter = $true; PNPDeviceID = 'PCI\VEN_14E4' })
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'platform'
            (Get-Row 'PLATFORM' 'PhysicalOrVirtual')[0].Status | Should -Be 'MANUAL'
            (Get-Row 'HARDWARE' 'BIOS')[0].Details | Should -Match 'ReleaseDate=2020-05-01'
            (Get-Row 'HARDWARE' 'NIC: Broadcom NetXtreme').Count | Should -Be 1
        }
    }

    Context 'performance' {
        It 'enough CPU and memory is OK' {
            (Invoke-TestCheck 'performance').Outcome | Should -Be 'Completed'
            (Get-Row 'PERFORMANCE' 'LogicalProcessors')[0].Status | Should -Be 'OK'
            (Get-Row 'PERFORMANCE' 'MemoryGB')[0].Status | Should -Be 'OK'
        }
        It 'one CPU is an ACTION and little memory a WARNING' {
            $script:Fake.Cim['Win32_ComputerSystem'].NumberOfLogicalProcessors = 1
            $script:Fake.Cim['Win32_ComputerSystem'].TotalPhysicalMemory = [double]4GB
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'performance'
            (Get-Row 'PERFORMANCE' 'LogicalProcessors')[0].Status | Should -Be 'ACTION'
            (Get-Row 'PERFORMANCE' 'MemoryGB')[0].Status | Should -Be 'WARNING'
        }
    }

    Context 'cluster' {
        It 'no failover clustering feature is OK' {
            (Invoke-TestCheck 'cluster').Outcome | Should -Be 'Completed'
            (Get-Row 'CLUSTER' 'FailoverClustering')[0].Status | Should -Be 'OK'
        }
        It 'the feature without cmdlets is an ACTION' {
            $script:Fake.Features['Failover-Clustering'] = $true
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'cluster'
            (Get-Row 'CLUSTER' 'FailoverClustering')[0].Status | Should -Be 'ACTION'
        }
        It 'cluster membership is a BLOCKER and lists nodes' {
            $script:Fake.Features['Failover-Clustering'] = $true
            $script:Fake.MissingCommands = @('Get-VMSwitch')
            $script:Fake.Cluster = [pscustomobject]@{ Name = 'CL01' }
            $script:Fake.ClusterNodes = @([pscustomobject]@{ Name = 'SRV01'; State = 'Up' }, [pscustomobject]@{ Name = 'SRV02'; State = 'Up' })
            $script:Fake.ClusterQuorum = [pscustomobject]@{ QuorumType = 'NodeAndFileShareMajority'; QuorumResource = 'File Share Witness' }
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'cluster'
            (Get-Row 'CLUSTER' 'ClusterMembership')[0].Status | Should -Be 'BLOCKER'
            (Get-Row 'CLUSTER' 'Node: SRV02').Count | Should -Be 1
            (Get-Row 'CLUSTER' 'Quorum').Count | Should -Be 1
        }
    }

    Context 'storage' {
        It 'enough free space, partitions, mount points and labels' {
            (Invoke-TestCheck 'storage').Outcome | Should -Be 'Completed'
            (Get-Row 'STORAGE' 'CFreeSpace')[0].Status | Should -Be 'OK'
            (Get-Row 'STORAGE' 'PartitionAfterC')[0].Status | Should -Be 'OK'
            (Get-Row 'STORAGE' 'SystemPartition')[0].Status | Should -Be 'OK'
            (Get-Row 'STORAGE' 'RecoveryPartition')[0].Status | Should -Be 'OK'
            $disk1 = (Get-Row 'STORAGE' 'Disk1')[0].Details
            $disk1 | Should -Match 'MountedAt=C:\\Mounts\\Logs\\'
            $disk1 | Should -Match 'Label=Logs'
            $disk1 | Should -Match ':D:'
        }
        It 'low free space on C: recommends the extension size' {
            $script:Fake.Cim["Win32_LogicalDisk|DeviceID='C:'"].FreeSpace = [double]22GB
            $null = Invoke-TestCheck 'storage'
            $r = (Get-Row 'STORAGE' 'CFreeSpace')[0]
            $r.Status | Should -Be 'ACTION'
            $r.Details | Should -Be 'RequiredExpansionGB=20'
        }
        It 'a partition after C: and a full system partition are flagged' {
            $script:Fake.Partitions += [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 4; DriveLetter = $null; Offset = [double]99.6GB; Size = 500MB; Type = 'Recovery'; GptType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'; MbrType = 0; IsSystem = $false; AccessPaths = @() }
            $script:Fake.Volumes['0-4'] = [pscustomobject]@{ Size = 500MB; SizeRemaining = 100MB; FileSystemLabel = ''; FileSystem = 'NTFS' }
            $script:Fake.Volumes['0-2'].SizeRemaining = 20MB
            $null = Invoke-TestCheck 'storage'
            (Get-Row 'STORAGE' 'PartitionAfterC')[0].Status | Should -Be 'WARNING'
            @(Get-Row 'STORAGE' 'SystemPartition' | Where-Object { $_.Status -eq 'WARNING' -and $_.Kind -eq 'Finding' }).Count | Should -Be 1
            @(Get-Row 'STORAGE' 'RecoveryPartition' | Where-Object { $_.Status -eq 'WARNING' -and $_.Kind -eq 'Observation' }).Count | Should -Be 1
        }
        It 'falls back to Win32_DiskDrive without storage cmdlets' {
            $script:Fake.MissingCommands += 'Get-Disk'
            $script:Fake.Cim['Win32_DiskDrive'] = @([pscustomobject]@{ Index = 0; Size = [double]100GB; Model = 'VMware Virtual disk' })
            $null = Invoke-TestCheck 'storage'
            (Get-Row 'STORAGE' 'Disk0')[0].Details | Should -Be 'Model=VMware Virtual disk'
        }
    }

    Context 'network' {
        It 'adapters, hosts entries and static routes' {
            (Invoke-TestCheck 'network').Outcome | Should -Be 'Completed'
            (Get-Row 'NETWORK' 'Ethernet0')[0].Value | Should -Match 'IPv4=10\.20\.30\.40'
            (Get-Row 'NETWORK' 'NICTeaming')[0].Status | Should -Be 'OK'
            (Get-Row 'NETWORK_DEPENDENCY' 'HostsFile')[0].Value | Should -Be 'ActiveEntries=2'
            (Get-Row 'NETWORK_DEPENDENCY' 'StaticRoutes')[0].Status | Should -Be 'MANUAL'
            (Get-Row 'NETWORK_DEPENDENCY' 'Route 10.50.0.0/16').Count | Should -Be 1
            $script:Data.Snapshot.IPv4 | Should -Contain '10.20.30.40'
            $script:Data.Snapshot.Routes | Should -Contain '10.50.0.0/16 via 10.20.30.1'
        }
        It 'an LBFO team under a Hyper-V switch is an ACTION' {
            $script:Fake.MissingCommands = @('Get-Cluster')
            $script:Fake.LbfoTeams = @([pscustomobject]@{ Name = 'Team1'; Status = 'Up'; TeamingMode = 'SwitchIndependent'; LoadBalancingAlgorithm = 'Dynamic'; Members = @('NIC1', 'NIC2') })
            $script:Fake.NetAdapters = @([pscustomobject]@{ Name = 'Team1'; InterfaceDescription = 'Microsoft Network Adapter Multiplexor Driver' })
            $script:Fake.VMSwitches = @([pscustomobject]@{ Name = 'vSwitch'; NetAdapterInterfaceDescription = 'Microsoft Network Adapter Multiplexor Driver' })
            $null = Invoke-TestCheck 'network'
            (Get-Row 'NETWORK' 'LBFO team: Team1')[0].Value | Should -Be 'LBFO team bound to a Hyper-V virtual switch'
        }
        It 'without Get-NetRoute the routes are MANUAL' {
            $script:Fake.MissingCommands += 'Get-NetRoute'
            $null = Invoke-TestCheck 'network'
            (Get-Row 'NETWORK_DEPENDENCY' 'StaticRoutes')[0].Value | Should -Be 'Get-NetRoute unavailable'
        }
    }

    Context 'exchange' {
        It 'no Exchange gives no rows' {
            (Invoke-TestCheck 'exchange').Outcome | Should -Be 'Completed'
            $script:Results.Count | Should -Be 0
        }
        It 'Exchange services are a BLOCKER' {
            $script:Fake.Cim['Win32_Service'] = @($script:Fake.Cim['Win32_Service']) + @(New-FakeService 'MSExchangeIS')
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'exchange'
            (Get-Row 'EXCHANGE' 'ExchangeServerRole')[0].Status | Should -Be 'BLOCKER'
        }
        It 'Exchange tools without services are an ACTION' {
            $script:Fake.Registry['HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup|MsiInstallPath'] = 'C:\Program Files\Microsoft\Exchange Server\V15\'
            $null = Invoke-TestCheck 'exchange'
            (Get-Row 'EXCHANGE' 'ExchangeComponents')[0].Status | Should -Be 'ACTION'
        }
    }

    Context 'sql' {
        It 'no SQL Server gives no rows' {
            (Invoke-TestCheck 'sql').Outcome | Should -Be 'Completed'
            $script:Results.Count | Should -Be 0
        }
        It 'SQL Server 2017 is a BLOCKER for a 2025 target' {
            $root = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server'
            $script:Fake.ItemProperty[$root + '\Instance Names\SQL'] = [pscustomobject]@{ MSSQLSERVER = 'MSSQL14.MSSQLSERVER' }
            $script:Fake.ItemProperty[$root + '\MSSQL14.MSSQLSERVER\Setup'] = [pscustomobject]@{ Version = '14.0.3485.1'; Edition = 'Standard Edition' }
            $null = Invoke-TestCheck 'sql'
            $r = (Get-Row 'SQL' 'Database Engine: MSSQLSERVER')[0]
            $r.Status | Should -Be 'BLOCKER'
            $r.Recommendation | Should -Match 'Windows Server 2022'
            $script:Data.SqlSummary | Should -Be 'MSSQLSERVER=SQL Server 2017'
        }
    }

    Context 'workloads' {
        It 'roles, application workloads and removed features' {
            $script:Fake.Features['SMTP-Server'] = $true
            $script:Fake.Apps += [pscustomobject]@{ Name = 'Eclipse Temurin JDK with Hotspot 17.0.12'; Version = '17.0.12'; Publisher = 'Eclipse Adoptium'; InstallDate = '' }
            Reset-FakeServerKeep
            (Invoke-TestCheck 'workloads').Outcome | Should -Be 'Completed'
            (Get-Row 'WORKLOAD' 'File Server')[0].Status | Should -Be 'WARNING'
            (Get-Row 'WORKLOAD' 'Java runtime')[0].Status | Should -Be 'WARNING'
            (Get-Row 'FEATURE_LIFECYCLE' 'SMTP Server')[0].Status | Should -Be 'ACTION'
            (Get-Row 'ROLES' 'FS-FileServer').Count | Should -Be 1
            (Get-Row 'APPLICATIONS' 'SA Agent').Count | Should -Be 1
        }
        It 'without Get-WindowsFeature the role inventory is MANUAL' {
            $script:Fake.MissingCommands += 'Get-WindowsFeature'
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'workloads'
            (Get-Row 'ROLES' 'Inventory')[0].Status | Should -Be 'MANUAL'
        }
    }

    Context 'fileshares' {
        BeforeEach {
            $script:Fake.Shares = @(
                [pscustomobject]@{ Name = 'ADMIN$'; Path = 'C:\Windows'; Description = 'Remote Admin'; Special = $true },
                [pscustomobject]@{ Name = 'C$'; Path = 'C:\'; Description = 'Default share'; Special = $true },
                [pscustomobject]@{ Name = 'Data'; Path = 'D:\Data'; Description = 'Team data'; Special = $false },
                [pscustomobject]@{ Name = 'print$'; Path = 'C:\Windows\system32\spool\drivers'; Description = 'Printer Drivers'; Special = $false }
            )
            $script:Fake.ShareAccess = @{ 'Data' = @([pscustomobject]@{ AccountName = 'CORP\Data Owners'; AccessRight = 'Full'; AccessControlType = 'Allow' }, [pscustomobject]@{ AccountName = 'Everyone'; AccessRight = 'Read'; AccessControlType = 'Allow' }) }
        }
        It 'lists shares with path and permissions, without administrative shares, and keeps them in the snapshot (#95)' {
            $script:Fake.Features['FS-FileServer'] = $true
            Reset-FakeServerKeep
            (Invoke-TestCheck 'fileshares').Outcome | Should -Be 'Completed'
            $sum = (Get-Row 'FILE_SHARES' 'FileShares')[0]
            $sum.Status | Should -Be 'WARNING'
            $sum.Details | Should -Be 'Data'
            $row = (Get-Row 'FILE_SHARES' 'Share: Data')[0]
            $row.Value | Should -Be 'D:\Data'
            $row.Details | Should -Be 'Path=D:\Data | Description=Team data | Share permissions: CORP\Data Owners: Full; Everyone: Read'
            (Get-Row 'FILE_SHARES' 'Share: ADMIN$').Count | Should -Be 0
            (Get-Row 'FILE_SHARES' 'Share: print$').Count | Should -Be 0
            ($script:Data.Snapshot.Shares -join ',') | Should -Be 'Data'
        }
        It 'shows print$ when the Print Server role is installed (#95)' {
            $script:Fake.Features['Print-Server'] = $true
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'fileshares'
            (Get-Row 'FILE_SHARES' 'Share: print$').Count | Should -Be 1
        }
        It 'the role without shares says so (#95)' {
            $script:Fake.Features['FS-FileServer'] = $true
            $script:Fake.Shares = @($script:Fake.Shares | Where-Object { $_.Special })
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'fileshares'
            $row = (Get-Row 'FILE_SHARES' 'FileShares')[0]
            $row.Status | Should -Be 'INFO'
            $row.Details | Should -Match 'role is installed but shares nothing'
        }
        It 'no role and no shares: one INFO row (#95)' {
            $script:Fake.Features['FS-FileServer'] = $false
            $script:Fake.Shares = @($script:Fake.Shares | Where-Object { $_.Special })
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'fileshares'
            @($script:Results | Where-Object { $_.Area -eq 'FILE_SHARES' }).Count | Should -Be 1
            (Get-Row 'FILE_SHARES' 'FileShares')[0].Status | Should -Be 'INFO'
        }
        It 'missing Get-SmbShare with the role is MANUAL (#95)' {
            $script:Fake.Features['FS-FileServer'] = $true
            $script:Fake.MissingCommands = @($script:Fake.MissingCommands) + 'Get-SmbShare'
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'fileshares'
            (Get-Row 'FILE_SHARES' 'FileShares')[0].Status | Should -Be 'MANUAL'
        }
    }

    Context 'iis' {
        It 'no IIS is OK' {
            (Invoke-TestCheck 'iis').Outcome | Should -Be 'Completed'
            (Get-Row 'IIS' 'Web-Server')[0].Status | Should -Be 'OK'
        }
        It 'IIS lists its sites' {
            $script:Fake.Features['Web-Server'] = $true
            $script:Fake.Modules = @('WebAdministration')
            $binding = [pscustomobject]@{ protocol = 'https'; bindingInformation = '*:443:' }
            $script:Fake.Websites = @([pscustomobject]@{ Name = 'Default Web Site'; State = 'Started'; PhysicalPath = 'C:\inetpub\wwwroot'; Bindings = [pscustomobject]@{ Collection = @($binding) } })
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'iis'
            (Get-Row 'IIS' 'Web-Server')[0].Status | Should -Be 'WARNING'
            (Get-Row 'IIS' 'Site: Default Web Site')[0].Details | Should -Match 'https:\*:443:'
        }
        It 'IIS installed: the configuration is copied into the evidence folder (#76)' {
            $PolicyEvidenceRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:Fake.Features['Web-Server'] = $true
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'iis'
            $row = (Get-Row 'IIS' 'ConfigurationCopy')[0]
            $row.Status | Should -Be 'OK'
            $row.Value | Should -BeLike '*-IPU-IIS-*.zip'
            $row.Details | Should -Match 'applicationHost.config SHA256=(AB){32}'
            (Get-Row 'IIS' 'SharedConfiguration').Count | Should -Be 0
            (Get-Row 'IIS' 'Web-Server')[0].Recommendation | Should -Match 'appcmd.exe add backup'
        }
        It 'IIS with shared configuration is a WARNING observation (#76)' {
            $PolicyEvidenceRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:Fake.Features['Web-Server'] = $true
            $script:Fake.IISShared = '\\files.example.test\iisconfig'
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'iis'
            $row = (Get-Row 'IIS' 'SharedConfiguration')[0]
            $row.Status | Should -Be 'WARNING'
            $row.Kind | Should -Be 'Observation'
        }
        It 'a failed copy is MANUAL, not silence (#76)' {
            $PolicyEvidenceRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:Fake.Features['Web-Server'] = $true
            $script:Fake.IISCopyError = 'Access is denied'
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'iis'
            $row = (Get-Row 'IIS' 'ConfigurationCopy')[0]
            $row.Status | Should -Be 'MANUAL'
            $row.Kind | Should -Be 'Finding'
            $row.Details | Should -Match 'Access is denied'
        }
        It 'switched off: no copy, and said so (#76)' {
            $EnableIISConfigEvidence = $false
            $script:Fake.Features['Web-Server'] = $true
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'iis'
            (Get-Row 'IIS' 'ConfigurationCopy')[0].Status | Should -Be 'INFO'
        }
        It 'no IIS: nothing is copied (#76)' {
            $null = Invoke-TestCheck 'iis'
            (Get-Row 'IIS' 'ConfigurationCopy').Count | Should -Be 0
        }
    }

    Context 'rds' {
        It 'no RDS roles is OK' {
            (Invoke-TestCheck 'rds').Outcome | Should -Be 'Completed'
            (Get-Row 'RDS' 'RDSessionHost')[0].Status | Should -Be 'OK'
        }
        It 'a session host is an ACTION and shows its licensing' {
            $script:Fake.Features['RDS-RD-Server'] = $true
            $script:Fake.Cim['Win32_TerminalServiceSetting'] = [pscustomobject]@{ LicensingType = 4 }
            $script:Fake.CimMethod['GetSpecifiedLicenseServerList'] = [pscustomobject]@{ SpecifiedLSList = @('lic01.corp.example.test') }
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'rds'
            (Get-Row 'RDS' 'RDSessionHost')[0].Status | Should -Be 'ACTION'
            $lic = (Get-Row 'RDS' 'LicensingConfiguration')[0]
            $lic.Value | Should -Be 'Mode=PerUser'
            $lic.Details | Should -Match 'lic01'
        }
    }

    Context 'pki' {
        It 'certificates, the RDP certificate and HTTP.sys bindings' {
            (Invoke-TestCheck 'pki').Outcome | Should -Be 'Completed'
            (Get-Row 'CERTIFICATES' 'AA11BB22CC33DD44EE55FF6677889900AABBCCDD').Count | Should -Be 1
            (Get-Row 'CERTIFICATES' 'RDP-Tcp certificate')[0].Status | Should -Be 'OK'
            (Get-Row 'CERTIFICATES' 'HTTP.sys binding 1')[0].Value | Should -Match '0\.0\.0\.0:443'
            (Get-Row 'CERTIFICATES' 'HTTP.sys binding 2').Count | Should -Be 0
            (Get-Row 'PKI' 'CertificationAuthority').Count | Should -Be 0
        }
        It 'an expiring certificate and a CA are reported' {
            $script:Fake.Children['Cert:\LocalMachine\My'][0].NotAfter = (Get-Date).AddDays(20)
            $script:Fake.Cim['Win32_Service'] = @($script:Fake.Cim['Win32_Service']) + @(New-FakeService 'CertSvc')
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'pki'
            (Get-Row 'CERTIFICATES' 'Expiring: AA11BB22CC33DD44EE55FF6677889900AABBCCDD')[0].Kind | Should -Be 'Observation'
            (Get-Row 'PKI' 'CertificationAuthority')[0].Status | Should -Be 'ACTION'
        }
        It 'an IIS binding whose certificate is missing is an ACTION' {
            $script:Fake.Features['Web-Server'] = $true
            $script:Fake.Modules = @('WebAdministration')
            $script:Fake.WebBindings = @([pscustomobject]@{ bindingInformation = '*:443:'; certificateHash = 'FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000'; certificateStoreName = 'My' })
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'pki'
            (Get-Row 'CERTIFICATES' 'IIS https *:443:')[0].Status | Should -Be 'ACTION'
        }
        It 'finds an IIS certificate in the WebHosting store' {
            $script:Fake.Features['Web-Server'] = $true
            $script:Fake.Modules = @('WebAdministration')
            $script:Fake.Children['Cert:\LocalMachine\WebHosting'] = @([pscustomobject]@{ Thumbprint = 'BB22000000000000000000000000000000000000'; Subject = 'CN=www.example.test'; Issuer = 'CN=Example CA'; NotAfter = (Get-Date).AddDays(300); HasPrivateKey = $true })
            $script:Fake.WebBindings = @([pscustomobject]@{ bindingInformation = '*:443:www.example.test'; certificateHash = 'BB22000000000000000000000000000000000000'; certificateStoreName = 'WebHosting' })
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'pki'
            (Get-Row 'CERTIFICATES' 'IIS https *:443:www.example.test')[0].Status | Should -Be 'OK'
        }
    }

    Context 'agents' {
        It 'finds all three OpenText agents and their services' {
            (Invoke-TestCheck 'agents').Outcome | Should -Be 'Completed'
            (Get-Row 'AGENTS' 'OpenText Server Automation Agent')[0].Value | Should -Be 'SA Agent'
            (Get-Row 'AGENTS' 'OpenText Operations Agent service')[0].Status | Should -Be 'OK'
            (Get-Row 'AGENTS' 'OpenText Universal Discovery Agent service')[0].Status | Should -Be 'OK'
        }
        It 'a missing agent is MANUAL and a stopped one a WARNING' {
            $script:Fake.Apps = @($script:Fake.Apps | Where-Object { $_.Name -ne 'Operations-agent' })
            $services = @($script:Fake.Cim['Win32_Service'] | Where-Object { $_.Name -ne 'OvCtrl' })
            ($services | Where-Object { $_.Name -eq 'UDAgent' }).State = 'Stopped'
            $script:Fake.Cim['Win32_Service'] = $services
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'agents'
            (Get-Row 'AGENTS' 'OpenText Operations Agent')[0].Status | Should -Be 'MANUAL'
            (Get-Row 'AGENTS' 'OpenText Universal Discovery Agent service')[0].Status | Should -Be 'WARNING'
        }
    }

    Context 'antivirus' {
        It 'Defender, a third-party EDR and security tools' {
            (Invoke-TestCheck 'antivirus').Outcome | Should -Be 'Completed'
            (Get-Row 'ANTIVIRUS' 'Microsoft Defender Antivirus')[0].Status | Should -Be 'OK'
            (Get-Row 'ANTIVIRUS' 'Trend Micro Deep Security Agent (Server & Workload Protection)')[0].Status | Should -Be 'WARNING'
            (Get-Row 'SECURITY' 'Tenable Nessus agent')[0].Status | Should -Be 'WARNING'
            (Get-Row 'SECURITY' 'Tenable Nessus agent')[0].Kind | Should -Be 'Observation'   # no driver (#78)
            (Get-Row 'ANTIVIRUS' 'EndpointProtection').Count | Should -Be 0
            (Get-Row 'SECURITY' 'FileSystemFilterDrivers')[0].Details | Should -Match 'tmeyes'
        }
        It 'no protection at all is MANUAL' {
            $script:Fake.Apps = @($script:Fake.Apps | Where-Object { $_.Name -notmatch 'Trend' })
            $script:Fake.Cim['Win32_Service'] = @($script:Fake.Cim['Win32_Service'] | Where-Object { $_.Name -notin @('WinDefend', 'ds_agent') })
            $script:Fake.Native['fltmc.exe'] = @{ Output = '' }
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'antivirus'
            (Get-Row 'ANTIVIRUS' 'EndpointProtection')[0].Status | Should -Be 'MANUAL'
        }
        It 'an unreadable Defender status is explained, not treated as absent' {
            $script:Fake.Mp = $null
            $null = Invoke-TestCheck 'antivirus'
            (Get-Row 'ANTIVIRUS' 'Microsoft Defender Antivirus')[0].Details | Should -Match 'Status not readable'
        }
        It 'lists the installed products with their version for the summary (#74)' {
            $null = Invoke-TestCheck 'antivirus'
            $script:Data.EndpointProducts | Should -Contain 'Trend Micro Deep Security Agent (Server & Workload Protection) 20.0'
        }
        It 'an unused built-in Defender for Endpoint sensor is INFO, not a warning (#74)' {
            $script:Fake.Cim['Win32_Service'] = @($script:Fake.Cim['Win32_Service']) + @(New-FakeService 'Sense' 'Stopped' 'Manual' 'Windows Defender Advanced Threat Protection Service')
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'antivirus'
            $row = (Get-Row 'ANTIVIRUS' 'Microsoft Defender for Endpoint (EDR sensor)')[0]
            $row.Status | Should -Be 'INFO'
            $row.Value | Should -Match 'not onboarded'
            ($script:Data.EndpointProducts -join ',') | Should -Not -Match 'Defender for Endpoint'
        }
        It 'an onboarded Defender for Endpoint sensor is a WARNING (#74)' {
            $script:Fake.Cim['Win32_Service'] = @($script:Fake.Cim['Win32_Service']) + @(New-FakeService 'Sense' 'Running' 'Auto' 'Windows Defender Advanced Threat Protection Service')
            $script:Fake.Registry['HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status|OnboardingState'] = 1
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'antivirus'
            (Get-Row 'ANTIVIRUS' 'Microsoft Defender for Endpoint (EDR sensor)')[0].Status | Should -Be 'WARNING'
        }
        It 'BitLocker on C: is a WARNING' {
            $script:Fake.BitLocker = [pscustomobject]@{ ProtectionStatus = 'On'; EncryptionMethod = 'XtsAes256' }
            $null = Invoke-TestCheck 'antivirus'
            (Get-Row 'SECURITY' 'BitLocker C:')[0].Status | Should -Be 'WARNING'
        }
    }

    Context 'backup' {
        It 'healthy VSS writers and provider' {
            (Invoke-TestCheck 'backup').Outcome | Should -Be 'Completed'
            (Get-Row 'BACKUP' 'VSS writer: System Writer')[0].Status | Should -Be 'OK'
            (Get-Row 'BACKUP' 'VSSWriters').Count | Should -Be 0
            (Get-Row 'BACKUP' 'GuestBackupAgent')[0].Status | Should -Be 'INFO'
        }
        It 'a failed writer is an ACTION' {
            $script:Fake.Native['vssadmin.exe'] = @{ Output = "Writer name: 'SqlServerWriter'`r`n   State: [8] Failed`r`n   Last error: Retryable error" }
            $null = Invoke-TestCheck 'backup'
            (Get-Row 'BACKUP' 'VSSWriters')[0].Status | Should -Be 'ACTION'
        }
        It 'unreadable VSS state is MANUAL' {
            $script:Fake.Native['vssadmin.exe'] = @{ TimedOut = $true; ExitCode = $null; Output = '' }
            $null = Invoke-TestCheck 'backup'
            (Get-Row 'BACKUP' 'VSSWriters')[0].Status | Should -Be 'MANUAL'
        }
        It 'recognises a backup agent' {
            $script:Fake.Apps += [pscustomobject]@{ Name = 'Commvault ContentStore'; Version = '11.32'; Publisher = 'Commvault'; InstallDate = '' }
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'backup'
            (Get-Row 'BACKUP' 'Commvault').Count | Should -Be 1
        }
    }

    Context 'services' {
        It 'counts automatic services and lists them' {
            (Invoke-TestCheck 'services').Outcome | Should -Be 'Completed'
            $r = (Get-Row 'SERVICES' 'AutomaticServices')[0]
            $r.Value | Should -Be 'Total=8'
            $r.Details | Should -Be 'NotRunning=1'
            (Get-Row 'SERVICES' 'AppSvc')[0].Details | Should -Match 'State=Stopped'
        }
    }

    Context 'vmware' {
        It 'current VMware Tools are OK and checklist items are added' {
            (Invoke-TestCheck 'vmware').Outcome | Should -Be 'Completed'
            (Get-Row 'VMWARE' 'VMwareTools')[0].Status | Should -Be 'OK'
            (Get-Row 'VMWARE' 'Driver: pvscsi').Count | Should -Be 1
            (Get-Row 'CHECKLIST' 'VMware host version')[0].Kind | Should -Be 'Checklist'
        }
        It 'old VMware Tools are an ACTION for 2025' {
            ($script:Fake.Apps | Where-Object { $_.Name -eq 'VMware Tools' }).Version = '12.3.5.22544099'
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'vmware'
            (Get-Row 'VMWARE' 'VMwareTools')[0].Status | Should -Be 'ACTION'
        }
        It 'does not apply to other platforms' {
            $script:Fake.Cim['Win32_ComputerSystem'].Manufacturer = 'Microsoft Corporation'
            $script:Fake.Cim['Win32_ComputerSystem'].Model = 'Virtual Machine'
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'vmware'
            (Get-Row 'VMWARE' 'Applicability')[0].Status | Should -Be 'INFO'
        }
    }

    Context 'drivers' {
        It 'lists non-Microsoft drivers and flags unsigned ones' {
            $script:Fake.Cim['Win32_PnPSignedDriver'] = @($script:Fake.Cim['Win32_PnPSignedDriver']) + @([pscustomobject]@{ DeviceName = 'Example Filter'; DriverProviderName = 'Example Corp'; DriverVersion = '1.0'; DriverDate = '20180101000000.000000-000'; DeviceClass = 'SYSTEM'; IsSigned = $false })
            (Invoke-TestCheck 'drivers').Outcome | Should -Be 'Completed'
            (Get-Row 'DRIVERS' 'Device: vmxnet3 Ethernet Adapter')[0].Details | Should -Match 'Date=2023-01-01'
            (Get-Row 'DRIVERS' 'Device: Microsoft Basic Display').Count | Should -Be 0
            (Get-Row 'DRIVERS' 'UnsignedDrivers')[0].Details | Should -Be 'Example Filter'
            (Get-Row 'DRIVERS' 'Summary')[0].Value | Should -Match 'NonMicrosoftDevices=2'
        }
    }

    Context 'ports' {
        It 'lists listening ports with their owner, without dynamic ports' {
            (Invoke-TestCheck 'ports').Outcome | Should -Be 'Completed'
            (Get-Row 'PORTS' 'TCP:3389')[0].Value | Should -Be 'Service TermService'
            (Get-Row 'PORTS' 'TCP:445')[0].Value | Should -Match 'LanmanServer'
            (Get-Row 'PORTS' 'UDP:123')[0].Value | Should -Be 'Process svchost'
            (Get-Row 'PORTS' 'TCP:50000').Count | Should -Be 0
            $script:Data.Snapshot.Ports | Should -Contain 'TCP:3389'
        }
    }

    Context 'tasks' {
        It 'skips Microsoft tasks and flags tasks with stored credentials' {
            $script:Fake.Tasks += [pscustomobject]@{ TaskPath = '\Example\'; TaskName = 'Nightly export'; State = 'Ready'; Principal = [pscustomobject]@{ UserId = 'CORP\svc_batch'; GroupId = '' }; Actions = @([pscustomobject]@{ Execute = 'C:\Tools\export.cmd'; Arguments = '' }) }
            (Invoke-TestCheck 'tasks').Outcome | Should -Be 'Completed'
            (Get-Row 'TASKS' '\Microsoft\Windows\Defrag\ScheduledDefrag').Count | Should -Be 0
            (Get-Row 'TASKS' '\Example\Cleanup')[0].Value | Should -Be 'RunAs=SYSTEM'
            (Get-Row 'TASKS' 'TasksWithNamedAccounts')[0].Details | Should -Match 'svc_batch'
            $script:Data.Snapshot.Tasks | Should -Contain '\Example\Nightly export'
        }
    }

    Context 'checklist' {
        It 'adds the standard change steps as checklist items' {
            (Invoke-TestCheck 'checklist').Outcome | Should -Be 'Completed'
            @($script:Results | Where-Object { $_.Kind -eq 'Checklist' }).Count | Should -Be 6
            (Get-Row 'CHECKLIST' 'Backup and fallback')[0].Recommendation | Should -Match 'VMware'
        }
    }

    Context 'dism' {
        BeforeEach { $script:SlowSecondsLeft = 3000 }
        It 'a healthy component store is OK' {
            (Invoke-TestCheck 'dism').Outcome | Should -Be 'Completed'
            (Get-Row 'WINDOWS_HEALTH' 'DISM ScanHealth')[0].Status | Should -Be 'OK'
            @($script:Fake.NativeCalls | Where-Object { $_.Exe -eq 'dism.exe' })[0].Args | Should -Contain '/ScanHealth'
        }
        It 'truncated output with no verdict is MANUAL, never OK' {
            $script:Fake.Native['dism.exe'] = @{ ExitCode = 0; Output = "Deployment Image Servicing and Management tool`r`nVersion: 10.0.14393.0`r`n[=====      20.0%" }
            $null = Invoke-TestCheck 'dism'
            (Get-Row 'WINDOWS_HEALTH' 'DISM ScanHealth')[0].Status | Should -Be 'MANUAL'
        }
        It 'a repairable store is an ACTION' {
            $script:Fake.Native['dism.exe'] = @{ ExitCode = 0; Output = 'The component store is repairable.' }
            $null = Invoke-TestCheck 'dism'
            (Get-Row 'WINDOWS_HEALTH' 'DISM ScanHealth')[0].Status | Should -Be 'ACTION'
        }
        It 'a timeout is MANUAL and marks the run TimedOut' {
            $script:Fake.Native['dism.exe'] = @{ TimedOut = $true; ExitCode = $null; Output = '' }
            (Invoke-TestCheck 'dism').Outcome | Should -Be 'TimedOut'
            (Get-Row 'WINDOWS_HEALTH' 'DISM ScanHealth')[0].Status | Should -Be 'MANUAL'
        }
        It 'can be skipped by configuration' {
            $RunDISMScanHealth = $false
            (Invoke-TestCheck 'dism').Outcome | Should -Be 'Skipped'
            @($script:Fake.NativeCalls | Where-Object { $_.Exe -eq 'dism.exe' }).Count | Should -Be 0
        }
    }

    Context 'sfc' {
        BeforeEach { $script:SlowSecondsLeft = 3000 }
        It 'clean English output is OK' {
            (Invoke-TestCheck 'sfc').Outcome | Should -Be 'Completed'
            (Get-Row 'WINDOWS_HEALTH' 'SFC VerifyOnly')[0].Status | Should -Be 'OK'
        }
        It 'truncated localized output without CBS evidence is MANUAL' {
            $script:Fake.Native['sfc.exe'] = @{ ExitCode = 0; Output = 'Systemscanningen startes. Denne proces tager noget tid.' }
            $null = Invoke-TestCheck 'sfc'
            (Get-Row 'WINDOWS_HEALTH' 'SFC VerifyOnly')[0].Status | Should -Be 'MANUAL'
        }
        It 'localized output is classified from CBS.log lines of this run' {
            $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            $script:Fake.Native['sfc.exe'] = @{ ExitCode = 0; Output = 'Windows-ressourcebeskyttelse fandt ingen problemer.' }
            $script:Fake.CbsLines = @('2001-01-01 00:00:00, Info  CSI  00000001 [SR] Verify complete', ($now + ', Info  CSI  00000099 [SR] Verify complete'))
            $null = Invoke-TestCheck 'sfc'
            $r = (Get-Row 'WINDOWS_HEALTH' 'SFC VerifyOnly')[0]
            $r.Status | Should -Be 'OK'
            $r.Value | Should -Match 'Basis=CBS.log'
        }
        It 'a timeout is MANUAL' {
            $script:Fake.Native['sfc.exe'] = @{ TimedOut = $true; ExitCode = $null; Output = '' }
            (Invoke-TestCheck 'sfc').Outcome | Should -Be 'TimedOut'
        }
    }

    Context 'compatscan' {
        BeforeEach {
            $script:SlowSecondsLeft = 6000
            $script:Media = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $script:Media 'sources') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:Media 'setup.exe') -Value 'fake'
            Set-Content -LiteralPath (Join-Path $script:Media 'sources\install.wim') -Value 'fake'
            $script:Fake.Images = @(
                [pscustomobject]@{ ImageIndex = 1; ImageName = 'Windows Server 2025 Standard'; EditionId = 'ServerStandard'; InstallationType = 'Server Core'; Languages = @('en-US') },
                [pscustomobject]@{ ImageIndex = 2; ImageName = 'Windows Server 2025 Standard (Desktop Experience)'; EditionId = 'ServerStandard'; InstallationType = 'Server'; Languages = @('en-US') })
            $script:Data.InstallLanguage = 'en-US'
            $script:Out = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        }
        It 'is skipped when no media is configured' {
            (Invoke-TestCheck 'compatscan').Outcome | Should -Be 'Skipped'
            (Get-Row 'COMPAT_SCAN' 'SetupCompatibilityScan')[0].Status | Should -Be 'INFO'
        }
        It 'a clean scan with the matching image is OK' {
            $TargetMediaPath = $script:Media
            $ReportDirectory = $script:Out
            $script:Fake.Native['setup.exe'] = @{ ExitCode = -1047526896 }
            (Invoke-TestCheck 'compatscan').Outcome | Should -Be 'Completed'
            (Get-Row 'COMPAT_SCAN' 'MatchingImage')[0].Value | Should -Be 'Index 2'
            (Get-Row 'COMPAT_SCAN' 'SetupCompatibilityScan')[0].Status | Should -Be 'OK'
            $setupArgs = @($script:Fake.NativeCalls | Where-Object { $_.Exe -eq 'setup.exe' })[0].Args
            $setupArgs -join ' ' | Should -Match '/compat scanonly /imageindex 2'
        }
        It 'a hard block is an ACTION that names the blocking item' {
            $TargetMediaPath = $script:Media
            $ReportDirectory = $script:Out
            $xml = Join-Path $TestDrive ('CompatData_' + [guid]::NewGuid().ToString('N') + '.xml')
            Set-Content -LiteralPath $xml -Value '<CompatReport><Programs><Program Name="Example Agent 1.0"><CompatibilityInfo BlockingType="Hard" /></Program></Programs></CompatReport>'
            $script:Fake.Children['C:\$WINDOWS.~BT\Sources\Panther'] = @(Microsoft.PowerShell.Management\Get-Item -LiteralPath $xml)
            $script:Fake.Native['setup.exe'] = @{ ExitCode = -1047526904 }
            $null = Invoke-TestCheck 'compatscan'
            $r = (Get-Row 'COMPAT_SCAN' 'SetupCompatibilityScan')[0]
            $r.Status | Should -Be 'ACTION'
            $r.Details | Should -Match 'Hard blocks: Example Agent 1.0'
            Join-Path $script:Out ($script:SafeComputerName + '-CompatData') | Should -Exist
        }
        It 'media without a matching image is an ACTION' {
            $TargetMediaPath = $script:Media
            $ReportDirectory = $script:Out
            $script:Fake.Images = @([pscustomobject]@{ ImageIndex = 1; ImageName = 'Windows Server 2025 Datacenter'; EditionId = 'ServerDatacenter'; InstallationType = 'Server'; Languages = @('en-US') })
            $null = Invoke-TestCheck 'compatscan'
            (Get-Row 'COMPAT_SCAN' 'MatchingImage')[0].Status | Should -Be 'ACTION'
            @($script:Fake.NativeCalls | Where-Object { $_.Exe -eq 'setup.exe' }).Count | Should -Be 0
        }
        It 'media in another language is a BLOCKER' {
            $TargetMediaPath = $script:Media
            $ReportDirectory = $script:Out
            $script:Data.InstallLanguage = 'da-DK'
            $script:Fake.Native['setup.exe'] = @{ ExitCode = -1047526908 }
            $null = Invoke-TestCheck 'compatscan'
            (Get-Row 'COMPAT_SCAN' 'MediaLanguage')[0].Status | Should -Be 'BLOCKER'
        }
    }
}
