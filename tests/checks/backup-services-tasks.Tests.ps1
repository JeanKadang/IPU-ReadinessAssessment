# Pester 5 tests for the check bodies: backup services tasks
# They run against the fake server in FakeServer.ps1 (Windows only).

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'The fake server deliberately shadows system cmdlets for the script under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-ins mirror the parameters the script passes to the real cmdlets.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Stand-ins return fixture objects.')]
param()

BeforeAll { . (Join-Path $PSScriptRoot 'FakeServer.ps1') }

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'Checks on a fake server: backup services tasks' -Skip:($env:OS -ne 'Windows_NT') {
    BeforeEach { Reset-FakeServer }

    Context 'backup' {
        It 'healthy VSS writers and provider' {
            (Invoke-TestCheck 'backup').Outcome | Should -Be 'Completed'
            (Get-Row 'BACKUP' 'VSS writer: System Writer')[0].Status | Should -Be 'OK'
            (Get-Row 'BACKUP' 'VSSWriters').Count | Should -Be 0
            (Get-Row 'BACKUP' 'GuestBackupAgent')[0].Status | Should -Be 'INFO'
        }
        It 'Italian writer texts: "Nessun errore" is OK although it contains "error" (#246)' {
            $script:Fake.Native['vssadmin.exe'] = @{ Output = "Writer name: 'System Writer'`r`n   State: [1] Stable`r`n   Last error: Nessun errore`r`nWriter name: 'Registry Writer'`r`n   State: [1] Stable`r`n   Last error: Nessun errore`r`nWriter name: 'SqlServerWriter'`r`n   State: [1] Stable`r`n   Last error: Errore non ripetibile" }
            $null = Invoke-TestCheck 'backup'
            (Get-Row 'BACKUP' 'VSS writer: System Writer')[0].Status | Should -Be 'OK'
            (Get-Row 'BACKUP' 'VSS writer: Registry Writer')[0].Status | Should -Be 'OK'
            (Get-Row 'BACKUP' 'VSS writer: SqlServerWriter')[0].Status | Should -Be 'ACTION'
        }
        It 'German writer texts: "Kein Fehler" is OK (#246)' {
            $script:Fake.Native['vssadmin.exe'] = @{ Output = "Writer name: 'System Writer'`r`n   State: [1] Stable`r`n   Last error: Kein Fehler`r`nWriter name: 'Registry Writer'`r`n   State: [1] Stable`r`n   Last error: Kein Fehler" }
            $null = Invoke-TestCheck 'backup'
            (Get-Row 'BACKUP' 'VSS writer: System Writer')[0].Status | Should -Be 'OK'
        }
        It 'a failed writer is an ACTION' {
            $script:Fake.Native['vssadmin.exe'] = @{ Output = "Writer name: 'SqlServerWriter'`r`n   State: [8] Failed`r`n   Last error: Retryable error" }
            $null = Invoke-TestCheck 'backup'
            (Get-Row 'BACKUP' 'VSSWriters')[0].Status | Should -Be 'ACTION'
        }
        It 'unreadable VSS state is MANUAL' {
            $script:Fake.Native['vssadmin.exe'] = @{ TimedOut = $true; ExitCode = $null; Output = '' }
            $null = Invoke-TestCheck 'backup'
            (Get-Row 'BACKUP' 'VSSWriters')[0].Status | Should -Be 'MANUAL'
        }
        It 'recognises a backup agent' {
            $script:Fake.Apps += [pscustomobject]@{ Name = 'Commvault ContentStore'; Version = '11.32'; Publisher = 'Commvault'; InstallDate = '' }
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'backup'
            (Get-Row 'BACKUP' 'Commvault').Count | Should -Be 1
        }
    }

    Context 'services' {
        It 'counts automatic services and lists them' {
            (Invoke-TestCheck 'services').Outcome | Should -Be 'Completed'
            $r = (Get-Row 'SERVICES' 'AutomaticServices')[0]
            $r.Value | Should -Be 'Total=8'
            $r.Details | Should -Be 'NotRunning=1'
            (Get-Row 'SERVICES' 'AppSvc')[0].Details | Should -Match 'State=Stopped'
        }
    }

    Context 'tasks' {
        It 'skips Microsoft tasks and flags tasks with stored credentials' {
            $script:Fake.Tasks += [pscustomobject]@{ TaskPath = '\Example\'; TaskName = 'Nightly export'; State = 'Ready'; Principal = [pscustomobject]@{ UserId = 'CORP\svc_batch'; GroupId = '' }; Actions = @([pscustomobject]@{ Execute = 'C:\Tools\export.cmd'; Arguments = '' }) }
            (Invoke-TestCheck 'tasks').Outcome | Should -Be 'Completed'
            (Get-Row 'TASKS' '\Microsoft\Windows\Defrag\ScheduledDefrag').Count | Should -Be 0
            (Get-Row 'TASKS' '\Example\Cleanup')[0].Value | Should -Be 'RunAs=SYSTEM'
            (Get-Row 'TASKS' 'TasksWithNamedAccounts')[0].Details | Should -Match 'svc_batch'
            $script:Data.Snapshot.Tasks | Should -Contain '\Example\Nightly export'
        }
        It 'German built-in task accounts are not named accounts (#246)' {
            $script:Fake.Tasks += [pscustomobject]@{ TaskPath = '\Example\'; TaskName = 'Wartung'; State = 'Ready'; Principal = [pscustomobject]@{ UserId = 'NT-AUTORITAET\SYSTEM'; GroupId = ''; LogonType = 'ServiceAccount' }; Actions = @() }
            $script:Fake.Tasks += [pscustomobject]@{ TaskPath = '\Example\'; TaskName = 'Gruppe'; State = 'Ready'; Principal = [pscustomobject]@{ UserId = ''; GroupId = 'Benutzer'; LogonType = 'Group' }; Actions = @() }
            $script:Fake.Tasks += [pscustomobject]@{ TaskPath = '\Example\'; TaskName = 'Nightly export'; State = 'Ready'; Principal = [pscustomobject]@{ UserId = 'CORP\svc_batch'; GroupId = ''; LogonType = 'Password' }; Actions = @() }
            $null = Invoke-TestCheck 'tasks'
            $named = (Get-Row 'TASKS' 'TasksWithNamedAccounts')[0].Details
            $named | Should -Match 'svc_batch'
            $named | Should -Not -Match 'Wartung'
            $named | Should -Not -Match 'Gruppe'
        }
        It 'Windows per-user feed tasks are one INFO line, not named-account tasks (#214)' {
            foreach ($g in '0F5377C2-5909-4495-A7CC-00331141DFDA', '55B0E49D-1AF0-44AF-B8D0-0123456789AB') {
                $script:Fake.Tasks += [pscustomobject]@{ TaskPath = '\'; TaskName = ('User_Feed_Synchronization-{' + $g + '}'); State = 'Ready'; Principal = [pscustomobject]@{ UserId = 'CORP\jdoe'; GroupId = '' }; Actions = @([pscustomobject]@{ Execute = 'C:\Windows\system32\msfeedssync.exe'; Arguments = 'sync' }) }
            }
            $script:Fake.Tasks += [pscustomobject]@{ TaskPath = '\Example\'; TaskName = 'Nightly export'; State = 'Ready'; Principal = [pscustomobject]@{ UserId = 'CORP\svc_batch'; GroupId = '' }; Actions = @() }
            $null = Invoke-TestCheck 'tasks'
            (Get-Row 'TASKS' 'WindowsPerUserTasks')[0].Value | Should -Be 'Count=2'
            $named = (Get-Row 'TASKS' 'TasksWithNamedAccounts')[0]
            $named.Value | Should -Be 'Count=1'
            $named.Details | Should -Not -Match 'User_Feed'
            @($script:Data.Snapshot.Tasks | Where-Object { $_ -like '\User_Feed_Synchronization-*' }).Count | Should -Be 2
        }
        It 'collects run-as accounts for redaction only from non-Microsoft tasks (#114)' {
            # On windows-2022 a Microsoft task runs as an account named like an
            # ordinary word. It is never reported, so it must not become a
            # redaction literal that blanks "Windows Installer" everywhere.
            $script:Fake.Tasks += [pscustomobject]@{ TaskPath = '\Microsoft\Windows\Example\'; TaskName = 'Installer task'; State = 'Ready'; Principal = [pscustomobject]@{ UserId = 'Installer'; GroupId = '' }; Actions = @() }
            $script:Fake.Tasks += [pscustomobject]@{ TaskPath = '\Example\'; TaskName = 'Nightly export'; State = 'Ready'; Principal = [pscustomobject]@{ UserId = 'CORP\svc_batch'; GroupId = '' }; Actions = @() }
            $null = Invoke-TestCheck 'tasks'
            $script:Data.RedactLiterals.Keys | Should -Contain 'svc_batch'
            $script:Data.RedactLiterals.Keys | Should -Not -Contain 'Installer'
            $ctx = New-RedactionContext 'SRV01' ''
            foreach ($k in @($script:Data.RedactLiterals.Keys)) { $ctx.Literals[$k] = $script:Data.RedactLiterals[$k] }
            Protect-ReportText 'Windows Installer; task runs as svc_batch' $ctx | Should -Be 'Windows Installer; task runs as ACCOUNT-1'
        }
    }

    Context 'checklist' {
        It 'adds the standard change steps as checklist items' {
            (Invoke-TestCheck 'checklist').Outcome | Should -Be 'Completed'
            @($script:Results | Where-Object { $_.Kind -eq 'Checklist' }).Count | Should -Be 6
            (Get-Row 'CHECKLIST' 'Installation media')[0].Command | Should -Be 'setup.exe /ResizeRecoveryPartition Disable'
            (Get-Row 'CHECKLIST' 'Backup and fallback')[0].Recommendation | Should -Match 'VMware'
        }
        It 'target licensing follows the activation channel found by the licensing check (#102)' {
            $null = Invoke-TestCheck 'licensing'
            $script:Data.ActivationKind | Should -Be 'KMS'
            $null = Invoke-TestCheck 'checklist'
            $r = (Get-Row 'CHECKLIST' 'Target licensing')[0]
            $r.Value | Should -Match 'KMS client \(GVLK\)'
            $r.Recommendation | Should -Match 'CSVLK'
        }
        It 'a MAK server is told it needs a MAK for the target, not about KMS (#102)' {
            $script:Fake.Licensing[0].ProductKeyChannel = 'Volume:MAK'
            $script:Fake.Licensing[0].Description = 'Windows(R) Operating System, VOLUME_MAK channel'
            $null = Invoke-TestCheck 'licensing'
            $null = Invoke-TestCheck 'checklist'
            $r = (Get-Row 'CHECKLIST' 'Target licensing')[0]
            $r.Value | Should -Be 'MAK (Multiple Activation Key)'
            $r.Recommendation | Should -Match 'Windows Server 2025 MAK'
            ($r.Value -match 'KMS') | Should -BeFalse
        }
    }
}
