# Pester 5 tests. The post-upgrade run: reading the baseline, coverage, keeping the earlier baseline.
# The script is loaded in library mode by ..\TestSetup.ps1: functions only, nothing is collected.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
param()

BeforeAll { . (Join-Path $PSScriptRoot '..\TestSetup.ps1') }

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'Invoke-PostUpgradeComparison (#34)' {
    BeforeAll {
        function Set-PostScenario {
            param([string]$NowRelease = '2025', [string]$BaselinePath = '', [hashtable]$Now = @{})
            $script:Results.Clear(); $script:CheckRuns.Clear()
            $script:TargetServerVersion = '2025'
            $script:Data = @{ SourceRelease = $NowRelease }
            $snap = @{ Services = @(); Ports = @('TCP:443'); Routes = @(); IPv4 = @('10.0.0.5'); Dns = @(); Adapters = @(); Hosts = @(); Apps = @(); Features = @(); Tasks = @(); Shares = @(); Printers = @(); PrinterPorts = @(); PrinterDrivers = @() }
            foreach ($k in $Now.Keys) { $snap[$k] = $Now[$k] }
            $script:Data.Snapshot = $snap
            $script:BaselinePath = $BaselinePath
        }
        function Save-Baseline {
            param([string]$Path, [bool]$Partial = $false, [hashtable]$Snapshot = @{}, [hashtable]$Extra = @{}, [string[]]$NotCompleted = @())
            $snap = @{ Services = @(); Ports = @('TCP:443'); Routes = @(); IPv4 = @('10.0.0.5'); Dns = @(); Adapters = @(); Hosts = @(); Apps = @(); Features = @(); Tasks = @(); Shares = @(); Printers = @(); PrinterPorts = @(); PrinterDrivers = @() }
            foreach ($k in $Snapshot.Keys) { $snap[$k] = $Snapshot[$k] }
            $runs = @('baseline', 'ports', 'network', 'tasks', 'fileshares', 'printers') | ForEach-Object { [pscustomobject]@{ Id = $_; Outcome = $(if ($NotCompleted -contains $_) { 'Failed' } else { 'Completed' }) } }
            $o = [ordered]@{ Schema = 'IPU-Assessment/1'; Mode = 'Pre'; ComputerName = $env:COMPUTERNAME; CollectorVersion = '4.0.1'; Completed = '2026-10-01 10:00:00'; Overall = 'WARNING'; Partial = $Partial
                Facts = [pscustomobject]@{ CurrentOS = 'Windows Server 2022 Standard' }; CheckRuns = @($runs); Results = @(); Snapshot = [pscustomobject]$snap }
            foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] }
            [pscustomobject]$o | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
        }
        function Get-Row([string]$Item) { @($script:Results | Where-Object { $_.Item -eq $Item }) }
    }
    AfterAll { $script:TargetServerVersion = '2025'; $script:Data = @{} }

    It 'target not reached gives an ACTION naming the Setup logs' {
        Set-PostScenario -NowRelease '2022' -BaselinePath (Join-Path $TestDrive 'none.json')
        Invoke-PostUpgradeComparison
        $r = Get-Row 'UpgradeReachedTarget'
        $r[0].Status | Should -Be 'ACTION'
        $r[0].Recommendation | Should -Match 'setuperr\.log'
        $r[0].Recommendation | Should -Match '\$WINDOWS\.~BT'
    }
    It 'missing baseline gives a MANUAL finding naming the expected path' {
        $path = Join-Path $TestDrive 'SRV-IPU-Assessment.json'
        Set-PostScenario -BaselinePath $path
        Invoke-PostUpgradeComparison
        $r = Get-Row 'Baseline'
        $r[0].Status | Should -Be 'MANUAL'
        $r[0].Kind | Should -Be 'Finding'
        $r[0].Details | Should -Be $path
        $script:CheckRuns[-1].Outcome | Should -Be 'Completed'
    }
    It 'a Partial baseline gives a WARNING Observation, not a Finding' {
        $path = Join-Path $TestDrive 'partial.json'
        Save-Baseline -Path $path -Partial $true
        Set-PostScenario -BaselinePath $path
        Invoke-PostUpgradeComparison
        $r = Get-Row 'BaselineComplete'
        $r[0].Status | Should -Be 'WARNING'
        $r[0].Kind | Should -Be 'Observation'
    }
    It 'no differences gives an OK comparison' {
        $path = Join-Path $TestDrive 'same.json'
        Save-Baseline -Path $path
        Set-PostScenario -BaselinePath $path
        Invoke-PostUpgradeComparison
        (Get-Row 'UpgradeReachedTarget')[0].Status | Should -Be 'OK'
        (Get-Row 'Comparison')[0].Status | Should -Be 'OK'
        @($script:Results | Where-Object { $_.Kind -eq 'Finding' -and $_.Status -ne 'OK' }).Count | Should -Be 0
    }
    It 'an empty baseline snapshot is MANUAL, never a clean comparison (#239)' {
        $path = Join-Path $TestDrive 'empty-snapshot.json'
        [pscustomobject]@{ Schema = 'IPU-Assessment/1'; Mode = 'Pre'; ComputerName = $env:COMPUTERNAME; Completed = '2026-10-01 10:00:00'; Partial = $false; Snapshot = [pscustomobject]@{} } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -Encoding UTF8
        Set-PostScenario -BaselinePath $path
        Invoke-PostUpgradeComparison
        (Get-Row 'BaselineSnapshot')[0].Status | Should -Be 'MANUAL'
        (Get-Row 'Comparison').Count | Should -Be 0
    }
    It 'a list whose check did not complete is not compared (#239)' {
        $path = Join-Path $TestDrive 'network-failed.json'
        Save-Baseline -Path $path -NotCompleted @('network')
        Set-PostScenario -BaselinePath $path
        Invoke-PostUpgradeComparison
        $r = Get-Row 'BaselineCoverage'
        $r[0].Status | Should -Be 'MANUAL'; $r[0].Kind | Should -Be 'Finding'
        (@($r[0].Details) -join ' ') | Should -Match 'Routes \(the network check failed\)'
        (@($r[0].Details) -join ' ') | Should -Not -Match 'Ports'
        (Get-Row 'Comparison').Count | Should -Be 0
    }
    It 'a SPECIAL short report as baseline leaves out what it never collected (#239)' {
        $path = Join-Path $TestDrive 'special.json'
        Save-Baseline -Path $path -Extra @{ Special = [pscustomobject]@{ Kind = 'Cluster'; Title = 'Cluster node' } }
        Set-PostScenario -BaselinePath $path
        Invoke-PostUpgradeComparison
        $text = (@((Get-Row 'BaselineCoverage')[0].Details) -join ' ')
        $text | Should -Match 'Ports \(the Pre run was a SPECIAL short report\)'
        $text | Should -Not -Match 'Services \('
        (Get-Row 'Comparison').Count | Should -Be 0
    }
    It 'a baseline taken after the upgrade is MANUAL (#239)' {
        $path = Join-Path $TestDrive 'after.json'
        $row = [pscustomobject]@{ Area = 'UPGRADE_PATH'; Item = 'CurrentOS'; Details = @('Build=26100.1', 'Release=Windows Server 2025', 'Architecture=64-bit') }
        Save-Baseline -Path $path -Extra @{ Results = @($row) }
        Set-PostScenario -BaselinePath $path
        Invoke-PostUpgradeComparison
        (Get-Row 'BaselineAfterUpgrade')[0].Status | Should -Be 'MANUAL'
        (Get-Row 'Comparison').Count | Should -Be 0
    }
    It 'a baseline from another server is MANUAL (#239)' {
        $path = Join-Path $TestDrive 'other-server.json'
        Save-Baseline -Path $path -Extra @{ ComputerName = 'SOME-OTHER-SERVER' }
        Set-PostScenario -BaselinePath $path
        Invoke-PostUpgradeComparison
        (Get-Row 'BaselineValid')[0].Value | Should -Match 'another server'
        (Get-Row 'Comparison').Count | Should -Be 0
    }
    It 'differences become findings in the comparison area' {
        $path = Join-Path $TestDrive 'diff.json'
        Save-Baseline -Path $path -Snapshot @{ Ports = @('TCP:443', 'TCP:1433'); Routes = @('10.50.0.0/16 via 10.0.0.1') }
        Set-PostScenario -BaselinePath $path
        Invoke-PostUpgradeComparison
        (Get-Row 'Static routes missing after upgrade')[0].Status | Should -Be 'ACTION'
        (Get-Row 'Listening ports missing after upgrade')[0].Details | Should -Be 'TCP:1433'
        (Get-Row 'Comparison').Count | Should -Be 0
    }
    It 'a list this run could not read is not reported as lost (#306)' {
        $path = Join-Path $TestDrive 'routes-now-unread.json'
        Save-Baseline -Path $path -Snapshot @{ Routes = @('10.50.0.0/16 via 10.0.0.1') }
        Set-PostScenario -BaselinePath $path
        $script:Data.Snapshot.Remove('Routes')
        Invoke-PostUpgradeComparison
        (Get-Row 'Static routes missing after upgrade').Count | Should -Be 0
        $r = Get-Row 'CurrentCoverage'
        $r[0].Status | Should -Be 'MANUAL'; $r[0].Kind | Should -Be 'Finding'
        (@($r[0].Details) -join ' ') | Should -Match 'Routes \(this run could not read it\)'
        (Get-Row 'Comparison').Count | Should -Be 0
    }
    It 'a list whose check failed in this run is not reported as lost (#306)' {
        $path = Join-Path $TestDrive 'tasks-now-failed.json'
        Save-Baseline -Path $path -Snapshot @{ Tasks = @('\Vendor\Nightly export') }
        Set-PostScenario -BaselinePath $path
        $script:CheckRuns.Add([pscustomobject]@{ Id = 'tasks'; Outcome = 'Failed' })
        Invoke-PostUpgradeComparison
        (Get-Row 'Scheduled tasks missing after upgrade').Count | Should -Be 0
        (@((Get-Row 'CurrentCoverage')[0].Details) -join ' ') | Should -Match 'Tasks \(the tasks check failed in this run\)'
    }
    It 'GPOs and AD groups this run could not read are not reported as lost (#306)' {
        $path = Join-Path $TestDrive 'gpos-now-unread.json'
        Save-Baseline -Path $path -Snapshot @{ Gpos = @('Server baseline'); Groups = @('Patch ring 2') }
        Set-PostScenario -BaselinePath $path
        Invoke-PostUpgradeComparison
        (Get-Row 'Applied GPOs missing after upgrade').Count | Should -Be 0
        (Get-Row 'AD groups missing after upgrade').Count | Should -Be 0
        $text = (@((Get-Row 'CurrentCoverage')[0].Details) -join ' ')
        $text | Should -Match 'Gpos'
        $text | Should -Match 'Groups'
    }
    It 'lists that were read are still compared next to one that was not (#306)' {
        $path = Join-Path $TestDrive 'mixed.json'
        Save-Baseline -Path $path -Snapshot @{ Ports = @('TCP:443', 'TCP:1433'); Routes = @('10.50.0.0/16 via 10.0.0.1') }
        Set-PostScenario -BaselinePath $path
        $script:Data.Snapshot.Remove('Routes')
        Invoke-PostUpgradeComparison
        (Get-Row 'Listening ports missing after upgrade')[0].Details | Should -Be 'TCP:1433'
        (Get-Row 'Static routes missing after upgrade').Count | Should -Be 0
    }
    It 'an error becomes a MANUAL finding and a Failed check run' {
        $path = Join-Path $TestDrive 'broken.json'
        Set-Content -LiteralPath $path -Value '{ this is not json'
        Set-PostScenario -BaselinePath $path
        Invoke-PostUpgradeComparison
        $r = Get-Row 'Post-upgrade comparison'
        $r[0].Status | Should -Be 'MANUAL'
        $r[0].Area | Should -Be 'COLLECTOR'
        $script:CheckRuns[-1].Id | Should -Be 'postcompare'
        $script:CheckRuns[-1].Outcome | Should -Be 'Failed'
        $script:CurrentCheckId | Should -Be 'core'
    }
}

Describe 'Test-BaselineKeepCopy (#239)' {
    BeforeAll {
        function New-ExistingBaseline([bool]$Partial, [string]$Release) {
            $row = [pscustomobject]@{ Area = 'UPGRADE_PATH'; Item = 'CurrentOS'; Details = @('Build=1', ('Release=' + $Release), 'Architecture=64-bit') }
            [pscustomobject]@{ Partial = $Partial; Snapshot = [pscustomobject]@{ Services = @() }; Results = @($row) }
        }
    }
    It 'nothing to keep when there is no earlier file' { Test-BaselineKeepCopy $null $false 'Windows Server 2016' | Should -BeFalse }
    It 'a complete baseline is kept before a checkpoint replaces it' { Test-BaselineKeepCopy (New-ExistingBaseline $false 'Windows Server 2016') $true 'Windows Server 2016' | Should -BeTrue }
    It 'a complete baseline is kept when the new run is on another release' { Test-BaselineKeepCopy (New-ExistingBaseline $false 'Windows Server 2016') $false 'Windows Server 2025' | Should -BeTrue }
    It 'a complete baseline of the same release is replaced by a complete run' { Test-BaselineKeepCopy (New-ExistingBaseline $false 'Windows Server 2016') $false 'Windows Server 2016' | Should -BeFalse }
    It 'an earlier partial result is not worth keeping' { Test-BaselineKeepCopy (New-ExistingBaseline $true 'Windows Server 2016') $true 'Windows Server 2016' | Should -BeFalse }
}

Describe 'Write-AssessmentJson keeps the earlier baseline (#239)' {
    BeforeEach {
        $script:KeepDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:KeepDir | Out-Null
        $script:JsonPath = Join-Path $script:KeepDir 'SRV-IPU-Assessment.json'
        $script:BaselinePath = $script:JsonPath
        $script:BaselineKept = $null
        $script:Data = @{ SourceRelease = '2016' }
        $row = [pscustomobject]@{ Area = 'UPGRADE_PATH'; Item = 'CurrentOS'; Details = @('Build=1', 'Release=Windows Server 2016', 'Architecture=64-bit') }
        [pscustomobject]@{ Partial = $false; Snapshot = [pscustomobject]@{ Services = @() }; Results = @($row); Marker = 'ORIGINAL' } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:JsonPath -Encoding UTF8
        Mock New-AssessmentJsonObject { [pscustomobject]@{ Marker = 'NEW'; Redacted = $false } }
    }
    It 'a checkpoint keeps the complete baseline as a dated copy and replaces the file' {
        Write-AssessmentJson -Results @() -Overall 'OK' -Completed (Get-Date) -Partial
        @(Get-ChildItem -LiteralPath $script:KeepDir -Filter 'SRV-IPU-Assessment-*.json').Count | Should -Be 1
        (Get-Content -LiteralPath $script:JsonPath -Raw | ConvertFrom-Json).Marker | Should -Be 'NEW'
        $kept = Get-ChildItem -LiteralPath $script:KeepDir -Filter 'SRV-IPU-Assessment-*.json' | Select-Object -First 1
        (Get-Content -LiteralPath $kept.FullName -Raw | ConvertFrom-Json).Marker | Should -Be 'ORIGINAL'
    }
    It 'only one copy per run, even though the final write follows the checkpoint' {
        Write-AssessmentJson -Results @() -Overall 'OK' -Completed (Get-Date) -Partial
        Write-AssessmentJson -Results @() -Overall 'OK' -Completed (Get-Date)
        @(Get-ChildItem -LiteralPath $script:KeepDir -Filter 'SRV-IPU-Assessment-*.json').Count | Should -Be 1
    }
    It 'a Post run never touches the baseline' {
        $AssessmentMode = 'Post'
        Write-AssessmentJson -Results @() -Overall 'OK' -Completed (Get-Date) -Partial
        @(Get-ChildItem -LiteralPath $script:KeepDir -Filter 'SRV-IPU-Assessment-*.json').Count | Should -Be 0
    }
}
