# Pester 5 tests for Windows-IPU-Readiness-Assessment.ps1 (4.x).
# Runs anywhere PowerShell + Pester run (Windows PowerShell 5.1 or pwsh 7):
#   Invoke-Pester .\tests -Output Detailed
# The script is loaded in library mode: functions only, nothing is collected.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
param()

BeforeAll {
    $env:IPU_ASSESSMENT_LIBRARY_ONLY = '1'
    . (Join-Path $PSScriptRoot '..\src\Windows-IPU-Readiness-Assessment.ps1')
}

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'Get-WindowsServerRelease' {
    It 'maps build <Build> to <Expected>' -TestCases @(
        @{ Build='9600';      Expected='2012R2' }
        @{ Build='14393';     Expected='2016' }
        @{ Build='17763.1';   Expected='2019' }
        @{ Build='20348';     Expected='2022' }
        @{ Build='26100';     Expected='2025' }
    ) {
        Get-WindowsServerRelease $Build '' | Should -Be $Expected
    }
    It 'falls back to the caption when the build is unknown' {
        Get-WindowsServerRelease '' 'Microsoft Windows Server 2012 R2 Standard' | Should -Be '2012R2'
    }
    It 'does not mistake a localized caption for another release' {
        Get-WindowsServerRelease '14393' 'Microsoft Windows Server 2016 Datacenter' | Should -Be '2016'
    }
}

Describe 'Get-UpgradePathDecision (Microsoft installation-media table)' {
    It '<Source> -> <Target> is <Expected>' -TestCases @(
        @{ Source='2012R2'; Target='2025'; Expected='OK' }
        @{ Source='2012R2'; Target='2022'; Expected='BLOCKER' }
        @{ Source='2016';   Target='2025'; Expected='OK' }
        @{ Source='2016';   Target='2022'; Expected='OK' }
        @{ Source='2019';   Target='2025'; Expected='OK' }
        @{ Source='2022';   Target='2025'; Expected='OK' }
        @{ Source='2012';   Target='2025'; Expected='BLOCKER' }
        @{ Source='2025';   Target='2022'; Expected='BLOCKER' }
        @{ Source='2025';   Target='2025'; Expected='INFO' }
        @{ Source='';       Target='2025'; Expected='MANUAL' }
    ) {
        (Get-UpgradePathDecision $Source $Target $false).Status | Should -Be $Expected
    }
    It 'suggests the supported target when the path is blocked' {
        (Get-UpgradePathDecision '2012R2' '2022' $false).Text | Should -Match 'Windows Server 2025'
    }
    It 'points clustered nodes to the SPECIAL section regardless of path (#152)' {
        $d = Get-UpgradePathDecision '2019' '2025' $true
        $d.Status | Should -Be 'INFO'
        $d.Text | Should -Match 'SPECIAL'
    }
}

Describe 'Get-EditionDecision' {
    It 'selects the Desktop Experience image for a Standard GUI server' {
        $d = Get-EditionDecision 'ServerStandard' 'Server' '2025'
        $d.Status | Should -Be 'OK'
        $d.MediaImage | Should -Be 'Windows Server 2025 Standard (Desktop Experience)'
    }
    It 'selects the plain (Server Core) image for a Core server' {
        $d = Get-EditionDecision 'ServerDatacenter' 'Server Core' '2022'
        $d.MediaImage | Should -Be 'Windows Server 2022 Datacenter'
        $d.Variant | Should -Be 'Server Core'
    }
    It 'blocks evaluation editions' { (Get-EditionDecision 'ServerStandardEval' 'Server' '2025').Status | Should -Be 'BLOCKER' }
    It 'blocks Storage Server editions' { (Get-EditionDecision 'ServerStorageStandard' 'Server' '2025').Status | Should -Be 'BLOCKER' }
    It 'needs manual review for unknown installation types' { (Get-EditionDecision 'ServerStandard' 'Nano Server' '2025').Status | Should -Be 'MANUAL' }
}

Describe 'ConvertFrom-LanguageId' {
    It 'reads hexadecimal InstallLanguage values' {
        ConvertFrom-LanguageId '0409' 16 | Should -Be 'en-US'
        ConvertFrom-LanguageId '0406' 16 | Should -Be 'da-DK'
    }
    It 'reads decimal WMI OSLanguage values' { ConvertFrom-LanguageId '1033' 10 | Should -Be 'en-US' }
    It 'returns empty for garbage' { ConvertFrom-LanguageId 'zz' 16 | Should -Be '' }
}

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

Describe 'Get-DismVerdict' {
    It 'healthy' { Get-DismVerdict 'No component store corruption detected.' 0 | Should -Be 'OK' }
    It 'repairable' { Get-DismVerdict 'The component store is repairable.' 0 | Should -Be 'ACTION' }
    It 'non-zero exit' { Get-DismVerdict 'Error: 87' 87 | Should -Be 'ACTION' }
    It 'unclear' { Get-DismVerdict '' 0 | Should -Be 'MANUAL' }
}

Describe 'Get-SfcVerdict' {
    It 'English clean output' { (Get-SfcVerdict 'Windows Resource Protection did not find any integrity violations.' @()).Status | Should -Be 'OK' }
    It 'English violations' { (Get-SfcVerdict 'Windows Resource Protection found integrity violations.' @()).Status | Should -Be 'ACTION' }
    It 'a repair waiting for a reboot is a WARNING, not violations (#159)' {
        $cbs = @('2026-10-09 08:20:00, Info CSI 00000001 [SR] Cannot repair member file [l:10]"x.dll" of y, file is missing')
        $v = Get-SfcVerdict ('There is a system repair pending which requires reboot to complete.  Restart' + [Environment]::NewLine + 'Windows and run sfc again.') $cbs
        $v.Status | Should -Be 'WARNING'
        $v.Basis | Should -Be 'Repair pending reboot'
    }
    It 'localized output falls back to clean CBS.log' {
        $cbs = @('2026-10-06 09:00:01, Info                  CSI    00000005 [SR] Verifying 100 components',
                 '2026-10-06 09:05:01, Info                  CSI    00000099 [SR] Verify complete')
        $v = Get-SfcVerdict 'Windows-ressourcebeskyttelse fandt ingen integritetskraenkelser.' $cbs
        $v.Status | Should -Be 'OK'; $v.Basis | Should -Be 'CBS.log'
    }
    It 'localized output with corruption in CBS.log' {
        $cbs = @('2026-10-06 09:02:01, Info  CSI  0000001 Hashes for file member \SystemRoot\x.dll do not match actual file',
                 '2026-10-06 09:05:01, Info  CSI  00000099 [SR] Verify complete')
        (Get-SfcVerdict 'lokaliseret tekst' $cbs).Status | Should -Be 'ACTION'
    }
    It 'nothing usable' { (Get-SfcVerdict '' @()).Status | Should -Be 'MANUAL' }
}

Describe 'VSS writer parsing' {
    BeforeAll {
        $script:sample = @(
            "Writer name: 'Task Scheduler Writer'",
            '   Writer Id: {d61d61c8-d73a-4eee-8cdd-f6f9786b7124}',
            '   Writer Instance Id: {1bddd48e-5052-49db-9b07-b96f96727e6b}',
            '   State: [1] Stable',
            '   Last error: No error',
            "Writer name: 'SqlServerWriter'",
            '   Writer Id: {a65faa63-5ea8-4ebc-9dbd-a0c4db26912a}',
            '   Writer Instance Id: {9075d8d5-a7d9-4d3d-8d82-7e8c2d0e71bc}',
            '   State: [8] Failed',
            '   Last error: Retryable error'
        )
    }
    It 'parses two writers' {
        $w = ConvertFrom-VssWriterOutput $script:sample
        $w.Count | Should -Be 2
        $w[0].Name | Should -Be 'Task Scheduler Writer'
        $w[1].StateCode | Should -Be 8
    }
    It 'classifies stable/no error as OK and failed as ACTION' {
        $w = ConvertFrom-VssWriterOutput $script:sample
        Get-VssWriterStatus $w[0] | Should -Be 'OK'
        Get-VssWriterStatus $w[1] | Should -Be 'ACTION'
    }
    It 'parses localized labels by structure' {
        $w = ConvertFrom-VssWriterOutput @("Skrivernavn: 'System Writer'", '   Tilstand: [1] Stabil', '   Seneste fejl: Ingen fejl')
        $w[0].Name | Should -Be 'System Writer'
        $w[0].StateCode | Should -Be 1
        $w[0].LastError | Should -Be 'Ingen fejl'
    }
}

Describe 'ConvertFrom-NativeByteArray' {
    It 'decodes UTF-16LE without BOM (sfc.exe style)' {
        $bytes = [Text.Encoding]::Unicode.GetBytes('Windows Resource Protection')
        ConvertFrom-NativeByteArray $bytes | Should -Be 'Windows Resource Protection'
    }
    It 'decodes single-byte output (dism.exe style)' {
        ConvertFrom-NativeByteArray ([Text.Encoding]::ASCII.GetBytes('No component store corruption detected.')) | Should -Be 'No component store corruption detected.'
    }
    It 'strips control characters' {
        ConvertFrom-NativeByteArray ([byte[]](0x41,0x08,0x42)) | Should -Be 'AB'
    }
}

Describe 'Result model' {
    BeforeEach { $script:Results.Clear() }
    It 'rejects unknown areas (typo protection)' {
        { Add-Result 'NOT_AN_AREA' 'x' 'INFO' } | Should -Throw
    }
    It 'defaults finding statuses to Finding and OK/INFO to Evidence' {
        Add-Result 'STORAGE' 'a' 'ACTION' 'v'
        Add-Result 'STORAGE' 'b' 'OK' 'v'
        $script:Results[0].Kind | Should -Be 'Finding'
        $script:Results[1].Kind | Should -Be 'Evidence'
    }
    It 'joins details and removes control characters' {
        Add-Result 'STORAGE' 'c' 'INFO' "line1`r`nline2" @('one','','two')
        $script:Results[0].Value | Should -Be 'line1 | line2'
        $script:Results[0].Details | Should -Be 'one | two'
    }
    It 'every area has a chapter that is in the chapter order' {
        foreach ($k in $script:AreaMap.Keys) { $script:ChapterOrder | Should -Contain $script:AreaMap[$k].Chapter }
    }
}

Describe 'Get-OverallStatus' {
    It 'ignores Observations and Checklist items' {
        $r = @(
            [pscustomobject]@{ Kind='Observation'; Status='ACTION' },
            [pscustomobject]@{ Kind='Checklist';   Status='MANUAL' },
            [pscustomobject]@{ Kind='Evidence';    Status='INFO' }
        )
        Get-OverallStatus $r | Should -Be 'OK'
    }
    It 'returns the most severe finding' {
        $r = @(
            [pscustomobject]@{ Kind='Finding'; Status='MANUAL' },
            [pscustomobject]@{ Kind='Finding'; Status='BLOCKER' },
            [pscustomobject]@{ Kind='Finding'; Status='WARNING' }
        )
        Get-OverallStatus $r | Should -Be 'BLOCKER'
    }
}

Describe 'Check runner' {
    BeforeEach { $script:Results.Clear(); $script:CheckRuns.Clear() }
    It 'records a throwing check as Failed with a MANUAL finding' {
        $check = [pscustomobject]@{ Id='boom'; Name='Exploding check'; Phase='Fast'; Script={ throw 'simulated failure' } }
        Invoke-Check $check
        $script:CheckRuns[0].Outcome | Should -Be 'Failed'
        $f = @($script:Results | Where-Object { $_.Area -eq 'COLLECTOR' })
        $f.Count | Should -Be 1
        $f[0].Status | Should -Be 'MANUAL'
        $f[0].Details | Should -Match 'simulated failure'
    }
    It 'turns non-terminating errors inside a check into failures' {
        $check = [pscustomobject]@{ Id='nt'; Name='Non-terminating'; Phase='Fast'; Script={ Write-Error 'quiet problem'; Add-Result 'STORAGE' 'never' 'OK' } }
        Invoke-Check $check
        $script:CheckRuns[0].Outcome | Should -Be 'Failed'
        @($script:Results | Where-Object { $_.Item -eq 'never' }).Count | Should -Be 0
    }
    It 'records a clean check as Completed' {
        Invoke-Check ([pscustomobject]@{ Id='ok'; Name='Fine'; Phase='Fast'; Script={ Add-Result 'STORAGE' 'x' 'OK' } })
        $script:CheckRuns[0].Outcome | Should -Be 'Completed'
    }
}

Describe 'HTML report' {
    BeforeAll {
        $script:Results.Clear(); $script:CheckRuns.Clear()
        Add-Result 'UPGRADE_PATH' 'TargetUpgradePath' 'BLOCKER' 'Not supported <script>' 'detail & more'
        Add-Result 'STORAGE' 'CFreeSpace' 'WARNING' 'low'
        Add-Result 'CHECKLIST' 'Backup and fallback' 'MANUAL' 'x' -Kind 'Checklist'
        $script:CheckRuns.Add([pscustomobject]@{ Id='a'; Name='A'; Phase='Fast'; Outcome='Failed'; Duration='00:00:01'; Seconds=1; Message='m' })
        $script:html = New-IPUReportHtml -Results $script:Results.ToArray() -CheckRuns $script:CheckRuns.ToArray() -OverallStatus 'BLOCKER' -CompletedTime (Get-Date) -Partial
    }
    It 'is a complete document' {
        $script:html | Should -Match '(?is)^\s*<!doctype html'
        $script:html | Should -Match '(?is)</html>\s*$'
    }
    It 'HTML-encodes values' {
        $script:html | Should -Not -Match 'Not supported <script>'
        $script:html | Should -Match 'Not supported &lt;script&gt;'
    }
    It 'shows the partial banner and the not-assessed warning' {
        $script:html | Should -Match 'PARTIAL REPORT'
        $script:html | Should -Match 'Not fully assessed'
    }
    It 'contains no external resources' {
        # Documentation links (#79) are plain <a href>; nothing is loaded.
        $script:html | Should -Not -Match 'src="https?:'
        $script:html | Should -Not -Match '<link[^>]+href="https?:'
        $script:html | Should -Not -Match '@import'
    }
}

# ---------------------------------------------------------------------------
# 4.0.1 additions
# ---------------------------------------------------------------------------
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
        @{ Version='11.3.5';          Target='2022'; Expected='OK' }
        @{ Version='';                Target='2025'; Expected='ACTION' }
        @{ Version='unknown';         Target='2025'; Expected='MANUAL' }
    ) {
        (Get-VMwareToolsDecision $Version $Target).Status | Should -Be $Expected
    }
}

Describe 'Get-FeatureLifecycleFinding' {
    It 'removed feature on a 2025 target is an ACTION finding' {
        $f = Get-FeatureLifecycleFinding @('SMTP-Server','FileAndStorage-Services') '2025'
        $f.Count | Should -Be 1
        $f[0].Status | Should -Be 'ACTION'
        $f[0].Kind | Should -Be 'Finding'
    }
    It 'the same feature is not flagged for a 2022 target' {
        (Get-FeatureLifecycleFinding @('SMTP-Server') '2022').Count | Should -Be 0
    }
    It 'deprecated features are observations' {
        $f = Get-FeatureLifecycleFinding @('NLB') '2022'
        $f[0].Kind | Should -Be 'Observation'
    }
}

Describe 'Get-CompatScanDecision (setup.exe /compat scanonly)' {
    It 'exit code <Code> is <Expected>' -TestCases @(
        @{ Code=-1047526896; Expected='OK' }        # 0xC1900210 as signed Int32
        @{ Code=3247440400;  Expected='OK' }        # same value unsigned
        @{ Code=-1047526904; Expected='ACTION' }    # 0xC1900208
        @{ Code=-1047526908; Expected='BLOCKER' }   # 0xC1900204
        @{ Code=-1047526912; Expected='BLOCKER' }   # 0xC1900200
        @{ Code=-1047526898; Expected='ACTION' }    # 0xC190020E
        @{ Code=5;           Expected='MANUAL' }
    ) {
        (Get-CompatScanDecision $Code).Status | Should -Be $Expected
    }
    It 'shows the code in hex' { (Get-CompatScanDecision -1047526896).Code | Should -Be '0xC1900210' }
    It 'handles a missing exit code' { (Get-CompatScanDecision $null).Status | Should -Be 'MANUAL' }
}

Describe 'ConvertTo-PendingRenamePath' {
    It 'strips the \??\ prefix, skips empty destinations and de-duplicates' {
        $p = ConvertTo-PendingRenamePath @('\??\C:\Program Files\Trend\x.dll','','\??\C:\Program Files\Trend\x.dll','') 5
        $p.Count | Should -Be 1
        $p[0] | Should -Be 'C:\Program Files\Trend\x.dll'
    }
    It 'limits the list and says how many more' {
        $p = ConvertTo-PendingRenamePath @('a','b','c','d') 2
        $p.Count | Should -Be 3
        $p[2] | Should -Be '... and 2 more'
    }
}

Describe 'Compare-IPUSnapshot (post-upgrade comparison)' {
    BeforeAll {
        $script:before = [pscustomobject]@{
            Services = @([pscustomobject]@{ Name='AppSvc'; State='Running'; StartMode='Auto' },
                         [pscustomobject]@{ Name='OldSvc'; State='Running'; StartMode='Auto' },
                         [pscustomobject]@{ Name='Lazy';   State='Stopped'; StartMode='Manual' })
            Ports = @('TCP:443','TCP:1433'); Routes = @('10.50.0.0/16 via 10.20.30.1'); IPv4 = @('10.20.30.42'); Dns = @('10.20.1.10')
            Hosts = @(); Apps = @([pscustomobject]@{ Name='App A'; Version='1' }); Features = @('FS-FileServer'); Tasks = @('\Backup\Nightly')
        }
    }
    It 'reports nothing when nothing changed' {
        (Compare-IPUSnapshot $script:before $script:before).Count | Should -Be 0
    }
    It 'reports a stopped service, a removed service, a lost port and a lost route' {
        $after = [pscustomobject]@{
            Services = @([pscustomobject]@{ Name='AppSvc'; State='Stopped'; StartMode='Auto' }, [pscustomobject]@{ Name='Lazy'; State='Stopped'; StartMode='Manual' })
            Ports = @('TCP:443'); Routes = @(); IPv4 = @('10.20.30.42'); Dns = @('10.20.1.10')
            Hosts = @(); Apps = @([pscustomobject]@{ Name='App A'; Version='2' }); Features = @('FS-FileServer'); Tasks = @('\Backup\Nightly')
        }
        $d = Compare-IPUSnapshot $script:before $after
        $items = @($d | ForEach-Object Item)
        $items | Should -Contain 'Automatic services no longer running'
        $items | Should -Contain 'Services no longer present'
        $items | Should -Contain 'Listening ports missing after upgrade'
        $items | Should -Contain 'Static routes missing after upgrade'
        @($d | Where-Object { $_.Item -eq 'Static routes missing after upgrade' })[0].Status | Should -Be 'ACTION'
        $items | Should -Not -Contain 'Applications missing after upgrade'   # version change only
    }
    It 'survives a JSON round trip, including single-element lists' {
        $json = $script:before | ConvertTo-Json -Depth 6
        $back = $json | ConvertFrom-Json
        (Compare-IPUSnapshot $back $script:before).Count | Should -Be 0
    }
}

Describe 'JSON result' {
    BeforeAll {
        $script:Results.Clear(); $script:CheckRuns.Clear()
        $script:Data.Snapshot = @{ Services=@(); Ports=@('TCP:3389'); Routes=@(); IPv4=@('10.0.0.1'); Dns=@(); Hosts=@(); Apps=@(); Features=@(); Tasks=@() }
        Add-Result 'STORAGE' 'CFreeSpace' 'ACTION' 'low'
        Add-Result 'CHECKLIST' 'x' 'MANUAL' 'y' -Kind 'Checklist'
        $script:obj = New-AssessmentJsonObject -Results $script:Results.ToArray() -Overall 'ACTION' -Completed (Get-Date)
        $script:round = ($script:obj | ConvertTo-Json -Depth 6) | ConvertFrom-Json
    }
    It 'counts only findings' {
        $script:round.Counts.ACTION | Should -Be 1
        $script:round.Counts.MANUAL | Should -Be 0
    }
    It 'carries results and snapshot' {
        @($script:round.Results).Count | Should -Be 2
        @($script:round.Snapshot.Ports)[0] | Should -Be 'TCP:3389'
    }
}

Describe 'Add-Result requires a named Recommendation' {
    It 'rejects a sixth positional argument' {
        { Add-Result 'STORAGE' 'a' 'OK' 'v' 'd' 'positional recommendation' } | Should -Throw
    }
}

Describe 'Output folder access (#12)' {
    It 'state <State> with readers <Readers> is <Expected>' -TestCases @(
        @{ State='CreatedRestricted';   Readers=@();          Expected='OK' }
        @{ State='CreatedUnrestricted'; Readers=@();          Expected='WARNING' }
        @{ State='Created';             Readers=@();          Expected='INFO' }
        @{ State='Existing';            Readers=@('Users');   Expected='WARNING' }
        @{ State='Existing';            Readers=@();          Expected='INFO' }
    ) {
        (Get-OutputFolderAccessDecision $State $Readers 'C:\Reports').Status | Should -Be $Expected
    }
    It 'gives the icacls command for an open existing folder, and never counts it as a finding' {
        $d = Get-OutputFolderAccessDecision 'Existing' @('Authenticated Users','Users') 'C:\Reports'
        $d.Kind | Should -Be 'Observation'
        $d.Command | Should -Be 'icacls "C:\Reports" /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F'
        $d.Text | Should -Match 'command shown'
        $d.Text | Should -Match 'Authenticated Users, Users'
    }

    Context 'Initialize-OutputFolder' {
        BeforeEach { Mock Set-RestrictedFolderAcl { } }

        It 'restricts a folder it creates' {
            $p = Join-Path $TestDrive 'new-restricted'
            Initialize-OutputFolder $p $true | Should -Be 'CreatedRestricted'
            $p | Should -Exist
            Should -Invoke Set-RestrictedFolderAcl -Times 1 -Exactly
        }
        It 'never touches an existing folder' {
            $p = Join-Path $TestDrive 'existing'
            New-Item -ItemType Directory -Path $p | Out-Null
            Initialize-OutputFolder $p $true | Should -Be 'Existing'
            Should -Invoke Set-RestrictedFolderAcl -Times 0 -Exactly
        }
        It 'keeps inherited permissions when RestrictOutputAcl is off' {
            $p = Join-Path $TestDrive 'opt-out'
            Initialize-OutputFolder $p $false | Should -Be 'Created'
            Should -Invoke Set-RestrictedFolderAcl -Times 0 -Exactly
        }
        It 'reports, rather than fails, when the ACL cannot be set' {
            Mock Set-RestrictedFolderAcl { throw 'access denied' }
            $p = Join-Path $TestDrive 'acl-fails'
            Initialize-OutputFolder $p $true | Should -Be 'CreatedUnrestricted'
            $p | Should -Exist
        }
    }

    It 'ignores empty reader lists (no false warning on a clean folder)' {
        (Get-OutputFolderAccessDecision 'Existing' @($null) 'C:\Reports').Status | Should -Be 'INFO'
        (Get-OutputFolderAccessDecision 'Existing' @() 'C:\Reports').Status | Should -Be 'INFO'
    }

    It 'builds a protected ACL with only SYSTEM and Administrators (Windows)' -Skip:($env:OS -ne 'Windows_NT') {
        $sec = New-RestrictedDirectorySecurity
        $sec.AreAccessRulesProtected | Should -BeTrue
        $sids = @($sec.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object { [string]$_.IdentityReference } | Sort-Object)
        ($sids -join ',') | Should -Be 'S-1-5-18,S-1-5-32-544'
    }
    It 'applies the ACL to a real folder (Windows)' -Skip:($env:OS -ne 'Windows_NT') {
        $p = Join-Path $TestDrive 'real-acl'
        New-Item -ItemType Directory -Path $p | Out-Null
        Set-RestrictedFolderAcl $p
        $acl = Get-Acl -LiteralPath $p
        $acl.AreAccessRulesProtected | Should -BeTrue
        @(Get-BroadFolderReader $p).Count | Should -Be 0
    }
}

Describe 'Hygiene (#18)' {
    Context 'ConvertTo-DateTimeValue' {
        It 'passes a [datetime] through unchanged' {
            $d = Get-Date -Year 2026 -Month 9 -Day 29 -Hour 1 -Minute 10 -Second 22
            ConvertTo-DateTimeValue $d | Should -Be $d
        }
        It 'reads a yyyyMMdd install date' {
            (ConvertTo-DateTimeValue '20260515').ToString('yyyy-MM-dd') | Should -Be '2026-05-15'
        }
        It 'reads an ISO date' {
            (ConvertTo-DateTimeValue '2026-09-28').ToString('yyyy-MM-dd') | Should -Be '2026-09-28'
        }
        It 'reads a WMI DMTF date (Windows)' -Skip:($env:OS -ne 'Windows_NT') {
            (ConvertTo-DateTimeValue '20260929120000.000000+120').ToString('yyyy-MM-dd') | Should -Be '2026-09-29'
        }
        It 'returns nothing for <Value>' -TestCases @(
            @{ Value = $null }
            @{ Value = '' }
            @{ Value = 'not a date' }
        ) {
            ConvertTo-DateTimeValue $Value | Should -BeNullOrEmpty
        }
    }

    Context 'CIM queries' {
        It 'Get-CimSafe returns nothing, instead of throwing, when the query fails' {
            Mock Get-CimRequired { throw 'Invalid class' }
            @(Get-CimSafe 'Win32_DoesNotExist').Count | Should -Be 0
        }
        It 'Get-CimRequired lets the failure through so the check is reported as not completed' {
            Mock Get-CimInstance { throw 'Invalid class' }
            { Get-CimRequired 'Win32_DoesNotExist' } | Should -Throw
        }
    }

    It 'renames Normalize-Thumbprint to an approved verb' {
        Get-Command ConvertTo-NormalizedThumbprint -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Normalize-Thumbprint -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        ConvertTo-NormalizedThumbprint 'ab cd:EF' | Should -Be 'ABCDEF'
    }

    Context 'Parameter validation' {
        BeforeAll { $script:ScriptPath = Join-Path $PSScriptRoot '..\src\Windows-IPU-Readiness-Assessment.ps1' }
        It 'rejects <Name> = <Value>' -TestCases @(
            @{ Name = 'MinimumCFreeGB';         Value = 0 }
            @{ Name = 'MinimumCFreeGB';         Value = -5 }
            @{ Name = 'SlowCheckBudgetMinutes'; Value = 0 }
            @{ Name = 'DISMTimeoutMinutes';     Value = 100000 }
            @{ Name = 'ReportDirectory';        Value = 'relative\folder' }
            @{ Name = 'TargetMediaPath';        Value = 'media\iso' }
            @{ Name = 'TargetMediaLanguage';    Value = 'english please' }
        ) {
            $splat = @{ $Name = $Value }
            { & $script:ScriptPath @splat } | Should -Throw
        }
        It 'accepts valid values (library mode returns without collecting)' {
            $splat = @{ MinimumCFreeGB = 40; ReportDirectory = [IO.Path]::GetTempPath(); TargetMediaPath = ''; TargetMediaLanguage = 'en-US' }
            { & $script:ScriptPath @splat } | Should -Not -Throw
        }
    }
}

Describe 'ConvertTo-RelaunchArgumentText (#38)' {
    It 'quotes strings and doubles embedded apostrophes' {
        ConvertTo-RelaunchArgumentText @{ ReportDirectory = "D:\O'Brien" } | Should -Be " -ReportDirectory 'D:\O''Brien'"
    }
    It 'keeps booleans typed' {
        ConvertTo-RelaunchArgumentText @{ WriteJson = $true } | Should -Be ' -WriteJson $true'
        ConvertTo-RelaunchArgumentText @{ RunSFCVerifyOnly = $false } | Should -Be ' -RunSFCVerifyOnly $false'
    }
    It 'passes integers unquoted' {
        ConvertTo-RelaunchArgumentText @{ MinimumCFreeGB = 60 } | Should -Be ' -MinimumCFreeGB 60'
    }
    It 'passes switches with an explicit value' {
        $on = [System.Management.Automation.SwitchParameter]::new($true)
        $off = [System.Management.Automation.SwitchParameter]::new($false)
        ConvertTo-RelaunchArgumentText @{ Demo = $on } | Should -Be ' -Demo:$true'
        ConvertTo-RelaunchArgumentText @{ Demo = $off } | Should -Be ' -Demo:$false'
    }
    It 'orders parameters by name so the command line is predictable' {
        ConvertTo-RelaunchArgumentText ([ordered]@{ Zeta = 'z'; Alpha = 1 }) | Should -Be " -Alpha 1 -Zeta 'z'"
    }
    It 'throws a clear error for an unsupported type' {
        { ConvertTo-RelaunchArgumentText @{ Ratio = [double]1.5 } } | Should -Throw -ExpectedMessage "*Ratio*System.Double*"
        { ConvertTo-RelaunchArgumentText @{ Paths = @('a','b') } } | Should -Throw -ExpectedMessage "*Paths*"
    }
    It 'returns an empty string when no parameters were given' {
        ConvertTo-RelaunchArgumentText @{} | Should -Be ''
        ConvertTo-RelaunchArgumentText $null | Should -Be ''
    }
    It 'produces text that PowerShell parses back to the same values' {
        $text = ConvertTo-RelaunchArgumentText ([ordered]@{ AssessmentMode = 'Post'; MinimumCFreeGB = 60; ReportDirectory = "D:\it's here"; WriteJson = $false })
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput('Test-Cmd' + $text, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
        $values = @($ast.EndBlock.Statements[0].PipelineElements[0].CommandElements | Where-Object { $_ -isnot [System.Management.Automation.Language.CommandParameterAst] } | Select-Object -Skip 1 | ForEach-Object { $_.SafeGetValue() })
        $values[0] | Should -Be 'Post'
        $values[1] | Should -Be 60
        $values[2] | Should -Be "D:\it's here"
        $values[3] | Should -Be $false
    }
}

Describe 'Slow-check time budget (#39)' {
    It 'default budget is 50 minutes' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\src\Windows-IPU-Readiness-Assessment.ps1'), [ref]$null, [ref]$null)
        $p = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'SlowCheckBudgetMinutes' }
        $p.DefaultValue.Value | Should -Be 50
        Get-SlowCheckBudget 50 45 '' 'Pre' | Should -Be 50
    }
    It 'adds the compat-scan timeout when media is set in Pre mode' {
        Get-SlowCheckBudget 50 45 'D:\' 'Pre' | Should -Be 95
    }
    It 'does not add it in Post mode' {
        Get-SlowCheckBudget 50 45 'D:\' 'Post' | Should -Be 50
    }
    It 'computes the seconds left' {
        Get-SlowSecondsLeft 50 0 | Should -Be 3000
        Get-SlowSecondsLeft 50 2940.4 | Should -Be 60
    }
    It '<Seconds> seconds left: skip = <Expected>' -TestCases @(
        @{ Seconds = 59;  Expected = $true }
        @{ Seconds = 60;  Expected = $false }
        @{ Seconds = 0;   Expected = $true }
        @{ Seconds = -30; Expected = $true }
        @{ Seconds = 600; Expected = $false }
    ) {
        Test-SlowCheckSkip $Seconds | Should -Be $Expected
    }
    It 'a skipped check produces a MANUAL finding and a Skipped run' {
        $script:Results.Clear(); $script:CheckRuns.Clear()
        Add-SkippedSlowCheck ([pscustomobject]@{ Id = 'sfc'; Name = 'SFC protected file verification' }) 50
        $script:Results.Count | Should -Be 1
        $script:Results[0].Status | Should -Be 'MANUAL'
        $script:Results[0].Kind | Should -Be 'Finding'
        $script:Results[0].CheckId | Should -Be 'sfc'
        $script:CheckRuns[0].Outcome | Should -Be 'Skipped'
        $script:CurrentCheckId | Should -Be 'core'
    }
}

Describe 'Compare-IPUSnapshot - every category (#35)' {
    BeforeAll {
        function New-Snapshot {
            param([hashtable]$Override = @{})
            $snap = [ordered]@{
                Services = @([pscustomobject]@{ Name = 'AppSvc'; State = 'Running'; StartMode = 'Auto' })
                Ports    = @('TCP:443')
                Routes   = @('10.50.0.0/16 via 10.20.30.1')
                IPv4     = @('10.20.30.42', '10.20.30.43')
                Dns      = @('10.20.1.10', '10.20.1.11')
                Hosts    = @('10.1.1.5 legacy-app.example.test')
                Apps     = @([pscustomobject]@{ Name = 'App A'; Version = '1.0' }, [pscustomobject]@{ Name = 'Agent B'; Version = '7.2' })
                Features = @('FS-FileServer', 'SNMP-Service')
                Tasks    = @('\Example\Nightly export', '\Example\Cleanup')
            }
            foreach ($k in $Override.Keys) { $snap[$k] = $Override[$k] }
            return [pscustomobject]$snap
        }
        function Get-Diff {
            param([string]$Item, $After)
            $all = Compare-IPUSnapshot (New-Snapshot) $After
            return ,@($all | Where-Object { $_.Item -eq $Item })
        }
    }

    It 'a lost IPv4 address is an ACTION' {
        $d = Get-Diff 'IPv4 addresses missing after upgrade' (New-Snapshot @{ IPv4 = @('10.20.30.42') })
        $d.Count | Should -Be 1
        $d[0].Status | Should -Be 'ACTION'
        $d[0].Details | Should -Be '10.20.30.43'
        $d[0].Recommendation | Should -Match 'Restore the IP configuration'
    }
    It 'a changed IPv4 address is reported as the old one missing' {
        $d = Get-Diff 'IPv4 addresses missing after upgrade' (New-Snapshot @{ IPv4 = @('10.20.30.42', '10.20.30.99') })
        $d[0].Details | Should -Be '10.20.30.43'
    }
    It 'a DNS change is a WARNING naming the lost server' {
        $d = Get-Diff 'DNS servers missing after upgrade' (New-Snapshot @{ Dns = @('10.20.1.10', '8.8.8.8') })
        $d[0].Status | Should -Be 'WARNING'
        $d[0].Details | Should -Be '10.20.1.11'
        $d[0].Recommendation | Should -Match 'DNS server configuration'
    }
    It 'a lost hosts entry is reported' {
        $d = Get-Diff 'Hosts file entries missing after upgrade' (New-Snapshot @{ Hosts = @() })
        $d[0].Status | Should -Be 'WARNING'
        $d[0].Value | Should -Be 'Count=1'
    }
    It 'a removed application is reported' {
        $d = Get-Diff 'Applications missing after upgrade' (New-Snapshot @{ Apps = @([pscustomobject]@{ Name = 'App A'; Version = '1.0' }) })
        $d[0].Details | Should -Be 'Agent B'
    }
    It 'an application whose version changed is NOT reported' {
        $after = New-Snapshot @{ Apps = @([pscustomobject]@{ Name = 'App A'; Version = '2.0' }, [pscustomobject]@{ Name = 'Agent B'; Version = '8.0' }) }
        (Get-Diff 'Applications missing after upgrade' $after).Count | Should -Be 0
    }
    It 'a lost Windows feature is reported' {
        $d = Get-Diff 'Windows features missing after upgrade' (New-Snapshot @{ Features = @('FS-FileServer') })
        $d[0].Details | Should -Be 'SNMP-Service'
    }
    It 'a lost scheduled task is reported' {
        $d = Get-Diff 'Scheduled tasks missing after upgrade' (New-Snapshot @{ Tasks = @('\Example\Cleanup') })
        $d[0].Details | Should -Be '\Example\Nightly export'
        $d[0].Recommendation | Should -Match 'run-as credentials'
    }
    It 'new items after the upgrade are not reported' {
        $after = New-Snapshot @{ Ports = @('TCP:443', 'TCP:5985'); Features = @('FS-FileServer', 'SNMP-Service', 'Windows-Defender') }
        (Compare-IPUSnapshot (New-Snapshot) $after).Count | Should -Be 0
    }
    It 'empty or $null sections do not throw' {
        $empty = [pscustomobject]@{ Services = $null; Ports = @(); Routes = $null; IPv4 = @(); Dns = $null; Hosts = @(); Apps = $null; Features = @(); Tasks = $null }
        { Compare-IPUSnapshot $empty $empty } | Should -Not -Throw
        { Compare-IPUSnapshot (New-Snapshot) $empty } | Should -Not -Throw
        { Compare-IPUSnapshot $empty (New-Snapshot) } | Should -Not -Throw
        (Compare-IPUSnapshot $empty (New-Snapshot)).Count | Should -Be 0
    }
    It 'a snapshot missing whole properties does not throw' {
        { Compare-IPUSnapshot ([pscustomobject]@{}) ([pscustomobject]@{}) } | Should -Not -Throw
        $d = Compare-IPUSnapshot (New-Snapshot) ([pscustomobject]@{})
        @($d | ForEach-Object Item) | Should -Contain 'Static routes missing after upgrade'
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

Describe 'Invoke-PostUpgradeComparison (#34)' {
    BeforeAll {
        function Set-PostScenario {
            param([string]$NowRelease = '2025', [string]$BaselinePath = '', [hashtable]$Now = @{})
            $script:Results.Clear(); $script:CheckRuns.Clear()
            $script:TargetServerVersion = '2025'
            $script:Data = @{ SourceRelease = $NowRelease }
            $snap = @{ Services = @(); Ports = @('TCP:443'); Routes = @(); IPv4 = @('10.0.0.5'); Dns = @(); Hosts = @(); Apps = @(); Features = @(); Tasks = @() }
            foreach ($k in $Now.Keys) { $snap[$k] = $Now[$k] }
            $script:Data.Snapshot = $snap
            $script:BaselinePath = $BaselinePath
        }
        function Save-Baseline {
            param([string]$Path, [bool]$Partial = $false, [hashtable]$Snapshot = @{})
            $snap = @{ Services = @(); Ports = @('TCP:443'); Routes = @(); IPv4 = @('10.0.0.5'); Dns = @(); Hosts = @(); Apps = @(); Features = @(); Tasks = @() }
            foreach ($k in $Snapshot.Keys) { $snap[$k] = $Snapshot[$k] }
            [pscustomobject]@{ Schema = 'IPU-Assessment/1'; CollectorVersion = '4.0.1'; Completed = '2026-10-01 10:00:00'; Overall = 'WARNING'; Partial = $Partial
                Facts = [pscustomobject]@{ CurrentOS = 'Windows Server 2022 Standard' }; Snapshot = [pscustomobject]$snap } |
                ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
        }
        function Get-Row([string]$Item) { @($script:Results | Where-Object { $_.Item -eq $Item }) }
    }
    AfterAll { $script:TargetServerVersion = '2025'; $script:Data = @{} }

    It 'target not reached gives an ACTION naming the Setup logs' {
        Set-PostScenario -NowRelease '2022' -BaselinePath (Join-Path $TestDrive 'none.json')
        Invoke-PostUpgradeComparison
        $r = Get-Row 'UpgradeReachedTarget'
        $r[0].Status | Should -Be 'ACTION'
        $r[0].Recommendation | Should -Match 'setuperr\.log'
        $r[0].Recommendation | Should -Match '\$WINDOWS\.~BT'
    }
    It 'missing baseline gives a MANUAL finding naming the expected path' {
        $path = Join-Path $TestDrive 'SRV-IPU-Assessment.json'
        Set-PostScenario -BaselinePath $path
        Invoke-PostUpgradeComparison
        $r = Get-Row 'Baseline'
        $r[0].Status | Should -Be 'MANUAL'
        $r[0].Kind | Should -Be 'Finding'
        $r[0].Details | Should -Be $path
        $script:CheckRuns[-1].Outcome | Should -Be 'Completed'
    }
    It 'a Partial baseline gives a WARNING Observation, not a Finding' {
        $path = Join-Path $TestDrive 'partial.json'
        Save-Baseline -Path $path -Partial $true
        Set-PostScenario -BaselinePath $path
        Invoke-PostUpgradeComparison
        $r = Get-Row 'BaselineComplete'
        $r[0].Status | Should -Be 'WARNING'
        $r[0].Kind | Should -Be 'Observation'
    }
    It 'no differences gives an OK comparison' {
        $path = Join-Path $TestDrive 'same.json'
        Save-Baseline -Path $path
        Set-PostScenario -BaselinePath $path
        Invoke-PostUpgradeComparison
        (Get-Row 'UpgradeReachedTarget')[0].Status | Should -Be 'OK'
        (Get-Row 'Comparison')[0].Status | Should -Be 'OK'
        @($script:Results | Where-Object { $_.Kind -eq 'Finding' -and $_.Status -ne 'OK' }).Count | Should -Be 0
    }
    It 'differences become findings in the comparison area' {
        $path = Join-Path $TestDrive 'diff.json'
        Save-Baseline -Path $path -Snapshot @{ Ports = @('TCP:443', 'TCP:1433'); Routes = @('10.50.0.0/16 via 10.0.0.1') }
        Set-PostScenario -BaselinePath $path
        Invoke-PostUpgradeComparison
        (Get-Row 'Static routes missing after upgrade')[0].Status | Should -Be 'ACTION'
        (Get-Row 'Listening ports missing after upgrade')[0].Details | Should -Be 'TCP:1433'
        (Get-Row 'Comparison').Count | Should -Be 0
    }
    It 'an error becomes a MANUAL finding and a Failed check run' {
        $path = Join-Path $TestDrive 'broken.json'
        Set-Content -LiteralPath $path -Value '{ this is not json'
        Set-PostScenario -BaselinePath $path
        Invoke-PostUpgradeComparison
        $r = Get-Row 'Post-upgrade comparison'
        $r[0].Status | Should -Be 'MANUAL'
        $r[0].Area | Should -Be 'COLLECTOR'
        $script:CheckRuns[-1].Id | Should -Be 'postcompare'
        $script:CheckRuns[-1].Outcome | Should -Be 'Failed'
        $script:CurrentCheckId | Should -Be 'core'
    }
}

Describe 'Report and JSON writers (#36)' {
    BeforeEach {
        $script:Results.Clear(); $script:CheckRuns.Clear(); $script:Data = @{}
        $script:CollectionStarted = (Get-Date).AddMinutes(-1)
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $script:ReportPath = Join-Path $dir 'SRV-IPU-Assessment.html'
        $script:JsonPath = Join-Path $dir 'SRV-IPU-Assessment.json'
        $script:LogPath = Join-Path $dir 'SRV-IPU-Assessment.log'
        $script:WriteJson = $true
        Add-Result 'STORAGE' 'CFreeSpace' 'ACTION' 'low'
    }

    It 'writes HTML and JSON and leaves no .writing file' {
        $r = Write-AssessmentReport
        $r.Overall | Should -Be 'ACTION'
        $script:ReportPath | Should -Exist
        $script:JsonPath | Should -Exist
        @(Get-ChildItem -LiteralPath (Split-Path $script:ReportPath) -Filter '*.writing').Count | Should -Be 0
        (Get-Content -LiteralPath $script:JsonPath -Raw | ConvertFrom-Json).Overall | Should -Be 'ACTION'
    }
    It 'replaces an existing report instead of appending' {
        Set-Content -LiteralPath $script:ReportPath -Value 'OLD REPORT CONTENT'
        Set-Content -LiteralPath $script:JsonPath -Value '{"Overall":"OLD"}'
        $null = Write-AssessmentReport
        $html = Get-Content -LiteralPath $script:ReportPath -Raw
        $html | Should -Not -Match 'OLD REPORT CONTENT'
        $html | Should -Match '(?is)^\s*<!doctype html'
        (Get-Content -LiteralPath $script:JsonPath -Raw | ConvertFrom-Json).Overall | Should -Be 'ACTION'
    }
    It 'refuses a <Case> document and leaves the previous report untouched' -TestCases @(
        @{ Case = 'short';             Html = '<!doctype html><html></html>' }
        @{ Case = 'unterminated';      Html = '<!doctype html><html>' + ('x' * 3000) }
        @{ Case = 'non-HTML';          Html = ('x' * 3000) + '</html>' }
    ) {
        Set-Content -LiteralPath $script:ReportPath -Value 'PREVIOUS GOOD REPORT'
        $script:FakeHtml = $Html
        Mock New-IPUReportHtml { $script:FakeHtml }
        { Write-AssessmentReport } | Should -Throw -ExpectedMessage '*HTML validation failed*'
        Get-Content -LiteralPath $script:ReportPath -Raw | Should -Match 'PREVIOUS GOOD REPORT'
        @(Get-ChildItem -LiteralPath (Split-Path $script:ReportPath) -Filter '*.writing').Count | Should -Be 0
    }
    It 'writes UTF-8 without a byte-order mark' {
        Add-Result 'STORAGE' 'Unicode' 'INFO' ('Caf' + [char]0xE9)
        $null = Write-AssessmentReport
        foreach ($p in $script:ReportPath, $script:JsonPath) {
            $bytes = [IO.File]::ReadAllBytes($p)
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        }
        # The HTML encodes the character (&#233;); the JSON keeps it as UTF-8.
        [IO.File]::ReadAllText($script:JsonPath, [Text.Encoding]::UTF8) | Should -Match ('Caf' + [char]0xE9)
        [IO.File]::ReadAllText($script:ReportPath) | Should -Match 'Caf&#233;'
    }
    It 'logs a JSON failure as a warning and still writes the HTML' {
        Mock Write-AssessmentJson { throw 'disk full' }
        $r = Write-AssessmentReport
        $script:ReportPath | Should -Exist
        $r.Bytes | Should -BeGreaterThan 2048
        Get-Content -LiteralPath $script:LogPath -Raw | Should -Match 'WARNING;JSON;JSON result could not be written: disk full'
    }
    It 'does not write JSON when WriteJson is off' {
        # A local variable shadows the script parameter for calls made from here.
        $WriteJson = $false
        $null = Write-AssessmentReport
        $script:JsonPath | Should -Not -Exist
    }
}

Describe 'Invoke-NativeCapture (#37)' -Tag 'Integration' {
    BeforeAll {
        # -Skip is evaluated during discovery, before this block runs, so the
        # tests test $env:OS directly. Paths are only built on Windows.
        if ($env:OS -eq 'Windows_NT') { $script:Cmd = Join-Path $env:windir 'System32\cmd.exe' }
        function Get-CaptureTempFile { @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'IPU-*' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^IPU-[0-9a-f]{32}\.(out|err)$' }) }
    }

    It 'returns exit code 0' -Skip:($env:OS -ne 'Windows_NT') {
        $r = Invoke-NativeCapture $script:Cmd @('/c', 'exit 0') 30
        $r.ExitCode | Should -Be 0
        $r.TimedOut | Should -BeFalse
        $r.Error | Should -Be ''
    }
    It 'returns a non-zero exit code' -Skip:($env:OS -ne 'Windows_NT') {
        (Invoke-NativeCapture $script:Cmd @('/c', 'exit 3') 30).ExitCode | Should -Be 3
    }
    It 'captures stdout and stderr' -Skip:($env:OS -ne 'Windows_NT') {
        $r = Invoke-NativeCapture $script:Cmd @('/c', 'echo to-stdout& echo to-stderr 1>&2') 30
        $r.Lines | Should -Contain 'to-stdout'
        $r.Lines | Should -Contain 'to-stderr'
    }
    It 'always has the exit code of a command that exits at once (#66)' -Skip:($env:OS -ne 'Windows_NT') {
        $codes = @(1..25 | ForEach-Object { (Invoke-NativeCapture $script:Cmd @('/c', ('exit ' + ($_ % 4))) 30).ExitCode })
        $expected = @(1..25 | ForEach-Object { $_ % 4 })
        ($codes -join ',') | Should -Be ($expected -join ',')
    }
    It 'captures UTF-16 output (#66)' -Skip:($env:OS -ne 'Windows_NT') {
        (Invoke-NativeCapture $script:Cmd @('/u', '/c', 'echo utf16-out') 30).Lines | Should -Contain 'utf16-out'
    }
    It 'stops a command that exceeds the timeout' -Skip:($env:OS -ne 'Windows_NT') {
        $started = Get-Date
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-NativeCapture (Join-Path $env:windir 'System32\PING.EXE') @('-n', '60', '127.0.0.1') 2
        $sw.Stop()
        $r.TimedOut | Should -BeTrue
        $r.ExitCode | Should -BeNullOrEmpty
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 30
        Start-Sleep -Milliseconds 500
        @(Get-Process -Name PING -ErrorAction SilentlyContinue | Where-Object { $_.StartTime -ge $started }).Count | Should -Be 0
    }
    It 'returns an Error, not an exception, for a missing executable' -Skip:($env:OS -ne 'Windows_NT') {
        { $script:missing = Invoke-NativeCapture 'C:\does-not-exist\nothing.exe' @() 10 } | Should -Not -Throw
        $script:missing.Error | Should -Not -BeNullOrEmpty
        $script:missing.ExitCode | Should -BeNullOrEmpty
    }
    It 'removes its temp files in every case' -Skip:($env:OS -ne 'Windows_NT') {
        $before = @(Get-CaptureTempFile | ForEach-Object FullName)
        $null = Invoke-NativeCapture $script:Cmd @('/c', 'echo x') 30
        $null = Invoke-NativeCapture $script:Cmd @('/c', 'exit 5') 30
        $null = Invoke-NativeCapture (Join-Path $env:windir 'System32\PING.EXE') @('-n', '60', '127.0.0.1') 1
        $null = Invoke-NativeCapture 'C:\does-not-exist\nothing.exe' @() 10
        $after = @(Get-CaptureTempFile | ForEach-Object FullName | Where-Object { $before -notcontains $_ })
        $after.Count | Should -Be 0
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

Describe 'HTML report accessibility (#28)' {
    BeforeAll {
        $script:Results.Clear(); $script:CheckRuns.Clear()
        Add-Result 'STORAGE' 'CFreeSpace' 'ACTION' 'low'
        Add-Result 'STORAGE' 'PartitionAfterC' 'WARNING' 'Yes'
        Add-Result 'CHECKLIST' 'Backup and fallback' 'MANUAL' 'x' -Kind 'Checklist'
        $script:CheckRuns.Add([pscustomobject]@{ Id = 'storage'; Name = 'Storage'; Phase = 'Fast'; Outcome = 'Completed'; Duration = '00:00:01'; Seconds = 1; Message = '' })
        $script:A11yHtml = New-IPUReportHtml -Results $script:Results.ToArray() -CheckRuns $script:CheckRuns.ToArray() -OverallStatus 'ACTION' -CompletedTime (Get-Date)

        function Get-Luminance([string]$Hex) {
            $h = $Hex.TrimStart('#')
            $c = foreach ($i in 0, 2, 4) {
                $v = [Convert]::ToInt32($h.Substring($i, 2), 16) / 255
                if ($v -le 0.03928) { $v / 12.92 } else { [math]::Pow(($v + 0.055) / 1.055, 2.4) }
            }
            return 0.2126 * $c[0] + 0.7152 * $c[1] + 0.0722 * $c[2]
        }
        function Get-ContrastRatio([string]$A, [string]$B) {
            $la = Get-Luminance $A; $lb = Get-Luminance $B
            return ([math]::Max($la, $lb) + 0.05) / ([math]::Min($la, $lb) + 0.05)
        }
        function Get-CssToken([string]$Block) {
            $t = @{}
            foreach ($m in [regex]::Matches($Block, '--([a-z-]+):(#[0-9a-fA-F]{6})')) { $t[$m.Groups[1].Value] = $m.Groups[2].Value }
            return $t
        }
        $script:Light = Get-CssToken ([regex]::Match($script:A11yHtml, ':root\{[^}]*\}').Value)
        $script:Dark = $script:Light.Clone()
        $darkBlock = Get-CssToken ([regex]::Match($script:A11yHtml, '@media \(prefers-color-scheme: dark\)\{:root\{[^}]*\}').Value)
        foreach ($k in $darkBlock.Keys) { $script:Dark[$k] = $darkBlock[$k] }
    }

    It 'every table has a caption and every header cell a column scope' {
        $tables = [regex]::Matches($script:A11yHtml, '<table>').Count
        $tables | Should -BeGreaterThan 3
        [regex]::Matches($script:A11yHtml, '<table><caption').Count | Should -Be $tables
        [regex]::Matches($script:A11yHtml, '<th[\s>]').Count | Should -BeGreaterThan 10
        [regex]::Matches($script:A11yHtml, '<th(?=[\s>])(?![^>]*scope="col")').Count | Should -Be 0
    }
    It 'the checklist glyph is hidden from screen readers and has a text status' {
        $script:A11yHtml | Should -Match '<span aria-hidden="true">&#x2610;</span> <span class="cbt">open</span>'
        $script:A11yHtml | Should -Match '<th scope="col" class="cb">Done</th>'
    }
    It 'collapsible sections have a visible keyboard focus style' {
        $script:A11yHtml | Should -Match 'summary:focus-visible\{outline:3px solid var\(--focus\)'
    }
    It 'defines a dark theme' {
        $script:Dark.Count | Should -BeGreaterThan 10
        $script:Dark['bg'] | Should -Not -Be $script:Light['bg']
    }
    It 'text contrast is at least 4.5:1 in the <Theme> theme' -TestCases @(@{ Theme = 'light' }, @{ Theme = 'dark' }) {
        $t = $script:Light; if ($Theme -eq 'dark') { $t = $script:Dark }
        foreach ($pair in @(@('ink', 'panel'), @('ink', 'bg'), @('muted', 'panel'), @('heading', 'panel'), @('th-ink', 'th-bg'), @('partial-ink', 'partial-bg'))) {
            Get-ContrastRatio $t[$pair[0]] $t[$pair[1]] | Should -BeGreaterOrEqual 4.5 -Because ($Theme + ': ' + ($pair -join ' on '))
        }
    }
    It 'focus outline contrast is at least 3:1 in the <Theme> theme' -TestCases @(@{ Theme = 'light' }, @{ Theme = 'dark' }) {
        $t = $script:Light; if ($Theme -eq 'dark') { $t = $script:Dark }
        Get-ContrastRatio $t['focus'] $t['panel'] | Should -BeGreaterOrEqual 3
        Get-ContrastRatio $t['focus'] $t['bg'] | Should -BeGreaterOrEqual 3
    }
    It 'white badge text meets 4.5:1 on every status colour' {
        foreach ($s in 'special', 'blocker', 'action', 'warning', 'manual', 'ok', 'info') {
            Get-ContrastRatio '#ffffff' $script:Light[$s] | Should -BeGreaterOrEqual 4.5 -Because $s
        }
    }
}

Describe 'Report redaction (#30)' {
    BeforeEach { $script:RedCtx = New-RedactionContext 'SRV01' 'corp.example.test' }

    It 'replaces <Kind> values, also inside free text' -TestCases @(
        @{ Kind = 'IPv4';        In = 'Gateway=10.20.30.1 | DNS=10.20.1.10,10.20.1.11'; Out = 'Gateway=IP-1 | DNS=IP-2,IP-3' }
        @{ Kind = 'IPv6';        In = 'Address fe80::1c2d:3e4f:5a6b:7c8d and 2001:db8:0:1:2:3:4:5 seen'; Out = 'Address IP-1 and IP-2 seen' }
        @{ Kind = 'MAC';         In = 'MAC=00:50:56:AB:CD:EF'; Out = 'MAC=MAC-1' }
        @{ Kind = 'computer';    In = 'Policy at C:\Temp\SRV01-IPU-Policy.zip on srv01'; Out = 'Policy at C:\Temp\HOST-1-IPU-Policy.zip on HOST-1' }
        @{ Kind = 'FQDN';        In = 'KMS=kms.corp.example.test:1688 Domain=corp.example.test'; Out = 'KMS=HOST-1:1688 Domain=DOMAIN-1' }
        @{ Kind = 'account';     In = 'RunAs=CORP\svc_batch, mail jane.doe@example.test'; Out = 'RunAs=ACCOUNT-1, mail ACCOUNT-2' }
        @{ Kind = 'group member'; In = 'jdoe [WinNT://CORP/jdoe]'; Out = 'ACCOUNT-1 [WinNT://DOMAIN-1/ACCOUNT-1]' }
        @{ Kind = 'local member'; In = 'Administrator [WinNT://SRV01/Administrator]'; Out = 'ACCOUNT-1 [WinNT://HOST-1/ACCOUNT-1]' }
        @{ Kind = 'SID';         In = 'Owner S-1-5-21-1111111111-2222222222-3333333333-500.'; Out = 'Owner SID-1.' }
        @{ Kind = 'thumbprint';  In = 'Thumbprint=AA11BB22CC33DD44EE55FF6677889900AABBCCDD'; Out = 'Thumbprint=CERT-1' }
        @{ Kind = 'subject';     In = 'Subject=CN=www.example.test, O=Example Corp | Issuer=CN=Example CA'; Out = 'Subject=CN=NAME-1, O=NAME-2 | Issuer=CN=NAME-3' }
    ) {
        Protect-ReportText $In $script:RedCtx | Should -BeExactly $Out
    }
    It 'keeps <What>' -TestCases @(
        @{ What = 'well-known accounts and SIDs'; In = 'NT AUTHORITY\SYSTEM | BUILTIN\Administrators [S-1-5-32-544] | S-1-5-18' }
        @{ What = 'masks, loopback and any-address'; In = '255.255.255.0 127.0.0.1 0.0.0.0:443 ::1 ::/0' }
        @{ What = 'versions'; In = 'Version=1.0.0.7 | Image Version: 10.0.20348.5631 | Collector 4.0.1' }
        @{ What = 'file and registry paths'; In = 'C:\Program Files\Example\agent.dll | HKLM\SYSTEM\Setup | \Microsoft\Windows\Defrag | C:\WINDOWS\system32' }
        @{ What = 'times'; In = 'Started 2026-10-06 09:44:41 | Duration=00:07:21' }
        @{ What = 'empty text'; In = '' }
    ) {
        Protect-ReportText $In $script:RedCtx | Should -BeExactly $In
    }
    It 'gives the same value the same placeholder and different values different ones' {
        $a = Protect-ReportText 'first 10.0.0.1 then 10.0.0.2' $script:RedCtx
        $b = Protect-ReportText 'again 10.0.0.2 and 10.0.0.1' $script:RedCtx
        $a | Should -BeExactly 'first IP-1 then IP-2'
        $b | Should -BeExactly 'again IP-2 and IP-1'
    }
    It 'redacts nested objects and keeps numbers and booleans' {
        $obj = [pscustomobject]@{ ComputerName = 'SRV01'; Partial = $true; Counts = [pscustomobject]@{ ACTION = 2 }; Results = @([pscustomobject]@{ Value = 'IPv4=10.1.2.3' }); Snapshot = [pscustomobject]@{ IPv4 = @('10.1.2.3'); Tasks = @() } }
        $r = Protect-ReportObject $obj $script:RedCtx
        $r.ComputerName | Should -Be 'HOST-1'
        $r.Partial | Should -BeTrue
        $r.Counts.ACTION | Should -Be 2
        $r.Results[0].Value | Should -Be 'IPv4=IP-1'
        @($r.Snapshot.IPv4).Count | Should -Be 1
        $r.Snapshot.IPv4[0] | Should -Be 'IP-1'
        @($r.Snapshot.Tasks).Count | Should -Be 0
        $obj.ComputerName | Should -Be 'SRV01' -Because 'the original is not changed'
    }

    Context 'writers' {
        BeforeEach {
            $script:Results.Clear(); $script:CheckRuns.Clear()
            $script:RedactionContext = $null
            $script:Data = @{ CS = [pscustomobject]@{ PartOfDomain = $true; Domain = 'corp.example.test' }; Snapshot = @{ IPv4 = @('10.20.30.40') } }
            $script:SavedComputer = $script:ComputerName
            $script:ComputerName = 'SRV01'
            $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir | Out-Null
            $script:ReportPath = Join-Path $dir 'REDACTED-20261006-094441-IPU-Assessment.html'
            $script:JsonPath = Join-Path $dir 'REDACTED-20261006-094441-IPU-Assessment.json'
            $script:LogPath = Join-Path $dir 'SRV01-IPU-Assessment.log'
            Add-Result 'NETWORK' 'Ethernet0' 'INFO' 'IPv4=10.20.30.40 / 255.255.255.0' 'DNS=10.20.1.10'
            Add-Result 'ACCESS' 'DomainMembership' 'INFO' 'Domain=corp.example.test'
            Add-Result 'TASKS' '\Example\Nightly' 'INFO' 'RunAs=CORP\svc_batch'
        }
        AfterEach { $script:ComputerName = $script:SavedComputer; $script:RedactionContext = $null }

        It 'writes a redacted HTML and JSON with the same placeholders' {
            $RedactReport = $true
            $WriteJson = $true
            $null = Write-AssessmentReport
            $html = [IO.File]::ReadAllText($script:ReportPath)
            $json = [IO.File]::ReadAllText($script:JsonPath)
            foreach ($secret in 'SRV01', '10.20.30.40', '10.20.1.10', 'corp.example.test', 'svc_batch') {
                $html | Should -Not -Match ([regex]::Escape($secret))
                $json | Should -Not -Match ([regex]::Escape($secret))
            }
            $html | Should -Match 'IPv4=IP-1 / 255\.255\.255\.0'
            $obj = $json | ConvertFrom-Json
            $obj.Redacted | Should -BeTrue
            $obj.ComputerName | Should -Be 'HOST-1'
            $obj.Snapshot.IPv4[0] | Should -Be 'IP-1'
        }
        It 'writes Redacted = false without redaction' {
            $RedactReport = $false
            $WriteJson = $true
            $null = Write-AssessmentReport
            ([IO.File]::ReadAllText($script:JsonPath) | ConvertFrom-Json).Redacted | Should -BeFalse
            [IO.File]::ReadAllText($script:ReportPath) | Should -Match '10\.20\.30\.40'
        }
    }

    It 'a redacted baseline is refused by the post-upgrade comparison' {
        $script:Results.Clear(); $script:CheckRuns.Clear()
        $TargetServerVersion = '2025'
        $script:Data = @{ SourceRelease = '2025'; Snapshot = @{} }
        $path = Join-Path $TestDrive 'redacted-baseline.json'
        [pscustomobject]@{ Schema = 'IPU-Assessment/1'; Redacted = $true; Completed = '2026-10-01 10:00:00'; CollectorVersion = '4.0.1'; Snapshot = [pscustomobject]@{} } | ConvertTo-Json | Set-Content -LiteralPath $path
        $script:BaselinePath = $path
        Invoke-PostUpgradeComparison
        $row = @($script:Results | Where-Object { $_.Item -eq 'Baseline' })[0]
        $row.Status | Should -Be 'MANUAL'
        $row.Value | Should -Be 'The pre-upgrade result is redacted'
        @($script:Results | Where-Object { $_.Item -eq 'Comparison' }).Count | Should -Be 0
    }
}

Describe 'Site data files (#32)' {
    Context 'ConvertFrom-SiteDataJson' {
        It 'returns the object when the schema matches' {
            (ConvertFrom-SiteDataJson '{ "Schema": "IPU-Profile/1", "Settings": {} }' 'IPU-Profile/1').Schema | Should -Be 'IPU-Profile/1'
        }
        It 'rejects <Case>' -TestCases @(
            @{ Case = 'an empty file';      Text = '   ';                              Message = 'empty' }
            @{ Case = 'invalid JSON';       Text = '{ "Schema": ';                     Message = 'not valid JSON' }
            @{ Case = 'a JSON array';       Text = '[ 1, 2 ]';                          Message = 'one JSON object' }
            @{ Case = 'a missing schema';   Text = '{ "Settings": {} }';                Message = 'Schema must be' }
            @{ Case = 'another schema';     Text = '{ "Schema": "IPU-Patterns/1" }';    Message = 'Schema must be' }
        ) {
            { ConvertFrom-SiteDataJson $Text 'IPU-Profile/1' } | Should -Throw ('*' + $Message + '*')
        }
    }

    Context 'Merge-DetectionPatternSet' {
        BeforeAll {
            function New-PatternFile([string]$Json) { ConvertFrom-SiteDataJson ('{ "Schema": "IPU-Patterns/1", ' + $Json + ' }') 'IPU-Patterns/1' }
        }
        It 'adds, replaces and disables entries by Label and leaves the built-in table untouched' {
            $before = @($script:DetectionPatterns.Workloads).Count
            $file = New-PatternFile '"EndpointProtection": [ { "Label": "Contoso EDR", "Service": "^CtsEdr$" }, { "Label": "sophos", "App": "^Sophos Central" } ], "Workloads": [ { "Label": "Boomi", "Disabled": true } ]'
            $r = Merge-DetectionPatternSet $script:DetectionPatterns $file
            @($r.Errors).Count | Should -Be 0
            ($r.Changes -join '; ') | Should -Be 'EndpointProtection: added "Contoso EDR"; EndpointProtection: replaced "sophos"; Workloads: disabled "Boomi"'
            @($r.Patterns.EndpointProtection | Where-Object { $_.Label -eq 'Contoso EDR' }).Count | Should -Be 1
            $sophos = @($r.Patterns.EndpointProtection | Where-Object { $_.Label -ieq 'Sophos' })
            $sophos.Count | Should -Be 1
            $sophos[0].App | Should -Be '^Sophos Central'
            $sophos[0].ContainsKey('Driver') | Should -BeFalse
            @($r.Patterns.Workloads | Where-Object { $_.Label -eq 'Boomi' }).Count | Should -Be 0
            @($script:DetectionPatterns.Workloads).Count | Should -Be $before
            @($script:DetectionPatterns.Workloads | Where-Object { $_.Label -eq 'Boomi' }).Count | Should -Be 1
            @($script:DetectionPatterns.EndpointProtection | Where-Object { $_.Label -eq 'Sophos' })[0].Driver | Should -Be '^Sophos'
        }
        It 'keeps every other category as it was' {
            $r = Merge-DetectionPatternSet $script:DetectionPatterns (New-PatternFile '"Backup": [ { "Label": "Contoso Backup", "App": "^Contoso Backup" } ]')
            foreach ($k in @('Agents', 'EndpointProtection', 'SecurityTools', 'Workloads')) {
                (@($r.Patterns[$k] | ForEach-Object { $_.Label }) -join '; ') | Should -Be (@($script:DetectionPatterns[$k] | ForEach-Object { $_.Label }) -join '; ')
            }
        }
        It 'merged patterns are used by Find-DetectionMatch' {
            $r = Merge-DetectionPatternSet $script:DetectionPatterns (New-PatternFile '"Workloads": [ { "Label": "Contoso ERP", "Service": "^CtsErp$" } ]')
            $services = @([pscustomobject]@{ Name = 'CtsErp'; DisplayName = 'Contoso ERP'; State = 'Running' })
            $found = Find-DetectionMatch $r.Patterns.Workloads @() $services
            @($found | ForEach-Object { $_.Label }) | Should -Be @('Contoso ERP')
        }
        It 'reports <Case>' -TestCases @(
            @{ Case = 'an unknown category';          Json = '"Antivirus": [ { "Label": "X", "App": "X" } ]';           Message = 'Unknown category "Antivirus"' }
            @{ Case = 'an unknown field';             Json = '"Backup": [ { "Label": "X", "Product": "X" } ]';          Message = 'unknown field Product' }
            @{ Case = 'an invalid regular expression';Json = '"Backup": [ { "Label": "X", "App": "Veeam[" } ]';         Message = 'not a valid regular expression' }
            @{ Case = 'a missing Label';              Json = '"Backup": [ { "App": "X" } ]';                            Message = 'Label is required' }
            @{ Case = 'an entry without a match field';Json = '"Backup": [ { "Label": "X" } ]';                         Message = 'needs at least one of' }
            @{ Case = 'disabling an unknown entry';   Json = '"Backup": [ { "Label": "Not there", "Disabled": true } ]'; Message = 'no built-in entry' }
            @{ Case = 'Disabled that is not a boolean';Json = '"Backup": [ { "Label": "Veeam", "Disabled": "yes" } ]';  Message = 'true or false' }
            @{ Case = 'a pattern that is not text';   Json = '"Backup": [ { "Label": "X", "App": 5 } ]';                Message = 'non-empty text' }
            @{ Case = 'an entry that is not an object';Json = '"Backup": [ "Veeam" ]';                                  Message = 'must be an object' }
            @{ Case = 'a file that changes nothing';  Json = '"Backup": [ ]';                                           Message = 'changes no pattern' }
        ) {
            $r = Merge-DetectionPatternSet $script:DetectionPatterns (New-PatternFile $Json)
            ($r.Errors -join ' | ') | Should -BeLike ('*' + $Message + '*')
        }
    }

    Context 'Get-ProfileSettingDecision' {
        BeforeAll {
            function New-ProfileFile([string]$Json) { ConvertFrom-SiteDataJson ('{ "Schema": "IPU-Profile/1", ' + $Json + ' }') 'IPU-Profile/1' }
            $script:ProfileAttributes = @{}
            foreach ($n in $script:ProfileSettingNames) { $script:ProfileAttributes[$n] = @((Get-Variable -Name $n).Attributes) }
        }
        It 'every profile setting is a script parameter' {
            foreach ($n in $script:ProfileSettingNames) { Get-Variable -Name $n -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because $n }
        }
        It 'converts values to the parameter types' {
            $d = Get-ProfileSettingDecision (New-ProfileFile '"Settings": { "MinimumCFreeGB": 60, "WriteJson": false, "NumberCultureName": "en-GB" }') $script:ProfileAttributes
            @($d.Errors).Count | Should -Be 0
            $d.Settings['MinimumCFreeGB'] | Should -Be 60
            $d.Settings['MinimumCFreeGB'] | Should -BeOfType ([int])
            $d.Settings['WriteJson'] | Should -BeFalse
            $d.Settings['WriteJson'] | Should -BeOfType ([bool])
            $d.Settings['NumberCultureName'] | Should -Be 'en-GB'
        }
        It 'an argument given to the script wins over the profile' {
            $d = Get-ProfileSettingDecision (New-ProfileFile '"Settings": { "MinimumCFreeGB": 60, "MaxPatchAgeDays": 30 }') $script:ProfileAttributes -Bound @('MinimumCFreeGB')
            $d.Settings.Contains('MinimumCFreeGB') | Should -BeFalse
            $d.Settings['MaxPatchAgeDays'] | Should -Be 30
            $d.Ignored | Should -Be @('MinimumCFreeGB')
        }
        It 'reports <Case>' -TestCases @(
            @{ Case = 'a value outside the parameter range'; Json = '"Settings": { "MinimumCFreeGB": 5000 }';          Message = 'MinimumCFreeGB: value "5000" is not allowed' }
            @{ Case = 'a value of the wrong type';           Json = '"Settings": { "MinimumMemoryGB": "lots" }';      Message = 'MinimumMemoryGB: value "lots"' }
            @{ Case = 'text for a boolean';                  Json = '"Settings": { "WriteJson": "no" }';              Message = 'WriteJson: value "no"' }
            @{ Case = 'a relative path';                     Json = '"Settings": { "LgpoExe": "LGPO.exe" }';          Message = 'LgpoExe: value "LGPO.exe"' }
            @{ Case = 'an unknown setting';                  Json = '"Settings": { "MinimumCFree": 60 }';             Message = '"MinimumCFree" is not a profile setting' }
            @{ Case = 'a per-run argument';                  Json = '"Settings": { "AssessmentMode": "Post" }';       Message = '"AssessmentMode" is not a profile setting' }
            @{ Case = 'a missing Settings object';           Json = '"Thresholds": { "MinimumCFreeGB": 60 }';         Message = 'Settings must be an object' }
            @{ Case = 'an empty Settings object';            Json = '"Settings": { }';                                Message = 'sets no setting' }
        ) {
            $d = Get-ProfileSettingDecision (New-ProfileFile $Json) $script:ProfileAttributes
            ($d.Errors -join ' | ') | Should -BeLike ('*' + $Message + '*')
            $d.Settings.Count | Should -Be 0
        }
    }

    It 'the example files in docs/examples are valid and apply cleanly' {
        $dir = Join-Path $PSScriptRoot '..\docs\examples'
        $patterns = ConvertFrom-SiteDataJson ([IO.File]::ReadAllText((Join-Path $dir 'site-patterns.example.json'))) 'IPU-Patterns/1'
        @((Merge-DetectionPatternSet $script:DetectionPatterns $patterns).Errors).Count | Should -Be 0
        $profileObj = ConvertFrom-SiteDataJson ([IO.File]::ReadAllText((Join-Path $dir 'site-profile.example.json'))) 'IPU-Profile/1'
        $attributes = @{}
        foreach ($n in $script:ProfileSettingNames) { $attributes[$n] = @((Get-Variable -Name $n).Attributes) }
        $d = Get-ProfileSettingDecision $profileObj $attributes
        @($d.Errors).Count | Should -Be 0
        $d.Settings.Count | Should -Be 4
    }

    Context 'Import-SiteDataFile' {
        BeforeEach {
            $script:Results.Clear()
            $script:SavedPatterns = $script:DetectionPatterns
        }
        AfterEach { $script:DetectionPatterns = $script:SavedPatterns }

        It 'without files changes nothing and writes no row' {
            $PatternFile = ''; $ProfileFile = ''
            Import-SiteDataFile
            $script:Results.Count | Should -Be 0
            [object]::ReferenceEquals($script:DetectionPatterns, $script:SavedPatterns) | Should -BeTrue
        }
        It 'a malformed pattern file is MANUAL and the built-in patterns stay' {
            $PatternFile = Join-Path $TestDrive 'bad-patterns.json'; $ProfileFile = ''
            Set-Content -LiteralPath $PatternFile -Value '{ "Schema": "IPU-Patterns/1", "Backup": [ { "Label": "X", "App": "Veeam[" } ] }'
            Import-SiteDataFile
            $row = @($script:Results | Where-Object { $_.Item -eq 'Pattern file' })[0]
            $row.Status | Should -Be 'MANUAL'
            $row.Kind | Should -Be 'Finding'
            $row.Details | Should -Match 'not a valid regular expression'
            $row.Details | Should -Match 'SHA256=[0-9A-F]{64}'
            [object]::ReferenceEquals($script:DetectionPatterns, $script:SavedPatterns) | Should -BeTrue
        }
        It 'a missing pattern file is MANUAL' {
            $PatternFile = Join-Path $TestDrive 'not-there.json'; $ProfileFile = ''
            Import-SiteDataFile
            @($script:Results | Where-Object { $_.Item -eq 'Pattern file' })[0].Status | Should -Be 'MANUAL'
        }
        It 'a valid pattern file is applied and listed' {
            $PatternFile = Join-Path $TestDrive 'patterns.json'; $ProfileFile = ''
            Set-Content -LiteralPath $PatternFile -Value '{ "Schema": "IPU-Patterns/1", "Workloads": [ { "Label": "Contoso ERP", "Service": "^CtsErp$" } ] }'
            Import-SiteDataFile
            $row = @($script:Results | Where-Object { $_.Item -eq 'Pattern file' })[0]
            $row.Status | Should -Be 'INFO'
            $row.Details | Should -Match 'Workloads: added "Contoso ERP"'
            @($script:DetectionPatterns.Workloads | Where-Object { $_.Label -eq 'Contoso ERP' }).Count | Should -Be 1
        }
        It 'a malformed profile file is MANUAL' {
            $PatternFile = ''; $ProfileFile = Join-Path $TestDrive 'bad-profile.json'
            Set-Content -LiteralPath $ProfileFile -Value '{ "Schema": "IPU-Profile/1", "Settings": { "MinimumCFreeGB": 0 } }'
            Import-SiteDataFile
            $row = @($script:Results | Where-Object { $_.Item -eq 'Profile file' })[0]
            $row.Status | Should -Be 'MANUAL'
            $row.Details | Should -Match 'MinimumCFreeGB'
        }
        It 'a valid profile file is applied and listed' {
            $PatternFile = ''; $ProfileFile = Join-Path $TestDrive 'profile.json'
            Set-Content -LiteralPath $ProfileFile -Value '{ "Schema": "IPU-Profile/1", "Settings": { "MaxPatchAgeDays": 45 } }'
            Import-SiteDataFile
            $row = @($script:Results | Where-Object { $_.Item -eq 'Profile file' })[0]
            $row.Status | Should -Be 'INFO'
            $row.Details | Should -Match 'MaxPatchAgeDays=45'
        }
    }
}

Describe 'Version (#19)' {
    BeforeAll {
        $script:Root = Join-Path $PSScriptRoot '..'
        $script:Header = [IO.File]::ReadAllText((Join-Path $script:Root 'src\Windows-IPU-Readiness-Assessment.ps1'))
        $script:Changelog = [IO.File]::ReadAllText((Join-Path $script:Root 'CHANGELOG.md'))
    }
    It 'the header VERSION equals $script:CollectorVersion' {
        $m = [regex]::Match($script:Header, '(?m)^\s*VERSION\s*:\s*(\d+\.\d+\.\d+)\s*$')
        $m.Success | Should -BeTrue
        $m.Groups[1].Value | Should -Be $script:CollectorVersion
    }
    It 'the version history in the header starts with this version' {
        [regex]::Match($script:Header, '(?ms)^\.VERSION HISTORY\s*\r?\n\s*(\d+\.\d+\.\d+) - ').Groups[1].Value | Should -Be $script:CollectorVersion
    }
    It 'CHANGELOG.md has a section for this version' {
        $script:Changelog | Should -Match ('(?m)^## \[' + [regex]::Escape($script:CollectorVersion) + '\]')
    }
}

Describe 'System access helpers (#33)' {
    It 'ConvertTo-SAField keeps the SA result line one field per value' {
        ConvertTo-SAField "a;b`r`nc" | Should -Be 'a,b | c'
        ConvertTo-SAField $null | Should -Be ''
    }
    It 'Test-CommandAvailable finds a cmdlet and not a missing one' {
        Test-CommandAvailable 'Get-Date' | Should -BeTrue
        Test-CommandAvailable 'Get-IpuNoSuchCommand' | Should -BeFalse
    }
    Context 'Read-FileTail' {
        It 'returns nothing for a missing file' {
            $lines = Read-FileTail (Join-Path $TestDrive 'missing.log')
            $lines.Count | Should -Be 0
        }
        It 'returns the lines of a small file' {
            $path = Join-Path $TestDrive 'small.log'
            [IO.File]::WriteAllText($path, "one`r`ntwo`r`nthree")
            (Read-FileTail $path) -join ',' | Should -Be 'one,two,three'
        }
        It 'returns only the end of a file larger than MaxBytes' {
            $path = Join-Path $TestDrive 'large.log'
            [IO.File]::WriteAllText($path, "first-line`nsecond-line`nlast-line")
            $lines = Read-FileTail $path 9
            $lines[-1] | Should -Be 'last-line'
            ($lines -join ',') | Should -Not -Match 'first-line'
        }
        It 'reads a file another process holds open for writing' {
            $path = Join-Path $TestDrive 'open.log'
            $writer = New-Object IO.FileStream($path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
            try {
                $bytes = [Text.Encoding]::ASCII.GetBytes("held-open`n")
                $writer.Write($bytes, 0, $bytes.Length); $writer.Flush()
                (Read-FileTail $path) | Should -Contain 'held-open'
            } finally { $writer.Dispose() }
        }
    }
}

Describe 'Registry and local account helpers (#33)' -Tag 'Integration' {
    It 'Get-RegistryValueSafe reads an existing value' -Skip:($env:OS -ne 'Windows_NT') {
        $r = Get-RegistryValueSafe 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuild'
        $r.Exists | Should -BeTrue
        [string]$r.Value | Should -Match '^\d+$'
    }
    It 'Get-RegistryValueSafe reports a missing value and a missing key without throwing' -Skip:($env:OS -ne 'Windows_NT') {
        (Get-RegistryValueSafe 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'IpuNoSuchValue').Exists | Should -BeFalse
        $r = Get-RegistryValueSafe 'HKLM:\SOFTWARE\IpuNoSuchKey' 'Anything'
        $r.Exists | Should -BeFalse
        $r.Value | Should -BeNullOrEmpty
    }
    It 'Get-InstalledApplication lists named applications, sorted, without duplicates' -Skip:($env:OS -ne 'Windows_NT') {
        $apps = @(Get-InstalledApplication)
        $apps.Count | Should -BeGreaterThan 0
        @($apps | Where-Object { -not $_.Name }).Count | Should -Be 0
        $keys = @($apps | ForEach-Object { $_.Name + '|' + $_.Version })
        @($keys | Sort-Object -Unique).Count | Should -Be $keys.Count
        ($apps[0].PSObject.Properties.Name -join ',') | Should -Be 'Name,Version,Publisher,InstallDate'
    }
    It 'Get-LocalGroupMembersBySid lists the local Administrators' -Skip:($env:OS -ne 'Windows_NT') {
        $members = Get-LocalGroupMembersBySid 'S-1-5-32-544'
        $members.Count | Should -BeGreaterThan 0
        $members[0] | Should -Match '\[WinNT://'
    }
    It 'Get-LocalGroupMembersBySid returns an empty list for an unknown group' -Skip:($env:OS -ne 'Windows_NT') {
        $members = Get-LocalGroupMembersBySid 'S-1-5-32-999'
        $members.Count | Should -Be 0
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

Describe 'Report header: linked counters and plain coverage notes (#77)' {
    BeforeAll {
        function New-Run([string]$Id, [string]$Name, [string]$Outcome, [string]$Message = '') {
            [pscustomobject]@{ Id = $Id; Name = $Name; Phase = 'Slow'; Outcome = $Outcome; Duration = '00:00:00'; Seconds = 0; Message = $Message }
        }
    }
    It 'a scan skipped for lack of media is a note, not a problem' {
        $n = Get-CoverageNotice @((New-Run 'compatscan' 'Setup compatibility scan' 'Skipped' 'Not configured: no installation media given (-TargetMediaPath)')) 'Windows Server 2025'
        @($n.Problems).Count | Should -Be 0
        @($n.ByChoice).Count | Should -Be 1
        $n.ByChoice[0] | Should -Match 'no Windows Server 2025 installation media was given'
        $n.ByChoice[0] | Should -Match '-TargetMediaPath'
    }
    It 'a check switched off is a note that says to run it before go/no-go' {
        $n = Get-CoverageNotice @((New-Run 'dism' 'DISM component store scan' 'Skipped' 'Not configured: switched off with -RunDISMScanHealth $false'))
        $n.ByChoice[0] | Should -Be 'DISM component store scan was switched off for this run (switched off with -RunDISMScanHealth $false). Run it before the final go/no-go.'
    }
    It 'a check that does not apply (Post mode) is not mentioned' {
        $n = Get-CoverageNotice @((New-Run 'compatscan' 'Setup compatibility scan' 'Skipped' 'Not applicable after the upgrade'))
        @($n.Problems).Count + @($n.ByChoice).Count | Should -Be 0
    }
    It '<Outcome> is a problem: "<Text>"' -TestCases @(
        @{ Outcome = 'Failed';   Message = 'IOException: x';      Text = 'Storage stopped with an error' }
        @{ Outcome = 'TimedOut'; Message = '';                    Text = 'Storage ran out of time' }
        @{ Outcome = 'Skipped';  Message = 'Time budget used up'; Text = 'Storage was not started, the time budget was used up' }
    ) {
        $n = Get-CoverageNotice @((New-Run 'storage' 'Storage' $Outcome $Message))
        $n.Problems | Should -Be @($Text)
        @($n.ByChoice).Count | Should -Be 0
    }
    Context 'generated HTML' {
        BeforeAll {
            $script:Results.Clear(); $script:CheckRuns.Clear()
            Add-Result 'STORAGE' 'PartitionAfterC' 'WARNING' 'Yes'
            Add-Result 'CHECKLIST' 'Backup and fallback' 'MANUAL' 'x' -Kind 'Checklist'
            $script:CheckRuns.Add((New-Run 'storage' 'Storage' 'Completed'))
            $script:CheckRuns.Add((New-Run 'compatscan' 'Setup compatibility scan' 'Skipped' 'Not configured: no installation media given (-TargetMediaPath)'))
            $TargetServerVersion = '2025'
            $script:HeaderHtml = New-IPUReportHtml -Results $script:Results.ToArray() -CheckRuns $script:CheckRuns.ToArray() -OverallStatus 'WARNING' -CompletedTime (Get-Date)
        }
        It 'shows no "Not fully assessed" banner when a check was only skipped by choice' {
            $script:HeaderHtml | Should -Not -Match 'Not fully assessed'
            $script:HeaderHtml | Should -Match '<div class="note"><strong>Not run by choice:</strong> Microsoft&#39;s own upgrade check'
        }
        It 'links a non-zero counter to its section and leaves a zero counter plain' {
            $script:HeaderHtml | Should -Match '<a class="card" href="#planning" aria-label="1 WARNING findings - go to the list">'
            $script:HeaderHtml | Should -Match '<div class="card"><small>BLOCKER</small><b>0</b></div>'
            $script:HeaderHtml | Should -Match '<a class="card" href="#checklist"'
            $script:HeaderHtml | Should -Match '<a class="card" href="#coverage"'
        }
        It 'every link target exists' {
            foreach ($m in [regex]::Matches($script:HeaderHtml, 'href="#([a-z]+)"')) {
                $script:HeaderHtml | Should -Match ('id="' + $m.Groups[1].Value + '"')
            }
        }
        It 'a failed check gives the banner and opens the coverage section' {
            $runs = @($script:CheckRuns.ToArray()) + @(New-Run 'iis' 'IIS' 'Failed' 'boom')
            $html = New-IPUReportHtml -Results $script:Results.ToArray() -CheckRuns $runs -OverallStatus 'MANUAL' -CompletedTime (Get-Date)
            $html | Should -Match 'Not fully assessed: IIS stopped with an error'
            $html | Should -Match '<details id="coverage" open>'
        }
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

Describe 'No company or host names in the repository (#90)' {
    It 'tracked files do not contain the names removed when the repository became public' {
        # The names are stored encoded so this test does not reintroduce them.
        $names = @('QWV2ZW4=', 'QUVWTldPU1RTVA==') | ForEach-Object { [Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($_)) }
        $root = Join-Path $PSScriptRoot '..'
        $files = Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' -and $_.Extension -in @('.ps1', '.psd1', '.md', '.json', '.yml', '.yaml', '.html', '.txt') }
        $hits = @()
        foreach ($f in $files) {
            $text = [IO.File]::ReadAllText($f.FullName)
            foreach ($n in $names) { if ($text.IndexOf($n, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hits += $f.Name } }
        }
        $hits | Should -BeNullOrEmpty
    }
}

Describe 'Group Policy, WMI filters and AD groups (#80)' {
    BeforeAll {
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
    }
    It 'reads applied and filtered GPOs with the reason, and the security groups' {
        $r = ConvertFrom-GpResultXml (New-FakeGpXml)
        $r.Domain | Should -Be 'corp.example.test'
        (@($r.Gpos | ForEach-Object { $_.Name + '=' + $(if ($_.Applied) { 'Applied' } else { $_.Reason }) }) -join '; ') | Should -Be 'Server Baseline=Applied; Default Domain Policy=Applied; Workstation Settings=Denied (WMI filter); Admins Only=Denied (security filtering)'
        $r.Gpos[0].Guid | Should -Be '{11111111-1111-1111-1111-111111111111}'
        $r.Gpos[0].Links | Should -Be @('corp.example.test/Servers')
        $r.Gpos[0].FilterName | Should -Be 'Server 2016-2022 only'
        ($r.Groups -join ', ') | Should -Be 'CORP\Domain Computers, CORP\Patch Ring 2'
    }
    It 'reads a workgroup server''s local policy' {
        $r = ConvertFrom-GpResultXml (New-FakeGpXml -Workgroup)
        @($r.Gpos).Count | Should -Be 1
        $r.Gpos[0].Name | Should -Be 'Local Group Policy'
        $r.Gpos[0].Applied | Should -BeTrue
        @($r.Groups).Count | Should -Be 0
    }
    It 'rejects output without computer results' {
        { ConvertFrom-GpResultXml '<Rsop xmlns="http://www.microsoft.com/GroupPolicy/Rsop"></Rsop>' } | Should -Throw '*No computer results*'
    }
    It 'reads the queries of a WMI filter' {
        $q = ConvertFrom-WmiFilterParm "1;3;10;66;WQL;root\CIMv2;SELECT * FROM Win32_OperatingSystem WHERE Version LIKE '10.0.14393%';3;10;45;WQL;root\CIMv2;SELECT * FROM Win32_ComputerSystem WHERE DomainRole=3;"
        $q.Count | Should -Be 2
        $q[0].Namespace | Should -Be 'root\CIMv2'
        $q[0].Query | Should -Be "SELECT * FROM Win32_OperatingSystem WHERE Version LIKE '10.0.14393%'"
        $q[1].Query | Should -Be 'SELECT * FROM Win32_ComputerSystem WHERE DomainRole=3'
        (ConvertFrom-WmiFilterParm '').Count | Should -Be 0
    }
    It '"<Query>" depends on the Windows version: <Expected>' -TestCases @(
        @{ Query = "SELECT * FROM Win32_OperatingSystem WHERE Version LIKE '10.0.14393%'"; Expected = $true }
        @{ Query = "select * from Win32_OperatingSystem where Caption like '%2016%'";       Expected = $true }
        @{ Query = 'SELECT * FROM Win32_OperatingSystem WHERE BuildNumber >= 17763';        Expected = $true }
        @{ Query = 'SELECT * FROM Win32_OperatingSystem WHERE ProductType = 3';             Expected = $false }
        @{ Query = 'SELECT * FROM Win32_ComputerSystem WHERE Model LIKE "%VMware%"';        Expected = $false }
        @{ Query = '';                                                                       Expected = $false }
    ) {
        Test-WmiFilterOsDependent $Query | Should -Be $Expected
    }
    Context 'Get-GroupPolicyDecision' {
        BeforeAll { $script:GpNow = [datetime]'2026-10-07 12:00' }
        It 'a workgroup server gets INFO only, never MANUAL - even when nothing could be read' {
            $rows = Get-GroupPolicyDecision $false $false $false $null $script:GpNow 7
            @($rows).Count | Should -Be 1
            $rows[0].Status | Should -Be 'INFO'
            $rows[0].Value | Should -Be 'Workgroup server: only local policy applies'
        }
        It 'a domain member with everything read: last applied is OK' {
            $rows = Get-GroupPolicyDecision $true $true $true ($script:GpNow.AddDays(-1)) $script:GpNow 7
            (@($rows | ForEach-Object { $_.Item + '=' + $_.Status }) -join ',') | Should -Be 'GroupPolicyLastApplied=OK'
        }
        It 'a domain member that cannot reach AD gets MANUAL with the reason' {
            $rows = Get-GroupPolicyDecision $true $true $false ($script:GpNow.AddDays(-1)) $script:GpNow 7 '' 'The server is not operational.'
            $row = @($rows | Where-Object { $_.Item -eq 'DomainLookup' })[0]
            $row.Status | Should -Be 'MANUAL'
            $row.Value | Should -Be 'Could not reach the domain: WMI filters and AD groups are incomplete'
            $row.Details | Should -Be 'The server is not operational.'
        }
        It 'a domain member where gpresult failed gets MANUAL, not an empty list' {
            $rows = Get-GroupPolicyDecision $true $false $true ($script:GpNow.AddDays(-1)) $script:GpNow 7 'Access is denied.'
            @($rows | Where-Object { $_.Item -eq 'GroupPolicyScope' -and $_.Status -eq 'MANUAL' }).Count | Should -Be 1
        }
        It 'last applied <Days> days ago with a limit of 7 is <Status>' -TestCases @(
            @{ Days = 7; Status = 'OK' }
            @{ Days = 8; Status = 'WARNING' }
        ) {
            $rows = Get-GroupPolicyDecision $true $true $true ($script:GpNow.AddDays(-1 * $Days)) $script:GpNow 7
            @($rows | Where-Object { $_.Item -eq 'GroupPolicyLastApplied' })[0].Status | Should -Be $Status
        }
        It 'a stale policy names the date' {
            $rows = Get-GroupPolicyDecision $true $true $true ([datetime]'2026-09-01 08:30') $script:GpNow 7
            @($rows | Where-Object { $_.Item -eq 'GroupPolicyLastApplied' })[0].Value | Should -Be 'This server has not received Group Policy since 2026-09-01 08:30 (36 days)'
        }
        It 'an unreadable last-applied time is a MANUAL observation' {
            $row = @(Get-GroupPolicyDecision $true $true $true $null $script:GpNow 7)[0]
            "$($row.Status)/$($row.Kind)" | Should -Be 'MANUAL/Observation'
        }
    }
    It 'converts the registry FILETIME parts' {
        $ft = ([datetime]'2026-10-01 06:00').ToFileTime()
        (ConvertFrom-FileTimeValue ([int64]($ft -shr 32)) ([int64]($ft -band 0xFFFFFFFF))) | Should -Be ([datetime]'2026-10-01 06:00')
        ConvertFrom-FileTimeValue $null 1 | Should -BeNullOrEmpty
        ConvertFrom-FileTimeValue 0 0 | Should -BeNullOrEmpty
    }
    It 'the post-upgrade comparison reports lost and new GPOs and lost groups' {
        $before = @{ Gpos = @('Default Domain Policy', 'Server Baseline'); Groups = @('CORP\Patch Ring 2') }
        $after = @{ Gpos = @('Default Domain Policy', 'Server 2025 Baseline'); Groups = @() }
        $d = Compare-IPUSnapshot $before $after
        @($d | Where-Object { $_.Item -eq 'Applied GPOs missing after upgrade' })[0].Details | Should -Be 'Server Baseline'
        @($d | Where-Object { $_.Item -eq 'GPOs newly applied after upgrade' })[0].Details | Should -Be 'Server 2025 Baseline'
        @($d | Where-Object { $_.Item -eq 'AD groups missing after upgrade' })[0].Details | Should -Be 'CORP\Patch Ring 2'
    }
    It 'an older baseline without GPO lists is not compared' {
        $d = Compare-IPUSnapshot @{} @{ Gpos = @('Default Domain Policy') }
        @($d | Where-Object { $_.Item -like '*GPO*' }).Count | Should -Be 0
    }
}

Describe 'Commands and links with recommendations (#79)' {
    It 'builds the exact <Id> command' -TestCases @(
        @{ Id = 'PendingRename'; Kind = 'Check';  Values = @{}; Expected = "Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PendingFileRenameOperations" }
        @{ Id = 'Restart';       Kind = 'Change'; Values = @{}; Expected = 'Restart-Computer' }
        @{ Id = 'IisBackup';     Kind = 'Change'; Values = @{}; Expected = '& "$env:windir\system32\inetsrv\appcmd.exe" add backup "PreIPU"' }
        @{ Id = 'FolderAcl';     Kind = 'Change'; Values = @{ Path = 'C:\Temp\IPU-Assessment' }; Expected = 'icacls "C:\Temp\IPU-Assessment" /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F' }
        @{ Id = 'EnableNla';     Kind = 'Change'; Values = @{}; Expected = 'Get-CimInstance -Namespace root\cimv2\TerminalServices -ClassName Win32_TSGeneralSetting -Filter "TerminalName=''RDP-tcp''" | Invoke-CimMethod -MethodName SetUserAuthenticationRequired -Arguments @{ UserAuthenticationRequired = 1 }' }
        @{ Id = 'LbfoTeams';     Kind = 'Check';  Values = @{}; Expected = 'Get-NetLbfoTeam | Format-List Name, Status, TeamingMode, LoadBalancingAlgorithm, Members' }
        @{ Id = 'CFreeSpace';    Kind = 'Check';  Values = @{}; Expected = 'Get-Volume -DriveLetter C | Format-List DriveLetter, FileSystemLabel, @{ n = ''SizeGB''; e = { [math]::Round($_.Size / 1GB, 1) } }, @{ n = ''FreeGB''; e = { [math]::Round($_.SizeRemaining / 1GB, 1) } }' }
    ) {
        $c = Get-RecommendationCommand $Id $Values
        $c.Kind | Should -Be $Kind
        $c.Command | Should -BeExactly $Expected
    }
    It 'every generated PowerShell command parses' {
        foreach ($id in 'PendingRename', 'Restart', 'IisBackup', 'EnableNla', 'LbfoTeams', 'CFreeSpace') {
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseInput((Get-RecommendationCommand $id).Command, [ref]$null, [ref]$errors)
            @($errors).Count | Should -Be 0 -Because $id
        }
    }
    It 'an unknown command id throws' {
        { Get-RecommendationCommand 'Nope' } | Should -Throw '*Unknown recommendation command*'
    }
    It 'commands in the script come from Get-RecommendationCommand only' {
        $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\src\Windows-IPU-Readiness-Assessment.ps1'))
        [regex]::Matches($text, "-Command\s+['""]").Count | Should -Be 0
    }
    Context 'Add-Result' {
        BeforeEach { $script:Results.Clear() }
        It 'stores command, kind, link and title' {
            Add-Result 'STORAGE' 'x' 'WARNING' 'v' -Recommendation 'r' -Command 'Get-Volume' -CommandKind 'Check' -Link 'https://learn.microsoft.com/x' -LinkTitle 'Doc'
            $r = $script:Results[0]
            "$($r.Command)|$($r.CommandKind)|$($r.Link)|$($r.LinkTitle)" | Should -Be 'Get-Volume|Check|https://learn.microsoft.com/x|Doc'
        }
        It 'leaves the fields empty when not given, and uses the URL as title when none is given' {
            Add-Result 'STORAGE' 'x' 'WARNING' 'v'
            Add-Result 'STORAGE' 'y' 'WARNING' 'v' -Link 'https://learn.microsoft.com/y'
            "$($script:Results[0].Command)|$($script:Results[0].CommandKind)|$($script:Results[0].Link)" | Should -Be '||'
            $script:Results[1].LinkTitle | Should -Be 'https://learn.microsoft.com/y'
        }
        It 'refuses a command without a kind and a link that is not https' {
            { Add-Result 'STORAGE' 'x' 'WARNING' -Command 'Get-Volume' } | Should -Throw '*CommandKind*'
            { Add-Result 'STORAGE' 'x' 'WARNING' -Link 'javascript:alert(1)' } | Should -Throw '*https*'
            { Add-Result 'STORAGE' 'x' 'WARNING' -Link 'http://example.test' } | Should -Throw '*https*'
        }
    }
    Context 'HTML' {
        It 'shows the command encoded, labelled, with a copy button, and the link' {
            $row = [pscustomobject]@{ Recommendation = 'Do it <now>'; Command = 'icacls "C:\R" /grant:r x'; CommandKind = 'Change'; Link = 'https://learn.microsoft.com/a?b=1&c=2'; LinkTitle = 'Doc & more' }
            $h = New-RecommendationHtml $row
            $h.StartsWith('Do it &lt;now&gt;') | Should -BeTrue
            $h.Contains('<span class="ck ck-change" title="run in the change window">Change</span><code>icacls &quot;C:\R&quot; /grant:r x</code>') | Should -BeTrue
            $h.Contains('data-cmd="icacls &quot;C:\R&quot; /grant:r x" aria-label="Copy the change command"') | Should -BeTrue
            $h.Contains('<a class="ext" href="https://learn.microsoft.com/a?b=1&amp;c=2" target="_blank" rel="noopener noreferrer">Doc &amp; more</a>') | Should -BeTrue
        }
        It 'shows only the text when there is no command or link' {
            New-RecommendationHtml ([pscustomobject]@{ Recommendation = 'Plain' }) | Should -Be 'Plain'
        }
        It 'the report carries the copy script and still ends as a complete document' {
            $script:Results.Clear(); $script:CheckRuns.Clear()
            Add-Result 'STORAGE' 'CFreeSpace' 'ACTION' 'low' -Recommendation 'Extend C:' -Command (Get-RecommendationCommand 'CFreeSpace').Command -CommandKind 'Check'
            $html = New-IPUReportHtml -Results $script:Results.ToArray() -CheckRuns $script:CheckRuns.ToArray() -OverallStatus 'ACTION' -CompletedTime (Get-Date)
            $html.Contains('<script type="text/javascript">document.documentElement.className+=" js"') | Should -BeTrue
            $html | Should -Match '(?is)</html>\s*$'
            ([regex]::Matches($html, 'class="cmd"')).Count | Should -Be 2   # decision table and chapter table
        }
    }
    Context 'pattern files' {
        It 'accepts an https Link and refuses another scheme' {
            $ok = ConvertFrom-SiteDataJson '{ "Schema": "IPU-Patterns/1", "Backup": [ { "Label": "Contoso Backup", "App": "^Contoso Backup", "Link": "https://docs.example.test/support", "LinkTitle": "Contoso: support matrix" } ] }' 'IPU-Patterns/1'
            $r = Merge-DetectionPatternSet $script:DetectionPatterns $ok
            @($r.Errors).Count | Should -Be 0
            @($r.Patterns.Backup | Where-Object { $_.Label -eq 'Contoso Backup' })[0].Link | Should -Be 'https://docs.example.test/support'
            $bad = ConvertFrom-SiteDataJson '{ "Schema": "IPU-Patterns/1", "Backup": [ { "Label": "Contoso Backup", "App": "x", "Link": "file://share/x" } ] }' 'IPU-Patterns/1'
            ((Merge-DetectionPatternSet $script:DetectionPatterns $bad).Errors -join ' ') | Should -Match 'Link must be an https URL'
        }
        It 'Find-DetectionMatch passes the link on' {
            $apps = @([pscustomobject]@{ Name = 'TrendAI Deep Security Agent'; Version = '20.0' })
            $m = Find-DetectionMatch $script:DetectionPatterns.EndpointProtection $apps @()
            $m[0].Link | Should -BeLike 'https://docs.trendmicro.com/*'
        }
    }
}

Describe 'Save-IISConfigEvidence (#76)' {
    BeforeAll {
        $script:IisSource = Join-Path $TestDrive 'inetsrv-config'
        New-Item -ItemType Directory -Path $script:IisSource | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:IisSource 'applicationHost.config'), '<configuration><system.applicationHost /></configuration>')
        [IO.File]::WriteAllText((Join-Path $script:IisSource 'administration.config'), '<configuration />')
        [IO.File]::WriteAllText((Join-Path $script:IisSource 'redirection.config'), '<configuration><configSections /><configurationRedirection /></configuration>')
        [IO.File]::WriteAllText((Join-Path $script:IisSource 'notes.txt'), 'not a config file')
        $script:IisBefore = @(Get-ChildItem -LiteralPath $script:IisSource | ForEach-Object { $_.Name + '|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks })
    }
    It 'copies every .config file, hashes applicationHost.config and zips the folder' {
        $dest = Join-Path $TestDrive 'evidence\SRV-IPU-IIS-1'
        $null = New-Item -ItemType Directory -Path (Split-Path $dest) -Force
        $r = Save-IISConfigEvidence -Destination $dest -SourceFolder $script:IisSource
        ($r.Files -join ',') | Should -Be 'administration.config,applicationHost.config,redirection.config'
        $r.Location | Should -Be ($dest + '.zip')
        Test-Path -LiteralPath $r.Location | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $dest 'notes.txt') | Should -BeFalse
        $r.ApplicationHostSha256 | Should -Be (Get-FileHash -LiteralPath (Join-Path $script:IisSource 'applicationHost.config') -Algorithm SHA256).Hash
        $r.SharedConfigPath | Should -Be ''
    }
    It 'does not change the source folder' {
        @(Get-ChildItem -LiteralPath $script:IisSource | ForEach-Object { $_.Name + '|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks }) -join ';' | Should -Be ($script:IisBefore -join ';')
    }
    It 'reports shared configuration from redirection.config' {
        $src = Join-Path $TestDrive 'shared-config'
        New-Item -ItemType Directory -Path $src | Out-Null
        [IO.File]::WriteAllText((Join-Path $src 'redirection.config'), '<configuration><configurationRedirection enabled="true" path="\\files.example.test\iisconfig" /></configuration>')
        $r = Save-IISConfigEvidence -Destination (Join-Path $TestDrive 'shared-copy') -SourceFolder $src -Zip $false
        $r.SharedConfigPath | Should -Be '\\files.example.test\iisconfig'
        $r.Location | Should -Be (Join-Path $TestDrive 'shared-copy')
    }
    It 'throws when there is nothing to copy' {
        $empty = Join-Path $TestDrive 'empty-config'
        New-Item -ItemType Directory -Path $empty | Out-Null
        { Save-IISConfigEvidence -Destination (Join-Path $TestDrive 'never') -SourceFolder $empty } | Should -Throw '*No .config files*'
    }
}

Describe 'User Account Control (#75)' {
    It '<Case>' -TestCases @(
        @{ Case = 'all defaults (no values) is on, Windows default'; Lua = $null; Consent = $null; Secure = $null; Filter = $null; Expected = 'On - prompt for consent for non-Windows programs (Windows default)' }
        @{ Case = 'EnableLUA 0 is off';                                Lua = 0;     Consent = 5;     Secure = 1;     Filter = 0;     Expected = 'Off - administrators run everything elevated without a prompt (EnableLUA=0)' }
        @{ Case = 'elevate without prompting';                         Lua = 1;     Consent = 0;     Secure = 1;     Filter = 0;     Expected = 'On - elevate without prompting' }
        @{ Case = 'credentials on the secure desktop';                 Lua = 1;     Consent = 1;     Secure = 0;     Filter = 0;     Expected = 'On - prompt for credentials on the secure desktop' }
        @{ Case = 'consent on the secure desktop';                     Lua = 1;     Consent = 2;     Secure = 1;     Filter = 0;     Expected = 'On - prompt for consent on the secure desktop' }
        @{ Case = 'credentials, secure desktop off';                   Lua = 1;     Consent = 3;     Secure = 0;     Filter = 0;     Expected = 'On - prompt for credentials, not on the secure desktop' }
        @{ Case = 'consent';                                           Lua = 1;     Consent = 4;     Secure = 1;     Filter = 0;     Expected = 'On - prompt for consent' }
        @{ Case = 'Admin Approval Mode for the built-in Administrator';Lua = 1;     Consent = 5;     Secure = 1;     Filter = 1;     Expected = 'On - prompt for consent for non-Windows programs (Windows default); built-in Administrator also gets prompts (Admin Approval Mode)' }
        @{ Case = 'an unknown prompt value is named';                  Lua = 1;     Consent = 9;     Secure = 1;     Filter = 0;     Expected = 'On - unknown prompt behaviour (ConsentPromptBehaviorAdmin=9)' }
    ) {
        (Get-UacDecision $Lua $Consent $Secure $Filter).Text | Should -Be $Expected
    }
    It 'the post-upgrade comparison reports a UAC change and nothing when unchanged' {
        $before = @{ Uac = 'On - prompt for consent' }
        $d = Compare-IPUSnapshot $before @{ Uac = 'Off - administrators run everything elevated without a prompt (EnableLUA=0)' }
        $row = @($d | Where-Object { $_.Item -eq 'UAC changed' })
        $row.Count | Should -Be 1
        $row[0].Status | Should -Be 'WARNING'
        $row[0].Details | Should -Be 'Before: On - prompt for consent'
        $same = Compare-IPUSnapshot $before @{ Uac = 'On - prompt for consent' }
        @($same | Where-Object { $_.Item -eq 'UAC changed' }).Count | Should -Be 0
    }
    It 'an older baseline without UAC is not reported as a change' {
        $d = Compare-IPUSnapshot @{ } @{ Uac = 'On - prompt for consent' }
        @($d | Where-Object { $_.Item -eq 'UAC changed' }).Count | Should -Be 0
    }
}

Describe 'Group Policy system helpers on a real Windows host (#80)' -Tag 'Integration' {
    It 'Get-GpResultXml returns RSoP XML that the parser reads, or a clear error' -Skip:($env:OS -ne 'Windows_NT') {
        $xml = $null; $err = $null
        try { $xml = Get-GpResultXml } catch { $err = $_.Exception.Message }
        if ($xml) {
            { ConvertFrom-GpResultXml $xml } | Should -Not -Throw
            @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'IPU-gpresult-*.xml' -ErrorAction SilentlyContinue).Count | Should -Be 0
        } else {
            $err | Should -Not -BeNullOrEmpty
        }
    }
    It 'Get-GroupPolicyLastApplied returns a date or nothing, never throws' -Skip:($env:OS -ne 'Windows_NT') {
        { $script:gpLast = Get-GroupPolicyLastApplied } | Should -Not -Throw
        if ($null -ne $script:gpLast) { $script:gpLast | Should -BeOfType ([datetime]) }
    }
    It 'Get-AdComputerGroup and Get-WmiFilterQuery fail clearly when the host is not in a domain' -Skip:($env:OS -ne 'Windows_NT' -or $env:USERDNSDOMAIN) {
        { Get-AdComputerGroup } | Should -Throw
        { Get-WmiFilterQuery @('{11111111-1111-1111-1111-111111111111}') } | Should -Throw
    }
}

Describe 'Prerequisites (#94)' {
    BeforeAll { $script:Ok = @{ Ps = [Version]'4.0'; Net = 528049; Elevated = $true } }
    It 'everything present: can run, nothing to report' {
        $d = Get-PrerequisiteDecision $script:Ok.Ps $script:Ok.Net $true @()
        $d.CanRun | Should -BeTrue
        @($d.Required).Count + @($d.Optional).Count | Should -Be 0
    }
    It 'missing <Case> stops the run with "<Expected>"' -TestCases @(
        @{ Case = 'PowerShell 4.0';  Ps = [Version]'3.0'; Net = 528049; Elevated = $true;  Expected = 'Windows PowerShell 4.0 or later (found 3.0)' }
        @{ Case = '.NET 4.5';        Ps = [Version]'4.0'; Net = 0;      Elevated = $true;  Expected = '.NET Framework 4.5 or later (not found). Install .NET Framework 4.8 and run again.' }
        @{ Case = 'an old .NET 4.x'; Ps = [Version]'4.0'; Net = 300000; Elevated = $true;  Expected = '.NET Framework 4.5 or later (release 300000)' }
        @{ Case = 'elevation';       Ps = [Version]'5.1'; Net = 528049; Elevated = $false; Expected = 'Administrator rights. Run the script elevated (Run as administrator), or as SYSTEM through OpenText SA.' }
    ) {
        $d = Get-PrerequisiteDecision $Ps $Net $Elevated @()
        $d.CanRun | Should -BeFalse
        ($d.Required -join ' ') | Should -BeLike ('*' + $Expected + '*')
    }
    It '.NET 4.5 exactly (release 378389) is enough' {
        (Get-PrerequisiteDecision ([Version]'4.0') 378389 $true @()).CanRun | Should -BeTrue
    }
    It 'a missing optional module does not stop the run and names the affected checks' {
        $d = Get-PrerequisiteDecision $script:Ok.Ps $script:Ok.Net $true @('Storage', 'ScheduledTasks')
        $d.CanRun | Should -BeTrue
        $d.Optional[0] | Should -Be 'PowerShell module Storage is not available: storage (disks, partitions, volumes) cannot be fully assessed.'
        $d.Optional[1] | Should -BeLike '*ScheduledTasks*scheduled tasks*'
    }
    It 'a missing required item stops before any check, with a clear SA line and report' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $ReportDirectory = $dir
        $RestrictOutputAcl = $false
        $WriteJson = $true
        $script:ReportPath = Join-Path $dir 'SRV-IPU-Assessment.html'
        $script:JsonPath = Join-Path $dir 'SRV-IPU-Assessment.json'
        $script:LogPath = Join-Path $dir 'SRV-IPU-Assessment.log'
        $script:Results.Clear(); $script:CheckRuns.Clear(); $script:Checks.Clear(); $script:Data = @{}
        Mock Get-PrerequisiteState { [pscustomobject]@{ PowerShellVersion = [Version]'5.1'; DotNetRelease = 528049; IsElevated = $false; MissingModules = @() } }
        $writer = New-Object IO.StringWriter
        $old = [Console]::Out
        [Console]::SetOut($writer)
        try { Invoke-Assessment } finally { [Console]::SetOut($old) }
        $out = $writer.ToString()
        $out | Should -Match ';FAILED;MANUAL;'
        $out | Should -Match 'Missing: Administrator rights\. Run the script elevated'
        $script:CheckRuns.Count | Should -Be 0
        $script:ExitCode | Should -Be 1
        [IO.File]::ReadAllText($script:ReportPath) | Should -Match 'Administrator rights'
    }
}

Describe 'Redaction gaps from a live run (#100)' {
    BeforeAll {
        $script:Data = @{}
        Add-RedactionLiteral 'CORP\adm-jdoe' 'ACCOUNT'
        Add-RedactionLiteral 'svc_batch' 'ACCOUNT'
        Add-RedactionLiteral 'Contoso Web Lockdown' 'GPO'
        Add-RedactionLiteral 'Contoso VM filter' 'NAME'
        foreach ($builtin in 'LocalSystem', 'NT AUTHORITY\NetworkService', 'NT SERVICE\MSSQLSERVER', 'Administrators', 'Default Domain Policy', 'S-1-5-18', 'ab') { Add-RedactionLiteral $builtin 'ACCOUNT' }
        $script:GapCtx = New-RedactionContext 'SRV01' 'corp.example.test'
        foreach ($k in $script:Data.RedactLiterals.Keys) { $script:GapCtx.Literals[$k] = $script:Data.RedactLiterals[$k] }
        function Protect([string]$Text) { Protect-ReportText $Text $script:GapCtx }
    }
    It 'collects only site-specific names (built-in accounts and short names are skipped)' {
        (@($script:Data.RedactLiterals.Keys) | Sort-Object) -join ',' | Should -Be 'adm-jdoe,Contoso VM filter,Contoso Web Lockdown,svc_batch'
    }
    It 'replaces <What>' -TestCases @(
        @{ What = 'IIS binding host names outside the domain'; In = 'IIS https *:443:shop.customer-site.dk'; Gone = 'customer-site' }
        @{ What = 'servers in another domain';                 In = 'Backup to bck01.backup.vendorcorp.com done'; Gone = 'vendorcorp' }
        @{ What = 'bare run-as accounts in free text';         In = '\Nightly export (adm-jdoe) | \Cleanup (svc_batch)'; Gone = 'adm-jdoe|svc_batch' }
        @{ What = 'the same account with a domain prefix';     In = 'RunAs=CORP\adm-jdoe'; Gone = 'adm-jdoe' }
        @{ What = 'GPO names';                                 In = 'GPO: Contoso Web Lockdown'; Gone = 'Contoso' }
        @{ What = 'WMI filter names';                          In = 'WMI filter: Contoso VM filter | Query: SELECT * FROM Win32_ComputerSystem'; Gone = 'Contoso' }
        @{ What = 'OU names in Group Policy link paths';       In = 'Linked at corp.example.test/General Servers/Web Apps; corp.example.test'; Gone = 'General Servers|Web Apps' }
        @{ What = 'domain components of a distinguished name'; In = 'CN=SRV01,OU=Servers,DC=corp,DC=example,DC=test'; Gone = 'corp|example' }
    ) {
        $out = Protect $In
        $out | Should -Not -Match $Gone
    }
    It 'gives one account one placeholder, with or without the domain' {
        $out = Protect 'Task (adm-jdoe) runs as CORP\adm-jdoe'
        $out | Should -Match '^Task \((ACCOUNT-\d+)\) runs as DOMAIN-\d+\\\1$'
    }
    It 'maps DC= components to the same placeholder as the domain name' {
        $a = Protect 'Domain=corp.example.test'
        $b = Protect 'CN=SRV01,DC=corp,DC=example,DC=test'
        $a -replace '^Domain=', '' | Should -Be ($b -replace '^.*DC=', '')
    }
    It 'keeps <What>' -TestCases @(
        @{ What = 'documentation links';         In = 'https://learn.microsoft.com/en-us/windows-server/get-started/perform-in-place-upgrade' }
        @{ What = 'vendor documentation';        In = 'https://docs.trendmicro.com/en-us/documentation/article/x' }
        @{ What = 'framework paths';             In = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319' }
        @{ What = 'file names and namespaces';   In = 'applicationHost.config tmmon.dll System.IO.Compression Windows.old ASP.NET' }
        @{ What = 'built-in accounts and GPOs';  In = 'LogOnAs=LocalSystem | GPO: Default Domain Policy | NT AUTHORITY\NetworkService' }
        @{ What = 'certificate locality fields'; In = 'Subject=L=Copenhagen, C=DK' }
    ) {
        Protect $In | Should -Be $In
    }
}

Describe 'Redact existing reports (#101)' {
    BeforeAll {
        $script:RexDir = Join-Path $TestDrive 'existing'
        New-Item -ItemType Directory -Path $script:RexDir | Out-Null
        $sample = Join-Path $PSScriptRoot '..\docs\samples'
        Copy-Item -LiteralPath (Join-Path $sample 'sample-result.json') -Destination (Join-Path $script:RexDir 'SRV-APP01-IPU-Assessment.json')
        Copy-Item -LiteralPath (Join-Path $sample 'sample-report.html') -Destination (Join-Path $script:RexDir 'SRV-APP01-IPU-Assessment.html')
        $script:RexBefore = @(Get-ChildItem -LiteralPath $script:RexDir | ForEach-Object { $_.Name + '|' + (Get-FileHash -LiteralPath $_.FullName).Hash })
        $script:RexCode = Invoke-RedactExisting $script:RexDir
        $script:RexJson = @(Get-ChildItem -LiteralPath $script:RexDir -Filter 'REDACTED-*-IPU-Assessment.json')
        $script:RexHtml = @(Get-ChildItem -LiteralPath $script:RexDir -Filter 'REDACTED-*-IPU-Assessment.html')
    }
    It 'writes one redacted JSON and HTML pair and returns 0' {
        $script:RexCode | Should -Be 0
        $script:RexJson.Count | Should -Be 1
        $script:RexHtml.Count | Should -Be 1
    }
    It 'the copies contain neither the computer name nor the domain, and the JSON is marked Redacted' {
        foreach ($f in @($script:RexJson[0], $script:RexHtml[0])) {
            $text = [IO.File]::ReadAllText($f.FullName)
            $text | Should -Not -Match 'SRV-APP01'
            $text | Should -Not -Match 'corp\.example\.test'
        }
        ([IO.File]::ReadAllText($script:RexJson[0].FullName) | ConvertFrom-Json).Redacted | Should -BeTrue
    }
    It 'HTML and JSON use the same placeholder for the computer' {
        $json = [IO.File]::ReadAllText($script:RexJson[0].FullName) | ConvertFrom-Json
        $json.ComputerName | Should -Match '^HOST-\d+$'
        [IO.File]::ReadAllText($script:RexHtml[0].FullName) | Should -Match ([regex]::Escape('<strong>' + $json.ComputerName + '</strong>'))
    }
    It 'leaves the originals unchanged' {
        $after = @(Get-ChildItem -LiteralPath $script:RexDir | Where-Object { $_.Name -notlike 'REDACTED-*' } | ForEach-Object { $_.Name + '|' + (Get-FileHash -LiteralPath $_.FullName).Hash })
        ($after -join ';') | Should -Be ($script:RexBefore -join ';')
    }
    It 'skips a report that is already redacted' {
        $out = Join-Path $TestDrive 'skip'
        New-Item -ItemType Directory -Path $out | Out-Null
        Copy-Item -LiteralPath $script:RexJson[0].FullName -Destination (Join-Path $out 'X-IPU-Assessment.json')
        Invoke-RedactExisting $out | Should -Be 1
        @(Get-ChildItem -LiteralPath $out -Filter 'REDACTED-*').Count | Should -Be 0
    }
    It 'says clearly when nothing is there' {
        Invoke-RedactExisting (Join-Path $TestDrive 'nowhere') | Should -Be 1
        $empty = Join-Path $TestDrive 'empty'
        New-Item -ItemType Directory -Path $empty | Out-Null
        Invoke-RedactExisting $empty | Should -Be 1
    }
    It 'recovers the names to redact from the result rows' {
        $rows = @(
            [pscustomobject]@{ Area = 'TASKS'; Item = '\Nightly'; Value = 'RunAs=CORP\adm-jdoe'; Details = '' }
            [pscustomobject]@{ Area = 'SERVICES'; Item = 'App'; Value = 'App'; Details = 'State=Running | StartMode=Auto | LogOnAs=svc_app@corp.example.test' }
            [pscustomobject]@{ Area = 'GROUP_POLICY'; Item = 'GPO: Web Lockdown'; Value = 'Applied'; Details = 'Linked at x | WMI filter: VM only | Query: SELECT 1' }
        )
        $l = Get-RedactionLiteralFromResult $rows
        (@($l | ForEach-Object { $_.Kind + '=' + $_.Value }) -join '; ') | Should -Be 'ACCOUNT=CORP\adm-jdoe; ACCOUNT=svc_app@corp.example.test; GPO=Web Lockdown; NAME=VM only'
    }
}

Describe 'File shares in the post-upgrade comparison (#95)' {
    It 'a share missing after the upgrade is an ACTION' {
        $d = Compare-IPUSnapshot @{ Shares = @('Data', 'Scans') } @{ Shares = @('Data') }
        $row = @($d | Where-Object { $_.Item -eq 'File shares missing after upgrade' })[0]
        $row.Status | Should -Be 'ACTION'
        $row.Details | Should -Be 'Scans'
    }
}

Describe 'OU path of the computer object (#99)' {
    It '<Dn> -> <Expected>' -TestCases @(
        @{ Dn = 'CN=SRV01,OU=Web,OU=Servers,DC=corp,DC=example,DC=test'; Expected = 'corp.example.test/Servers/Web' }
        @{ Dn = 'CN=SRV02,CN=Computers,DC=corp,DC=example,DC=test';     Expected = 'corp.example.test/Computers' }
        @{ Dn = 'CN=SRV03,OU=Sales\, North,DC=corp,DC=test';             Expected = 'corp.test/Sales, North' }
        @{ Dn = '';                                                       Expected = '' }
    ) {
        ConvertTo-AdLocation $Dn | Should -Be $Expected
    }
    It 'the post-upgrade comparison reports a moved computer object, and nothing when unchanged' {
        $before = @{ Ou = 'CN=SRV01,OU=Web,DC=corp,DC=test' }
        $moved = Compare-IPUSnapshot $before @{ Ou = 'CN=SRV01,CN=Computers,DC=corp,DC=test' }
        $row = @($moved | Where-Object { $_.Item -eq 'Computer object moved in AD' })
        $row.Count | Should -Be 1
        $row[0].Status | Should -Be 'WARNING'
        $same = Compare-IPUSnapshot $before $before
        @($same | Where-Object { $_.Item -eq 'Computer object moved in AD' }).Count | Should -Be 0
        $old = Compare-IPUSnapshot @{} @{ Ou = 'CN=SRV01,DC=corp,DC=test' }
        @($old | Where-Object { $_.Item -eq 'Computer object moved in AD' }).Count | Should -Be 0
    }
    It 'redaction replaces the OU path and the distinguished name, including the DC= parts' {
        $script:Data = @{}
        $ctx = New-RedactionContext 'SRV01' 'corp.example.test'
        $out = Protect-ReportText 'corp.example.test/Servers/Web | DistinguishedName=CN=SRV01,OU=Web,OU=Servers,DC=corp,DC=example,DC=test' $ctx
        $out | Should -Not -Match 'corp|example|Servers|Web|SRV01'
        $out | Should -Match '^(DOMAIN-\d+)/NAME-\d+/NAME-\d+ \| DistinguishedName=CN=NAME-\d+,OU=NAME-\d+,OU=NAME-\d+,DC=\1$'
    }
}

Describe 'Status meaning right after the Summary (#96)' {
    It 'orders the report: Summary, Status meaning, decision, planning, checklist, chapters (<Mode>)' -TestCases @(@{ Mode = 'Pre' }, @{ Mode = 'Post' }) {
        $script:Results.Clear(); $script:CheckRuns.Clear()
        Add-Result 'STORAGE' 'CFreeSpace' 'ACTION' 'low'
        Add-Result 'STORAGE' 'PartitionAfterC' 'WARNING' 'Yes'
        Add-Result 'CHECKLIST' 'Backup and fallback' 'MANUAL' 'x' -Kind 'Checklist'
        $AssessmentMode = $Mode
        $html = New-IPUReportHtml -Results $script:Results.ToArray() -CheckRuns $script:CheckRuns.ToArray() -OverallStatus 'ACTION' -CompletedTime (Get-Date)
        $positions = @('<h2>Summary</h2>', '<h2>Status meaning</h2>', '<section id="decision">', '<section id="planning">', '<details') | ForEach-Object { $html.IndexOf($_) }
        foreach ($p in $positions) { $p | Should -BeGreaterThan -1 }
        for ($i = 1; $i -lt $positions.Count; $i++) { $positions[$i] | Should -BeGreaterThan $positions[$i - 1] }
        if ($Mode -eq 'Pre') { $html.IndexOf('<section id="checklist">') | Should -BeGreaterThan $positions[3] }
    }
}

Describe 'Domain role wording (#98)' {
    It 'DomainRole <Role> is "<Expected>"' -TestCases @(
        @{ Role = 0; Domain = 'WORKGROUP';         Expected = 'Workgroup computer (standalone), workgroup WORKGROUP' }
        @{ Role = 1; Domain = 'corp.example.test'; Expected = 'Member workstation' }
        @{ Role = 2; Domain = 'WORKGROUP';         Expected = 'Workgroup server (standalone), workgroup WORKGROUP' }
        @{ Role = 2; Domain = '';                  Expected = 'Workgroup server (standalone)' }
        @{ Role = 3; Domain = 'corp.example.test'; Expected = 'Member server' }
        @{ Role = 4; Domain = 'corp.example.test'; Expected = 'Backup domain controller' }
        @{ Role = 5; Domain = 'corp.example.test'; Expected = 'Primary domain controller' }
        @{ Role = 9; Domain = '';                  Expected = 'Unknown role (9)' }
    ) {
        Get-DomainRoleText $Role $Domain | Should -Be $Expected
    }
}

Describe 'Report chapters open and closed (#97)' {
    BeforeAll {
        $script:Results.Clear(); $script:CheckRuns.Clear()
        Add-Result 'STORAGE' 'PartitionAfterC' 'WARNING' 'Yes'                                    # finding -> Storage open
        Add-Result 'SERVICES' 'AutomaticServices' 'INFO' 'Total=10'                              # evidence only -> closed
        Add-Result 'RDP' 'NetworkLevelAuthentication' 'WARNING' 'Disabled' -Kind 'Observation'  # observation only -> closed
        Add-Result 'BACKUP' 'VSSWriters' 'MANUAL' 'Unreadable'                                  # MANUAL finding -> open
        $script:ChapterHtml = New-IPUReportHtml -Results $script:Results.ToArray() -CheckRuns $script:CheckRuns.ToArray() -OverallStatus 'WARNING' -CompletedTime (Get-Date)
    }
    It '<Chapter> is <State>' -TestCases @(
        @{ Chapter = 'Storage';                        State = 'open' }
        @{ Chapter = 'Backup and Recovery';            State = 'open' }
        @{ Chapter = 'Services and Scheduled Tasks';   State = 'closed' }
        @{ Chapter = 'Access and Remote Desktop';      State = 'closed' }
    ) {
        $tag = [string][regex]::Match([string]$script:ChapterHtml, '<details[^>]*><summary>' + [regex]::Escape($Chapter) + ' \(').Value
        $tag | Should -Not -BeNullOrEmpty
        [regex]::IsMatch($tag, '<details[^>]*\sopen[\s>]') | Should -Be ($State -eq 'open')
    }
    It 'explains the rule and offers Expand all / Collapse all buttons (hidden without JavaScript)' {
        $script:ChapterHtml | Should -Match '<p class="chapters-note">Chapters with findings to act on are open'
        $script:ChapterHtml | Should -Match '<button type="button" class="tgl" data-open="1">Expand all</button>'
        $script:ChapterHtml | Should -Match '<button type="button" class="tgl" data-open="0">Collapse all</button>'
        $script:ChapterHtml | Should -Match '\.js-only\{display:none\}'
    }
    It 'opens every chapter for printing and restores them afterwards' {
        $script:ChapterHtml | Should -Match 'addEventListener\("beforeprint"'
        $script:ChapterHtml | Should -Match 'addEventListener\("afterprint"'
    }
}

Describe 'Source end of support (#102)' {
    It '<Release> on <Today> is <Status>' -TestCases @(
        @{ Release = '2012R2'; Today = '2023-10-10'; Status = 'INFO';    Ended = $false }
        @{ Release = '2012R2'; Today = '2023-10-11'; Status = 'WARNING'; Ended = $true }
        @{ Release = '2012';   Today = '2026-10-08'; Status = 'WARNING'; Ended = $true }
        @{ Release = '2016';   Today = '2027-01-12'; Status = 'INFO';    Ended = $false }
        @{ Release = '2016';   Today = '2027-01-13'; Status = 'WARNING'; Ended = $true }
        @{ Release = '2019';   Today = '2026-10-08'; Status = 'INFO';    Ended = $false }
        @{ Release = '2022';   Today = '2031-10-15'; Status = 'WARNING'; Ended = $true }
        @{ Release = '';       Today = '2026-10-08'; Status = 'INFO';    Ended = $false }
    ) {
        $d = Get-SupportLifecycleDecision $Release ([datetime]::ParseExact($Today, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture))
        $d.Status | Should -Be $Status
        $d.Ended | Should -Be $Ended
    }
    It 'counts the days left while supported and mentions ESU once ended' {
        (Get-SupportLifecycleDecision '2016' ([datetime]'2027-01-02')).Value | Should -Match '\(10 days\)'
        (Get-SupportLifecycleDecision '2012R2' ([datetime]'2026-10-08')).Text | Should -Match 'ESU'
    }
}

Describe 'Target licensing per activation channel (#102)' {
    It '<Channel> / <Description> is <Kind>' -TestCases @(
        @{ Channel = 'Volume:GVLK'; Description = 'Windows(R) Operating System, VOLUME_KMSCLIENT channel'; Kind = 'KMS' }
        @{ Channel = 'Volume:MAK';  Description = 'Windows(R) Operating System, VOLUME_MAK channel';       Kind = 'MAK' }
        @{ Channel = 'OEM:DM';      Description = 'Windows(R) Operating System, OEM_DM channel';           Kind = 'OEM' }
        @{ Channel = 'Retail';      Description = 'Windows(R) Operating System, RETAIL channel';           Kind = 'Retail' }
        @{ Channel = 'Retail';      Description = 'Windows(R) Operating System, VIRTUAL_MACHINE_ACTIVATION channel'; Kind = 'AVMA' }
        @{ Channel = '';            Description = '';                                                       Kind = 'Unknown' }
    ) {
        Get-ActivationChannelKind $Channel $Description | Should -Be $Kind
    }
    It '<Kind> needs <Expect>' -TestCases @(
        @{ Kind = 'KMS';     Expect = 'CSVLK' }
        @{ Kind = 'MAK';     Expect = 'Windows Server 2025 MAK' }
        @{ Kind = 'AVMA';    Expect = 'Hyper-V host must run Datacenter' }
        @{ Kind = 'OEM';     Expect = 'tied to the original hardware' }
        @{ Kind = 'Retail';  Expect = 'retail Windows Server 2025 licence' }
        @{ Kind = 'Unknown'; Expect = 'KMS host/ADBA, MAK or AVMA host' }
    ) {
        (Get-TargetLicensingDecision $Kind 'kms.example.test:1688' '2025').Text | Should -Match $Expect
    }
    It 'only the KMS and unknown channels mention the KMS endpoint' {
        (Get-TargetLicensingDecision 'KMS' 'kms.example.test:1688' '2025').Value | Should -Match 'kms\.example\.test'
        (Get-TargetLicensingDecision 'MAK' 'kms.example.test:1688' '2025').Value | Should -Not -Match 'KMS'
    }
}

Describe 'Redaction of user-rights entries (#156)' {
    BeforeAll {
        $script:RightsIn = 'CORP.LOCALDOM\Group Policy Creator Owners [S-1-5-21-1111111111-2222222222-3333333333-520] | CORP.LOCALDOM\ACME-T0-Privileged Accounts-All [S-1-5-21-1111111111-2222222222-3333333333-11234] | CORP\Acme Server Admins [S-1-5-21-1111111111-2222222222-3333333333-11235] | BUILTIN\Administrators [S-1-5-32-544] | NT AUTHORITY\LOCAL SERVICE'
    }
    It 'replaces custom group names with spaces and a full domain name' {
        $out = Protect-ReportText $script:RightsIn (New-RedactionContext 'SRV01' 'corp')
        $out | Should -Not -Match 'ACME|Acme|Privileged|LOCALDOM|CORP'
        $out | Should -Not -Match 'S-1-5-21'
    }
    It 'keeps built-in domain groups and local built-ins readable' {
        $out = Protect-ReportText $script:RightsIn (New-RedactionContext 'SRV01' 'corp')
        $out | Should -Match 'DOMAIN-\d+\\Group Policy Creator Owners \[SID-\d+\]'
        $out | Should -Match 'BUILTIN\\Administrators \[S-1-5-32-544\]'
        $out | Should -Match 'NT AUTHORITY\\LOCAL SERVICE'
    }
    It 'replaces a domain with an unknown DNS suffix as a whole' {
        $out = Protect-ReportText 'The user "CORP.LOCALDOM\SRV01$" does not have RSoP data.' (New-RedactionContext 'SRV01' 'corp')
        $out | Should -Be 'The user "DOMAIN-1\HOST-1$" does not have RSoP data.'
    }
    It 'gives the NetBIOS name, the DNS name and a suffixed form one placeholder' {
        $ctx = New-RedactionContext 'SRV01' 'corp.example.test'
        $out = Protect-ReportText 'Domain=corp.example.test | CORP\Domain Admins [S-1-5-21-1-2-3-512] | CORP.LOCALDOM\x' $ctx
        @([regex]::Matches($out, 'DOMAIN-\d+') | ForEach-Object { $_.Value } | Sort-Object -Unique).Count | Should -Be 1
    }
    It 'treats a local account on this server as an account' {
        $out = Protect-ReportText 'SRV01\localadmin [S-1-5-21-9-9-9-1001]' (New-RedactionContext 'SRV01' 'corp.example.test')
        $out | Should -Match '^ACCOUNT-\d+ \[SID-\d+\]$'
    }
}

Describe 'Recovery partition after C: (#161)' {
    BeforeAll {
        function New-Part($Number, $OffsetMB, $SizeMB, $Recovery) { [pscustomobject]@{ PartitionNumber = $Number; Offset = [double]$OffsetMB * 1MB; SizeMB = $SizeMB; IsRecovery = $Recovery } }
    }
    It 'reads status and location from reagentc /info' {
        $r = ConvertFrom-ReagentcInfo ("Windows Recovery Environment (Windows RE) and system reset configuration`r`nInformation:`r`n    Windows RE status:         Enabled`r`n    Windows RE location:       \\?\GLOBALROOT\device\harddisk0\partition3\Recovery\WindowsRE")
        $r.Enabled | Should -BeTrue
        $r.Disk | Should -Be 0
        $r.Partition | Should -Be 3
    }
    It 'returns nothing it cannot read' {
        $r = ConvertFrom-ReagentcInfo ''
        $r.Enabled | Should -BeNullOrEmpty
        $r.Partition | Should -BeNullOrEmpty
    }
    It '<Case> -> <Kind>' -TestCases @(
        @{ Case = 'MBR, only System Reserved (Pre)';         Mode = 'Pre';  Layout = @('1,1,500,0', '2,501,150000,0');                    Kind = 'LikelyNew' }
        @{ Case = 'GPT, 500 MB WinRE at the start (Pre)';    Mode = 'Pre';  Layout = @('1,1,500,1', '2,501,100,0', '4,700,800000,0');     Kind = 'LikelyNew' }
        @{ Case = 'big enough WinRE at the start (Pre)';      Mode = 'Pre';  Layout = @('1,1,1024,1', '2,1100,100,0', '4,1300,800000,0');  Kind = 'Fine' }
        @{ Case = 'new partition after C: (Post)';            Mode = 'Post'; Layout = @('1,1,500,0', '2,501,160000,0', '3,160600,901,1');   Kind = 'AfterC' }
        @{ Case = 'no recovery partition (Post)';             Mode = 'Post'; Layout = @('1,1,500,0', '2,501,110000,0');                     Kind = 'Fine' }
    ) {
        $built = @($Layout | ForEach-Object { $f = $_ -split ','; New-Part ([int]$f[0]) ([double]$f[1]) ([double]$f[2]) ($f[3] -eq '1') })
        $cNumber = if ($Case -like 'GPT*' -or $Case -like 'big*') { 4 } else { 2 }
        (Get-RecoveryPartitionDecision $built $cNumber $null $Mode).Kind | Should -Be $Kind
    }
    It 'names the partition after C:, prefers the one WinRE is on, and warns about reagentc /disable' {
        $parts = @((New-Part 1 1 500 $true), (New-Part 2 600 100 $false), (New-Part 5 800 800000 $false), (New-Part 6 801000 901 $true))
        $d = Get-RecoveryPartitionDecision $parts 5 6 'Post'
        $d.PartitionNumber | Should -Be 6
        $d.Value | Should -Match 'P6 \(901 MB\)'
        $d.Text | Should -Match 'Never skip reagentc /disable'
        $d.Text | Should -Match 'WinRE is on it'
    }
    It 'builds the exact Setup and removal commands' {
        (Get-RecommendationCommand 'SetupNoRecoveryPartition').Command | Should -Be 'setup.exe /ResizeRecoveryPartition Disable'
        $lines = (Get-RecommendationCommand 'RemoveRecoveryPartition' @{ Disk = 0; Partition = 3 }).Command -split '\r?\n'
        $lines[0] | Should -Be 'reagentc /info'
        $lines[1] | Should -Be 'reagentc /disable'
        $lines | Should -Contain '  select partition 3'
        $lines | Should -Contain '  delete partition override'
        $lines[-2] | Should -Be 'reagentc /enable'
    }
}

Describe 'LGPO edge cases (#150)' {
    It 'points to the LGPO backup only when this run makes one' {
        Get-LocalPolicyAdvice $true $true | Should -Match 'local policy backup \(LGPO\)'
        Get-LocalPolicyAdvice $false $true | Should -Not -Match 'LGPO'
        Get-LocalPolicyAdvice $true $false | Should -Not -Match 'LGPO'
        Get-LocalPolicyAdvice $false $false | Should -Match 'gpresult /scope computer'
    }
    It 'an empty -LgpoExe means LGPO is not available, without testing an empty path' {
        $LgpoExe = ''
        Test-LgpoAvailable | Should -BeFalse
    }
}

Describe 'Group Policy from the registry when gpresult has no RSoP data (#160)' {
    It 'converts GPO-List entries to applied GPOs with readable link paths' {
        $gp = ConvertFrom-GpoListEntry @(
            [pscustomobject]@{ DisplayName = 'Server Baseline'; GPOName = '{11111111-1111-1111-1111-111111111111}'; Link = 'LDAP://OU=Web,OU=Servers,DC=corp,DC=example,DC=test' },
            [pscustomobject]@{ DisplayName = 'Local Group Policy'; GPOName = 'LocalGPO'; Link = 'Local' },
            [pscustomobject]@{ DisplayName = ''; GPOName = ''; Link = '' })
        @($gp.Gpos).Count | Should -Be 2
        $gp.Gpos[0].Applied | Should -BeTrue
        $gp.Gpos[0].Guid | Should -Be '{11111111-1111-1111-1111-111111111111}'
        $gp.Gpos[0].Links | Should -Be 'corp.example.test/Servers/Web'
        $gp.Gpos[1].Guid | Should -Be ''
        $gp.Gpos[1].Links | Should -Be 'Local'
    }
}

Describe 'Redact existing reports: one placeholder per server across files (#157)' {
    BeforeAll {
        $dir = Join-Path $TestDrive 'fleet'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $sample = Join-Path $PSScriptRoot '..\docs\samples'
        $json = [IO.File]::ReadAllText((Join-Path $sample 'sample-result.json'))
        $html = [IO.File]::ReadAllText((Join-Path $sample 'sample-report.html'))
        foreach ($f in @(@{ Name = 'SRV-APP01-IPU-Assessment'; Host = 'SRV-APP01' }, @{ Name = 'SRV-APP01-IPU-PostUpgrade'; Host = 'SRV-APP01' }, @{ Name = 'SRV-DB02-IPU-Assessment'; Host = 'SRV-DB02' })) {
            $obj = $json.Replace('SRV-APP01', $f.Host) | ConvertFrom-Json
            if ($f.Name -like '*PostUpgrade') { $obj.Mode = 'Post' }
            [IO.File]::WriteAllText((Join-Path $dir ($f.Name + '.json')), ($obj | ConvertTo-Json -Depth 8))
            [IO.File]::WriteAllText((Join-Path $dir ($f.Name + '.html')), $html.Replace('SRV-APP01', $f.Host))
        }
        $script:FleetCode = Invoke-RedactExisting $dir
        $script:FleetJson = @(Get-ChildItem -LiteralPath $dir -Filter 'REDACTED-*.json' | Sort-Object Name)
    }
    It 'redacts all three reports' {
        $script:FleetCode | Should -Be 0
        $script:FleetJson.Count | Should -Be 3
    }
    It 'names each copy after the server placeholder, and the JSON agrees' {
        foreach ($f in $script:FleetJson) {
            $f.Name | Should -Match '^REDACTED-\d{8}-\d{6}-(HOST-\d+)-IPU-(Assessment|PostUpgrade)\.json$'
            $tag = [regex]::Match($f.Name, 'HOST-\d+').Value
            ([IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json).ComputerName | Should -Be $tag
        }
    }
    It 'a fleet overview of the redacted copies shows one row per server and mode' {
        $only = Join-Path $TestDrive 'fleet-redacted'
        $mergeOut = Join-Path $TestDrive 'fleet-overview'
        New-Item -ItemType Directory -Path $only, $mergeOut | Out-Null
        foreach ($f in $script:FleetJson) { Copy-Item -LiteralPath $f.FullName -Destination $only }
        $null = & (Join-Path $PSScriptRoot '..\src\Merge-IPUAssessments.ps1') -InputFolder $only -OutputFolder $mergeOut
        $rows = @(Import-Csv -LiteralPath (Join-Path $mergeOut 'IPU-Fleet-Servers.csv') -Delimiter ';')
        $rows.Count | Should -Be 3
        @($rows | ForEach-Object { $_.ComputerName + '|' + $_.Mode } | Sort-Object -Unique).Count | Should -Be 3
        @($rows | ForEach-Object { $_.ComputerName } | Sort-Object -Unique).Count | Should -Be 2
    }
    It 'gives one server the same placeholder in pre and post, and different servers different ones' {
        $tags = @($script:FleetJson | ForEach-Object { [regex]::Match($_.Name, 'HOST-\d+').Value + '|' + [regex]::Match($_.Name, 'Assessment|PostUpgrade').Value })
        @($tags | ForEach-Object { ($_ -split '\|')[0] } | Sort-Object -Unique) -join ',' | Should -Be 'HOST-1,HOST-2'   # numbered first (#172)
        $post = @($tags | Where-Object { $_ -like '*|PostUpgrade' })[0].Split('|')[0]
        @($tags | Where-Object { $_ -eq ($post + '|Assessment') }).Count | Should -Be 1
    }
}

Describe 'Post-upgrade comparison: expected changes and NLA (#158)' {
    BeforeAll {
        function New-Svc([string]$Name, [string]$State, [string]$Mode) { [pscustomobject]@{ Name = $Name; State = $State; StartMode = $Mode } }
        $before = [pscustomobject]@{
            Services = @((New-Svc 'DiagTrack' 'Running' 'Auto'), (New-Svc 'IKEEXT' 'Running' 'Auto'), (New-Svc 'AppSvc' 'Running' 'Auto'), (New-Svc 'CDPUserSvc_11a24784c' 'Running' 'Auto'), (New-Svc 'tiledatamodelsvc' 'Running' 'Auto'), (New-Svc 'GoneSvc' 'Running' 'Auto'))
            Ports = @('UDP:500', 'UDP:4500', 'TCP:8080', 'TCP:9000')
            PortOwners = [pscustomobject]@{ 'TCP:9000' = 'Service DiagTrack' }
            Features = @('PowerShell-V2', 'Windows-Defender-Gui', 'NET-Framework-Core', 'Web-Server', 'SNMP-Service')
            Nla = 'On'
        }
        $after = [pscustomobject]@{
            Services = @((New-Svc 'DiagTrack' 'Stopped' 'Disabled'), (New-Svc 'IKEEXT' 'Stopped' 'Manual'), (New-Svc 'AppSvc' 'Stopped' 'Auto'), (New-Svc 'CDPUserSvc_d6e7e9e9' 'Running' 'Auto'))
            Ports = @(); Features = @('Web-Server'); Nla = 'Off'
        }
        $script:Diff158 = Compare-IPUSnapshot $before $after
        function Get-DiffRow([string]$Item) { @($script:Diff158 | Where-Object { $_.Item -eq $Item }) | Select-Object -First 1 }
    }
    It 'a service now disabled is a WARNING of its own, not ACTION' {
        (Get-DiffRow 'Automatic services now disabled').Status | Should -Be 'WARNING'
        (Get-DiffRow 'Automatic services now disabled').Details | Should -Match 'DiagTrack'
        (Get-DiffRow 'Automatic services no longer running').Details | Should -Be 'AppSvc (Stopped, Auto)'
    }
    It 'Microsoft start-type changes and removals are INFO' {
        $r = Get-DiffRow 'Service changes made by Windows'
        $r.Status | Should -Be 'INFO'
        $r.Details | Should -Match 'IKEEXT'
        $r.Details | Should -Match 'tiledatamodelsvc'
    }
    It 'per-user services with a new suffix are not missing; other missing services still are' {
        (Get-DiffRow 'Services no longer present').Details | Should -Be 'GoneSvc'
        ConvertTo-ServiceBaseName 'CDPUserSvc_11a24784c' | Should -Be 'CDPUserSvc'
        ConvertTo-ServiceBaseName 'MSSQLSERVER' | Should -Be 'MSSQLSERVER'
    }
    It 'ports closed with their disabled or changed service are INFO (known ports and recorded owners)' {
        (Get-DiffRow 'Ports closed with their service').Details | Should -Be 'TCP:9000, UDP:4500, UDP:500'
        (Get-DiffRow 'Listening ports missing after upgrade').Details | Should -Be 'TCP:8080'
    }
    It 'features removed by Microsoft are INFO; .NET 3.5 is a WARNING with the reinstall command; others stay' {
        (Get-DiffRow 'Windows features removed or renamed by Microsoft').Status | Should -Be 'INFO'
        (Get-DiffRow '.NET Framework 3.5 removed by the upgrade').Recommendation | Should -Match 'Install-WindowsFeature NET-Framework-Core'
        (Get-DiffRow 'Windows features missing after upgrade').Details | Should -Be 'SNMP-Service'
    }
    It 'NLA turned off is an ACTION; unchanged or turned on is not reported' {
        (Get-DiffRow 'RDP Network Level Authentication turned off').Status | Should -Be 'ACTION'
        # Assign first: the function returns the list as one object.
        $same = Compare-IPUSnapshot ([pscustomobject]@{ Nla = 'On' }) ([pscustomobject]@{ Nla = 'On' })
        $same.Count | Should -Be 0
        $better = Compare-IPUSnapshot ([pscustomobject]@{ Nla = 'Off' }) ([pscustomobject]@{ Nla = 'On' })
        $better.Count | Should -Be 0
    }
    It 'pending renames that are only installer leftovers are harmless' {
        Test-PendingRenameHarmless @('\??\C:\Config.Msi\1bc393.rbf', '', '\??\C:\Program Files (x86)\Microsoft\EdgeUpdate\1.3.283.15', '') | Should -BeTrue
        Test-PendingRenameHarmless @('\??\C:\Config.Msi\1bc393.rbf', '', '\??\C:\Program Files\Example\agent.dll', '') | Should -BeFalse
        Test-PendingRenameHarmless @() | Should -BeFalse
    }
}

Describe 'RedactExisting recovers every name the collector registers (#172)' {
    It 'recovers share names and descriptions from the share rows' {
        $rows = @(
            [pscustomobject]@{ Area = 'FILE_SHARES'; Item = 'FileShares'; Value = 'Count=2'; Details = 'Finance, Scans$' }
            [pscustomobject]@{ Area = 'FILE_SHARES'; Item = 'Share: Finance'; Value = 'D:\Finance'; Details = @('Path=D:\Finance', 'Description=Contoso finance team', 'Share permissions: Everyone: Read') }
            [pscustomobject]@{ Area = 'FILE_SHARES'; Item = 'Share: Scans$'; Value = 'D:\Scans'; Details = @('Path=D:\Scans', 'Share permissions: not readable') }
        )
        $l = Get-RedactionLiteralFromResult $rows
        (@($l | ForEach-Object { $_.Kind + '=' + $_.Value }) -join '; ') | Should -Be 'NAME=Finance; NAME=Contoso finance team; NAME=Scans$'
    }
    It 'has a recovery rule for every Add-RedactionLiteral call site in the collector' {
        # When this fails, a new call site was added: add a rule to
        # Get-RedactionLiteralFromResult and its pattern here.
        $src = [IO.File]::ReadAllLines((Join-Path $PSScriptRoot '..\src\Windows-IPU-Readiness-Assessment.ps1'))
        $sites = @($src | Where-Object { $_ -match 'Add-RedactionLiteral ' -and $_ -notmatch '^\s*function ' -and $_ -notmatch 'Get-RedactionLiteralFromResult' } | ForEach-Object { $_.Trim() })
        $known = @(
            'Add-RedactionLiteral $g.Name ''GPO''',
            'if ($g.FilterName) { Add-RedactionLiteral $g.FilterName ''NAME'' }',
            'Add-RedactionLiteral $filter.Name ''NAME''',
            'Add-RedactionLiteral ([string]$sh.Name) ''NAME''',
            'if ($sh.Description) { Add-RedactionLiteral ([string]$sh.Description) ''NAME'' }',
            'foreach ($s in @($script:Data.Services | Where-Object { $_.StartName })) { Add-RedactionLiteral ([string]$s.StartName) ''ACCOUNT'' }',
            'if ($user -and $user -notmatch $builtIn) { Add-RedactionLiteral $user ''ACCOUNT'' }',
            'Add-RedactionLiteral ([string]$cluster.Name) ''HOST''',
            'foreach ($n in @(Get-ClusterNode -ErrorAction SilentlyContinue)) { Add-RedactionLiteral ([string]$n.Name) ''HOST''; Add-Result ''CLUSTER'' (''Node: '' + $n.Name) ''INFO'' (''State='' + $n.State) -Source ''Get-ClusterNode'' }',
            'if ($act.KmsHost) { foreach ($h in @($act.KmsHost, ($act.KmsHost -split ''\.'')[0]) | Select-Object -Unique) { Add-RedactionLiteral $h ''HOST'' }; $script:Data.KmsEndpoint = $act.KmsEndpoint } elseif ($script:Data.ActivationKind -eq ''KMS'') { $script:Data.KmsEndpoint = ''found via DNS'' }',
            'foreach ($p in $printers) { Add-RedactionLiteral $p.Name ''NAME''; if ($p.ShareName) { Add-RedactionLiteral $p.ShareName ''NAME'' } }',
            'foreach ($pt in $ports) { Add-RedactionLiteral $pt.Name ''NAME''; if ($pt.Address -and $pt.Address -notmatch ''^[0-9.:]+$'') { Add-RedactionLiteral $pt.Address ''HOST'' } }'
        )
        @($sites | Where-Object { $known -notcontains $_ }) | Should -BeNullOrEmpty
    }
}

Describe 'Post-upgrade comparison: per-user services and on-demand ports (#173)' {
    BeforeAll {
        function New-Svc([string]$Name, [string]$State, [string]$Mode) { [pscustomobject]@{ Name = $Name; State = $State; StartMode = $Mode } }
        $before = [pscustomobject]@{
            Services = @((New-Svc 'CDPUserSvc_11a24784c' 'Running' 'Auto'), (New-Svc 'OneSyncSvc_11a24784c' 'Running' 'Auto'), (New-Svc 'GoneSvc' 'Running' 'Auto'), (New-Svc 'SSDPSRV' 'Running' 'Manual'), (New-Svc 'AppSvc' 'Running' 'Auto'))
            Ports = @('UDP:1900', 'TCP:9000', 'TCP:8080')
            PortOwners = [pscustomobject]@{ 'TCP:9000' = 'Service AppSvc'; 'TCP:8080' = 'Process app' }
        }
        $after = [pscustomobject]@{
            Services = @((New-Svc 'SSDPSRV' 'Stopped' 'Manual'), (New-Svc 'AppSvc' 'Running' 'Auto'))
            Ports = @()
        }
        $script:Diff173 = Compare-IPUSnapshot $before $after
        function Get-Row173([string]$Item) { @($script:Diff173 | Where-Object { $_.Item -eq $Item }) | Select-Object -First 1 }
    }
    It 'per-user service instances without a signed-in user are INFO, other missing services stay WARNING' {
        (Get-Row173 'Service changes made by Windows').Details | Should -Match 'CDPUserSvc \(per-user service'
        (Get-Row173 'Service changes made by Windows').Details | Should -Match 'OneSyncSvc'
        (Get-Row173 'Services no longer present').Details | Should -Be 'GoneSvc'
    }
    It 'a port whose service is no longer started automatically is INFO, even when the service was Manual before' {
        (Get-Row173 'Ports closed with their service').Details | Should -Be 'UDP:1900'
    }
    It 'a port whose service still runs automatically, or with a process owner, stays WARNING' {
        (Get-Row173 'Listening ports missing after upgrade').Details | Should -Be 'TCP:8080, TCP:9000'
    }
}

Describe 'RDP NLA in the Summary (#174)' {
    It '<Now> / <Before> -> <Text>' -TestCases @(
        @{ Now = 'On';  Before = '';    Text = 'NLA on' }
        @{ Now = 'Off'; Before = '';    Text = 'NLA off' }
        @{ Now = 'Off'; Before = 'On';  Text = 'NLA off (was on before the upgrade)' }
        @{ Now = 'On';  Before = 'Off'; Text = 'NLA on (was off before the upgrade)' }
        @{ Now = 'On';  Before = 'On';  Text = 'NLA on' }
        @{ Now = '';    Before = 'On';  Text = 'NLA unknown' }
        @{ Now = 'Unknown'; Before = ''; Text = 'NLA unknown' }
    ) {
        Get-NlaFactText $Now $Before | Should -Be $Text
    }
    It 'folds NLA into the RDP access line' {
        $script:Data = @{ RdpSummary = 'GO (no local blocker)'; NlaState = 'Off'; NlaBefore = 'On' }
        Get-RdpAccessFact | Should -Be 'GO (no local blocker), NLA off (was on before the upgrade)'
        $script:Data = @{}
        Get-RdpAccessFact | Should -Be 'Not reported, NLA unknown'
    }
}

Describe 'Activation per channel, with the KMS host and renewal (#171)' {
    It 'a KMS client names the host it found via DNS and the days to renewal' {
        $d = Get-ActivationDecision 'KMS' 1 'Licensed' 'Volume:GVLK' (173 * 1440 + 30) 'kms01.corp.example.test' '1688' '' ''
        $d.Status | Should -Be 'OK'
        $d.Value | Should -Be 'Licensed (KMS client), activated by kms01.corp.example.test:1688, found via DNS. Renewal due in 173 days'
        $d.KmsHost | Should -Be 'kms01.corp.example.test'
    }
    It 'a host set on the server says so' {
        (Get-ActivationDecision 'KMS' 1 'Licensed' 'Volume:GVLK' 0 'kms01' '1688' 'kms02.corp.example.test' '1688').Value | Should -Match 'activated by kms02\.corp\.example\.test:1688, set manually on this server'
    }
    It 'few days left is a WARNING; not activated is an ACTION with the reason' {
        $low = Get-ActivationDecision 'KMS' 1 'Licensed' 'Volume:GVLK' (12 * 1440) 'kms01' '1688' '' ''
        $low.Status | Should -Be 'WARNING'
        $low.Text | Should -Match '_vlmcs\._tcp'
        $off = Get-ActivationDecision 'KMS' 2 'OOBGrace' 'Volume:GVLK' (20 * 1440) '' '' '' ''
        $off.Status | Should -Be 'ACTION'
        $off.Value | Should -Be 'Not activated (OOBGrace, KMS client)'
    }
    It '<Kind> gets its own text and no KMS wording' -TestCases @(
        @{ Kind = 'MAK';    Expect = 'Licensed (MAK), activated permanently - no renewal needed' }
        @{ Kind = 'AVMA';   Expect = 'Licensed (AVMA), activated through the Hyper-V host' }
        @{ Kind = 'OEM';    Expect = 'Licensed (OEM)' }
        @{ Kind = 'Retail'; Expect = 'Licensed (Retail)' }
    ) {
        $d = Get-ActivationDecision $Kind 1 'Licensed' 'x' 0 'kms01' '1688' '' ''
        $d.Value | Should -Be $Expect
        $d.Value | Should -Not -Match 'KMS'
        $d.KmsHost | Should -Be ''
    }
    It 'RedactExisting recovers the KMS host name' {
        $rows = @([pscustomobject]@{ Area = 'LICENSING'; Item = 'CurrentActivation'; Value = 'Licensed (KMS client), activated by kms01:1688, found via DNS'; Details = @('Channel=Volume:GVLK', 'PartialProductKey=ABCDE', 'KMS host: kms01:1688 (found via DNS)') })
        $l = Get-RedactionLiteralFromResult $rows
        (@($l | ForEach-Object { $_.Kind + '=' + $_.Value }) -join ';') | Should -Be 'HOST=kms01'
    }
}

Describe 'SPECIAL servers (#152)' {
    It '<Case> -> <Kind>' -TestCases @(
        @{ Case = 'member server';                         Role = 3; Feature = $false; Svc = $false; Key = $false; Block = $true;  Kind = '' }
        @{ Case = 'domain controller';                     Role = 5; Feature = $false; Svc = $false; Key = $false; Block = $true;  Kind = 'DomainController' }
        @{ Case = 'domain controller, block switched off'; Role = 4; Feature = $false; Svc = $false; Key = $false; Block = $false; Kind = '' }
        @{ Case = 'cluster node';                          Role = 3; Feature = $true;  Svc = $true;  Key = $true;  Block = $true;  Kind = 'Cluster' }
        @{ Case = 'feature only, no cluster';              Role = 3; Feature = $true;  Svc = $false; Key = $false; Block = $true;  Kind = '' }
        @{ Case = 'signals disagree';                      Role = 3; Feature = $true;  Svc = $true;  Key = $false; Block = $true;  Kind = 'Undecided' }
    ) {
        Get-SpecialServerDecision $Role $Feature $Svc $Key $Block | Should -Be $Kind
    }
    It 'a cluster several versions behind needs several rolling upgrades, said plainly' {
        $c = Get-SpecialServerContent 'Cluster' '2016' '2025'
        $c.Title | Should -Be 'Failover cluster node'
        $c.Banner | Should -Match 'expensive and risky'
        $c.Options[0].Text | Should -Match '3 rolling upgrades in a row, or a migration'
        $c.Options[0].Url | Should -Match '^https://learn\.microsoft\.com/'
        @($c.Risks | Where-Object { $_ -match 'functional level cannot be undone' }).Count | Should -Be 1
        (Get-SpecialServerContent 'Cluster' '2022' '2025').Options[0].Text | Should -Not -Match 'rolling upgrades in a row'
    }
    It 'a domain controller names the side-by-side way and the USN rollback risk, as options not instructions' {
        $c = Get-SpecialServerContent 'DomainController' '2016' '2025'
        $c.Options[0].Text | Should -Match 'add a new domain controller'
        @($c.Risks | Where-Object { $_ -match 'USN rollback' }).Count | Should -Be 1
        $c.Options[1].Text | Should -Match 'planned, approved exception'
    }
    It 'RedactExisting recovers cluster and node names' {
        $rows = @(
            [pscustomobject]@{ Area = 'CLUSTER'; Item = 'ClusterMembership'; Value = 'Cluster=CL01'; Details = '' }
            [pscustomobject]@{ Area = 'CLUSTER'; Item = 'Node: SRV02'; Value = 'State=Up'; Details = '' }
        )
        $l = Get-RedactionLiteralFromResult $rows
        (@($l | ForEach-Object { $_.Kind + '=' + $_.Value }) -join ';') | Should -Be 'HOST=CL01;HOST=SRV02'
    }
    It 'an unknown kind is refused' {
        { Get-SpecialServerContent 'Printer' } | Should -Throw '*Unknown SPECIAL kind*'
    }
    It 'SPECIAL is the overall result when present, above BLOCKER' {
        $r = @([pscustomobject]@{ Status = 'BLOCKER'; Kind = 'Finding' }, [pscustomobject]@{ Status = 'SPECIAL'; Kind = 'Finding' })
        Get-OverallStatus $r | Should -Be 'SPECIAL'
    }
    It 'the short report keeps only the checks that describe the server' {
        $ids = Get-SpecialServerCheckId
        $ids | Should -Contain 'special'
        $ids | Should -Contain 'baseline'
        $ids | Should -Not -Contain 'dism'
        $ids | Should -Not -Contain 'compatscan'
    }
    Context 'report' {
        BeforeAll {
            $script:Results.Clear(); $script:CheckRuns.Clear()
            $script:Data.Special = Get-SpecialServerContent 'DomainController' '2016' '2025'
            $script:Data.Special | Add-Member -NotePropertyName Facts -NotePropertyValue @('FSMO roles on this server: PDC emulator') -Force
            Add-Result 'SPECIAL' 'Domain controller' 'SPECIAL' 'Not a standard in-place upgrade: expensive and risky'
            $script:SpecialHtml = New-IPUReportHtml -Results $script:Results.ToArray() -CheckRuns $script:CheckRuns.ToArray() -OverallStatus 'SPECIAL' -CompletedTime (Get-Date)
        }
        AfterAll { $script:Data.Remove('Special') }
        It 'has a SPECIAL section with banner, facts, risks and options with links' {
            $script:SpecialHtml | Should -Match '<section id="special" class="special">'
            $script:SpecialHtml | Should -Match 'expensive and risky'
            $script:SpecialHtml | Should -Match 'FSMO roles on this server: PDC emulator'
            $script:SpecialHtml | Should -Match '<h3>Risks</h3>'
            $script:SpecialHtml | Should -Match 'href="https://learn\.microsoft\.com/en-us/windows-server/identity/ad-ds/deploy/upgrade-domain-controllers"'
        }
        It 'shows the SPECIAL verdict, card and legend line' {
            $script:SpecialHtml | Should -Match 'Overall IPU assessment: <span class="badge s-special">SPECIAL</span>'
            $script:SpecialHtml | Should -Match '<small>SPECIAL</small>'
            $script:SpecialHtml | Should -Match 'Not a standard in-place upgrade \(cluster node, domain controller\)'
        }
        It 'a report without SPECIAL has no SPECIAL card' {
            $html = New-IPUReportHtml -Results @() -CheckRuns @() -OverallStatus 'OK' -CompletedTime (Get-Date)
            $html | Should -Not -Match '<small>SPECIAL</small>'
        }
    }
}

Describe 'Network configuration (#149)' {
    BeforeAll {
        function New-TestAdapter {
            param([string]$Name = 'Ethernet0', [string]$Mac = '00:50:56:00:00:01', [string[]]$IPv4 = @('10.20.30.40'), [string[]]$Gateway = @('10.20.30.1'), [string[]]$Dns = @('10.20.1.10', '10.20.1.11'), [bool]$Dhcp = $false, [string[]]$IPv6 = @('fe80::1'), [string]$Suffix = 'corp.example.test', [string[]]$Wins = @(), [string]$NetBios = 'Default (set by DHCP)', [string]$Vlan = '', [string]$Metric = '15', [bool]$Register = $true)
            return [pscustomobject]@{ Name = $Name; Mac = $Mac; IPv4 = $IPv4; Mask = @('255.255.255.0'); IPv6 = $IPv6; Gateway = $Gateway; Dns = $Dns; Suffix = $Suffix; SuffixSearch = @(); RegisterInDns = $Register; RegisterSuffix = $false; Wins = $Wins; NetBios = $NetBios; Metric = $Metric; Dhcp = $Dhcp; Vlan = $Vlan }
        }
    }
    It 'NetBIOS option <Option> is <Text>' -TestCases @(
        @{ Option = 0; Text = 'Default (set by DHCP)' }
        @{ Option = 1; Text = 'Enabled' }
        @{ Option = 2; Text = 'Disabled' }
        @{ Option = $null; Text = 'Unknown' }
    ) {
        Get-NetBiosSettingText $Option | Should -Be $Text
    }
    It 'builds the adapter record from Win32_NetworkAdapterConfiguration' {
        $cfg = [pscustomobject]@{ IPAddress = @('10.20.30.40', 'fe80::1'); IPSubnet = @('255.255.255.0', '64'); DefaultIPGateway = @('10.20.30.1'); DNSServerSearchOrder = @('10.20.1.10'); DHCPEnabled = $false; MACAddress = '00-50-56-aa-00-01'; DNSDomain = 'corp.example.test'; DNSDomainSuffixSearchOrder = $null; FullDNSRegistrationEnabled = $true; DomainDNSRegistrationEnabled = $false; WINSPrimaryServer = ''; WINSSecondaryServer = $null; TcpipNetbiosOptions = 1; IPConnectionMetric = 25 }
        $r = ConvertTo-NetworkAdapterRecord $cfg 'Ethernet0' 0
        $r.Mac | Should -Be '00:50:56:AA:00:01'
        ($r.IPv4 -join ',') | Should -Be '10.20.30.40'
        ($r.Mask -join ',') | Should -Be '255.255.255.0'
        ($r.IPv6 -join ',') | Should -Be 'fe80::1'
        @($r.Wins).Count | Should -Be 0
        $r.NetBios | Should -Be 'Enabled'
        $r.Metric | Should -Be '25'
        $r.Vlan | Should -Be ''          # VLAN 0 means untagged
        $r.RegisterInDns | Should -BeTrue
        ConvertTo-MacKey '00-50-56-aa-00-01' | Should -Be (ConvertTo-MacKey '00:50:56:AA:00:01')
    }
    It 'nothing changed: no rows' {
        @(Compare-NetworkAdapter @(New-TestAdapter) @(New-TestAdapter)).Count | Should -Be 0
    }
    It 'matches adapters by MAC, so a renamed adapter is only INFO' {
        $rows = @(Compare-NetworkAdapter @(New-TestAdapter) @(New-TestAdapter -Name 'Ethernet 2'))
        $rows.Count | Should -Be 1
        $rows[0].Status | Should -Be 'INFO'
        $rows[0].Item | Should -Be 'Network adapter changed: Ethernet 2'
        $rows[0].Details | Should -Be 'Name: before Ethernet0, now Ethernet 2'
    }
    It 'a static adapter reset to DHCP is an ACTION with every difference listed' {
        $after = New-TestAdapter -IPv4 @('10.20.99.7') -Gateway @('10.20.99.1') -Dns @('10.20.99.2') -Dhcp $true -Suffix ''
        $rows = @(Compare-NetworkAdapter @(New-TestAdapter) @($after))
        $rows.Count | Should -Be 1
        $rows[0].Status | Should -Be 'ACTION'
        $rows[0].Value | Should -Be 'MAC=00:50:56:00:00:01'
        foreach ($want in @('DHCP: before False, now True', 'IPv4: before 10.20.30.40, now 10.20.99.7', 'Gateway: before 10.20.30.1, now 10.20.99.1', 'DNS servers: before 10.20.1.10,10.20.1.11, now 10.20.99.2', 'DNS suffix: before corp.example.test, now (none)')) {
            $rows[0].Details | Should -Match ([regex]::Escape($want))
        }
        $rows[0].Recommendation | Should -Match 'network evidence file'
    }
    It 'a new address on a DHCP adapter is a WARNING, not an ACTION' {
        $rows = @(Compare-NetworkAdapter @(New-TestAdapter -Dhcp $true) @(New-TestAdapter -Dhcp $true -IPv4 @('10.20.30.41')))
        $rows[0].Status | Should -Be 'WARNING'
    }
    It 'DNS server order matters; WINS, NetBIOS, registration and global IPv6 are compared' {
        $after = New-TestAdapter -Dns @('10.20.1.11', '10.20.1.10') -Wins @('10.20.1.20') -NetBios 'Disabled' -Register $false -IPv6 @('fe80::2')
        $before = New-TestAdapter -IPv6 @('fe80::1', '2001:db8::40')
        $rows = @(Compare-NetworkAdapter @($before) @($after))
        $rows[0].Status | Should -Be 'WARNING'
        foreach ($want in @('DNS servers:', 'WINS: before (none), now 10.20.1.20', 'NetBIOS over TCP/IP: before Default (set by DHCP), now Disabled', 'Register in DNS: before True, now False', 'IPv6: before 2001:db8::40, now (none)')) {
            $rows[0].Details | Should -Match ([regex]::Escape($want))
        }
        # A new link-local address alone is not a change worth reporting.
        @(Compare-NetworkAdapter @(New-TestAdapter) @(New-TestAdapter -IPv6 @('fe80::9'))).Count | Should -Be 0
    }
    It 'a changed VLAN is an ACTION' {
        (@(Compare-NetworkAdapter @(New-TestAdapter -Vlan '20') @(New-TestAdapter -Vlan '')))[0].Status | Should -Be 'ACTION'
    }
    It 'an adapter that is gone is an ACTION; a new one is INFO' {
        $rows = @(Compare-NetworkAdapter @(New-TestAdapter) @(New-TestAdapter -Name 'Ethernet1' -Mac '00:50:56:00:00:02'))
        ($rows | Where-Object { $_.Item -eq 'Network adapter missing after upgrade: Ethernet0' }).Status | Should -Be 'ACTION'
        ($rows | Where-Object { $_.Item -eq 'Network adapters new after upgrade' }).Details | Should -Match 'Ethernet1'
    }
    It 'Compare-IPUSnapshot uses the adapter comparison when both runs have it, and the flat lists otherwise' {
        $before = [pscustomobject]@{ IPv4 = @('10.20.30.40'); Dns = @('10.20.1.10'); Adapters = @(New-TestAdapter) }
        $after = [pscustomobject]@{ IPv4 = @('10.20.99.7'); Dns = @('10.20.1.10'); Adapters = @(New-TestAdapter -IPv4 @('10.20.99.7')) }
        $d = Compare-IPUSnapshot $before $after
        @($d | Where-Object { $_.Item -eq 'IPv4 addresses missing after upgrade' }).Count | Should -Be 0
        @($d | Where-Object { $_.Item -eq 'Network adapter changed: Ethernet0' }).Count | Should -Be 1
        # A baseline from 4.4.0 or older has no adapter list.
        $old = [pscustomobject]@{ IPv4 = @('10.20.30.40'); Dns = @('10.20.1.10') }
        $d = Compare-IPUSnapshot $old $after
        @($d | Where-Object { $_.Item -eq 'IPv4 addresses missing after upgrade' }).Count | Should -Be 1
    }
    It 'a redacted report hides every address in the adapter details' {
        $ctx = New-RedactionContext 'SRV01' 'corp.example.test'
        $text = (Get-NetworkAdapterDetail (New-TestAdapter -IPv6 @('fe80::1', '2001:db8::40') -Wins @('10.20.1.20'))) -join ' | '
        $red = Protect-ReportText $text $ctx
        foreach ($addr in @('10.20.30.1', '10.20.1.10', '10.20.1.20', 'fe80::1', '2001:db8::40', '00:50:56:00:00:01', 'corp.example.test')) {
            $red | Should -Not -Match ([regex]::Escape($addr))
        }
    }
}

Describe 'Save-NetworkEvidence (#149)' {
    BeforeAll {
        Mock Test-CommandAvailable { $false }
    }
    It 'saves each command output into the folder and zips it' {
        Mock Invoke-NativeCapture { [pscustomobject]@{ ExitCode = 0; Output = ('output of ' + ($ArgumentList -join ' ')); Lines = @('x'); TimedOut = $false; Error = '' } }
        $dest = Join-Path $TestDrive 'evidence\SRV-IPU-Network-1'
        $r = Save-NetworkEvidence -Destination $dest
        ($r.Files -join ',') | Should -Be 'ipconfig-all.txt,route-print.txt,netsh-ipv4-show-config.txt,netsh-interface-dump.txt'
        @($r.Failed).Count | Should -Be 0
        $r.Location | Should -Be ($dest + '.zip')
        Test-Path -LiteralPath $r.Location | Should -BeTrue
        [IO.File]::ReadAllText((Join-Path $dest 'netsh-interface-dump.txt')) | Should -Match 'output of -c interface dump'
        Should -Invoke Invoke-NativeCapture -Times 4 -Exactly
    }
    It 'runs only read-only commands, each with a timeout' {
        Mock Invoke-NativeCapture { [pscustomobject]@{ ExitCode = 0; Output = 'x'; Lines = @('x'); TimedOut = $false; Error = '' } }
        $null = Save-NetworkEvidence -Destination (Join-Path $TestDrive 'ro') -Zip $false -TimeoutSeconds 30
        Should -Invoke Invoke-NativeCapture -Times 4 -Exactly -ParameterFilter {
            $TimeoutSeconds -eq 30 -and (($ArgumentList -join ' ') -in @('/all', 'print', 'interface ipv4 show config', '-c interface dump'))
        }
    }
    It 'a command that times out is listed in Failed; the rest is saved' {
        Mock Invoke-NativeCapture { [pscustomobject]@{ ExitCode = $null; Output = ''; Lines = @(); TimedOut = $true; Error = '' } } -ParameterFilter { $FilePath -like '*route.exe' }
        Mock Invoke-NativeCapture { [pscustomobject]@{ ExitCode = 0; Output = 'x'; Lines = @('x'); TimedOut = $false; Error = '' } } -ParameterFilter { $FilePath -notlike '*route.exe' }
        $r = Save-NetworkEvidence -Destination (Join-Path $TestDrive 'partial') -Zip $false
        @($r.Files).Count | Should -Be 3
        ($r.Failed -join ' ') | Should -Match 'route print: no answer within 60 seconds'
    }
    It 'throws when nothing could be saved' {
        Mock Invoke-NativeCapture { [pscustomobject]@{ ExitCode = 1; Output = ''; Lines = @(); TimedOut = $false; Error = '' } }
        { Save-NetworkEvidence -Destination (Join-Path $TestDrive 'none') -Zip $false } | Should -Throw '*No network command output*'
    }
    It '-RedactExisting leaves the evidence alone: it is not a report' {
        $dir = Join-Path $TestDrive 'share'
        New-Item -ItemType Directory -Path $dir | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'SRV01-IPU-Network-20261013-100000.txt'), 'IPv4 Address. . . : 10.20.30.40')
        Invoke-RedactExisting $dir | Should -Be 1
        @(Get-ChildItem -LiteralPath $dir -Filter 'REDACTED-*').Count | Should -Be 0
    }
}

Describe 'Dated facts have a source and a recent check (#132)' {
    It 'every fact table is listed with a date and an https source' {
        foreach ($name in 'SupportedUpgradePaths', 'SqlSupportedOnTarget', 'ReleaseEndOfSupport', 'FeatureLifecycle', 'VMwareToolsMinimum', 'ExpectedWindowsChanges', 'WinReMinPartitionMB', 'DocLinks') {
            $script:FactSources.Contains($name) | Should -BeTrue -Because $name
        }
        @(Get-StaleFactSource $script:FactSources ([datetime]'2026-10-13')) | Should -BeNullOrEmpty
    }
    It 'no fact table was last checked more than six months ago' {
        $stale = Get-StaleFactSource $script:FactSources (Get-Date)
        @($stale) | Should -BeNullOrEmpty -Because ('these need a recheck (CONTRIBUTING, "Dated facts"): ' + (@($stale) -join '; '))
    }
    It 'a back-dated entry is reported with its source; a missing date or source too' {
        $sources = [ordered]@{
            Old = @{ Verified = '2026-01-01'; Source = 'https://learn.microsoft.com/example' }
            Fresh = @{ Verified = '2026-09-01'; Source = 'https://learn.microsoft.com/example' }
            NoDate = @{ Verified = 'soon'; Source = 'https://learn.microsoft.com/example' }
            NoSource = @{ Verified = '2026-09-01'; Source = '' }
        }
        $stale = Get-StaleFactSource $sources ([datetime]'2026-10-13')
        @($stale).Count | Should -Be 3
        $stale[0] | Should -Be 'Old: last verified 2026-01-01, recheck against https://learn.microsoft.com/example'
        ($stale -join ' ') | Should -Match 'NoDate: no valid'
        ($stale -join ' ') | Should -Match 'NoSource: no valid'
    }
    It 'six months is the limit' {
        $s = [ordered]@{ T = @{ Verified = '2026-04-13'; Source = 'https://x.example' } }
        @(Get-StaleFactSource $s ([datetime]'2026-10-13')).Count | Should -Be 0
        @(Get-StaleFactSource $s ([datetime]'2026-10-14')).Count | Should -Be 1
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

Describe 'Read-only system helpers (#127: every function runs in a test)' {
    It 'Get-PrerequisiteState never throws and reads this host' {
        $s = Get-PrerequisiteState
        $s.PowerShellVersion | Should -Be $PSVersionTable.PSVersion
        $s.DotNetRelease | Should -BeOfType [int]
        $s.IsElevated | Should -BeOfType [bool]
        , @($s.MissingModules) | Should -BeOfType [object[]]
    }
    It 'Get-AdComputerDn returns a DN or throws with a message (never an empty name)' {
        $r = try { Get-AdComputerDn } catch { 'threw: ' + $_.Exception.Message }
        $r | Should -Match '^(CN=.+|threw: .+)'
    }
    It 'Get-GpoListRegistryEntry reads the GPO-List keys in numeric order' {
        Mock Get-ChildItem { @([pscustomobject]@{ PSChildName = '10'; PSPath = 'k10' }, [pscustomobject]@{ PSChildName = '2'; PSPath = 'k2' }) }
        Mock Get-ItemProperty { if ($LiteralPath -eq 'k2') { [pscustomobject]@{ DisplayName = 'Second'; GPOName = '{2}'; Link = 'Local' } } else { [pscustomobject]@{ DisplayName = 'Tenth'; GPOName = '{10}'; Link = 'Local' } } }
        $list = Get-GpoListRegistryEntry
        ($list | ForEach-Object { $_.DisplayName }) -join ',' | Should -Be 'Second,Tenth'
    }
    It 'Get-FileCompanyName: empty for a missing file, the company for a real one' {
        Get-FileCompanyName '' | Should -Be ''
        Get-FileCompanyName (Join-Path $TestDrive 'missing.dll') | Should -Be ''
        $exe = (Get-Process -Id $PID).Path
        Get-FileCompanyName $exe | Should -BeOfType [string]
    }
    It 'Get-PrintDriverStoreSize adds up every file under spool\drivers' {
        Mock Get-ChildItem { @([pscustomobject]@{ Length = 1000 }, [pscustomobject]@{ Length = 2500 }) }
        Get-PrintDriverStoreSize | Should -Be 3500
    }
    It 'Get-PrintMonitorInventory lists port monitors and print processors with their company' {
        Mock Get-ChildItem { @([pscustomobject]@{ PSChildName = 'Local Port'; PSPath = 'mon1' }) } -ParameterFilter { $LiteralPath -like '*\Monitors' }
        Mock Get-ChildItem { @([pscustomobject]@{ PSChildName = 'winprint'; PSPath = 'pp1' }) } -ParameterFilter { $LiteralPath -like '*Print Processors' }
        Mock Get-ItemProperty { if ($LiteralPath -eq 'mon1') { [pscustomobject]@{ Driver = 'localspl.dll' } } else { [pscustomobject]@{ Driver = 'winprint.dll' } } }
        Mock Get-FileCompanyName { 'Microsoft Corporation' }
        $items = Get-PrintMonitorInventory
        ($items | ForEach-Object { $_.Type + ':' + $_.Name + ':' + $_.Driver + ':' + $_.Company }) -join ';' | Should -Be 'PortMonitor:Local Port:localspl.dll:Microsoft Corporation;PrintProcessor:winprint:winprint.dll:Microsoft Corporation'
    }
}
