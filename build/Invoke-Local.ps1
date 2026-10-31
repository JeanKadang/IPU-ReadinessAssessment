<#
    Runs the CI checks on this machine with one command (#140), so a change can
    be checked before it is pushed:

        pwsh ./build/Invoke-Local.ps1                       # Lint and Test
        pwsh ./build/Invoke-Local.ps1 -Task Lint,Test,Smoke # as CI, plus the smoke test
        pwsh ./build/Invoke-Local.ps1 -Task All -Coverage

    Lint   the built files match their parts (the three -Check builds), the
           skill copies are identical, PSScriptAnalyzer at -FailOn Warning.
    Test   the Pester suite (-Coverage adds the coverage floor CI uses).
    Smoke  the real assessment end to end; needs PowerShell 7 for the schema check.
    Sample regenerates docs/samples/ (it changes files: look at git diff).

    Pester and PSScriptAnalyzer are installed at the versions pinned in
    .github/workflows/ci.yml when they are missing; a newer version already
    installed is used as it is. Each task runs in its own
    PowerShell process, and one summary table is printed at the end. The exit
    code is 1 when any task failed.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'An interactive helper that prints progress and a summary.')]
[CmdletBinding()]
param(
    [ValidateSet('Lint', 'Test', 'Smoke', 'Sample', 'All')][string[]]$Task = @('Lint', 'Test'),
    [switch]$Coverage
)

function Resolve-LocalTask {
    # Pure: the tasks to run, each once, in the order CI runs them.
    param([string[]]$Task)
    $order = @('Lint', 'Test', 'Smoke', 'Sample')
    $wanted = @($Task)
    if ($wanted -contains 'All') { return $order }
    return @($order | Where-Object { $wanted -contains $_ })
}

function Get-CiToolVersion {
    # Pure: the pinned version of a CI tool, read from the workflow text
    # (PESTER_VERSION, PSSA_VERSION), so the local run uses the version CI uses.
    param([string]$WorkflowText, [string]$Variable)
    $m = [regex]::Match($WorkflowText, '(?m)^\s*' + [regex]::Escape($Variable) + ':\s*([0-9][0-9.]*)\s*$')
    if (-not $m.Success) { throw ('{0} is not set in .github/workflows/ci.yml' -f $Variable) }
    return $m.Groups[1].Value
}

function Get-CiCoverageFloor {
    # Pure: the coverage floor (percent) that the coverage job of CI passes.
    param([string]$WorkflowText)
    $m = [regex]::Match($WorkflowText, '-MinimumCoverage\s+(\d+)')
    if (-not $m.Success) { throw '-MinimumCoverage is not set in .github/workflows/ci.yml' }
    return [int]$m.Groups[1].Value
}

function Get-LocalWarning {
    # Pure: warnings to print before the run. CI runs elevated on Windows
    # runners; the smoke test is the task whose result depends on that.
    param([bool]$IsElevated, [string[]]$Task, [bool]$HasPowerShell7)
    $warnings = New-Object Collections.Generic.List[string]
    if (-not $IsElevated) {
        $warnings.Add('This session is not elevated. CI runs elevated, so a result here can differ, most of all for the smoke test. Start an elevated PowerShell for the same result as CI.')
    }
    if (($Task -contains 'Smoke') -and -not $HasPowerShell7) {
        $warnings.Add('The smoke test needs PowerShell 7 (pwsh) for the JSON Schema check; it will fail without it.')
    }
    return @($warnings)
}

function Format-LocalSummary {
    # Pure: the summary lines. $Results have Name, Passed, Seconds and Note.
    param([object[]]$Results)
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('')
    $lines.Add('Summary')
    foreach ($r in @($Results)) {
        $word = if ($r.Passed) { 'PASS' } else { 'FAIL' }
        $note = if ($r.Note) { '  ' + $r.Note } else { '' }
        $seconds = ([double]$r.Seconds).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
        $lines.Add(('  {0}  {1,-7}{2,6} s{3}' -f $word, $r.Name, $seconds, $note))
    }
    $failed = @($Results | Where-Object { -not $_.Passed })
    if ($failed.Count -eq 0) { $lines.Add('All tasks passed.') }
    else { $lines.Add(('Failed: {0}.' -f (($failed | ForEach-Object { $_.Name }) -join ', '))) }
    return @($lines)
}

if ($MyInvocation.InvocationName -eq '.') { return }

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root
$workflow = [IO.File]::ReadAllText((Join-Path $root '.github/workflows/ci.yml'))
$tasks = @(Resolve-LocalTask -Task $Task)
$shell = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
foreach ($w in @(Get-LocalWarning -IsElevated $elevated -Task $tasks -HasPowerShell7 ($shell -eq 'pwsh'))) { Write-Host ('WARNING: ' + $w) -ForegroundColor Yellow }

function Invoke-Step {
    # One command in its own PowerShell process; true when it exited with 0.
    param([string]$Title, [string[]]$Arguments)
    Write-Host ('  > ' + $Title)
    # Out-Host: the output goes to the console and is not part of the return value.
    & $shell -NoProfile -ExecutionPolicy Bypass @Arguments | Out-Host
    return ($LASTEXITCODE -eq 0)
}

$results = New-Object Collections.Generic.List[object]
foreach ($name in $tasks) {
    Write-Host ''
    Write-Host ('== {0}' -f $name) -ForegroundColor Cyan
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $passed = $true
    $note = ''
    try {
        switch ($name) {
            'Lint' {
                $steps = @(
                    @('Built file matches its parts', '-File', './build/Build-Script.ps1', '-Check'),
                    @('Get-IPUEolStatus.ps1 matches its parts', '-File', './build/Build-Script.ps1', '-Check', '-Manifest', 'src/eol/manifest.txt', '-OutputPath', 'src/Get-IPUEolStatus.ps1'),
                    @('Merge-IPUAssessments.ps1 matches its parts', '-File', './build/Build-Script.ps1', '-Check', '-Manifest', 'src/merge/manifest.txt', '-OutputPath', 'src/Merge-IPUAssessments.ps1'),
                    @('Skill copies are identical', '-File', './build/Sync-Skills.ps1', '-Check'),
                    @('Install PSScriptAnalyzer', '-File', './build/Install-CiModule.ps1', '-Name', 'PSScriptAnalyzer', '-RequiredVersion', (Get-CiToolVersion -WorkflowText $workflow -Variable 'PSSA_VERSION'), '-AcceptNewer'),
                    @('PSScriptAnalyzer', '-File', './build/Invoke-CiLint.ps1', '-FailOn', 'Warning')
                )
                foreach ($s in $steps) { if (-not (Invoke-Step -Title $s[0] -Arguments $s[1..($s.Count - 1)])) { $passed = $false; $note = $s[0]; break } }
            }
            'Test' {
                if (-not (Invoke-Step -Title 'Install Pester' -Arguments @('-File', './build/Install-CiModule.ps1', '-Name', 'Pester', '-RequiredVersion', (Get-CiToolVersion -WorkflowText $workflow -Variable 'PESTER_VERSION'), '-SkipPublisherCheck', '-AcceptNewer'))) { $passed = $false; $note = 'Install Pester' }
                else {
                    $args2 = @('-File', './build/Invoke-CiTests.ps1')
                    if ($Coverage) { $args2 += @('-Coverage', '-MinimumCoverage', (Get-CiCoverageFloor -WorkflowText $workflow)) }
                    if (-not (Invoke-Step -Title 'Pester' -Arguments $args2)) { $passed = $false; $note = 'Pester' }
                }
            }
            'Smoke' {
                if (-not (Invoke-Step -Title 'Smoke test' -Arguments @('-File', './build/Invoke-SmokeTest.ps1'))) { $passed = $false; $note = 'Smoke test' }
            }
            'Sample' {
                if (-not (Invoke-Step -Title 'Sample report' -Arguments @('-File', './build/New-SampleReport.ps1'))) { $passed = $false; $note = 'Sample report' }
                else { $note = 'docs/samples/ rewritten: check git diff' }
            }
        }
    } catch {
        $passed = $false
        $note = $_.Exception.Message
    }
    $watch.Stop()
    $results.Add([pscustomobject]@{ Name = $name; Passed = $passed; Seconds = $watch.Elapsed.TotalSeconds; Note = $note })
}

foreach ($line in @(Format-LocalSummary -Results $results.ToArray())) { Write-Host $line }
if (@($results | Where-Object { -not $_.Passed }).Count -gt 0) { exit 1 }
