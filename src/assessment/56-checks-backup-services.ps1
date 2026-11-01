# Chapter: Backup, services and checklist (docs/checks.md).
# Each check is one function; Register-AssessmentCheck (50-checks.ps1) lists them in run order.

function Invoke-BackupCheck {
    $backup = Find-DetectionMatch $script:DetectionPatterns.Backup $script:Data.Apps $script:Data.Services
    foreach ($m in $backup) {
        Add-Result 'BACKUP' $m.Label 'INFO' ('Applications=' + @($m.Apps).Count + ', Services=' + @($m.Services).Count) (Get-DetectionEvidence $m) -Source 'Uninstall registry, Win32_Service'
    }
    if ($backup.Count -eq 0) {
        Add-Result 'BACKUP' 'GuestBackupAgent' 'INFO' 'No recognized in-guest backup agent' 'VM-level backup is invisible from inside the guest; this does not mean the server is unprotected.' -Source 'Uninstall registry, Win32_Service'
    }

    $vss = Invoke-NativeCapture (Join-Path $env:windir 'System32\vssadmin.exe') @('list','writers') 120
    $writers = ConvertFrom-VssWriterOutput $vss.Lines
    if ($vss.TimedOut -or $writers.Count -eq 0) {
        Add-Result 'BACKUP' 'VSSWriters' 'MANUAL' 'VSS writer state could not be read' @(('TimedOut=' + $vss.TimedOut),$vss.Error) -Recommendation 'Run "vssadmin list writers" manually; failed writers break application-consistent backups and snapshots.' -Kind 'Finding' -Source 'vssadmin list writers'
    }
    $failed = 0
    $noError = Get-VssNoErrorText $writers
    foreach ($w in $writers) {
        $st = Get-VssWriterStatus $w $noError
        if ($st -eq 'ACTION') { $failed++ }
        Add-Result 'BACKUP' ('VSS writer: ' + $w.Name) $st ('[' + $w.StateCode + '] ' + $w.StateText) $w.LastError -Kind 'Evidence' -Source 'vssadmin list writers'
    }
    if ($failed -gt 0) {
        Add-Result 'BACKUP' 'VSSWriters' 'ACTION' ('FailedWriters=' + $failed) -Recommendation 'Resolve VSS writer errors (often fixed by restarting the owning service) so the pre-change backup/snapshot is application-consistent.' -Source 'vssadmin list writers'
    }
    foreach ($prov in @(Get-CimSafe 'Win32_ShadowProvider')) {
        $st = 'OK'; $rec = ''
        if ($prov.Name -notmatch '^Microsoft (Software|File Share) Shadow Copy provider') { $st = 'WARNING'; $rec = 'Third-party VSS provider: confirm it supports the target OS.' }
        Add-Result 'BACKUP' ('VSS provider: ' + $prov.Name) $st ('Version=' + $prov.Version) -Recommendation $rec -Kind 'Observation' -Source 'Win32_ShadowProvider'
    }
}

function Invoke-ServicesCheck {
    $auto = @($script:Data.Services | Where-Object { $_.StartMode -eq 'Auto' })
    $autoStopped = @($auto | Where-Object { $_.State -ne 'Running' })
    Add-Result 'SERVICES' 'AutomaticServices' 'INFO' ('Total=' + $auto.Count) ('NotRunning=' + $autoStopped.Count) -Recommendation 'Save this list. After IPU, compare which Automatic services are running to spot what did not come back.' -Source 'Win32_Service'
    foreach ($s in @($script:Data.Services | Where-Object { $_.StartName })) { Add-RedactionLiteral ([string]$s.StartName) 'ACCOUNT' }
    foreach ($s in @($script:Data.Services | Where-Object { $_.StartMode -in @('Auto','Manual') } | Sort-Object StartMode,DisplayName)) {
        Add-Result 'SERVICES' $s.Name 'INFO' $s.DisplayName @(('State=' + $s.State),('StartMode=' + $s.StartMode),('LogOnAs=' + $s.StartName)) -Source 'Win32_Service'
    }
}

function Invoke-TasksCheck {
    if (-not (Test-CommandAvailable 'Get-ScheduledTask')) {
        Add-Result 'TASKS' 'ScheduledTasks' 'INFO' 'Get-ScheduledTask unavailable' -Source 'ScheduledTasks module'
        return
    }
    $named = @(); $perUser = 0
    foreach ($t in @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } | Sort-Object TaskPath,TaskName)) {
        $user = [string]$t.Principal.UserId
        if (-not $user) { $user = [string]$t.Principal.GroupId }
        $actions = @($t.Actions | ForEach-Object { (([string]$_.Execute) + ' ' + ([string]$_.Arguments)).Trim() } | Where-Object { $_ }) -join '; '
        $fullName = $t.TaskPath + $t.TaskName
        $isBuiltIn = Test-BuiltInTaskAccount $user ([string]$t.Principal.LogonType)
        if ($user -and -not $isBuiltIn) { Add-RedactionLiteral $user 'ACCOUNT' }
        $script:Data.Snapshot.Tasks += $fullName
        # Windows' own per-user feed tasks: one line for all of them (#214).
        if (Test-WindowsPerUserTask $fullName) { $perUser++; continue }
        Add-Result 'TASKS' $fullName 'INFO' ('RunAs=' + $user) @(('State=' + $t.State),('Action=' + $actions)) -Source 'Get-ScheduledTask'
        if ($user -and -not $isBuiltIn) { $named += ($fullName + ' (' + $user + ')') }
    }
    if ($perUser -gt 0) {
        Add-Result 'TASKS' 'WindowsPerUserTasks' 'INFO' ('Count=' + $perUser) 'User_Feed_Synchronization-{GUID}: created by Windows for each user who signed in; they run as that user.' -Recommendation 'Not relevant for the upgrade.' -Source 'Get-ScheduledTask'
    }
    if ($named.Count -gt 0) {
        Add-Result 'TASKS' 'TasksWithNamedAccounts' 'WARNING' ('Count=' + $named.Count) $named -Recommendation 'These tasks run as named accounts with stored credentials. Confirm the passwords are known/managed and test the tasks after IPU.' -Kind 'Observation' -Source 'Get-ScheduledTask'
    }
}

function Invoke-ChecklistCheck {
    $isVM = ($script:Data.Platform.Type -eq 'Virtual')
    $fallback = 'Confirm a tested bare-metal recovery path and a recent successful backup.'
    if ($isVM) { $fallback = 'Confirm a recent successful backup externally, snapshot eligibility (' + $script:Data.Platform.Hypervisor + ') and the approved snapshot procedure.' }
    Add-Result 'CHECKLIST' 'Backup and fallback' 'MANUAL' 'Cannot be proven from inside the guest' -Recommendation $fallback -Kind 'Checklist'
    Add-Result 'CHECKLIST' 'Credentials and console access' 'MANUAL' 'Not provable by an unattended inventory' -Recommendation 'Validate domain logon, PAM checkout and local fallback credentials, plus console (vCenter/iLO/iDRAC) access in case network logon fails.' -Kind 'Checklist'
    $lic = Get-TargetLicensingDecision ([string]$script:Data.ActivationKind) ([string]$script:Data.KmsEndpoint) $TargetServerVersion
    Add-Result 'CHECKLIST' 'Target licensing' 'MANUAL' $lic.Value -Recommendation $lic.Text -Kind 'Checklist'
    $media = $script:Data.RecommendedMedia; if (-not $media) { $media = 'See Upgrade path section' }
    Add-Result 'CHECKLIST' 'Installation media' 'MANUAL' $media -Recommendation 'Use media with the exact edition, installation type and language listed. Start Setup with /ResizeRecoveryPartition Disable, so Setup does not shrink C: to add a recovery partition after it (#161). Optional pre-flight: setup.exe /auto upgrade /compat scanonly with the same media.' -Kind 'Checklist' -Command (Get-RecommendationCommand 'SetupNoRecoveryPartition').Command -CommandKind 'Change' -Link $script:DocLinks.SetupOptions.Url -LinkTitle $script:DocLinks.SetupOptions.Title
    Add-Result 'CHECKLIST' 'Application owner sign-off' 'MANUAL' 'Required for every listed workload' -Recommendation 'Get sign-off from each workload owner, including a post-upgrade test plan.' -Kind 'Checklist'
    Add-Result 'CHECKLIST' 'Monitoring and management agents' 'MANUAL' 'Backend communication cannot be proven locally' -Recommendation 'Confirm SA, UD and Operations agents are reporting in the backend before the change; verify again afterwards.' -Kind 'Checklist'
}
