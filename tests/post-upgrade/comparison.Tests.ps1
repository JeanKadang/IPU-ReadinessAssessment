# Pester 5 tests. Post-upgrade comparison rules (pure functions).
# The script is loaded in library mode by ..\TestSetup.ps1: functions only, nothing is collected.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
param()

BeforeAll { . (Join-Path $PSScriptRoot '..\TestSetup.ps1') }

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

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

Describe 'File shares in the post-upgrade comparison (#95)' {
    It 'a share missing after the upgrade is an ACTION' {
        $d = Compare-IPUSnapshot @{ Shares = @('Data', 'Scans') } @{ Shares = @('Data') }
        $row = @($d | Where-Object { $_.Item -eq 'File shares missing after upgrade' })[0]
        $row.Status | Should -Be 'ACTION'
        $row.Details | Should -Be 'Scans'
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
    It 'recognises only Windows'' per-user feed tasks at the root (#214)' {
        Test-WindowsPerUserTask '\User_Feed_Synchronization-{0F5377C2-5909-4495-A7CC-00331141DFDA}' | Should -BeTrue
        Test-WindowsPerUserTask '\Example\User_Feed_Synchronization-{0F5377C2-5909-4495-A7CC-00331141DFDA}' | Should -BeFalse
        Test-WindowsPerUserTask '\User_Feed_Synchronization' | Should -BeFalse
    }
    It 'a task renamed only by its version or GUID is not missing; a removed task still is (#196)' {
        $old = '\ExampleVendor\Updater\UpdaterTaskSystem156.0.8067.0{F1E18D42-90EA-4F0D-AFDA-E08AB09647CA}'
        $new = '\ExampleVendor\Updater\UpdaterTaskSystem157.0.8089.0{0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9}'
        ConvertTo-TaskBaseName $old | Should -Be '\ExampleVendor\Updater\UpdaterTaskSystem'
        ConvertTo-TaskBaseName '\Backup\Nightly' | Should -Be '\Backup\Nightly'
        $d = Compare-IPUSnapshot ([pscustomobject]@{ Tasks = @($old, '\Backup\Nightly') }) ([pscustomobject]@{ Tasks = @($new) })
        (@($d | Where-Object { $_.Item -eq 'Scheduled tasks missing after upgrade' }))[0].Details | Should -Be '\Backup\Nightly'
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
    It 'AzureArcSetup, a Feature on Demand from Windows Server 2025 on, is INFO, not missing (#197)' {
        $d = Compare-IPUSnapshot ([pscustomobject]@{ Features = @('AzureArcSetup', 'FS-FileServer') }) ([pscustomobject]@{ Features = @('FS-FileServer') })
        $r = @($d | Where-Object { $_.Item -eq 'Windows features removed or renamed by Microsoft' })[0]
        $r.Status | Should -Be 'INFO'
        $r.Details | Should -Be 'AzureArcSetup'
        $r.Recommendation | Should -Match 'Feature on Demand'
        @($d | Where-Object { $_.Item -eq 'Windows features missing after upgrade' }).Count | Should -Be 0
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
    It 'only Windows'' per-user service templates lose their suffix; a hex-like suffix on another service stays (#247)' {
        foreach ($name in 'AppSvc_DB01', 'Backup_2016', 'Agent_CAFE', 'MSSQL_0001') { ConvertTo-ServiceBaseName $name | Should -Be $name }
        ConvertTo-ServiceBaseName 'OneSyncSvc_443f50' | Should -Be 'OneSyncSvc'
        ConvertTo-ServiceBaseName 'onesyncsvc_443F50' | Should -Be 'onesyncsvc'
        ConvertTo-ServiceBaseName 'webthreatdefusersvc_a1b2c3' | Should -Be 'webthreatdefusersvc'
    }
    It 'a running Auto service with a hex-like suffix that is gone after the upgrade is WARNING, not INFO (#247)' {
        $b = [pscustomobject]@{ Services = @((New-Svc 'AppSvc_DB01' 'Running' 'Auto')) }
        $a = [pscustomobject]@{ Services = @() }
        $d = Compare-IPUSnapshot $b $a
        @($d | Where-Object { $_.Item -eq 'Services no longer present' })[0].Details | Should -Be 'AppSvc_DB01'
        @($d | Where-Object { $_.Item -eq 'Service changes made by Windows' }).Count | Should -Be 0
    }
    It 'a port whose service is no longer started automatically is INFO, even when the service was Manual before' {
        (Get-Row173 'Ports closed with their service').Details | Should -Be 'UDP:1900'
    }
    It 'a port whose service still runs automatically, or with a process owner, stays WARNING' {
        (Get-Row173 'Listening ports missing after upgrade').Details | Should -Be 'TCP:8080, TCP:9000'
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
    It 'a changed subnet mask on a static adapter is an ACTION (#247)' {
        $after = New-TestAdapter; $after.Mask = @('255.0.0.0')
        $rows = @(Compare-NetworkAdapter @(New-TestAdapter) @($after))
        $rows.Count | Should -Be 1
        $rows[0].Status | Should -Be 'ACTION'
        $rows[0].Details | Should -Be 'Subnet mask of 10.20.30.40: before 255.255.255.0, now 255.0.0.0'
    }
    It 'a changed subnet mask on a DHCP adapter is a WARNING (#247)' {
        $before = New-TestAdapter -Dhcp $true; $after = New-TestAdapter -Dhcp $true; $after.Mask = @('255.255.0.0')
        (@(Compare-NetworkAdapter @($before) @($after)))[0].Status | Should -Be 'WARNING'
    }
    It 'the mask is compared per address, in step with the address list (#247)' {
        $before = New-TestAdapter -IPv4 @('10.20.30.40', '10.20.31.40'); $before.Mask = @('255.255.255.0', '255.255.255.0')
        $after = New-TestAdapter -IPv4 @('10.20.31.40', '10.20.30.40'); $after.Mask = @('255.255.255.0', '255.255.255.0')
        @(Compare-NetworkAdapter @($before) @($after)).Count | Should -Be 0
        $after.Mask = @('255.255.0.0', '255.255.255.0')
        (@(Compare-NetworkAdapter @($before) @($after)))[0].Details | Should -Be 'Subnet mask of 10.20.31.40: before 255.255.255.0, now 255.255.0.0'
    }
    It 'a missing mask is not a change (#247)' {
        $after = New-TestAdapter; $after.Mask = @()
        @(Compare-NetworkAdapter @(New-TestAdapter) @($after)).Count | Should -Be 0
    }
    It 'a changed registration with the DNS suffix is a WARNING (#247)' {
        $after = New-TestAdapter; $after.RegisterSuffix = $true
        $rows = @(Compare-NetworkAdapter @(New-TestAdapter) @($after))
        $rows[0].Status | Should -Be 'WARNING'
        $rows[0].Details | Should -Be 'Register with DNS suffix: before False, now True'
    }
    It 'a baseline without RegisterSuffix does not report a change (#247)' {
        $before = New-TestAdapter; $before.PSObject.Properties.Remove('RegisterSuffix')
        $after = New-TestAdapter; $after.RegisterSuffix = $true
        @(Compare-NetworkAdapter @($before) @($after)).Count | Should -Be 0
    }
    It 'an added address with nothing lost is INFO (#247)' {
        $after = New-TestAdapter -IPv4 @('10.20.30.40', '10.20.30.41'); $after.Mask = @('255.255.255.0', '255.255.255.0')
        $rows = @(Compare-NetworkAdapter @(New-TestAdapter) @($after))
        $rows.Count | Should -Be 1
        $rows[0].Status | Should -Be 'INFO'
        $rows[0].Details | Should -Be 'IPv4 added: 10.20.30.41'
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

Describe 'Get-CurrentListGap (#306)' {
    BeforeAll {
        function New-Snap([hashtable]$H) { [pscustomobject]$H }
    }
    It 'a list the baseline has and this run lacks is a gap: <List>' -TestCases @(
        @{ List = 'Services' }, @{ List = 'Apps' }, @{ List = 'Features' }, @{ List = 'Ports' }
        @{ List = 'IPv4' }, @{ List = 'Dns' }, @{ List = 'Adapters' }, @{ List = 'Hosts' }, @{ List = 'Routes' }
        @{ List = 'Tasks' }, @{ List = 'Shares' }, @{ List = 'Printers' }, @{ List = 'PrinterPorts' }, @{ List = 'PrinterDrivers' }
        @{ List = 'Gpos' }, @{ List = 'Groups' }
    ) {
        $before = New-Snap @{ $List = @('entry') }
        $gaps = @(Get-CurrentListGap $before (New-Snap @{}) @())
        $gaps.Count | Should -Be 1
        $gaps[0].List | Should -Be $List
        $gaps[0].Reason | Should -Be 'this run could not read it'
    }
    It 'a list whose source check did not complete in this run is a gap, even when present' {
        $runs = @([pscustomobject]@{ Id = 'network'; Outcome = 'TimedOut' })
        $gaps = @(Get-CurrentListGap (New-Snap @{ Routes = @('r1'); IPv4 = @('10.0.0.5') }) (New-Snap @{ Routes = @(); IPv4 = @() }) $runs)
        (@($gaps | ForEach-Object { $_.List }) -join ',') | Should -Be 'IPv4,Routes'
        $gaps[0].Reason | Should -Be 'the network check timed out in this run'
    }
    It 'reads a hashtable snapshot as well as an object' {
        @(Get-CurrentListGap (New-Snap @{ Ports = @('TCP:443') }) @{ Ports = @() } @()).Count | Should -Be 0
        @(Get-CurrentListGap (New-Snap @{ Ports = @('TCP:443') }) @{ } @()).Count | Should -Be 1
    }
    It 'no gap when the baseline list is empty or missing' {
        @(Get-CurrentListGap (New-Snap @{ Routes = @() }) (New-Snap @{}) @()).Count | Should -Be 0
        @(Get-CurrentListGap (New-Snap @{}) (New-Snap @{}) @()).Count | Should -Be 0
    }
    It 'no gap when the list was read and its check completed' {
        $runs = @([pscustomobject]@{ Id = 'ports'; Outcome = 'Completed' })
        @(Get-CurrentListGap (New-Snap @{ Ports = @('TCP:443') }) (New-Snap @{ Ports = @() }) $runs).Count | Should -Be 0
    }
    It 'no baseline gives no gaps' {
        @(Get-CurrentListGap $null (New-Snap @{}) @()).Count | Should -Be 0
    }
}

Describe 'Get-SnapshotWithoutList (#306)' {
    It 'leaves out the named lists and keeps the rest, without changing the original' {
        $snap = [pscustomobject]@{ Ports = @('TCP:443'); Routes = @('r1'); Nla = 'On' }
        $copy = Get-SnapshotWithoutList $snap @('Routes')
        (@($copy.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') | Should -Be 'Ports,Nla'
        $copy.Nla | Should -Be 'On'
        @($snap.PSObject.Properties).Count | Should -Be 3
    }
}
