# Pester 5 tests for the check bodies: platform storage network
# They run against the fake server in FakeServer.ps1 (Windows only).

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'The fake server deliberately shadows system cmdlets for the script under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-ins mirror the parameters the script passes to the real cmdlets.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Stand-ins return fixture objects.')]
param()

BeforeAll { . (Join-Path $PSScriptRoot 'FakeServer.ps1') }

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'Checks on a fake server: platform storage network' -Skip:($env:OS -ne 'Windows_NT') {
    BeforeEach { Reset-FakeServer }

    Context 'storage: space after C (#241)' {
        It 'is worked out from the partition layout and the disk size, not from Get-PartitionSupportedSize' {
            $script:Fake.SupportedSize = $null
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'storage'
            $row = (Get-Row 'STORAGE' 'CExtendableNowGB')
            $row.Count | Should -Be 1
            $row[0].Value | Should -Match '^0[.,]4'
            $row[0].Source | Should -Be 'Get-Partition, Get-Disk'
        }
    }

    Context 'special (#152)' {
        It 'a cluster node gets the SPECIAL row and the facts to choose a plan' {
            $script:Fake.MissingCommands = @('Get-VMSwitch')
            $script:Fake.Features['Failover-Clustering'] = $true
            $script:Fake.Cluster = [pscustomobject]@{ Name = 'CL01' }
            $script:Fake.ClusterNodes = @([pscustomobject]@{ Name = 'SRV01'; State = 'Up' }, [pscustomobject]@{ Name = 'SRV02'; State = 'Up' })
            $script:Fake.ClusterGroups = @([pscustomobject]@{ Name = 'SQL (MSSQLSERVER)'; GroupType = 'Unknown'; State = 'Online'; OwnerNode = 'SRV01' }, [pscustomobject]@{ Name = 'Cluster Group'; GroupType = 'Cluster'; State = 'Online'; OwnerNode = 'SRV01' })
            $script:Fake.ClusterResources = @([pscustomobject]@{ Name = 'SQL Server'; ResourceType = 'SQL Server'; State = 'Online'; OwnerGroup = 'SQL (MSSQLSERVER)' })
            $script:Fake.ClusterQuorum = [pscustomobject]@{ QuorumType = 'NodeAndFileShareMajority'; QuorumResource = 'File Share Witness' }
            Reset-FakeServerKeep
            $script:Data.SpecialKind = 'Cluster'
            $run = Invoke-TestCheck 'special'
            $run.Message | Should -BeNullOrEmpty
            $run.Outcome | Should -Be 'Completed'
            $r = (Get-Row 'SPECIAL' 'Failover cluster node')[0]
            $r.Status | Should -Be 'SPECIAL'
            $script:Data.Special.Facts | Should -Contain 'Cluster: CL01'
            $script:Data.Special.Facts | Should -Contain 'Nodes (2): SRV01 (Up), SRV02 (Up)'
            $script:Data.Special.Facts | Should -Contain 'SQL Server failover cluster instances: 1'
            $script:Data.Special.Facts | Should -Contain 'Roles: Unknown x1'
        }
        It 'a cluster fact that cannot be read says so instead of a count of 0 (#306)' {
            $script:Fake.MissingCommands = @('Get-VMSwitch')
            $script:Fake.Features['Failover-Clustering'] = $true
            $script:Fake.Cluster = [pscustomobject]@{ Name = 'CL01' }
            $script:Fake.Fail['Get-ClusterNode'] = 'Error'
            Reset-FakeServerKeep
            $script:Data.SpecialKind = 'Cluster'
            (Invoke-TestCheck 'special').Outcome | Should -Be 'Completed'
            $script:Data.Special.Facts | Should -Contain 'Nodes: not readable'
            @($script:Data.Special.Facts | Where-Object { $_ -like 'Nodes (0)*' }).Count | Should -Be 0
        }
        It 'a domain controller gets the SPECIAL row; facts that cannot be read say so' {
            $script:Fake.Cim['Win32_ComputerSystem'].DomainRole = 5
            Reset-FakeServerKeep
            $script:Data.SpecialKind = 'DomainController'
            $run = Invoke-TestCheck 'special'
            $run.Message | Should -BeNullOrEmpty
            $run.Outcome | Should -Be 'Completed'
            (Get-Row 'SPECIAL' 'Domain controller')[0].Status | Should -Be 'SPECIAL'
            @($script:Data.Special.Facts | Where-Object { $_ -like 'Other roles on this server:*' }).Count | Should -Be 1
            @($script:Data.Special.Facts | Where-Object { $_ -like 'Replication summary*' }).Count | Should -Be 1
        }
        It 'undecided cluster signals are MANUAL, never a silent standard report' {
            $script:Data.SpecialKind = 'Undecided'
            $null = Invoke-TestCheck 'special'
            (Get-Row 'SPECIAL' 'ClusterMembership')[0].Status | Should -Be 'MANUAL'
        }
        It 'a normal server gets no SPECIAL rows' {
            $script:Data.SpecialKind = ''
            $null = Invoke-TestCheck 'special'
            @($script:Results | Where-Object { $_.Area -eq 'SPECIAL' }).Count | Should -Be 0
        }
        It 'the whole run on a domain controller is a short SPECIAL report' {
            $script:Fake.Cim['Win32_ComputerSystem'].DomainRole = 5
            Reset-FakeServerKeep
            $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $ReportDirectory = $dir; $RestrictOutputAcl = $false; $WriteJson = $true; $EnableRDPPolicyEvidence = $false
            $script:ReportPath = Join-Path $dir 'SRV01-IPU-Assessment.html'
            $script:JsonPath = Join-Path $dir 'SRV01-IPU-Assessment.json'
            $script:LogPath = Join-Path $dir 'SRV01-IPU-Assessment.log'
            $script:Results.Clear(); $script:CheckRuns.Clear(); $script:Checks.Clear()
            function Get-PrerequisiteState { [pscustomobject]@{ PowerShellVersion = [Version]'5.1'; DotNetRelease = 528049; IsElevated = $true; MissingModules = @() } }
            $writer = New-Object IO.StringWriter
            $old = [Console]::Out
            [Console]::SetOut($writer)
            try { Invoke-Assessment } finally { [Console]::SetOut($old) }
            $out = $writer.ToString()
            $out | Should -Match ';SUCCEEDED;SPECIAL;'
            $out | Should -Match 'SPECIAL server \(Domain controller\): short report'
            @($script:CheckRuns | Where-Object { $_.Id -eq 'dism' })[0].Message | Should -Be 'Not applicable: SPECIAL server, short report'
            @($script:CheckRuns | Where-Object { $_.Id -eq 'special' })[0].Outcome | Should -Be 'Completed'
            $json = [IO.File]::ReadAllText($script:JsonPath) | ConvertFrom-Json
            $json.Overall | Should -Be 'SPECIAL'
            $json.Special.Kind | Should -Be 'DomainController'
            $json.Counts.SPECIAL | Should -Be 1
            [IO.File]::ReadAllText($script:ReportPath) | Should -Match '<section id="special"'
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
        It 'cluster membership points to SPECIAL, lists nodes and registers their names for redaction (#152)' {
            $script:Fake.Features['Failover-Clustering'] = $true
            $script:Fake.MissingCommands = @('Get-VMSwitch')
            $script:Fake.Cluster = [pscustomobject]@{ Name = 'CL01' }
            $script:Fake.ClusterNodes = @([pscustomobject]@{ Name = 'SRV01'; State = 'Up' }, [pscustomobject]@{ Name = 'SRV02'; State = 'Up' })
            $script:Fake.ClusterQuorum = [pscustomobject]@{ QuorumType = 'NodeAndFileShareMajority'; QuorumResource = 'File Share Witness' }
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'cluster'
            (Get-Row 'CLUSTER' 'ClusterMembership')[0].Status | Should -Be 'INFO'
            (Get-Row 'CLUSTER' 'Node: SRV02').Count | Should -Be 1
            $script:Data.RedactLiterals.ContainsKey('CL01') | Should -BeTrue
            $script:Data.RedactLiterals.ContainsKey('SRV02') | Should -BeTrue
            (Get-Row 'CLUSTER' 'Quorum').Count | Should -Be 1
            (Get-Row 'CLUSTER' 'ClusterDetails').Count | Should -Be 0
        }
        It 'cluster details that cannot be read are named as MANUAL, not left out (#306)' {
            $script:Fake.Features['Failover-Clustering'] = $true
            $script:Fake.MissingCommands = @('Get-VMSwitch')
            $script:Fake.Cluster = [pscustomobject]@{ Name = 'CL01' }
            $script:Fake.Fail['Get-ClusterNode'] = 'Error'
            $script:Fake.Fail['Get-ClusterQuorum'] = 'Error'
            Reset-FakeServerKeep
            (Invoke-TestCheck 'cluster').Outcome | Should -Be 'Completed'
            $r = (Get-Row 'CLUSTER' 'ClusterDetails')[0]
            $r.Status | Should -Be 'MANUAL'
            (@($r.Details) -join ' ') | Should -Match 'nodes'
            (@($r.Details) -join ' ') | Should -Match 'quorum'
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
        It 'predicts a new recovery partition before the upgrade and shows the Setup switch (#161)' {
            $null = Invoke-TestCheck 'storage'
            $r = (Get-Row 'STORAGE' 'RecoveryPartitionAfterC')[0]
            $r.Status | Should -Be 'WARNING'
            $r.Value | Should -Match 'smaller than 900 MB'
            $r.Command | Should -Be 'setup.exe /ResizeRecoveryPartition Disable'
        }
        It 'a recovery partition after C: gets the removal steps with its number (#161)' {
            $script:Fake.Partitions += [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 4; DriveLetter = $null; Offset = [double]99.6GB; Size = 901MB; Type = 'Recovery'; GptType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'; MbrType = 0; IsSystem = $false; AccessPaths = @() }
            $script:Fake.Volumes['0-4'] = [pscustomobject]@{ Size = 901MB; SizeRemaining = 147MB; FileSystemLabel = ''; FileSystem = 'NTFS' }
            $script:Fake.Native['reagentc.exe'] = @{ ExitCode = 0; Output = "    Windows RE status:         Enabled`r`n    Windows RE location:       \\?\GLOBALROOT\device\harddisk0\partition4\Recovery\WindowsRE" }
            $null = Invoke-TestCheck 'storage'
            $r = (Get-Row 'STORAGE' 'RecoveryPartitionAfterC')[0]
            $r.Value | Should -Match 'P4 \(901 MB\) directly after C:'
            $r.Command | Should -Match 'select partition 4'
            $r.Recommendation | Should -Match 'WinRE is on it'
            (Get-Row 'STORAGE' 'WinREStatus')[0].Value | Should -Be 'Enabled, Disk0 P4'
        }
        It 'German reagentc output: the WinRE row is written from ReAgent.xml and the location (#246)' {
            $script:Fake.Native['reagentc.exe'] = @{ ExitCode = 0; Output = "    Status der Windows RE:     Aktiviert`r`n    Windows RE-Speicherort:    \?\GLOBALROOT\device\harddisk0\partition4\Recovery\WindowsRE" }
            $script:Fake.ReAgentXml = '<WindowsRE version="2.0"><InstallState state="1"/></WindowsRE>'
            $null = Invoke-TestCheck 'storage'
            (Get-Row 'STORAGE' 'WinREStatus')[0].Value | Should -Be 'Enabled, Disk0 P4'
        }
        It 'unreadable reagentc output and no ReAgent.xml is MANUAL, not silence (#246)' {
            $script:Fake.Native['reagentc.exe'] = @{ ExitCode = 0; Output = "    Status der Windows RE:     Aktiviert" }
            $script:Fake.ReAgentXml = ''
            $null = Invoke-TestCheck 'storage'
            $r = (Get-Row 'STORAGE' 'WinREStatus')
            $r.Count | Should -Be 1; $r[0].Status | Should -Be 'MANUAL'
        }
        It 'a failed reagentc /info is MANUAL (#161)' {
            $script:Fake.Native['reagentc.exe'] = @{ ExitCode = 2; Output = 'Access denied' }
            (Invoke-TestCheck 'storage').Outcome | Should -Be 'Completed'
            (Get-Row 'STORAGE' 'WinREStatus')[0].Status | Should -Be 'MANUAL'
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
        It 'adapter details: IPv6, DNS suffix, registration, WINS, NetBIOS, metric and VLAN (#149)' {
            $script:Fake.Cim['Win32_NetworkAdapterConfiguration|IPEnabled=True'] = [pscustomobject]@{ Index = 1; IPAddress = @('10.20.30.40', 'fe80::1', '2001:db8::40'); IPSubnet = @('255.255.255.0', '64', '64'); DefaultIPGateway = @('10.20.30.1'); DNSServerSearchOrder = @('10.20.1.10'); DHCPEnabled = $false; MACAddress = '00:50:56:00:00:01'; Description = 'vmxnet3 Ethernet Adapter'; DNSDomain = 'corp.example.test'; DNSDomainSuffixSearchOrder = @('corp.example.test', 'example.test'); FullDNSRegistrationEnabled = $true; DomainDNSRegistrationEnabled = $false; WINSPrimaryServer = '10.20.1.20'; WINSSecondaryServer = $null; TcpipNetbiosOptions = 2; IPConnectionMetric = 15 }
            $script:Fake.NetAdapters = @([pscustomobject]@{ Name = 'Ethernet0'; InterfaceDescription = 'vmxnet3 Ethernet Adapter'; MacAddress = '00-50-56-00-00-01'; VlanID = 20 })
            $null = Invoke-TestCheck 'network'
            $d = @((Get-Row 'NETWORK' 'Ethernet0')[0].Details) -join ' | '
            foreach ($want in @('IPv6=fe80::1,2001:db8::40', 'DNS suffix=corp.example.test', 'Suffix search list=corp.example.test,example.test', 'Register in DNS=Yes, with suffix=No', 'WINS=10.20.1.20', 'NetBIOS over TCP/IP=Disabled', 'Metric=15', 'VLAN=20', 'MAC=00:50:56:00:00:01')) {
                $d | Should -Match ([regex]::Escape($want))
            }
            $snap = @($script:Data.Snapshot.Adapters)
            $snap.Count | Should -Be 1
            $snap[0].Mac | Should -Be '00:50:56:00:00:01'
            $snap[0].Vlan | Should -Be '20'
            $snap[0].NetBios | Should -Be 'Disabled'
            $script:Data.Snapshot.IPv4 | Should -Contain '10.20.30.40'
        }
        It 'saves the network evidence file in the evidence folder (#149)' {
            $EvidenceRoot = Join-Path $TestDrive 'evidence'
            $null = Invoke-TestCheck 'network'
            $row = (Get-Row 'NETWORK' 'NetworkEvidence')[0]
            $row.Status | Should -Be 'OK'
            $row.Value | Should -BeLike (Join-Path $EvidenceRoot 'Network\*-IPU-Network-*.zip')
            $row.Recommendation | Should -Match 'off the server'
            $row.Recommendation | Should -Match 'not redacted'
            $script:Data.NetworkEvidence | Should -Be $row.Value
        }
        It 'a command that failed makes the evidence MANUAL, listing it (#149)' {
            $script:Fake.NetEvidenceFailed = @('route print: no answer within 60 seconds')
            $null = Invoke-TestCheck 'network'
            $row = (Get-Row 'NETWORK' 'NetworkEvidence')[0]
            $row.Status | Should -Be 'MANUAL'
            $row.Kind | Should -Be 'Finding'
            (@($row.Details) -join ' ') | Should -Match 'Failed: route print: no answer'
        }
        It 'evidence that could not be saved is MANUAL, not silence (#149)' {
            $script:Fake.NetEvidenceError = 'Access is denied'
            $null = Invoke-TestCheck 'network'
            $row = (Get-Row 'NETWORK' 'NetworkEvidence')[0]
            $row.Status | Should -Be 'MANUAL'
            $row.Details | Should -Match 'Access is denied'
        }
        It 'switched off: no evidence, and said so (#149)' {
            $EnableNetworkEvidence = $false
            $null = Invoke-TestCheck 'network'
            (Get-Row 'NETWORK' 'NetworkEvidence')[0].Value | Should -Match 'EnableNetworkEvidence is off'
        }
        It 'without Get-NetRoute the routes are MANUAL' {
            $script:Fake.MissingCommands += 'Get-NetRoute'
            $null = Invoke-TestCheck 'network'
            (Get-Row 'NETWORK_DEPENDENCY' 'StaticRoutes')[0].Value | Should -Be 'Get-NetRoute unavailable'
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
}
