# Pester 5 tests for Windows-IPU-Readiness-Assessment.ps1 (4.x).
# Runs anywhere PowerShell + Pester run (Windows PowerShell 5.1 or pwsh 7):
#   Invoke-Pester .\tests -Output Detailed
# The script is loaded in library mode: functions only, nothing is collected.

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
    It 'blocks clustered nodes regardless of path' {
        (Get-UpgradePathDecision '2019' '2025' $true).Status | Should -Be 'BLOCKER'
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
    It 'localized output falls back to clean CBS.log' {
        $cbs = @('2026-10-06 09:00:01, Info                  CSI    00000005 [SR] Verifying 100 components',
                 '2026-10-06 09:05:01, Info                  CSI    00000099 [SR] Verify complete')
        $v = Get-SfcVerdict 'Windows-ressourcebeskyttelse fandt ingen integritetskrænkelser.' $cbs
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
        $script:html | Should -Not -Match '<script>'
        $script:html | Should -Match '&lt;script&gt;'
    }
    It 'shows the partial banner and the not-assessed warning' {
        $script:html | Should -Match 'PARTIAL REPORT'
        $script:html | Should -Match 'Not fully assessed'
    }
    It 'contains no external resources' {
        $script:html | Should -Not -Match '(src|href)="https?:'
    }
}

# ---------------------------------------------------------------------------
# 4.0.1 additions
# ---------------------------------------------------------------------------
Describe 'Detection patterns - replay of AEVNWOSTST009 (first live run)' {
    BeforeAll {
        $script:liveApps = @('FlexNet Inventory Agent','Microsoft Visual C++ v14 Redistributable (x64) - 14.50.35719','Nessus Agent (x64)','NXLog','Operations-agent','SA Agent','TrendAI™ Deep Security Agent','Universal Discovery Agent (x86)','VMware Tools') |
            ForEach-Object { [pscustomobject]@{ Name=$_; Version='1.0'; Publisher='' } }
        $script:liveServices = @(
            [pscustomobject]@{ Name='ds_agent';      DisplayName='TrendAI™ Deep Security Agent'; State='Running' },
            [pscustomobject]@{ Name='Sense';         DisplayName='Windows Defender Advanced Threat Protection Service'; State='Running' },
            [pscustomobject]@{ Name='OpswareAgent';  DisplayName='Opsware Agent'; State='Running' },
            [pscustomobject]@{ Name='UDAgent';       DisplayName='Universal Discovery Agent'; State='Running' },
            [pscustomobject]@{ Name='OvCtrl';        DisplayName='HP OpenView Ctrl Service'; State='Running' },
            [pscustomobject]@{ Name='Tenable Nessus Agent'; DisplayName='Tenable Nessus Agent'; State='Running' },
            [pscustomobject]@{ Name='nxlog';         DisplayName='nxlog'; State='Running' },
            [pscustomobject]@{ Name='VMTools';       DisplayName='VMware Tools'; State='Running' }
        )
        $script:liveDrivers = @('bindflt','SysmonDrv','TmKmSnsr','tmeyes','vsepflt','storqosflt','wcifs','CldFlt','FileCrypt','luafv','UnionFS','npsvctrig','Wof')
    }
    It 'recognises TrendAI Deep Security (was missed by 4.0.0)' {
        $m = Find-DetectionMatch $script:DetectionPatterns.EndpointProtection $script:liveApps $script:liveServices $script:liveDrivers
        @($m | ForEach-Object Label) | Should -Contain 'Trend Micro / TrendAI Deep Security, Apex One, Vision One'
    }
    It 'recognises the Defender for Endpoint sensor' {
        $m = Find-DetectionMatch $script:DetectionPatterns.EndpointProtection $script:liveApps $script:liveServices $script:liveDrivers
        @($m | ForEach-Object Label) | Should -Contain 'Microsoft Defender for Endpoint (EDR sensor)'
    }
    It 'finds the application entries of all three OpenText agents' {
        $m = Find-DetectionMatch $script:DetectionPatterns.Agents $script:liveApps $script:liveServices
        $m.Count | Should -Be 3
        foreach ($x in $m) { @($x.Apps).Count | Should -Be 1 }
    }
    It 'flags Nessus, NXLog and Sysmon (Sysmon via its driver)' {
        $m = Find-DetectionMatch $script:DetectionPatterns.SecurityTools $script:liveApps $script:liveServices $script:liveDrivers
        $labels = @($m | ForEach-Object Label)
        $labels | Should -Contain 'Tenable Nessus agent'
        $labels | Should -Contain 'NXLog'
        $labels | Should -Contain 'Sysmon'
    }
    It 'reports no workloads and no backup product for this server' {
        (Find-DetectionMatch $script:DetectionPatterns.Workloads $script:liveApps $script:liveServices).Count | Should -Be 0
        (Find-DetectionMatch $script:DetectionPatterns.Backup $script:liveApps $script:liveServices).Count | Should -Be 0
    }
    It 'detects a product by driver alone (renamed/hidden install entry)' {
        $m = Find-DetectionMatch $script:DetectionPatterns.EndpointProtection @() @() @('CSAgent')
        $m[0].Label | Should -Be 'CrowdStrike Falcon'
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
        $d.Text | Should -Match 'icacls "C:\\Reports" /inheritance:r'
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
        Get-SlowBudgetMinutes 50 45 '' 'Pre' | Should -Be 50
    }
    It 'adds the compat-scan timeout when media is set in Pre mode' {
        Get-SlowBudgetMinutes 50 45 'D:\' 'Pre' | Should -Be 95
    }
    It 'does not add it in Post mode' {
        Get-SlowBudgetMinutes 50 45 'D:\' 'Post' | Should -Be 50
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
