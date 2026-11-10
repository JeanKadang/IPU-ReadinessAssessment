# Pester 5 tests for build/Find-RoadmapDrift.ps1 (#395): the weekly comparison of
# docs/roadmap.md with the open issues. Pure functions only; nothing calls gh.

BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:Repo 'build\Find-RoadmapDrift.ps1')
    function New-RoadmapIssue([int]$Number, [string]$Milestone, [string[]]$Labels = @('P3'), [string[]]$Assignees = @('alice')) {
        $m = $null
        if ($Milestone) { $m = [pscustomobject]@{ title = $Milestone } }
        [pscustomobject]@{
            number    = $Number
            title     = "Issue $Number"
            milestone = $m
            labels    = @($Labels | ForEach-Object { [pscustomobject]@{ name = $_ } })
            assignees = @($Assignees | ForEach-Object { [pscustomobject]@{ login = $_ } })
        }
    }
    function New-RoadmapRow([int]$Number, [string]$Milestone, [string]$Priority = 'P3', [string]$Owner = 'alice') {
        [pscustomobject]@{ Number = $Number; Milestone = $Milestone; Priority = $Priority; Owner = $Owner }
    }
}

Describe 'ConvertFrom-RoadmapPage (#395)' {
    It 'reads the rows under their milestone heading' {
        $text = "# Roadmap`n`n## 4.9.0`n`n| Issue | Priority | Owner | Title |`n|---|---|---|---|`n| [#12](https://example.test/12) | P2 | alice | First |`n`n## Future`n`n| [#7](https://example.test/7) | P1 | bob | Second |`n"
        $rows = @(ConvertFrom-RoadmapPage $text)
        $rows.Count | Should -Be 2
        $rows[0].Number | Should -Be 12
        $rows[0].Milestone | Should -Be '4.9.0'
        $rows[0].Priority | Should -Be 'P2'
        $rows[0].Owner | Should -Be 'alice'
        $rows[1].Number | Should -Be 7
        $rows[1].Milestone | Should -Be 'Future'
    }
    It 'works with Windows line endings' {
        $rows = @(ConvertFrom-RoadmapPage "## Future`r`n| [#3](u) | P3 | bob | T |`r`n")
        $rows.Count | Should -Be 1
        $rows[0].Milestone | Should -Be 'Future'
    }
    It 'ignores the header row, the separator row and plain text' {
        @(ConvertFrom-RoadmapPage "## A`n| Issue | Priority | Owner | Title |`n|---|---|---|---|`nSee #5 for more.`n").Count | Should -Be 0
    }
    It 'handles an empty or missing text' {
        @(ConvertFrom-RoadmapPage $null).Count | Should -Be 0
        @(ConvertFrom-RoadmapPage '').Count | Should -Be 0
    }
}

Describe 'Find-RoadmapDrift (#395)' {
    It 'reports nothing when the page and the issues agree' {
        $page = @((New-RoadmapRow 1 '4.9.0' 'P2' 'alice'), (New-RoadmapRow 2 'Future' 'P3' 'bob'))
        $issues = @((New-RoadmapIssue 1 '4.9.0' @('P2', 'bug') @('alice')), (New-RoadmapIssue 2 'Future' @('P3') @('bob')))
        @(Find-RoadmapDrift $page $issues).Count | Should -Be 0
    }
    It 'reports an open issue in a milestone that is not on the page' {
        $d = @(Find-RoadmapDrift @((New-RoadmapRow 1 'Future')) @((New-RoadmapIssue 1 'Future'), (New-RoadmapIssue 9 '4.9.0')))
        $d.Count | Should -Be 1
        $d[0].Number | Should -Be 9
        $d[0].Problem | Should -Match 'not on the page'
    }
    It 'does not expect an open issue without a milestone on the page' {
        @(Find-RoadmapDrift @((New-RoadmapRow 1 'Future')) @((New-RoadmapIssue 1 'Future'), (New-RoadmapIssue 9 ''))).Count | Should -Be 0
    }
    It 'reports a row whose issue is closed or does not exist' {
        $d = @(Find-RoadmapDrift @((New-RoadmapRow 4 'Future')) @())
        $d.Count | Should -Be 1
        $d[0].Problem | Should -Match 'not open'
    }
    It 'reports a different milestone' {
        $d = @(Find-RoadmapDrift @((New-RoadmapRow 1 'Future')) @((New-RoadmapIssue 1 '4.9.0')))
        $d.Count | Should -Be 1
        $d[0].Problem | Should -Match 'milestone "4\.9\.0"'
    }
    It 'reports a different priority (the #349 case: P3 on the page, P2 on the issue)' {
        $d = @(Find-RoadmapDrift @((New-RoadmapRow 349 '4.9.0' 'P3')) @((New-RoadmapIssue 349 '4.9.0' @('P2', 'testing'))))
        $d.Count | Should -Be 1
        $d[0].Problem | Should -Match 'Priority on the page is "P3"; the issue has the label P2'
    }
    It 'reports an issue with no priority label or with two' {
        @(Find-RoadmapDrift @((New-RoadmapRow 1 'Future')) @((New-RoadmapIssue 1 'Future' @('bug'))))[0].Problem | Should -Match 'no priority label'
        @(Find-RoadmapDrift @((New-RoadmapRow 1 'Future')) @((New-RoadmapIssue 1 'Future' @('P3', 'P1'))))[0].Problem | Should -Match 'the label P1, P3'
    }
    It 'reports a different owner, and accepts any of several assignees' {
        @(Find-RoadmapDrift @((New-RoadmapRow 1 'Future' 'P3' 'alice')) @((New-RoadmapIssue 1 'Future' @('P3') @('bob'))))[0].Problem | Should -Match 'assigned to bob'
        @(Find-RoadmapDrift @((New-RoadmapRow 1 'Future' 'P3' 'bob')) @((New-RoadmapIssue 1 'Future' @('P3') @('alice', 'bob')))).Count | Should -Be 0
    }
    It 'accepts "-" as the owner of an unassigned issue' {
        @(Find-RoadmapDrift @((New-RoadmapRow 1 'Future' 'P3' '-')) @((New-RoadmapIssue 1 'Future' @('P3') @()))).Count | Should -Be 0
        @(Find-RoadmapDrift @((New-RoadmapRow 1 'Future' 'P3' 'alice')) @((New-RoadmapIssue 1 'Future' @('P3') @())))[0].Problem | Should -Match 'assigned to nobody'
    }
    It 'reports an issue listed twice' {
        $d = @(Find-RoadmapDrift @((New-RoadmapRow 1 'Future'), (New-RoadmapRow 1 'Future')) @((New-RoadmapIssue 1 'Future')))
        $d.Count | Should -Be 1
        $d[0].Problem | Should -Match 'more than once'
    }
    It 'sorts the differences by issue number' {
        $d = @(Find-RoadmapDrift @((New-RoadmapRow 8 'Future'), (New-RoadmapRow 3 'Future')) @())
        ($d | ForEach-Object Number) | Should -Be @(3, 8)
    }
}

Describe 'Format-RoadmapDriftReport (#395)' {
    It 'writes one line per difference' {
        $text = Format-RoadmapDriftReport @(Find-RoadmapDrift @((New-RoadmapRow 4 'Future')) @())
        $text | Should -Match '(?m)^- #4: Listed under "Future", but the issue is not open$'
    }
}

Describe 'docs/roadmap.md can be read by the check (#395)' {
    BeforeAll { $script:Rows = @(ConvertFrom-RoadmapPage ([IO.File]::ReadAllText((Join-Path $script:Repo 'docs\roadmap.md')))) }
    It 'has issue rows, each under a heading and with a P0 to P3 priority' {
        $script:Rows.Count | Should -BeGreaterThan 0
        foreach ($r in $script:Rows) {
            $r.Milestone | Should -Not -BeNullOrEmpty
            $r.Priority | Should -Match '^P[0-3]$'
        }
    }
    It 'lists no issue twice' {
        @($script:Rows | Group-Object Number | Where-Object { $_.Count -gt 1 }).Count | Should -Be 0
    }
}
