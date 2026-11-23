# Pester 5 tests. -RedactExisting masks passwords in the task command lines of reports made
# before 4.9.0 (#451, GHSA-3xmq-62gm-6hxj).
# The script is loaded in library mode by ..\TestSetup.ps1: functions only, nothing is collected.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
param()

BeforeAll { . (Join-Path $PSScriptRoot '..\TestSetup.ps1') }

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'Hide-TaskActionInResult (#451)' {
    It 'masks the Action of a TASKS row, adds the note, and returns the pair' {
        $rows = @([pscustomobject]@{ Area = 'TASKS'; Item = '\Backup\Nightly'; Value = 'RunAs=svc'; Details = @('State=Ready', 'Action=backup.exe -User bob -Password Hunter2x') })
        $pairs = @(Hide-TaskActionInResult $rows)
        $rows[0].Details[1] | Should -Not -Match 'Hunter2x'
        $rows[0].Details[1] | Should -Match '^Action=backup\.exe -User bob -Password \*+$'
        @($rows[0].Details) | Should -Contain 'Note=A password or token in the arguments was masked.'
        $pairs.Count | Should -Be 1
        $pairs[0].Original | Should -Be 'backup.exe -User bob -Password Hunter2x'
    }
    It 'leaves a command line without a secret, and rows of other areas, alone' {
        $rows = @(
            [pscustomobject]@{ Area = 'TASKS'; Item = '\A'; Value = 'RunAs=x'; Details = @('State=Ready', 'Action=cleanup.exe /quiet') },
            [pscustomobject]@{ Area = 'SERVICES'; Item = 'svc'; Value = 'x'; Details = @('Action=tool -Password abc') }
        )
        @(Hide-TaskActionInResult $rows).Count | Should -Be 0
        $rows[0].Details.Count | Should -Be 2
        $rows[1].Details[0] | Should -Be 'Action=tool -Password abc'
    }
    It 'a row without Details does not stop the others' {
        $rows = @(
            [pscustomobject]@{ Area = 'TASKS'; Item = '\A'; Value = 'x' },
            [pscustomobject]@{ Area = 'TASKS'; Item = '\B'; Value = 'x'; Details = @('Action=net use \\srv\share Secr3t /user:d\u') }
        )
        @(Hide-TaskActionInResult $rows).Count | Should -Be 1
        $rows[1].Details[0] | Should -Not -Match 'Secr3t'
    }
}

Describe 'Redact existing reports: task command lines (#451)' {
    BeforeAll {
        $script:CmdDir = Join-Path $TestDrive 'oldreport'
        New-Item -ItemType Directory -Path $script:CmdDir | Out-Null
        $action = 'sync.exe -Password "Hunter2 x" /dest:"D:\Data & Co"'
        $result = [ordered]@{
            Schema = 'IPU-Assessment/1'; ComputerName = 'SRV-APP01'; Collector = '4.8.0'
            Results = @(
                [ordered]@{ Area = 'TASKS'; Item = '\Nightly'; Status = 'INFO'; Kind = 'Evidence'; Value = 'RunAs=SYSTEM'; Details = @('State=Ready', ('Action=' + $action)) }
            )
        }
        [IO.File]::WriteAllText((Join-Path $script:CmdDir 'SRV-APP01-IPU-Assessment.json'), ($result | ConvertTo-Json -Depth 6))
        $page = '<html><body><table><tr><td>\Nightly</td><td>State=Ready | Action=' + [Net.WebUtility]::HtmlEncode($action) + '</td></tr></table></body></html>'
        [IO.File]::WriteAllText((Join-Path $script:CmdDir 'SRV-APP01-IPU-Assessment.html'), $page)
        $script:CmdCode = Invoke-RedactExisting $script:CmdDir
        $script:CmdJson = [IO.File]::ReadAllText((@(Get-ChildItem -LiteralPath $script:CmdDir -Filter 'REDACTED-*.json')[0]).FullName)
        $script:CmdHtml = [IO.File]::ReadAllText((@(Get-ChildItem -LiteralPath $script:CmdDir -Filter 'REDACTED-*.html')[0]).FullName)
    }
    It 'succeeds' { $script:CmdCode | Should -Be 0 }
    It 'the password is gone from the redacted JSON, and the note says why' {
        $script:CmdJson | Should -Not -Match 'Hunter2'
        $script:CmdJson | Should -Match 'was masked'
    }
    It 'the password is gone from the redacted HTML, including its encoded form' {
        $script:CmdHtml | Should -Not -Match 'Hunter2'
        $script:CmdHtml | Should -Match '\*{8}'
    }
    It 'the rest of the command line stays readable' {
        $script:CmdJson | Should -Match 'sync\.exe'
    }
    It 'the original report is not changed' {
        [IO.File]::ReadAllText((Join-Path $script:CmdDir 'SRV-APP01-IPU-Assessment.json')) | Should -Match 'Hunter2'
    }
}
