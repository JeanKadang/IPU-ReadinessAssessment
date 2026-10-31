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
    It 'does not accept another version, and handles none installed' {
        Test-ModuleInstalled -Installed @([pscustomobject]@{ Version = [version]'5.5.0' }) -RequiredVersion '5.7.1' | Should -BeFalse
        Test-ModuleInstalled -Installed @() -RequiredVersion '5.7.1' | Should -BeFalse
        Test-ModuleInstalled -Installed $null -RequiredVersion '5.7.1' | Should -BeFalse
    }
}
