# =============================================================================
# 1. PARAMETERS / SETTINGS (defaults are what SA uses when no arguments are given)
# =============================================================================
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleCommands', 'Get-MpComputerStatus', Justification = 'Called only after Test-CommandAvailable confirms it exists (Defender is not part of Windows Server 2012 R2).')]
[CmdletBinding()]
param(
    # Planned destination release.
    [ValidateSet('2025','2022')][string]$TargetServerVersion = '2025',

    # Pre = readiness assessment before the upgrade.
    # Post = verification after the upgrade, compared with the Pre result.
    [ValidateSet('Pre','Post')][string]$AssessmentMode = 'Pre',

    # Language of the target ISO, e.g. 'en-US'. Blank = report tells you.
    [ValidatePattern('^$|^[a-zA-Z]{2,3}(-[a-zA-Z0-9]{2,8})*$')][string]$TargetMediaLanguage = '',

    # Optional: target installation media for Setup's own compatibility scan.
    # A folder or drive containing setup.exe, a UNC share (the computer
    # account needs read access), or an .iso file on the server. Blank = skip.
    [ValidateScript({ $_ -eq '' -or [IO.Path]::IsPathRooted($_) })][string]$TargetMediaPath = '',

    # Site policy, on by default: a domain controller is reported as SPECIAL
    # (replace it side-by-side) instead of as a normal in-place upgrade. A
    # profile file can switch it off (see the user guide).
    [bool]$BlockDomainControllerIPU = $true,

    # Operational thresholds (project values, not Microsoft minimums unless noted).
    [ValidateRange(1, 2048)][int]$MinimumCFreeGB = 40,
    [ValidateRange(1, 1024)][int]$ExtendBlockGB = 10,
    [ValidateRange(1, 4096)][int]$MinimumMemoryGB = 8,
    [ValidateRange(1, 3650)][int]$MaxPatchAgeDays = 60,
    [ValidateRange(1, 3650)][int]$UptimeWarningDays = 60,
    [ValidateRange(1, 365)][int]$GroupPolicyMaxAgeDays = 7,
    [ValidateRange(1, 365)][int]$AVMaxAgeDays = 3,
    [ValidateRange(1, 3650)][int]$CertificateWarningDays = 90,
    [ValidateRange(1, 180)][int]$KmsRenewWarnDays = 165,   # a KMS activation lasts 180 days and renews every 7: below 165 days left, two renewals were missed
    [ValidateRange(1, 10240)][int]$SystemPartitionMinFreeMB = 50,
    [ValidateRange(1, 10240)][int]$RecoveryPartitionMinFreeMB = 250,   # Microsoft's WinRE servicing guidance

    # Slow, read-only checks. Each is time-boxed; DISM and SFC share one budget.
    [bool]$RunDISMScanHealth = $true,
    [bool]$RunSFCVerifyOnly = $true,
    [ValidateRange(1, 240)][int]$DISMTimeoutMinutes = 30,
    [ValidateRange(1, 240)][int]$SFCTimeoutMinutes = 30,
    [ValidateRange(1, 600)][int]$SlowCheckBudgetMinutes = 50,
    [ValidateRange(1, 240)][int]$CompatScanTimeoutMinutes = 45,

    # Evidence copies (#198): one restricted folder with a subfolder per
    # topic - Policy, IIS, Network, Printers - and a README. Unredacted:
    # never part of the report; copy it off the server before the change.
    [ValidateScript({ [IO.Path]::IsPathRooted($_) })][string]$EvidenceRoot = 'C:\Temp\IPU-Evidence',
    # RDP access/policy evidence. LGPO.exe is optional (backup only).
    [bool]$EnableRDPPolicyEvidence = $true,
    [ValidateScript({ $_ -eq '' -or [IO.Path]::IsPathRooted($_) })][string]$LgpoExe = 'C:\Temp\Tools\LGPO.exe',
    # Blank = EvidenceRoot\Policy. Set it to keep the policy evidence in an
    # older location (before 4.5.1: C:\Temp\Tools\PolBackup).
    [ValidateScript({ $_ -eq '' -or [IO.Path]::IsPathRooted($_) })][string]$PolicyEvidenceRoot = '',
    [bool]$CreatePolicyEvidenceZip = $true,
    # When IIS is installed, copy its configuration files (the same files
    # "appcmd add backup" saves) into a restricted evidence folder and ZIP
    # under EvidenceRoot\IIS. A read-only copy; IIS itself is not touched.
    [bool]$EnableIISConfigEvidence = $true,
    # Save ipconfig /all, route print and the netsh interface configuration
    # (a script that can re-apply it) into a restricted evidence folder and
    # ZIP under EvidenceRoot\Network (#149). Never redacted: copy it off the
    # server before the change, and do not share it.
    [bool]$EnableNetworkEvidence = $true,
    # On a print server, export printers, ports and drivers with PrintBrm -B
    # into a restricted evidence folder under EvidenceRoot\Printers (#148). Skipped
    # (MANUAL, with the command) when the drive lacks 1.5 x the size of
    # spool\drivers + 1 GB. A slow check: counts against the time budget.
    [bool]$EnablePrintBackup = $true,
    [ValidateRange(1, 240)][int]$PrintBackupTimeoutMinutes = 30,

    # End-of-life snapshot (eol-snapshot.json, ADR 0003). Blank = look next to
    # the script, then in the report folder. Reading a file makes no network call.
    [ValidateScript({ $_ -eq '' -or [IO.Path]::IsPathRooted($_) })][string]$EolSnapshotPath = '',

    # Output.
    [ValidateScript({ [IO.Path]::IsPathRooted($_) })][string]$ReportDirectory = 'C:\Temp\IPU-Assessment',
    [bool]$WriteJson = $true,
    # Replace host names, IP and MAC addresses, accounts, SIDs and certificate
    # details with placeholders (HOST-1, IP-3, ...) in the HTML and JSON, for
    # sharing a report outside the team. Best effort - read before sharing.
    # Output files are then named REDACTED-<time>-..., and a redacted result
    # cannot serve as the post-upgrade baseline. The log is not redacted.
    [bool]$RedactReport = $false,
    # Write REDACTED- copies of reports that already exist (a folder or one
    # report file), without collecting anything (#101). The originals stay.
    [ValidateScript({ $_ -eq '' -or [IO.Path]::IsPathRooted($_) })][string]$RedactExisting = '',
    # With -RedactReport or -RedactExisting, also write the key that maps each
    # placeholder to its original name (#211): DO-NOT-SHARE-...-REDACTION-
    # KEY.csv next to the redacted copies, readable by SYSTEM, Administrators
    # and the current user only. Keep it in the team; share only REDACTED-*.
    [bool]$WriteRedactionKey = $true,
    # Folders this run creates (report, policy evidence) get SYSTEM and
    # Administrators access only; reports describe the server in detail.
    # Existing folders are never changed. $false keeps inherited permissions.
    [bool]$RestrictOutputAcl = $true,
    # Culture for numbers in the SA result line. The default is kept for the
    # site's existing SA jobs; set your own in a profile file.
    [string]$NumberCultureName = 'da-DK',

    # Optional site data files (JSON), see the user guide, "Site data files".
    # PatternFile adds, replaces or disables detection patterns (section 2).
    # ProfileFile sets site defaults for the settings above; an argument given
    # to the script still wins. A file that cannot be used is reported as
    # MANUAL and nothing from it is applied. Blank = built-in values only.
    [ValidateScript({ $_ -eq '' -or [IO.Path]::IsPathRooted($_) })][string]$PatternFile = '',
    [ValidateScript({ $_ -eq '' -or [IO.Path]::IsPathRooted($_) })][string]$ProfileFile = ''
)

# Settings given as arguments; they take precedence over a profile file.
$script:BoundParameterNames = @($PSBoundParameters.Keys)


