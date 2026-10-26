# Pester 5 tests. Repository-wide rules: version consistency, no host data, dated facts, SilentlyContinue reasons.
# The script is loaded in library mode by ..\TestSetup.ps1: functions only, nothing is collected.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
param()

BeforeAll { . (Join-Path $PSScriptRoot '..\TestSetup.ps1') }

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'Version (#19)' {
    BeforeAll {
        $script:Root = Join-Path $PSScriptRoot '..\..'
        $script:Header = [IO.File]::ReadAllText((Join-Path $script:Root 'src\Windows-IPU-Readiness-Assessment.ps1'))
        $script:Changelog = [IO.File]::ReadAllText((Join-Path $script:Root 'CHANGELOG.md'))
    }
    It 'the header VERSION equals $script:CollectorVersion' {
        $m = [regex]::Match($script:Header, '(?m)^\s*VERSION\s*:\s*(\d+\.\d+\.\d+)\s*$')
        $m.Success | Should -BeTrue
        $m.Groups[1].Value | Should -Be $script:CollectorVersion
    }
    It 'the version history in the header starts with this version' {
        [regex]::Match($script:Header, '(?ms)^\.VERSION HISTORY\s*\r?\n\s*(\d+\.\d+\.\d+) - ').Groups[1].Value | Should -Be $script:CollectorVersion
    }
    It 'CHANGELOG.md has a section for this version' {
        $script:Changelog | Should -Match ('(?m)^## \[' + [regex]::Escape($script:CollectorVersion) + '\]')
    }
}

Describe 'No company or host names in the repository (#90)' {
    It 'tracked files do not contain the names removed when the repository became public' {
        # The names are stored encoded so this test does not reintroduce them.
        $names = @('QWV2ZW4=', 'QUVWTldPU1RTVA==') | ForEach-Object { [Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($_)) }
        $root = Join-Path $PSScriptRoot '..\..'
        $files = Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' -and $_.Extension -in @('.ps1', '.psd1', '.md', '.json', '.yml', '.yaml', '.html', '.txt') }
        $hits = @()
        foreach ($f in $files) {
            $text = [IO.File]::ReadAllText($f.FullName)
            foreach ($n in $names) { if ($text.IndexOf($n, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hits += $f.Name } }
        }
        $hits | Should -BeNullOrEmpty
    }
}

Describe 'Dated facts have a source and a recent check (#132)' {
    It 'every fact table is listed with a date and an https source' {
        foreach ($name in 'SupportedUpgradePaths', 'SqlSupportedOnTarget', 'ReleaseEndOfSupport', 'FeatureLifecycle', 'PerUserServices', 'VMwareToolsMinimum', 'ExpectedWindowsChanges', 'WinReMinPartitionMB', 'DocLinks') {
            $script:FactSources.Contains($name) | Should -BeTrue -Because $name
        }
        @(Get-StaleFactSource $script:FactSources ([datetime]'2026-10-13')) | Should -BeNullOrEmpty
    }
    It 'no fact table was last checked more than six months ago' {
        $stale = Get-StaleFactSource $script:FactSources (Get-Date)
        @($stale) | Should -BeNullOrEmpty -Because ('these need a recheck (CONTRIBUTING, "Dated facts"): ' + (@($stale) -join '; '))
    }
    It 'a back-dated entry is reported with its source; a missing date or source too' {
        $sources = [ordered]@{
            Old = @{ Verified = '2026-01-01'; Source = 'https://learn.microsoft.com/example' }
            Fresh = @{ Verified = '2026-09-01'; Source = 'https://learn.microsoft.com/example' }
            NoDate = @{ Verified = 'soon'; Source = 'https://learn.microsoft.com/example' }
            NoSource = @{ Verified = '2026-09-01'; Source = '' }
        }
        $stale = Get-StaleFactSource $sources ([datetime]'2026-10-13')
        @($stale).Count | Should -Be 3
        $stale[0] | Should -Be 'Old: last verified 2026-01-01, recheck against https://learn.microsoft.com/example'
        ($stale -join ' ') | Should -Match 'NoDate: no valid'
        ($stale -join ' ') | Should -Match 'NoSource: no valid'
    }
    It 'six months is the limit' {
        $s = [ordered]@{ T = @{ Verified = '2026-04-13'; Source = 'https://x.example' } }
        @(Get-StaleFactSource $s ([datetime]'2026-10-13')).Count | Should -Be 0
        @(Get-StaleFactSource $s ([datetime]'2026-10-14')).Count | Should -Be 1
    }
}

Describe 'SilentlyContinue has a reason in the source parts (#306)' {
    It 'every -ErrorAction SilentlyContinue carries a comment on its line or the line above' {
        $parts = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\..\src\assessment') -Filter '*.ps1'
        $bare = @()
        foreach ($part in $parts) {
            $tokens = $null; $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($part.FullName, [ref]$tokens, [ref]$errors)
            $commentLines = @{}
            foreach ($t in $tokens) { if ($t.Kind -eq 'Comment') { for ($l = $t.Extent.StartLineNumber; $l -le $t.Extent.EndLineNumber; $l++) { $commentLines[$l] = $true } } }
            for ($i = 0; $i -lt $tokens.Count - 1; $i++) {
                if ($tokens[$i].Kind -eq 'Parameter' -and $tokens[$i].Text -ieq '-ErrorAction' -and $tokens[$i + 1].Text -ieq 'SilentlyContinue') {
                    $line = $tokens[$i].Extent.StartLineNumber
                    if (-not ($commentLines[$line] -or $commentLines[$line - 1])) { $bare += ($part.Name + ':' + $line) }
                }
            }
        }
        $bare | Should -BeNullOrEmpty
    }
}
