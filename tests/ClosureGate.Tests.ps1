# Pester 5 tests for build/Find-UncheckedClosedIssue.ps1 (#263): the weekly check
# for issues closed as completed with unchecked criteria. Pure functions only;
# nothing calls gh.

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\Find-UncheckedClosedIssue.ps1')
    function New-GateIssue([int]$Number, [string]$Reason, [string]$Body, [string]$Closed = '2026-10-20T10:00:00Z') {
        [pscustomobject]@{ number = $Number; title = "Issue $Number"; stateReason = $Reason; body = $Body; closedAt = $Closed; url = "https://example.test/$Number" }
    }
}

Describe 'Get-UncheckedCriterion (#263)' {
    It 'returns the unchecked lines and leaves the ticked ones' {
        $body = "## Acceptance criteria`n- [x] done`n- [ ] not done`n* [ ] star bullet`n  - [ ] indented`n- [X] also done"
        Get-UncheckedCriterion $body | Should -Be @('not done', 'star bullet', 'indented')
    }
    It 'works with Windows line endings' {
        Get-UncheckedCriterion "- [x] a`r`n- [ ] b`r`n" | Should -Be @('b')
    }
    It 'ignores a box inside a code fence' {
        $body = "Example:`n``````markdown`n- [ ] sample`n```````n- [x] real"
        @(Get-UncheckedCriterion $body).Count | Should -Be 0
    }
    It 'ignores brackets in the middle of a line and empty boxes without text' {
        @(Get-UncheckedCriterion "see [ ] here`n- [ ]`n").Count | Should -Be 0
    }
    It 'handles an empty or missing body' {
        @(Get-UncheckedCriterion $null).Count | Should -Be 0
        @(Get-UncheckedCriterion '').Count | Should -Be 0
    }
}

Describe 'Find-UncheckedClosedIssue (#263)' {
    It 'lists completed issues with open boxes, oldest closure first' {
        $rows = Find-UncheckedClosedIssue @(
            (New-GateIssue 5 'COMPLETED' '- [ ] late' '2026-10-25T10:00:00Z'),
            (New-GateIssue 3 'COMPLETED' '- [ ] early' '2026-10-21T10:00:00Z'))
        ($rows | ForEach-Object Number) | Should -Be @(3, 5)
        $rows[0].Unchecked | Should -Be @('early')
    }
    It 'ignores issues closed as not planned or as a duplicate' {
        @(Find-UncheckedClosedIssue @(
                (New-GateIssue 1 'NOT_PLANNED' '- [ ] x'),
                (New-GateIssue 2 'DUPLICATE' '- [ ] x'))).Count | Should -Be 0
    }
    It 'ignores completed issues whose boxes are all ticked or that have none' {
        @(Find-UncheckedClosedIssue @(
                (New-GateIssue 1 'COMPLETED' '- [x] a'),
                (New-GateIssue 2 'COMPLETED' 'no list'))).Count | Should -Be 0
    }
    It 'counts an issue with no recorded reason as completed' {
        @(Find-UncheckedClosedIssue @((New-GateIssue 7 '' '- [ ] x'))).Count | Should -Be 1
    }
    It 'accepts a parsed date as the closing time' {
        $i = New-GateIssue 8 'COMPLETED' '- [ ] x'
        $i.closedAt = [datetime]'2026-10-23T09:00:00Z'
        (Find-UncheckedClosedIssue @($i))[0].Closed | Should -Match '^2026-10-23'
    }
    It 'no issues at all is an empty list' {
        @(Find-UncheckedClosedIssue @()).Count | Should -Be 0
    }
}

Describe 'Format-UncheckedClosedReport (#263)' {
    It 'names each issue with its closing day and the number of open boxes' {
        $rows = Find-UncheckedClosedIssue @((New-GateIssue 9 'COMPLETED' "- [ ] one`n- [ ] two"))
        $text = Format-UncheckedClosedReport $rows
        $text | Should -Match '- #9 Issue 9 \(closed 2026-10-20, 2 unchecked\)'
        $text | Should -Match '  - one'
    }
    It 'shows at most five boxes per issue and says how many more' {
        $body = (1..8 | ForEach-Object { "- [ ] item $_" }) -join "`n"
        $text = Format-UncheckedClosedReport (Find-UncheckedClosedIssue @((New-GateIssue 10 'COMPLETED' $body)))
        $text | Should -Match 'item 5'
        $text | Should -Not -Match 'item 6'
        $text | Should -Match '\.\.\. and 3 more'
    }
}
