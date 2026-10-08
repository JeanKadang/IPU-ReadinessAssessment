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
$script:Passed = 0
$script:Facts = New-Object System.Collections.Generic.List[string]
function Assert-That([bool]$Condition, [string]$Message) {
    if ($Condition) { $script:Passed++; Write-Host ('[pass] ' + $Message) }
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

function Invoke-Assessment([string]$Mode, [string]$Folder = $reports, [string]$Extra = '') {
    # -Command (not -File) so that [bool] parameters receive real booleans.
    $command = "& '" + $scriptPath + "' -AssessmentMode " + $Mode + " -ReportDirectory '" + $Folder + "' -PolicyEvidenceRoot '" + $evidence + "' -RunDISMScanHealth `$false -RunSFCVerifyOnly `$false " + $Extra + "; exit `$LASTEXITCODE"
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
    if ($preJson) { $script:Facts.Add(('Pre: overall {0}, {1} records, {2} checks completed' -f $preJson.Overall, @($preJson.Results).Count, @($preJson.CheckRuns | Where-Object { $_.Outcome -eq 'Completed' }).Count)) }

    $post = Invoke-Assessment 'Post'
    Assert-That ($post.Exit -eq 0) 'Post run exits with 0'
    Assert-That ($post.Fields.Count -ge 12 -and $post.Fields[1] -eq 'SUCCEEDED') ('Post run reports RunStatus SUCCEEDED (got: ' + ($post.Fields -join ';') + ')')
    if ($post.Exit -ne 0 -or $post.Fields.Count -lt 2) { $post.Output | Select-Object -Last 40 | ForEach-Object { Write-Host ('  > ' + $_) } }
    Test-Report (Join-Path $reports ($computer + '-IPU-PostUpgrade.html')) @('Windows Server Post-Upgrade Verification', 'Post-Upgrade Comparison', 'Before/after comparison')
    $postJson = Test-ResultJson (Join-Path $reports ($computer + '-IPU-PostUpgrade.json')) 'Post'
    if ($postJson) {
        $baselineRow = @($postJson.Results | Where-Object { $_.Area -eq 'POST_UPGRADE' -and $_.Item -eq 'Baseline' }) | Select-Object -First 1
        Assert-That ($baselineRow -and $baselineRow.Status -eq 'INFO') 'Post run read the Pre result as its baseline'
        $script:Facts.Add(('Post: overall {0}, {1} checks completed' -f $postJson.Overall, @($postJson.CheckRuns | Where-Object { $_.Outcome -eq 'Completed' }).Count))
    }

    # Redacted run: neutral file names, no computer name or IPv4 address of
    # the runner in the HTML or JSON, Redacted = true, still schema-valid.
    $redactedFolder = Join-Path $work 'redacted'
    $red = Invoke-Assessment 'Pre' $redactedFolder '-RedactReport $true'
    Assert-That ($red.Exit -eq 0 -and $red.Fields.Count -ge 12 -and $red.Fields[1] -eq 'SUCCEEDED') 'Redacted run succeeds'
    $redHtml = @(Get-ChildItem -LiteralPath $redactedFolder -Filter 'REDACTED-*-IPU-Assessment.html' -ErrorAction SilentlyContinue)
    $redJson = @(Get-ChildItem -LiteralPath $redactedFolder -Filter 'REDACTED-*-IPU-Assessment.json' -ErrorAction SilentlyContinue)
    Assert-That ($redHtml.Count -eq 1 -and $redJson.Count -eq 1) 'Redacted run writes REDACTED-* files'
    Assert-That (@(Get-ChildItem -LiteralPath $redactedFolder -Filter ($computer + '-IPU-Assessment.*') -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ne '.log' }).Count -eq 0) 'Redacted run writes no report named after the computer'
    if ($redHtml.Count -eq 1 -and $redJson.Count -eq 1) {
        $secrets = @($env:COMPUTERNAME) + @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' | ForEach-Object { $_.IPAddress } | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notmatch '^127\.' })
        $texts = @([IO.File]::ReadAllText($redHtml[0].FullName), [IO.File]::ReadAllText($redJson[0].FullName))
        foreach ($secret in $secrets) {
            Assert-That (@($texts | Where-Object { $_ -match ('(?<![\w.])' + [regex]::Escape($secret) + '(?![\w.])') }).Count -eq 0) ('Redacted output does not contain the runner''s ' + $(if ($secret -eq $env:COMPUTERNAME) { 'computer name' } else { 'IPv4 address' }))
        }
        # Leak check (#100): no host name outside the allow-list of documentation
        # domains, and none of the runner's service or task accounts.
        $keep = 'microsoft\.com|windows\.com|windowsupdate\.com|trendmicro\.com|broadcom\.com|vmware\.com|asp\.net|microsoft\.net|example\.test|example\.com'
        $fqdnPattern = '(?<![\w.@-])(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+(?:com|net|org|local|lan|corp|internal|dk|se|no|de|eu|io|cloud)(?![\w-]|\.[A-Za-z0-9])'
        $hosts = @($texts | ForEach-Object { [regex]::Matches($_, $fqdnPattern) | ForEach-Object { $_.Value } } | Where-Object { $_ -notmatch ('(^|\.)(' + $keep + ')$') } | Sort-Object -Unique)
        Assert-That ($hosts.Count -eq 0) ('Redacted output has no host names outside the allow-list' + $(if ($hosts.Count) { ' (found ' + $hosts.Count + ')' } else { '' }))
        $accounts = @(@(Get-CimInstance Win32_Service | ForEach-Object { [string]$_.StartName }) + @(Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Principal.UserId }) |
            Where-Object { $_ } | ForEach-Object { ($_ -split '\\')[-1].TrimStart('.') } |
            Where-Object { $_.Length -ge 3 -and $_ -notmatch '^(SYSTEM|LocalSystem|LOCAL SERVICE|LocalService|NETWORK SERVICE|NetworkService|INTERACTIVE|Users|Administrators|Administrator|Everyone|Guest)$' -and $_ -notmatch '^S-1-' } | Sort-Object -Unique)
        $leaked = @($accounts | Where-Object { $a = $_; @($texts | Where-Object { $_ -match ('(?<![\w.-])' + [regex]::Escape($a) + '(?![\w-])') }).Count -gt 0 })
        # Where a leak is (#114): the account's source and the JSON rows and
        # fields holding it, with the name itself replaced. A public CI log
        # must never show the runner's account names.
        if ($leaked.Count -gt 0) {
            $leakJson = [IO.File]::ReadAllText($redJson[0].FullName) | ConvertFrom-Json
            $i = 0
            foreach ($a in $leaked) {
                $i++
                # Case-insensitive, like the -match that found the leak.
                $pattern = '(?i)(?<![\w.-])' + [regex]::Escape($a) + '(?![\w-])'
                $sources = @()
                if (@(Get-CimInstance Win32_Service | Where-Object { ([string]$_.StartName -split '\\')[-1].TrimStart('.') -eq $a }).Count) { $sources += 'service logon account' }
                foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { ([string]$_.Principal.UserId -split '\\')[-1].TrimStart('.') -eq $a })) {
                    $sources += $(if ($t.TaskPath -like '\Microsoft\*') { 'task principal (Microsoft task)' } else { 'task principal (non-Microsoft task)' })
                }
                $where = @()
                foreach ($r in @($leakJson.Results)) {
                    foreach ($field in 'Item', 'Value', 'Details', 'Recommendation', 'Source', 'Command') {
                        $v = [string]$r.$field
                        $m = [regex]::Match($v, $pattern)
                        if (-not $m.Success) { continue }
                        $before = $v.Substring(0, $m.Index)
                        $context = 'text'
                        if ($before -match '(?i)\\Users\\$') { $context = 'user profile path' } elseif ($before -match '[\\/]$') { $context = 'path' } elseif ($before -match '(?i)WinNT://[^/]*/$') { $context = 'WinNT path' }
                        $where += ('{0}/{1}/{2} ({3})' -f $r.Area, ([regex]::Replace([string]$r.Item, $pattern, '<leak>')), $field, $context)
                    }
                }
                foreach ($k in @($leakJson.Facts.PSObject.Properties)) { if ([regex]::IsMatch([string]$k.Value, $pattern)) { $where += ('Facts/' + $k.Name) } }
                # Anywhere else in the raw JSON (Snapshot, CheckRuns, property
                # names): the surrounding text, with the name masked.
                $rawJson = [IO.File]::ReadAllText($redJson[0].FullName)
                foreach ($m in @([regex]::Matches($rawJson, $pattern) | Select-Object -First 5)) {
                    $start = [Math]::Max(0, $m.Index - 60)
                    $snippet = $rawJson.Substring($start, [Math]::Min($rawJson.Length - $start, $m.Length + 120))
                    $where += ('raw JSON: ...' + ([regex]::Replace($snippet, $pattern, '<leak>') -replace '\s+', ' ') + '...')
                }
                if ([regex]::IsMatch([IO.File]::ReadAllText($redHtml[0].FullName), $pattern) -and $where.Count -eq 0) { $where += 'HTML only' }
                Write-Host ('::warning title=Redaction leak {0}::source: {1}; found in: {2}' -f $i, ((@($sources | Sort-Object -Unique) -join ', ')), ((@($where | Select-Object -First 15) -join '; ')))
            }
        }
        Assert-That ($leaked.Count -eq 0) ('Redacted output has none of the runner''s ' + $accounts.Count + ' service and task account names' + $(if ($leaked.Count) { ' (leaked ' + $leaked.Count + ')' } else { '' }))
        $redObj = Test-ResultJson $redJson[0].FullName 'Pre'
        if ($redObj) { Assert-That ([bool]$redObj.Redacted) 'Redacted JSON has Redacted = true' }
    }

    # Site data files (#32): a pattern file that adds a workload matching a
    # service every Windows host has, and a profile that raises the C: target
    # above any runner disk. MaxPatchAgeDays is also an argument, so the
    # profile value must be ignored.
    $siteFolder = Join-Path $work 'sitedata'
    $null = New-Item -ItemType Directory -Path $siteFolder -Force
    $patternPath = Join-Path $work 'patterns.json'
    $profilePath = Join-Path $work 'profile.json'
    [IO.File]::WriteAllText($patternPath, '{ "Schema": "IPU-Patterns/1", "Workloads": [ { "Label": "Smoke test workload", "Service": "^EventLog$" } ] }')
    [IO.File]::WriteAllText($profilePath, '{ "Schema": "IPU-Profile/1", "Settings": { "MinimumCFreeGB": 2048, "MaxPatchAgeDays": 1 } }')
    $site = Invoke-Assessment 'Pre' $siteFolder ("-PatternFile '" + $patternPath + "' -ProfileFile '" + $profilePath + "' -MaxPatchAgeDays 3650")
    Assert-That ($site.Exit -eq 0 -and $site.Fields.Count -ge 12 -and $site.Fields[1] -eq 'SUCCEEDED') 'Run with site data files succeeds'
    $siteJson = Test-ResultJson (Join-Path $siteFolder ($computer + '-IPU-Assessment.json')) 'Pre'
    if ($siteJson) {
        $rows = @($siteJson.Results)
        $patternRow = @($rows | Where-Object { $_.Item -eq 'Pattern file' }) | Select-Object -First 1
        $profileRow = @($rows | Where-Object { $_.Item -eq 'Profile file' }) | Select-Object -First 1
        Assert-That ($patternRow -and $patternRow.Status -eq 'INFO') ('Pattern file applied (got: ' + $(if ($patternRow) { $patternRow.Status + ' ' + $patternRow.Details } else { 'no row' }) + ')')
        Assert-That ($profileRow -and $profileRow.Status -eq 'INFO') ('Profile file applied (got: ' + $(if ($profileRow) { $profileRow.Status + ' ' + $profileRow.Details } else { 'no row' }) + ')')
        Assert-That (@($rows | Where-Object { $_.Area -eq 'WORKLOAD' -and $_.Item -eq 'Smoke test workload' }).Count -eq 1) 'The added pattern detects its workload'
        Assert-That (@($rows | Where-Object { $_.Area -eq 'STORAGE' -and $_.Item -eq 'CFreeSpace' -and $_.Status -eq 'ACTION' }).Count -eq 1) 'The profile threshold is used (C: below 2048 GB)'
        Assert-That ($profileRow -and $profileRow.Details -match 'MaxPatchAgeDays: the argument given to the script was used') 'An argument wins over the profile'
    }
    $plain = @(Get-Content -LiteralPath (Join-Path $reports ($computer + '-IPU-Assessment.json')) -Raw | ConvertFrom-Json)
    Assert-That (@($plain[0].Results | Where-Object { $_.Item -eq 'Pattern file' -or $_.Item -eq 'Profile file' }).Count -eq 0) 'A run without site data files writes no site data row'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

$summary = @('### Smoke test on PowerShell ' + $PSVersionTable.PSVersion, '', ('Failures: {0}' -f $script:Failures.Count))
foreach ($f in $script:Failures) { $summary += ('- ' + $f) }
if ($env:GITHUB_STEP_SUMMARY) { $summary -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8 }
Write-Host ('::notice title=Smoke test (PowerShell ' + $PSVersionTable.PSVersion + ')::Assertions passed ' + $script:Passed + ', failed ' + $script:Failures.Count + '. ' + ($script:Facts -join '. '))
if ($script:Failures.Count -gt 0) { exit 1 }
