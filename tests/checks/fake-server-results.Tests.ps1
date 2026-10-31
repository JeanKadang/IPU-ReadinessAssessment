# Pester 5 test: the shape of everything the 38 checks produce on the fake server
# (#360). Steps that are meant to change no behaviour (moving, declaring or
# renaming check data) must leave this unchanged: a key that moved to the wrong
# owner changes a row, and this test shows which. The golden file holds, per
# check, its outcome and its rows as Area | Item | Status | Kind, then the keys
# of $script:Data and the lists of its Snapshot at the end. Values and texts are
# left out on purpose, so rewording a message does not break it.
#
# A check that legitimately gains, loses or changes a row makes this test fail
# with the difference. Review it, then rewrite the golden file:
#     $env:IPU_UPDATE_GOLDEN = '1'; Invoke-Pester .\tests\checks\fake-server-results.Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'The fake server deliberately shadows system cmdlets for the script under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-ins mirror the parameters the script passes to the real cmdlets.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Stand-ins return fixture objects.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'FakeServer.ps1')
    # The file probes of the eolcandidates check (OpenSSL, PHP, nginx ...) look at
    # the real disk with .NET calls that the fake server does not intercept: a
    # runner with OpenSSL installed would get a row that another machine does
    # not. This test is about the check data, so no probe finds anything.
    function Resolve-EolProbePath {
        param([string]$Pattern)
        return [pscustomobject]@{ Paths = @(); Error = '' }
    }
    $script:GoldenPath = Join-Path $PSScriptRoot 'fake-server-results.golden.txt'
    # Evidence copies go to the test drive, not to the machine's C:\Temp.
    $EvidenceRoot = Join-Path $TestDrive 'evidence'
    $script:Data = @{}
    $script:Results.Clear(); $script:CheckRuns.Clear()
    $lines = New-Object Collections.Generic.List[string]
    foreach ($check in $script:AllChecks) {
        $before = $script:Results.Count
        Invoke-Check $check
        $run = $script:CheckRuns[-1]
        $lines.Add('check ' + $check.Id + ' ' + $run.Outcome)
        foreach ($row in @($script:Results.ToArray() | Select-Object -Skip $before)) {
            $lines.Add('  ' + $row.Area + ' | ' + $row.Item + ' | ' + $row.Status + ' | ' + $row.Kind)
        }
    }
    $lines.Add('data keys: ' + ((@($script:Data.Keys) | Sort-Object) -join ' '))
    $lines.Add('snapshot lists: ' + ((@($script:Data.Snapshot.Keys) | Sort-Object) -join ' '))
    $script:Actual = @($lines.ToArray())
}

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'The fake server run: outcome and rows of every check, keys and snapshot lists (#360)' {
    It 'matches the golden file' {
        if ($env:IPU_UPDATE_GOLDEN -eq '1') {
            [IO.File]::WriteAllText($script:GoldenPath, (($script:Actual -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
            Set-ItResult -Skipped -Because 'the golden file was rewritten (IPU_UPDATE_GOLDEN=1)'
            return
        }
        $golden = @([IO.File]::ReadAllText($script:GoldenPath).TrimEnd() -split '\r?\n')
        $difference = @(Compare-Object -ReferenceObject $golden -DifferenceObject $script:Actual | ForEach-Object { ($(if ($_.SideIndicator -eq '<=') { 'golden: ' } else { 'now:    ' })) + $_.InputObject })
        $difference | Should -BeNullOrEmpty -Because ("the checks produce different rows than the golden file. If the change is meant, rewrite it with IPU_UPDATE_GOLDEN=1. Differences:`n" + ($difference -join "`n"))
    }
    It 'ran all 38 checks and every one completed' {
        @($script:Actual | Where-Object { $_ -like 'check *' }).Count | Should -Be 38
        @($script:Actual | Where-Object { $_ -like 'check * Failed' }).Count | Should -Be 0
    }
}
