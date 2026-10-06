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
