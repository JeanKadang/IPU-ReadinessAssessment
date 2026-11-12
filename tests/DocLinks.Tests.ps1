# Pester 5 tests for build/Find-BrokenDocLink.ps1 (#265): relative links in the documents
# must resolve, now that the user guide is split into several files.

BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:Repo 'build\Find-BrokenDocLink.ps1')
    function New-DocTree([hashtable]$Files) {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($k in $Files.Keys) {
            $p = Join-Path $root $k
            New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force | Out-Null
            [IO.File]::WriteAllText($p, [string]$Files[$k])
        }
        return $root
    }
}

Describe 'Get-MarkdownSlug' {
    It '<Heading> -> <Slug>' -TestCases @(
        @{ Heading = 'Overview'; Slug = 'overview' }
        @{ Heading = '1. Overview'; Slug = '1-overview' }
        @{ Heading = 'Sharing a report: redaction'; Slug = 'sharing-a-report-redaction' }
        @{ Heading = 'SPECIAL: cluster nodes and domain controllers'; Slug = 'special-cluster-nodes-and-domain-controllers' }
        @{ Heading = 'The `-Mode` switch (Pre/Post)'; Slug = 'the--mode-switch-prepost' }
        @{ Heading = 'Snake_case and-dash'; Slug = 'snake_case-and-dash' }
        @{ Heading = 'A [link](other.md) heading'; Slug = 'a-link-heading' }
    ) {
        Get-MarkdownSlug $Heading | Should -Be $Slug
    }
}

Describe 'Get-MarkdownAnchor' {
    It 'lists the headings of every level, repeated ones with -1, -2' {
        @(Get-MarkdownAnchor "# One`n## Two`n### Two`n#### Two`n") | Should -Be @('one', 'two', 'two-1', 'two-2')
    }
    It 'skips code fences and takes the closing hashes and the trailing blanks off' {
        $text = "# Real #`n``````powershell`n# Not a heading`n## Nor this`n```````n## C#  `n"
        @(Get-MarkdownAnchor $text) | Should -Be @('real', 'c')
    }
    It 'a hash without a blank after it is not a heading' {
        @(Get-MarkdownAnchor "#nope`n####### seven`n") | Should -BeNullOrEmpty
    }
}

Describe 'Get-MarkdownLink' {
    It 'finds links and images, with the line number and without the title' {
        $l = @(Get-MarkdownLink "text [a](one.md) and ![img](pic.png)`nsecond [b](two.md#x ""Title"")`n")
        $l.Count | Should -Be 3
        $l[0].Target | Should -Be 'one.md'; $l[0].Line | Should -Be 1
        $l[1].Target | Should -Be 'pic.png'
        $l[2].Target | Should -Be 'two.md#x'; $l[2].Line | Should -Be 2
    }
    It 'ignores links in code fences and in inline code' {
        $l = @(Get-MarkdownLink "``[x](in-code.md)`` and [y](real.md)`n```````n[z](fenced.md)`n```````n")
        $l.Count | Should -Be 1
        $l[0].Target | Should -Be 'real.md'
    }
}

Describe 'Find-BrokenDocLink' {
    It 'accepts a file, a heading in the same file, a heading in another file and a folder' {
        $root = New-DocTree @{
            'a.md'         = "# A`n## Part`n[o](b.md) [h](#part) [x](b.md#other-part) [d](docs/) [u](docs/c.md#c)`n"
            'b.md'         = "# B`n## Other part`n"
            'docs/c.md'    = "# C`n[up](../a.md#part)`n"
        }
        @(Find-BrokenDocLink $root @('a.md', 'docs/c.md')) | Should -BeNullOrEmpty
    }
    It 'reports a file that is not there, with file, line and target' {
        $root = New-DocTree @{ 'a.md' = "# A`n`n[gone](missing.md)`n" }
        $b = @(Find-BrokenDocLink $root @('a.md'))
        $b.Count | Should -Be 1
        $b[0].File | Should -Be 'a.md'; $b[0].Line | Should -Be 3; $b[0].Target | Should -Be 'missing.md'
        $b[0].Reason | Should -Be 'file not found'
    }
    It 'reports a heading that is not in the target file (the case of a split guide)' {
        $root = New-DocTree @{ 'a.md' = "[p](b.md#4-parameters)`n[q](#nowhere)`n"; 'b.md' = "# B`n## Parameters`n" }
        $b = @(Find-BrokenDocLink $root @('a.md'))
        $b.Count | Should -Be 2
        $b[0].Reason | Should -Match 'no such heading in b.md'
        $b[1].Reason | Should -Match 'no such heading in a.md'
    }
    It 'does not follow other sites, mail addresses or anchors in files that are not Markdown' {
        $root = New-DocTree @{ 'a.md' = "[w](https://example.test/x#y) [m](mailto:a@example.test) [c](code.ps1#L10)`n"; 'code.ps1' = "x`n" }
        @(Find-BrokenDocLink $root @('a.md')) | Should -BeNullOrEmpty
    }
    It 'reads %20 in a path and a path from the root of the repository' {
        $root = New-DocTree @{ 'a.md' = "[s](my%20file.md) [r](/docs/c.md)`n"; 'my file.md' = "# S`n"; 'docs/c.md' = "# C`n" }
        @(Find-BrokenDocLink $root @('a.md')) | Should -BeNullOrEmpty
    }
}

Describe 'the documents of this repository (#265)' {
    It 'every relative link resolves, to a file and to a heading' {
        $files = @(Get-DocLinkFile $script:Repo)
        $files | Should -Contain 'README.md'
        $files | Should -Contain 'docs/user-guide.md'
        $broken = @(Find-BrokenDocLink $script:Repo $files)
        ($broken | ForEach-Object { $_.File + ':' + $_.Line + ' ' + $_.Target + ' (' + $_.Reason + ')' }) -join "`n" | Should -BeNullOrEmpty
    }
    It 'the user guide index links every part, and every part links back to the index' {
        $parts = @(Get-ChildItem -LiteralPath (Join-Path $script:Repo 'docs') -Filter 'user-guide-*.md' | ForEach-Object { $_.Name })
        $parts.Count | Should -BeGreaterOrEqual 4
        $index = [IO.File]::ReadAllText((Join-Path $script:Repo 'docs\user-guide.md'))
        foreach ($p in $parts) {
            $index | Should -Match ([regex]::Escape('(' + $p + ')')) -Because ('the index must link ' + $p)
            [IO.File]::ReadAllText((Join-Path $script:Repo ('docs\' + $p))) | Should -Match ([regex]::Escape('(user-guide.md)')) -Because ($p + ' must link back to the index')
        }
    }
    It 'the release zip carries every part of the user guide' {
        $release = [IO.File]::ReadAllText((Join-Path $script:Repo '.github\workflows\release.yml'))
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $script:Repo 'docs') -Filter 'user-guide*.md')) {
            $release | Should -Match ([regex]::Escape('docs/' + $f.Name)) -Because ('release.yml must copy ' + $f.Name)
        }
    }
}
