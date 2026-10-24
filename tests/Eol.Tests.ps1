# Pester 5 tests for src/Get-IPUEolStatus.ps1. Pure functions only: no network, no snapshot file.
# Synthetic lifecycle data, shaped like endoflife.date releases.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\Get-IPUEolStatus.ps1')
    $script:Today = [datetime]'2026-10-23'
    function New-Cycle([string]$Cycle, $Eol, $Support = $null) { [pscustomobject]@{ cycle = $Cycle; eol = $Eol; support = $Support } }
}

Describe 'ConvertTo-EolSegment' {
    It 'splits on dots and drops a suffix' { (ConvertTo-EolSegment '13.0-sp3') -join '|' | Should -Be '13|0' }
    It 'drops a leading v' { (ConvertTo-EolSegment 'v8.2.1') -join '|' | Should -Be '8|2|1' }
    It 'empty text gives no segments' { @(ConvertTo-EolSegment '').Count | Should -Be 0 }
}

Describe 'Get-EolCycleMatch' {
    BeforeAll { $script:Cycles = @((New-Cycle '1.10' '2030-01-01'), (New-Cycle '1.1' '2020-01-01'), (New-Cycle '8' '2030-01-01'), (New-Cycle '8.2' '2028-01-01')) }
    It '1.10.3 matches 1.10, not 1.1' { (Get-EolCycleMatch $script:Cycles '1.10.3').cycle | Should -Be '1.10' }
    It '1.1.9 matches 1.1, not 1.10' { (Get-EolCycleMatch $script:Cycles '1.1.9').cycle | Should -Be '1.1' }
    It 'the longest release number wins' { (Get-EolCycleMatch $script:Cycles '8.2.12').cycle | Should -Be '8.2' }
    It 'falls back to the shorter release' { (Get-EolCycleMatch $script:Cycles '8.4.0').cycle | Should -Be '8' }
    It 'no match' { Get-EolCycleMatch $script:Cycles '9.0' | Should -BeNullOrEmpty }
    It 'a version shorter than the release number does not match' { Get-EolCycleMatch @((New-Cycle '4.8.1' $false)) '4.8' | Should -BeNullOrEmpty }
    It '.NET Framework 4.8.x is not 4.8.1' {
        $c = @((New-Cycle '4.8.1' $false), (New-Cycle '4.8' $false))
        (Get-EolCycleMatch $c '4.8.9032').cycle | Should -Be '4.8'
    }
    It 'SQL Server service pack suffix on the release name' { (Get-EolCycleMatch @((New-Cycle '13.0-sp3' '2026-07-14')) '13.0.6300.2').cycle | Should -Be '13.0-sp3' }
}

Describe 'ConvertTo-EolWindowsRelease' {
    It 'maps builds' {
        ConvertTo-EolWindowsRelease '10.0.14393' | Should -Be '2016'
        ConvertTo-EolWindowsRelease '10.0.20348.2113' | Should -Be '2022'
        ConvertTo-EolWindowsRelease '6.3.9600' | Should -Be '2012-r2'
        ConvertTo-EolWindowsRelease '26100' | Should -Be '2025'
    }
    It 'passes a release name through' { ConvertTo-EolWindowsRelease '2019' | Should -Be '2019' }
    It 'an unknown build is returned unchanged' { ConvertTo-EolWindowsRelease '10.0.99999' | Should -Be '10.0.99999' }
}

Describe 'Windows Server 2008 to 2025' {
    BeforeAll {
        # Shaped like the endoflife.date windows-server list, in its order (newest first).
        $script:Win = @((New-Cycle '2025' '2034-11-14' '2029-11-13'), (New-Cycle '2022' '2031-10-14' '2026-10-13'), (New-Cycle '2019' '2029-01-09' '2024-01-09'),
                        (New-Cycle '2016' '2027-01-12' '2022-01-11'), (New-Cycle '2012-r2' '2023-10-10' '2018-10-09'), (New-Cycle '2012' '2023-10-10' '2018-10-09'),
                        (New-Cycle '2008-r2-sp1' '2020-01-14' '2015-01-13'), (New-Cycle '2008-sp2' '2020-01-14' '2015-01-13'))
    }
    It '<Version> is release <Cycle>' -ForEach @(
        @{ Version = '6.0.6001'; Cycle = '2008-sp2' }, @{ Version = '6.0.6002'; Cycle = '2008-sp2' }
        @{ Version = '6.1.7600'; Cycle = '2008-r2-sp1' }, @{ Version = '6.1.7601'; Cycle = '2008-r2-sp1' }
        @{ Version = '6.2.9200'; Cycle = '2012' }, @{ Version = '6.3.9600'; Cycle = '2012-r2' }
        @{ Version = '10.0.14393'; Cycle = '2016' }, @{ Version = '10.0.17763'; Cycle = '2019' }
        @{ Version = '10.0.20348'; Cycle = '2022' }, @{ Version = '10.0.26100'; Cycle = '2025' }
        @{ Version = '2008'; Cycle = '2008-sp2' }, @{ Version = '2008R2'; Cycle = '2008-r2-sp1' }
        @{ Version = '2012'; Cycle = '2012' }, @{ Version = '2012R2'; Cycle = '2012-r2' }
    ) {
        (Get-EolDecision 'windows-server' $Version $script:Win $script:Today).Cycle | Should -Be $Cycle
    }
    It '2012 and 2012 R2 are not mixed up when either is listed first' {
        $flipped = @($script:Win[5], $script:Win[4])
        (Get-EolDecision 'windows-server' '2012R2' $flipped $script:Today).Cycle | Should -Be '2012-r2'
        (Get-EolDecision 'windows-server' '2012' $flipped $script:Today).Cycle | Should -Be '2012'
    }
    It '2008 and 2008 R2 are out of support, 2012 and 2012 R2 too' {
        foreach ($v in '2008', '2008R2', '2012', '2012R2') { (Get-EolDecision 'windows-server' $v $script:Win $script:Today).State | Should -Be 'EndOfLife' }
    }
    It '2016 ends within the warning window, 2019 to 2025 are supported' {
        (Get-EolDecision 'windows-server' '2016' $script:Win $script:Today).State | Should -Be 'EndingSoon'
        foreach ($v in '2019', '2022', '2025') { (Get-EolDecision 'windows-server' $v $script:Win $script:Today).Status | Should -Not -Be 'MANUAL' }
    }
    It 'an unknown Windows Server build is MANUAL' { (Get-EolDecision 'windows-server' '10.0.99999' $script:Win $script:Today).Status | Should -Be 'MANUAL' }
}
Describe 'ConvertTo-EolDate' {
    It 'text' { (ConvertTo-EolDate '2027-01-12').ToString('yyyy-MM-dd') | Should -Be '2027-01-12' }
    It 'a DateTime (PowerShell 7 JSON)' { (ConvertTo-EolDate ([datetime]'2027-01-12 13:45')).ToString('yyyy-MM-dd HH:mm') | Should -Be '2027-01-12 00:00' }
    It 'boolean and null give no date' { ConvertTo-EolDate $false | Should -BeNullOrEmpty; ConvertTo-EolDate $null | Should -BeNullOrEmpty }
    It 'text that is not yyyy-MM-dd gives no date' { ConvertTo-EolDate '12/01/2027' | Should -BeNullOrEmpty }
}

Describe 'Get-EolDecision' {
    It 'supported' {
        $d = Get-EolDecision 'php' '8.4.1' @((New-Cycle '8.4' '2028-12-31' '2026-12-31')) $script:Today
        $d.State | Should -Be 'Supported'; $d.Status | Should -Be 'OK'; $d.Cycle | Should -Be '8.4'; $d.EolDate | Should -Be '2028-12-31'
    }
    It 'the last day is still supported, the next day is not' {
        $c = @((New-Cycle '7.4' '2026-10-23'))
        (Get-EolDecision 'php' '7.4.1' $c $script:Today).State | Should -Not -Be 'EndOfLife'
        $d = Get-EolDecision 'php' '7.4.1' $c ([datetime]'2026-10-24')
        $d.State | Should -Be 'EndOfLife'; $d.Status | Should -Be 'WARNING'
    }
    It 'ending soon inside the warning window' {
        $d = Get-EolDecision 'mariadb' '10.11.2' @((New-Cycle '10.11' '2027-02-01')) $script:Today -WarnDays 180
        $d.State | Should -Be 'EndingSoon'; $d.Status | Should -Be 'INFO'; $d.DaysLeft | Should -Be 101
    }
    It 'the same release is just supported with a shorter window' {
        (Get-EolDecision 'mariadb' '10.11.2' @((New-Cycle '10.11' '2027-02-01')) $script:Today -WarnDays 30).State | Should -Be 'Supported'
    }
    It 'security fixes only once active support is over' {
        $d = Get-EolDecision 'nodejs' '20.1.0' @((New-Cycle '20' '2029-04-30' '2026-04-22')) $script:Today
        $d.State | Should -Be 'SecurityOnly'; $d.Status | Should -Be 'INFO'
    }
    It 'eol=false is OK but does not promise support' {
        $d = Get-EolDecision 'apache-http-server' '2.4.58' @((New-Cycle '2.4' $false)) $script:Today
        $d.State | Should -Be 'Supported'; $d.Text | Should -Match 'no end-of-life date'
    }
    It 'eol=true is end of life without a date' {
        $d = Get-EolDecision 'php' '5.6.40' @((New-Cycle '5.6' $true)) $script:Today
        $d.State | Should -Be 'EndOfLife'; $d.Status | Should -Be 'WARNING'
    }
    It 'a DateTime eol (PowerShell 7 JSON) gives the same verdict as text' {
        $d = Get-EolDecision 'php' '7.4.1' @((New-Cycle '7.4' ([datetime]'2022-11-28'))) $script:Today
        $d.State | Should -Be 'EndOfLife'
    }
    It 'no matching release is MANUAL, never OK' {
        $d = Get-EolDecision 'php' '9.9.9' @((New-Cycle '8.4' '2028-12-31')) $script:Today
        $d.State | Should -Be 'Unknown'; $d.Status | Should -Be 'MANUAL'
    }
    It 'no release data at all is MANUAL' { (Get-EolDecision 'php' '8.4.1' @() $script:Today).Status | Should -Be 'MANUAL' }
    It 'Windows Server by build' {
        $d = Get-EolDecision 'windows-server' '10.0.14393' @((New-Cycle '2016' '2027-01-12'), (New-Cycle '2019' '2029-01-09')) $script:Today
        $d.Cycle | Should -Be '2016'; $d.State | Should -Be 'EndingSoon'
    }
    It 'names the product' { (Get-EolDecision 'mssqlserver' '16.0.1000' @((New-Cycle '16.0' '2033-01-11')) $script:Today).Name | Should -Be 'Microsoft SQL Server' }
}

Describe 'Product list' {
    It 'has no duplicate display names' { @($script:EolProducts.Values | Select-Object -Unique).Count | Should -Be $script:EolProducts.Count }
    It 'covers the operating system, databases, web servers, PHP and runtimes' {
        foreach ($p in 'windows-server', 'mssqlserver', 'postgresql', 'apache-http-server', 'php', 'dotnet', 'eclipse-temurin') { $script:EolProducts.Contains($p) | Should -BeTrue }
    }
}

Describe 'Get-EolSnapshotRelease' {
    BeforeAll {
        $script:SnapPath = Join-Path ([IO.Path]::GetTempPath()) ('eol-snapshot-' + [guid]::NewGuid().ToString('N') + '.json')
        '{"asOf":"2026-10-23","source":"endoflife.date","products":{"php":[{"cycle":"8.4","eol":"2028-12-31","support":"2026-12-31"}]}}' | Set-Content -LiteralPath $script:SnapPath -Encoding UTF8
    }
    AfterAll { Remove-Item -LiteralPath $script:SnapPath -ErrorAction SilentlyContinue }
    It 'reads the releases and the snapshot date' {
        $r = Get-EolSnapshotRelease -Product 'php' -SnapshotPath $script:SnapPath
        $r.Source | Should -Be 'snapshot'; $r.AsOf | Should -Be '2026-10-23'; @($r.Cycles).Count | Should -Be 1
    }
    It 'releases read from the file give a verdict whatever the JSON parser does with the dates' {
        $r = Get-EolSnapshotRelease -Product 'php' -SnapshotPath $script:SnapPath
        (Get-EolDecision 'php' '8.4.2' $r.Cycles ([datetime]'2026-10-23')).State | Should -Be 'Supported'
    }
    It 'a product that is not in the snapshot gives nothing' { Get-EolSnapshotRelease -Product 'nginx' -SnapshotPath $script:SnapPath | Should -BeNullOrEmpty }
    It 'a missing file gives nothing' { Get-EolSnapshotRelease -Product 'php' -SnapshotPath (Join-Path ([IO.Path]::GetTempPath()) 'no-such-eol-file.json') | Should -BeNullOrEmpty }
    It 'no path gives nothing' { Get-EolSnapshotRelease -Product 'php' -SnapshotPath '' | Should -BeNullOrEmpty }
}

Describe 'Get-EolOnlineRelease' {
    It 'asks endoflife.date for the product and returns its releases' {
        Mock Invoke-RestMethod { @([pscustomobject]@{ cycle = '8.4'; eol = '2028-12-31' }) } -ParameterFilter { $Uri -eq 'https://endoflife.date/api/php.json' }
        $r = Get-EolOnlineRelease -Product 'php'
        $r.Source | Should -Be 'endoflife.date'; @($r.Cycles).Count | Should -Be 1
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }
}

Describe 'New-EolSnapshotObject' {
    It 'holds the date, the source, the licence, the attribution and the releases by product' {
        $s = New-EolSnapshotObject -Products @{ php = @((New-Cycle '8.4' '2028-12-31')); nginx = @((New-Cycle '1.30' $false)) } -AsOf '2026-10-23'
        $s.asOf | Should -Be '2026-10-23'; $s.license | Should -Be 'MIT'; $s.attribution | Should -Match 'endoflife.date'
        $s.licenseNotice | Should -Match 'Copyright 2020 endoflife.date contributors'; $s.licenseNotice | Should -Match 'Permission is hereby granted'
        @($s.products.Keys) -join ',' | Should -Be 'nginx,php'
    }
}

Describe 'Get-EolSnapshotAge' {
    It 'fresh inside the limit' {
        $a = Get-EolSnapshotAge '2026-06-01' ([datetime]'2026-10-23') 6
        $a.State | Should -Be 'Fresh'; $a.Months | Should -Be 4
    }
    It 'the last day of the limit is still fresh, the next day is stale' {
        (Get-EolSnapshotAge '2026-04-23' ([datetime]'2026-10-23') 6).State | Should -Be 'Fresh'
        (Get-EolSnapshotAge '2026-04-23' ([datetime]'2026-10-24') 6).State | Should -Be 'Stale'
    }
    It 'stale says how old' {
        $a = Get-EolSnapshotAge '2025-10-23' ([datetime]'2026-10-23') 6
        $a.State | Should -Be 'Stale'; $a.Months | Should -Be 12; $a.Text | Should -Match '12 months old, limit 6'
    }
    It 'no usable date counts as too old' {
        (Get-EolSnapshotAge '' ([datetime]'2026-10-23') 6).State | Should -Be 'Unknown'
        (Get-EolSnapshotAge 'last spring' ([datetime]'2026-10-23') 6).State | Should -Be 'Unknown'
    }
    It 'a date in the future is not negative' { (Get-EolSnapshotAge '2027-01-01' ([datetime]'2026-10-23') 6).Months | Should -Be 0 }
}

Describe 'ConvertTo-EolStaleDecision' {
    BeforeAll {
        $script:Fresh = [pscustomobject]@{ State = 'Fresh'; Months = 1; Text = 'The snapshot is from 2026-09-01.' }
        $script:Stale = [pscustomobject]@{ State = 'Stale'; Months = 12; Text = 'The snapshot is from 2025-10-23 (12 months old, limit 6).' }
        function New-Decision([string]$State, [string]$Status) { [pscustomobject]@{ Product = 'php'; State = $State; Status = $Status; Text = 'php 8.4 verdict.' } }
    }
    It 'a fresh snapshot leaves the verdict alone' {
        $d = New-Decision 'Supported' 'OK'
        (ConvertTo-EolStaleDecision $d $script:Fresh).Status | Should -Be 'OK'
    }
    It 'a stale snapshot cannot confirm support: <State> becomes MANUAL' -ForEach @(@{ State = 'Supported' }, @{ State = 'SecurityOnly' }) {
        $r = ConvertTo-EolStaleDecision (New-Decision $State 'OK') $script:Stale
        $r.Status | Should -Be 'MANUAL'; $r.State | Should -Be 'Unconfirmed'; $r.Text | Should -Match '12 months old'
    }
    It 'a stale snapshot still shows <State>, with the age' -ForEach @(@{ State = 'EndOfLife'; Status = 'WARNING' }, @{ State = 'EndingSoon'; Status = 'INFO' }) {
        $r = ConvertTo-EolStaleDecision (New-Decision $State $Status) $script:Stale
        $r.Status | Should -Be $Status; $r.State | Should -Be $State; $r.Text | Should -Match 'limit 6'
    }
    It 'an unknown snapshot date is treated like a stale one' {
        $r = ConvertTo-EolStaleDecision (New-Decision 'Supported' 'OK') ([pscustomobject]@{ State = 'Unknown'; Months = $null; Text = 'The snapshot has no usable date.' })
        $r.Status | Should -Be 'MANUAL'
    }
}

Describe 'Test-EolSnapshotFile' {
    BeforeAll {
        function New-ShippedSnapshot([string]$Path, [string]$AsOf = '2026-10-01', [string[]]$Leave = @(), [hashtable]$Override = @{}) {
            $products = @{}
            foreach ($slug in $script:EolProducts.Keys) { if ($Leave -notcontains $slug) { $products[$slug] = @((New-Cycle '1' '2030-01-01')) } }
            $s = New-EolSnapshotObject -Products $products -AsOf $AsOf
            foreach ($k in $Override.Keys) { $s[$k] = $Override[$k] }
            [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $s -Depth 6), (New-Object Text.UTF8Encoding($false)))
        }
        $script:Dir = Join-Path $TestDrive 'shipped'; New-Item -ItemType Directory -Path $script:Dir | Out-Null
    }
    It 'a complete, recent snapshot passes' {
        $p = Join-Path $script:Dir 'ok.json'; New-ShippedSnapshot $p
        $r = Test-EolSnapshotFile -Path $p -Today ([datetime]'2026-10-23')
        $r.Ok | Should -BeTrue; $r.Age.State | Should -Be 'Fresh'
    }
    It 'an old snapshot is stale, which the release refuses' {
        $p = Join-Path $script:Dir 'old.json'; New-ShippedSnapshot $p -AsOf '2026-03-01'
        $r = Test-EolSnapshotFile -Path $p -Today ([datetime]'2026-10-23') -MaxAgeMonths 6
        $r.Age.State | Should -Be 'Stale'; $r.Age.Text | Should -Match 'limit 6'
    }
    It 'the age limit follows MaxAgeMonths' {
        $p = Join-Path $script:Dir 'limit.json'; New-ShippedSnapshot $p -AsOf '2026-03-01'
        (Test-EolSnapshotFile -Path $p -Today ([datetime]'2026-10-23') -MaxAgeMonths 12).Age.State | Should -Be 'Fresh'
    }
    It 'a product without releases is named' {
        $p = Join-Path $script:Dir 'partial.json'; New-ShippedSnapshot $p -Leave @('php')
        $r = Test-EolSnapshotFile -Path $p -Today ([datetime]'2026-10-23')
        $r.Ok | Should -BeFalse; ($r.Problems -join ' ') | Should -Match 'No releases for php'
    }
    It 'a missing licence notice is a problem' {
        $p = Join-Path $script:Dir 'nolicence.json'; New-ShippedSnapshot $p -Override @{ licenseNotice = $null }
        (Test-EolSnapshotFile -Path $p -Today ([datetime]'2026-10-23')).Problems -join ' ' | Should -Match 'licence notice'
    }
    It 'no date is a problem and counts as too old' {
        $p = Join-Path $script:Dir 'nodate.json'; New-ShippedSnapshot $p -AsOf ''
        $r = Test-EolSnapshotFile -Path $p -Today ([datetime]'2026-10-23')
        $r.Ok | Should -BeFalse; $r.Age.State | Should -Be 'Unknown'
    }
    It 'text that is not JSON is a problem' {
        $p = Join-Path $script:Dir 'bad.json'; Set-Content -LiteralPath $p -Value 'not json {'
        $r = Test-EolSnapshotFile -Path $p
        $r.Ok | Should -BeFalse; $r.Problems[0] | Should -Match 'not valid JSON'
    }
    It 'a missing file is a problem' {
        $r = Test-EolSnapshotFile -Path (Join-Path $script:Dir 'nothing.json')
        $r.Ok | Should -BeFalse; $r.Age.State | Should -Be 'Unknown'
    }
    It 'the snapshot committed in data/ has the structure the release needs (age is checked at release time)' {
        $r = Test-EolSnapshotFile -Path (Join-Path $PSScriptRoot '..\src\eol-snapshot.json')
        $r.Problems | Should -BeNullOrEmpty
    }
}

Describe 'Get-EolRefreshDecision' {
    BeforeAll {
        function New-Doc([string]$AsOf, [string]$Eol) { [pscustomobject]@{ asOf = $AsOf; products = [pscustomobject]@{ php = @([pscustomobject]@{ cycle = '8.4'; eol = $Eol }) } } }
        $script:T = [datetime]'2026-10-23'
    }
    It 'changed data opens a pull request' { (Get-EolRefreshDecision (New-Doc '2026-10-01' '2028-12-31') (New-Doc '2026-10-23' '2027-12-31') $script:T).Action | Should -Be 'PullRequest' }
    It 'unchanged data does nothing' {
        $r = Get-EolRefreshDecision (New-Doc '2026-10-01' '2028-12-31') (New-Doc '2026-10-23' '2028-12-31') $script:T
        $r.Action | Should -Be 'None'
    }
    It 'unchanged data with an old date renews the date' {
        $r = Get-EolRefreshDecision (New-Doc '2026-06-01' '2028-12-31') (New-Doc '2026-10-23' '2028-12-31') $script:T
        $r.Action | Should -Be 'PullRequest'; $r.Reason | Should -Match 'renew'
    }
    It 'the renewal age follows KeepDays' { (Get-EolRefreshDecision (New-Doc '2026-06-01' '2028-12-31') (New-Doc '2026-10-23' '2028-12-31') $script:T -KeepDays 200).Action | Should -Be 'None' }
    It 'no current snapshot opens a pull request' { (Get-EolRefreshDecision $null (New-Doc '2026-10-23' '2028-12-31') $script:T).Action | Should -Be 'PullRequest' }
    It 'a current snapshot without a date renews it' { (Get-EolRefreshDecision (New-Doc '' '2028-12-31') (New-Doc '2026-10-23' '2028-12-31') $script:T).Action | Should -Be 'PullRequest' }
}

Describe 'Save-EolSnapshot' {
    BeforeEach { $script:OutPath = Join-Path ([IO.Path]::GetTempPath()) ('eol-out-' + [guid]::NewGuid().ToString('N') + '.json') }
    AfterEach { Remove-Item -LiteralPath $script:OutPath -ErrorAction SilentlyContinue }
    It 'writes every product and names the one that failed' {
        Mock Get-EolOnlineRelease { if ($Product -eq 'php') { throw 'HTTP 503' }; [pscustomobject]@{ Cycles = @([pscustomobject]@{ cycle = '1'; eol = $false }); Source = 'endoflife.date'; AsOf = '2026-10-23' } }
        $r = Save-EolSnapshot -Path $script:OutPath -Today ([datetime]'2026-10-23')
        $r.Failed.Count | Should -Be 1; $r.Failed[0] | Should -Match '^php: HTTP 503'
        $r.Written | Should -Not -Contain 'php'; $r.Written.Count | Should -Be ($script:EolProducts.Count - 1)
        $back = Get-EolSnapshotRelease -Product 'nginx' -SnapshotPath $script:OutPath
        $back.AsOf | Should -Be '2026-10-23'; @($back.Cycles).Count | Should -Be 1
        Get-EolSnapshotRelease -Product 'php' -SnapshotPath $script:OutPath | Should -BeNullOrEmpty
    }
    It 'the file starts without a byte-order mark' {
        Mock Get-EolOnlineRelease { [pscustomobject]@{ Cycles = @([pscustomobject]@{ cycle = '1'; eol = $false }); Source = 'endoflife.date'; AsOf = '2026-10-23' } }
        [void](Save-EolSnapshot -Path $script:OutPath -Today ([datetime]'2026-10-23'))
        [IO.File]::ReadAllBytes($script:OutPath)[0] | Should -Be 123
    }
    It 'a folder as the path gets eol-snapshot.json inside it' {
        Mock Get-EolOnlineRelease { [pscustomobject]@{ Cycles = @([pscustomobject]@{ cycle = '1'; eol = $false }); Source = 'endoflife.date'; AsOf = '2026-10-23' } }
        $dir = Join-Path ([IO.Path]::GetTempPath()) ('eol-dir-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            $r = Save-EolSnapshot -Path $dir -Today ([datetime]'2026-10-23')
            $r.Path | Should -Be (Join-Path $dir 'eol-snapshot.json')
            Test-Path -LiteralPath (Join-Path $dir 'eol-snapshot.json') | Should -BeTrue
        } finally { Remove-Item -LiteralPath $dir -Recurse -ErrorAction SilentlyContinue }
    }
    It 'a folder that does not exist is an error, not a result' {
        Mock Get-EolOnlineRelease { [pscustomobject]@{ Cycles = @(); Source = 'endoflife.date'; AsOf = '2026-10-23' } }
        { Save-EolSnapshot -Path (Join-Path ([IO.Path]::GetTempPath()) ('no-such-' + [guid]::NewGuid().ToString('N') + '\x.json')) -Today ([datetime]'2026-10-23') } | Should -Throw '*does not exist*'
    }
    It 'a write that fails is an error, never a result' {
        Mock Get-EolOnlineRelease { [pscustomobject]@{ Cycles = @([pscustomobject]@{ cycle = '1'; eol = $false }); Source = 'endoflife.date'; AsOf = '2026-10-23' } }
        $locked = Join-Path ([IO.Path]::GetTempPath()) ('eol-lock-' + [guid]::NewGuid().ToString('N') + '.json')
        $fs = [IO.File]::Open($locked, 'Create', 'ReadWrite', 'None')
        try { { Save-EolSnapshot -Path $locked -Today ([datetime]'2026-10-23') } | Should -Throw '*Could not write the snapshot*' }
        finally { $fs.Dispose(); Remove-Item -LiteralPath $locked -ErrorAction SilentlyContinue }
    }
    It 'no product at all is an error and writes nothing' {
        Mock Get-EolOnlineRelease { throw 'offline' }
        { Save-EolSnapshot -Path $script:OutPath -Today ([datetime]'2026-10-23') } | Should -Throw '*No product could be fetched*'
        Test-Path -LiteralPath $script:OutPath | Should -BeFalse
    }
}
