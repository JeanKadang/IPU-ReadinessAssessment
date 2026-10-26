# Pester 5 tests. Redaction of a live run (-RedactReport) and the redaction key.
# The script is loaded in library mode by ..\TestSetup.ps1: functions only, nothing is collected.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
param()

BeforeAll { . (Join-Path $PSScriptRoot '..\TestSetup.ps1') }

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

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
        @{ What = 'the certificate country code (#212)'; In = 'Subject=C=DK' }
    ) {
        Protect $In | Should -Be $In
    }
}

Describe 'Certificate subjects (#212)' {
    It 'replaces locality, state, street, postal code, e-mail and serial number; keeps the country' {
        $ctx = New-RedactionContext 'SRV01' 'corp.example.test'
        $out = Protect-ReportText 'Subject=CN=App Gateway, O=Example Org, L=Exampleton, S=Example Region, STREET=Main Street 1, PostalCode=2750, E=pki@example.org, SERIALNUMBER=12345678, C=DK' $ctx
        foreach ($w in 'App Gateway', 'Example Org', 'Exampleton', 'Example Region', 'Main Street 1', '2750', 'pki@example.org', '12345678') { $out | Should -Not -Match ([regex]::Escape($w)) }
        $out | Should -Match 'C=DK'
        $out | Should -Match 'L=NAME-\d+'
    }
}

Describe 'Redaction keeps version numbers (#194)' {
    BeforeEach { $script:VerCtx = New-RedactionContext 'SRV01' 'corp.example.test' }
    It 'keeps <What>' -TestCases @(
        @{ What = 'a version after "version"'; In = 'Example Agent version 5.8.3.123' }
        @{ What = 'a version after "Version="'; In = 'Version=5.8.3.123' }
        @{ What = 'a version folder in a path'; In = 'C:\Program Files\Example\datrep\4.0.2.39\scan.exe' }
        @{ What = 'a version with a build suffix (#213)'; In = 'Example OpenJDK with Hotspot 11.0.16.1+1 (x64)' }
    ) {
        Protect-ReportText $In $script:VerCtx | Should -Be $In
    }
    It 'still replaces <What>' -TestCases @(
        @{ What = 'a UNC host'; In = '\\10.1.2.3\share'; Out = '\\IP-1\share' }
        @{ What = 'an address after a product name'; In = 'Agent 10.1.2.3'; Out = 'Agent IP-1' }
        @{ What = 'an address at the end of a path'; In = 'route\10.1.2.3'; Out = 'route\IP-1' }
        @{ What = 'an address in a key=value pair'; In = 'Gateway=10.1.2.3'; Out = 'Gateway=IP-1' }
    ) {
        Protect-ReportText $In $script:VerCtx | Should -Be $Out
    }
    It 'keeps version fields in the JSON, and redacts addresses next to them' {
        $o = Protect-ReportObject ([pscustomobject]@{ Name = 'Example Agent'; Version = '5.8.3.123'; Note = 'Server 10.9.8.7'; Driver = [ordered]@{ DriverVersion = '1.2.3.4'; Address = '10.1.1.1' } }) $script:VerCtx
        $o.Version | Should -Be '5.8.3.123'
        $o.Driver.DriverVersion | Should -Be '1.2.3.4'
        $o.Note | Should -Be 'Server IP-1'
        $o.Driver.Address | Should -Be 'IP-2'
        # A field named Version that holds more than a version is still redacted.
        (Protect-ReportObject ([pscustomobject]@{ Version = 'from 10.1.2.3' }) $script:VerCtx).Version | Should -Be 'from IP-3'
    }
    It 'detection evidence names the version, so it stays readable' {
        $e = Get-DetectionEvidence ([pscustomobject]@{ Apps = @([pscustomobject]@{ Name = 'Example Agent'; Version = '5.8.3.123' }, [pscustomobject]@{ Name = 'No Version App'; Version = '' }); Services = @(); Drivers = @() })
        $e[0] | Should -Be 'Example Agent version 5.8.3.123'
        $e[1] | Should -Be 'No Version App'
        Protect-ReportText $e[0] $script:VerCtx | Should -Be $e[0]
    }
}

Describe 'Redaction: collected names in one pass (#243, SE-7)' {
    BeforeEach { $script:LitCtx = New-RedactionContext 'SRV01' 'corp.example.test' }
    It 'replaces every collected name with the placeholder of its kind, whatever the case' {
        $script:LitCtx.Literals['Print Queue East'] = 'NAME'
        $script:LitCtx.Literals['svc-backup'] = 'ACCOUNT'
        $out = Protect-ReportText 'Queue PRINT QUEUE EAST runs as svc-Backup; again print queue east.' $script:LitCtx
        $out | Should -Be 'Queue NAME-1 runs as ACCOUNT-1; again NAME-1.'
    }
    It 'the longest name wins over a shorter one it contains' {
        $script:LitCtx.Literals['Finance'] = 'NAME'
        $script:LitCtx.Literals['Finance Servers Policy'] = 'GPO'
        Protect-ReportText 'GPO: Finance Servers Policy and Finance' $script:LitCtx | Should -Be 'GPO: GPO-1 and NAME-1'
    }
    It 'a name inside a longer word or a dotted name is left alone' {
        $script:LitCtx.Literals['Backup'] = 'NAME'
        Protect-ReportText 'Backups and my-Backup.exe and Backup' $script:LitCtx | Should -Be 'Backups and my-Backup.exe and NAME-1'
    }
    It 'names added after the first text are used (the cache follows the names)' {
        $script:LitCtx.Literals['alpha-one'] = 'NAME'
        Protect-ReportText 'alpha-one' $script:LitCtx | Should -Be 'NAME-1'
        $script:LitCtx.Literals['beta-two'] = 'NAME'
        Protect-ReportText 'beta-two and alpha-one' $script:LitCtx | Should -Be 'NAME-2 and NAME-1'
    }
    It 'a name with regex characters is matched as text' {
        $script:LitCtx.Literals['Queue (HP) [2nd]'] = 'NAME'
        Protect-ReportText 'Using Queue (HP) [2nd] now' $script:LitCtx | Should -Be 'Using NAME-1 now'
    }
    It 'no names, no pattern' {
        Get-RedactionLiteralRegex $script:LitCtx | Should -BeNullOrEmpty
        Protect-ReportText 'plain text' $script:LitCtx | Should -Be 'plain text'
    }
    It 'the pattern is built once and reused while the names stay the same' {
        $script:LitCtx.Literals['one-name'] = 'NAME'
        $a = Get-RedactionLiteralRegex $script:LitCtx
        [object]::ReferenceEquals($a, (Get-RedactionLiteralRegex $script:LitCtx)) | Should -BeTrue
        $script:LitCtx.Literals['two-name'] = 'NAME'
        [object]::ReferenceEquals($a, (Get-RedactionLiteralRegex $script:LitCtx)) | Should -BeFalse
    }
    It '500 names and 100 texts take seconds, not minutes (was 173 ms per text)' {
        foreach ($i in 1..500) { $script:LitCtx.Literals[('Queue-' + $i.ToString('000') + '-Name')] = 'NAME' }
        $texts = @(1..100 | ForEach-Object { 'Printer on Queue-' + ($_ * 3).ToString('000') + '-Name uses port 9100 and driver Example Driver ' + $_ })
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $out = @($texts | ForEach-Object { Protect-ReportText $_ $script:LitCtx })
        $watch.Stop()
        $out[0] | Should -Match 'NAME-\d+'
        $out[0] | Should -Not -Match 'Queue-003-Name'
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 5
    }
}

Describe 'Redaction: four-part versions in free text (#243, SE-43)' {
    BeforeEach { $script:V4Ctx = New-RedactionContext 'SRV01' 'corp.example.test' }
    It 'keeps <What>' -TestCases @(
        @{ What = 'a version after the word build'; In = 'Example Agent build 5.8.3.123 installed' }
        @{ What = 'a version after Release'; In = 'Example Suite Release 12.4.7.9' }
        @{ What = 'a version after "ver."'; In = 'Example Tool ver. 2.1.0.45' }
        @{ What = 'a version after "update"'; In = 'Example Runtime update: 8.0.3910.11' }
        @{ What = 'a version followed by (x64)'; In = 'Example Agent 5.8.3.123 (x64) is running' }
        @{ What = 'a version followed by x86'; In = 'Example Agent 5.8.3.123 x86' }
        @{ What = 'a number that starts with 0'; In = 'Example Library 0.9.8.1 loaded' }
    ) {
        Protect-ReportText $In $script:V4Ctx | Should -Be $In
    }
    It 'still replaces <What>' -TestCases @(
        @{ What = 'an address after a product name'; In = 'Agent 10.1.2.3 is up'; Out = 'Agent IP-1 is up' }
        @{ What = 'an address in brackets'; In = 'Server [10.1.2.3] answers'; Out = 'Server [IP-1] answers' }
        @{ What = 'an address followed by a port'; In = 'Listening on 192.168.1.20:443'; Out = 'Listening on IP-1:443' }
        @{ What = 'an address followed by a word in brackets'; In = 'DNS 10.20.1.10 (primary)'; Out = 'DNS IP-1 (primary)' }
        @{ What = 'an address that follows the word versions elsewhere'; In = 'Agent version 5.8.3.123 talks to 10.9.9.9'; Out = 'Agent version 5.8.3.123 talks to IP-1' }
    ) {
        Protect-ReportText $In $script:V4Ctx | Should -Be $Out
    }
    It 'Test-FourPartVersionContext: version words, architecture and a leading 0' {
        Test-FourPartVersionContext 'Agent build ' '' '5' | Should -BeTrue
        Test-FourPartVersionContext 'x ' ' (x64) y' '5' | Should -BeTrue
        Test-FourPartVersionContext 'x ' ' x86' '5' | Should -BeTrue
        Test-FourPartVersionContext 'x ' ' y' '0' | Should -BeTrue
        Test-FourPartVersionContext 'Agent ' ' is up' '10' | Should -BeFalse
        Test-FourPartVersionContext 'rebuild ' '' '5' | Should -BeFalse
    }
}

Describe 'Redaction key (#211)' {
    It 'records each placeholder with its kind and first-seen original' {
        $ctx = New-RedactionContext 'SRV-KEY01' 'corp.example.test'
        $null = Get-RedactionPlaceholder $ctx 'HOST' 'SRV-Key01'
        $null = Get-RedactionPlaceholder $ctx 'HOST' 'srv-key01'
        $null = Get-RedactionPlaceholder $ctx 'IP' '10.1.2.3'
        $null = Get-RedactionPlaceholder $ctx 'HOST' 'web01.corp.example.test'
        $lines = ConvertTo-RedactionKeyLine $ctx.Originals
        ($lines -join '|') | Should -Be 'Placeholder;Kind;Original|HOST-1;HOST;SRV-Key01|HOST-2;HOST;web01.corp.example.test|IP-1;IP;10.1.2.3'
    }
    It 'sorts numerically and neutralises formulas, separators and quotes' {
        $o = [ordered]@{}
        foreach ($i in 1..11) { $o['NAME-' + $i] = [pscustomobject]@{ Placeholder = 'NAME-' + $i; Kind = 'NAME'; Original = ('n' + $i) } }
        $o['NAME-2'].Original = '=HYPERLINK("x")'
        $o['NAME-3'].Original = 'a;b'
        $lines = ConvertTo-RedactionKeyLine $o
        $lines[2] | Should -Be 'NAME-2;NAME;"''=HYPERLINK(""x"")"'
        $lines[3] | Should -Be 'NAME-3;NAME;"a;b"'
        $lines[11] | Should -Match '^NAME-11;'
    }
    It 'Write-RedactionKey writes a BOM UTF-8 CSV that keeps non-ASCII names' {
        $ctx = New-RedactionContext 'SRV01' ''
        $null = Get-RedactionPlaceholder $ctx 'NAME' ('S' + [char]0x00F8 + 'borg')
        $path = Join-Path $TestDrive 'key.csv'
        Write-RedactionKey $ctx $path | Should -Be $path
        $bytes = [IO.File]::ReadAllBytes($path)
        ($bytes[0..2] -join ',') | Should -Be '239,187,191'
        [IO.File]::ReadAllText($path) | Should -Match ('NAME-1;NAME;S' + [char]0x00F8 + 'borg')
    }
    It 'the key file is readable by SYSTEM, Administrators and the current user only (Windows)' -Skip:($env:OS -ne 'Windows_NT') {
        $path = Join-Path $TestDrive 'key-acl.csv'
        $null = Write-RedactionKey (New-RedactionContext 'SRV01' '') $path
        $acl = Get-Acl -LiteralPath $path
        $acl.AreAccessRulesProtected | Should -BeTrue
        $sids = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object { [string]$_.IdentityReference })
        @($sids | Where-Object { @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545') -contains $_ }) | Should -BeNullOrEmpty
    }
    Context '-RedactExisting' {
        BeforeAll {
            $script:KeyDir = Join-Path $TestDrive 'key-existing'
            New-Item -ItemType Directory -Path $script:KeyDir | Out-Null
            $sample = Join-Path $PSScriptRoot '..\..\docs\samples'
            Copy-Item -LiteralPath (Join-Path $sample 'sample-result.json') -Destination (Join-Path $script:KeyDir 'SRV-APP01-IPU-Assessment.json')
            Copy-Item -LiteralPath (Join-Path $sample 'sample-report.html') -Destination (Join-Path $script:KeyDir 'SRV-APP01-IPU-Assessment.html')
            $WriteRedactionKey = $true
            $script:KeyCode = Invoke-RedactExisting $script:KeyDir
            $script:KeyFiles = @(Get-ChildItem -LiteralPath $script:KeyDir -Filter 'DO-NOT-SHARE-REDACTION-KEY-*.csv')
        }
        It 'writes one key file next to the copies' {
            $script:KeyCode | Should -Be 0
            $script:KeyFiles.Count | Should -Be 1
        }
        It 'maps the server and every placeholder used in the copies' {
            $key = [IO.File]::ReadAllText($script:KeyFiles[0].FullName)
            $key | Should -Match 'HOST-1;HOST;SRV-APP01'
            $copies = (@(Get-ChildItem -LiteralPath $script:KeyDir -Filter 'REDACTED-*') | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join ' '
            $used = @([regex]::Matches($copies, '\b(HOST|IP|NAME|ACCOUNT|DOMAIN|GPO|SID|MAC|CERT)-\d+\b') | ForEach-Object { $_.Value } | Sort-Object -Unique)
            $used.Count | Should -BeGreaterThan 3
            foreach ($p in $used) { $key | Should -Match ('(?m)^' + [regex]::Escape($p) + ';') }
        }
        It 'is not written with -WriteRedactionKey $false' {
            $dir = Join-Path $TestDrive 'key-off'
            New-Item -ItemType Directory -Path $dir | Out-Null
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\..\docs\samples\sample-result.json') -Destination (Join-Path $dir 'SRV-APP01-IPU-Assessment.json')
            $WriteRedactionKey = $false
            Invoke-RedactExisting $dir | Should -Be 0
            @(Get-ChildItem -LiteralPath $dir -Filter 'DO-NOT-SHARE-*').Count | Should -Be 0
        }
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

Describe 'Redaction covers every collected kind (#124)' {
    # A synthetic worst case: every kind of name and address the collector
    # reports, with random values (a new seed per run, shown on failure), run
    # through the live JSON path, the live HTML path and -RedactExisting.
    # The test fails when any input value survives in any of them.
    BeforeAll {
        $script:RedSeed = Get-Random -Maximum 2147483647
        $rng = New-Object System.Random $script:RedSeed
        function New-Word([int]$Length = 8) { -join (1..$Length | ForEach-Object { [char](97 + $rng.Next(26)) }) }
        function New-Octet { 1 + $rng.Next(253) }
        function New-Hex([int]$Length) { -join (1..$Length | ForEach-Object { '0123456789abcdef'[$rng.Next(16)] }) }
        $label = New-Word 7
        $nb = $label.ToUpperInvariant()
        $fqdn = $label + '.corp.test'
        $computer = 'SRV' + (New-Word 6).ToUpperInvariant()
        $v = [ordered]@{
            Computer = $computer; Domain = $fqdn; NetBios = $nb
            TaskAccount = 'adm-' + (New-Word); ServiceDomainAccount = 'svc_' + (New-Word); ServiceLocalAccount = 'loc' + (New-Word)
            WordAccount = 'Installer'                                  # the #114 shape: an account that is an ordinary word
            UpnUser = 'u' + (New-Word); Gpo = 'GPO ' + (New-Word) + ' Baseline'; WmiFilter = 'Filter ' + (New-Word)
            Share = 'Share' + (New-Word); ShareDescription = 'Team ' + (New-Word) + ' data'
            Cluster = 'CL' + (New-Word 5).ToUpperInvariant(); Node = 'ND' + (New-Word 5).ToUpperInvariant()
            KmsHost = 'kms' + (New-Word 5); Ou = 'OU' + (New-Word); Org = 'Org ' + (New-Word)
            HostCom = (New-Word) + '.com'; HostDk = (New-Word) + '.dk'; HostLocal = (New-Word) + '.local'; HostInternal = (New-Word) + '.internal'; HostInDomain = (New-Word) + '.' + $fqdn
            IPv4 = '10.' + (New-Octet) + '.' + (New-Octet) + '.' + (New-Octet); IPv4Gateway = '172.16.' + (New-Octet) + '.' + (New-Octet)
            IPv6 = '2001:db8:' + (New-Hex 4) + '::' + (New-Hex 3); LinkLocal = 'fe80::' + (New-Hex 4) + ':' + (New-Hex 4)
            Mac = ((1..6 | ForEach-Object { New-Hex 2 }) -join '-').ToUpperInvariant()
            Sid = 'S-1-5-21-' + $rng.Next(100000, 999999) + '-' + $rng.Next(100000, 999999) + '-' + $rng.Next(100000, 999999) + '-1105'
            Thumbprint = (New-Hex 40).ToUpperInvariant()
            SqlInstance = 'SQ' + (New-Word 6).ToUpperInvariant()
            City = 'City' + (New-Word); Region = 'Region' + (New-Word)
            Printer = 'PR-' + (New-Word); PrinterShare = 'PS' + (New-Word); PrinterPort = 'port_' + (New-Word); PrinterHost = 'prn' + (New-Word 5) + '.' + $fqdn
        }
        $script:RedValues = $v
        $script:RedSavedComputer = $script:ComputerName
        $script:ComputerName = $computer
        $script:Data = @{}
        # What the collector registers while it runs (the Add-RedactionLiteral call sites).
        Add-RedactionLiteral ($nb + '\' + $v.TaskAccount) 'ACCOUNT'
        Add-RedactionLiteral ($nb + '\' + $v.ServiceDomainAccount) 'ACCOUNT'
        Add-RedactionLiteral ('.\' + $v.ServiceLocalAccount) 'ACCOUNT'
        Add-RedactionLiteral ($nb + '\' + $v.WordAccount) 'ACCOUNT'
        Add-RedactionLiteral $v.Gpo 'GPO'; Add-RedactionLiteral $v.WmiFilter 'NAME'
        Add-RedactionLiteral $v.Share 'NAME'; Add-RedactionLiteral $v.ShareDescription 'NAME'
        Add-RedactionLiteral $v.Cluster 'HOST'; Add-RedactionLiteral $v.Node 'HOST'
        Add-RedactionLiteral ($v.KmsHost + '.' + $fqdn) 'HOST'; Add-RedactionLiteral $v.KmsHost 'HOST'
        Add-RedactionLiteral $v.SqlInstance 'NAME'; Add-RedactionLiteral ('MSSQL16.' + $v.SqlInstance) 'NAME'
        Add-RedactionLiteral $v.Printer 'NAME'; Add-RedactionLiteral $v.PrinterShare 'NAME'; Add-RedactionLiteral $v.PrinterPort 'NAME'; Add-RedactionLiteral $v.PrinterHost 'HOST'
        $script:Results.Clear(); $script:CheckRuns.Clear()
        Add-Result 'ACCESS' 'DomainMembership' 'INFO' ('Domain=' + $fqdn) ('NetBIOS=' + $nb)
        Add-Result 'ACCESS' 'ComputerObjectOu' 'INFO' ('CN=' + $computer + ',OU=' + $v.Ou + ',OU=Servers,DC=' + $label + ',DC=corp,DC=test')
        Add-Result 'TASKS' '\Ops\Export' 'INFO' ('RunAs=' + $nb + '\' + $v.TaskAccount)
        Add-Result 'SERVICES' 'AppSvc' 'INFO' 'AppSvc' ('State=Running | StartMode=Auto | LogOnAs=' + $nb + '\' + $v.ServiceDomainAccount)
        Add-Result 'SERVICES' 'LocalSvc' 'INFO' 'LocalSvc' ('State=Running | StartMode=Auto | LogOnAs=.\' + $v.ServiceLocalAccount)
        Add-Result 'SERVICES' 'Setup helper' 'INFO' 'Setup helper' ('State=Running | StartMode=Auto | LogOnAs=' + $nb + '\' + $v.WordAccount)
        Add-Result 'SERVICES' 'UpnSvc' 'INFO' 'UpnSvc' ('State=Running | StartMode=Auto | LogOnAs=' + $v.UpnUser + '@' + $fqdn)
        Add-Result 'GROUP_POLICY' ('GPO: ' + $v.Gpo) 'WARNING' 'Applied' @(('WMI filter: ' + $v.WmiFilter), ('Linked at ' + $fqdn + '/Servers/' + $v.Ou))
        Add-Result 'GROUP_POLICY' 'ADGroup' 'INFO' ($nb + '\Patch Ring 2') ('SID=' + $v.Sid)
        Add-Result 'FILE_SHARES' ('Share: ' + $v.Share) 'INFO' ('D:\' + $v.Share) @(('Path=D:\' + $v.Share), ('Description=' + $v.ShareDescription), ('Share permissions: ' + $nb + '\' + $v.TaskAccount + ': Full'))
        Add-Result 'CLUSTER' 'ClusterMembership' 'INFO' ('Cluster=' + $v.Cluster)
        Add-Result 'CLUSTER' ('Node: ' + $v.Node) 'INFO' 'State=Up'
        Add-Result 'LICENSING' 'WindowsActivation' 'OK' 'Licensed (KMS)' ('KMS host: ' + $v.KmsHost + '.' + $fqdn + ':1688 (found via DNS)')
        Add-Result 'NETWORK' 'Ethernet0' 'INFO' ('IPv4=' + $v.IPv4 + ' / 255.255.255.0') @(('Gateway=' + $v.IPv4Gateway), ('DNS=' + $v.IPv4Gateway), ('MAC=' + $v.Mac), ('IPv6=' + $v.IPv6 + ',' + $v.LinkLocal), ('DNS suffix=' + $fqdn))
        Add-Result 'PKI' 'Certificate' 'INFO' ('CN=' + $v.HostInDomain + ', O=' + $v.Org + ', L=' + $v.City + ', S=' + $v.Region + ', C=DK') ('Thumbprint=' + $v.Thumbprint)
        Add-Result 'SQL' ('Database Engine: ' + $v.SqlInstance) 'OK' 'SQL Server 2022' @('Version=16.0.1000.6', 'Edition=Standard Edition', ('InstanceId=MSSQL16.' + $v.SqlInstance))
        Add-Result 'SERVICES' ('MSSQL$' + $v.SqlInstance) 'INFO' ('SQL Server (' + $v.SqlInstance + ')') 'State=Running | StartMode=Auto | LogOnAs=NT Service\MSSQLSERVER'
        Add-Result 'PRINTING' ('Printer: ' + $v.Printer) 'INFO' ('Driver=Example PCL6; Port=' + $v.PrinterPort) @(('Share=' + $v.PrinterShare), 'Published in AD=True')
        Add-Result 'PRINTING' ('Port: ' + $v.PrinterPort) 'WARNING' 'LPR port monitor' @(('Address=' + $v.PrinterHost), 'Queue=labels')
        Add-Result 'NETWORK_DEPENDENCY' 'Hosts line 1' 'INFO' ('Address=' + $v.IPv4) ('Names=' + $v.HostCom + ',' + $v.HostDk + ',' + $v.HostLocal + ',' + $v.HostInternal)
        $script:CheckRuns.Add([pscustomobject]@{ Id = 'baseline'; Name = 'Baseline inventory'; Phase = 'Fast'; Outcome = 'Completed'; Duration = '00:00:01'; Seconds = 1; Message = '' })
        $script:RedRows = $script:Results.ToArray()
        $script:RedObject = [ordered]@{
            Schema = 'IPU-Assessment/1'; ComputerName = $computer; Mode = 'Pre'; Overall = 'WARNING'
            Facts = [ordered]@{ SqlServer = ($v.SqlInstance + '=SQL Server 2022'); DomainRole = 'Member server'; ComputerObjectOu = ('OU=' + $v.Ou + ',DC=' + $label + ',DC=corp,DC=test'); KmsHost = $v.KmsHost }
            Results = $script:RedRows; CheckRuns = $script:CheckRuns.ToArray()
            Snapshot = [ordered]@{ IPv4 = @($v.IPv4); Dns = @($v.IPv4Gateway); Shares = @($v.Share); Gpos = @($v.Gpo); Groups = @($nb + '\Patch Ring 2'); Ou = ('OU=' + $v.Ou + ',DC=' + $label + ',DC=corp,DC=test')
                Adapters = @([pscustomobject]@{ Name = 'Ethernet0'; Mac = $v.Mac; IPv4 = @($v.IPv4); IPv6 = @($v.IPv6); Gateway = @($v.IPv4Gateway); Dns = @($v.IPv4Gateway); Suffix = $fqdn }) }
        }
        $script:RedHtml = New-IPUReportHtml -Results $script:RedRows -CheckRuns $script:CheckRuns.ToArray() -OverallStatus 'WARNING' -CompletedTime (Get-Date)
        function Get-Survivor([string]$Text) {
            @($script:RedValues.Keys | Where-Object { $Text.IndexOf([string]$script:RedValues[$_], [StringComparison]::OrdinalIgnoreCase) -ge 0 } | ForEach-Object { $_ + '=' + $script:RedValues[$_] })
        }
    }
    AfterAll { $script:ComputerName = $script:RedSavedComputer; $script:Data = @{} }

    It 'the input really contains every value (the test is not empty)' {
        $plain = ($script:RedObject | ConvertTo-Json -Depth 8) + $script:RedHtml
        @($script:RedValues.Keys | Where-Object { $plain.IndexOf([string]$script:RedValues[$_], [StringComparison]::OrdinalIgnoreCase) -lt 0 }) | Should -BeNullOrEmpty
    }
    It 'live run, JSON: no input value survives' {
        $ctx = New-RedactionContext $script:RedValues.Computer $script:RedValues.Domain
        foreach ($k in @($script:Data.RedactLiterals.Keys)) { $ctx.Literals[$k] = $script:Data.RedactLiterals[$k] }
        $json = (Protect-ReportObject $script:RedObject $ctx) | ConvertTo-Json -Depth 8
        Get-Survivor $json | Should -BeNullOrEmpty -Because ('seed ' + $script:RedSeed)
    }
    It 'live run, HTML: no input value survives' {
        $ctx = New-RedactionContext $script:RedValues.Computer $script:RedValues.Domain
        foreach ($k in @($script:Data.RedactLiterals.Keys)) { $ctx.Literals[$k] = $script:Data.RedactLiterals[$k] }
        Get-Survivor (Protect-ReportText $script:RedHtml $ctx) | Should -BeNullOrEmpty -Because ('seed ' + $script:RedSeed)
    }
    It '-RedactExisting, JSON and HTML: no input value survives (names recovered from the rows)' {
        $dir = Join-Path $TestDrive 'worst-case'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $base = Join-Path $dir ($script:RedValues.Computer + '-IPU-Assessment')
        [IO.File]::WriteAllText($base + '.json', ($script:RedObject | ConvertTo-Json -Depth 8))
        [IO.File]::WriteAllText($base + '.html', $script:RedHtml)
        Invoke-RedactExisting $dir | Should -Be 0
        $out = @(Get-ChildItem -LiteralPath $dir -Filter 'REDACTED-*')
        $out.Count | Should -Be 2
        foreach ($f in $out) {
            Get-Survivor ([IO.File]::ReadAllText($f.FullName)) | Should -BeNullOrEmpty -Because ($f.Extension + ', seed ' + $script:RedSeed)
            $f.Name | Should -Not -Match ([regex]::Escape($script:RedValues.Computer))
        }
    }
    It 'fails when a value is left in (the check itself works)' {
        Get-Survivor ('text with ' + $script:RedValues.Share + ' inside') | Should -Be @('Share=' + $script:RedValues.Share)
    }
}
