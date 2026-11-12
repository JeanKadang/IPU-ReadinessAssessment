# Pester 5 tests. The hosts file is judged, not only listed (#412).
# The script is loaded in library mode by ..\TestSetup.ps1: functions only, nothing is collected.

param()

BeforeAll { . (Join-Path $PSScriptRoot '..\TestSetup.ps1') }

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'Get-HostsAddressFamily (#412)' {
    It '<Text> is <Family>' -TestCases @(
        @{ Text = '10.1.1.5';       Family = 'IPv4' }
        @{ Text = '127.0.0.1';      Family = 'IPv4' }
        @{ Text = '0.0.0.0';        Family = 'IPv4' }
        @{ Text = '::1';            Family = 'IPv6' }
        @{ Text = 'fe80::1%12';     Family = 'IPv6' }
        @{ Text = '2001:db8::10';   Family = 'IPv6' }
        @{ Text = '1';              Family = '' }
        @{ Text = '10.1.1';         Family = '' }
        @{ Text = '999.1.1.1';      Family = '' }
        @{ Text = 'app.example.test'; Family = '' }
        @{ Text = '';               Family = '' }
    ) {
        Get-HostsAddressFamily $Text | Should -Be $Family
    }
}

Describe 'Get-HostsEntryDecision (#412)' {
    BeforeAll {
        function Get-Entry($Result, [int]$LineNo) { @($Result.Entries | Where-Object { $_.LineNo -eq $LineNo })[0] }
        $script:Me = 'SRV01'; $script:Dom = 'corp.example.test'
        function Judge([string[]]$Lines, [string[]]$Dcs = @()) {
            Get-HostsEntryDecision -Lines $Lines -ComputerName $script:Me -DomainName $script:Dom -DomainControllers $Dcs
        }
    }

    Context 'the file' {
        It 'a missing file is not reported as "no active entries"' {
            $r = Get-HostsEntryDecision -FileExists $false
            $r.State | Should -Be 'Missing'
            $r.Status | Should -Be 'INFO'
            $r.Value | Should -Not -Match 'No active entries'
        }
        It 'a failed read is MANUAL, with the reason' {
            $r = Get-HostsEntryDecision -ReadError 'Access to the path is denied.'
            $r.State | Should -Be 'Unreadable'
            $r.Status | Should -Be 'MANUAL'
            $r.Details | Should -Match 'denied'
        }
        It 'a read error wins over a missing-file flag' {
            (Get-HostsEntryDecision -FileExists $false -ReadError 'boom').State | Should -Be 'Unreadable'
        }
        It 'an empty file, or one with comments only, has no active entries (OK)' {
            foreach ($lines in @(@(), @('# hosts', '', '   # 127.0.0.1 localhost'))) {
                $r = Get-HostsEntryDecision -Lines $lines
                $r.State | Should -Be 'Empty'
                $r.Status | Should -Be 'OK'
                $r.Value | Should -Be 'No active entries'
            }
        }
        It 'with entries the summary stays MANUAL and counts them' {
            $r = Judge @('10.1.1.5 app.example.test', '127.0.0.1 localhost')
            $r.State | Should -Be 'Entries'
            $r.Status | Should -Be 'MANUAL'
            $r.Value | Should -Be 'ActiveEntries=2'
        }
    }

    Context 'lines' {
        It 'the line number counts comments and blank lines; the text is what the Post run compares' {
            $r = Judge @('# hosts file', '', '10.1.1.5   app.example.test    # owner: app team')
            $e = Get-Entry $r 3
            $e.Text | Should -Be '10.1.1.5 app.example.test'
            $e.Address | Should -Be '10.1.1.5'
            $e.Names | Should -Be @('app.example.test')
            $e.Status | Should -Be 'INFO'
            $e.Value | Should -Be 'Address=10.1.1.5'
            $e.Details | Should -Be 'Names=app.example.test'
        }
        It 'an ordinary application name inside the domain is only listed' {
            (Get-Entry (Judge @('10.1.1.5 legacy-app.corp.example.test')) 1).Status | Should -Be 'INFO'
        }
        It 'localhost on both loopback addresses is normal: not a duplicate, not a block' {
            $r = Judge @('127.0.0.1 localhost', '::1 localhost')
            @($r.Entries | Where-Object { $_.Status -ne 'INFO' }).Count | Should -Be 0
            @($r.Entries | Where-Object { $_.Reasons.Count -gt 0 }).Count | Should -Be 0
        }
    }

    Context 'names the run knows' {
        It 'the name of this server is a WARNING, bare or with the domain, in any case' -TestCases @(
            @{ Name = 'SRV01' }, @{ Name = 'srv01' }, @{ Name = 'SRV01.corp.example.test' }, @{ Name = 'Srv01.CORP.example.test' }
        ) {
            $e = Get-Entry (Judge @('10.1.1.5 ' + $Name)) 1
            $e.Status | Should -Be 'WARNING'
            $e.Value | Should -Match 'pins the name of this server'
            $e.Recommendation | Should -Not -BeNullOrEmpty
        }
        It 'the same name on loopback is still the name of this server, not a block' {
            $e = Get-Entry (Judge @('127.0.0.1 SRV01')) 1
            $e.Status | Should -Be 'WARNING'
            $e.Value | Should -Not -Match 'blocks'
        }
        It 'a name that only starts like this server is not it' {
            (Get-Entry (Judge @('10.1.1.5 SRV010', '10.1.1.6 SRV01-backup.corp.example.test')) 1).Status | Should -Be 'INFO'
            (Get-Entry (Judge @('10.1.1.5 SRV010', '10.1.1.6 SRV01-backup.corp.example.test')) 2).Status | Should -Be 'INFO'
        }
        It 'the domain name is a WARNING' {
            $e = Get-Entry (Judge @('10.1.1.5 Corp.Example.Test')) 1
            $e.Status | Should -Be 'WARNING'
            $e.Value | Should -Match 'pins the name of the domain'
        }
        It 'on a workgroup server (no domain name) only the computer name counts' {
            $r = Get-HostsEntryDecision -Lines @('10.1.1.5 SRV01', '10.1.1.6 SRV01.corp.example.test') -ComputerName 'SRV01' -DomainName ''
            (Get-Entry $r 1).Status | Should -Be 'WARNING'
            (Get-Entry $r 2).Status | Should -Be 'INFO'
        }
        It 'a domain controller is a WARNING by its full name, or by its short name' -TestCases @(
            @{ Name = 'dc01.corp.example.test' }, @{ Name = 'DC01' }
        ) {
            $e = Get-Entry (Judge @('10.1.1.9 ' + $Name) @('dc01.corp.example.test', 'dc02.corp.example.test')) 1
            $e.Status | Should -Be 'WARNING'
            $e.Value | Should -Match 'pins the name of a domain controller'
        }
        It 'a short name does not match a controller name in another domain' {
            (Get-Entry (Judge @('10.1.1.9 dc01.other.example.test') @('dc01.corp.example.test')) 1).Status | Should -Be 'INFO'
        }
        It 'without a list of domain controllers nothing is guessed' {
            (Get-Entry (Judge @('10.1.1.9 dc01.corp.example.test')) 1).Status | Should -Be 'INFO'
        }
    }

    Context 'block, duplicate and malformed lines' {
        It 'a name sent to loopback or 0.0.0.0 is INFO "blocks the name"' -TestCases @(
            @{ Line = '127.0.0.1 ads.example.test' }, @{ Line = '0.0.0.0 ads.example.test' }, @{ Line = '::1 ads.example.test' }, @{ Line = '127.0.0.2 ads.example.test' }
        ) {
            $e = Get-Entry (Judge @($Line)) 1
            $e.Status | Should -Be 'INFO'
            $e.Value | Should -Match 'blocks the name'
        }
        It 'the same name with another address is a WARNING on the later line, naming the first' {
            $r = Judge @('10.1.1.5 app.example.test', '10.1.1.6 APP.example.test')
            (Get-Entry $r 1).Status | Should -Be 'INFO'
            $e = Get-Entry $r 2
            $e.Status | Should -Be 'WARNING'
            $e.Value | Should -Match 'also on line 1'
        }
        It 'the same name and address twice is harmless' {
            $r = Judge @('10.1.1.5 app.example.test', '10.1.1.5 app.example.test')
            @($r.Entries | Where-Object { $_.Status -ne 'INFO' }).Count | Should -Be 0
        }
        It 'the same name for an IPv4 and an IPv6 address is not a duplicate' {
            $r = Judge @('10.1.1.5 app.example.test', '2001:db8::5 app.example.test')
            @($r.Entries | Where-Object { $_.Status -ne 'INFO' }).Count | Should -Be 0
        }
        It 'an address without a name is MANUAL, not skipped, and still listed for the Post run' {
            $r = Judge @('10.1.1.5')
            $e = Get-Entry $r 1
            $e.Status | Should -Be 'MANUAL'
            $e.Value | Should -Match 'no name'
            $e.Text | Should -Be '10.1.1.5'
        }
        It 'a first word that is not an address is MANUAL' -TestCases @(
            @{ Line = 'app.example.test 10.1.1.5' }, @{ Line = '1 app.example.test' }, @{ Line = '999.1.1.1 app.example.test' }
        ) {
            $e = Get-Entry (Judge @($Line)) 1
            $e.Status | Should -Be 'MANUAL'
            $e.Value | Should -Match 'not an IP address'
        }
    }

    Context 'text that reaches the report' {
        It 'no reason or recommendation repeats a name from the file (redaction has nothing new to catch)' {
            $names = @('uniqueone.example.test', 'SRV01', 'corp.example.test', 'dc01.corp.example.test', 'dupname.example.test')
            $r = Judge @('127.0.0.1 uniqueone.example.test', '10.1.1.5 SRV01', '10.1.1.6 corp.example.test', '10.1.1.7 dc01.corp.example.test', '10.1.1.8 dupname.example.test', '10.1.1.9 dupname.example.test') @('dc01.corp.example.test')
            $text = (@($r.Entries | ForEach-Object { $_.Value + ' ' + $_.Recommendation }) + $r.Recommendation) -join ' '
            foreach ($n in $names) { $text.IndexOf($n, [StringComparison]::OrdinalIgnoreCase) | Should -BeLessThan 0 -Because $n }
        }
        It 'the names stay in Details, where the existing redaction handles them' {
            $e = Get-Entry (Judge @('10.1.1.5 SRV01 srv01.corp.example.test')) 1
            $e.Details | Should -Be 'Names=SRV01,srv01.corp.example.test'
        }
    }
}

Describe 'Compare-IPUSnapshot - hosts entries that are new (#412)' {
    BeforeAll {
        function New-HostsSnapshot($Hosts) {
            [pscustomobject]@{ Services = @(); Ports = @(); Routes = @(); IPv4 = @(); Dns = @(); Hosts = $Hosts; Apps = @(); Features = @(); Tasks = @() }
        }
        function Get-HostsDiff($Before, $After) { $all = Compare-IPUSnapshot $Before $After; return ,@($all | Where-Object { $_.Item -like 'Hosts file entries*' }) }
    }
    It 'a new entry is INFO, next to the existing WARNING for a lost one' {
        $d = Get-HostsDiff (New-HostsSnapshot @('10.1.1.5 app.example.test')) (New-HostsSnapshot @('10.1.1.5 app.example.test', '10.1.1.6 other.example.test'))
        $d.Count | Should -Be 1
        $d[0].Item | Should -Be 'Hosts file entries new after upgrade'
        $d[0].Status | Should -Be 'INFO'
        $d[0].Value | Should -Be 'Count=1'
        $d[0].Details | Should -Be '10.1.1.6 other.example.test'
    }
    It 'a changed entry is one lost (WARNING) and one new (INFO)' {
        $d = Get-HostsDiff (New-HostsSnapshot @('10.1.1.5 app.example.test')) (New-HostsSnapshot @('10.1.1.99 app.example.test'))
        $d.Count | Should -Be 2
        @($d | Where-Object { $_.Item -like '*missing after upgrade' })[0].Status | Should -Be 'WARNING'
        @($d | Where-Object { $_.Item -like '*new after upgrade' })[0].Status | Should -Be 'INFO'
    }
    It 'the same entries give no difference' {
        (Get-HostsDiff (New-HostsSnapshot @('10.1.1.5 app.example.test')) (New-HostsSnapshot @('10.1.1.5 app.example.test'))).Count | Should -Be 0
    }
    It 'a Pre result without the hosts list reports nothing as new' {
        (Get-HostsDiff (New-HostsSnapshot $null) (New-HostsSnapshot @('10.1.1.6 other.example.test'))).Count | Should -Be 0
    }
    It 'a Pre result with an empty list reports every entry as new' {
        (Get-HostsDiff (New-HostsSnapshot @()) (New-HostsSnapshot @('10.1.1.6 other.example.test'))).Count | Should -Be 1
    }
}
