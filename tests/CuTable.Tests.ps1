# Pester 5 tests. The cumulative update table: the refresh tool and the shipped file (#267, #459).
# The page text below is test data, not Microsoft's page.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
    . (Join-Path $PSScriptRoot '..\build\Update-CuTable.ps1') -LibraryOnly
    $script:Page = @'
## Windows Server release history

**Windows Server 2022 (OS build 20348)**

| Servicing option | Update type | Availability date | Build | KB article |
| --- | --- | --- | --- | --- |
| LTSC | 2026-11 OOB | 2026-11-13 | 20348.5873 | [KB1000003](https://example.test/1) |
| LTSC | 2026-11 B | 2026-11-10 | 20348.5870 | [KB1000002](https://example.test/2) |
| LTSC | 2026-10 C | 2026-10-27 | 20348.5800 | [KB1000001](https://example.test/3) |
| LTSC | 2026-10 A | 2026-10-01 | 20348.5700 |  |
| LTSC | 2026-10 B | 2026-10-13 | 20348.5761 | [KB1000004](https://example.test/4) |

**Windows Server 2016 (OS build 14393)**

| Servicing option | Update type | Availability date | Build | KB article |
| --- | --- | --- | --- | --- |
| LTSB | 2026-11 B | 2026-11-10 | 14393.9000 | [KB1000005](https://example.test/5) |
| LTSB | not a type label | 2026-11-11 | 14393.9001 | [KB1000006](https://example.test/6) |

## Windows Server hotpatch calendar

| Month | Update type | Type | Availability date | Build | KB article |
| --- | --- | --- | --- | --- | --- |
| January | 2026.01 B | Baseline (Restart) | 2026-01-13 | 26100.32230 | [KB1000007](https://example.test/7) |
| February | 2026.02 B | Hotpatch | 2026-02-10 | 26100.32313 | [KB1000008](https://example.test/8) |
| February | 2026.02 B | Hotpatch | 2026-02-10 | 20348.5870 | [KB1000002](https://example.test/2) |
'@
}

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'ConvertFrom-ReleaseHealthMarkdown (#459)' {
    BeforeAll { $script:Parsed = ConvertFrom-ReleaseHealthMarkdown $script:Page ([datetime]'2026-11-23') 'https://example.test/page' }
    It 'reads build, UBR, KB, date and type, grouped and sorted by build and UBR' {
        @($script:Parsed.releases.PSObject.Properties.Name) | Should -Be @('14393', '20348', '26100')
        @($script:Parsed.releases.'20348' | ForEach-Object { $_.ubr }) | Should -Be @(5761, 5800, 5870, 5873)
        $row = @($script:Parsed.releases.'20348' | Where-Object { $_.ubr -eq 5873 })[0]
        $row.kb | Should -Be 'KB1000003'; $row.released | Should -Be '2026-11-13'; $row.type | Should -Be 'OOB'
        @($script:Parsed.releases.'20348' | Where-Object { $_.ubr -eq 5800 })[0].type | Should -Be 'C'
    }
    It 'leaves out a row without a KB number or without an update type label' {
        @($script:Parsed.releases.'20348' | ForEach-Object { $_.ubr }) | Should -Not -Contain 5700
        @($script:Parsed.releases.'14393' | ForEach-Object { $_.ubr }) | Should -Be @(9000)
    }
    It 'reads hotpatch rows, and lists a row that is in both tables once' {
        @($script:Parsed.releases.'26100').Count | Should -Be 2
        @($script:Parsed.releases.'20348' | Where-Object { $_.ubr -eq 5870 }).Count | Should -Be 1
    }
    It 'records the date and the source, and passes the table check' {
        $script:Parsed.asOf | Should -Be '2026-11-23'
        $script:Parsed.source | Should -Be 'https://example.test/page'
        @(Test-CuTableContent $script:Parsed).Count | Should -Be 0
    }
    It 'text without rows gives an empty table' {
        @((ConvertFrom-ReleaseHealthMarkdown 'no tables here' ([datetime]'2026-11-23')).releases.PSObject.Properties).Count | Should -Be 0
    }
}

Describe 'ConvertTo-CuTableJson (#459)' {
    It 'writes JSON that reads back as the same table, one row per line, LF only' {
        $parsed = ConvertFrom-ReleaseHealthMarkdown $script:Page ([datetime]'2026-11-23') 'https://example.test/page'
        $text = ConvertTo-CuTableJson $parsed
        $text | Should -Not -Match "`r"
        $back = $text | ConvertFrom-Json
        $back.schema | Should -Be 'IPU-CuTable/1'
        @(Test-CuTableContent $back).Count | Should -Be 0
        (Get-CumulativeUpdateLookup $back '20348.5870').Kb | Should -Be 'KB1000002'
        @($text -split "`n" | Where-Object { $_ -match '"ubr":' }).Count | Should -Be 7
    }
}

Describe 'Get-CuTableRefreshDecision (#459)' {
    BeforeAll {
        $script:Old = ConvertFrom-ReleaseHealthMarkdown $script:Page ([datetime]'2026-10-01')
    }
    It 'the same rows on another day are no pull request' {
        $same = ConvertFrom-ReleaseHealthMarkdown $script:Page ([datetime]'2026-11-23')
        (Get-CuTableRefreshDecision $script:Old $same).Action | Should -Be 'None'
    }
    It 'a new row is a pull request' {
        $more = ConvertFrom-ReleaseHealthMarkdown ($script:Page + "`n| LTSC | 2026-12 B | 2026-12-08 | 20348.6000 | [KB1000009](https://example.test/9) |") ([datetime]'2026-12-09')
        (Get-CuTableRefreshDecision $script:Old $more).Action | Should -Be 'PullRequest'
    }
    It 'fewer rows than the table has, or none, fails instead of replacing it' {
        $fewer = ConvertFrom-ReleaseHealthMarkdown ($script:Page -replace '(?m)^\| LTSC \| 2026-10 B.*$', '') ([datetime]'2026-11-23')
        (Get-CuTableRefreshDecision $script:Old $fewer).Action | Should -Be 'Fail'
        $none = ConvertFrom-ReleaseHealthMarkdown 'layout changed' ([datetime]'2026-11-23')
        (Get-CuTableRefreshDecision $script:Old $none).Action | Should -Be 'Fail'
        (Get-CuTableRefreshDecision $script:Old $none).Reason | Should -Match 'layout'
    }
    It 'with no table yet, the first one is a pull request' {
        (Get-CuTableRefreshDecision $null $script:Old).Action | Should -Be 'PullRequest'
    }
}

Describe 'The shipped table, src/cu-table.json (#459)' {
    BeforeAll { $script:Shipped = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\cu-table.json') -Raw | ConvertFrom-Json }
    It 'passes the table check' { @(Test-CuTableContent $script:Shipped) | Should -BeNullOrEmpty }
    It 'covers Windows Server 2016, 2019, 2022 and 2025 and says where it came from' {
        foreach ($build in '14393', '17763', '20348', '26100') { $script:Shipped.releases.PSObject.Properties.Name | Should -Contain $build }
        $script:Shipped.source | Should -Match 'learn\.microsoft\.com'
    }
    It 'is the output of the refresh tool: one row per line, LF only, ASCII' {
        $raw = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\src\cu-table.json'))
        $raw | Should -Not -Match "`r"
        $raw | Should -Match '^[\x00-\x7F]*$'
        ConvertTo-CuTableJson $script:Shipped | Should -Be $raw
    }
    It 'finds a known update: Windows Server 2022, November 2023' {
        $r = Get-CumulativeUpdateLookup $script:Shipped '20348.2113'
        $r.Kind | Should -Be 'Found'; $r.Kb | Should -Be 'KB5032198'; $r.Released | Should -Be '2023-11-14'
    }
}
