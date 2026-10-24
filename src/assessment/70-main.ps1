# =============================================================================
# 7. MAIN
# =============================================================================
function Invoke-Assessment {
    $header = 'ComputerName;RunStatus;AssessmentStatus;ReportPath;LogPath;ReportSizeKB;Records;Started;Completed;Duration;CollectorVersion;Message'
    # An output folder that cannot be written is found now, not after up to an
    # hour of checks (#250): the log file is the first thing written.
    $folderError = ''; $runBusy = $false
    try {
        $script:OutputFolderState = Initialize-OutputFolder $ReportDirectory
        # Before the log is rewritten: a second run must not wipe the first run's log (#244).
        $script:RunLock = Enter-RunLock ($script:LogPath + '.lock')
        if ($script:RunLock) { [IO.File]::WriteAllText($script:LogPath,('Timestamp;Level;Phase;Message' + [Environment]::NewLine),(New-Object System.Text.UTF8Encoding($false))) }
        else { $runBusy = $true }
    } catch { $folderError = $_.Exception.Message }
    if ($runBusy) {
        $now = Get-Date
        [Console]::Out.WriteLine($header)
        [Console]::Out.WriteLine((@(
            $script:ComputerName,'FAILED','MANUAL','','','',0,
            $script:CollectionStarted.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture),$now.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture),
            (Format-Duration ($now - $script:CollectionStarted)),$script:CollectorVersion,
            ('Nothing was assessed: another assessment run on this server is using ' + $ReportDirectory + ' (' + $script:LogPath + '.lock). Wait for it to finish, or give this run another -ReportDirectory.')
        ) | ForEach-Object { ConvertTo-SAField $_ }) -join ';')
        $script:ExitCode = 1
        return
    }
    if ($folderError) {
        Exit-RunLock $script:RunLock
        $now = Get-Date
        [Console]::Out.WriteLine($header)
        [Console]::Out.WriteLine((@(
            $script:ComputerName,'FAILED','MANUAL','','','',0,
            $script:CollectionStarted.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture),$now.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture),
            (Format-Duration ($now - $script:CollectionStarted)),$script:CollectorVersion,
            ('Nothing was assessed: the report folder cannot be written (' + $ReportDirectory + '): ' + $folderError + ' Give -ReportDirectory a folder the account can write to.')
        ) | ForEach-Object { ConvertTo-SAField $_ }) -join ';')
        $script:ExitCode = 1
        return
    }
    Write-AssessmentLog 'INFO' 'START' ('Collector={0} | Mode={1} | Target={2} | PowerShell={3}' -f $script:CollectorVersion,$AssessmentMode,$TargetServerVersion,$PSVersionTable.PSVersion)

    # Prerequisites first (#94): stop with a clear message instead of failing
    # deep inside a check when something required is missing.
    $state = Get-PrerequisiteState
    $prereq = Get-PrerequisiteDecision $state.PowerShellVersion $state.DotNetRelease $state.IsElevated $state.MissingModules
    Write-AssessmentLog 'INFO' 'PREREQ' ('PowerShell={0} | .NET release={1} | Elevated={2} | MissingModules={3}' -f $state.PowerShellVersion,$state.DotNetRelease,$state.IsElevated,(@($state.MissingModules) -join ','))
    foreach ($o in @($prereq.Optional)) { Add-Result 'COLLECTOR' 'Prerequisites' 'MANUAL' $o -Recommendation 'Install the missing component (or the Windows feature that provides it) and run again, or review the affected area manually.' -Kind 'Finding' -Source 'Get-Module -ListAvailable' }
    if (-not $prereq.CanRun) {
        $missingText = 'Missing: ' + (@($prereq.Required) -join ' ')
        Write-AssessmentLog 'ERROR' 'PREREQ' $missingText
        foreach ($r in @($prereq.Required)) { Add-Result 'COLLECTOR' 'Prerequisites' 'MANUAL' 'Not assessed: a required component is missing' $r -Recommendation 'Fix this and run the assessment again. Nothing was collected.' -Kind 'Finding' -Source 'Prerequisites check' }
        $reportPath = ''
        try { $null = Write-AssessmentReport; $reportPath = $script:ReportPath } catch { Write-Swallowed $_ }
        $now = Get-Date
        [Console]::Out.WriteLine($header)
        [Console]::Out.WriteLine((@(
            $script:ComputerName,'FAILED','MANUAL',$reportPath,$script:LogPath,'',$script:Results.Count,
            $script:CollectionStarted.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture),$now.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture),
            (Format-Duration ($now - $script:CollectionStarted)),$script:CollectorVersion,$missingText
        ) | ForEach-Object { ConvertTo-SAField $_ }) -join ';')
        $script:ExitCode = 1
        Exit-RunLock $script:RunLock
        return
    }

    # Anything that throws outside a check (site data, registering checks, the
    # SPECIAL decision, skipping a slow check) must still end in a report and an SA
    # result line, not in a bare error (#251).
    $runFailure = ''
    try {
        Import-SiteDataFile
        Register-AssessmentCheck
        $skip = @()
        if ($AssessmentMode -eq 'Post') { $skip = @('checklist','compatscan') }
        # The baseline first: it decides whether this is a SPECIAL server (#152).
        $baselineCheck = @($script:Checks | Where-Object { $_.Id -eq 'baseline' }) | Select-Object -First 1
        if ($baselineCheck) { Invoke-Check $baselineCheck; $skip += 'baseline' }
        $script:Data.SpecialKind = ''
        if ($AssessmentMode -ne 'Post') {
            try { $script:Data.SpecialKind = Get-SpecialServerState } catch { $script:Data.SpecialKind = 'Undecided'; Write-Swallowed $_ }
        }
        if ($script:Data.SpecialKind -eq 'Cluster' -or $script:Data.SpecialKind -eq 'DomainController') {
            # Short report: only what is needed to choose a plan.
            $keep = Get-SpecialServerCheckId
            Write-AssessmentLog 'INFO' 'SPECIAL' ('Kind=' + $script:Data.SpecialKind + ' | short report with checks: ' + ($keep -join ','))
            foreach ($c in @($script:Checks | Where-Object { $keep -notcontains $_.Id -and $skip -notcontains $_.Id })) {
                $script:CheckRuns.Add([pscustomobject]@{ Id=$c.Id; Name=$c.Name; Phase=$c.Phase; Outcome='Skipped'; Duration='00:00:00'; Seconds=0; Message='Not applicable: SPECIAL server, short report' })
                $skip += $c.Id
            }
        }
        foreach ($check in @($script:Checks | Where-Object { $_.Phase -eq 'Fast' -and $skip -notcontains $_.Id })) { Invoke-Check $check }
        if ($AssessmentMode -eq 'Post') { Invoke-PostUpgradeComparison }

        try { $null = Write-AssessmentReport -Partial } catch { Write-AssessmentLog 'WARNING' 'REPORT' ('Checkpoint report failed: ' + $_.Exception.Message) }

        # PrintBrm, DISM and SFC share one pool; the Setup scan has its own clock (#244).
        $poolMinutes = Get-SlowCheckBudget $SlowCheckBudgetMinutes $PrintBackupTimeoutMinutes (Test-PrintBackupDue $AssessmentMode ([bool]$script:Data.PrintServer) ([bool]$EnablePrintBackup))
        $compatMinutes = 0; if ($TargetMediaPath -and $AssessmentMode -eq 'Pre') { $compatMinutes = $CompatScanTimeoutMinutes }
        $slowWatch = [Diagnostics.Stopwatch]::StartNew()
        foreach ($check in @($script:Checks | Where-Object { $_.Phase -eq 'Slow' -and $skip -notcontains $_.Id })) {
            $plan = Get-SlowCheckPlan $check.Id $poolMinutes $slowWatch.Elapsed.TotalSeconds $compatMinutes $script:CheckRuns.ToArray()
            if ($plan.Skip) {
                Add-SkippedSlowCheck $check $poolMinutes $plan.Reason
                continue
            }
            $script:SlowSecondsLeft = $plan.SecondsLeft
            Invoke-Check $check
        }

    } catch {
        $runFailure = $_.Exception.GetType().Name + ': ' + $_.Exception.Message
        Write-AssessmentLog 'ERROR' 'RUN' ($runFailure + ' | Line ' + $_.InvocationInfo.ScriptLineNumber)
        try { Add-Result 'COLLECTOR' 'Assessment run' 'MANUAL' 'The run stopped early' $runFailure -Recommendation 'Read the log, fix the cause and run again. Checks that had not run yet are missing from this report; absence of findings is NOT evidence of a clean server.' -Source 'Invoke-Assessment' } catch { Write-Swallowed $_ }
    }

    $records = $script:Results.Count
    $failedChecks = @($script:CheckRuns | Where-Object { $_.Outcome -ne 'Completed' }).Count
    $runStatus = 'SUCCEEDED'; if ($runFailure) { $runStatus = 'FAILED' }
    try {
        $final = Write-AssessmentReport
        # A JSON that was asked for and not written is a failed run: the fleet overview and the Post baseline need that file.
        if ($WriteJson -and $final.JsonOutcome -eq 'Failed') { $runStatus = 'FAILED' }
        $specialNote = ''
        if ($script:Data.Special) { $specialNote = 'SPECIAL server (' + $script:Data.Special.Title + '): short report, separate plan needed. ' }
        $msg = $specialNote + 'Mode=' + $AssessmentMode + ', Checks=' + $script:CheckRuns.Count + ', NotCompleted=' + $failedChecks + (Get-JsonOutcomeText $WriteJson $final.JsonOutcome $script:JsonPath) + '. Retrieve the HTML via the approved SA process.'
        if ($runFailure) { $msg = 'The run stopped early (' + $runFailure + '). ' + $msg }
        [Console]::Out.WriteLine($header)
        [Console]::Out.WriteLine((@(
            $script:ComputerName,$runStatus,$final.Overall,$script:ReportPath,$script:LogPath,
            ([Math]::Round($final.Bytes/1KB,1)).ToString('N1',$script:NumberCulture),$records,
            $script:CollectionStarted.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture),$final.Completed.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture),
            (Format-Duration ($final.Completed - $script:CollectionStarted)),$script:CollectorVersion,$msg
        ) | ForEach-Object { ConvertTo-SAField $_ }) -join ';')
        $script:ExitCode = $(if ($runFailure -or $runStatus -eq 'FAILED') { 1 } else { 0 })
    } catch {
        $msg = $_.Exception.GetType().Name + ': ' + $_.Exception.Message
        Write-AssessmentLog 'ERROR' 'FAILED' $msg
        Remove-Item -LiteralPath ($script:ReportPath + '.writing') -Force -ErrorAction SilentlyContinue
        $now = Get-Date
        [Console]::Out.WriteLine($header)
        [Console]::Out.WriteLine((@(
            $script:ComputerName,'FAILED',(Get-OverallStatus $script:Results.ToArray()),$script:ReportPath,$script:LogPath,'',$records,
            $script:CollectionStarted.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture),$now.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture),
            (Format-Duration ($now - $script:CollectionStarted)),$script:CollectorVersion,$msg
        ) | ForEach-Object { ConvertTo-SAField $_ }) -join ';')
        $script:ExitCode = 1
    }
    Exit-RunLock $script:RunLock
}

if ($env:IPU_ASSESSMENT_LIBRARY_ONLY -eq '1') { return }

if ($RedactExisting) { exit (Invoke-RedactExisting $RedactExisting) }

# A 32-bit PowerShell host on 64-bit Windows sees redirected registry
# (Wow6432Node) and System32 (SysWOW64) views, which would silently give wrong
# application, SQL and tool results. Relaunch in 64-bit PowerShell when the
# script has a file path; otherwise continue and flag it in the report.
$script:Is32BitHost = ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess)
if ($script:Is32BitHost -and $env:IPU_ASSESSMENT_RELAUNCHED -ne '1') {
    $selfPath = $MyInvocation.MyCommand.Path
    $ps64 = Join-Path $env:windir 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if ($selfPath -and (Test-Path -LiteralPath $ps64)) {
        $env:IPU_ASSESSMENT_RELAUNCHED = '1'
        # Pass through every parameter the caller gave, typed correctly. If
        # building the command fails, carry on in this 32-bit host: the
        # baseline reports it (#251).
        $relaunchCommand = ''
        try {
            $argText = ConvertTo-RelaunchArgumentText $PSBoundParameters
            $relaunchCommand = "& '" + ($selfPath -replace "'","''") + "'" + $argText + '; exit $LASTEXITCODE'
        } catch { Write-Swallowed $_ }
        if ($relaunchCommand) {
            & $ps64 -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $relaunchCommand
            exit $LASTEXITCODE
        }
    }
}

$script:ExitCode = 1
$null = Invoke-Assessment
exit $script:ExitCode
