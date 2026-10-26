# Pester 5 tests. Decision rules: platform, SQL, VMware, detection patterns, security products, printers.
# The script is loaded in library mode by ..\TestSetup.ps1: functions only, nothing is collected.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
param()

BeforeAll { . (Join-Path $PSScriptRoot '..\TestSetup.ps1') }

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'Get-PlatformClassification' {
    It '<Manufacturer> / <Model> -> <Type> <Hypervisor>' -TestCases @(
        @{ Manufacturer='VMware, Inc.';          Model='VMware7,1';               Type='Virtual';  Hypervisor='VMware' }
        @{ Manufacturer='Microsoft Corporation'; Model='Virtual Machine';         Type='Virtual';  Hypervisor='Hyper-V / Azure' }
        @{ Manufacturer='Amazon EC2';            Model='m5.large';                Type='Virtual';  Hypervisor='AWS EC2' }
        @{ Manufacturer='Google';                Model='Google Compute Engine';   Type='Virtual';  Hypervisor='Google Cloud' }
        @{ Manufacturer='Nutanix';               Model='AHV';                     Type='Virtual';  Hypervisor='Nutanix AHV' }
        @{ Manufacturer='QEMU';                  Model='Standard PC (Q35 + ICH9, 2009)'; Type='Virtual'; Hypervisor='KVM-based' }
        @{ Manufacturer='Xen';                   Model='HVM domU';                Type='Virtual';  Hypervisor='Xen' }
        @{ Manufacturer='HPE';                   Model='ProLiant DL380 Gen10';    Type='Physical'; Hypervisor='' }
        @{ Manufacturer='Dell Inc.';             Model='PowerEdge R740';          Type='Physical'; Hypervisor='' }
        @{ Manufacturer='';                      Model='';                        Type='Unknown';  Hypervisor='' }
    ) {
        $p = Get-PlatformClassification $Manufacturer $Model
        $p.Type | Should -Be $Type
        $p.Hypervisor | Should -Be $Hypervisor
    }
}

Describe 'Get-SqlSupportDecision (Microsoft SQL/Windows matrix)' {
    It 'SQL major <Major> on <Target> is <Expected>' -TestCases @(
        @{ Major=14; Target='2025'; Expected='BLOCKER' }
        @{ Major=14; Target='2022'; Expected='OK' }
        @{ Major=13; Target='2022'; Expected='BLOCKER' }
        @{ Major=15; Target='2025'; Expected='OK' }
        @{ Major=16; Target='2025'; Expected='OK' }
        @{ Major=17; Target='2025'; Expected='OK' }
    ) {
        (Get-SqlSupportDecision $Major $Target).Status | Should -Be $Expected
    }
    It 'points SQL 2017 on a 2025 target to Windows Server 2022' {
        (Get-SqlSupportDecision 14 '2025').Text | Should -Match 'Windows Server 2022'
    }
    It 'tells SQL 2016 to upgrade SQL first (no supported target)' {
        (Get-SqlSupportDecision 13 '2025').Text | Should -Match 'Upgrade SQL Server first'
    }
}

Describe 'Detection patterns - synthetic server with renamed security products' {
    BeforeAll {
        # Synthetic inventory modelled on a typical managed VM: the EDR is
        # registered under the TrendAI brand rather than "Trend Micro", and
        # Defender for Endpoint shows only as a service.
        $script:synApps = @('Inventory Agent','Microsoft Visual C++ v14 Redistributable (x64)','Nessus Agent (x64)','NXLog','Operations-agent','SA Agent','TrendAI Deep Security Agent','Universal Discovery Agent (x86)','VMware Tools') |
            ForEach-Object { [pscustomobject]@{ Name=$_; Version='1.0'; Publisher='' } }
        $script:synServices = @(
            [pscustomobject]@{ Name='ds_agent';      DisplayName='TrendAI Deep Security Agent'; State='Running' },
            [pscustomobject]@{ Name='Sense';         DisplayName='Windows Defender Advanced Threat Protection Service'; State='Running' },
            [pscustomobject]@{ Name='OpswareAgent';  DisplayName='Opsware Agent'; State='Running' },
            [pscustomobject]@{ Name='UDAgent';       DisplayName='Universal Discovery Agent'; State='Running' },
            [pscustomobject]@{ Name='OvCtrl';        DisplayName='HP OpenView Ctrl Service'; State='Running' },
            [pscustomobject]@{ Name='Tenable Nessus Agent'; DisplayName='Tenable Nessus Agent'; State='Running' },
            [pscustomobject]@{ Name='nxlog';         DisplayName='nxlog'; State='Running' },
            [pscustomobject]@{ Name='VMTools';       DisplayName='VMware Tools'; State='Running' }
        )
        $script:synDrivers = @('bindflt','SysmonDrv','TmKmSnsr','tmeyes','vsepflt','storqosflt','wcifs','CldFlt','FileCrypt','luafv','UnionFS','npsvctrig','Wof')
    }
    It 'recognises a renamed Trend product (TrendAI)' {
        $m = Find-DetectionMatch $script:DetectionPatterns.EndpointProtection $script:synApps $script:synServices $script:synDrivers
        @($m | ForEach-Object Label) | Should -Contain 'Trend Micro Deep Security Agent (Server & Workload Protection)'
    }
    It 'recognises the Defender for Endpoint sensor' {
        $m = Find-DetectionMatch $script:DetectionPatterns.EndpointProtection $script:synApps $script:synServices $script:synDrivers
        @($m | ForEach-Object Label) | Should -Contain 'Microsoft Defender for Endpoint (EDR sensor)'
    }
    It 'finds the application entries of all three OpenText agents' {
        $m = Find-DetectionMatch $script:DetectionPatterns.Agents $script:synApps $script:synServices
        $m.Count | Should -Be 3
        foreach ($x in $m) { @($x.Apps).Count | Should -Be 1 }
    }
    It 'flags Nessus, NXLog and Sysmon (Sysmon via its driver)' {
        $m = Find-DetectionMatch $script:DetectionPatterns.SecurityTools $script:synApps $script:synServices $script:synDrivers
        $labels = @($m | ForEach-Object Label)
        $labels | Should -Contain 'Tenable Nessus agent'
        $labels | Should -Contain 'NXLog'
        $labels | Should -Contain 'Sysmon'
    }
    It 'reports no workloads and no backup product for this server' {
        (Find-DetectionMatch $script:DetectionPatterns.Workloads $script:synApps $script:synServices).Count | Should -Be 0
        (Find-DetectionMatch $script:DetectionPatterns.Backup $script:synApps $script:synServices).Count | Should -Be 0
    }
    It 'detects a product by driver alone (renamed/hidden install entry)' {
        $m = Find-DetectionMatch $script:DetectionPatterns.EndpointProtection @() @() @('CSAgent')
        $m[0].Label | Should -Be 'CrowdStrike Falcon'
    }
}

Describe 'Detection patterns - one fixture per vendor row (#17)' {
    BeforeAll {
        # One realistic product name or service per row of $script:DetectionPatterns.
        # A new row without a fixture here fails the coverage test below.
        $script:VendorFixtures = @{
            'OpenText Server Automation Agent'   = @{ App = 'SA Agent' }
            'OpenText Universal Discovery Agent' = @{ App = 'Universal Discovery Agent (x86)' }
            'OpenText Operations Agent'          = @{ App = 'Operations-agent' }
            'Trend Micro Deep Security Agent (Server & Workload Protection)' = @{ App = 'TrendAI Deep Security Agent' }
            'Trend Micro Apex One' = @{ App = 'Trend Micro Apex One Security Agent' }
            'Trend Vision One Endpoint Security agent (Endpoint Basecamp)' = @{ App = 'Trend Micro Endpoint Basecamp' }
            'Microsoft Defender for Endpoint (EDR sensor)' = @{ Service = 'Sense' }
            'CrowdStrike Falcon'                 = @{ App = 'CrowdStrike Windows Sensor' }
            'SentinelOne'                        = @{ App = 'Sentinel Agent' }
            'Cisco Secure Endpoint (AMP)'        = @{ App = 'Cisco Secure Endpoint' }
            'Trellix / McAfee'                   = @{ App = 'Trellix Endpoint Security Platform' }
            'Sophos'                             = @{ App = 'Sophos Endpoint Agent' }
            'Symantec / Broadcom Endpoint Protection' = @{ App = 'Symantec Endpoint Protection' }
            'ESET'                               = @{ App = 'ESET Server Security' }
            'Kaspersky'                          = @{ App = 'Kaspersky Security for Windows Server' }
            'VMware Carbon Black'                = @{ App = 'VMware Carbon Black Cloud Sensor 64-bit'; Expect = 'Carbon Black' }
            'Tenable Nessus agent'               = @{ App = 'Nessus Agent (x64)' }
            'NXLog'                              = @{ App = 'NXLog-CE' }
            'Sysmon'                             = @{ Driver = 'SysmonDrv' }
            'Secure Root'                        = @{ App = 'Secure Root Agent' }
            'Commvault'                          = @{ App = 'Commvault ContentStore' }
            'IBM Spectrum Protect (TSM)'         = @{ App = 'IBM Spectrum Protect Client' }
            'Veeam'                              = @{ App = 'Veeam Agent for Microsoft Windows' }
            'SharePoint'                         = @{ App = 'Microsoft SharePoint Server 2019' }
            'Oracle Database'                    = @{ Service = 'OracleServiceORCL' }
            'SAP'                                = @{ App = 'SAP Host Agent' }
            'Citrix'                             = @{ App = 'Citrix Virtual Delivery Agent 2203' }
            'Boomi'                              = @{ Service = 'Boomi_Atom' }
            'Java runtime'                       = @{ App = 'Eclipse Temurin JRE with Hotspot 17.0.12' }
            'Apache Tomcat'                      = @{ App = 'Apache Tomcat 9.0 Tomcat9' }
            'MySQL'                              = @{ App = 'MySQL Server 8.0' }
            'PostgreSQL'                         = @{ App = 'PostgreSQL 15' }
            'IBM Db2'                            = @{ App = 'IBM Db2 Server Edition' }
        }
        $script:AllRows = @()
        foreach ($table in 'Agents', 'EndpointProtection', 'SecurityTools', 'Backup', 'Workloads') {
            foreach ($row in $script:DetectionPatterns[$table]) { $script:AllRows += [pscustomobject]@{ Table = $table; Row = $row } }
        }
    }
    It 'every pattern row has a fixture' {
        foreach ($r in $script:AllRows) { $script:VendorFixtures.ContainsKey($r.Row.Label) | Should -BeTrue -Because ("pattern row '" + $r.Row.Label + "' needs a fixture") }
    }
    It 'each fixture is detected by its own row and the label is unique' {
        foreach ($r in $script:AllRows) {
            $f = $script:VendorFixtures[$r.Row.Label]
            $apps = @(); $svcs = @(); $drv = @()
            if ($f.App) { $apps = @([pscustomobject]@{ Name = $f.App; Version = '1.0' }) }
            if ($f.Service) { $svcs = @([pscustomobject]@{ Name = $f.Service; DisplayName = $f.Service; State = 'Running' }) }
            if ($f.Driver) { $drv = @($f.Driver) }
            $found = Find-DetectionMatch $script:DetectionPatterns[$r.Table] $apps $svcs $drv
            $labels = @($found | ForEach-Object Label)
            $labels | Should -Contain $r.Row.Label -Because ("fixture for '" + $r.Row.Label + "'")
            @($script:AllRows | Where-Object { $_.Row.Label -eq $r.Row.Label }).Count | Should -Be 1
        }
    }
    It 'common Windows components match no vendor row' {
        $apps = @('Microsoft Visual C++ 2015-2022 Redistributable (x64)', 'Microsoft Edge', 'VMware Tools', 'Windows Admin Center') | ForEach-Object { [pscustomobject]@{ Name = $_; Version = '1' } }
        $svcs = @('WinRM', 'LanmanServer', 'Spooler', 'W32Time', 'VMTools') | ForEach-Object { [pscustomobject]@{ Name = $_; DisplayName = $_; State = 'Running' } }
        foreach ($table in 'Agents', 'EndpointProtection', 'SecurityTools', 'Backup', 'Workloads') {
            (Find-DetectionMatch $script:DetectionPatterns[$table] $apps $svcs @('WdFilter', 'storqosflt')).Count | Should -Be 0 -Because $table
        }
    }
}

Describe 'Get-VMwareToolsDecision' {
    It '<Version> for <Target> is <Expected>' -TestCases @(
        @{ Version='12.4.5.23787635'; Target='2025'; Expected='ACTION' }
        @{ Version='12.5.0.24276846'; Target='2025'; Expected='OK' }
        @{ Version='13.0.0';          Target='2025'; Expected='OK' }
        @{ Version='12.5';            Target='2025'; Expected='OK' }
        @{ Version='13.0';            Target='2025'; Expected='OK' }
        @{ Version='12.4';            Target='2025'; Expected='ACTION' }
        @{ Version='11.3.5';          Target='2022'; Expected='OK' }
        @{ Version='';                Target='2025'; Expected='ACTION' }
        @{ Version='unknown';         Target='2025'; Expected='MANUAL' }
    ) {
        (Get-VMwareToolsDecision $Version $Target).Status | Should -Be $Expected
    }
}

Describe 'Edge cases for thin decision functions (#40)' {
    Context 'Get-UpgradePathDecision' {
        It 'a 2025 to 2016 downgrade is a BLOCKER' {
            $d = Get-UpgradePathDecision '2025' '2016' $false
            # 2016 is not a configured target, so it is rejected before the downgrade rule.
            $d.Status | Should -Be 'MANUAL'
            (Get-UpgradePathDecision '2025' '2022' $false).Status | Should -Be 'BLOCKER'
            (Get-UpgradePathDecision '2025' '2022' $false).Text | Should -Match 'Downgrade is not possible'
        }
        It 'an unconfigured target is MANUAL and names the valid targets' {
            $d = Get-UpgradePathDecision '2019' '2019' $false
            $d.Status | Should -Be 'MANUAL'
            $d.Text | Should -Match '2025 or 2022'
        }
        It 'a clustered node on the same release still points to SPECIAL (#152)' {
            (Get-UpgradePathDecision '2025' '2025' $true).Text | Should -Match 'SPECIAL'
        }
    }

    Context 'Get-VMwareToolsDecision' {
        It '<Version> for 2025 is <Expected>' -TestCases @(
            @{ Version = '12.4.9';         Expected = 'ACTION' }
            @{ Version = '12.5.0';         Expected = 'OK' }
            @{ Version = '12.5.0.24276846'; Expected = 'OK' }
            @{ Version = '12.5.1';         Expected = 'OK' }
            @{ Version = '9.4';            Expected = 'ACTION' }
            @{ Version = 'garbage';        Expected = 'MANUAL' }
            @{ Version = '';               Expected = 'ACTION' }
        ) {
            (Get-VMwareToolsDecision $Version '2025').Status | Should -Be $Expected
        }
        It 'has no 12.5.0 minimum for a 2022 target' {
            (Get-VMwareToolsDecision '12.1.0' '2022').Status | Should -Be 'OK'
        }
    }

    Context 'Get-PlatformClassification' {
        It '<Manufacturer> / <Model> is <Type> <Hypervisor>' -TestCases @(
            @{ Manufacturer = 'Lenovo';                Model = 'ThinkSystem SR650';       Type = 'Physical'; Hypervisor = '' }
            @{ Manufacturer = 'Cisco Systems Inc';     Model = 'UCSC-C220-M5SX';          Type = 'Physical'; Hypervisor = '' }
            @{ Manufacturer = 'VMware, Inc.';          Model = 'VMware20,1';              Type = 'Virtual';  Hypervisor = 'VMware' }
            @{ Manufacturer = 'Microsoft Corporation'; Model = 'Virtual Machine';         Type = 'Virtual';  Hypervisor = 'Hyper-V / Azure' }
            @{ Manufacturer = 'Amazon EC2';            Model = 't3.medium';               Type = 'Virtual';  Hypervisor = 'AWS EC2' }
            @{ Manufacturer = 'innotek GmbH';          Model = 'VirtualBox';              Type = 'Virtual';  Hypervisor = 'VirtualBox' }
            @{ Manufacturer = 'Microsoft Corporation'; Model = 'Surface Pro';             Type = 'Physical'; Hypervisor = '' }
        ) {
            $p = Get-PlatformClassification $Manufacturer $Model
            $p.Type | Should -Be $Type
            $p.Hypervisor | Should -Be $Hypervisor
        }
    }

    Context 'Get-OverallStatus' {
        BeforeAll {
            function New-R([string]$Status, [string]$Kind = 'Finding') { [pscustomobject]@{ Status = $Status; Kind = $Kind } }
        }
        It 'no results is OK' {
            Get-OverallStatus @() | Should -Be 'OK'
            Get-OverallStatus $null | Should -Be 'OK'
        }
        It 'a BLOCKER Observation is ignored' {
            Get-OverallStatus @((New-R 'BLOCKER' 'Observation'), (New-R 'WARNING')) | Should -Be 'WARNING'
        }
        It '<Worst> wins when it is the worst present' -TestCases @(
            @{ Worst = 'BLOCKER'; Others = @('ACTION', 'WARNING', 'MANUAL') }
            @{ Worst = 'ACTION';  Others = @('WARNING', 'MANUAL') }
            @{ Worst = 'WARNING'; Others = @('MANUAL') }
            @{ Worst = 'MANUAL';  Others = @() }
        ) {
            $results = @(New-R $Worst) + @($Others | ForEach-Object { New-R $_ }) + @(New-R 'OK' 'Evidence')
            Get-OverallStatus $results | Should -Be $Worst
        }
    }

    Context 'ConvertTo-PendingRenamePath' {
        It 'an empty value gives an empty list' {
            (ConvertTo-PendingRenamePath @() 5).Count | Should -Be 0
            (ConvertTo-PendingRenamePath @('', '') 5).Count | Should -Be 0
        }
        It 'an odd number of entries does not lose the last one' {
            $p = ConvertTo-PendingRenamePath @('\??\C:\a.dll', '', '\??\C:\b.dll') 5
            @($p) -join '|' | Should -Be 'C:\a.dll|C:\b.dll'
        }
        It 'strips the ! (replace) prefix so both forms show the same path' {
            $p = ConvertTo-PendingRenamePath @('\??\C:\new.dll', '!\??\C:\target.dll', '\??\C:\target.dll') 5
            @($p) -join '|' | Should -Be 'C:\new.dll|C:\target.dll'
        }
    }
}

Describe 'Test-HttpSysBindingBlock' {
    It 'rejects the netsh header block' {
        Test-HttpSysBindingBlock @('SSL Certificate bindings:', '-------------------------') | Should -BeFalse
    }
    It 'accepts IP, hostname and central-store bindings' {
        Test-HttpSysBindingBlock @('IP:port                      : 0.0.0.0:443', 'Certificate Hash : aa') | Should -BeTrue
        Test-HttpSysBindingBlock @('Hostname:port                : www.example.test:443') | Should -BeTrue
        Test-HttpSysBindingBlock @('Central Certificate Store    : 443') | Should -BeTrue
    }
}

Describe 'Endpoint protection products (#74)' {
    It 'names each Trend product separately (test-server evidence: Deep Security Agent plus Endpoint Basecamp, no Apex One)' {
        $apps = @([pscustomobject]@{ Name = 'TrendAI Deep Security Agent'; Version = '20.0.32902' })
        $services = @('tm_netsrv', 'Trend Micro Endpoint Basecamp', 'ds_agent', 'ds_monitor', 'ds_notifier', 'Amsp') | ForEach-Object { [pscustomobject]@{ Name = $_; DisplayName = $_; State = 'Running' } }
        $m = Find-DetectionMatch $script:DetectionPatterns.EndpointProtection $apps $services @('tmeyes', 'TmKmSnsr', 'TMUMH')
        (@($m | ForEach-Object Label) | Sort-Object) -join ' | ' | Should -Be 'Trend Micro Deep Security Agent (Server & Workload Protection) | Trend Vision One Endpoint Security agent (Endpoint Basecamp)'
        $dsa = @($m | Where-Object { $_.Label -like 'Trend Micro Deep Security*' })[0]
        @($dsa.Services).Count | Should -Be 4
        @($dsa.Drivers).Count | Should -Be 3
        Get-DetectionProductName $dsa | Should -Be 'Trend Micro Deep Security Agent (Server & Workload Protection) 20.0.32902'
    }
    It 'still recognises Apex One by its services' {
        $services = @('ntrtscan', 'tmlisten') | ForEach-Object { [pscustomobject]@{ Name = $_; DisplayName = $_; State = 'Running' } }
        $m = Find-DetectionMatch $script:DetectionPatterns.EndpointProtection @() $services
        (@($m | ForEach-Object Label) -join ',') | Should -Be 'Trend Micro Apex One'
    }
    It 'a product without a version is named by its label' {
        Get-DetectionProductName ([pscustomobject]@{ Label = 'Sysmon'; Apps = @() }) | Should -Be 'Sysmon'
    }
    It 'Defender for Endpoint: <Case> is <Status>' -TestCases @(
        @{ Case = 'stopped and not onboarded';           Sense = 'Stopped'; Onboarding = $null; Status = 'INFO';    Active = $false }
        @{ Case = 'stopped, OnboardingState 0';          Sense = 'Stopped'; Onboarding = 0;     Status = 'INFO';    Active = $false }
        @{ Case = 'onboarded (OnboardingState 1)';       Sense = 'Stopped'; Onboarding = 1;     Status = 'WARNING'; Active = $true }
        @{ Case = 'running, state not readable';         Sense = 'Running'; Onboarding = $null; Status = 'WARNING'; Active = $true }
    ) {
        $d = Get-DefenderEndpointDecision $Sense $Onboarding
        $d.Status | Should -Be $Status
        $d.Active | Should -Be $Active
    }
}

Describe 'Security tools: finding only with a driver (#78)' {
    It 'a tool with a driver is a finding that names the driver' {
        $d = Get-SecurityToolDecision @('SysmonDrv') 'Windows Server 2025'
        $d.Kind | Should -Be 'Finding'
        $d.Recommendation | Should -Match 'Installs a driver \(SysmonDrv\)'
        $d.Recommendation | Should -Match 'Windows Server 2025'
    }
    It 'a tool without a driver is an observation to verify after the upgrade' {
        foreach ($none in @(@(), @(''), $null)) {
            $d = Get-SecurityToolDecision $none 'Windows Server 2025'
            $d.Kind | Should -Be 'Observation'
            $d.Recommendation | Should -Match 'after the upgrade'
        }
    }
}

Describe 'Print servers (#148)' {
    It 'port kind: <Desc> / <Monitor> / <Protocol> -> <Kind>' -TestCases @(
        @{ Desc = 'Standard TCP/IP Port'; Monitor = 'TCPMON.DLL'; Protocol = '1'; Kind = 'Standard TCP/IP (RAW)' }
        @{ Desc = 'Standard TCP/IP Port'; Monitor = 'TCPMON.DLL'; Protocol = '2'; Kind = 'Standard TCP/IP (LPR protocol)' }
        @{ Desc = 'LPR Port'; Monitor = 'LPR Port'; Protocol = ''; Kind = 'LPR port monitor' }
        @{ Desc = 'WSD Port'; Monitor = 'WSD Port'; Protocol = ''; Kind = 'WSD' }
        @{ Desc = 'Local Port'; Monitor = 'Local Port'; Protocol = ''; Kind = 'Local' }
        @{ Desc = 'Virtual printer port for USB'; Monitor = 'USB Monitor'; Protocol = ''; Kind = 'USB' }
        @{ Desc = 'Example Secure Port'; Monitor = 'Example Port Monitor'; Protocol = ''; Kind = 'Other: Example Secure Port' }
    ) {
        Get-PrinterPortKind $Desc $Monitor $Protocol | Should -Be $Kind
    }
    It 'backup space: 1.5 x the driver store + 1 GB, at the boundary' {
        $need = [long](1.5 * 2GB) + [long]1GB
        (Get-PrintBackupSpaceDecision ([long]2GB) $need).Proceed | Should -BeTrue
        (Get-PrintBackupSpaceDecision ([long]2GB) ($need - 1)).Proceed | Should -BeFalse
        (Get-PrintBackupSpaceDecision ([long]2GB) $need).RequiredBytes | Should -Be $need
        (Get-PrintBackupSpaceDecision ([long]0) ([long]1GB)).Proceed | Should -BeTrue
        (Get-PrintBackupSpaceDecision ([long]0) ([long]1GB - 1)).Proceed | Should -BeFalse
    }
    It 'third-party port monitors and print processors are WARNINGs; Microsoft ones are not' {
        $items = @(
            [pscustomobject]@{ Type = 'PortMonitor'; Name = 'Local Port'; Driver = 'localspl.dll'; Company = 'Microsoft Corporation' }
            [pscustomobject]@{ Type = 'PortMonitor'; Name = 'Example Port Monitor'; Driver = 'exmon.dll'; Company = 'Example Inc' }
            [pscustomobject]@{ Type = 'PrintProcessor'; Name = 'exproc'; Driver = 'exproc.dll'; Company = '' }
        )
        $rows = @(Get-PrintComponentDecision $items 'Windows Server 2025')
        ($rows | ForEach-Object { $_.Status + ' ' + $_.Item }) -join '; ' | Should -Be 'WARNING Port monitor: Example Port Monitor; WARNING Print processor: exproc'
        $rows[1].Details | Should -Match 'unknown'
        $ok = @(Get-PrintComponentDecision @($items[0]) 'Windows Server 2025')
        $ok[0].Status | Should -Be 'OK'
    }
    It 'third-party drivers: WARNING, with the Windows Update note only for 2025' {
        $drivers = @(
            [pscustomobject]@{ Name = 'Example PCL6'; Environment = 'Windows x64'; Major = '3'; Manufacturer = 'Example Inc' }
            [pscustomobject]@{ Name = 'Microsoft IPP Class Driver'; Environment = 'Windows x64'; Major = '4'; Manufacturer = 'Microsoft' }
            [pscustomobject]@{ Name = 'Microsoft Print To PDF'; Environment = 'Windows x64'; Major = '4'; Manufacturer = 'Microsoft' }
        )
        $r = @(Get-PrinterDriverDecision $drivers 'Windows Server 2025' '2025')
        $r[0].Status | Should -Be 'WARNING'
        $r[0].Value | Should -Be 'Third-party=1 of 2 (x64)'
        $r[0].Details | Should -Be 'Example PCL6 (v3, Example Inc)'
        $r[0].Recommendation | Should -Match 'Windows Update'
        (@(Get-PrinterDriverDecision $drivers 'Windows Server 2022' '2022'))[0].Recommendation | Should -Not -Match 'Windows Update'
        (@(Get-PrinterDriverDecision @($drivers[1]) 'Windows Server 2025' '2025'))[0].Status | Should -Be 'OK'
    }
    It 'a printer with another driver after the upgrade is named' {
        $before = @([pscustomobject]@{ Printer = 'P1'; Driver = 'Example PCL6' }, [pscustomobject]@{ Printer = 'P2'; Driver = 'Example PS' })
        $after = @([pscustomobject]@{ Printer = 'P1'; Driver = 'Microsoft IPP Class Driver' }, [pscustomobject]@{ Printer = 'P2'; Driver = 'Example PS' })
        $c = Compare-PrinterDriver $before $after
        @($c) | Should -Be @('P1: Example PCL6 -> Microsoft IPP Class Driver')
    }
    It 'the post-upgrade comparison reports missing printers and ports (ACTION) and changed drivers (WARNING)' {
        $before = [pscustomobject]@{ Printers = @('P1', 'P2'); PrinterPorts = @('IP_10.20.40.11', 'IP_10.20.40.12'); PrinterDrivers = @([pscustomobject]@{ Printer = 'P1'; Driver = 'Example PCL6' }) }
        $after = [pscustomobject]@{ Printers = @('P1'); PrinterPorts = @('IP_10.20.40.11'); PrinterDrivers = @([pscustomobject]@{ Printer = 'P1'; Driver = 'Microsoft IPP Class Driver' }) }
        $d = Compare-IPUSnapshot $before $after
        (@($d | Where-Object { $_.Item -eq 'Printers missing after upgrade' }))[0].Status | Should -Be 'ACTION'
        (@($d | Where-Object { $_.Item -eq 'Printers missing after upgrade' }))[0].Details | Should -Be 'P2'
        (@($d | Where-Object { $_.Item -eq 'Printer ports missing after upgrade' }))[0].Status | Should -Be 'ACTION'
        (@($d | Where-Object { $_.Item -eq 'Printer drivers changed' }))[0].Status | Should -Be 'WARNING'
    }
    It 'the export command for a manual run' {
        Get-PrintBackupCommand 'E:\Export\' 'SRV01' | Should -Be '%windir%\System32\spool\tools\PrintBrm.exe -B -F E:\Export\SRV01-printers.printerExport'
    }
    It 'reads printers from CIM when the PrintManagement module is missing' {
        Mock Test-CommandAvailable { $false }
        Mock Get-CimRequired { @([pscustomobject]@{ Name = 'P1'; ShareName = 'P1S'; Shared = $true; Published = $false; DriverName = 'Example PCL6'; PortName = 'IP_10.20.40.11' }) } -ParameterFilter { $Class -eq 'Win32_Printer' }
        Mock Get-CimSafe { @([pscustomobject]@{ Name = 'IP_10.20.40.11'; HostAddress = '10.20.40.11'; PortNumber = 9100; Protocol = 1; Queue = '' }) } -ParameterFilter { $Class -eq 'Win32_TCPIPPrinterPort' }
        Mock Get-CimSafe { @([pscustomobject]@{ Name = 'Example PCL6,3,Windows x64'; SupportedPlatform = 'Windows x64'; Version = 3 }) } -ParameterFilter { $Class -eq 'Win32_PrinterDriver' }
        $inv = Get-PrinterInventory
        $inv.Printers[0].ShareName | Should -Be 'P1S'
        $inv.Ports[0].Address | Should -Be '10.20.40.11'
        $inv.Drivers[0].Name | Should -Be 'Example PCL6'
        $inv.Drivers[0].Major | Should -Be '3'
        $inv.Drivers[0].Environment | Should -Be 'Windows x64'
    }
    It 'RedactExisting recovers printer, share and port names and port host names' {
        $rows = @(
            [pscustomobject]@{ Area = 'PRINTING'; Item = 'Printer: Floor2-Color'; Value = 'Driver=Example PCL6; Port=IP_10.20.40.11'; Details = @('Share=Floor2C', 'Published in AD=True') }
            [pscustomobject]@{ Area = 'PRINTING'; Item = 'Printer: Local-Only'; Value = 'Driver=Example PCL6; Port=LPT1:'; Details = @('Share=(not shared)', 'Published in AD=False') }
            [pscustomobject]@{ Area = 'PRINTING'; Item = 'Port: lpr-label'; Value = 'LPR port monitor'; Details = @('Address=labelhost.corp.example.test', 'Queue=labels') }
            [pscustomobject]@{ Area = 'PRINTING'; Item = 'Port: IP_10.20.40.11'; Value = 'Standard TCP/IP (RAW)'; Details = @('Address=10.20.40.11:9100') }
        )
        $l = Get-RedactionLiteralFromResult $rows
        (@($l | ForEach-Object { $_.Kind + '=' + $_.Value }) -join '; ') | Should -Be 'NAME=Floor2-Color; NAME=Floor2C; NAME=Local-Only; NAME=lpr-label; HOST=labelhost.corp.example.test; NAME=IP_10.20.40.11'
    }
}

Describe 'Get-SecureBootDecision (#242)' {
    It 'PlatformNotSupportedException is a legacy BIOS machine' {
        $d = Get-SecureBootDecision 'PlatformNotSupportedException' 'x'
        $d.Kind | Should -Be 'LegacyBios'; $d.Status | Should -Be 'INFO'
    }
    It 'the platform message alone is enough' { (Get-SecureBootDecision 'RuntimeException' 'Cmdlet not supported on this platform: 0xC0000002').Kind | Should -Be 'LegacyBios' }
    It 'any other error says nothing about the firmware' {
        $d = Get-SecureBootDecision 'UnauthorizedAccessException' 'Access is denied'
        $d.Kind | Should -Be 'Unreadable'; $d.Status | Should -Be 'MANUAL'
    }
}

Describe 'Get-CaTypeName (#242)' {
    It 'names the known types' {
        Get-CaTypeName 0 | Should -Be 'EnterpriseRoot'
        Get-CaTypeName 1 | Should -Be 'EnterpriseSubordinate'
        Get-CaTypeName 3 | Should -Be 'StandaloneRoot'
        Get-CaTypeName 4 | Should -Be 'StandaloneSubordinate'
        Get-CaTypeName '4' | Should -Be 'StandaloneSubordinate'
    }
    It 'a missing value is not an enterprise root CA' { Get-CaTypeName $null | Should -Be '' }
    It 'text and unknown numbers have no name' {
        Get-CaTypeName '' | Should -Be ''
        Get-CaTypeName 'abc' | Should -Be ''
        Get-CaTypeName 2 | Should -Be ''
    }
}

Describe 'Get-PrinterReadFailureDecision (#242)' {
    It 'with the Print Server role it is a failure to look' { Get-PrinterReadFailureDecision $true 'Disabled' $true | Should -Be 'Manual' }
    It 'without the role, a disabled spooler explains it' { Get-PrinterReadFailureDecision $false 'Disabled' $true | Should -Be 'NotPrintServer' }
    It 'without the role, a missing spooler explains it' { Get-PrinterReadFailureDecision $false '' $false | Should -Be 'NotPrintServer' }
    It 'without the role but with a spooler that should run, it is unexplained' { Get-PrinterReadFailureDecision $false 'Auto' $true | Should -Be 'Manual' }
}
