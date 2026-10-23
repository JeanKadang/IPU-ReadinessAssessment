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
