# Pester 5 tests for build/Find-OutdatedCiTool.ps1 (#262): the monthly comparison of
# the pinned CI tool versions with the PowerShell Gallery. The pure functions are
# tested directly; the script is run once with a JSON file in place of the Gallery.

BeforeAll {
    $script:Build = Join-Path (Split-Path -Parent $PSScriptRoot) 'build'
    . (Join-Path $script:Build 'Find-OutdatedCiTool.ps1')
    $script:Workflow = "env:`n  PESTER_VERSION: 5.7.1`n  PSSA_VERSION: 1.23.0`n"
}

Describe 'Get-CiToolPin (#262)' {
    It 'reads both pins from the workflow text' {
        $pins = @(Get-CiToolPin $script:Workflow)
        ($pins | ForEach-Object { $_.Name + '=' + $_.Pinned }) | Should -Be @('Pester=5.7.1', 'PSScriptAnalyzer=1.23.0')
    }
    It 'reads the pins of the real ci.yml' {
        $text = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $script:Build) '.github/workflows/ci.yml') -Raw
        @(Get-CiToolPin $text | ForEach-Object { $_.Pinned }) | ForEach-Object { $_ | Should -Match '^\d+\.\d+\.\d+$' }
    }
    It 'throws when a pin is missing, so the job cannot report "current" for nothing' {
        { Get-CiToolPin "env:`n  PESTER_VERSION: 5.7.1`n" } | Should -Throw '*PSSA_VERSION is not set*'
    }
}

Describe 'Compare-CiToolVersion (#262)' {
    BeforeAll { $script:Pins = @(Get-CiToolPin $script:Workflow) }
    It 'lists a tool whose pin is behind' {
        $rows = @(Compare-CiToolVersion -Pin $script:Pins -Latest @{ Pester = '5.8.0'; PSScriptAnalyzer = '1.23.0' })
        $rows.Count | Should -Be 1
        $rows[0].Name | Should -Be 'Pester'
        $rows[0].Latest | Should -Be '5.8.0'
    }
    It 'compares versions as numbers, not as text' {
        @(Compare-CiToolVersion -Pin $script:Pins -Latest @{ Pester = '5.10.0'; PSScriptAnalyzer = '1.9.0' }).Count | Should -Be 1
    }
    It 'lists nothing when every pin is current or ahead' {
        @(Compare-CiToolVersion -Pin $script:Pins -Latest @{ Pester = '5.7.1'; PSScriptAnalyzer = '1.20.0' }).Count | Should -Be 0
    }
    It 'leaves out a tool with no newest version or one that does not parse' {
        @(Compare-CiToolVersion -Pin $script:Pins -Latest @{ Pester = 'not-a-version' }).Count | Should -Be 0
    }
}

Describe 'Format-OutdatedCiToolReport (#262)' {
    It 'names the tool, both versions and the variable to change' {
        $text = Format-OutdatedCiToolReport @([pscustomobject]@{ Name = 'Pester'; Variable = 'PESTER_VERSION'; Pinned = '5.7.1'; Latest = '5.8.0' })
        $text | Should -Match 'Pester: pinned 5\.7\.1, newest 5\.8\.0 \(`PESTER_VERSION`\)'
        $text | Should -Match 'Invoke-Local\.ps1'
    }
}

Describe 'the script (#262)' {
    BeforeAll {
        $script:Ci = Join-Path (Split-Path -Parent $script:Build) '.github/workflows/ci.yml'
        $script:Pwsh = (Get-Process -Id $PID).Path
        function Invoke-Tool([string]$Latest) {
            $latestPath = Join-Path $TestDrive 'latest.json'
            Set-Content -LiteralPath $latestPath -Value $Latest -Encoding UTF8
            $report = Join-Path $TestDrive 'report.md'
            if (Test-Path $report) { Remove-Item $report }
            $out = Join-Path $TestDrive 'github-output.txt'
            if (Test-Path $out) { Remove-Item $out }
            $env:GITHUB_OUTPUT = $out
            try { $text = & $script:Pwsh -NoProfile -File (Join-Path $script:Build 'Find-OutdatedCiTool.ps1') -WorkflowPath $script:Ci -LatestPath $latestPath -ReportPath $report 2>&1 | Out-String }
            finally { Remove-Item Env:\GITHUB_OUTPUT -ErrorAction SilentlyContinue }
            [pscustomobject]@{ Text = $text; Report = $(if (Test-Path $report) { Get-Content -LiteralPath $report -Raw } else { $null }); Output = @(Get-Content -LiteralPath $out) }
        }
    }
    It 'reports a pin that is behind and writes the report' {
        $r = Invoke-Tool '{ "Pester": "99.0.0", "PSScriptAnalyzer": "99.0.0" }'
        $r.Output | Should -Contain 'ok=true'
        $r.Output | Should -Contain 'count=2'
        $r.Report | Should -Match 'newest 99\.0\.0'
    }
    It 'says every pin is current when none is behind' {
        $r = Invoke-Tool '{ "Pester": "0.0.1", "PSScriptAnalyzer": "0.0.1" }'
        $r.Output | Should -Contain 'count=0'
        $r.Text | Should -Match 'Every pin is current'
    }
    It 'fails safe when a newest version is missing: ok=false and no report' {
        $r = Invoke-Tool '{ "Pester": "99.0.0" }'
        $r.Output | Should -Contain 'ok=false'
        $r.Report | Should -BeNullOrEmpty
        $r.Text | Should -Match 'could not be read'
    }
}
