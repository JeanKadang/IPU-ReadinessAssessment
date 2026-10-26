# Pester 5 tests for the check bodies: the check registry and docs/checks.md.
# They run against the fake server in FakeServer.ps1 (Windows only).

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'The fake server deliberately shadows system cmdlets for the script under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-ins mirror the parameters the script passes to the real cmdlets.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Stand-ins return fixture objects.')]
param()

BeforeAll { . (Join-Path $PSScriptRoot 'FakeServer.ps1') }

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'Check registry' {
    It 'registers 36 checks with unique ids' {
        $script:AllChecks.Count | Should -Be 38
        @($script:AllChecks | Group-Object Id | Where-Object { $_.Count -gt 1 }).Count | Should -Be 0
    }
    It 'docs/checks.md describes every registered check' {
        $doc = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\..\docs\checks.md'))
        foreach ($c in $script:AllChecks) { $doc | Should -Match ('`' + $c.Id + '`') -Because ('check ' + $c.Id + ' needs an entry in docs/checks.md') }
    }
    It 'the sample result matches docs/result-schema.json' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
        $json = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\..\docs\samples\sample-result.json'))
        $schema = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\..\docs\result-schema.json'))
        Microsoft.PowerShell.Utility\Test-Json -Json $json -Schema $schema | Should -BeTrue
    }
    It 'every registered check has a test in this folder' {
        $text = (Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
        foreach ($c in $script:AllChecks) { $text | Should -Match ("Invoke-TestCheck '" + $c.Id + "'") -Because ('check ' + $c.Id + ' needs a test') }
    }
}
