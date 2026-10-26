# Pester 5 tests for the check bodies: access and security
# They run against the fake server in FakeServer.ps1 (Windows only).

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'The fake server deliberately shadows system cmdlets for the script under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-ins mirror the parameters the script passes to the real cmdlets.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Stand-ins return fixture objects.')]
param()

BeforeAll { . (Join-Path $PSScriptRoot 'FakeServer.ps1') }

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'Checks on a fake server: access and security' -Skip:($env:OS -ne 'Windows_NT') {
    BeforeEach { Reset-FakeServer }

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
            (Get-Row 'GROUP_POLICY' 'ComputerOU')[0].Value | Should -Be 'corp.example.test/Servers/Web'   # (#99)
            $script:Data.AdLocation | Should -Be 'corp.example.test/Servers/Web'
            $script:Data.Snapshot.Ou | Should -Be 'CN=SRV01,OU=Web,OU=Servers,DC=corp,DC=example,DC=test'
        }
        It 'a workgroup server: local policy only, no MANUAL (#80)' {
            $script:Fake.Cim['Win32_ComputerSystem'].PartOfDomain = $false
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'grouppolicy'
            (Get-Row 'GROUP_POLICY' 'GroupPolicyScope')[0].Value | Should -Be 'Workgroup server: only local policy applies'
            (Get-Row 'GROUP_POLICY' 'GPO: Local Group Policy')[0].Value | Should -Be 'Applied'
            (Get-Row 'GROUP_POLICY' 'ADGroup')[0].Value | Should -Be 'Not applicable (workgroup)'
            @($script:Results | Where-Object { $_.Area -eq 'GROUP_POLICY' -and $_.Status -eq 'MANUAL' }).Count | Should -Be 0
            $script:Data.AdLocation | Should -Be 'Not applicable (workgroup)'   # (#99)
        }
        It 'a domain member that cannot reach AD: MANUAL, GPO list still shown, groups not in the snapshot (#80)' {
            $script:Fake.AdError = 'The server is not operational.'
            $null = Invoke-TestCheck 'grouppolicy'
            (Get-Row 'GROUP_POLICY' 'DomainLookup')[0].Status | Should -Be 'MANUAL'
            (Get-Row 'GROUP_POLICY' 'GPO: Server Baseline')[0].Status | Should -Be 'INFO'
            (Get-Row 'GROUP_POLICY' 'ADGroup').Count | Should -Be 0
            $script:Data.Snapshot.ContainsKey('Groups') | Should -BeFalse
            $script:Data.AdLocation | Should -Be 'Not readable (domain not reachable)'   # (#99)
            $script:Data.Snapshot.ContainsKey('Ou') | Should -BeFalse
        }
        It 'gpresult failing on a domain member: MANUAL and no GPO list in the snapshot (#80)' {
            $script:Fake.GpResultError = 'gpresult wrote no result (exit 1)'
            $null = Invoke-TestCheck 'grouppolicy'
            (Get-Row 'GROUP_POLICY' 'GroupPolicyScope')[0].Status | Should -Be 'MANUAL'
            $script:Data.Snapshot.ContainsKey('Gpos') | Should -BeFalse
        }
        It 'gpresult without RSoP data as SYSTEM: applied GPOs from the registry, AD groups still listed (#160)' {
            $script:Fake.GpResultError = 'gpresult wrote no result (exit 0): INFO: The user "CORP\SRV01$" does not have RSoP data.'
            $script:Fake.GpoList = @(
                [pscustomobject]@{ DisplayName = 'Server Baseline'; GPOName = '{11111111-1111-1111-1111-111111111111}'; Link = 'LDAP://OU=Servers,DC=corp,DC=example,DC=test' },
                [pscustomobject]@{ DisplayName = 'Default Domain Policy'; GPOName = '{31B2F340-016D-11D2-945F-00C04FB984F9}'; Link = 'LDAP://DC=corp,DC=example,DC=test' },
                [pscustomobject]@{ DisplayName = 'Local Group Policy'; GPOName = 'LocalGPO'; Link = 'Local' })
            $null = Invoke-TestCheck 'grouppolicy'
            @(Get-Row 'GROUP_POLICY' 'GroupPolicyScope' | Where-Object { $_.Status -eq 'MANUAL' }).Count | Should -Be 0
            (Get-Row 'GROUP_POLICY' 'GroupPolicySource')[0].Value | Should -Match 'registry'
            (Get-Row 'GROUP_POLICY' 'GroupPolicySource')[0].Details | Should -Match 'does not have RSoP data'
            $gpo = (Get-Row 'GROUP_POLICY' 'GPO: Server Baseline')[0]
            $gpo.Details | Should -Match 'Linked at corp\.example\.test/Servers'
            $gpo.Status | Should -Be 'WARNING'   # the OS-version WMI filter is still found in AD by GUID
            (Get-Row 'GROUP_POLICY' 'ADGroup').Count | Should -Be 3
            $script:Data.Snapshot.Gpos | Should -Contain 'Server Baseline'
        }
        It 'gpresult and the registry both failing: MANUAL, AD groups still listed (#160)' {
            $script:Fake.GpResultError = 'gpresult wrote no result (exit 1)'
            $script:Fake.GpoListError = 'Simulated: key missing'
            $null = Invoke-TestCheck 'grouppolicy'
            (Get-Row 'GROUP_POLICY' 'GroupPolicyScope')[0].Status | Should -Be 'MANUAL'
            (Get-Row 'GROUP_POLICY' 'GroupPolicyScope')[0].Details | Should -Match 'Registry fallback failed: Simulated: key missing'
            (Get-Row 'GROUP_POLICY' 'ADGroup').Count | Should -Be 3
        }
        It 'Group Policy not applied for longer than GroupPolicyMaxAgeDays is a WARNING (#80)' {
            $script:Fake.GpLastApplied = (Get-Date).AddDays(-30)
            $null = Invoke-TestCheck 'grouppolicy'
            (Get-Row 'GROUP_POLICY' 'GroupPolicyLastApplied')[0].Status | Should -Be 'WARNING'
        }
    }

    Context 'domain' {
        It 'calls a non-domain server a workgroup server, with the workgroup name (#98)' {
            $script:Fake.Cim['Win32_ComputerSystem'].PartOfDomain = $false
            $script:Fake.Cim['Win32_ComputerSystem'].DomainRole = 2
            $script:Fake.Cim['Win32_ComputerSystem'].Domain = 'WORKGROUP'
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'domain'
            $script:Data.DomainRoleText | Should -Be 'Workgroup server (standalone), workgroup WORKGROUP'
            (Get-Row 'ACCESS' 'DomainMembership')[0].Details | Should -Be 'Role=Workgroup server (standalone), workgroup WORKGROUP'
        }
        It 'a domain controller does not list its accounts for the built-in Administrator (#241)' {
            $script:Fake.Cim['Win32_ComputerSystem'].DomainRole = 5
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'domain'
            $row = (Get-Row 'ACCESS' 'BuiltInAdministrator')[0]
            $row.Value | Should -Be 'Not looked up on a domain controller'
            $row.Status | Should -Be 'INFO'
        }
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
        It 'a domain controller is evidence only; the SPECIAL section carries the plan (#152)' {
            $script:Fake.Cim['Win32_ComputerSystem'].DomainRole = 5
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'domain'
            $r = (Get-Row 'DOMAIN_CONTROLLER' 'DomainController')[0]
            $r.Status | Should -Be 'INFO'
            $r.Recommendation | Should -Match 'SPECIAL'
        }
        It 'with -BlockDomainControllerIPU $false a domain controller is a WARNING in a full report' {
            $script:Fake.Cim['Win32_ComputerSystem'].DomainRole = 5
            Reset-FakeServerKeep
            $BlockDomainControllerIPU = $false
            $null = Invoke-TestCheck 'domain'
            (Get-Row 'DOMAIN_CONTROLLER' 'DomainController')[0].Status | Should -Be 'WARNING'
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
        BeforeEach { $script:RdpEvidence = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')) }
        It 'a reachable server is GO and evidence is written' {
            $PolicyEvidenceRoot = $script:RdpEvidence
            (Invoke-TestCheck 'rdp').Outcome | Should -Be 'Completed'
            (Get-Row 'RDP' 'RDPAccessReadiness')[0].Value | Should -Be 'GO'
            (Get-Row 'RDP' 'DriveRedirection')[0].Status | Should -Be 'OK'
            (Get-Row 'RDP' 'SeRemoteInteractiveLogonRight')[0].Value | Should -Match 'S-1-5-32-544'
            $script:Data.PolicyEvidence | Should -Match '\.zip$'
            $script:Data.PolicyEvidence | Should -Exist
        }
        It 'an empty -LgpoExe skips LGPO and the rest of the evidence completes (#150)' {
            $PolicyEvidenceRoot = $script:RdpEvidence
            $LgpoExe = ''
            (Invoke-TestCheck 'rdp').Outcome | Should -Be 'Completed'
            (Get-Row 'POLICY_EVIDENCE' 'LocalGroupPolicyBackup')[0].Value | Should -Match 'LGPO disabled'
            (Get-Row 'RDP' 'RDPAccessReadiness')[0].Value | Should -Be 'GO'
        }
        It 'RDP disabled is NO-GO' {
            $PolicyEvidenceRoot = $script:RdpEvidence
            $script:Fake.Registry['HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server|fDenyTSConnections'] = 1
            $null = Invoke-TestCheck 'rdp'
            $r = (Get-Row 'RDP' 'RDPAccessReadiness')[0]
            $r.Status | Should -Be 'ACTION'
            $r.Value | Should -Be 'NO-GO'
        }
        It 'NLA off and blocked drive redirection are reported' {
            $PolicyEvidenceRoot = $script:RdpEvidence
            $script:Fake.Registry['HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp|UserAuthentication'] = 0
            $script:Fake.Registry['HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services|fDisableCdm'] = 1
            $null = Invoke-TestCheck 'rdp'
            (Get-Row 'RDP' 'NetworkLevelAuthentication')[0].Kind | Should -Be 'Observation'
            (Get-Row 'RDP' 'DriveRedirection')[0].Status | Should -Be 'WARNING'
        }
        It 'policy evidence goes to EvidenceRoot\Policy unless PolicyEvidenceRoot is set (#198)' {
            $PolicyEvidenceRoot = ''
            $EvidenceRoot = $script:RdpEvidence
            (Invoke-TestCheck 'rdp').Outcome | Should -Be 'Completed'
            $script:Data.PolicyEvidence | Should -BeLike (Join-Path $script:RdpEvidence 'Policy\*-IPU-Policy-*.zip')
        }
        It 'evidence disabled gives REVIEW without writing files' {
            $EnableRDPPolicyEvidence = $false
            $PolicyEvidenceRoot = $script:RdpEvidence
            $null = Invoke-TestCheck 'rdp'
            (Get-Row 'RDP' 'RDPAccessReadiness')[0].Status | Should -Be 'MANUAL'
            $script:RdpEvidence | Should -Not -Exist
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
}
