# The fake server for the check tests in this folder (issue #17), dot-sourced
# by each *.Tests.ps1 here in its BeforeAll. Not a test file itself.
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
# The strict-mode finder (#256, build/Invoke-CiTests.ps1 -StrictModeFinder)
# loads the code under Set-StrictMode. Normal runs and production never do.
if ($env:IPU_TEST_STRICT_MODE) { Set-StrictMode -Version $env:IPU_TEST_STRICT_MODE }
$env:IPU_ASSESSMENT_LIBRARY_ONLY = '1'
. (Join-Path $PSScriptRoot '..\..\src\Windows-IPU-Readiness-Assessment.ps1')
# Set by the main block in a real run, which library mode skips; the
# baseline reads it (needed under the strict-mode finder, #256).
$script:Is32BitHost = $false
$script:OutputFolderState = $null   # the baseline then assumes 'Existing', as in tests until now
# Unelevated runs (#126): keep the current user on the folders the tests
# restrict, so they can be used and cleaned up. Elevated runs are as before.
if ($env:OS -eq 'Windows_NT') {
    $me = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($me)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { $script:ExtraRestrictedSids = @($me.User.Value) }
}

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
function Write-FakeFailure {
    # A fixture-driven failure for a stand-in cmdlet. Write-Error (not throw), like the CDXML cmdlets:
    # -ErrorAction SilentlyContinue hides it, -ErrorAction Stop raises it (#242).
    param([string]$Name)
    $mode = $script:Fake.Fail[$Name]
    if (-not $mode) { return $false }
    if ($mode -eq 'NotFound') { Write-Error ('Simulated: nothing found by ' + $Name) -Category ObjectNotFound }
    else { Write-Error ('Simulated failure of ' + $Name) -Category InvalidOperation }
    return $true
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
    # Indexers, not dot access: a key the fixture leaves out is $null, also
    # under the strict-mode finder (#256).
    $output = [string]$spec['Output']
    return [pscustomobject]@{
        ExitCode = $(if ($spec.ContainsKey('ExitCode')) { $spec['ExitCode'] } else { 0 })
        Output   = $output
        Lines    = @($output -split '\r?\n' | Where-Object { $_ -ne '' })
        TimedOut = [bool]$spec['TimedOut']
        StillRunning = [bool]$spec['StillRunning']
        Error    = [string]$spec['Error']
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
function Get-GpoListRegistryEntry {
    if ($script:Fake.GpoListError) { throw $script:Fake.GpoListError }
    return ,@($script:Fake.GpoList | Where-Object { $_ })
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
function Get-AdComputerDn {
    if ($script:Fake.AdError) { throw $script:Fake.AdError }
    return 'CN=SRV01,OU=Web,OU=Servers,DC=corp,DC=example,DC=test'
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
function Save-NetworkEvidence {
    param([string]$Destination, [bool]$Zip = $true, [int]$TimeoutSeconds = 60)
    if ($script:Fake.NetEvidenceError) { throw $script:Fake.NetEvidenceError }
    return [pscustomobject]@{ Location = ($Destination + '.zip'); Folder = $Destination; Files = @('ipconfig-all.txt', 'route-print.txt', 'netsh-ipv4-show-config.txt', 'netsh-interface-dump.txt'); Failed = @($script:Fake.NetEvidenceFailed | Where-Object { $_ }) }
}
function Initialize-EvidenceFolder {
    # Real folders only under the test drive; the default root stays fake.
    param([string]$Topic)
    $p = Get-EvidenceFolderPath $EvidenceRoot $Topic $PolicyEvidenceRoot
    if (Test-RealPath $p) { $null = Microsoft.PowerShell.Management\New-Item -ItemType Directory -Path $p -Force }
    return $p
}
function Read-ReAgentXml { return [string]$script:Fake['ReAgentXml'] }
function Get-PrinterInventory {
    if ($script:Fake.PrintInvError) { throw $script:Fake.PrintInvError }
    if ($script:Fake.PrintInv) { return $script:Fake.PrintInv }
    return [pscustomobject]@{ Printers = @([pscustomobject]@{ Name = 'Microsoft Print to PDF'; ShareName = ''; Shared = $false; Published = $false; DriverName = 'Microsoft Print To PDF'; PortName = 'PORTPROMPT:' }); Ports = @(); Drivers = @(); Source = 'Get-Printer' }
}
function Get-PrintMonitorInventory { return ,@($script:Fake.PrintComponents | Where-Object { $_ }) }
function Get-PrintDriverStoreSize { if ($script:Fake.ContainsKey('DriverStoreBytes')) { return [long]$script:Fake.DriverStoreBytes }; return [long]200MB }
function Get-LocalGroupMembersBySid { param([string]$Sid) return ,@($script:Fake.Groups[$Sid]) }
function Read-FileTail { param([string]$Path, [int]$MaxBytes = 0) return ,@($script:Fake.CbsLines) }
function Test-CommandAvailable { param([string]$Name) return ($script:Fake.MissingCommands -notcontains $Name) }

# ------------------------------------------------- core cmdlet stand-ins
function Test-Path {
    [CmdletBinding()] param([Parameter(Position = 0)][string]$Path, [string]$LiteralPath, [string]$PathType)
    # Like Windows PowerShell 4.0/5.1, refuse an empty -LiteralPath (#150).
    if ($PSBoundParameters.ContainsKey('LiteralPath') -and $LiteralPath -eq '') { throw 'Cannot bind argument to parameter ''LiteralPath'' because it is an empty string.' }
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
    if (Write-FakeFailure ('Get-ChildItem:' + $p)) { return }
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
function Get-WindowsFeature { [CmdletBinding()] param() if ($script:Fake.FeaturesThrow) { throw 'Simulated: ServerManager provider failed' } foreach ($k in @($script:Fake.Features.Keys)) { [pscustomobject]@{ Name = $k; Installed = [bool]$script:Fake.Features[$k] } } }
function Get-WinSystemLocale { [CmdletBinding()] param() [pscustomobject]@{ Name = $script:Fake.SystemLocale } }
function Get-HotFix { [CmdletBinding()] param() return @($script:Fake.HotFixes) }
function Test-ComputerSecureChannel { [CmdletBinding()] param() if ($null -eq $script:Fake.SecureChannel) { throw 'Simulated: domain unreachable' } return $script:Fake.SecureChannel }
function Get-ScheduledTask { [CmdletBinding()] param() return @($script:Fake.Tasks) }
function Get-MpComputerStatus { [CmdletBinding()] param() if ($null -eq $script:Fake.Mp) { throw 'Simulated: Defender status unavailable' } return $script:Fake.Mp }
function Get-AppLockerPolicy { [CmdletBinding()] param([switch]$Effective) if (Write-FakeFailure 'Get-AppLockerPolicy') { return } return $script:Fake.AppLocker }
function Get-BitLockerVolume { [CmdletBinding()] param([string]$MountPoint) if (Write-FakeFailure 'Get-BitLockerVolume') { return } return $script:Fake.BitLocker }
function Confirm-SecureBootUEFI { [CmdletBinding()] param() if ($script:Fake.Fail['Confirm-SecureBootUEFI']) { throw 'Simulated: access denied' } if ($null -eq $script:Fake.SecureBoot) { throw (New-Object System.PlatformNotSupportedException('Cmdlet not supported on this platform: 0xC0000002')) } return $script:Fake.SecureBoot }
function Get-Tpm { [CmdletBinding()] param() if (Write-FakeFailure 'Get-Tpm') { return } return $script:Fake.Tpm }

# ------------------------------------------- storage cmdlets
function Get-Partition {
    [CmdletBinding()] param([string]$DriveLetter, $DiskNumber)
    if ($null -ne $DiskNumber -and (Write-FakeFailure 'Get-Partition')) { return }
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
function Get-NetLbfoTeam { [CmdletBinding()] param() if (Write-FakeFailure 'Get-NetLbfoTeam') { return } return @($script:Fake.LbfoTeams) }
function Get-NetAdapter { [CmdletBinding()] param([string]$Name) return @($script:Fake.NetAdapters | Where-Object { -not $Name -or $_.Name -eq $Name }) | Select-Object -First 1 }
function Get-VMSwitch { [CmdletBinding()] param() return @($script:Fake.VMSwitches) }
function Get-VMSwitchTeam { [CmdletBinding()] param() return @($script:Fake.VMSwitchTeams) }
function Get-NetRoute {
    [CmdletBinding()] param([string]$PolicyStore)
    if (Write-FakeFailure 'Get-NetRoute') { return }
    if ($PolicyStore -eq 'PersistentStore') { return @($script:Fake.RoutesPersistent) }
    return @($script:Fake.RoutesActive)
}
function Get-NetTCPConnection {
    [CmdletBinding()] param([string]$State, $LocalPort)
    if (Write-FakeFailure 'Get-NetTCPConnection') { return }
    return @($script:Fake.Tcp | Where-Object { $null -eq $LocalPort -or $_.LocalPort -eq [int]$LocalPort })
}
function Get-NetUDPEndpoint { [CmdletBinding()] param() if (Write-FakeFailure 'Get-NetUDPEndpoint') { return } return @($script:Fake.Udp) }
function Get-NetFirewallProfile { [CmdletBinding()] param([string]$PolicyStore) return @($script:Fake.FirewallProfiles) }
function Get-NetFirewallRule { [CmdletBinding()] param([string]$PolicyStore) return @($script:Fake.FirewallRules) }

# ------------------------------------------- cluster, IIS, media cmdlets
function Get-Cluster { [CmdletBinding()] param() if (-not $script:Fake.Cluster) { throw 'Simulated: not a cluster member' } return $script:Fake.Cluster }
function Get-ClusterNode { [CmdletBinding()] param() if (Write-FakeFailure 'Get-ClusterNode') { return } return @($script:Fake.ClusterNodes) }
function Get-ClusterGroup { [CmdletBinding()] param() return @($script:Fake.ClusterGroups) }
function Get-ClusterQuorum { [CmdletBinding()] param() if (Write-FakeFailure 'Get-ClusterQuorum') { return } return $script:Fake.ClusterQuorum }
function Get-ClusterSharedVolume { [CmdletBinding()] param() return @($script:Fake.ClusterCsv) }
function Get-ClusterResource { [CmdletBinding()] param() return @($script:Fake.ClusterResources) }
function Get-Website { [CmdletBinding()] param() if (Write-FakeFailure 'Get-Website') { return } return @($script:Fake.Websites) }
function Get-WebBinding { [CmdletBinding()] param([string]$Protocol) if (Write-FakeFailure 'Get-WebBinding') { return } return @($script:Fake.WebBindings) }
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
        NativeCalls = @(); Fail = @{}; CimThrow = @(); FeaturesThrow = $false; MissingCommands = @('Get-Cluster', 'Get-VMSwitch')
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
            'Win32_NetworkAdapterConfiguration|IPEnabled=True' = [pscustomobject]@{ Index = 1; WINSPrimaryServer = $null; WINSSecondaryServer = $null; IPAddress = @('10.20.30.40', 'fe80::1'); IPSubnet = @('255.255.255.0', '64'); DefaultIPGateway = @('10.20.30.1'); DNSServerSearchOrder = @('10.20.1.10', '10.20.1.11'); DHCPEnabled = $false; MACAddress = '00:50:56:00:00:01'; Description = 'vmxnet3 Ethernet Adapter' }
            'Win32_NetworkAdapter|Index=1' = [pscustomobject]@{ NetConnectionID = 'Ethernet0' }
            'Win32_UserAccount|LocalAccount=True AND SID LIKE ''%-500''' = @([pscustomobject]@{ Name = 'LocalAdmin'; SID = 'S-1-5-21-1-2-3-500'; Disabled = $false }, [pscustomobject]@{ Name = 'Guest'; SID = 'S-1-5-21-1-2-3-501'; Disabled = $true })
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
            [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Defrag\'; TaskName = 'ScheduledDefrag'; State = 'Ready'; Principal = [pscustomobject]@{ UserId = 'SYSTEM'; GroupId = ''; LogonType = 'ServiceAccount' }; Actions = @() },
            [pscustomobject]@{ TaskPath = '\Example\'; TaskName = 'Cleanup'; State = 'Ready'; Principal = [pscustomobject]@{ UserId = 'SYSTEM'; GroupId = ''; LogonType = 'ServiceAccount' }; Actions = @([pscustomobject]@{ Execute = 'C:\Tools\cleanup.exe'; Arguments = '/q' }) })
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
    $run = $script:CheckRuns[-1]
    # Strict-mode finder (#256): the runner turns an error inside a check
    # into a MANUAL row, which hides where it was raised. Run the check once
    # more without the runner to record the error and its place for the
    # finder, then put the first run's results back.
    if ($env:IPU_TEST_STRICT_LOG -and $run.Outcome -ne 'Completed') {
        $keepResults = @($script:Results.ToArray()); $keepRuns = @($script:CheckRuns.ToArray())
        try { & { $ErrorActionPreference = 'Stop'; $null = & $check.Script } }
        catch {
            $where = ((([string]$_.ScriptStackTrace) -split '\r?\n')[0]) -replace '^at ', '' -replace '.*[\\/]', ''
            Add-Content -LiteralPath $env:IPU_TEST_STRICT_LOG -Value ('check ' + $Id + "`t" + $_.Exception.Message + ' [' + $where + ']')
        }
        $script:Results.Clear(); foreach ($r in $keepResults) { $script:Results.Add($r) }
        $script:CheckRuns.Clear(); foreach ($r in $keepRuns) { $script:CheckRuns.Add($r) }
    }
    return $run
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
