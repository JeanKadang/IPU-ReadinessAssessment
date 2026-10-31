# Pester 5 tests for the check bodies: failed reads
# They run against the fake server in FakeServer.ps1 (Windows only).

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'The fake server deliberately shadows system cmdlets for the script under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-ins mirror the parameters the script passes to the real cmdlets.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Stand-ins return fixture objects.')]
param()

BeforeAll { . (Join-Path $PSScriptRoot 'FakeServer.ps1') }

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'Checks on a fake server: failed reads' -Skip:($env:OS -ne 'Windows_NT') {
    BeforeEach { Reset-FakeServer }

    Context 'a failed query is not a clean result (#242)' {
        BeforeEach { $script:RdpEvidence = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')) }
        It 'LBFO: a failed team query is MANUAL, not "No LBFO team detected"' {
            $script:Fake.Fail['Get-NetLbfoTeam'] = 'Error'
            (Invoke-TestCheck 'network').Outcome | Should -Be 'Completed'
            $r = (Get-Row 'NETWORK' 'NICTeaming')
            $r.Count | Should -Be 1; $r[0].Status | Should -Be 'MANUAL'; $r[0].Kind | Should -Be 'Finding'
            $r[0].Details | Should -Match 'Simulated failure'
        }
        It 'LBFO: "nothing found" is still the clean answer' {
            $script:Fake.Fail['Get-NetLbfoTeam'] = 'NotFound'
            $null = Invoke-TestCheck 'network'
            (Get-Row 'NETWORK' 'NICTeaming')[0].Status | Should -Be 'OK'
        }
        It 'LBFO: a machine without the cmdlet is MANUAL too' {
            $script:Fake.MissingCommands += 'Get-NetLbfoTeam'
            $null = Invoke-TestCheck 'network'
            (Get-Row 'NETWORK' 'NICTeaming')[0].Status | Should -Be 'MANUAL'
        }
        It 'routes: a failed query is MANUAL and the list is left out of the snapshot' {
            $script:Fake.Fail['Get-NetRoute'] = 'Error'
            (Invoke-TestCheck 'network').Outcome | Should -Be 'Completed'
            $r = (Get-Row 'NETWORK_DEPENDENCY' 'StaticRoutes')
            $r.Count | Should -Be 1; $r[0].Status | Should -Be 'MANUAL'; $r[0].Kind | Should -Be 'Finding'
            $script:Data.Snapshot.ContainsKey('Routes') | Should -BeFalse
            $script:Data.Snapshot.ContainsKey('IPv4') | Should -BeTrue
        }
        It 'routes: no route found is the clean answer' {
            $script:Fake.Fail['Get-NetRoute'] = 'NotFound'
            $null = Invoke-TestCheck 'network'
            (Get-Row 'NETWORK_DEPENDENCY' 'StaticRoutes')[0].Status | Should -Be 'OK'
            $script:Data.Snapshot.ContainsKey('Routes') | Should -BeTrue
        }
        It 'ports: a failed query fails the check, which is reported as not completed' {
            $script:Fake.Fail['Get-NetTCPConnection'] = 'Error'
            $run = Invoke-TestCheck 'ports'
            $run.Outcome | Should -Be 'Failed'
            (Get-Row 'COLLECTOR' 'Listening ports')[0].Status | Should -Be 'MANUAL'
            (Get-Row 'PORTS' 'Summary').Count | Should -Be 0
        }
        It 'ports: a machine without Get-NetTCPConnection is MANUAL and leaves the list out' {
            $script:Fake.MissingCommands += 'Get-NetTCPConnection'
            $null = Invoke-TestCheck 'ports'
            (Get-Row 'PORTS' 'ListeningPorts')[0].Status | Should -Be 'MANUAL'
            $script:Data.Snapshot.ContainsKey('Ports') | Should -BeFalse
        }
        It 'ports: nothing found is an empty list, not a failure' {
            $script:Fake.Fail['Get-NetTCPConnection'] = 'NotFound'
            (Invoke-TestCheck 'ports').Outcome | Should -Be 'Completed'
            (Get-Row 'PORTS' 'Summary')[0].Value | Should -Match 'ListeningPorts='
        }
        It 'drivers: a failed device query is MANUAL and the summary says unknown, not 0' {
            $script:Fake.CimThrow = @('Win32_PnPSignedDriver')
            (Invoke-TestCheck 'drivers').Outcome | Should -Be 'Completed'
            (Get-Row 'DRIVERS' 'DeviceDrivers')[0].Status | Should -Be 'MANUAL'
            (Get-Row 'DRIVERS' 'Summary')[0].Value | Should -Match 'NonMicrosoftDevices=unknown'
        }
        It 'IIS: installed without the WebAdministration module is MANUAL, not silence' {
            $script:Fake.Features['Web-Server'] = $true
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'iis'
            (Get-Row 'IIS' 'Sites')[0].Status | Should -Be 'MANUAL'
            (Get-Row 'IIS' 'Sites')[0].Value | Should -Match 'WebAdministration module missing'
        }
        It 'IIS: a failed site query is MANUAL' {
            $script:Fake.Features['Web-Server'] = $true
            $script:Fake.Modules = @('WebAdministration')
            Reset-FakeServerKeep
            $script:Fake.Fail['Get-Website'] = 'Error'
            $null = Invoke-TestCheck 'iis'
            (Get-Row 'IIS' 'Sites')[0].Status | Should -Be 'MANUAL'
        }
        It 'HTTPS bindings: without the module, or when the query fails, they are MANUAL' {
            $script:Fake.Features['Web-Server'] = $true
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'pki'
            (Get-Row 'CERTIFICATES' 'IIS https bindings')[0].Value | Should -Match 'module missing'
            $script:Fake.Modules = @('WebAdministration')
            $script:Fake.Fail['Get-WebBinding'] = 'Error'
            $null = Invoke-TestCheck 'pki'
            (Get-Row 'CERTIFICATES' 'IIS https bindings')[0].Value | Should -Match 'could not be read'
        }
        It 'HTTPS bindings: no binding found is not a failure' {
            $script:Fake.Features['Web-Server'] = $true
            $script:Fake.Modules = @('WebAdministration')
            Reset-FakeServerKeep
            $script:Fake.Fail['Get-WebBinding'] = 'NotFound'
            $null = Invoke-TestCheck 'pki'
            (Get-Row 'CERTIFICATES' 'IIS https bindings').Count | Should -Be 0
        }
        It 'printers: an unreadable inventory without the role but with a running spooler is MANUAL' {
            $script:Fake.Cim['Win32_Service'] = @($script:Fake.Cim['Win32_Service']) + @(New-FakeService 'Spooler' 'Running' 'Auto')
            Reset-FakeServerKeep
            $script:Fake.PrintInvError = 'Simulated: spooler RPC failed'
            (Invoke-TestCheck 'printers').Outcome | Should -Be 'Completed'
            (Get-Row 'PRINTING' 'Printers')[0].Status | Should -Be 'MANUAL'
        }
        It 'printers: a disabled spooler without the role means not a print server' {
            $script:Fake.Cim['Win32_Service'] = @($script:Fake.Cim['Win32_Service']) + @(New-FakeService 'Spooler' 'Stopped' 'Disabled')
            Reset-FakeServerKeep
            $script:Fake.PrintInvError = 'Simulated: spooler RPC failed'
            $null = Invoke-TestCheck 'printers'
            (Get-Row 'PRINTING' 'Printers').Count | Should -Be 0
            (Get-Row 'PRINTING' 'PrintServer')[0].Status | Should -Be 'OK'
        }
        It 'printers: an unreadable inventory with the role is MANUAL' {
            $script:Fake.Features['Print-Server'] = $true
            Reset-FakeServerKeep
            $script:Fake.PrintInvError = 'Simulated: spooler RPC failed'
            $null = Invoke-TestCheck 'printers'
            (Get-Row 'PRINTING' 'Printers')[0].Status | Should -Be 'MANUAL'
        }
        It 'storage: an unreadable partition layout fails the check visibly, with no OK row' {
            $script:Fake.Fail['Get-Partition'] = 'Error'
            $run = Invoke-TestCheck 'storage'
            $run.Outcome | Should -Be 'Failed'
            (Get-Row 'COLLECTOR' 'Storage')[0].Status | Should -Be 'MANUAL'
            (Get-Row 'STORAGE' 'RecoveryPartitionAfterC').Count | Should -Be 0
        }
        It 'storage: a system partition without a readable volume is MANUAL' {
            $script:Fake.Volumes.Remove('0-2')
            $null = Invoke-TestCheck 'storage'
            $r = (Get-Row 'STORAGE' 'SystemPartition')
            $r.Count | Should -Be 1; $r[0].Status | Should -Be 'MANUAL'; $r[0].Kind | Should -Be 'Finding'
            $r[0].Value | Should -Match 'free space not readable'
        }
        It 'storage: a recovery partition without a readable volume is MANUAL too' {
            $script:Fake.Volumes.Remove('0-1')
            $null = Invoke-TestCheck 'storage'
            $r = (Get-Row 'STORAGE' 'RecoveryPartition')
            $r.Count | Should -Be 1; $r[0].Status | Should -Be 'MANUAL'; $r[0].Kind | Should -Be 'Finding'
        }
        It 'security: unreadable AppLocker, BitLocker and TPM states are MANUAL rows' {
            foreach ($n in 'Get-AppLockerPolicy', 'Get-BitLockerVolume', 'Get-Tpm') { $script:Fake.Fail[$n] = 'Error' }
            $null = Invoke-TestCheck 'antivirus'
            (Get-Row 'SECURITY' 'AppLocker')[0].Status | Should -Be 'MANUAL'
            (Get-Row 'SECURITY' 'BitLocker C:')[0].Status | Should -Be 'MANUAL'
            (Get-Row 'SECURITY' 'TPM')[0].Status | Should -Be 'MANUAL'
        }
        It 'security: Secure Boot on a legacy BIOS machine is information, any other error is MANUAL' {
            $script:Fake.SecureBoot = $null
            $null = Invoke-TestCheck 'antivirus'
            (Get-Row 'SECURITY' 'SecureBoot')[0].Status | Should -Be 'INFO'
            (Get-Row 'SECURITY' 'SecureBoot')[0].Value | Should -Match 'legacy BIOS'
            $script:Fake.Fail['Confirm-SecureBootUEFI'] = 'Error'
            $null = Invoke-TestCheck 'antivirus'
            (Get-Row 'SECURITY' 'SecureBoot')[0].Status | Should -Be 'MANUAL'
            (Get-Row 'SECURITY' 'SecureBoot')[0].Value | Should -Not -Match 'legacy BIOS'
        }
        It 'rdp: a failed listener query is not reported as "Nothing listening"' {
            $PolicyEvidenceRoot = $script:RdpEvidence
            $script:Fake.Fail['Get-NetTCPConnection'] = 'Error'
            $null = Invoke-TestCheck 'rdp'
            $r = (Get-Row 'RDP' 'RDPAccessReadiness')[0]
            $r.Value | Should -Be 'REVIEW'
            (@($r.Details) -join ' ') | Should -Match 'listener query failed'
            (@($r.Details) -join ' ') | Should -Not -Match 'Nothing listening'
        }
        It 'rdp: no listener found is still NO-GO' {
            $PolicyEvidenceRoot = $script:RdpEvidence
            $script:Fake.Fail['Get-NetTCPConnection'] = 'NotFound'
            $null = Invoke-TestCheck 'rdp'
            $r = (Get-Row 'RDP' 'RDPAccessReadiness')[0]
            $r.Value | Should -Be 'NO-GO'
            (@($r.Details) -join ' ') | Should -Match 'Nothing listening'
        }
        It 'PKI: an unreadable CA configuration is MANUAL, not an enterprise root CA' {
            $script:Fake.Cim['Win32_Service'] = @($script:Fake.Cim['Win32_Service']) + @(New-FakeService 'CertSvc')
            $script:Fake.Registry['HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration|Active'] = 'Example-CA'
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'pki'
            $r = (Get-Row 'PKI' 'CA: Example-CA')
            $r[0].Status | Should -Be 'MANUAL'
            $r[0].Value | Should -Not -Match 'EnterpriseRoot'
        }
        It 'PKI: a CA configuration without a type is MANUAL; with a type it is listed' {
            $script:Fake.Cim['Win32_Service'] = @($script:Fake.Cim['Win32_Service']) + @(New-FakeService 'CertSvc')
            $script:Fake.Registry['HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration|Active'] = 'Example-CA'
            Reset-FakeServerKeep
            $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\Example-CA'
            $script:Fake.ItemProperty[$key] = [pscustomobject]@{ DBDirectory = 'D:\CA\db'; DBLogDirectory = 'D:\CA\log' }
            $null = Invoke-TestCheck 'pki'
            (Get-Row 'PKI' 'CA: Example-CA')[0].Status | Should -Be 'MANUAL'
            $script:Fake.ItemProperty[$key] = [pscustomobject]@{ CAType = 1; DBDirectory = 'D:\CA\db'; DBLogDirectory = 'D:\CA\log' }
            $null = Invoke-TestCheck 'pki'
            (Get-Row 'PKI' 'CA: Example-CA')[0].Value | Should -Be 'Type=EnterpriseSubordinate'
        }
    }
}

Describe 'Checks on a fake server: a failed baseline (#360, step 3)' -Skip:($env:OS -ne 'Windows_NT') {
    BeforeAll {
        # Evidence copies go to the test drive; no file probe finds anything on the host.
        $EvidenceRoot = Join-Path $TestDrive 'evidence'
        function Resolve-EolProbePath { param([string]$Pattern) return [pscustomobject]@{ Paths = @(); Error = '' } }
        $script:Fake = New-FakeMachine
        $script:Fake.CimThrow = @('Win32_OperatingSystem')   # the first query of baseline fails
        $script:Data = @{}
        $script:Results.Clear(); $script:CheckRuns.Clear()
        foreach ($check in $script:AllChecks) { Invoke-Check $check }
        $script:Runs = @{}
        foreach ($run in $script:CheckRuns.ToArray()) { $script:Runs[$run.Id] = $run }
        $script:Rows = @($script:Results.ToArray())
    }
    It 'baseline itself stopped with an error' {
        $script:Runs['baseline'].Outcome | Should -Be 'Failed'
    }
    It 'every check that reads its data was skipped, and says which check it needs' {
        foreach ($id in $script:CheckNeeds.Keys) {
            $script:Runs[$id].Outcome | Should -Be 'Skipped' -Because $id
            $script:Runs[$id].Message | Should -Match '^Needs (baseline, which stopped with an error|printers, which was not run|eolcandidates, which was not run)$' -Because $id
        }
    }
    It 'each skipped check left exactly one result, a MANUAL finding that says it was not assessed' {
        foreach ($id in $script:CheckNeeds.Keys) {
            $name = $script:Runs[$id].Name
            $mine = @($script:Rows | Where-Object { $_.Area -eq 'COLLECTOR' -and $_.Item -eq $name -and $_.Value -eq 'Check not run' })
            $mine.Count | Should -Be 1 -Because $id
            $mine[0].Status | Should -Be 'MANUAL'
            $mine[0].Kind | Should -Be 'Finding'
            $mine[0].Recommendation | Should -Match 'NOT assessed'
        }
    }
    It 'no skipped check reported anything else: nothing reads as OK or not installed from data it never saw' {
        $skippedNames = @($script:CheckNeeds.Keys | ForEach-Object { $script:Runs[$_].Name })
        $others = @($script:Rows | Where-Object { $_.Area -ne 'COLLECTOR' -and $_.CheckId -in @($script:CheckNeeds.Keys) })
        $others.Count | Should -Be 0 -Because ('rows from skipped checks: ' + (($others | ForEach-Object { $_.CheckId + '/' + $_.Item }) -join ', '))
        $skippedNames.Count | Should -Be $script:CheckNeeds.Count
    }
    It 'the checks that run their own queries still ran' {
        foreach ($id in 'licensing', 'patchlevel', 'storage', 'sql', 'dism', 'sfc') {
            $script:Runs[$id].Outcome | Should -Be 'Completed' -Because $id
        }
    }
    It 'the coverage notice names the area as not assessed' {
        $notice = Get-CoverageNotice @($script:CheckRuns.ToArray())
        $notice.Problems.Count | Should -BeGreaterThan $script:CheckNeeds.Count
        ($notice.Problems -join '|') | Should -Match 'Baseline inventory stopped with an error'
        ($notice.Problems -join '|') | Should -Match 'was skipped \(Needs baseline, which stopped with an error\)'
    }
}
