<#
    End-to-end smoke test for CI (issue #26). Runs the real assessment on the
    Windows runner in the same PowerShell edition that runs this script,
    first in Pre mode, then in Post mode against the Pre result, and checks:
      - exit code 0 and RunStatus SUCCEEDED in the SA result line
      - the HTML passes the report's own sanity rules and has the chapters
      - the JSON matches docs/result-schema.json
      - every check completed (a failed check is a bug: the script must
        handle a missing feature or tool without failing)
    DISM and SFC are switched off to keep the run short. Output goes to a
    temporary folder and is deleted; nothing is uploaded.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'GitHub workflow commands must be written to the host stream.')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:Failures = New-Object System.Collections.Generic.List[string]
function Assert-That([bool]$Condition, [string]$Message) {
    if ($Condition) { Write-Host ('[pass] ' + $Message) }
    else { Write-Host ('::error title=Smoke test::' + $Message); $script:Failures.Add($Message) }
}

$repo = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repo 'src\Windows-IPU-Readiness-Assessment.ps1'
$schemaPath = Join-Path $repo 'docs\result-schema.json'
$work = Join-Path ([IO.Path]::GetTempPath()) ('ipu-smoke-' + [guid]::NewGuid().ToString('N'))
$reports = Join-Path $work 'reports'
$evidence = Join-Path $work 'evidence'
$engine = Join-Path $PSHOME 'powershell.exe'
if ($PSVersionTable.PSVersion.Major -ge 6) { $engine = Join-Path $PSHOME 'pwsh.exe' }
$computer = ($env:COMPUTERNAME -replace '[^A-Za-z0-9_.-]', '_')

function Invoke-Assessment([string]$Mode) {
    # -Command (not -File) so that [bool] parameters receive real booleans.
    $command = "& '" + $scriptPath + "' -AssessmentMode " + $Mode + " -ReportDirectory '" + $reports + "' -PolicyEvidenceRoot '" + $evidence + "' -RunDISMScanHealth `$false -RunSFCVerifyOnly `$false; exit `$LASTEXITCODE"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $output = @(& $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1 | ForEach-Object { [string]$_ })
    $sw.Stop()
    $exit = $LASTEXITCODE
    Write-Host ('{0} run: exit {1}, {2:N0} s, {3} output lines' -f $Mode, $exit, $sw.Elapsed.TotalSeconds, $output.Count)
    $headerIndex = [array]::IndexOf($output, 'ComputerName;RunStatus;AssessmentStatus;ReportPath;LogPath;ReportSizeKB;Records;Started;Completed;Duration;CollectorVersion;Message')
    $fields = @()
    if ($headerIndex -ge 0 -and $output.Count -gt $headerIndex + 1) { $fields = $output[$headerIndex + 1] -split ';' }
    return [pscustomobject]@{ Exit = $exit; Output = $output; Fields = $fields }
}

function Test-Report([string]$HtmlPath, [string[]]$Chapters) {
    Assert-That (Test-Path -LiteralPath $HtmlPath) ('HTML exists: ' + (Split-Path $HtmlPath -Leaf))
    if (-not (Test-Path -LiteralPath $HtmlPath)) { return }
    $html = [IO.File]::ReadAllText($HtmlPath)
    Assert-That ($html.Length -ge 2048 -and $html -match '(?is)^\s*<!doctype html' -and $html -match '(?is)</html>\s*$') 'HTML passes the report sanity rules'
    Assert-That ($html -notmatch 'PARTIAL REPORT') 'HTML is the final report, not the checkpoint'
    foreach ($c in $Chapters) { Assert-That ($html.Contains($c)) ('HTML has "' + $c + '"') }
}

function Test-ResultJson([string]$JsonPath, [string]$Mode) {
    Assert-That (Test-Path -LiteralPath $JsonPath) ('JSON exists: ' + (Split-Path $JsonPath -Leaf))
    if (-not (Test-Path -LiteralPath $JsonPath)) { return $null }
    $text = [IO.File]::ReadAllText($JsonPath)
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) {
        # Schema validation needs PowerShell 7 (Test-Json -Schema); the JSON
        # itself may have been written by Windows PowerShell 5.1.
        $check = "`$ErrorActionPreference='Stop'; try { if (Test-Json -Json ([IO.File]::ReadAllText('" + $JsonPath + "')) -Schema ([IO.File]::ReadAllText('" + $schemaPath + "'))) { 'VALID' } } catch { 'INVALID: ' + `$_.Exception.Message + ' ' + (`$_.ErrorDetails | Out-String) }"
        $verdict = (& $pwsh.Source -NoProfile -NonInteractive -Command $check 2>&1 | Out-String).Trim()
        Assert-That ($verdict -eq 'VALID') ('JSON matches docs/result-schema.json (' + $Mode + ')' + $(if ($verdict -ne 'VALID') { ': ' + $verdict } else { '' }))
    } else {
        Assert-That $false 'pwsh is needed to validate the JSON schema'
    }
    $obj = $text | ConvertFrom-Json
    Assert-That ($obj.Mode -eq $Mode) ('JSON Mode is ' + $Mode)
    Assert-That (-not $obj.Partial) 'JSON is the final result'
    $failed = @($obj.CheckRuns | Where-Object { $_.Outcome -eq 'Failed' })
    foreach ($f in $failed) { Write-Host ('::error title=Check failed on the runner::' + $f.Name + ': ' + $f.Message) }
    Assert-That ($failed.Count -eq 0) ('Every check completed (' + $Mode + ', ' + @($obj.CheckRuns).Count + ' checks)')
    return $obj
}

try {
    Write-Host ('Engine: ' + $engine + ' (PowerShell ' + $PSVersionTable.PSVersion + ')')

    $pre = Invoke-Assessment 'Pre'
    Assert-That ($pre.Exit -eq 0) 'Pre run exits with 0'
    Assert-That ($pre.Fields.Count -ge 12 -and $pre.Fields[1] -eq 'SUCCEEDED') ('Pre run reports RunStatus SUCCEEDED (got: ' + ($pre.Fields -join ';') + ')')
    if ($pre.Exit -ne 0 -or $pre.Fields.Count -lt 2) { $pre.Output | Select-Object -Last 40 | ForEach-Object { Write-Host ('  > ' + $_) } }
    Test-Report (Join-Path $reports ($computer + '-IPU-Assessment.html')) @('Windows Server IPU Readiness Assessment', 'IPU decision - must be resolved', 'Upgrade Path, Licensing and Windows Health', 'Assessment and Collector', 'Collector coverage')
    $preJson = Test-ResultJson (Join-Path $reports ($computer + '-IPU-Assessment.json')) 'Pre'
    if ($preJson) { Write-Host ('Pre result: Overall ' + $preJson.Overall + ', ' + @($preJson.Results).Count + ' records') }

    $post = Invoke-Assessment 'Post'
    Assert-That ($post.Exit -eq 0) 'Post run exits with 0'
    Assert-That ($post.Fields.Count -ge 12 -and $post.Fields[1] -eq 'SUCCEEDED') ('Post run reports RunStatus SUCCEEDED (got: ' + ($post.Fields -join ';') + ')')
    if ($post.Exit -ne 0 -or $post.Fields.Count -lt 2) { $post.Output | Select-Object -Last 40 | ForEach-Object { Write-Host ('  > ' + $_) } }
    Test-Report (Join-Path $reports ($computer + '-IPU-PostUpgrade.html')) @('Windows Server Post-Upgrade Verification', 'Post-Upgrade Comparison', 'Before/after comparison')
    $postJson = Test-ResultJson (Join-Path $reports ($computer + '-IPU-PostUpgrade.json')) 'Post'
    if ($postJson) {
        $baselineRow = @($postJson.Results | Where-Object { $_.Area -eq 'POST_UPGRADE' -and $_.Item -eq 'Baseline' }) | Select-Object -First 1
        Assert-That ($baselineRow -and $baselineRow.Status -eq 'INFO') 'Post run read the Pre result as its baseline'
        Write-Host ('Post result: Overall ' + $postJson.Overall)
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

$summary = @('### Smoke test on PowerShell ' + $PSVersionTable.PSVersion, '', ('Failures: {0}' -f $script:Failures.Count))
foreach ($f in $script:Failures) { $summary += ('- ' + $f) }
if ($env:GITHUB_STEP_SUMMARY) { $summary -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8 }
Write-Host ('::notice title=Smoke test (PowerShell ' + $PSVersionTable.PSVersion + ')::Failures ' + $script:Failures.Count)
if ($script:Failures.Count -gt 0) { exit 1 }
