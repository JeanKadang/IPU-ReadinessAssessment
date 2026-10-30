# Pester 5 tests. Decision rules: activation, KMS renewal and target licensing.
# The script is loaded in library mode by ..\TestSetup.ps1: functions only, nothing is collected.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
param()

BeforeAll { . (Join-Path $PSScriptRoot '..\TestSetup.ps1') }

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'KMS renewal warning and the OS licence product (#248)' {
    It 'a KMS client with 45 days left has missed renewals: WARNING (was OK under a 30-day threshold)' {
        $d = Get-ActivationDecision 'KMS' 1 'Licensed' 'Volume:GVLK' (45 * 1440) 'kms01.corp.example.test' '1688' '' ''
        $d.Status | Should -Be 'WARNING'; $d.Value | Should -Match 'Renewal due in 45 days'
    }
    It 'a fresh activation (173 days left, renewed a week ago) is OK' {
        (Get-ActivationDecision 'KMS' 1 'Licensed' 'Volume:GVLK' (173 * 1440) 'kms01' '1688' '' '').Status | Should -Be 'OK'
    }
    It 'the default threshold is 165 days: two missed renewal windows' {
        (Get-ActivationDecision 'KMS' 1 'Licensed' 'Volume:GVLK' (166 * 1440) 'kms01' '1688' '' '').Status | Should -Be 'OK'
        (Get-ActivationDecision 'KMS' 1 'Licensed' 'Volume:GVLK' (164 * 1440) 'kms01' '1688' '' '').Status | Should -Be 'WARNING'
    }
    It 'the threshold can be set' {
        (Get-ActivationDecision 'KMS' 1 'Licensed' 'Volume:GVLK' (100 * 1440) 'kms01' '1688' '' '' 90).Status | Should -Be 'OK'
        (Get-ActivationDecision 'KMS' 1 'Licensed' 'Volume:GVLK' (100 * 1440) 'kms01' '1688' '' '' 120).Status | Should -Be 'WARNING'
    }
    It 'KmsRenewWarnDays is a script setting a profile can set' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\..\src\Windows-IPU-Readiness-Assessment.ps1'), [ref]$null, [ref]$null)
        $p = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'KmsRenewWarnDays' }
        $p.DefaultValue.Value | Should -Be 165
        $script:ProfileSettingNames | Should -Contain 'KmsRenewWarnDays'
    }
    Context 'Select-OsLicenseProduct' {
        BeforeAll {
            function New-LicenseProduct([string]$Name, [int]$Status, $Addon = $null, [string]$Description = '') {
                $o = [pscustomobject]@{ Name = $Name; Description = $Description; LicenseStatus = $Status; PartialProductKey = 'ABCDE' }
                if ($null -ne $Addon) { $o | Add-Member -NotePropertyName LicenseIsAddon -NotePropertyValue $Addon }
                return $o
            }
        }
        It 'picks the operating system licence' {
            $r = Select-OsLicenseProduct @((New-LicenseProduct 'Windows(R), ServerStandard edition' 1 $false))
            $r.Primary.Name | Should -Be 'Windows(R), ServerStandard edition'; @($r.AddOns).Count | Should -Be 0
        }
        It 'an add-on flagged LicenseIsAddon is never the OS licence, even when it sorts first and is licensed' {
            $os = New-LicenseProduct 'Windows(R), ServerStandard edition' 5 $false
            $esu = New-LicenseProduct 'Windows(R), ServerStandard-ESU-Year1 add-on' 1 $true
            $r = Select-OsLicenseProduct @($esu, $os)
            $r.Primary.LicenseStatus | Should -Be 5
            @($r.AddOns).Count | Should -Be 1; $r.AddOns[0].Name | Should -Match 'ESU'
        }
        It 'ESU in the name or description is the second signal when the flag is missing' {
            $os = New-LicenseProduct 'Windows(R), ServerStandard edition' 5
            $esu = New-LicenseProduct 'Windows(R) Operating System' 1 $null 'Windows(R) Operating System, ESU-Year1 add-on'
            (Select-OsLicenseProduct @($esu, $os)).Primary.LicenseStatus | Should -Be 5
        }
        It 'the real 2012 R2 add-on names are add-ons without the flag: <AddOnName> (#330)' -TestCases @(
            @{ AddOnName = 'Windows(R), Server-ESU-Year1 add-on for ServerDatacenter,ServerDatacenterCore,ServerDatacenterV,ServerDatacenterVCore,ServerStandard,ServerStandardCore,ServerStandardV,ServerStandardVCore' }
            @{ AddOnName = 'Windows(R), Server-FES-ESU-Year2 add-on for ServerDatacenter,ServerStandard' }
            @{ AddOnName = 'Windows(R), APPXLOB-Server add-on for ServerStandard,ServerStandardEval,ServerDatacenter,ServerDatacenterEval' }
        ) {
            $os = New-LicenseProduct 'Windows(R), ServerStandard edition' 5 $null 'Windows(R) Operating System, VOLUME_MAK channel'
            $addOn = New-LicenseProduct $AddOnName 1 $null 'Windows(R) Operating System, VOLUME_MAK channel'
            $r = Select-OsLicenseProduct @($addOn, $os)
            $r.Primary.Name | Should -Be 'Windows(R), ServerStandard edition'
            @($r.AddOns).Count | Should -Be 1
        }
        It 'the real 2012 R2 OS licence has LicenseIsAddon False and is the Primary (#330)' {
            $r = Select-OsLicenseProduct @((New-LicenseProduct 'Windows(R), ServerStandard edition' 1 $false 'Windows(R) Operating System, VOLUME_MAK channel'))
            $r.Primary.LicenseStatus | Should -Be 1; @($r.AddOns).Count | Should -Be 0
        }
        It 'a licensed OS product comes before an unlicensed one' {
            $r = Select-OsLicenseProduct @((New-LicenseProduct 'Windows(R), B edition' 5 $false), (New-LicenseProduct 'Windows(R), A edition' 1 $false))
            $r.Primary.Name | Should -Be 'Windows(R), A edition'
        }
        It 'only an add-on: there is no OS licence' {
            $r = Select-OsLicenseProduct @((New-LicenseProduct 'Windows(R), ESU add-on' 1 $true))
            $r.Primary | Should -BeNullOrEmpty; @($r.AddOns).Count | Should -Be 1
        }
        It 'no products' { (Select-OsLicenseProduct @()).Primary | Should -BeNullOrEmpty }
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
    It 'RedactExisting recovers named SQL instances and their ids, not the default instance (#195)' {
        $rows = @(
            [pscustomobject]@{ Area = 'SQL'; Item = 'Database Engine: APPDB'; Value = 'SQL Server 2022'; Details = @('Version=16.0.1000.6', 'InstanceId=MSSQL16.APPDB') }
            [pscustomobject]@{ Area = 'SQL'; Item = 'Database Engine: MSSQLSERVER'; Value = 'SQL Server 2019'; Details = @('InstanceId=MSSQL15.MSSQLSERVER') }
        )
        $l = Get-RedactionLiteralFromResult $rows
        (@($l | ForEach-Object { $_.Kind + '=' + $_.Value }) -join ';') | Should -Be 'NAME=APPDB;NAME=MSSQL16.APPDB'
    }
    It 'RedactExisting recovers a KMS host FQDN and its first label, like the live run (#124)' {
        $rows = @([pscustomobject]@{ Area = 'LICENSING'; Item = 'CurrentActivation'; Value = 'Licensed (KMS client)'; Details = @('KMS host: kms01.corp.example.test:1688 (set on this server)') })
        $l = Get-RedactionLiteralFromResult $rows
        (@($l | ForEach-Object { $_.Kind + '=' + $_.Value }) -join ';') | Should -Be 'HOST=kms01.corp.example.test;HOST=kms01'
    }
}
