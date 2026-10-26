# Pester 5 tests. Runtime: the check runner, native tools, time limits, output folders, the SA result line, prerequisites, relaunch.
# The script is loaded in library mode by ..\TestSetup.ps1: functions only, nothing is collected.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
param()

BeforeAll { . (Join-Path $PSScriptRoot '..\TestSetup.ps1') }

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'ConvertFrom-NativeByteArray' {
    It 'decodes UTF-16LE without BOM (sfc.exe style)' {
        $bytes = [Text.Encoding]::Unicode.GetBytes('Windows Resource Protection')
        ConvertFrom-NativeByteArray $bytes | Should -Be 'Windows Resource Protection'
    }
    It 'decodes single-byte output (dism.exe style)' {
        ConvertFrom-NativeByteArray ([Text.Encoding]::ASCII.GetBytes('No component store corruption detected.')) | Should -Be 'No component store corruption detected.'
    }
    It 'strips control characters' {
        ConvertFrom-NativeByteArray ([byte[]](0x41,0x08,0x42)) | Should -Be 'AB'
    }
}

Describe 'Check runner' {
    BeforeEach { $script:Results.Clear(); $script:CheckRuns.Clear() }
    It 'records a throwing check as Failed with a MANUAL finding' {
        $check = [pscustomobject]@{ Id='boom'; Name='Exploding check'; Phase='Fast'; Script={ throw 'simulated failure' } }
        Invoke-Check $check
        $script:CheckRuns[0].Outcome | Should -Be 'Failed'
        $f = @($script:Results | Where-Object { $_.Area -eq 'COLLECTOR' })
        $f.Count | Should -Be 1
        $f[0].Status | Should -Be 'MANUAL'
        $f[0].Details | Should -Match 'simulated failure'
    }
    It 'turns non-terminating errors inside a check into failures' {
        $check = [pscustomobject]@{ Id='nt'; Name='Non-terminating'; Phase='Fast'; Script={ Write-Error 'quiet problem'; Add-Result 'STORAGE' 'never' 'OK' } }
        Invoke-Check $check
        $script:CheckRuns[0].Outcome | Should -Be 'Failed'
        @($script:Results | Where-Object { $_.Item -eq 'never' }).Count | Should -Be 0
    }
    It 'records a clean check as Completed' {
        Invoke-Check ([pscustomobject]@{ Id='ok'; Name='Fine'; Phase='Fast'; Script={ Add-Result 'STORAGE' 'x' 'OK' } })
        $script:CheckRuns[0].Outcome | Should -Be 'Completed'
    }
    It 'a break inside a check fails that check and does not end the caller''s loop (#251)' {
        $ran = 0
        foreach ($i in 1..3) {
            Invoke-Check ([pscustomobject]@{ Id="brk$i"; Name='Breaks'; Phase='Fast'; Script={ break } })
            $ran++
        }
        $ran | Should -Be 3
        @($script:CheckRuns | Where-Object { $_.Outcome -eq 'Failed' }).Count | Should -Be 3
        $script:CheckRuns[0].Message | Should -Match 'break or continue'
        @($script:Results | Where-Object { $_.Area -eq 'COLLECTOR' -and $_.Status -eq 'MANUAL' }).Count | Should -Be 3
    }
    It 'a continue inside a check fails that check and does not end the caller''s loop (#251)' {
        $ran = 0
        foreach ($i in 1..3) {
            Invoke-Check ([pscustomobject]@{ Id="cont$i"; Name='Continues'; Phase='Fast'; Script={ continue } })
            $ran++
        }
        $ran | Should -Be 3
        $script:CheckRuns[2].Outcome | Should -Be 'Failed'
    }
    It 'a return inside a check is an ordinary finish' {
        Invoke-Check ([pscustomobject]@{ Id='ret'; Name='Returns'; Phase='Fast'; Script={ Add-Result 'STORAGE' 'r' 'OK'; return } })
        $script:CheckRuns[0].Outcome | Should -Be 'Completed'
    }
}

Describe 'Add-Result requires a named Recommendation' {
    It 'rejects a sixth positional argument' {
        { Add-Result 'STORAGE' 'a' 'OK' 'v' 'd' 'positional recommendation' } | Should -Throw
    }
}

Describe 'Invoke-WithTimeout (#241)' {
    It 'returns what the block returns' { @(Invoke-WithTimeout -TimeoutSec 20 -ScriptBlock { 'a'; 'b' }) -join ',' | Should -Be 'a,b' }
    It 'gives up after the time limit' {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        { Invoke-WithTimeout -TimeoutSec 1 -ScriptBlock { Start-Sleep -Seconds 30 } } | Should -Throw '*Timed out after 1 seconds*'
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 15
    }
    It 'throws an error raised inside the block' {
        { Invoke-WithTimeout -TimeoutSec 20 -ScriptBlock { throw 'boom inside' } } | Should -Throw '*boom inside*'
    }
}

Describe 'Get-CimRequired has a time limit (#241)' -Skip:($env:OS -ne 'Windows_NT') {
    It 'passes OperationTimeoutSec to Get-CimInstance' {
        Mock Get-CimInstance { @() } -ParameterFilter { $OperationTimeoutSec -eq 120 }
        $null = Get-CimRequired 'Win32_BIOS'
        Should -Invoke Get-CimInstance -Times 1 -Exactly -ParameterFilter { $OperationTimeoutSec -eq 120 }
    }
}

Describe 'Resolve-NumberCulture (#139)' {
    It 'a culture this server knows is used' {
        $r = Resolve-NumberCulture 'da-DK'
        $r.Known | Should -BeTrue; $r.Culture.Name | Should -Be 'da-DK'
    }
    It 'the case of the name does not matter' { (Resolve-NumberCulture 'DA-dk').Known | Should -BeTrue }
    It '<Name> is not known: invariant culture and Known = false' -ForEach @(
        @{ Name = 'xx-INVALID' }, @{ Name = 'not a culture' }, @{ Name = '' }, @{ Name = 'da_DK' }
    ) {
        $r = Resolve-NumberCulture $Name
        $r.Known | Should -BeFalse
        $r.Culture.Name | Should -Be ''
    }
}

Describe 'New-RestrictedFolder (#139)' -Skip:($env:OS -ne 'Windows_NT') {
    It 'creates the folder with an access list that leaves out Users from the start' {
        $p = Join-Path $TestDrive ('restricted-' + [guid]::NewGuid().ToString('N'))
        New-RestrictedFolder $p
        $p | Should -Exist
        $sids = @((Get-Acl -LiteralPath $p).GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value })
        $sids | Should -Contain 'S-1-5-18'
        $sids | Should -Contain 'S-1-5-32-544'
        $sids | Should -Not -Contain 'S-1-5-32-545'
        $sids | Should -Not -Contain 'S-1-1-0'
        $sids | Should -Not -Contain 'S-1-5-11'
    }
}

Describe 'Format-UtcOffset (#252)' {
    It '<Hours>h<Minutes>m is <Expected>' -ForEach @(
        @{ Hours = 2; Minutes = 0; Expected = '+02:00' }
        @{ Hours = 0; Minutes = 0; Expected = '+00:00' }
        @{ Hours = -5; Minutes = -30; Expected = '-05:30' }
        @{ Hours = 5; Minutes = 45; Expected = '+05:45' }
        @{ Hours = -8; Minutes = 0; Expected = '-08:00' }
    ) { Format-UtcOffset (New-TimeSpan -Hours $Hours -Minutes $Minutes) | Should -Be $Expected }
}

Describe 'Output folder access (#12)' {
    It 'state <State> with readers <Readers> is <Expected>' -TestCases @(
        @{ State='CreatedRestricted';   Readers=@();          Expected='OK' }
        @{ State='CreatedUnrestricted'; Readers=@();          Expected='WARNING' }
        @{ State='Created';             Readers=@();          Expected='INFO' }
        @{ State='Existing';            Readers=@('Users');   Expected='WARNING' }
        @{ State='Existing';            Readers=@();          Expected='INFO' }
    ) {
        (Get-OutputFolderAccessDecision $State $Readers 'C:\Reports').Status | Should -Be $Expected
    }
    It 'gives the icacls command for an open existing folder, and never counts it as a finding' {
        $d = Get-OutputFolderAccessDecision 'Existing' @('Authenticated Users','Users') 'C:\Reports'
        $d.Kind | Should -Be 'Observation'
        $d.Command | Should -Be 'icacls "C:\Reports" /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F'
        $d.Text | Should -Match 'command shown'
        $d.Text | Should -Match 'Authenticated Users, Users'
    }

    Context 'Initialize-OutputFolder' {
        BeforeEach {
            Mock Set-RestrictedFolderAcl { }
            Mock New-RestrictedFolder { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
        }

        It 'creates a restricted folder in one step, with no later Set-Acl (#139)' {
            $p = Join-Path $TestDrive 'new-restricted'
            Initialize-OutputFolder $p $true | Should -Be 'CreatedRestricted'
            $p | Should -Exist
            Should -Invoke New-RestrictedFolder -Times 1 -Exactly
            Should -Invoke Set-RestrictedFolderAcl -Times 0 -Exactly
        }
        It 'falls back to create + restrict when the one-step create is not possible (#139)' {
            Mock New-RestrictedFolder { throw 'no such overload' }
            $p = Join-Path $TestDrive 'fallback'
            Initialize-OutputFolder $p $true | Should -Be 'CreatedRestricted'
            $p | Should -Exist
            Should -Invoke Set-RestrictedFolderAcl -Times 1 -Exactly
        }
        It 'never touches an existing folder' {
            $p = Join-Path $TestDrive 'existing'
            New-Item -ItemType Directory -Path $p | Out-Null
            Initialize-OutputFolder $p $true | Should -Be 'Existing'
            Should -Invoke Set-RestrictedFolderAcl -Times 0 -Exactly
        }
        It 'keeps inherited permissions when RestrictOutputAcl is off' {
            $p = Join-Path $TestDrive 'opt-out'
            Initialize-OutputFolder $p $false | Should -Be 'Created'
            Should -Invoke Set-RestrictedFolderAcl -Times 0 -Exactly
        }
        It 'reports, rather than fails, when the ACL cannot be set' {
            Mock New-RestrictedFolder { throw 'no such overload' }
            Mock Set-RestrictedFolderAcl { throw 'access denied' }
            $p = Join-Path $TestDrive 'acl-fails'
            Initialize-OutputFolder $p $true | Should -Be 'CreatedUnrestricted'
            $p | Should -Exist
        }
    }

    It 'ignores empty reader lists (no false warning on a clean folder)' {
        (Get-OutputFolderAccessDecision 'Existing' @($null) 'C:\Reports').Status | Should -Be 'INFO'
        (Get-OutputFolderAccessDecision 'Existing' @() 'C:\Reports').Status | Should -Be 'INFO'
    }

    It 'builds a protected ACL with only SYSTEM and Administrators (Windows)' -Skip:($env:OS -ne 'Windows_NT') {
        $sec = New-RestrictedDirectorySecurity -ExtraSids @()
        $sec.AreAccessRulesProtected | Should -BeTrue
        $sids = @($sec.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object { [string]$_.IdentityReference } | Sort-Object)
        ($sids -join ',') | Should -Be 'S-1-5-18,S-1-5-32-544'
    }
    It 'adds extra SIDs only when given (the unelevated test run, #126)' -Skip:($env:OS -ne 'Windows_NT') {
        $sec = New-RestrictedDirectorySecurity -ExtraSids @('S-1-5-21-1-2-3-1001', 'S-1-5-18')
        $sids = @($sec.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object { [string]$_.IdentityReference } | Sort-Object)
        ($sids -join ',') | Should -Be 'S-1-5-18,S-1-5-21-1-2-3-1001,S-1-5-32-544'
        $script:ExtraRestrictedSids.GetType().IsArray | Should -BeTrue
    }
    It 'applies the ACL to a real folder (Windows)' -Skip:($env:OS -ne 'Windows_NT') {
        $p = Join-Path $TestDrive 'real-acl'
        New-Item -ItemType Directory -Path $p | Out-Null
        Set-RestrictedFolderAcl $p
        $acl = Get-Acl -LiteralPath $p
        $acl.AreAccessRulesProtected | Should -BeTrue
        @(Get-BroadFolderReader $p).Count | Should -Be 0
    }
}

Describe 'Hygiene (#18)' {
    Context 'ConvertTo-DateTimeValue' {
        It 'passes a [datetime] through unchanged' {
            $d = Get-Date -Year 2026 -Month 9 -Day 29 -Hour 1 -Minute 10 -Second 22
            ConvertTo-DateTimeValue $d | Should -Be $d
        }
        It 'reads a yyyyMMdd install date' {
            (ConvertTo-DateTimeValue '20260515').ToString('yyyy-MM-dd') | Should -Be '2026-05-15'
        }
        It 'reads an ISO date' {
            (ConvertTo-DateTimeValue '2026-09-28').ToString('yyyy-MM-dd') | Should -Be '2026-09-28'
        }
        It 'reads a WMI DMTF date (Windows)' -Skip:($env:OS -ne 'Windows_NT') {
            (ConvertTo-DateTimeValue '20260929120000.000000+120').ToString('yyyy-MM-dd') | Should -Be '2026-09-29'
        }
        It 'returns nothing for <Value>' -TestCases @(
            @{ Value = $null }
            @{ Value = '' }
            @{ Value = 'not a date' }
        ) {
            ConvertTo-DateTimeValue $Value | Should -BeNullOrEmpty
        }
    }

    Context 'CIM queries' {
        It 'Get-CimSafe returns nothing, instead of throwing, when the query fails' {
            Mock Get-CimRequired { throw 'Invalid class' }
            @(Get-CimSafe 'Win32_DoesNotExist').Count | Should -Be 0
        }
        It 'Get-CimRequired lets the failure through so the check is reported as not completed' {
            Mock Get-CimInstance { throw 'Invalid class' }
            { Get-CimRequired 'Win32_DoesNotExist' } | Should -Throw
        }
    }

    It 'renames Normalize-Thumbprint to an approved verb' {
        Get-Command ConvertTo-NormalizedThumbprint -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Normalize-Thumbprint -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        ConvertTo-NormalizedThumbprint 'ab cd:EF' | Should -Be 'ABCDEF'
    }

    Context 'Parameter validation' {
        BeforeAll { $script:ScriptPath = Join-Path $PSScriptRoot '..\..\src\Windows-IPU-Readiness-Assessment.ps1' }
        It 'rejects <Name> = <Value>' -TestCases @(
            @{ Name = 'MinimumCFreeGB';         Value = 0 }
            @{ Name = 'MinimumCFreeGB';         Value = -5 }
            @{ Name = 'SlowCheckBudgetMinutes'; Value = 0 }
            @{ Name = 'DISMTimeoutMinutes';     Value = 100000 }
            @{ Name = 'ReportDirectory';        Value = 'relative\folder' }
            @{ Name = 'TargetMediaPath';        Value = 'media\iso' }
            @{ Name = 'TargetMediaLanguage';    Value = 'english please' }
        ) {
            $splat = @{ $Name = $Value }
            { & $script:ScriptPath @splat } | Should -Throw
        }
        It 'accepts valid values (library mode returns without collecting)' {
            $splat = @{ MinimumCFreeGB = 40; ReportDirectory = [IO.Path]::GetTempPath(); TargetMediaPath = ''; TargetMediaLanguage = 'en-US' }
            { & $script:ScriptPath @splat } | Should -Not -Throw
        }
    }
}

Describe 'ConvertTo-RelaunchArgumentText (#38)' {
    It 'quotes strings and doubles embedded apostrophes' {
        ConvertTo-RelaunchArgumentText @{ ReportDirectory = "D:\O'Brien" } | Should -Be " -ReportDirectory 'D:\O''Brien'"
    }
    It 'keeps booleans typed' {
        ConvertTo-RelaunchArgumentText @{ WriteJson = $true } | Should -Be ' -WriteJson $true'
        ConvertTo-RelaunchArgumentText @{ RunSFCVerifyOnly = $false } | Should -Be ' -RunSFCVerifyOnly $false'
    }
    It 'passes integers unquoted' {
        ConvertTo-RelaunchArgumentText @{ MinimumCFreeGB = 60 } | Should -Be ' -MinimumCFreeGB 60'
    }
    It 'passes switches with an explicit value' {
        $on = [System.Management.Automation.SwitchParameter]::new($true)
        $off = [System.Management.Automation.SwitchParameter]::new($false)
        ConvertTo-RelaunchArgumentText @{ Demo = $on } | Should -Be ' -Demo:$true'
        ConvertTo-RelaunchArgumentText @{ Demo = $off } | Should -Be ' -Demo:$false'
    }
    It 'orders parameters by name so the command line is predictable' {
        ConvertTo-RelaunchArgumentText ([ordered]@{ Zeta = 'z'; Alpha = 1 }) | Should -Be " -Alpha 1 -Zeta 'z'"
    }
    It 'throws a clear error for an unsupported type' {
        { ConvertTo-RelaunchArgumentText @{ Ratio = [double]1.5 } } | Should -Throw -ExpectedMessage "*Ratio*System.Double*"
        { ConvertTo-RelaunchArgumentText @{ Paths = @('a','b') } } | Should -Throw -ExpectedMessage "*Paths*"
    }
    It 'returns an empty string when no parameters were given' {
        ConvertTo-RelaunchArgumentText @{} | Should -Be ''
        ConvertTo-RelaunchArgumentText $null | Should -Be ''
    }
    It 'produces text that PowerShell parses back to the same values' {
        $text = ConvertTo-RelaunchArgumentText ([ordered]@{ AssessmentMode = 'Post'; MinimumCFreeGB = 60; ReportDirectory = "D:\it's here"; WriteJson = $false })
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput('Test-Cmd' + $text, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
        $values = @($ast.EndBlock.Statements[0].PipelineElements[0].CommandElements | Where-Object { $_ -isnot [System.Management.Automation.Language.CommandParameterAst] } | Select-Object -Skip 1 | ForEach-Object { $_.SafeGetValue() })
        $values[0] | Should -Be 'Post'
        $values[1] | Should -Be 60
        $values[2] | Should -Be "D:\it's here"
        $values[3] | Should -Be $false
    }
}

Describe 'Slow-check time budget (#39)' {
    It 'default budget is 50 minutes' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\..\src\Windows-IPU-Readiness-Assessment.ps1'), [ref]$null, [ref]$null)
        $p = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'SlowCheckBudgetMinutes' }
        $p.DefaultValue.Value | Should -Be 50
        Get-SlowCheckBudget 50 30 $false | Should -Be 50
    }
    It 'the print export draws on the pool only when it applies (#244)' {
        Get-SlowCheckBudget 50 30 $true | Should -Be 80
        Test-PrintBackupDue 'Pre' $true $true | Should -BeTrue
        Test-PrintBackupDue 'Post' $true $true | Should -BeFalse
        Test-PrintBackupDue 'Pre' $false $true | Should -BeFalse
        Test-PrintBackupDue 'Pre' $true $false | Should -BeFalse
    }
    It 'the Setup scan is not part of the shared pool (#244)' {
        $plan = Get-SlowCheckPlan 'compatscan' 50 99999 45 @()
        $plan.Skip | Should -BeFalse
        $plan.SecondsLeft | Should -Be 2700
    }
    It 'SE-8: DISM and SFC use all of their pool, and the Setup scan still has its full timeout (#244)' {
        # Every check ran to its timeout, so the pool clock is used up.
        (Get-SlowCheckPlan 'dism' 50 3000 45 @()).Reason | Should -Be 'BudgetUsedUp'
        $plan = Get-SlowCheckPlan 'compatscan' 50 3000 45 @([pscustomobject]@{ Id = 'dism'; Outcome = 'TimedOut' }, [pscustomobject]@{ Id = 'sfc'; Outcome = 'Skipped' })
        $plan.Skip | Should -BeFalse; $plan.SecondsLeft | Should -Be 2700
    }
    It 'a check inside the pool gets the seconds that are left' {
        $plan = Get-SlowCheckPlan 'dism' 50 600 0 @()
        $plan.Skip | Should -BeFalse; $plan.SecondsLeft | Should -Be 2400
    }
    It 'with no media the Setup scan plan has no time (the check itself is not applicable)' { (Get-SlowCheckPlan 'compatscan' 50 0 0 @()).SecondsLeft | Should -Be 0 }
    It 'after a DISM timeout SFC is skipped, because the scan may still be running (#244)' {
        $plan = Get-SlowCheckPlan 'sfc' 50 1800 0 @([pscustomobject]@{ Id = 'printbackup'; Outcome = 'Completed' }, [pscustomobject]@{ Id = 'dism'; Outcome = 'TimedOut' })
        $plan.Skip | Should -BeTrue; $plan.Reason | Should -Be 'ServicingMayBeRunning'
    }
    It 'a DISM that failed or finished does not stop SFC; a PrintBrm timeout does not either' {
        (Get-SlowCheckPlan 'sfc' 50 600 0 @([pscustomobject]@{ Id = 'dism'; Outcome = 'Failed' })).Skip | Should -BeFalse
        (Get-SlowCheckPlan 'sfc' 50 600 0 @([pscustomobject]@{ Id = 'dism'; Outcome = 'Completed' })).Skip | Should -BeFalse
        (Get-SlowCheckPlan 'dism' 50 600 0 @([pscustomobject]@{ Id = 'printbackup'; Outcome = 'TimedOut' })).Skip | Should -BeFalse
    }
    It 'a skipped servicing check is a MANUAL finding that coverage lists as a problem (#244)' {
        $script:Results.Clear(); $script:CheckRuns.Clear()
        Add-SkippedSlowCheck ([pscustomobject]@{ Id = 'sfc'; Name = 'SFC protected file verification' }) 50 'ServicingMayBeRunning'
        $script:Results[0].Status | Should -Be 'MANUAL'; $script:Results[0].Kind | Should -Be 'Finding'
        $script:Results[0].Value | Should -Match 'may still be running'
        $script:Results[0].Recommendation | Should -Match 'TiWorker'
        $script:CheckRuns[0].Outcome | Should -Be 'Skipped'
        $notice = Get-CoverageNotice @($script:CheckRuns[0])
        @($notice.Problems).Count | Should -Be 1
        $notice.Problems[0] | Should -Match 'may still be running'
        $script:CurrentCheckId | Should -Be 'core'
    }
    It 'the stop failure text is only there when the process is still running (#244)' {
        Get-StopFailureText $true | Should -Match 'could not be stopped'
        Get-StopFailureText $false | Should -Be ''
    }
    It 'the process state decides whether the stop worked (#244)' {
        (Get-NativeKillOutcome $true 0).StillRunning | Should -BeFalse
        (Get-NativeKillOutcome $true 128).StillRunning | Should -BeFalse
        (Get-NativeKillOutcome $true $null).StillRunning | Should -BeFalse
        $stuck = Get-NativeKillOutcome $false 0
        $stuck.StillRunning | Should -BeTrue; $stuck.Text | Should -Match 'still running'
        (Get-NativeKillOutcome $false 5).Text | Should -Match 'exit code 5'
    }
    It 'computes the seconds left' {
        Get-SlowSecondsLeft 50 0 | Should -Be 3000
        Get-SlowSecondsLeft 50 2940.4 | Should -Be 60
    }
    It '<Seconds> seconds left: skip = <Expected>' -TestCases @(
        @{ Seconds = 59;  Expected = $true }
        @{ Seconds = 60;  Expected = $false }
        @{ Seconds = 0;   Expected = $true }
        @{ Seconds = -30; Expected = $true }
        @{ Seconds = 600; Expected = $false }
    ) {
        Test-SlowCheckSkip $Seconds | Should -Be $Expected
    }
    It 'a skipped check produces a MANUAL finding and a Skipped run' {
        $script:Results.Clear(); $script:CheckRuns.Clear()
        Add-SkippedSlowCheck ([pscustomobject]@{ Id = 'sfc'; Name = 'SFC protected file verification' }) 50
        $script:Results.Count | Should -Be 1
        $script:Results[0].Status | Should -Be 'MANUAL'
        $script:Results[0].Kind | Should -Be 'Finding'
        $script:Results[0].CheckId | Should -Be 'sfc'
        $script:CheckRuns[0].Outcome | Should -Be 'Skipped'
        $script:CurrentCheckId | Should -Be 'core'
    }
}

Describe 'Run lock (#244)' {
    It 'the HRESULT of a sharing or lock violation is recognised' {
        Test-SharingViolation (-2147024864) | Should -BeTrue    # 0x80070020
        Test-SharingViolation (-2147024863) | Should -BeTrue    # 0x80070021
        Test-SharingViolation (-2147024891) | Should -BeFalse   # access denied
        Test-SharingViolation 32 | Should -BeFalse
    }
    It 'a second run on the same lock is refused, and a leftover file does not block' {
        $path = Join-Path $TestDrive 'srv.log.lock'
        $first = Enter-RunLock $path
        $first | Should -Not -BeNullOrEmpty
        Enter-RunLock $path | Should -BeNullOrEmpty
        Exit-RunLock $first
        # The file is still there, but nobody holds it (a killed run leaves exactly this).
        Test-Path -LiteralPath $path | Should -BeTrue
        $again = Enter-RunLock $path
        $again | Should -Not -BeNullOrEmpty
        Exit-RunLock $again
    }
    It 'another lock name is independent' {
        $a = Enter-RunLock (Join-Path $TestDrive 'a.log.lock'); $b = Enter-RunLock (Join-Path $TestDrive 'b.log.lock')
        $a | Should -Not -BeNullOrEmpty; $b | Should -Not -BeNullOrEmpty
        Exit-RunLock $a; Exit-RunLock $b
    }
    It 'a lock that cannot be created is an error, not "another run"' {
        { Enter-RunLock (Join-Path $TestDrive 'no-such-folder\x.lock') } | Should -Throw
    }
    It 'releasing nothing is fine' { { Exit-RunLock $null } | Should -Not -Throw }
}

Describe 'ConvertTo-NativeArgument (#136)' {
    It '<Name>' -ForEach @(
        @{ Name = 'a plain argument is left alone'; In = '/replsummary'; Out = '/replsummary' }
        @{ Name = 'a path with a space is quoted'; In = 'C:\Install Media\x.iso'; Out = '"C:\Install Media\x.iso"' }
        @{ Name = 'a trailing backslash is doubled so it cannot escape the closing quote'; In = 'C:\a b\'; Out = '"C:\a b\\"' }
        @{ Name = 'an embedded quote is escaped'; In = 'a"b'; Out = '"a\"b"' }
        @{ Name = 'backslashes before an embedded quote are doubled'; In = 'a\"b'; Out = '"a\\\"b"' }
        @{ Name = 'backslashes inside a path stay single'; In = 'C:\Program Files\x'; Out = '"C:\Program Files\x"' }
        @{ Name = 'an empty argument stays an argument'; In = ''; Out = '""' }
        @{ Name = 'an argument the caller already quoted is kept'; In = '"C:\a b"'; Out = '"C:\a b"' }
        @{ Name = 'a path without a space or quote is left alone, even with a trailing backslash'; In = 'C:\Temp\'; Out = 'C:\Temp\' }
    ) { ConvertTo-NativeArgument $In | Should -Be $Out }
}

Describe 'Invoke-NativeCapture (#37)' -Tag 'Integration' {
    BeforeAll {
        # -Skip is evaluated during discovery, before this block runs, so the
        # tests test $env:OS directly. Paths are only built on Windows.
        if ($env:OS -eq 'Windows_NT') { $script:Cmd = Join-Path $env:windir 'System32\cmd.exe' }
        function Get-CaptureTempFile { @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'IPU-*' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^IPU-[0-9a-f]{32}\.(out|err)$' }) }
    }

    It 'passes C:\a b\, a"b and a plain argument to a real process unchanged (#136)' -Skip:($env:OS -ne 'Windows_NT') {
        $script = Join-Path $TestDrive 'echo-args.ps1'
        'foreach ($a in $args) { Write-Output ("ARG<" + $a + ">") }' | Set-Content -LiteralPath $script -Encoding ASCII
        $ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $r = Invoke-NativeCapture $ps @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script, 'C:\a b\', 'a"b', 'plain') 60
        $r.ExitCode | Should -Be 0
        $r.Lines | Should -Contain 'ARG<C:\a b\>'
        $r.Lines | Should -Contain 'ARG<a"b>'
        $r.Lines | Should -Contain 'ARG<plain>'
    }
    It 'returns exit code 0' -Skip:($env:OS -ne 'Windows_NT') {
        $r = Invoke-NativeCapture $script:Cmd @('/c', 'exit 0') 30
        $r.ExitCode | Should -Be 0
        $r.TimedOut | Should -BeFalse
        $r.Error | Should -Be ''
    }
    It 'returns a non-zero exit code' -Skip:($env:OS -ne 'Windows_NT') {
        (Invoke-NativeCapture $script:Cmd @('/c', 'exit 3') 30).ExitCode | Should -Be 3
    }
    It 'captures stdout and stderr' -Skip:($env:OS -ne 'Windows_NT') {
        $r = Invoke-NativeCapture $script:Cmd @('/c', 'echo to-stdout& echo to-stderr 1>&2') 30
        $r.Lines | Should -Contain 'to-stdout'
        $r.Lines | Should -Contain 'to-stderr'
    }
    It 'always has the exit code of a command that exits at once (#66)' -Skip:($env:OS -ne 'Windows_NT') {
        $codes = @(1..25 | ForEach-Object { (Invoke-NativeCapture $script:Cmd @('/c', ('exit ' + ($_ % 4))) 30).ExitCode })
        $expected = @(1..25 | ForEach-Object { $_ % 4 })
        ($codes -join ',') | Should -Be ($expected -join ',')
    }
    It 'captures UTF-16 output (#66)' -Skip:($env:OS -ne 'Windows_NT') {
        (Invoke-NativeCapture $script:Cmd @('/u', '/c', 'echo utf16-out') 30).Lines | Should -Contain 'utf16-out'
    }
    It 'stops a command that exceeds the timeout' -Skip:($env:OS -ne 'Windows_NT') {
        $started = Get-Date
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-NativeCapture (Join-Path $env:windir 'System32\PING.EXE') @('-n', '60', '127.0.0.1') 2
        $sw.Stop()
        $r.TimedOut | Should -BeTrue
        $r.ExitCode | Should -BeNullOrEmpty
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 30
        $r.StillRunning | Should -BeFalse
        Start-Sleep -Milliseconds 500
        @(Get-Process -Name PING -ErrorAction SilentlyContinue | Where-Object { $_.StartTime -ge $started }).Count | Should -Be 0
    }
    It 'returns an Error, not an exception, for a missing executable' -Skip:($env:OS -ne 'Windows_NT') {
        { $script:missing = Invoke-NativeCapture 'C:\does-not-exist\nothing.exe' @() 10 } | Should -Not -Throw
        $script:missing.Error | Should -Not -BeNullOrEmpty
        $script:missing.ExitCode | Should -BeNullOrEmpty
    }
    It 'removes its temp files in every case' -Skip:($env:OS -ne 'Windows_NT') {
        $before = @(Get-CaptureTempFile | ForEach-Object FullName)
        $null = Invoke-NativeCapture $script:Cmd @('/c', 'echo x') 30
        $null = Invoke-NativeCapture $script:Cmd @('/c', 'exit 5') 30
        $null = Invoke-NativeCapture (Join-Path $env:windir 'System32\PING.EXE') @('-n', '60', '127.0.0.1') 1
        $null = Invoke-NativeCapture 'C:\does-not-exist\nothing.exe' @() 10
        $after = @(Get-CaptureTempFile | ForEach-Object FullName | Where-Object { $before -notcontains $_ })
        $after.Count | Should -Be 0
    }
}

Describe 'Prerequisites (#94)' {
    BeforeAll { $script:Ok = @{ Ps = [Version]'4.0'; Net = 528049; Elevated = $true } }
    It 'everything present: can run, nothing to report' {
        $d = Get-PrerequisiteDecision $script:Ok.Ps $script:Ok.Net $true @()
        $d.CanRun | Should -BeTrue
        @($d.Required).Count + @($d.Optional).Count | Should -Be 0
    }
    It 'missing <Case> stops the run with "<Expected>"' -TestCases @(
        @{ Case = 'PowerShell 4.0';  Ps = [Version]'3.0'; Net = 528049; Elevated = $true;  Expected = 'Windows PowerShell 4.0 or later (found 3.0)' }
        @{ Case = '.NET 4.5';        Ps = [Version]'4.0'; Net = 0;      Elevated = $true;  Expected = '.NET Framework 4.5 or later (not found). Install .NET Framework 4.8 and run again.' }
        @{ Case = 'an old .NET 4.x'; Ps = [Version]'4.0'; Net = 300000; Elevated = $true;  Expected = '.NET Framework 4.5 or later (release 300000)' }
        @{ Case = 'elevation';       Ps = [Version]'5.1'; Net = 528049; Elevated = $false; Expected = 'Administrator rights. Run the script elevated (Run as administrator), or as SYSTEM through OpenText SA.' }
    ) {
        $d = Get-PrerequisiteDecision $Ps $Net $Elevated @()
        $d.CanRun | Should -BeFalse
        ($d.Required -join ' ') | Should -BeLike ('*' + $Expected + '*')
    }
    It '.NET 4.5 exactly (release 378389) is enough' {
        (Get-PrerequisiteDecision ([Version]'4.0') 378389 $true @()).CanRun | Should -BeTrue
    }
    It 'a missing optional module does not stop the run and names the affected checks' {
        $d = Get-PrerequisiteDecision $script:Ok.Ps $script:Ok.Net $true @('Storage', 'ScheduledTasks')
        $d.CanRun | Should -BeTrue
        $d.Optional[0] | Should -Be 'PowerShell module Storage is not available: storage (disks, partitions, volumes) cannot be fully assessed.'
        $d.Optional[1] | Should -BeLike '*ScheduledTasks*scheduled tasks*'
    }
    It 'a missing required item stops before any check, with a clear SA line and report' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $ReportDirectory = $dir
        $RestrictOutputAcl = $false
        $WriteJson = $true
        $script:ReportPath = Join-Path $dir 'SRV-IPU-Assessment.html'
        $script:JsonPath = Join-Path $dir 'SRV-IPU-Assessment.json'
        $script:LogPath = Join-Path $dir 'SRV-IPU-Assessment.log'
        $script:Results.Clear(); $script:CheckRuns.Clear(); $script:Checks.Clear(); $script:Data = @{}
        Mock Get-PrerequisiteState { [pscustomobject]@{ PowerShellVersion = [Version]'5.1'; DotNetRelease = 528049; IsElevated = $false; MissingModules = @() } }
        $writer = New-Object IO.StringWriter
        $old = [Console]::Out
        [Console]::SetOut($writer)
        try { Invoke-Assessment } finally { [Console]::SetOut($old) }
        $out = $writer.ToString()
        $out | Should -Match ';FAILED;MANUAL;'
        $out | Should -Match 'Missing: Administrator rights\. Run the script elevated'
        $script:CheckRuns.Count | Should -Be 0
        $script:ExitCode | Should -Be 1
        [IO.File]::ReadAllText($script:ReportPath) | Should -Match 'Administrator rights'
    }
}

Describe 'A throw outside a check still gives a report and an SA line (#251)' {
    It 'site data that fails to load ends in FAILED with a report, not a bare error' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $ReportDirectory = $dir
        $RestrictOutputAcl = $false
        $WriteJson = $true
        $script:ReportPath = Join-Path $dir 'SRV-IPU-Assessment.html'
        $script:JsonPath = Join-Path $dir 'SRV-IPU-Assessment.json'
        $script:LogPath = Join-Path $dir 'SRV-IPU-Assessment.log'
        $script:Results.Clear(); $script:CheckRuns.Clear(); $script:Checks.Clear(); $script:Data = @{}
        Mock Get-PrerequisiteState { [pscustomobject]@{ PowerShellVersion = [Version]'5.1'; DotNetRelease = 528049; IsElevated = $true; MissingModules = @() } }
        Mock Import-SiteDataFile { throw 'site data file is broken' }
        $writer = New-Object IO.StringWriter
        $old = [Console]::Out
        [Console]::SetOut($writer)
        try { Invoke-Assessment } finally { [Console]::SetOut($old) }
        $out = $writer.ToString()
        $out | Should -Match ';FAILED;MANUAL;'
        $out | Should -Match 'The run stopped early'
        $out | Should -Match 'site data file is broken'
        $script:ExitCode | Should -Be 1
        Test-Path -LiteralPath $script:ReportPath | Should -BeTrue
        @($script:Results | Where-Object { $_.Item -eq 'Assessment run' -and $_.Status -eq 'MANUAL' }).Count | Should -Be 1
    }
}

Describe 'Get-JsonOutcomeText (#250)' {
    It 'JSON off says nothing' { Get-JsonOutcomeText $false 'Disabled' 'C:\r\x.json' | Should -Be '' }
    It 'written names the file' { Get-JsonOutcomeText $true 'Written' 'C:\r\x.json' | Should -Be ', JSON=C:\r\x.json' }
    It 'a checkpoint is called PARTIAL' {
        $t = Get-JsonOutcomeText $true 'Partial' 'C:\r\x.json'
        $t | Should -Match '^, JSON=PARTIAL'
        $t.Contains('C:\r\x.json') | Should -BeTrue
    }
    It 'a failed write is called FAILED and never names the file as if it existed' {
        $t = Get-JsonOutcomeText $true 'Failed' 'C:\r\x.json'
        $t | Should -Match '^, JSON=FAILED'
        $t | Should -Not -Match 'x\.json'
    }
}

Describe 'Output folder and JSON problems end in a clear SA line (#250)' {
    BeforeEach {
        $script:Results.Clear(); $script:CheckRuns.Clear(); $script:Checks.Clear(); $script:Data = @{}
        $script:Writer = New-Object IO.StringWriter
        $script:OldOut = [Console]::Out
    }
    AfterEach { [Console]::SetOut($script:OldOut) }
    It 'an unwritable report folder stops at once with FAILED, before any check' {
        $blocker = Join-Path $TestDrive 'a-file'
        Set-Content -LiteralPath $blocker -Value 'x'
        $ReportDirectory = Join-Path $blocker 'sub'
        $RestrictOutputAcl = $false
        $script:LogPath = Join-Path $ReportDirectory 'x.log'
        Mock Get-PrerequisiteState { throw 'must not get this far' }
        [Console]::SetOut($script:Writer)
        Invoke-Assessment
        [Console]::SetOut($script:OldOut)
        $out = $script:Writer.ToString()
        $out | Should -Match ';FAILED;MANUAL;'
        $out | Should -Match 'Nothing was assessed: the report folder cannot be written'
        $script:ExitCode | Should -Be 1
        $script:CheckRuns.Count | Should -Be 0
    }
    It 'a JSON that cannot be written makes the line FAILED and says JSON=FAILED' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $ReportDirectory = $dir
        $RestrictOutputAcl = $false
        $WriteJson = $true
        $script:ReportPath = Join-Path $dir 'SRV-IPU-Assessment.html'
        $script:JsonPath = Join-Path $dir 'SRV-IPU-Assessment.json'
        $script:LogPath = Join-Path $dir 'SRV-IPU-Assessment.log'
        Mock Get-PrerequisiteState { [pscustomobject]@{ PowerShellVersion = [Version]'5.1'; DotNetRelease = 528049; IsElevated = $true; MissingModules = @() } }
        Mock Import-SiteDataFile { }
        Mock Register-AssessmentCheck { }
        Mock Write-AssessmentJson { throw 'disk full' }
        [Console]::SetOut($script:Writer)
        Invoke-Assessment
        [Console]::SetOut($script:OldOut)
        $out = $script:Writer.ToString()
        $out | Should -Match ';FAILED;'
        $out | Should -Match 'JSON=FAILED'
        $script:ExitCode | Should -Be 1
        Test-Path -LiteralPath $script:ReportPath | Should -BeTrue
    }
}

Describe 'Test-NotFoundError (#242)' {
    It 'an ObjectNotFound error is an empty answer' {
        $e = $null
        try { Write-Error 'x' -Category ObjectNotFound -ErrorAction Stop } catch { $e = $_ }
        Test-NotFoundError $e | Should -BeTrue
    }
    It 'any other category is a failure' {
        $e = $null
        try { Write-Error 'x' -Category InvalidOperation -ErrorAction Stop } catch { $e = $_ }
        Test-NotFoundError $e | Should -BeFalse
    }
    It 'nothing is not a not-found error' { Test-NotFoundError $null | Should -BeFalse }
}

Describe 'Strict-mode finder (#256)' {
    It 'with IPU_TEST_STRICT_MODE set, strict mode is in effect where the tests call the script' -Skip:(-not $env:IPU_TEST_STRICT_MODE) {
        { $null = $NoSuchVariable256 } | Should -Throw
    }
}
