# Pester 5 tests. Decision rules: Group Policy, WMI filters, AD groups, UAC, domain role, OU.
# The script is loaded in library mode by ..\TestSetup.ps1: functions only, nothing is collected.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
param()

BeforeAll { . (Join-Path $PSScriptRoot '..\TestSetup.ps1') }

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

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

Describe 'Group Policy registry fallback says what it found (#215)' {
    It '<Case>' -TestCases @(
        @{ Case = 'key missing';   Entries = 0; Named = 0; Err = 'Cannot find path'; Missing = $true;  Expected = 'Registry fallback: the key HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\GPO-List does not exist' }
        @{ Case = 'read error';    Entries = 0; Named = 0; Err = 'Access denied';    Missing = $false; Expected = 'Registry fallback failed: Access denied' }
        @{ Case = 'empty key';     Entries = 0; Named = 0; Err = '';                 Missing = $false; Expected = 'Registry fallback: HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\GPO-List has no entries' }
        @{ Case = 'nameless';      Entries = 3; Named = 0; Err = '';                 Missing = $false; Expected = 'Registry fallback: 3 entries in HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\GPO-List, none with a GPO name' }
    ) {
        Get-GpoFallbackNote $Entries $Named $Err $Missing | Should -Be $Expected
    }
}
