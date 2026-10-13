# Pester 5 tests for build/Sync-Skills.ps1 (#129): the two vendored skill
# copies must stay identical. Works on copies in the test drive.

BeforeAll {
    $script:Sync = Join-Path (Split-Path -Parent $PSScriptRoot) 'build\Sync-Skills.ps1'
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    function New-SkillRoot {
        $r = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($t in '.claude\skills\demo', '.agents\skills\demo') {
            $null = New-Item -ItemType Directory -Path (Join-Path $r $t) -Force
            [IO.File]::WriteAllText((Join-Path $r ($t + '\SKILL.md')), "# Demo`n")
        }
        return $r
    }
}

Describe 'Vendored skills stay identical (#129)' {
    It 'the repository copies are identical' {
        $null = & $script:Sync -Check -Root $script:RepoRoot
        $LASTEXITCODE | Should -Be 0
    }
    It '-Check passes for identical copies' {
        $null = & $script:Sync -Check -Root (New-SkillRoot)
        $LASTEXITCODE | Should -Be 0
    }
    It '-Check fails when a file differs' {
        $r = New-SkillRoot
        [IO.File]::WriteAllText((Join-Path $r '.agents\skills\demo\SKILL.md'), "# Demo, edited`n")
        $out = & $script:Sync -Check -Root $r 6>&1
        $LASTEXITCODE | Should -Be 1
        ($out -join ' ') | Should -Match 'different: demo/SKILL.md'
    }
    It '-Check fails when a file exists in one copy only' {
        $r = New-SkillRoot
        [IO.File]::WriteAllText((Join-Path $r '.claude\skills\demo\extra.md'), 'x')
        $out = & $script:Sync -Check -Root $r 6>&1
        $LASTEXITCODE | Should -Be 1
        ($out -join ' ') | Should -Match 'only in .claude/skills: demo/extra.md'
    }
    It '-Source replaces both copies with the source skills' {
        $r = New-SkillRoot
        $src = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $src 'github-new') -Force
        [IO.File]::WriteAllText((Join-Path $src 'github-new\SKILL.md'), "# New`n")
        $null = New-Item -ItemType Directory -Path (Join-Path $src 'not-a-skill') -Force
        $null = & $script:Sync -Source $src -Root $r 6>&1
        Test-Path -LiteralPath (Join-Path $r '.claude\skills\demo') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $r '.agents\skills\github-new\SKILL.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $r '.claude\skills\not-a-skill') | Should -BeFalse
        $null = & $script:Sync -Check -Root $r
        $LASTEXITCODE | Should -Be 0
    }
}
