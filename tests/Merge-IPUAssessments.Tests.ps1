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
