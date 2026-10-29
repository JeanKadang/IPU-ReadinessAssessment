# Pester 5 tests. Decision rules: release, upgrade path, edition, language, lifecycle, Setup scan, disks and SPECIAL servers.
# The script is loaded in library mode by ..\TestSetup.ps1: functions only, nothing is collected.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
param()

BeforeAll { . (Join-Path $PSScriptRoot '..\TestSetup.ps1') }

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
    It 'the IIS 6 console and PowerShell 2.0 are not flagged for a 2022 target either (#187)' {
        (Get-FeatureLifecycleFinding @('Web-Lgcy-Mgmt-Console','PowerShell-V2') '2022').Count | Should -Be 0
        (Get-FeatureLifecycleFinding @('Web-Lgcy-Mgmt-Console','PowerShell-V2') '2025').Count | Should -Be 2
    }
    It 'deprecated features are observations' {
        $f = Get-FeatureLifecycleFinding @('NLB') '2025'
        $f[0].Kind | Should -Be 'Observation'
    }
    It 'NLB, WebDAV Redirector and WID are listed on the 2025 tab only, not for a 2022 target (#232)' {
        (Get-FeatureLifecycleFinding @('NLB','WebDAV-Redirector','Windows-Internal-Database') '2022').Count | Should -Be 0
        (Get-FeatureLifecycleFinding @('NLB','WebDAV-Redirector','Windows-Internal-Database') '2025').Count | Should -Be 3
    }
    It 'iSNS is removed for a 2022 target and stays removed for 2025 (#232)' {
        foreach ($t in '2022','2025') {
            $f = Get-FeatureLifecycleFinding @('ISNS') $t
            $f.Count | Should -Be 1
            $f[0].Status | Should -Be 'ACTION'
            $f[0].Kind | Should -Be 'Finding'
        }
    }
    It 'WINS is an observation for a 2022 target (#232)' {
        $f = Get-FeatureLifecycleFinding @('WINS') '2022'
        $f.Count | Should -Be 1
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

Describe 'Get-SpaceAfterPartition (#241)' {
    It 'unallocated space after the partition, up to the end of the disk' {
        Get-SpaceAfterPartition 1MB 60GB @(1MB) 100GB | Should -Be (100GB - 1MB - 60GB)
    }
    It 'stops at the next partition' {
        Get-SpaceAfterPartition 1MB 60GB @(1MB, 70GB) 100GB | Should -Be (70GB - 1MB - 60GB)
    }
    It 'a partition directly followed by another has none' { Get-SpaceAfterPartition 1MB 60GB @(1MB, (1MB + 60GB)) 100GB | Should -Be 0 }
    It 'a partition that fills the disk has none' { Get-SpaceAfterPartition 1MB 99GB @(1MB) (1MB + 99GB) | Should -Be 0 }
    It 'never negative' { Get-SpaceAfterPartition 1MB 120GB @(1MB) 100GB | Should -Be 0 }
}

Describe 'Resolve-ClusterFeatureState (#238)' {
    It 'a known feature state is used as it is' {
        Resolve-ClusterFeatureState $true $false $false | Should -BeTrue
        Resolve-ClusterFeatureState $false $true $true | Should -BeFalse
    }
    It 'an unknown state with the Cluster service and the cluster key is a cluster node' { Resolve-ClusterFeatureState $null $true $true | Should -BeTrue }
    It 'an unknown state without both stays unknown, never "not installed"' {
        $null -eq (Resolve-ClusterFeatureState $null $false $false) | Should -BeTrue
        $null -eq (Resolve-ClusterFeatureState $null $true $false) | Should -BeTrue
        $null -eq (Resolve-ClusterFeatureState $null $false $true) | Should -BeTrue
    }
}

Describe 'Test-MediaLanguageMatch (#245)' {
    It 'the same language matches' { Test-MediaLanguageMatch @('en-US') 'en-US' | Should -BeTrue }
    It 'the "(Default)" form that Get-WindowsImage lists matches' { Test-MediaLanguageMatch @('en-US (Default)') 'en-US' | Should -BeTrue }
    It 'case does not matter' { Test-MediaLanguageMatch @('EN-us (Default)') 'en-US' | Should -BeTrue }
    It 'one of several languages is enough' { Test-MediaLanguageMatch @('da-DK', 'en-US (Default)') 'en-US' | Should -BeTrue }
    It 'another language is a mismatch' { Test-MediaLanguageMatch @('en-US (Default)') 'da-DK' | Should -BeFalse }
    It 'a similar language is not the same' { Test-MediaLanguageMatch @('en-GB') 'en-US' | Should -BeFalse }
    It 'the installed language may carry the suffix too' { Test-MediaLanguageMatch @('da-DK') 'da-DK (Default)' | Should -BeTrue }
    It 'unknown on either side is not a mismatch' {
        Test-MediaLanguageMatch @() 'en-US' | Should -BeTrue
        Test-MediaLanguageMatch @('en-US') '' | Should -BeTrue
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

Describe 'PKI site policy (#322)' {
    It 'ConvertTo-ReleaseList reads a comma-separated list' {
        (@(ConvertTo-ReleaseList ' 2022 , 2025') -join '|') | Should -Be '2022|2025'
        (@(ConvertTo-ReleaseList '2022') -join '|') | Should -Be '2022'
    }
    It 'Test-PkiServer: the CA role or the CertSvc service' {
        Test-PkiServer $true @() | Should -BeTrue
        Test-PkiServer $null @('W32Time', 'CertSvc') | Should -BeTrue
        Test-PkiServer $false @('W32Time') | Should -BeFalse
        Test-PkiServer $null @() | Should -BeFalse
    }
    It '<Source> to <Target> with <Allowed> allowed is <Kind>' -TestCases @(
        @{ Source = '2019';   Target = '2022'; Allowed = '2022';      Kind = 'Allowed';          Status = 'OK' }
        @{ Source = '2016';   Target = '2022'; Allowed = '2022';      Kind = 'Allowed';          Status = 'OK' }
        @{ Source = '2019';   Target = '2025'; Allowed = '2022';      Kind = 'TargetNotAllowed'; Status = 'BLOCKER' }
        @{ Source = '2022';   Target = '2025'; Allowed = '2022';      Kind = 'TargetNotAllowed'; Status = 'BLOCKER' }
        @{ Source = '2012R2'; Target = '2025'; Allowed = '2022';      Kind = 'NoAllowedPath';    Status = 'BLOCKER' }
        @{ Source = '2012R2'; Target = '2022'; Allowed = '2022';      Kind = 'NoAllowedPath';    Status = 'BLOCKER' }
        @{ Source = '2019';   Target = '2025'; Allowed = '2022,2025'; Kind = 'Allowed';          Status = 'OK' }
        @{ Source = '2012R2'; Target = '2025'; Allowed = '2022,2025'; Kind = 'Allowed';          Status = 'OK' }
        @{ Source = '';       Target = '2025'; Allowed = '2022';      Kind = 'Unknown';          Status = 'MANUAL' }
        # The default since #338: 2019 and 2022 allowed, 2025 not.
        @{ Source = '2016';   Target = '2019'; Allowed = '2019,2022'; Kind = 'Allowed';          Status = 'OK' }
        @{ Source = '2012R2'; Target = '2019'; Allowed = '2019,2022'; Kind = 'Allowed';          Status = 'OK' }
        @{ Source = '2012R2'; Target = '2022'; Allowed = '2019,2022'; Kind = 'Allowed';          Status = 'OK' }
        @{ Source = '2012R2'; Target = '2025'; Allowed = '2019,2022'; Kind = 'TargetNotAllowed'; Status = 'BLOCKER' }
        @{ Source = '2016';   Target = '2025'; Allowed = '2019,2022'; Kind = 'TargetNotAllowed'; Status = 'BLOCKER' }
        @{ Source = '2022';   Target = '2025'; Allowed = '2019,2022'; Kind = 'TargetNotAllowed'; Status = 'BLOCKER' }
    ) {
        $d = Get-PkiTargetDecision $Source $Target (ConvertTo-ReleaseList $Allowed)
        $d.Kind | Should -Be $Kind
        $d.Status | Should -Be $Status
    }
    It 'a target the policy does not allow names the allowed release and how to assess against it' {
        $d = Get-PkiTargetDecision '2019' '2025' @('2022')
        $d.Text | Should -Match 'Site policy'
        $d.Text | Should -Match 'Windows Server 2022'
        $d.Recommendation | Should -Match '-TargetServerVersion 2022'
    }
    It 'a PKI server already on the highest allowed release is told to stay there' {
        $d = Get-PkiTargetDecision '2022' '2025' @('2022')
        $d.Text | Should -Match 'already on Windows Server 2022'
    }
    It 'a target outside the policy names the highest allowed target, the exception and a new build (#338)' {
        $d = Get-PkiTargetDecision '2016' '2025' @('2019', '2022')
        $d.Recommendation | Should -Match '-TargetServerVersion 2022'
        $d.Recommendation | Should -Match 'exception agreed with the PKI team'
        $d.Recommendation | Should -Match 'new PKI on Windows Server 2025'
        (Get-PkiTargetDecision '2012R2' '2025' @('2019', '2022')).Recommendation | Should -Match '-TargetServerVersion 2019'
        (Get-PkiTargetDecision '2022' '2025' @('2019', '2022')).Recommendation | Should -Match 'exception agreed with the PKI team'
    }
    It 'the parameter default allows 2019 and 2022 (#338)' {
        $cmd = Get-Command (Join-Path $PSScriptRoot '..\..\src\Windows-IPU-Readiness-Assessment.ps1')
        $default = $cmd.ScriptBlock.Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'PkiAllowedTargets' }
        $default.DefaultValue.Value | Should -Be '2019,2022'
    }
    It 'no allowed path means a migration with the PKI team' {
        $d = Get-PkiTargetDecision '2012R2' '2022' @('2022')
        $d.Text | Should -Match 'Windows Server 2012 R2'
        $d.Recommendation | Should -Match 'migration'
    }
    It 'Get-UpgradePathDecision leaves out a suggested target the PKI policy does not allow' {
        $plain = Get-UpgradePathDecision '2012R2' '2022' $false
        $plain.Text | Should -Match 'Windows Server 2025'
        $pki = Get-UpgradePathDecision '2012R2' '2022' $false -AllowedTargets @('2022')
        $pki.Status | Should -Be 'BLOCKER'
        $pki.Text | Should -Match 'PKI site policy does not allow'
        $pki.Text | Should -Not -Match 'Supported direct target'
    }
    It 'Get-UpgradePathDecision is unchanged when the allowed list permits the hint' {
        $d = Get-UpgradePathDecision '2012R2' '2022' $false -AllowedTargets @('2022', '2025')
        $d.Text | Should -Match 'Supported direct target\(s\) from this source: Windows Server 2025'
    }
}

Describe 'Target Windows Server 2019 (#332)' {
    It 'the parameter accepts 2019 as a target and in the PKI policy list' {
        $cmd = Get-Command (Join-Path $PSScriptRoot '..\..\src\Windows-IPU-Readiness-Assessment.ps1')
        $set = @($cmd.Parameters['TargetServerVersion'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })[0]
        $set.ValidValues | Should -Contain '2019'
        $pattern = @($cmd.Parameters['PkiAllowedTargets'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidatePatternAttribute] })[0].RegexPattern
        '2019,2022' | Should -Match $pattern
    }
    It '<Source> to 2019 is <Expected>' -TestCases @(
        @{ Source = '2012R2'; Expected = 'OK' }
        @{ Source = '2016';   Expected = 'OK' }
        @{ Source = '2019';   Expected = 'INFO' }
        @{ Source = '2022';   Expected = 'BLOCKER' }
        @{ Source = '2012';   Expected = 'BLOCKER' }
    ) {
        (Get-UpgradePathDecision $Source '2019' $false).Status | Should -Be $Expected
    }
    It 'an unknown target names all three configured targets' {
        (Get-UpgradePathDecision '2016' '2008' $false).Text | Should -Match 'Use 2025, 2022 or 2019'
    }
    It 'a PKI server is held to the PKI policy for 2019 too' {
        (Get-PkiTargetDecision '2016' '2019' @('2022')).Kind | Should -Be 'TargetNotAllowed'
        (Get-PkiTargetDecision '2016' '2019' @('2019', '2022')).Kind | Should -Be 'Allowed'
    }
    It 'features removed or no longer developed in 2019 (2019 tab only)' {
        # The function returns its array whole (return ,$out): assign, do not wrap in @().
        $r = Get-FeatureLifecycleFinding @('Print-Scan-Server', 'ISNS', 'Web-Digest-Auth', 'Web-Metabase') '2019'
        @($r).Count | Should -Be 4
        ($r | Where-Object { $_.Feature -eq 'Print-Scan-Server' }).Status | Should -Be 'ACTION'
        ($r | Where-Object { $_.Feature -eq 'ISNS' }).Status | Should -Be 'WARNING'
        ($r | Where-Object { $_.Feature -eq 'Web-Digest-Auth' }).Kind | Should -Be 'Observation'
        ($r | Where-Object { $_.Feature -eq 'Web-Metabase' }).Status | Should -Be 'WARNING'
        $r22 = Get-FeatureLifecycleFinding @('ISNS') '2022'
        ($r22 | Where-Object { $_.Feature -eq 'ISNS' }).Status | Should -Be 'ACTION'
        $r25 = Get-FeatureLifecycleFinding @('Web-Digest-Auth', 'Print-Scan-Server') '2025'
        @($r25).Count | Should -Be 0
    }
}
