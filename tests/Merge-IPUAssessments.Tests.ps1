# Pester 5 tests for src/Merge-IPUAssessments.ps1 (fleet overview).
# Synthetic results only - no real host data.

BeforeAll {
    $script:MergeScript = Join-Path $PSScriptRoot '..\src\Merge-IPUAssessments.ps1'

    function New-FakeResult {
        param([string]$Computer, [string]$Mode = 'Pre', [string]$Overall = 'OK', [string]$Completed = '2026-10-06 10:00:00',
              [object[]]$Results = @(), [string]$Schema = 'IPU-Assessment/1')
        $counts = [ordered]@{}
        foreach ($s in 'BLOCKER','ACTION','WARNING','MANUAL') { $counts[$s] = @($Results | Where-Object { $_.Kind -eq 'Finding' -and $_.Status -eq $s }).Count }
        [pscustomobject][ordered]@{
            Schema = $Schema; CollectorVersion = '4.0.1'; ComputerName = $Computer; Mode = $Mode; TargetServerVersion = '2025'
            Started = $Completed; Completed = $Completed; Partial = $false; Overall = $Overall; Counts = [pscustomobject]$counts
            Facts = [pscustomobject]@{ CurrentOS = 'Windows Server 2016 Standard'; UpgradePath = 'Supported'; RecommendedMedia = 'Windows Server 2025 Standard'; Platform = 'Virtual (VMware)'; DomainRole = 'Member server'; SqlServer = ''; Activation = 'Licensed'; CDrive = 'free 50 GB'; CompatScan = '' }
            Results = @($Results); CheckRuns = @([pscustomobject]@{ Id = 'baseline'; Name = 'Baseline inventory'; Phase = 'Fast'; Outcome = 'Completed'; Duration = '00:00:01'; Message = '' })
            Snapshot = [pscustomobject]@{}
        }
    }
    function Set-FakeOffset($Result, [string]$UtcOffset) { if ($UtcOffset) { $Result | Add-Member -NotePropertyName UtcOffset -NotePropertyValue $UtcOffset }; return $Result }
    function New-FakeFinding([string]$Status, [string]$Item, [string]$Kind = 'Finding') {
        [pscustomobject]@{ CheckId = 'x'; Area = 'STORAGE'; Item = $Item; Status = $Status; Kind = $Kind; Value = 'v'; Details = 'd'; Recommendation = 'r'; Source = 's' }
    }
    function Save-Result($Object, [string]$Folder, [string]$Name) {
        $Object | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Folder $Name) -Encoding UTF8
    }
}

Describe 'Merge-IPUAssessments.ps1' {
    BeforeAll {
        $script:In = Join-Path $TestDrive 'in'
        $script:Out = Join-Path $TestDrive 'out'
        New-Item -ItemType Directory -Path $script:In, $script:Out | Out-Null

        Save-Result (New-FakeResult 'SRV-BLOCK' -Overall 'BLOCKER' -Results @((New-FakeFinding 'BLOCKER' 'Exchange Server'), (New-FakeFinding 'ACTION' 'C: free space'))) $script:In 'SRV-BLOCK-IPU-Assessment.json'
        Save-Result (New-FakeResult 'SRV-WARN' -Overall 'WARNING' -Results @((New-FakeFinding 'WARNING' 'Uptime'), (New-FakeFinding 'WARNING' 'Ignored observation' 'Observation'))) $script:In 'SRV-WARN-IPU-Assessment.json'
        Save-Result (New-FakeResult 'SRV-OK' -Overall 'OK') $script:In 'SRV-OK-IPU-Assessment.json'
        # An older result for the same server and mode: must be ignored.
        $older = New-FakeResult 'SRV-OK' -Overall 'ACTION' -Completed '2026-01-01 08:00:00' -Results @((New-FakeFinding 'ACTION' 'Old finding'))
        Save-Result $older $script:In 'old-copy-SRV-OK-IPU-Assessment.json'
        Save-Result (New-FakeResult 'SRV-BLOCK' -Mode 'Post' -Overall 'ACTION' -Results @((New-FakeFinding 'ACTION' 'Static routes missing after upgrade'))) $script:In 'SRV-BLOCK-IPU-PostUpgrade.json'
        Save-Result (New-FakeResult 'SRV-ODD' -Schema 'Something-Else/9') $script:In 'SRV-ODD-IPU-Assessment.json'
        Set-Content -LiteralPath (Join-Path $script:In 'SRV-BROKEN-IPU-Assessment.json') -Value '{ not json'
        Set-Content -LiteralPath (Join-Path $script:In 'unrelated.json') -Value '{}'

        $script:Output = & $script:MergeScript -InputFolder $script:In -OutputFolder $script:Out
        $script:Servers = @(Import-Csv -LiteralPath (Join-Path $script:Out 'IPU-Fleet-Servers.csv') -Delimiter ';')
        $script:Findings = @(Import-Csv -LiteralPath (Join-Path $script:Out 'IPU-Fleet-Findings.csv') -Delimiter ';')
        $script:Html = Get-Content -LiteralPath (Join-Path $script:Out 'IPU-Fleet-Overview.html') -Raw
    }

    It 'writes the HTML overview and both CSV files' {
        Join-Path $script:Out 'IPU-Fleet-Overview.html' | Should -Exist
        Join-Path $script:Out 'IPU-Fleet-Servers.csv' | Should -Exist
        Join-Path $script:Out 'IPU-Fleet-Findings.csv' | Should -Exist
    }
    It 'keeps one row per server and mode, the newest result' {
        $script:Servers.Count | Should -Be 4
        $ok = @($script:Servers | Where-Object { $_.ComputerName -eq 'SRV-OK' })
        $ok.Count | Should -Be 1
        $ok[0].Overall | Should -Be 'OK'
    }
    It 'sorts servers worst first' {
        $script:Servers[0].Overall | Should -Be 'BLOCKER'
        $script:Servers[-1].Overall | Should -Be 'OK'
    }
    It 'lists BLOCKER and ACTION items as top issues' {
        ($script:Servers | Where-Object { $_.ComputerName -eq 'SRV-BLOCK' -and $_.Mode -eq 'Pre' }).TopIssues | Should -Be 'BLOCKER: Exchange Server | ACTION: C: free space'
    }
    It 'exports findings only, not observations, and not from superseded results' {
        @($script:Findings | ForEach-Object Item) | Should -Contain 'Uptime'
        @($script:Findings | ForEach-Object Item) | Should -Not -Contain 'Ignored observation'
        @($script:Findings | ForEach-Object Item) | Should -Not -Contain 'Old finding'
    }
    It 'reports unreadable and unknown-schema files instead of failing' {
        $script:Html | Should -Match 'Files not read'
        $script:Html | Should -Match 'SRV-BROKEN-IPU-Assessment.json'
        $script:Html | Should -Match 'unknown schema'
        $script:Output[0] | Should -Match 'Unreadable files: 2'
    }
    It 'ignores JSON files that are not assessment results' {
        $script:Html | Should -Not -Match 'unrelated.json'
    }
    It 'filters by mode' {
        $preOut = Join-Path $TestDrive 'pre'
        $null = & $script:MergeScript -InputFolder $script:In -OutputFolder $preOut -Mode Pre
        $rows = @(Import-Csv -LiteralPath (Join-Path $preOut 'IPU-Fleet-Servers.csv') -Delimiter ';')
        @($rows | Where-Object { $_.Mode -eq 'Post' }).Count | Should -Be 0
        $rows.Count | Should -Be 3
    }
    It 'HTML-encodes server data' {
        $evil = Join-Path $TestDrive 'evil'
        New-Item -ItemType Directory -Path $evil | Out-Null
        Save-Result (New-FakeResult '<script>x</script>') $evil 'EVIL-IPU-Assessment.json'
        $null = & $script:MergeScript -InputFolder $evil
        $page = Get-Content -LiteralPath (Join-Path $evil 'IPU-Fleet-Overview.html') -Raw
        $page | Should -Not -Match '<script>x'
        $page | Should -Match '&lt;script&gt;x'
    }
    It 'fails clearly when the folder has no results' {
        $empty = Join-Path $TestDrive 'empty'
        New-Item -ItemType Directory -Path $empty | Out-Null
        { & $script:MergeScript -InputFolder $empty } | Should -Throw -ExpectedMessage '*No *-IPU-Assessment.json*'
    }
}

Describe 'Merge-IPUAssessments.ps1 - modes, order, delimiter and safety (#41)' {
    BeforeAll {
        $script:In2 = Join-Path $TestDrive 'in2'
        New-Item -ItemType Directory -Path $script:In2 | Out-Null
        $order = @(
            @{ Name = 'SRV-E-OK';      Overall = 'OK' },
            @{ Name = 'SRV-D-MANUAL';  Overall = 'MANUAL' },
            @{ Name = 'SRV-C-WARNING'; Overall = 'WARNING' },
            @{ Name = 'SRV-B-ACTION';  Overall = 'ACTION' },
            @{ Name = 'SRV-A-BLOCKER'; Overall = 'BLOCKER' }
        )
        foreach ($o in $order) { Save-Result (New-FakeResult $o.Name -Overall $o.Overall) $script:In2 ($o.Name + '-IPU-Assessment.json') }
        Save-Result (New-FakeResult 'SRV-POST' -Mode 'Post' -Overall 'WARNING') $script:In2 'SRV-POST-IPU-PostUpgrade.json'
        $mixed = @((New-FakeFinding 'MANUAL' 'Manual item'), (New-FakeFinding 'OK' 'Clean item'), (New-FakeFinding 'INFO' 'Info item'))
        Save-Result (New-FakeResult 'SRV-MIXED' -Overall 'MANUAL' -Results $mixed) $script:In2 'SRV-MIXED-IPU-Assessment.json'
        function Invoke-Merge([string]$Mode = 'All', [string]$Delimiter = ';') {
            $out = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $null = & $script:MergeScript -InputFolder $script:In2 -OutputFolder $out -Mode $Mode -Delimiter $Delimiter
            return $out
        }
    }

    It '-Mode <Mode> includes <Expected> servers' -TestCases @(
        @{ Mode = 'Pre';  Expected = 6 }
        @{ Mode = 'Post'; Expected = 1 }
        @{ Mode = 'All';  Expected = 7 }
    ) {
        $out = Invoke-Merge -Mode $Mode
        $rows = @(Import-Csv -LiteralPath (Join-Path $out 'IPU-Fleet-Servers.csv') -Delimiter ';')
        $rows.Count | Should -Be $Expected
        if ($Mode -eq 'Post') { $rows[0].ComputerName | Should -Be 'SRV-POST' }
        if ($Mode -eq 'Pre') { @($rows | Where-Object { $_.Mode -ne 'Pre' }).Count | Should -Be 0 }
    }
    It 'sorts BLOCKER, ACTION, WARNING, MANUAL, OK' {
        $out = Invoke-Merge -Mode Pre
        $rows = @(Import-Csv -LiteralPath (Join-Path $out 'IPU-Fleet-Servers.csv') -Delimiter ';')
        $statuses = @($rows | ForEach-Object Overall | Select-Object -Unique)
        ($statuses -join ',') | Should -Be 'BLOCKER,ACTION,WARNING,MANUAL,OK'
        $html = Get-Content -LiteralPath (Join-Path $out 'IPU-Fleet-Overview.html') -Raw
        $html.IndexOf('SRV-A-BLOCKER') | Should -BeLessThan $html.IndexOf('SRV-B-ACTION')
        $html.IndexOf('SRV-B-ACTION') | Should -BeLessThan $html.IndexOf('SRV-C-WARNING')
        $html.IndexOf('SRV-D-MANUAL') | Should -BeLessThan $html.IndexOf('SRV-E-OK')
    }
    It 'writes both CSV files with ";" by default and honours -Delimiter ","' {
        $semi = Invoke-Merge
        foreach ($f in 'IPU-Fleet-Servers.csv', 'IPU-Fleet-Findings.csv') {
            (Get-Content -LiteralPath (Join-Path $semi $f) -TotalCount 1) | Should -Match '^"ComputerName";"Mode";'
        }
        $comma = Invoke-Merge -Delimiter ','
        foreach ($f in 'IPU-Fleet-Servers.csv', 'IPU-Fleet-Findings.csv') {
            (Get-Content -LiteralPath (Join-Path $comma $f) -TotalCount 1) | Should -Match '^"ComputerName","Mode",'
        }
        @(Import-Csv -LiteralPath (Join-Path $comma 'IPU-Fleet-Servers.csv') -Delimiter ',').Count | Should -Be 7
    }
    It 'exports only BLOCKER, ACTION, WARNING and MANUAL findings' {
        $out = Invoke-Merge
        $rows = @(Import-Csv -LiteralPath (Join-Path $out 'IPU-Fleet-Findings.csv') -Delimiter ';')
        @($rows | ForEach-Object Item) | Should -Contain 'Manual item'
        @($rows | ForEach-Object Item) | Should -Not -Contain 'Clean item'
        @($rows | ForEach-Object Item) | Should -Not -Contain 'Info item'
        @($rows | Where-Object { $_.Status -notin @('BLOCKER', 'ACTION', 'WARNING', 'MANUAL') }).Count | Should -Be 0
    }
    It 'HTML-encodes < and & from the data' {
        $dir = Join-Path $TestDrive 'amp'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $r = New-FakeResult 'SRV-AMP' -Overall 'ACTION' -Results @(New-FakeFinding 'ACTION' 'R&D <share>')
        Save-Result $r $dir 'SRV-AMP-IPU-Assessment.json'
        $null = & $script:MergeScript -InputFolder $dir
        $page = Get-Content -LiteralPath (Join-Path $dir 'IPU-Fleet-Overview.html') -Raw
        $page | Should -Match 'R&amp;D &lt;share&gt;'
        $page | Should -Not -Match 'R&D <share>'
    }
    It 'neutralises values that Excel would run as formulas' {
        $dir = Join-Path $TestDrive 'formula'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $findings = @((New-FakeFinding 'ACTION' '=HYPERLINK("http://example.test","x")'), (New-FakeFinding 'WARNING' '+1+1'), (New-FakeFinding 'MANUAL' '@SUM(A1)'), (New-FakeFinding 'WARNING' '-2+3'), (New-FakeFinding 'WARNING' 'Plain item'))
        Save-Result (New-FakeResult 'SRV-CSV' -Overall 'ACTION' -Results $findings) $dir 'SRV-CSV-IPU-Assessment.json'
        $null = & $script:MergeScript -InputFolder $dir
        $items = @(Import-Csv -LiteralPath (Join-Path $dir 'IPU-Fleet-Findings.csv') -Delimiter ';' | ForEach-Object Item)
        $items | Should -Contain "'=HYPERLINK(""http://example.test"",""x"")"
        $items | Should -Contain "'+1+1"
        $items | Should -Contain "'@SUM(A1)"
        $items | Should -Contain "'-2+3"
        $items | Should -Contain 'Plain item'
        (Import-Csv -LiteralPath (Join-Path $dir 'IPU-Fleet-Servers.csv') -Delimiter ';')[0].Blocker | Should -Be '0'
    }
}

Describe 'Merge-IPUAssessments.ps1 - commands and links (#79)' {
    It 'exports Command and Link with each finding, empty for results from older versions' {
        $dir = Join-Path $TestDrive 'cmd'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $withCmd = New-FakeFinding 'ACTION' 'C: free space'
        $withCmd | Add-Member -NotePropertyName Command -NotePropertyValue 'Get-Volume -DriveLetter C'
        $withCmd | Add-Member -NotePropertyName CommandKind -NotePropertyValue 'Check'
        $withCmd | Add-Member -NotePropertyName Link -NotePropertyValue 'https://learn.microsoft.com/x'
        Save-Result (New-FakeResult 'SRV-CMD' -Overall 'ACTION' -Results @($withCmd, (New-FakeFinding 'WARNING' 'Old style'))) $dir 'SRV-CMD-IPU-Assessment.json'
        $null = & $script:MergeScript -InputFolder $dir
        $rows = @(Import-Csv -LiteralPath (Join-Path $dir 'IPU-Fleet-Findings.csv') -Delimiter ';')
        $a = @($rows | Where-Object { $_.Item -eq 'C: free space' })[0]
        $a.Command | Should -Be 'Get-Volume -DriveLetter C'
        $a.Link | Should -Be 'https://learn.microsoft.com/x'
        @($rows | Where-Object { $_.Item -eq 'Old style' })[0].Command | Should -Be ''
    }
}

Describe 'Merge-IPUAssessments.ps1 - redacted results (#30)' {
    It 'keeps every redacted file as its own row and marks it' {
        $dir = Join-Path $TestDrive 'redacted'
        New-Item -ItemType Directory -Path $dir | Out-Null
        foreach ($n in 1..2) {
            $r = New-FakeResult 'HOST-1' -Overall 'WARNING'
            $r | Add-Member -NotePropertyName Redacted -NotePropertyValue $true
            Save-Result $r $dir ('REDACTED-2026100' + $n + '-090000-IPU-Assessment.json')
        }
        $null = & $script:MergeScript -InputFolder $dir
        $rows = @(Import-Csv -LiteralPath (Join-Path $dir 'IPU-Fleet-Servers.csv') -Delimiter ';')
        $rows.Count | Should -Be 2
        @($rows | Where-Object { $_.Redacted -eq 'True' }).Count | Should -Be 2
        Get-Content -LiteralPath (Join-Path $dir 'IPU-Fleet-Overview.html') -Raw | Should -Match 'redacted'
    }
}

Describe 'Merge-IPUAssessments.ps1 - an original and its redacted copy (#138)' {
    BeforeAll {
        $script:In5 = Join-Path $TestDrive 'dup-in'
        New-Item -ItemType Directory -Path $script:In5 | Out-Null
        Save-Result (New-FakeResult 'SRV01' -Overall 'ACTION' -Results @((New-FakeFinding 'ACTION' 'C: free space'))) $script:In5 'SRV01-IPU-Assessment.json'
        $copy = New-FakeResult 'HOST-1' -Overall 'ACTION' -Results @((New-FakeFinding 'ACTION' 'C: free space'))
        $copy | Add-Member -NotePropertyName Redacted -NotePropertyValue $true
        Save-Result $copy $script:In5 'REDACTED-20261006-090000-IPU-Assessment.json'
    }
    It 'gives one row per server by default and says how many redacted files were skipped' {
        $out = Join-Path $TestDrive 'dup-out1'
        $lines = @(& $script:MergeScript -InputFolder $script:In5 -OutputFolder $out)
        $rows = @(Import-Csv -LiteralPath (Join-Path $out 'IPU-Fleet-Servers.csv') -Delimiter ';')
        $rows.Count | Should -Be 1
        $rows[0].ComputerName | Should -Be 'SRV01'
        @(Import-Csv -LiteralPath (Join-Path $out 'IPU-Fleet-Findings.csv') -Delimiter ';').Count | Should -Be 1
        ($lines -join "`n") | Should -Match 'Redacted files skipped: 1'
    }
    It '-IncludeRedacted keeps the redacted copy as its own row' {
        $out = Join-Path $TestDrive 'dup-out2'
        $lines = @(& $script:MergeScript -InputFolder $script:In5 -OutputFolder $out -IncludeRedacted)
        @(Import-Csv -LiteralPath (Join-Path $out 'IPU-Fleet-Servers.csv') -Delimiter ';').Count | Should -Be 2
        ($lines -join "`n") | Should -Not -Match 'skipped'
    }
}
Describe 'Merge-IPUAssessments.ps1 - RDP NLA column (#174)' {
    It 'shows NLA per server in the CSV and the overview, empty for older results' {
        $in = Join-Path $TestDrive 'nla-in'; $out = Join-Path $TestDrive 'nla-out'
        New-Item -ItemType Directory -Path $in, $out | Out-Null
        $off = New-FakeResult 'SRV-NLA-OFF' -Mode 'Post' -Overall 'ACTION'
        $off.Facts | Add-Member -NotePropertyName Nla -NotePropertyValue 'Off'
        Save-Result $off $in 'SRV-NLA-OFF-IPU-PostUpgrade.json'
        Save-Result (New-FakeResult 'SRV-OLD') $in 'SRV-OLD-IPU-Assessment.json'
        $null = & $script:MergeScript -InputFolder $in -OutputFolder $out
        $rows = @(Import-Csv -LiteralPath (Join-Path $out 'IPU-Fleet-Servers.csv') -Delimiter ';')
        @($rows | Where-Object { $_.ComputerName -eq 'SRV-NLA-OFF' })[0].Nla | Should -Be 'Off'
        @($rows | Where-Object { $_.ComputerName -eq 'SRV-OLD' })[0].Nla | Should -Be ''
        [IO.File]::ReadAllText((Join-Path $out 'IPU-Fleet-Overview.html')) | Should -Match '<th>RDP NLA</th>'
    }
}

Describe 'Merge-IPUAssessments.ps1 - output folder permissions (#128)' {
    BeforeAll {
        $script:AclIn = Join-Path $TestDrive 'acl-in'
        New-Item -ItemType Directory -Path $script:AclIn | Out-Null
        Save-Result (New-FakeResult 'SRV-ACL') $script:AclIn 'SRV-ACL-IPU-Assessment.json'
        $script:BroadSids = @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545')
        function Get-AllowedSid([string]$Path) {
            @((Get-Acl -LiteralPath $Path).GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | Where-Object { [string]$_.AccessControlType -eq 'Allow' } | ForEach-Object { [string]$_.IdentityReference })
        }
    }
    It 'a folder created by the merge is limited to SYSTEM, Administrators and the current user' {
        $out = Join-Path $TestDrive 'acl-new\overview'
        $null = & $script:MergeScript -InputFolder $script:AclIn -OutputFolder $out -WarningVariable w -WarningAction SilentlyContinue
        $sids = Get-AllowedSid $out
        @($sids | Where-Object { $script:BroadSids -contains $_ }) | Should -BeNullOrEmpty
        $sids | Should -Contain 'S-1-5-18'
        $sids | Should -Contain 'S-1-5-32-544'
        $sids | Should -Contain ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        (Get-Acl -LiteralPath $out).AreAccessRulesProtected | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $out 'IPU-Fleet-Overview.html') | Should -BeTrue
        @($w) | Should -BeNullOrEmpty
    }
    It 'an existing folder that Users can read is left unchanged, with a warning' {
        $out = Join-Path $TestDrive 'acl-open'
        New-Item -ItemType Directory -Path $out | Out-Null
        $acl = Get-Acl -LiteralPath $out
        $users = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($users, 'ReadAndExecute', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
        Set-Acl -LiteralPath $out -AclObject $acl
        $null = & $script:MergeScript -InputFolder $script:AclIn -OutputFolder $out -WarningVariable w -WarningAction SilentlyContinue
        (@($w) -join ' ') | Should -Match 'can be read by Users'
        Get-AllowedSid $out | Should -Contain 'S-1-5-32-545'
    }
}

Describe 'Merge-IPUAssessments.ps1 - CSV encoding and time zones (#252)' {
    BeforeAll {
        $script:In3 = Join-Path $TestDrive 'in3'
        New-Item -ItemType Directory -Path $script:In3 | Out-Null
        # Same server, two Pre results from different time zones. By the text, 09:30 is
        # older than 10:00; by UTC, 09:30 +00:00 (09:30Z) is newer than 10:00 +02:00 (08:00Z).
        Save-Result (Set-FakeOffset (New-FakeResult 'SRV-ZONE' -Overall 'ACTION' -Completed '2026-10-06 10:00:00' -Results @((New-FakeFinding 'ACTION' 'Seen from the east'))) '+02:00') $script:In3 'east-SRV-ZONE-IPU-Assessment.json'
        Save-Result (Set-FakeOffset (New-FakeResult 'SRV-ZONE' -Overall 'WARNING' -Completed '2026-10-06 09:30:00' -Results @((New-FakeFinding 'WARNING' 'Seen from UTC'))) '+00:00') $script:In3 'utc-SRV-ZONE-IPU-Assessment.json'
        $script:Nordic = [string]([char]0xC6) + [char]0xD8 + [char]0xC5
        Save-Result (New-FakeResult ('SRV-' + $script:Nordic) -Overall 'OK') $script:In3 'SRV-AEOA-IPU-Assessment.json'
        $script:Out3 = Join-Path $TestDrive 'out3'
        $null = & $script:MergeScript -InputFolder $script:In3 -OutputFolder $script:Out3
    }
    It 'both CSV files start with a UTF-8 byte-order mark on every host' -ForEach @('IPU-Fleet-Servers.csv', 'IPU-Fleet-Findings.csv') {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $script:Out3 $_))
        ($bytes[0..2] -join ',') | Should -Be '239,187,191'
    }
    It 'letters outside ASCII survive in the CSV' {
        [IO.File]::ReadAllText((Join-Path $script:Out3 'IPU-Fleet-Servers.csv'), [Text.Encoding]::UTF8) | Should -Match ('SRV-' + $script:Nordic)
    }
    It 'the newest result is chosen by UTC, not by the text of the local time' {
        $rows = @(Import-Csv -LiteralPath (Join-Path $script:Out3 'IPU-Fleet-Servers.csv') -Delimiter ';' | Where-Object { $_.ComputerName -eq 'SRV-ZONE' })
        $rows.Count | Should -Be 1
        $rows[0].Overall | Should -Be 'WARNING'
    }
    It 'files without an offset (before 4.5.4) are still compared by their local time' {
        $dir = Join-Path $TestDrive 'in4'; New-Item -ItemType Directory -Path $dir | Out-Null
        Save-Result (New-FakeResult 'SRV-OLD' -Overall 'ACTION' -Completed '2026-10-06 08:00:00') $dir 'a-SRV-OLD-IPU-Assessment.json'
        Save-Result (New-FakeResult 'SRV-OLD' -Overall 'OK' -Completed '2026-10-06 12:00:00') $dir 'b-SRV-OLD-IPU-Assessment.json'
        $o = Join-Path $TestDrive 'out4'
        $null = & $script:MergeScript -InputFolder $dir -OutputFolder $o
        $rows = @(Import-Csv -LiteralPath (Join-Path $o 'IPU-Fleet-Servers.csv') -Delimiter ';')
        $rows[0].Overall | Should -Be 'OK'
    }
}

Describe 'End-of-life verdicts in the fleet overview (#275)' {
    BeforeAll {
        # The pure functions live in parts of the merge script: load them as they are built in.
        . (Join-Path $PSScriptRoot '..\src\assessment\25-eol-core.ps1')
        . (Join-Path $PSScriptRoot '..\src\merge\20-eol-fleet.ps1')
        $script:Today = [datetime]'2026-10-24'
        $script:SnapJson = '{"asOf":"2026-10-01","products":{"php":[{"cycle":"7.4","eol":"2022-11-28","support":"2021-11-28"},{"cycle":"8.9","eol":"2099-01-01","support":"2098-01-01"}],"redis":[]}}'
        $script:Snap = $script:SnapJson | ConvertFrom-Json
        function New-Cand([string]$Product, [string]$Version) { [pscustomobject]@{ Product = $Product; Version = $Version; Source = 'File probe'; Evidence = 'php.exe' } }
        function New-EolServer([string]$Name, [object[]]$Candidates) { [pscustomobject]@{ ComputerName = $Name; Candidates = $Candidates } }
    }
    Context 'pure functions' {
        It 'Find-EolSnapshotFile: the named file wins, else the first folder that has one' {
            Find-EolSnapshotFile 'D:\x\snap.json' @($TestDrive) | Should -Be 'D:\x\snap.json'
            $a = Join-Path $TestDrive 'a'; $b = Join-Path $TestDrive 'b'
            New-Item -ItemType Directory -Path $a, $b | Out-Null
            Set-Content -LiteralPath (Join-Path $b 'eol-snapshot.json') -Value '{}'
            Find-EolSnapshotFile '' @($a, $b, '') | Should -Be (Join-Path $b 'eol-snapshot.json')
            Find-EolSnapshotFile '' @($a) | Should -Be ''
        }
        It 'Get-EolFleetRow: one row per product and version, servers counted, worst first' {
            $servers = @(
                (New-EolServer 'SRV-A' @((New-Cand 'php' '8.9.1'), (New-Cand 'php' '7.4.33'))),
                (New-EolServer 'SRV-B' @((New-Cand 'php' '7.4.33'), (New-Cand 'redis' '7.0.1'))))
            $rows = @(Get-EolFleetRow $servers $script:Snap $script:Today)
            $rows.Count | Should -Be 3
            $rows[0].Status | Should -Be 'WARNING'; $rows[0].Product | Should -Be 'PHP'; $rows[0].Version | Should -Be '7.4.33'
            $rows[0].ServerCount | Should -Be 2; $rows[0].Servers | Should -Be 'SRV-A, SRV-B'
            $rows[1].Status | Should -Be 'MANUAL'; $rows[1].Product | Should -Be 'Redis'
            $rows[2].Status | Should -Be 'OK'
        }
        It 'Get-EolFleetRow: without a snapshot every product is MANUAL, never supported' {
            $rows = @(Get-EolFleetRow @((New-EolServer 'SRV-A' @((New-Cand 'php' '8.9.1')))) $null $script:Today)
            $rows[0].Status | Should -Be 'MANUAL'; $rows[0].Text | Should -Match 'Not checked'; $rows[0].Product | Should -Be 'PHP'
        }
        It 'Get-EolFleetRow: no servers or no candidates, no rows' {
            @(Get-EolFleetRow @() $script:Snap $script:Today).Count | Should -Be 0
            @(Get-EolFleetRow @((New-EolServer 'SRV-A' @())) $script:Snap $script:Today).Count | Should -Be 0
        }
        It 'Get-EolServerFinding: only findings, and not the ones the server already reported' {
            $c = @((New-Cand 'php' '7.4.33'), (New-Cand 'php' '8.9.1'), (New-Cand 'redis' '7.0.1'))
            $f = @(Get-EolServerFinding $c @() $script:Snap $script:Today)
            $f.Count | Should -Be 2
            ($f | Where-Object Item -eq 'EOL: PHP 7.4.33').Status | Should -Be 'WARNING'
            ($f | Where-Object Item -eq 'EOL: Redis 7.0.1').Status | Should -Be 'MANUAL'
            @(Get-EolServerFinding $c @('EOL: PHP 7.4.33') $script:Snap $script:Today).Count | Should -Be 1
            @(Get-EolServerFinding $c @() $null $script:Today).Count | Should -Be 0
        }
        It 'Get-EolServerSummary: the products past end of life' {
            Get-EolServerSummary @((New-Cand 'php' '7.4.33'), (New-Cand 'php' '8.9.1')) $script:Snap $script:Today | Should -Be 'PHP 7.4.33'
            Get-EolServerSummary @((New-Cand 'php' '8.9.1')) $script:Snap $script:Today | Should -Be ''
            Get-EolServerSummary @((New-Cand 'php' '7.4.33')) $null $script:Today | Should -Be ''
        }
    }
    Context 'the merge script' {
        BeforeAll {
            $script:MergeScript = Join-Path $PSScriptRoot '..\src\Merge-IPUAssessments.ps1'
            function Save-Fake($Object, [string]$Folder, [string]$Name) { $Object | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Folder $Name) -Encoding UTF8 }
            function New-Server([string]$Computer, [object[]]$Candidates, [object[]]$Results = @()) {
                $counts = [ordered]@{ BLOCKER = 0; ACTION = 0; WARNING = 0; MANUAL = 0 }
                $o = [pscustomobject][ordered]@{
                    Schema = 'IPU-Assessment/1'; CollectorVersion = '4.6.0'; ComputerName = $Computer; Mode = 'Pre'; TargetServerVersion = '2025'
                    Started = '2026-10-06 10:00:00'; Completed = '2026-10-06 10:00:00'; Partial = $false; Overall = 'OK'; Counts = [pscustomobject]$counts
                    Facts = [pscustomobject]@{ CurrentOS = 'Windows Server 2016 Standard'; UpgradePath = 'Supported'; RecommendedMedia = 'x'; Platform = 'Virtual'; DomainRole = 'Member server'; SqlServer = ''; CompatScan = ''; CDrive = ''; Activation = '' }
                    Results = @($Results); CheckRuns = @([pscustomobject]@{ Id = 'baseline'; Name = 'Baseline inventory'; Phase = 'Fast'; Outcome = 'Completed'; Duration = '00:00:01'; Message = '' })
                    Snapshot = [pscustomobject]@{}
                    EolCandidates = @($Candidates)
                }
                return $o
            }
            $script:EIn = Join-Path $TestDrive 'ein'; New-Item -ItemType Directory -Path $script:EIn | Out-Null
            Save-Fake (New-Server 'SRV-A' @((New-Cand 'php' '7.4.33'), (New-Cand 'php' '8.9.1'))) $script:EIn 'SRV-A-IPU-Assessment.json'
            # SRV-B already has its own EOL row from a snapshot on the server: not added twice.
            $own = [pscustomobject]@{ CheckId = 'eolsnapshot'; Area = 'APPLICATIONS'; Item = 'EOL: PHP 7.4.33'; Status = 'WARNING'; Kind = 'Finding'; Value = 'v'; Details = 'd'; Recommendation = 'r'; Source = 's' }
            Save-Fake (New-Server 'SRV-B' @((New-Cand 'php' '7.4.33')) @($own)) $script:EIn 'SRV-B-IPU-Assessment.json'
            # A result from before 4.6.0 has no EolCandidates at all.
            $old = New-Server 'SRV-OLD' @(); $old.PSObject.Properties.Remove('EolCandidates')
            Save-Fake $old $script:EIn 'SRV-OLD-IPU-Assessment.json'
            Set-Content -LiteralPath (Join-Path $script:EIn 'snap.json') -Value $script:SnapJson
        }
        It 'with a snapshot: the EOL file, the servers column, the findings and the overview agree' {
            $out = Join-Path $TestDrive 'eout1'
            $text = & $script:MergeScript -InputFolder $script:EIn -OutputFolder $out -EolSnapshot (Join-Path $script:EIn 'snap.json')
            ($text -join "`n") | Should -Match 'IPU-Fleet-Eol.csv'
            $eol = @(Import-Csv -LiteralPath (Join-Path $out 'IPU-Fleet-Eol.csv') -Delimiter ';')
            $eol.Count | Should -Be 2
            $eol[0].Status | Should -Be 'WARNING'; $eol[0].Product | Should -Be 'PHP'; $eol[0].ServerCount | Should -Be '2'
            $servers = @(Import-Csv -LiteralPath (Join-Path $out 'IPU-Fleet-Servers.csv') -Delimiter ';')
            ($servers | Where-Object ComputerName -eq 'SRV-A').EndOfLifeProducts | Should -Be 'PHP 7.4.33'
            ($servers | Where-Object ComputerName -eq 'SRV-OLD').EndOfLifeProducts | Should -Be ''
            $findings = @(Import-Csv -LiteralPath (Join-Path $out 'IPU-Fleet-Findings.csv') -Delimiter ';' | Where-Object { $_.Item -like 'EOL: *' })
            @($findings | Where-Object ComputerName -eq 'SRV-A').Count | Should -Be 1
            @($findings | Where-Object ComputerName -eq 'SRV-B').Count | Should -Be 1   # its own row, not doubled
            $html = Get-Content -LiteralPath (Join-Path $out 'IPU-Fleet-Overview.html') -Raw
            $html | Should -Match 'End-of-life products'
            $html | Should -Match 'Snapshot from 2026-10-01'
            $html | Should -Match 'End-of-life data from endoflife.date \(https://endoflife.date\), MIT License'
        }
        It 'without a snapshot: listed as not checked, a note says so, nothing is called supported' {
            $dir = Join-Path $TestDrive 'ein2'; New-Item -ItemType Directory -Path $dir | Out-Null
            Save-Fake (New-Server 'SRV-A' @((New-Cand 'php' '8.9.1'))) $dir 'SRV-A-IPU-Assessment.json'
            $out = Join-Path $TestDrive 'eout2'
            $text = & $script:MergeScript -InputFolder $dir -OutputFolder $out -EolSnapshot (Join-Path $dir 'missing.json')
            $eol = @(Import-Csv -LiteralPath (Join-Path $out 'IPU-Fleet-Eol.csv') -Delimiter ';')
            $eol[0].Status | Should -Be 'MANUAL'; $eol[0].Text | Should -Match 'Not checked'
            ($text -join "`n") | Should -Match 'could not be read'
            (Get-Content -LiteralPath (Join-Path $out 'IPU-Fleet-Overview.html') -Raw) | Should -Match 'listed but not checked'
            @(Import-Csv -LiteralPath (Join-Path $out 'IPU-Fleet-Findings.csv') -Delimiter ';' | Where-Object { $_.Item -like 'EOL: *' }).Count | Should -Be 0
        }
        It 'a snapshot older than six months says so; end of life still shows' {
            $dir = Join-Path $TestDrive 'ein3'; New-Item -ItemType Directory -Path $dir | Out-Null
            Save-Fake (New-Server 'SRV-A' @((New-Cand 'php' '7.4.33'), (New-Cand 'php' '8.9.1'))) $dir 'SRV-A-IPU-Assessment.json'
            Set-Content -LiteralPath (Join-Path $dir 'eol-snapshot.json') -Value ($script:SnapJson.Replace('2026-10-01', '2020-01-01'))
            $out = Join-Path $TestDrive 'eout3'
            $null = & $script:MergeScript -InputFolder $dir -OutputFolder $out -EolSnapshot (Join-Path $dir eol-snapshot.json)
            $eol = @(Import-Csv -LiteralPath (Join-Path $out 'IPU-Fleet-Eol.csv') -Delimiter ';')
            ($eol | Where-Object Version -eq '7.4.33').Status | Should -Be 'WARNING'
            ($eol | Where-Object Version -eq '8.9.1').Status | Should -Be 'MANUAL'
            (Get-Content -LiteralPath (Join-Path $out 'IPU-Fleet-Overview.html') -Raw) | Should -Match 'cannot confirm'
        }
        It 'a Windows Server release is matched by name in the merge script too' {
            $dir = Join-Path $TestDrive 'ein5'; New-Item -ItemType Directory -Path $dir | Out-Null
            Save-Fake (New-Server 'SRV-W' @((New-Cand 'windows-server' '6.3.9600'))) $dir 'SRV-W-IPU-Assessment.json'
            Set-Content -LiteralPath (Join-Path $dir 'snap.json') -Value '{"asOf":"2026-10-01","products":{"windows-server":[{"cycle":"2012-r2","eol":"2023-10-10"}]}}'
            $out = Join-Path $TestDrive 'eout5'
            $null = & $script:MergeScript -InputFolder $dir -OutputFolder $out -EolSnapshot (Join-Path $dir 'snap.json')
            $eol = @(Import-Csv -LiteralPath (Join-Path $out 'IPU-Fleet-Eol.csv') -Delimiter ';')
            $eol[0].Status | Should -Be 'WARNING'; $eol[0].Release | Should -Be '2012-r2'
        }
        It 'no server reports products: the section says so' {
            $dir = Join-Path $TestDrive 'ein4'; New-Item -ItemType Directory -Path $dir | Out-Null
            Save-Fake (New-Server 'SRV-A' @()) $dir 'SRV-A-IPU-Assessment.json'
            $out = Join-Path $TestDrive 'eout4'
            $null = & $script:MergeScript -InputFolder $dir -OutputFolder $out -EolSnapshot (Join-Path $script:EIn 'snap.json')
            (Get-Content -LiteralPath (Join-Path $out 'IPU-Fleet-Overview.html') -Raw) | Should -Match 'No server reported a product'
        }
    }
}
