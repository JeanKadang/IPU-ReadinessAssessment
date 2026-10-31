# Pester 5 tests for the helper functions of the build scripts (#141, #140). The
# scripts are dot-sourced for their functions only; nothing is installed or run.

BeforeAll {
    $script:Build = Join-Path (Split-Path -Parent $PSScriptRoot) 'build'
    . (Join-Path $script:Build 'Install-CiModule.ps1') -Name Dummy -RequiredVersion 1.0.0
}

Describe 'Invoke-WithRetry (#141)' {
    BeforeEach {
        $script:Lines = New-Object Collections.Generic.List[string]
        $script:Sleeps = New-Object Collections.Generic.List[int]
        $script:Report = { param($Line) $script:Lines.Add($Line) }
        $script:Sleep = { param($Seconds) $script:Sleeps.Add($Seconds) }
        $script:Calls = 0
    }
    It 'runs once and does not wait when the first attempt works' {
        $n = Invoke-WithRetry -Label 'Install X' -Action { $script:Calls++ } -Report $script:Report -Sleep $script:Sleep
        $n | Should -Be 1
        $script:Calls | Should -Be 1
        $script:Sleeps.Count | Should -Be 0
        $script:Lines.Count | Should -Be 1
        $script:Lines[0] | Should -Be 'Install X: attempt 1 of 3'
    }
    It 'tries again after a failure, waits between attempts and says so in the log' {
        $n = Invoke-WithRetry -Label 'Install X' -DelaySeconds 7 -Report $script:Report -Sleep $script:Sleep -Action {
            $script:Calls++
            if ($script:Calls -lt 3) { throw 'End of Central Directory record could not be found.' }
        }
        $n | Should -Be 3
        $script:Calls | Should -Be 3
        @($script:Sleeps) | Should -Be @(7, 7)
        @($script:Lines | Where-Object { $_ -like '*attempt * of 3' }).Count | Should -Be 3
        ($script:Lines -join "`n") | Should -Match 'attempt 1 failed \(End of Central Directory record could not be found\.\); trying again in 7 s'
    }
    It 'throws the last failure unchanged after the last attempt and does not wait after it' {
        { Invoke-WithRetry -Label 'Install X' -Attempts 3 -Report $script:Report -Sleep $script:Sleep -Action { $script:Calls++; throw "failure $script:Calls" } } | Should -Throw 'failure 3'
        $script:Calls | Should -Be 3
        $script:Sleeps.Count | Should -Be 2
    }
    It 'one attempt means no retry and no wait' {
        { Invoke-WithRetry -Label 'Install X' -Attempts 1 -Report $script:Report -Sleep $script:Sleep -Action { $script:Calls++; throw 'boom' } } | Should -Throw 'boom'
        $script:Calls | Should -Be 1
        $script:Sleeps.Count | Should -Be 0
    }
    It 'works with the default report and sleep (no wait when it works first time)' {
        Invoke-WithRetry -Label 'Install X' -Action { $script:Calls++ } 6>$null | Should -Be 1
    }
}

Describe 'Test-ModuleInstalled (#141)' {
    It 'finds the exact pinned version among several' {
        $installed = @([pscustomobject]@{ Version = [version]'5.5.0' }, [pscustomobject]@{ Version = [version]'5.7.1' })
        Test-ModuleInstalled -Installed $installed -RequiredVersion '5.7.1' | Should -BeTrue
    }
    It 'accepts a newer version only with -OrNewer' {
        $installed = @([pscustomobject]@{ Version = [version]'5.8.0' })
        Test-ModuleInstalled -Installed $installed -RequiredVersion '5.7.1' | Should -BeFalse
        Test-ModuleInstalled -Installed $installed -RequiredVersion '5.7.1' -OrNewer | Should -BeTrue
        Test-ModuleInstalled -Installed @([pscustomobject]@{ Version = [version]'5.5.0' }) -RequiredVersion '5.7.1' -OrNewer | Should -BeFalse
    }
    It 'does not accept another version, and handles none installed' {
        Test-ModuleInstalled -Installed @([pscustomobject]@{ Version = [version]'5.5.0' }) -RequiredVersion '5.7.1' | Should -BeFalse
        Test-ModuleInstalled -Installed @() -RequiredVersion '5.7.1' | Should -BeFalse
        Test-ModuleInstalled -Installed $null -RequiredVersion '5.7.1' | Should -BeFalse
    }
}

Describe 'build/Invoke-Local.ps1 (#140)' {
    BeforeAll {
        . (Join-Path $script:Build 'Invoke-Local.ps1')
        $script:Workflow = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $script:Build) '.github/workflows/ci.yml'))
    }
    Context 'Resolve-LocalTask' {
        It 'runs the tasks once each, in the order CI runs them' {
            @(Resolve-LocalTask -Task 'Test', 'Lint', 'Test') | Should -Be @('Lint', 'Test')
        }
        It 'All is every task' {
            @(Resolve-LocalTask -Task 'All') | Should -Be @('Lint', 'Test', 'Smoke', 'Sample')
        }
        It 'All together with a single task is still every task, once' {
            @(Resolve-LocalTask -Task 'Smoke', 'All').Count | Should -Be 4
        }
    }
    Context 'Get-CiToolVersion and Get-CiCoverageFloor' {
        It 'read the pinned version and the coverage floor from the workflow text' {
            $text = "env:`n  PESTER_VERSION: 5.7.1`n  PSSA_VERSION: 1.23.0`n    run: ./build/Invoke-CiTests.ps1 -Coverage -MinimumCoverage 85 } else"
            Get-CiToolVersion -WorkflowText $text -Variable 'PESTER_VERSION' | Should -Be '5.7.1'
            Get-CiToolVersion -WorkflowText $text -Variable 'PSSA_VERSION' | Should -Be '1.23.0'
            Get-CiCoverageFloor -WorkflowText $text | Should -Be 85
        }
        It 'say what is missing instead of guessing' {
            { Get-CiToolVersion -WorkflowText 'env:' -Variable 'PESTER_VERSION' } | Should -Throw '*PESTER_VERSION is not set*'
            { Get-CiCoverageFloor -WorkflowText 'nothing' } | Should -Throw '*MinimumCoverage*'
        }
        It 'find both pins and the floor in the real ci.yml' {
            Get-CiToolVersion -WorkflowText $script:Workflow -Variable 'PESTER_VERSION' | Should -Match '^\d+\.\d+\.\d+$'
            Get-CiToolVersion -WorkflowText $script:Workflow -Variable 'PSSA_VERSION' | Should -Match '^\d+\.\d+\.\d+$'
            Get-CiCoverageFloor -WorkflowText $script:Workflow | Should -BeGreaterThan 0
        }
    }
    Context 'Get-LocalWarning' {
        It 'warns when the session is not elevated' {
            @(Get-LocalWarning -IsElevated $false -Task 'Lint' -HasPowerShell7 $true).Count | Should -Be 1
            @(Get-LocalWarning -IsElevated $false -Task 'Lint' -HasPowerShell7 $true)[0] | Should -Match 'not elevated'
        }
        It 'is silent when elevated and nothing is missing' {
            @(Get-LocalWarning -IsElevated $true -Task 'Lint', 'Test' -HasPowerShell7 $false).Count | Should -Be 0
        }
        It 'warns that the smoke test needs PowerShell 7' {
            @(Get-LocalWarning -IsElevated $true -Task 'Smoke' -HasPowerShell7 $false)[0] | Should -Match 'PowerShell 7'
            @(Get-LocalWarning -IsElevated $true -Task 'Smoke' -HasPowerShell7 $true).Count | Should -Be 0
        }
    }
    Context 'Format-LocalSummary' {
        It 'lists each task with its result and says all passed' {
            $lines = Format-LocalSummary -Results @(
                [pscustomobject]@{ Name = 'Lint'; Passed = $true; Seconds = 12.34; Note = '' },
                [pscustomobject]@{ Name = 'Test'; Passed = $true; Seconds = 80.0; Note = '' })
            ($lines -join "`n") | Should -Match 'PASS  Lint'
            ($lines -join "`n") | Should -Match 'PASS  Test'
            $lines[-1] | Should -Be 'All tasks passed.'
        }
        It 'names the failed tasks and the step that failed' {
            $lines = Format-LocalSummary -Results @(
                [pscustomobject]@{ Name = 'Lint'; Passed = $false; Seconds = 3; Note = 'PSScriptAnalyzer' },
                [pscustomobject]@{ Name = 'Test'; Passed = $true; Seconds = 9; Note = '' })
            ($lines -join "`n") | Should -Match 'FAIL  Lint\s+3\.0 s  PSScriptAnalyzer'
            $lines[-1] | Should -Be 'Failed: Lint.'
        }
    }
}
