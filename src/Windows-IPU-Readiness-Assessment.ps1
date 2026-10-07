<#
===============================================================================
 SCRIPT NAME : Windows-IPU-Readiness-Assessment.ps1
 VERSION     : 4.1.0
 RELEASE DATE: 2026-10-06
 PURPOSE     : Windows Server in-place upgrade (IPU) readiness assessment and
               post-upgrade verification, with a self-contained HTML report
               and a JSON result file written on the assessed server.
 EXECUTION   : OpenText Server Automation (SA) Ad-Hoc Scripting, normally as
               the SA Agent / LocalSystem account. Windows PowerShell 4.0+.
===============================================================================

.SYNOPSIS
    Read-only IPU readiness assessment for Windows Server 2012 R2 and later,
    targeting Windows Server 2025 (default) or Windows Server 2022.
    Run once before the upgrade (Mode Pre) and, optionally, once after it
    (Mode Post) to compare the server against its own pre-upgrade snapshot.

.DESCRIPTION
    Pre-upgrade run (default) writes to C:\Temp\IPU-Assessment:
        <ComputerName>-IPU-Assessment.html   report for people
        <ComputerName>-IPU-Assessment.json   same results for tools, and the
                                             baseline for the post-upgrade run
        <ComputerName>-IPU-Assessment.log    collector log
    Post-upgrade run (-AssessmentMode Post) writes
        <ComputerName>-IPU-PostUpgrade.html / .json / .log
    and compares against the pre-upgrade .json in the same folder.

    RDP policy evidence (optional) goes to a timestamped folder and ZIP under
    C:\Temp\Tools\PolBackup. The optional Setup compatibility scan keeps
    Setup's CompatData XML next to the report.

    The report is written TWICE: a PARTIAL checkpoint after the fast checks,
    and the final report after the slow checks (DISM, SFC, optional Setup
    compatibility scan). If SA stops the job, the checkpoint still exists.

    SA receives one semicolon-delimited result line (same header as 3.x/4.0).

.PARAMETERS
    Every setting is a parameter with a default, so the script runs unchanged
    from SA. If your SA job can pass arguments, override any of them, e.g.
        -TargetServerVersion 2022
        -AssessmentMode Post
        -TargetMediaPath 'D:\'   (or an .iso path, or a UNC share)
    Otherwise edit the defaults in the param() block below, or keep site
    defaults in a JSON profile (-ProfileFile) and site detection patterns in
    a JSON pattern file (-PatternFile); see the user guide, Site data files.

.HOW 4.x IS ORGANISED
    1. PARAMETERS / SETTINGS - the only section operators normally change.
    2. DETECTION PATTERNS    - product names, services and drivers used to
                               recognise agents, AV/EDR, backup and workloads.
                               Update here when a vendor renames a product,
                               or override them with -PatternFile.
    3. CORE                  - result model, check runner, helpers, logging.
    4. DECISION RULES        - pure functions (no system access); unit-tested
                               by Windows-IPU-Readiness-Assessment.Tests.ps1.
    5. CHECKS                - one Register-Check block per area.
    6. HTML/JSON REPORT
    7. MAIN

.RESULT KINDS
    Finding     - affects the overall status (BLOCKER/ACTION = decision,
                  WARNING/MANUAL = planning).
    Observation - has a status for visibility, does not affect the overall.
    Checklist   - standard change-procedure steps, listed separately.
    Evidence    - documentation/inventory.

.SAFETY
    - Non-remediating. DISM /ScanHealth and SFC /verifyonly only.
    - LGPO.exe only with /b (backup) and /parse - never /g or /m.
    - No Win32_Product query. Nothing is installed, removed or reconfigured.
    - Side effects, by design: report/log/JSON/evidence files are written.
      Only when TargetMediaPath is set: an .iso is mounted and dismounted
      again, and Setup's compatibility scan creates C:\$WINDOWS.~BT (Setup
      manages that folder; the scan never starts an upgrade).
    - Set the SA job timeout above SlowCheckBudgetMinutes (+ CompatScan-
      TimeoutMinutes when TargetMediaPath is set) + about 15 minutes.

.TESTING OFF-SERVER
    Set IPU_ASSESSMENT_LIBRARY_ONLY=1 and dot-source the script: functions
    load, nothing is collected. The Pester tests use this.

.VERSION HISTORY
    4.1.0 - First tagged release. Opt-in report redaction (-RedactReport);
            optional site data files (-PatternFile, -ProfileFile); output
            folders limited to SYSTEM and Administrators; CIM instead of WMI;
            validated parameters; no silent catch blocks; accessible report
            with dark mode; external tools keep their exit code on Windows
            PowerShell 5.1; HTTP.sys header and pending-rename fixes. Tested
            in CI on Windows PowerShell 5.1 and PowerShell 7 (Server 2022 and
            2025 images). See CHANGELOG.md for the full list.
    4.0.1 - Fixes from the first live run and the 4.0.0 review:
            AV/EDR detection by product name, service and filter driver
            (TrendAI/Deep Security, Defender for Endpoint, CrowdStrike,
            SentinelOne, ...) and the reason Defender status cannot be read;
            Panther setupact.log no longer counted as upgrade evidence;
            mount points and volume labels restored; SA/Operations agent
            names; pending file rename paths shown; "None detected" wording;
            Sysmon and RDP NLA observations. New: param() block, central
            detection pattern table, JSON output (fleet aggregation and
            post-upgrade baseline), post-upgrade comparison mode, VMware
            guest readiness (Tools 12.5.0+ for 2025, certified vSphere
            versions), optional Setup compatibility scan with target media,
            removed/deprecated features for the target, non-Microsoft driver
            inventory, listening ports, non-Microsoft scheduled tasks, system
            and recovery partition free space, swallowed errors logged,
            Recommendation as a named parameter.
    4.0.0 - Restructured: check registry, single area map, pure decision
            rules with unit tests, time-boxed slow checks, checkpoint report,
            standard checklist separated from findings, Microsoft-verified
            upgrade/edition/Exchange/SQL/teaming rules.
    3.5.0 - Local Group Policy backup and RDP readiness (earlier edition,
            superseded by the 4.0.0 restructure).
#>

#requires -Version 4.0

# =============================================================================
# 1. PARAMETERS / SETTINGS (defaults are what SA uses when no arguments are given)
# =============================================================================
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

    # Company policy: domain controllers are replaced side-by-side.
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
    [ValidateRange(1, 10240)][int]$SystemPartitionMinFreeMB = 50,
    [ValidateRange(1, 10240)][int]$RecoveryPartitionMinFreeMB = 250,   # Microsoft's WinRE servicing guidance

    # Slow, read-only checks. Each is time-boxed; DISM and SFC share one budget.
    [bool]$RunDISMScanHealth = $true,
    [bool]$RunSFCVerifyOnly = $true,
    [ValidateRange(1, 240)][int]$DISMTimeoutMinutes = 30,
    [ValidateRange(1, 240)][int]$SFCTimeoutMinutes = 30,
    [ValidateRange(1, 600)][int]$SlowCheckBudgetMinutes = 50,
    [ValidateRange(1, 240)][int]$CompatScanTimeoutMinutes = 45,

    # RDP access/policy evidence. LGPO.exe is optional (backup only).
    [bool]$EnableRDPPolicyEvidence = $true,
    [ValidateScript({ $_ -eq '' -or [IO.Path]::IsPathRooted($_) })][string]$LgpoExe = 'C:\Temp\Tools\LGPO.exe',
    [ValidateScript({ [IO.Path]::IsPathRooted($_) })][string]$PolicyEvidenceRoot = 'C:\Temp\Tools\PolBackup',
    [bool]$CreatePolicyEvidenceZip = $true,
    # When IIS is installed, copy its configuration files (the same files
    # "appcmd add backup" saves) into a restricted evidence folder and ZIP
    # under PolicyEvidenceRoot. A read-only copy; IIS itself is not touched.
    [bool]$EnableIISConfigEvidence = $true,

    # Output.
    [ValidateScript({ [IO.Path]::IsPathRooted($_) })][string]$ReportDirectory = 'C:\Temp\IPU-Assessment',
    [bool]$WriteJson = $true,
    # Replace host names, IP and MAC addresses, accounts, SIDs and certificate
    # details with placeholders (HOST-1, IP-3, ...) in the HTML and JSON, for
    # sharing a report outside the team. Best effort - read before sharing.
    # Output files are then named REDACTED-<time>-..., and a redacted result
    # cannot serve as the post-upgrade baseline. The log is not redacted.
    [bool]$RedactReport = $false,
    # Folders this run creates (report, policy evidence) get SYSTEM and
    # Administrators access only; reports describe the server in detail.
    # Existing folders are never changed. $false keeps inherited permissions.
    [bool]$RestrictOutputAcl = $true,
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


# =============================================================================
# 2. DETECTION PATTERNS
# =============================================================================
# Regular expressions, matched case-insensitively:
#   App     - installed application DisplayName (uninstall registry)
#   Service - service short Name
#   Display - service DisplayName
#   Driver  - file-system filter driver or kernel driver name
# Keep them specific: a broad word matches unrelated software.
$script:DetectionPatterns = @{
    Agents = @(
        @{ Label='OpenText Server Automation Agent';  App='^SA Agent$|Server Automation|Opsware';           Service='^OpswareAgent$';        Display='Opsware Agent|Server Automation' }
        @{ Label='OpenText Universal Discovery Agent'; App='Universal Discovery|^UD Agent';                  Service='^UDAgent$|^DDMA';        Display='Universal Discovery' }
        @{ Label='OpenText Operations Agent';          App='^Operations-agent$|Operations Agent|OMi Agent|HP Operations'; Service='^OvCtrl$|^ovcd$|^opcagt'; Display='OpenView Ctrl|Operations Agent' }
    )
    EndpointProtection = @(
        # Trend Micro / TrendAI: one row per product, so the report names
        # what is installed. Kernel drivers are listed under the Deep
        # Security Agent, which installs them.
        @{ Label='Trend Micro Deep Security Agent (Server & Workload Protection)'; App='Deep Security Agent'; Service='^(ds_agent|ds_monitor|ds_notifier|Amsp)$'; Display='Deep Security'; Driver='^(tmeyes|TmKmSnsr|tmumh)$'; Link='https://docs.trendmicro.com/en-us/documentation/article/trend-vision-one-agent-platform-compatibility'; LinkTitle='Trend Micro: agent platform compatibility' }
        @{ Label='Trend Micro Apex One'; App='Apex One|OfficeScan'; Service='^(ntrtscan|tmlisten|TmCCSF|TMBMServer|TmPfw)$'; Display='Apex One|OfficeScan' }
        @{ Label='Trend Vision One Endpoint Security agent (Endpoint Basecamp)'; App='Endpoint Basecamp|Vision One'; Service='^(Trend Micro Endpoint Basecamp|tm_netsrv)$'; Display='Endpoint Basecamp|Vision One'; Link='https://docs.trendmicro.com/en-us/documentation/article/trend-vision-one-agent-platform-compatibility'; LinkTitle='Trend Micro: agent platform compatibility' }
        @{ Label='Microsoft Defender for Endpoint (EDR sensor)'; Service='^Sense$' }
        @{ Label='CrowdStrike Falcon';       App='CrowdStrike';                       Service='^(CSAgent|CSFalconService)$';  Driver='^CSAgent$' }
        @{ Label='SentinelOne';              App='SentinelOne|Sentinel Agent';         Service='^(SentinelAgent|SentinelStaticEngine)$'; Driver='^SentinelMonitor$' }
        @{ Label='Cisco Secure Endpoint (AMP)'; App='Cisco Secure Endpoint|Cisco AMP|AMP for Endpoints|Immunet'; Service='^(CiscoAMP|immunetprotect)'; Display='Cisco Secure Endpoint|Cisco AMP' }
        @{ Label='Trellix / McAfee';         App='Trellix|McAfee';                     Service='^(mfefire|mfemms|masvc|macmnsvc|xagt)$'; Driver='^(mfehidk|mfencbdc)$' }
        @{ Label='Sophos';                   App='^Sophos';                            Service='^Sophos';                       Driver='^Sophos' }
        @{ Label='Symantec / Broadcom Endpoint Protection'; App='Symantec Endpoint|Broadcom Endpoint'; Service='^SepMasterService$'; Driver='^(SymEFASI|SRTSP)' }
        @{ Label='ESET';                     App='^ESET';                              Service='^ekrn$';                        Driver='^eamonm$' }
        @{ Label='Kaspersky';                App='Kaspersky';                          Service='^AVP' }
        @{ Label='VMware Carbon Black';      App='Carbon Black|Cb Defense|Cb Protection'; Service='^(CbDefense|Parity|CarbonBlack)'; Driver='^(carbonblackk|ctifile|parity)$' }
    )
    SecurityTools = @(
        @{ Label='Tenable Nessus agent'; App='Nessus|Tenable';  Service='^Tenable Nessus Agent$|^NessusAgent'; Display='Nessus' }
        @{ Label='NXLog';                App='^NXLog';          Service='^nxlog$' }
        @{ Label='Sysmon';               Service='^Sysmon(64)?$'; Driver='^SysmonDrv$' }
        @{ Label='Secure Root';          App='Secure Root';     Display='Secure Root' }
    )
    Backup = @(
        @{ Label='Commvault';                  App='Commvault|ContentStore|Hitachi Data Protection'; Service='^GxCVD|^GxClMgrS|^GXCVD' }
        @{ Label='IBM Spectrum Protect (TSM)'; App='Tivoli Storage Manager|Spectrum Protect|IBM Storage Protect'; Service='^(dsmcad|TSM)' }
        @{ Label='Veeam';                      App='Veeam';                             Service='^Veeam' }
    )
    Workloads = @(
        @{ Label='SharePoint';      App='^Microsoft SharePoint (Server|Foundation)'; Service='^(SPTimerV4|SPAdminV4)$' }
        @{ Label='Oracle Database'; App='^Oracle (Database|Client)|^Oracle .*Home';  Service='^(OracleService|OracleOraDB)|TNSListener' }
        @{ Label='SAP';             App='(^|[\s_\-])SAP([\s_\-]|$)|SAP HANA|SAP NetWeaver|SAP Host Agent'; Service='^(SAP\w+_\d\d|SAPHostExec|SAPHostControl|sapstartsrv)' }
        @{ Label='Citrix';          App='^Citrix';                                   Service='^(Citrix|Ctx)' }
        @{ Label='Boomi';           App='Boomi';                                     Service='Boomi' }
        @{ Label='Java runtime';    App='^(Java( \d+)?( Update \d+)?|Java\(TM\)|Java SE|Eclipse Temurin|Adoptium|Amazon Corretto|Microsoft Build of OpenJDK|Azul Zulu|OpenJDK|IBM Semeru)' }
        @{ Label='Apache Tomcat';   App='Apache Tomcat';                             Service='^Tomcat\d*$' }
        @{ Label='MySQL';           App='^MySQL Server';                             Service='^MySQL\d*$' }
        @{ Label='PostgreSQL';      App='^PostgreSQL';                               Service='^postgresql' }
        @{ Label='IBM Db2';         App='^IBM Db2|^DB2 ';                            Service='^DB2' }
    )
}

# Windows features removed or no longer developed, per Microsoft's
# "Features removed or no longer developed" pages for the target release.
# Removed  -> ACTION (Setup drops the feature; the dependent workload breaks).
# Deprecated -> Observation (still works, plan a replacement).
$script:FeatureLifecycle = @(
    @{ Feature='SMTP-Server';              Name='SMTP Server';                     State='Removed';    Targets=@('2025') }
    @{ Feature='Web-Lgcy-Mgmt-Console';    Name='IIS 6 Management Console';        State='Removed';    Targets=@('2025') }
    @{ Feature='PowerShell-V2';            Name='Windows PowerShell 2.0 engine';   State='Removed';    Targets=@('2025') }
    @{ Feature='WebDAV-Redirector';        Name='WebDAV Redirector';               State='Deprecated'; Targets=@('2022','2025') }
    @{ Feature='NLB';                      Name='Network Load Balancing';          State='Deprecated'; Targets=@('2022','2025') }
    @{ Feature='Windows-Internal-Database';Name='Windows Internal Database (WID)'; State='Deprecated'; Targets=@('2022','2025') }
    @{ Feature='UpdateServices';           Name='WSUS';                            State='Deprecated'; Targets=@('2025') }
)


# =============================================================================
# 3. CORE
# =============================================================================
$ProgressPreference = 'SilentlyContinue'
$script:CollectorVersion  = '4.1.0'
# Settings a profile file (-ProfileFile) may set. Mode, target, media path,
# report folder and redaction describe one run, so they stay arguments only.
$script:ProfileSettingNames = @(
    'TargetMediaLanguage','BlockDomainControllerIPU',
    'MinimumCFreeGB','ExtendBlockGB','MinimumMemoryGB','MaxPatchAgeDays','UptimeWarningDays','GroupPolicyMaxAgeDays','AVMaxAgeDays',
    'CertificateWarningDays','SystemPartitionMinFreeMB','RecoveryPartitionMinFreeMB',
    'RunDISMScanHealth','RunSFCVerifyOnly','DISMTimeoutMinutes','SFCTimeoutMinutes','SlowCheckBudgetMinutes','CompatScanTimeoutMinutes',
    'EnableRDPPolicyEvidence','LgpoExe','PolicyEvidenceRoot','CreatePolicyEvidenceZip','EnableIISConfigEvidence',
    'WriteJson','RestrictOutputAcl','NumberCultureName'
)
$script:PatternFields = @('Label','App','Service','Display','Driver','Disabled','Link','LinkTitle')
$script:Results           = New-Object System.Collections.Generic.List[object]
$script:CheckRuns         = New-Object System.Collections.Generic.List[object]
$script:Checks            = New-Object System.Collections.Generic.List[object]
$script:Data              = @{}
$script:CurrentCheckId    = 'core'
$script:CurrentCheckOutcome = $null
$script:CurrentCheckMessage = $null
$script:LogWriteFailures  = 0
$script:SlowSecondsLeft   = 0
$script:CollectionStarted = Get-Date
$script:ComputerName      = $env:COMPUTERNAME
if (-not $script:ComputerName) { $script:ComputerName = [Environment]::MachineName }
$script:SafeComputerName  = ($script:ComputerName -replace '[^A-Za-z0-9_.-]','_')
$script:ReportSuffix      = $(if ($AssessmentMode -eq 'Post') { '-IPU-PostUpgrade' } else { '-IPU-Assessment' })
$script:ReportBaseName    = $script:SafeComputerName + $script:ReportSuffix
# A redacted report must not carry the computer name in its file name.
if ($RedactReport) { $script:ReportBaseName = 'REDACTED-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + $script:ReportSuffix }
$script:ReportPath        = [IO.Path]::Combine($ReportDirectory, $script:ReportBaseName + '.html')
$script:LogPath           = [IO.Path]::Combine($ReportDirectory, $script:SafeComputerName + $script:ReportSuffix + '.log')
$script:JsonPath          = [IO.Path]::Combine($ReportDirectory, $script:ReportBaseName + '.json')
$script:BaselinePath      = [IO.Path]::Combine($ReportDirectory, $script:SafeComputerName + '-IPU-Assessment.json')

try { $script:NumberCulture = New-Object System.Globalization.CultureInfo($NumberCultureName) }
catch { $script:NumberCulture = [System.Globalization.CultureInfo]::InvariantCulture }

$script:StatusOrder  = @('BLOCKER','ACTION','WARNING','MANUAL','OK','INFO')
$script:FindingStatuses = @('BLOCKER','ACTION','WARNING','MANUAL')
$script:ValidKinds   = @('Finding','Observation','Evidence','Checklist')

# The single definition of report areas. Name = what readers see, Chapter =
# which collapsible chapter the area belongs to.
$script:ChapterOrder = @(
    'Post-Upgrade Comparison',
    'Upgrade Path, Licensing and Windows Health',
    'Workloads and Applications',
    'Hardware and Virtualization',
    'Storage',
    'Clustering',
    'Network',
    'Access and Remote Desktop',
    'IIS and Remote Desktop Services',
    'PKI and Certificates',
    'Security and Antivirus',
    'Management Agents',
    'Backup and Recovery',
    'Services and Scheduled Tasks',
    'Assessment and Collector'
)
$script:AreaMap = @{
    'POST_UPGRADE'       = @{ Name='Before/after comparison';     Chapter='Post-Upgrade Comparison' }
    'COMPAT_SCAN'        = @{ Name='Setup compatibility scan';    Chapter='Upgrade Path, Licensing and Windows Health' }
    'FEATURE_LIFECYCLE'  = @{ Name='Removed/deprecated features'; Chapter='Workloads and Applications' }
    'VMWARE'             = @{ Name='VMware guest readiness';      Chapter='Hardware and Virtualization' }
    'DRIVERS'            = @{ Name='Non-Microsoft drivers';       Chapter='Hardware and Virtualization' }
    'PORTS'              = @{ Name='Listening ports';             Chapter='Network' }
    'TASKS'              = @{ Name='Scheduled tasks';             Chapter='Services and Scheduled Tasks' }
    'UPGRADE_PATH'       = @{ Name='Upgrade path and media';      Chapter='Upgrade Path, Licensing and Windows Health' }
    'LICENSING'          = @{ Name='Windows activation';          Chapter='Upgrade Path, Licensing and Windows Health' }
    'WINDOWS_HEALTH'     = @{ Name='Windows health';              Chapter='Upgrade Path, Licensing and Windows Health' }
    'UPGRADE_HISTORY'    = @{ Name='Upgrade history';             Chapter='Upgrade Path, Licensing and Windows Health' }
    'EXCHANGE'           = @{ Name='Exchange Server';             Chapter='Workloads and Applications' }
    'SQL'                = @{ Name='SQL Server';                  Chapter='Workloads and Applications' }
    'DOMAIN_CONTROLLER'  = @{ Name='Domain controller';           Chapter='Workloads and Applications' }
    'WORKLOAD'           = @{ Name='Roles and workloads';         Chapter='Workloads and Applications' }
    'ROLES'              = @{ Name='Installed roles/features';    Chapter='Workloads and Applications' }
    'APPLICATIONS'       = @{ Name='Installed applications';      Chapter='Workloads and Applications' }
    'PLATFORM'           = @{ Name='Platform';                    Chapter='Hardware and Virtualization' }
    'HARDWARE'           = @{ Name='Physical hardware';           Chapter='Hardware and Virtualization' }
    'PERFORMANCE'        = @{ Name='CPU and memory';              Chapter='Hardware and Virtualization' }
    'STORAGE'            = @{ Name='Storage';                     Chapter='Storage' }
    'CLUSTER'            = @{ Name='Failover clustering';         Chapter='Clustering' }
    'NETWORK'            = @{ Name='Network adapters and teaming';Chapter='Network' }
    'NETWORK_DEPENDENCY' = @{ Name='Hosts file and static routes';Chapter='Network' }
    'ACCESS'             = @{ Name='Access and credentials';      Chapter='Access and Remote Desktop' }
    'RDP'                = @{ Name='RDP access and policy';       Chapter='Access and Remote Desktop' }
    'GROUP_POLICY'       = @{ Name='Group Policy and AD groups';  Chapter='Access and Remote Desktop' }
    'POLICY_EVIDENCE'    = @{ Name='Policy evidence files';       Chapter='Access and Remote Desktop' }
    'IIS'                = @{ Name='IIS';                         Chapter='IIS and Remote Desktop Services' }
    'RDS'                = @{ Name='Remote Desktop Services';     Chapter='IIS and Remote Desktop Services' }
    'PKI'                = @{ Name='Certification Authority';     Chapter='PKI and Certificates' }
    'CERTIFICATES'       = @{ Name='Certificates and bindings';   Chapter='PKI and Certificates' }
    'ANTIVIRUS'          = @{ Name='Antivirus';                   Chapter='Security and Antivirus' }
    'SECURITY'           = @{ Name='Security configuration';      Chapter='Security and Antivirus' }
    'AGENTS'             = @{ Name='Management agents';           Chapter='Management Agents' }
    'BACKUP'             = @{ Name='Backup and VSS';              Chapter='Backup and Recovery' }
    'SERVICES'           = @{ Name='Services';                    Chapter='Services and Scheduled Tasks' }
    'CHECKLIST'          = @{ Name='Change checklist';            Chapter='Assessment and Collector' }
    'COLLECTOR'          = @{ Name='Collector coverage';          Chapter='Assessment and Collector' }
    'ASSESSMENT'         = @{ Name='Assessment metadata';         Chapter='Assessment and Collector' }
}

function Write-AssessmentLog {
    param([string]$Level = 'INFO', [string]$Phase = '', [string]$Message = '')
    try {
        $line = '{0};{1};{2};{3}{4}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Phase,(($Message -replace '[\r\n;]+',' | ')),[Environment]::NewLine
        [IO.File]::AppendAllText($script:LogPath,$line,(New-Object System.Text.UTF8Encoding($false)))
    } catch {
        # The log itself cannot record this; count it so the report can say
        # the log is incomplete. Logging must never stop the assessment.
        $script:LogWriteFailures++
    }
}

function ConvertTo-CleanText {
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    $s = [string]$Value
    $s = $s -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]',''
    $s = $s -replace '[\r\n]+',' | '
    return $s.Trim()
}

function ConvertTo-SAField {
    param([object]$Value)
    return ((ConvertTo-CleanText $Value) -replace ';',',')
}

function Write-Swallowed {
    # Records an intentionally ignored failure of an optional query in the log,
    # so "not found" and "could not look" can be told apart afterwards.
    param($ErrorRecord)
    try {
        $where = ''
        if ($ErrorRecord -and $ErrorRecord.InvocationInfo) { $where = ' (line ' + $ErrorRecord.InvocationInfo.ScriptLineNumber + ')' }
        Write-AssessmentLog 'DEBUG' $script:CurrentCheckId ('Optional query failed' + $where + ': ' + $ErrorRecord.Exception.Message)
    } catch {
        $script:LogWriteFailures++
    }
}

function Find-DetectionMatch {
    # Pure: matches one pattern table (section 2) against the inventories and
    # returns one object per detected product with the evidence that matched.
    param([object[]]$Patterns, [object[]]$Apps = @(), [object[]]$Services = @(), [string[]]$Drivers = @())
    $found = @()
    foreach ($pattern in $Patterns) {
        $mApps = @(); $mSvcs = @(); $mDrv = @()
        if ($pattern.App) { $mApps = @($Apps | Where-Object { $_.Name -match $pattern.App -and $_.Name -notmatch 'VirtualBox' }) }
        if ($pattern.Service -or $pattern.Display) {
            $mSvcs = @($Services | Where-Object { ($pattern.Service -and $_.Name -match $pattern.Service) -or ($pattern.Display -and $_.DisplayName -match $pattern.Display) })
        }
        if ($pattern.Driver) { $mDrv = @($Drivers | Where-Object { $_ -match $pattern.Driver }) }
        if (($mApps.Count + $mSvcs.Count + $mDrv.Count) -gt 0) {
            $found += [pscustomobject]@{ Label=$pattern.Label; Apps=$mApps; Services=$mSvcs; Drivers=$mDrv; Link=[string]$pattern.Link; LinkTitle=[string]$pattern.LinkTitle }
        }
    }
    return ,$found
}

function Get-DetectionEvidence {
    param($Match)
    $parts = @()
    foreach ($a in $Match.Apps) { $parts += ($a.Name + ' ' + $a.Version).Trim() }
    foreach ($s in $Match.Services) { $parts += ('Service ' + $s.Name + ' (' + $s.State + ')') }
    if (@($Match.Drivers).Count -gt 0) { $parts += ('Drivers ' + (@($Match.Drivers) -join ',')) }
    return ,$parts
}

function Format-Duration {
    param([TimeSpan]$Duration)
    if ($Duration.Days -gt 0) {
        return ('{0}.{1:00}:{2:00}:{3:00}' -f $Duration.Days,$Duration.Hours,$Duration.Minutes,$Duration.Seconds)
    }
    return ('{0:00}:{1:00}:{2:00}' -f [math]::Floor($Duration.TotalHours),$Duration.Minutes,$Duration.Seconds)
}

function Format-Number {
    param([double]$Value, [int]$Decimals = 2)
    return $Value.ToString(('N' + $Decimals), $script:NumberCulture)
}

function Add-Result {
    param(
        [Parameter(Mandatory=$true,Position=0)][string]$Area,
        [Parameter(Mandatory=$true,Position=1)][string]$Item,
        [Parameter(Position=2)][ValidateSet('BLOCKER','ACTION','WARNING','MANUAL','OK','INFO')][string]$Status = 'INFO',
        [Parameter(Position=3)][object]$Value = '',
        [Parameter(Position=4)][object]$Details = '',
        [string]$Recommendation = '',
        [string]$Kind = '',
        [string]$Source = '',
        # Optional "how" and "read more" (#79). The script only shows the
        # command; it never runs it. Check = read-only, Change = run in the
        # change window.
        [string]$Command = '',
        [ValidateSet('','Check','Change')][string]$CommandKind = '',
        [string]$Link = '',
        [string]$LinkTitle = ''
    )
    if ($Command -and -not $CommandKind) { throw 'Add-Result: -Command needs -CommandKind Check or Change.' }
    if ($Link -and $Link -notmatch '^https://[^\s"<>]+$') { throw ('Add-Result: -Link must be an https URL: ' + $Link) }
    if (-not $script:AreaMap.ContainsKey($Area)) { throw ("Unknown report area '{0}'. Add it to `$script:AreaMap." -f $Area) }
    if (-not $Kind) {
        if ($script:FindingStatuses -contains $Status) { $Kind = 'Finding' } else { $Kind = 'Evidence' }
    }
    if ($script:ValidKinds -notcontains $Kind) { throw ("Unknown result kind '{0}'." -f $Kind) }
    $detailParts = @()
    foreach ($part in @($Details)) {
        $clean = ConvertTo-CleanText $part
        if ($clean) { $detailParts += $clean }
    }
    $script:Results.Add([pscustomobject]@{
        CheckId        = $script:CurrentCheckId
        Area           = $Area
        Item           = (ConvertTo-CleanText $Item)
        Status         = $Status
        Kind           = $Kind
        Value          = (ConvertTo-CleanText $Value)
        Details        = ($detailParts -join ' | ')
        Recommendation = (ConvertTo-CleanText $Recommendation)
        Source         = (ConvertTo-CleanText $Source)
        Command        = (ConvertTo-CleanText $Command)
        CommandKind    = $(if ($Command) { $CommandKind } else { '' })
        Link           = $Link
        LinkTitle      = $(if ($Link) { $(if ($LinkTitle) { ConvertTo-CleanText $LinkTitle } else { $Link }) } else { '' })
    })
}

function Register-Check {
    param(
        [Parameter(Mandatory=$true)][string]$Id,
        [Parameter(Mandatory=$true)][string]$Name,
        [ValidateSet('Fast','Slow')][string]$Phase = 'Fast',
        [Parameter(Mandatory=$true)][scriptblock]$Script
    )
    $script:Checks.Add([pscustomobject]@{ Id=$Id; Name=$Name; Phase=$Phase; Script=$Script })
}

function Invoke-Check {
    param([Parameter(Mandatory=$true)]$Check)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $script:CurrentCheckId = $Check.Id
    $script:CurrentCheckOutcome = $null
    $script:CurrentCheckMessage = $null
    $outcome = 'Completed'
    $message = ''
    Write-AssessmentLog 'INFO' $Check.Id 'Started.'
    try {
        # Inside a check every error is terminating. Optional queries must use
        # -ErrorAction SilentlyContinue or try/catch explicitly, so an
        # unexpected failure is visible instead of looking like a clean result.
        $ErrorActionPreference = 'Stop'
        $null = & $Check.Script
        if ($script:CurrentCheckOutcome) { $outcome = $script:CurrentCheckOutcome }
        if ($script:CurrentCheckMessage) { $message = $script:CurrentCheckMessage }
    } catch {
        $outcome = 'Failed'
        $message = $_.Exception.GetType().Name + ': ' + $_.Exception.Message
        $position = ''
        if ($_.InvocationInfo) { $position = 'Line ' + $_.InvocationInfo.ScriptLineNumber }
        Write-AssessmentLog 'ERROR' $Check.Id ($message + ' | ' + $position)
        try {
            Add-Result 'COLLECTOR' $Check.Name 'MANUAL' 'Check did not complete' @($message,$position) -Recommendation 'This area was only partially assessed. Absence of findings here is NOT evidence of readiness. Review it manually, or fix the cause and re-run.' -Kind 'Finding' -Source ('Check ' + $Check.Id)
        } catch { Write-Swallowed $_ }
    }
    $sw.Stop()
    $script:CheckRuns.Add([pscustomobject]@{
        Id=$Check.Id; Name=$Check.Name; Phase=$Check.Phase; Outcome=$outcome
        Duration=(Format-Duration $sw.Elapsed); Seconds=[math]::Round($sw.Elapsed.TotalSeconds,1); Message=$message
    })
    Write-AssessmentLog 'INFO' $Check.Id ('Finished. Outcome={0} | Duration={1}' -f $outcome,(Format-Duration $sw.Elapsed))
    $script:CurrentCheckId = 'core'
}

function New-RestrictedDirectorySecurity {
    # SYSTEM and Administrators full control, inheritance from the parent
    # removed. Built from SIDs so it works on every OS language.
    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, [System.Security.AccessControl.FileSystemRights]::FullControl, $inherit, [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)
    }
    return $security
}

function Set-RestrictedFolderAcl {
    param([string]$Path)
    Set-Acl -LiteralPath $Path -AclObject (New-RestrictedDirectorySecurity) -ErrorAction Stop
}

function Initialize-OutputFolder {
    # Creates a folder for the script's own output. Only a folder created by
    # this run is restricted; an existing folder keeps its permissions (it may
    # be shared, e.g. C:\Temp) and the report says whether it is too open.
    param([string]$Path, [bool]$Restrict = $RestrictOutputAcl)
    if (Test-Path -LiteralPath $Path -PathType Container) { return 'Existing' }
    New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
    if (-not $Restrict) { return 'Created' }
    try {
        Set-RestrictedFolderAcl $Path
        return 'CreatedRestricted'
    } catch {
        Write-AssessmentLog 'WARNING' 'ACL' ('Could not restrict ' + $Path + ': ' + $_.Exception.Message)
        return 'CreatedUnrestricted'
    }
}

function Get-GpResultXml {
    # Runs "gpresult /scope computer /x" into a temp file and returns the
    # XML text. Throws with gpresult's own message when it fails.
    $file = Join-Path ([IO.Path]::GetTempPath()) ('IPU-gpresult-' + [guid]::NewGuid().ToString('N') + '.xml')
    try {
        $r = Invoke-NativeCapture (Join-Path $env:windir 'System32\gpresult.exe') @('/scope','computer','/x',$file,'/f') 180
        if ($r.TimedOut) { throw 'gpresult did not finish within 3 minutes' }
        if (-not (Test-Path -LiteralPath $file)) { throw ('gpresult wrote no result (exit ' + $r.ExitCode + '): ' + (@($r.Lines) -join ' ')) }
        return [IO.File]::ReadAllText($file)
    } finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

function Get-AdComputerGroup {
    # The computer object's security groups from AD, nested groups included
    # (tokenGroups), read as the computer account itself - no RSAT needed.
    $searcher = New-Object System.DirectoryServices.DirectorySearcher
    $searcher.Filter = '(&(objectCategory=computer)(sAMAccountName=' + $env:COMPUTERNAME + '$))'
    $searcher.ClientTimeout = [TimeSpan]::FromSeconds(30)
    $hit = $searcher.FindOne()
    if (-not $hit) { throw ('Computer object ' + $env:COMPUTERNAME + '$ not found in AD') }
    $entry = $hit.GetDirectoryEntry()
    $entry.RefreshCache([string[]]@('tokenGroups'))
    $names = @()
    foreach ($bytes in @($entry.Properties['tokenGroups'])) {
        $sid = New-Object System.Security.Principal.SecurityIdentifier ([byte[]]$bytes), 0
        try { $names += $sid.Translate([System.Security.Principal.NTAccount]).Value } catch { $names += $sid.Value }
    }
    return ,@($names | Sort-Object -Unique)
}

function Get-WmiFilterQuery {
    # WMI filter name and queries for the given GPO GUIDs, from AD.
    # Returns GUID -> @{ Name; Queries }; GPOs without a filter are absent.
    param([string[]]$GpoGuids)
    $result = @{}
    $root = New-Object System.DirectoryServices.DirectoryEntry('LDAP://RootDSE')
    $nc = [string]$root.Properties['defaultNamingContext'][0]
    foreach ($guid in @($GpoGuids | Where-Object { $_ } | Sort-Object -Unique)) {
        $s = New-Object System.DirectoryServices.DirectorySearcher([ADSI]('LDAP://CN=Policies,CN=System,' + $nc))
        $s.Filter = '(&(objectClass=groupPolicyContainer)(cn=' + $guid + '))'
        $null = $s.PropertiesToLoad.Add('gPCWQLFilter')
        $gpo = $s.FindOne()
        if (-not $gpo -or $gpo.Properties['gpcwqlfilter'].Count -eq 0) { continue }
        $link = [string]$gpo.Properties['gpcwqlfilter'][0]
        $m = [regex]::Match($link, '\{[0-9A-Fa-f-]{36}\}')
        if (-not $m.Success) { continue }
        $f = New-Object System.DirectoryServices.DirectorySearcher([ADSI]('LDAP://CN=SOM,CN=WMIPolicy,CN=System,' + $nc))
        $f.Filter = '(&(objectClass=msWMI-Som)(msWMI-ID=' + $m.Value + '))'
        foreach ($p in 'msWMI-Name','msWMI-Parm2') { $null = $f.PropertiesToLoad.Add($p) }
        $hit = $f.FindOne()
        if (-not $hit) { continue }
        $result[$guid] = @{ Name = [string]$hit.Properties['mswmi-name'][0]; Queries = (ConvertFrom-WmiFilterParm ([string]$hit.Properties['mswmi-parm2'][0])) }
    }
    return $result
}

function Get-GroupPolicyLastApplied {
    # Last time the computer's Group Policy core processing ran, from the
    # registry (FILETIME as two DWORDs). $null when not recorded.
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\Extension-List\{00000000-0000-0000-0000-000000000000}'
    $hi = Get-RegistryValueSafe $key 'EndTimeHi'
    $lo = Get-RegistryValueSafe $key 'EndTimeLo'
    if (-not $hi.Exists -or -not $lo.Exists) { return $null }
    return (ConvertFrom-FileTimeValue $hi.Value $lo.Value)
}

function Save-IISConfigEvidence {
    # Copies the IIS configuration files into a new, restricted evidence
    # folder and zips it (#76). Read-only for IIS: nothing under inetsrv is
    # written. applicationHost.config can hold encrypted secrets, so the
    # folder gets the same SYSTEM/Administrators-only access as the other
    # evidence. Throws when nothing could be copied.
    param(
        [Parameter(Mandatory=$true)][string]$Destination,
        [string]$SourceFolder = (Join-Path $env:windir 'System32\inetsrv\config'),
        [bool]$Zip = $true
    )
    $files = @(Get-ChildItem -LiteralPath $SourceFolder -Filter '*.config' -File -ErrorAction Stop)
    if ($files.Count -eq 0) { throw ('No .config files found in ' + $SourceFolder) }
    $null = Initialize-OutputFolder $Destination
    foreach ($f in $files) { Copy-Item -LiteralPath $f.FullName -Destination $Destination -Force -ErrorAction Stop }
    $hash = ''
    $appHost = Join-Path $Destination 'applicationHost.config'
    if (Test-Path -LiteralPath $appHost) {
        try { $hash = (Get-FileHash -LiteralPath $appHost -Algorithm SHA256 -ErrorAction Stop).Hash } catch { Write-Swallowed $_ }
    }
    # Shared configuration: redirection.config points to the real files.
    $shared = ''
    $redirection = Join-Path $Destination 'redirection.config'
    if (Test-Path -LiteralPath $redirection) {
        try {
            [xml]$doc = [IO.File]::ReadAllText($redirection)
            $node = $doc.SelectSingleNode('//configurationRedirection')
            if ($node -and [string]$node.GetAttribute('enabled') -eq 'true') { $shared = [string]$node.GetAttribute('path') }
        } catch { Write-Swallowed $_ }
    }
    $location = $Destination
    if ($Zip) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zipPath = $Destination + '.zip'
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
        [IO.Compression.ZipFile]::CreateFromDirectory($Destination, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $false)
        $location = $zipPath
    }
    return [pscustomobject]@{ Location = $location; Folder = $Destination; Files = @($files | ForEach-Object { $_.Name } | Sort-Object); ApplicationHostSha256 = $hash; SharedConfigPath = $shared }
}

function Get-BroadFolderReader {
    # Returns the broad groups (Everyone, Authenticated Users, Users) that are
    # allowed to read the folder. Empty when the ACL cannot be read.
    param([string]$Path)
    $broad = @{ 'S-1-1-0' = 'Everyone'; 'S-1-5-11' = 'Authenticated Users'; 'S-1-5-32-545' = 'Users' }
    $found = @()
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        foreach ($rule in @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
            $sid = [string]$rule.IdentityReference
            if ($broad.ContainsKey($sid) -and [string]$rule.AccessControlType -eq 'Allow' -and ([int]$rule.FileSystemRights -band [int][System.Security.AccessControl.FileSystemRights]::ReadData)) {
                if ($found -notcontains $broad[$sid]) { $found += $broad[$sid] }
            }
        }
    } catch { Write-Swallowed $_ }
    return $found
}

function Test-CommandAvailable {
    # True when a cmdlet or function exists on this server. One place, so
    # tests can simulate servers with and without optional modules.
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-RegistryValueSafe {
    param([string]$Path, [string]$Name)
    $result = New-Object PSObject -Property @{ Exists=$false; Value=$null }
    try {
        if (Test-Path -LiteralPath $Path) {
            $item = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
            if ($item.PSObject.Properties[$Name]) {
                $result.Exists = $true
                $result.Value = $item.$Name
            }
        }
    } catch { Write-Swallowed $_ }
    return $result
}

function Get-CimRequired {
    # Essential CIM query: a failure throws, so the calling check is reported
    # as "did not complete" instead of looking clean. CIM cmdlets exist from
    # PowerShell 3.0; a local query needs no WinRM.
    param([string]$Class, [string]$Filter = '', [string]$Namespace = 'root\cimv2')
    $p = @{ ClassName=$Class; Namespace=$Namespace; ErrorAction='Stop' }
    if ($Filter) { $p.Filter = $Filter }
    return @(Get-CimInstance @p)
}

function Get-CimSafe {
    # Optional CIM query: a failure returns nothing and is logged.
    param([string]$Class, [string]$Filter = '', [string]$Namespace = 'root\cimv2')
    try { return @(Get-CimRequired $Class $Filter $Namespace) } catch { Write-Swallowed $_; return @() }
}

function ConvertTo-DateTimeValue {
    # Pure: CIM returns [datetime]; WMI-era data and some providers return
    # DMTF strings (20260929011022.500000+120) or plain date text. Returns
    # $null when the value cannot be read as a date.
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value }
    $text = [string]$Value
    if (-not $text) { return $null }
    if ($text -match '^\d{14}\.\d{6}[+-]\d{3}$') {
        try { return [Management.ManagementDateTimeConverter]::ToDateTime($text) } catch { Write-Swallowed $_ }
    }
    if ($text -match '^\d{8}$') {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($text, 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) { return $parsed }
    }
    $any = [datetime]::MinValue
    if ([datetime]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$any)) { return $any }
    return $null
}

function ConvertFrom-NativeByteArray {
    # Native tools write either UTF-16LE (sfc.exe, secedit) or the OEM code
    # page (dism.exe, netsh, vssadmin). Detect which and strip control chars.
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
    $text = ''
    $isUnicode = $false
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) { $isUnicode = $true }
    else {
        $sample = [Math]::Min($Bytes.Length, 512)
        $oddPositions = 0; $oddZeros = 0
        for ($i = 1; $i -lt $sample; $i += 2) { $oddPositions++; if ($Bytes[$i] -eq 0) { $oddZeros++ } }
        if ($oddPositions -gt 0 -and ($oddZeros / $oddPositions) -gt 0.3) { $isUnicode = $true }
    }
    if ($isUnicode) { $text = [Text.Encoding]::Unicode.GetString($Bytes) }
    else {
        $encoding = $null
        try { $encoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch { Write-Swallowed $_ }
        if ($null -eq $encoding) { $encoding = New-Object System.Text.UTF8Encoding($false) }
        $text = $encoding.GetString($Bytes)
    }
    $text = $text.TrimStart([char]0xFEFF)
    return ($text -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]','')
}

function Invoke-NativeCapture {
    # Runs a native command with a timeout and captured output. Used for every
    # external tool so that stderr output never becomes a terminating
    # PowerShell error and a hung tool cannot stall the whole assessment.
    # The process is started through System.Diagnostics.Process (not
    # Start-Process -PassThru), so the exit code is available even when the
    # tool exits at once (#66). Output is read as raw bytes in the background
    # and decoded by ConvertFrom-NativeByteArray (sfc.exe writes UTF-16).
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 120
    )
    $result = [pscustomobject]@{ ExitCode=$null; Output=''; Lines=@(); TimedOut=$false; Error='' }
    $process = $null
    try {
        $quoted = @()
        foreach ($arg in $ArgumentList) {
            if ($arg -match '\s' -and $arg -notmatch '^".*"$') { $quoted += ('"' + $arg + '"') } else { $quoted += $arg }
        }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        $psi.Arguments = ($quoted -join ' ')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        $null = $process.Start()
        $outBuffer = New-Object System.IO.MemoryStream
        $errBuffer = New-Object System.IO.MemoryStream
        $readers = [System.Threading.Tasks.Task[]]@(
            $process.StandardOutput.BaseStream.CopyToAsync($outBuffer),
            $process.StandardError.BaseStream.CopyToAsync($errBuffer)
        )
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $result.TimedOut = $true
            try { $null = Invoke-NativeTreeKill $process.Id } catch { Write-Swallowed $_ }
            try { $null = $process.WaitForExit(15000) } catch { Write-Swallowed $_ }
        } else {
            $process.WaitForExit()
            $result.ExitCode = $process.ExitCode
        }
        # A child process that outlives the tool can keep the pipes open;
        # never wait for it longer than 15 seconds.
        try { $null = [System.Threading.Tasks.Task]::WaitAll($readers, 15000) } catch { Write-Swallowed $_ }
        $chunks = @()
        foreach ($buffer in @($outBuffer,$errBuffer)) { $chunks += (ConvertFrom-NativeByteArray $buffer.ToArray()) }
        $result.Output = (($chunks | Where-Object { $_ }) -join "`n")
        $result.Lines = @($result.Output -split '\r?\n' | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -ne '' })
    } catch {
        $result.Error = $_.Exception.Message
    } finally {
        if ($process) { try { $process.Dispose() } catch { Write-Swallowed $_ } }
    }
    return $result
}

function Invoke-NativeTreeKill {
    param([int]$ProcessId)
    $taskkill = Join-Path $env:windir 'System32\taskkill.exe'
    if (Test-Path -LiteralPath $taskkill) {
        $p = Start-Process -FilePath $taskkill -ArgumentList @('/PID',[string]$ProcessId,'/T','/F') -PassThru -NoNewWindow -Wait -ErrorAction SilentlyContinue
        return $p
    }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Get-InstalledApplication {
    $items = @()
    foreach ($path in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        foreach ($entry in @(Get-ItemProperty $path -ErrorAction SilentlyContinue)) {
            if ($entry.DisplayName -and -not $entry.SystemComponent) {
                $items += [pscustomobject]@{
                    Name=[string]$entry.DisplayName; Version=[string]$entry.DisplayVersion
                    Publisher=[string]$entry.Publisher; InstallDate=[string]$entry.InstallDate
                }
            }
        }
    }
    return @($items | Sort-Object Name,Version -Unique)
}

function Get-FeatureState {
    param([string]$Name)
    if ($null -eq $script:Data.Features) { return $null }
    if ($script:Data.Features.ContainsKey($Name)) { return [bool]$script:Data.Features[$Name] }
    return $false
}

function ConvertTo-NormalizedThumbprint {
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [byte[]]) { return (($Value | ForEach-Object { $_.ToString('X2') }) -join '') }
    return (([string]$Value) -replace '[^0-9A-Fa-f]','').ToUpperInvariant()
}

function Resolve-PolicyAccountName {
    param([string]$Account)
    if (-not $Account) { return '' }
    $clean = ($Account.Trim() -replace '^\*','')
    if ($clean -match '^S-\d-') {
        try {
            $sid = New-Object Security.Principal.SecurityIdentifier($clean)
            return $sid.Translate([Security.Principal.NTAccount]).Value + ' [' + $clean + ']'
        } catch { return $clean }
    }
    return $clean
}

function Get-LocalGroupMembersBySid {
    param([string]$Sid)
    $members = @()
    $group = @(Get-CimSafe 'Win32_Group' ("LocalAccount=True AND SID='" + $Sid + "'")) | Select-Object -First 1
    if ($group) {
        try {
            $adsi = [ADSI]('WinNT://' + $script:ComputerName + '/' + $group.Name + ',group')
            foreach ($member in @($adsi.psbase.Invoke('Members'))) {
                $name = $member.GetType().InvokeMember('Name','GetProperty',$null,$member,$null)
                $path = $member.GetType().InvokeMember('ADsPath','GetProperty',$null,$member,$null)
                $members += ($name + ' [' + $path + ']')
            }
        } catch { Write-Swallowed $_ }
    }
    return ,$members
}

function Read-FileTail {
    # Reads the last part of a log that another process may hold open.
    param([string]$Path, [int]$MaxBytes = 20MB)
    $lines = @()
    if (-not (Test-Path -LiteralPath $Path)) { return ,$lines }
    $stream = $null; $reader = $null
    try {
        $stream = New-Object IO.FileStream($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        if ($stream.Length -gt $MaxBytes) { $null = $stream.Seek(-1 * $MaxBytes, [IO.SeekOrigin]::End) }
        $reader = New-Object IO.StreamReader($stream)
        $lines = @($reader.ReadToEnd() -split '\r?\n')
    } catch { Write-Swallowed $_ } finally {
        if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() }
    }
    return ,$lines
}


# =============================================================================
# 4. DECISION RULES (pure functions - no system access; unit-tested)
# =============================================================================
$script:ReleaseOrder = @('2012','2012R2','2016','2019','2022','2025')

# Microsoft "Supported in-place upgrade paths" (installation media).
$script:SupportedUpgradePaths = @{
    '2022' = @('2016','2019')
    '2025' = @('2012R2','2016','2019','2022')
}

# SQL Server major version -> Windows Server support (Microsoft "Using SQL
# Server in Windows" compatibility matrix).
$script:SqlReleaseNames = @{ 9='2005'; 10='2008 / 2008 R2'; 11='2012'; 12='2014'; 13='2016'; 14='2017'; 15='2019'; 16='2022'; 17='2025' }
$script:SqlSupportedOnTarget = @{
    '2022' = @(14,15,16,17)
    '2025' = @(15,16,17)
}

function Get-ReleaseDisplayName {
    param([string]$Release)
    if ($Release -eq '2012R2') { return 'Windows Server 2012 R2' }
    if ($Release) { return ('Windows Server ' + $Release) }
    return 'Unknown'
}

function Get-WindowsServerRelease {
    # Build numbers are language independent; the caption is a fallback.
    param([string]$BuildNumber, [string]$Caption)
    $build = 0
    [void][int]::TryParse((([string]$BuildNumber) -split '\.')[0], [ref]$build)
    switch ($build) {
        9200  { return '2012' }
        9600  { return '2012R2' }
        14393 { return '2016' }
        17763 { return '2019' }
        20348 { return '2022' }
        26100 { return '2025' }
    }
    if ($Caption -match '2012 R2') { return '2012R2' }
    foreach ($r in @('2025','2022','2019','2016','2012')) { if ($Caption -match $r) { return $r } }
    return ''
}

function Get-UpgradePathDecision {
    param([string]$Source, [string]$Target, [bool]$Clustered = $false)
    $make = { param($s,$t) [pscustomobject]@{ Status=$s; Text=$t } }
    if ($Clustered) {
        return (& $make 'BLOCKER' 'Clustered node: the standalone IPU procedure does not apply. Use a Cluster OS Rolling Upgrade (one version at a time) or migration plan.')
    }
    if (-not $Source) { return (& $make 'MANUAL' 'The source Windows Server release was not recognized.') }
    if (-not $script:SupportedUpgradePaths.ContainsKey($Target)) {
        return (& $make 'MANUAL' ("Target '" + $Target + "' is not a configured target. Use 2025 or 2022."))
    }
    if ($Source -eq $Target) { return (& $make 'INFO' ('Source is already ' + (Get-ReleaseDisplayName $Target) + '.')) }
    if ($script:ReleaseOrder.IndexOf($Source) -gt $script:ReleaseOrder.IndexOf($Target)) {
        return (& $make 'BLOCKER' ('Source (' + (Get-ReleaseDisplayName $Source) + ') is newer than the target. Downgrade is not possible.'))
    }
    if ($script:SupportedUpgradePaths[$Target] -contains $Source) {
        return (& $make 'OK' ('Supported in-place upgrade path: ' + (Get-ReleaseDisplayName $Source) + ' to ' + (Get-ReleaseDisplayName $Target) + '.'))
    }
    $alternatives = @()
    foreach ($t in @($script:SupportedUpgradePaths.Keys | Sort-Object)) {
        if ($script:SupportedUpgradePaths[$t] -contains $Source) { $alternatives += (Get-ReleaseDisplayName $t) }
    }
    $hint = ''
    if ($alternatives.Count -gt 0) { $hint = ' Supported direct target(s) from this source: ' + ($alternatives -join ', ') + '.' }
    return (& $make 'BLOCKER' ('Microsoft does not support a direct in-place upgrade from ' + (Get-ReleaseDisplayName $Source) + ' to ' + (Get-ReleaseDisplayName $Target) + '.' + $hint))
}

function Get-EditionDecision {
    # Edition is retained (Standard may move up to Datacenter, never down),
    # and Server Core <-> Desktop Experience cannot change during IPU. The
    # result names the exact image to select in Setup.
    param([string]$EditionId, [string]$InstallationType, [string]$Target)
    $targetName = Get-ReleaseDisplayName $Target
    $variant = ''
    if ($InstallationType -eq 'Server Core') { $variant = 'Server Core' }
    elseif ($InstallationType -eq 'Server') { $variant = 'Desktop Experience' }
    $suffix = ''
    if ($variant -eq 'Desktop Experience') { $suffix = ' (Desktop Experience)' }
    $out = [pscustomobject]@{ Status='MANUAL'; Edition=''; Variant=$variant; MediaImage=''; Text='' }
    if (-not $variant) {
        $out.Text = "Installation type '" + $InstallationType + "' was not recognized; the Server Core / Desktop Experience choice cannot be determined."
        return $out
    }
    $id = [string]$EditionId
    if ($id -match 'Eval') {
        $out.Status = 'BLOCKER'; $out.Edition = 'Evaluation'
        $out.Text = 'Evaluation edition. Convert it to a licensed edition (DISM /Set-Edition) or rebuild before planning a licensed IPU.'
    } elseif ($id -match '^ServerStorage') {
        $out.Status = 'BLOCKER'; $out.Edition = 'Storage Server'
        $out.Text = 'In-place upgrade from Windows Storage Server editions is not supported.'
    } elseif ($id -match '^ServerStandard(Core|Cor)?$') {
        $out.Status = 'OK'; $out.Edition = 'Standard'
        $out.MediaImage = $targetName + ' Standard' + $suffix
        $out.Text = 'Standard is retained by default (Datacenter is also allowed as an upgrade). Select the ' + $variant + ' image; switching between Server Core and Desktop Experience during IPU is not supported.'
    } elseif ($id -match '^ServerDatacenter(Core|Cor)?$') {
        $out.Status = 'OK'; $out.Edition = 'Datacenter'
        $out.MediaImage = $targetName + ' Datacenter' + $suffix
        $out.Text = 'Datacenter must stay Datacenter (downgrade to Standard is not supported). Select the ' + $variant + ' image.'
    } elseif ($id -match '^ServerTurbine') {
        $out.Edition = 'Datacenter: Azure Edition'
        $out.Text = 'Datacenter: Azure Edition has its own upgrade/hotpatch servicing model. Validate the upgrade method separately.'
    } elseif ($id -match 'Solution|Essentials') {
        $out.Edition = 'Essentials'
        $out.Text = 'Essentials edition: validate upgrade support and licensing separately.'
    } else {
        $out.Edition = $id
        $out.Text = "Edition ID '" + $id + "' is not recognized by the assessment. Validate the matching installation image manually."
    }
    return $out
}

function ConvertFrom-LanguageId {
    # InstallLanguage in the registry is hexadecimal (e.g. 0409); WMI
    # OSLanguage is decimal (e.g. 1033).
    param([string]$LanguageId, [int]$Base = 16)
    if (-not $LanguageId) { return '' }
    try {
        $lcid = [Convert]::ToInt32($LanguageId.Trim(), $Base)
        return (New-Object Globalization.CultureInfo($lcid)).Name
    } catch { return '' }
}

function Get-PlatformClassification {
    param([string]$Manufacturer, [string]$Model)
    $m = [string]$Manufacturer; $mo = [string]$Model
    $h = ''
    if (-not $m -and -not $mo) { return [pscustomobject]@{ Type='Unknown'; Hypervisor='' } }
    if ($m -match 'VMware' -or $mo -match 'VMware') { $h = 'VMware' }
    elseif ($m -match 'Amazon EC2') { $h = 'AWS EC2' }
    elseif ($m -match '^Google' -or $mo -match 'Google Compute Engine') { $h = 'Google Cloud' }
    elseif ($m -match 'Nutanix' -or $mo -match '^AHV') { $h = 'Nutanix AHV' }
    elseif ($m -match 'Microsoft Corporation' -and $mo -match 'Virtual Machine') { $h = 'Hyper-V / Azure' }
    elseif ($m -match 'QEMU|Red Hat|oVirt|OpenStack' -or $mo -match 'KVM|OpenStack|RHEV|oVirt') { $h = 'KVM-based' }
    elseif ($m -match 'Xen' -or $mo -match 'HVM domU') { $h = 'Xen' }
    elseif ($mo -match 'VirtualBox') { $h = 'VirtualBox' }
    elseif ($m -match 'Parallels') { $h = 'Parallels' }
    if ($h) { return [pscustomobject]@{ Type='Virtual'; Hypervisor=$h } }
    return [pscustomobject]@{ Type='Physical'; Hypervisor='' }
}

function Get-SqlSupportDecision {
    param([int]$Major, [string]$Target)
    $name = $script:SqlReleaseNames[$Major]
    if (-not $name) { $name = 'major version ' + $Major }
    $label = 'SQL Server ' + $name
    if (-not $script:SqlSupportedOnTarget.ContainsKey($Target)) {
        return [pscustomobject]@{ Status='MANUAL'; Release=$label; Text=('No SQL support matrix configured for target ' + $Target + '.') }
    }
    if ($script:SqlSupportedOnTarget[$Target] -contains $Major) {
        return [pscustomobject]@{ Status='OK'; Release=$label; Text=($label + ' is supported on ' + (Get-ReleaseDisplayName $Target) + '. Confirm the latest CU is installed and engage the DBA.') }
    }
    $alternatives = @()
    foreach ($t in @($script:SqlSupportedOnTarget.Keys | Sort-Object)) {
        if ($t -ne $Target -and $script:SqlSupportedOnTarget[$t] -contains $Major) { $alternatives += (Get-ReleaseDisplayName $t) }
    }
    $hint = ' Upgrade SQL Server first, or migrate the databases.'
    if ($alternatives.Count -gt 0) { $hint = ' ' + ($alternatives -join ', ') + ' supports this SQL version - choose that target, or upgrade SQL Server first.' }
    return [pscustomobject]@{ Status='BLOCKER'; Release=$label; Text=($label + ' is not supported on ' + (Get-ReleaseDisplayName $Target) + '.' + $hint) }
}

function Get-DismVerdict {
    param([string]$OutputText, $ExitCode)
    if ($OutputText -match 'No component store corruption detected') { return 'OK' }
    if ($OutputText -match 'component store is repairable|component store cannot be repaired') { return 'ACTION' }
    if ($null -ne $ExitCode -and [int]$ExitCode -ne 0) { return 'ACTION' }
    return 'MANUAL'
}

function Get-SfcVerdict {
    # SFC's console text is localized; CBS.log is always English. Use the
    # console text when it is English, otherwise the CBS.log lines written
    # during this run.
    param([string]$OutputText, [string[]]$CbsLines = @())
    if ($OutputText -match 'did not find any integrity violations') { return [pscustomobject]@{ Status='OK'; Basis='SFC output' } }
    if ($OutputText -match 'found integrity violations|found corrupt files|could not perform the requested operation') { return [pscustomobject]@{ Status='ACTION'; Basis='SFC output' } }
    $sr = @($CbsLines | Where-Object { $_ -match '\[SR\]|CSI' })
    if (@($sr | Where-Object { $_ -match 'corrupt|do not match actual file|Cannot repair' }).Count -gt 0) {
        return [pscustomobject]@{ Status='ACTION'; Basis='CBS.log' }
    }
    if (@($sr | Where-Object { $_ -match '\[SR\] Verify complete' }).Count -gt 0) {
        return [pscustomobject]@{ Status='OK'; Basis='CBS.log' }
    }
    return [pscustomobject]@{ Status='MANUAL'; Basis='Unclassified' }
}

function ConvertFrom-VssWriterOutput {
    # Label-independent parsing: a quoted name starts a writer block, the
    # "[n] Text" line is the state, and the next line is the last error.
    param([string[]]$Lines)
    $writers = @()
    $current = $null
    $expectError = $false
    foreach ($line in $Lines) {
        if ($line -match "^\s*[^'\{\[]+:\s*'(.+)'\s*$") {
            if ($current) { $writers += $current }
            $current = [pscustomobject]@{ Name=$matches[1]; StateCode=$null; StateText=''; LastError='' }
            $expectError = $false
            continue
        }
        if (-not $current) { continue }
        if ($line -match '^\s*[^:]+:\s*\[(\d+)\]\s*(.*)$') {
            $current.StateCode = [int]$matches[1]; $current.StateText = $matches[2].Trim(); $expectError = $true
            continue
        }
        if ($expectError -and $line.Trim()) {
            $current.LastError = (($line -split ':',2)[-1]).Trim(); $expectError = $false
        }
    }
    if ($current) { $writers += $current }
    return ,$writers
}

function Get-VssWriterStatus {
    param($Writer)
    if ($null -ne $Writer.StateCode -and $Writer.StateCode -ne 1) { return 'ACTION' }
    if ($Writer.LastError -match '^\s*No error\s*$') { return 'OK' }
    if ($Writer.LastError -match 'error|fail|timeout|retryable') { return 'ACTION' }
    if ($Writer.StateCode -eq 1) { return 'MANUAL' }
    return 'MANUAL'
}

function Get-VMwareToolsDecision {
    # Broadcom: VMware Tools 12.5.0 is the release whose drivers are certified
    # for Windows Server 2025; Broadcom's IPU KB says to update Tools first.
    param([string]$Version, [string]$Target)
    if (-not $Version) {
        return [pscustomobject]@{ Status='ACTION'; Text='VMware Tools not found. Install current VMware Tools before IPU (PVSCSI/VMXNET3 and other VMware drivers).' }
    }
    $parsed = $null
    $clean = ([regex]::Match($Version, '^\d+(\.\d+){1,3}')).Value
    if (-not $clean -or -not [version]::TryParse($clean, [ref]$parsed)) {
        return [pscustomobject]@{ Status='MANUAL'; Text=("VMware Tools version '" + $Version + "' could not be parsed. Confirm it is current.") }
    }
    if ($Target -eq '2025' -and $parsed -lt [version]'12.5.0') {
        return [pscustomobject]@{ Status='ACTION'; Text=('VMware Tools ' + $clean + ' predates 12.5.0, the first release with drivers certified for Windows Server 2025. Update VMware Tools before IPU.') }
    }
    return [pscustomobject]@{ Status='OK'; Text=('VMware Tools ' + $clean + '. Update to the latest release before IPU, as Broadcom recommends.') }
}

function Get-FeatureLifecycleFinding {
    param([string[]]$InstalledFeatures, [string]$Target)
    $out = @()
    foreach ($f in $script:FeatureLifecycle) {
        if ($f.Targets -notcontains $Target) { continue }
        if ($InstalledFeatures -notcontains $f.Feature) { continue }
        if ($f.State -eq 'Removed') {
            $out += [pscustomobject]@{ Status='ACTION'; Kind='Finding'; Feature=$f.Feature; Name=$f.Name
                Text=($f.Name + ' is removed in ' + (Get-ReleaseDisplayName $Target) + '. Find out what uses it and plan a replacement before IPU; it will not be available afterwards.') }
        } else {
            $out += [pscustomobject]@{ Status='WARNING'; Kind='Observation'; Feature=$f.Feature; Name=$f.Name
                Text=($f.Name + ' is no longer developed by Microsoft. It still works after IPU; plan a replacement.') }
        }
    }
    return ,$out
}

function Get-CompatScanDecision {
    # Exit codes documented for setup.exe /Compat ScanOnly.
    param([object]$ExitCode)
    if ($null -eq $ExitCode) { return [pscustomobject]@{ Status='MANUAL'; Code=''; Text='Setup returned no exit code.' } }
    $n = [int64]$ExitCode
    if ($n -lt 0) { $n += 4294967296 }   # signed Int32 exit code -> unsigned
    $hex = '0x' + $n.ToString('X8')
    switch ($hex) {
        '0xC1900210' { return [pscustomobject]@{ Status='OK';      Code=$hex; Text='Setup found no compatibility issues.' } }
        '0xC1900208' { return [pscustomobject]@{ Status='ACTION';  Code=$hex; Text='Setup found compatibility issues (typically an incompatible application or driver). See the CompatData XML.' } }
        '0xC1900204' { return [pscustomobject]@{ Status='BLOCKER'; Code=$hex; Text='Setup reports that an upgrade keeping files and apps is not available with this media (edition, installation type or language mismatch).' } }
        '0xC1900200' { return [pscustomobject]@{ Status='BLOCKER'; Code=$hex; Text='Setup reports that this server is not eligible for the target version.' } }
        '0xC190020E' { return [pscustomobject]@{ Status='ACTION';  Code=$hex; Text='Setup reports insufficient free disk space.' } }
        '0xC1900215' { return [pscustomobject]@{ Status='MANUAL';  Code=$hex; Text='Setup needs an image index; no matching image was selected.' } }
        '0xC190010E' { return [pscustomobject]@{ Status='MANUAL';  Code=$hex; Text='Setup needs EULA acceptance for unattended use.' } }
    }
    return [pscustomobject]@{ Status='MANUAL'; Code=$hex; Text=('Unexpected Setup result ' + $hex + '. Review the Panther logs.') }
}

function ConvertTo-PendingRenamePath {
    # PendingFileRenameOperations holds pairs (source, destination); show the
    # first few sources so the owning product is recognisable.
    param([object[]]$Values, [int]$Max = 5)
    $paths = @()
    foreach ($v in @($Values)) {
        # A destination prefixed with '!' means "replace the existing file";
        # strip it with the \??\ prefix so both forms show the same path.
        $p = ([string]$v -replace '^!','' -replace '^\\\?\?\\','').Trim()
        if ($p -and $paths -notcontains $p) { $paths += $p }
    }
    $shown = @($paths | Select-Object -First $Max)
    if ($paths.Count -gt $Max) { $shown += ('... and ' + ($paths.Count - $Max) + ' more') }
    return ,$shown
}

function Compare-IPUSnapshot {
    # Pure: compares the pre-upgrade snapshot with the current one and returns
    # the differences an engineer must look at after the upgrade.
    param($Before, $After)
    $diff = @()
    $make = { param($st,$item,$val,$det,$rec) [pscustomobject]@{ Status=$st; Item=$item; Value=$val; Details=$det; Recommendation=$rec } }

    $nowRunning = @{}
    foreach ($s in @($After.Services)) { $nowRunning[[string]$s.Name] = $s }
    $stopped = @(); $missing = @()
    foreach ($s in @($Before.Services | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -eq 'Running' })) {
        if (-not $nowRunning.ContainsKey([string]$s.Name)) { $missing += [string]$s.Name }
        elseif ($nowRunning[[string]$s.Name].State -ne 'Running') { $stopped += ([string]$s.Name + ' (' + $nowRunning[[string]$s.Name].State + ', ' + $nowRunning[[string]$s.Name].StartMode + ')') }
    }
    if ($stopped.Count -gt 0) { $diff += (& $make 'ACTION' 'Automatic services no longer running' ('Count=' + $stopped.Count) ($stopped -join ', ') 'These ran before the upgrade. Start them, check their event logs, and confirm with the application owner.') }
    if ($missing.Count -gt 0) { $diff += (& $make 'WARNING' 'Services no longer present' ('Count=' + $missing.Count) ($missing -join ', ') 'These running services no longer exist. Expected for some Windows components; confirm none belongs to an application.') }

    $lists = @(
        @{ Name='Listening ports';   Prop='Ports';        Status='WARNING'; Rec='These ports listened before the upgrade. Confirm the owning service is running and test from a client.' },
        @{ Name='Static routes';     Prop='Routes';       Status='ACTION';  Rec='Re-create the missing routes (route -p add / New-NetRoute) and test the destinations.' },
        @{ Name='IPv4 addresses';    Prop='IPv4';         Status='ACTION';  Rec='Restore the IP configuration; check teaming and adapter names.' },
        @{ Name='DNS servers';       Prop='Dns';          Status='WARNING'; Rec='Restore the DNS server configuration on the adapter.' },
        @{ Name='Hosts file entries';Prop='Hosts';        Status='WARNING'; Rec='Restore the missing hosts entries if still needed.' },
        @{ Name='Applications';      Prop='Apps';         Status='WARNING'; Rec='Applications that disappeared during the upgrade must be reinstalled or confirmed obsolete by the owner.' },
        @{ Name='Windows features';  Prop='Features';     Status='WARNING'; Rec='Features removed by Setup. Confirm nothing depends on them.' },
        @{ Name='Scheduled tasks';   Prop='Tasks';        Status='WARNING'; Rec='Re-create missing tasks and confirm their run-as credentials.' },
        @{ Name='Applied GPOs';      Prop='Gpos';         Status='WARNING'; Rec='These GPOs applied before the upgrade and no longer do. Check their WMI filters (often a Windows version filter) and security filtering.' },
        @{ Name='AD groups';         Prop='Groups';       Status='WARNING'; Rec='The computer was in these groups before. Check the AD group memberships (patch rings, GPO filtering, certificate enrolment).' }
    )
    if ($Before.Uac -and $After.Uac -and [string]$Before.Uac -ne [string]$After.Uac) {
        $diff += (& $make 'WARNING' 'UAC changed' ([string]$After.Uac) ('Before: ' + [string]$Before.Uac) 'User Account Control is set differently after the upgrade. Confirm the change is intended (usually set by Group Policy).')
    }
    foreach ($l in $lists) {
        $b = @($Before.($l.Prop) | Where-Object { $_ })
        $a = @($After.($l.Prop) | Where-Object { $_ })
        if ($l.Prop -eq 'Apps') { $b = @($b | ForEach-Object { [string]$_.Name }); $a = @($a | ForEach-Object { [string]$_.Name }) }
        $lost = @($b | Where-Object { $a -notcontains $_ } | Sort-Object -Unique)
        if ($lost.Count -gt 0) { $diff += (& $make $l.Status ($l.Name + ' missing after upgrade') ('Count=' + $lost.Count) ($lost -join ', ') $l.Rec) }
    }
    # Group Policy can also start applying after the upgrade (#80). Only
    # compared when the baseline has the list (4.2.0 and later).
    if ($null -ne $Before.Gpos -and $null -ne $After.Gpos) {
        $b = @($Before.Gpos | Where-Object { $_ }); $a = @($After.Gpos | Where-Object { $_ })
        $new = @($a | Where-Object { $b -notcontains $_ } | Sort-Object -Unique)
        if ($new.Count -gt 0) { $diff += (& $make 'WARNING' 'GPOs newly applied after upgrade' ('Count=' + $new.Count) ($new -join ', ') 'These GPOs did not apply before the upgrade. Confirm they are intended for this server (WMI filters on the Windows version often cause this).') }
    }
    return ,$diff
}

function ConvertFrom-GpResultXml {
    # Pure: parses "gpresult /scope computer /x" (RSoP XML) into the GPOs
    # that applied, the GPOs that were filtered out with the reason, and the
    # computer's security groups (#80). Namespace-agnostic, so it reads the
    # output of every supported Windows release.
    param([Parameter(Mandatory=$true)][string]$Xml)
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($Xml)
    $computer = $doc.SelectSingleNode("//*[local-name()='ComputerResults']")
    if (-not $computer) { throw 'No computer results in the gpresult output.' }
    $text = {
        param($Node, [string]$Name)
        $n = $Node.SelectSingleNode("*[local-name()='" + $Name + "']")
        if ($n) { return ([string]$n.InnerText).Trim() }
        return ''
    }
    $gpos = @()
    foreach ($g in @($computer.SelectNodes("*[local-name()='GPO']"))) {
        $name = & $text $g 'Name'
        $guid = ''
        $id = $g.SelectSingleNode("*[local-name()='Path']/*[local-name()='Identifier']")
        if ($id) { $guid = ([string]$id.InnerText).Trim() }
        $links = @()
        $appliedLink = $false
        foreach ($l in @($g.SelectNodes("*[local-name()='Link']"))) {
            $som = & $text $l 'SOMPath'
            $order = 0; [void][int]::TryParse((& $text $l 'AppliedOrder'), [ref]$order)
            $linkOn = ((& $text $l 'Enabled') -ne 'false')
            if ($som) { $links += $som }
            if ($linkOn -and $order -gt 0) { $appliedLink = $true }
        }
        $reason = ''
        if ((& $text $g 'AccessDenied') -eq 'true') { $reason = 'Denied (security filtering)' }
        elseif ((& $text $g 'FilterAllowed') -eq 'false') { $reason = 'Denied (WMI filter)' }
        elseif ((& $text $g 'Enabled') -eq 'false') { $reason = 'Disabled GPO' }
        elseif ((& $text $g 'IsValid') -eq 'false') { $reason = 'Not valid' }
        elseif (-not $appliedLink) { $reason = 'Not applied (link disabled or empty GPO)' }
        $gpos += [pscustomobject]@{
            Name = $name; Guid = $guid; Applied = (-not $reason); Reason = $reason
            Links = $links; FilterName = (& $text $g 'FilterName')
        }
    }
    $groups = @()
    foreach ($sg in @($computer.SelectNodes("*[local-name()='SecurityGroup']"))) {
        $n = & $text $sg 'Name'
        if (-not $n) { $n = & $text $sg 'SID' }
        if ($n) { $groups += $n }
    }
    return [pscustomobject]@{
        Domain = (& $text $computer 'Domain'); Site = (& $text $computer 'Site')
        Gpos = $gpos; Groups = @($groups | Sort-Object -Unique)
    }
}

function ConvertFrom-WmiFilterParm {
    # Pure: the queries stored in a WMI filter's msWMI-Parm2 attribute, for
    # example "1;3;10;66;WQL;root\CIMv2;SELECT * FROM Win32_OperatingSystem
    # WHERE Version LIKE '10.0.%';". Fields are separated by ";", and each
    # query is preceded by its length.
    param([string]$Parm)
    $queries = @()
    if (-not $Parm) { return ,$queries }
    $parts = $Parm -split ';'
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($parts[$i] -eq 'WQL' -and $i + 2 -lt $parts.Count) {
            $queries += [pscustomobject]@{ Namespace = $parts[$i + 1]; Query = $parts[$i + 2] }
            $i += 2
        }
    }
    return ,$queries
}

function Test-WmiFilterOsDependent {
    # Pure: true when a WMI filter selects on the Windows version, build or
    # caption - such a filter can stop or start matching after an in-place
    # upgrade. ProductType (server/DC) alone does not change with the upgrade.
    param([string]$Query)
    if (-not $Query) { return $false }
    return ($Query -match 'Win32_OperatingSystem' -and $Query -match '\b(Version|BuildNumber|Caption|OperatingSystemSKU)\b')
}

function Get-GroupPolicyDecision {
    # Pure: what the report says about Group Policy (#80), in three cases:
    # workgroup (only local policy, never MANUAL), domain member with the
    # data read, and domain member where gpresult or AD could not be read
    # (MANUAL, never an empty list that looks clean).
    param(
        [bool]$PartOfDomain,
        [bool]$GpResultRead,
        [bool]$AdRead,
        $LastApplied,
        [datetime]$Now,
        [int]$MaxAgeDays = 7,
        [string]$GpResultError = '',
        [string]$AdError = ''
    )
    $rows = @()
    if (-not $PartOfDomain) {
        $rows += [pscustomobject]@{ Item = 'GroupPolicyScope'; Status = 'INFO'; Kind = 'Evidence'; Value = 'Workgroup server: only local policy applies'; Details = 'No domain GPOs or AD groups apply to a workgroup server.'; Recommendation = '' }
        return ,$rows
    }
    if (-not $GpResultRead) {
        $rows += [pscustomobject]@{ Item = 'GroupPolicyScope'; Status = 'MANUAL'; Kind = 'Finding'; Value = 'Could not read the applied Group Policy (gpresult)'; Details = $GpResultError; Recommendation = 'The GPO list is missing - this is not evidence that no GPO applies. Run "gpresult /scope computer /h gp.html" as administrator and review it before the change.' }
    }
    if (-not $AdRead) {
        $rows += [pscustomobject]@{ Item = 'DomainLookup'; Status = 'MANUAL'; Kind = 'Finding'; Value = 'Could not reach the domain: WMI filters and AD groups are incomplete'; Details = $AdError; Recommendation = 'Check domain connectivity from this server, then re-run. Until then, review the WMI filters of the GPOs and the computer''s groups in Active Directory manually.' }
    }
    if ($null -eq $LastApplied) {
        $rows += [pscustomobject]@{ Item = 'GroupPolicyLastApplied'; Status = 'MANUAL'; Kind = 'Observation'; Value = 'Not readable'; Details = ''; Recommendation = 'Check "gpresult /r" for the last time Group Policy was applied.' }
    } else {
        $age = [math]::Floor(($Now - [datetime]$LastApplied).TotalDays)
        if ($age -gt $MaxAgeDays) {
            $rows += [pscustomobject]@{ Item = 'GroupPolicyLastApplied'; Status = 'WARNING'; Kind = 'Finding'; Value = ('This server has not received Group Policy since ' + ([datetime]$LastApplied).ToString('yyyy-MM-dd HH:mm') + ' (' + $age + ' days)'); Details = ('Limit: ' + $MaxAgeDays + ' days (GroupPolicyMaxAgeDays)'); Recommendation = 'Find out why (domain connectivity, secure channel, Group Policy errors in the System log), fix it and run "gpupdate /target:computer" before the change.' }
        } else {
            $rows += [pscustomobject]@{ Item = 'GroupPolicyLastApplied'; Status = 'OK'; Kind = 'Evidence'; Value = ([datetime]$LastApplied).ToString('yyyy-MM-dd HH:mm'); Details = ($age.ToString() + ' days ago'); Recommendation = '' }
        }
    }
    return ,$rows
}

function ConvertFrom-FileTimeValue {
    # Pure: a FILETIME stored as two DWORD registry values (high, low).
    param($High, $Low)
    if ($null -eq $High -or $null -eq $Low) { return $null }
    # Registry DWORDs arrive as Int32 (possibly negative): mask to 32 bits.
    $mask = [int64]4294967295
    $value = (([int64]$High -band $mask) -shl 32) -bor ([int64]$Low -band $mask)
    if ($value -le 0) { return $null }
    try { return [DateTime]::FromFileTime($value) } catch { return $null }
}

# Official pages linked from recommendations (#79). Only stable pages;
# the report text must make sense without them (servers are often offline).
$script:DocLinks = @{
    InPlaceUpgrade = @{ Url = 'https://learn.microsoft.com/en-us/windows-server/get-started/perform-in-place-upgrade'; Title = 'Microsoft: Perform an in-place upgrade of Windows Server' }
    SetupOptions   = @{ Url = 'https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-command-line-options'; Title = 'Microsoft: Windows Setup command-line options (/Compat ScanOnly)' }
    AppCmd         = @{ Url = 'https://learn.microsoft.com/en-us/iis/get-started/getting-started-with-iis/getting-started-with-appcmdexe'; Title = 'Microsoft: Getting started with AppCmd.exe (backups)' }
    TrendAgents    = @{ Url = 'https://docs.trendmicro.com/en-us/documentation/article/trend-vision-one-agent-platform-compatibility'; Title = 'Trend Micro: agent platform compatibility' }
}

function Get-RecommendationCommand {
    # Pure: the exact command shown with a recommendation (#79). Every
    # command is built here, so each one has a test of its exact text.
    # The script never runs these commands.
    param([Parameter(Mandatory=$true)][string]$Id, [hashtable]$Values = @{})
    switch ($Id) {
        'PendingRename' { return [pscustomobject]@{ Kind = 'Check'; Command = "Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PendingFileRenameOperations" } }
        'Restart'       { return [pscustomobject]@{ Kind = 'Change'; Command = 'Restart-Computer' } }
        'IisBackup'     { return [pscustomobject]@{ Kind = 'Change'; Command = '& "$env:windir\system32\inetsrv\appcmd.exe" add backup "PreIPU"' } }
        'FolderAcl'     { return [pscustomobject]@{ Kind = 'Change'; Command = ('icacls "' + $Values.Path + '" /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F') } }
        'EnableNla'     { return [pscustomobject]@{ Kind = 'Change'; Command = 'Get-CimInstance -Namespace root\cimv2\TerminalServices -ClassName Win32_TSGeneralSetting -Filter "TerminalName=''RDP-tcp''" | Invoke-CimMethod -MethodName SetUserAuthenticationRequired -Arguments @{ UserAuthenticationRequired = 1 }' } }
        'LbfoTeams'     { return [pscustomobject]@{ Kind = 'Check'; Command = 'Get-NetLbfoTeam | Format-List Name, Status, TeamingMode, LoadBalancingAlgorithm, Members' } }
        'CFreeSpace'    { return [pscustomobject]@{ Kind = 'Check'; Command = 'Get-Volume -DriveLetter C | Format-List DriveLetter, FileSystemLabel, @{ n = ''SizeGB''; e = { [math]::Round($_.Size / 1GB, 1) } }, @{ n = ''FreeGB''; e = { [math]::Round($_.SizeRemaining / 1GB, 1) } }' } }
    }
    throw ('Unknown recommendation command: ' + $Id)
}

function Get-UacDecision {
    # Pure: User Account Control in plain words from the registry values
    # under HKLM\...\Policies\System (#75). Missing values mean the
    # Windows defaults (EnableLUA 1, ConsentPromptBehaviorAdmin 5,
    # PromptOnSecureDesktop 1, FilterAdministratorToken 0).
    param($EnableLua, $ConsentPromptBehaviorAdmin, $PromptOnSecureDesktop, $FilterAdministratorToken)
    $num = { param($v, [int]$Default) if ($null -eq $v -or [string]$v -eq '') { return $Default }; return [int]$v }
    $lua = & $num $EnableLua 1
    if ($lua -eq 0) {
        return [pscustomobject]@{ State = 'Off'; Text = 'Off - administrators run everything elevated without a prompt (EnableLUA=0)' }
    }
    $consent = & $num $ConsentPromptBehaviorAdmin 5
    $secure = & $num $PromptOnSecureDesktop 1
    $texts = @{ 0 = 'elevate without prompting'; 1 = 'prompt for credentials on the secure desktop'; 2 = 'prompt for consent on the secure desktop'; 3 = 'prompt for credentials'; 4 = 'prompt for consent'; 5 = 'prompt for consent for non-Windows programs (Windows default)' }
    $text = $texts[$consent]
    if (-not $text) { $text = 'unknown prompt behaviour (ConsentPromptBehaviorAdmin=' + $consent + ')' }
    if ($consent -ge 3 -and $consent -le 5 -and $secure -eq 0) { $text += ', not on the secure desktop' }
    $result = 'On - ' + $text
    if ((& $num $FilterAdministratorToken 0) -eq 1) { $result += '; built-in Administrator also gets prompts (Admin Approval Mode)' }
    return [pscustomobject]@{ State = 'On'; Text = $result }
}

function Get-OutputFolderAccessDecision {
    # Pure: what the report says about the output folder's permissions.
    param([string]$State, [string[]]$BroadReaders = @(), [string]$Path = '')
    $readers = @($BroadReaders | Where-Object { $_ })
    switch ($State) {
        'CreatedRestricted' {
            return [pscustomobject]@{ Status='OK'; Kind='Evidence'; Text='Created by this run; access limited to SYSTEM and Administrators.' }
        }
        'CreatedUnrestricted' {
            return [pscustomobject]@{ Status='WARNING'; Kind='Observation'; Text='Created by this run, but its permissions could not be restricted (see the log). Restrict access manually; the reports describe the server in detail.' }
        }
        'Created' {
            return [pscustomobject]@{ Status='INFO'; Kind='Evidence'; Text='Created by this run with inherited permissions (RestrictOutputAcl is off).' }
        }
    }
    if ($readers.Count -gt 0) {
        return [pscustomobject]@{ Status='WARNING'; Kind='Observation'
            Text=('Existing folder readable by ' + ($readers -join ', ') + '. The reports describe the server in detail. Restrict it with the command shown, or delete the folder so the next run recreates it restricted.')
            Command=(Get-RecommendationCommand 'FolderAcl' @{ Path = $Path }).Command }
    }
    return [pscustomobject]@{ Status='INFO'; Kind='Evidence'; Text='Existing folder; its permissions were left unchanged and do not grant read access to Everyone, Authenticated Users or Users.' }
}

function ConvertTo-RelaunchArgumentText {
    # Pure: turns the caller's bound parameters into PowerShell argument text
    # for the 64-bit relaunch (-Command). Strings are single-quoted with
    # embedded quotes doubled; booleans and switches keep their type. Any
    # other type throws, so a future parameter cannot be passed wrongly.
    param([System.Collections.IDictionary]$Parameters)
    $text = ''
    if ($null -eq $Parameters) { return $text }
    foreach ($key in @($Parameters.Keys | Sort-Object)) {
        $v = $Parameters[$key]
        if ($v -is [System.Management.Automation.SwitchParameter]) { $text += ' -' + $key + ':$' + ([bool]$v).ToString().ToLowerInvariant() }
        elseif ($v -is [bool]) { $text += ' -' + $key + ' $' + $v.ToString().ToLowerInvariant() }
        elseif ($v -is [int]) { $text += ' -' + $key + ' ' + $v.ToString([Globalization.CultureInfo]::InvariantCulture) }
        elseif ($v -is [string]) { $text += ' -' + $key + " '" + ($v -replace "'","''") + "'" }
        else {
            $typeName = '<null>'
            if ($null -ne $v) { $typeName = $v.GetType().FullName }
            throw ("Parameter '" + $key + "' has type " + $typeName + ", which the 64-bit relaunch cannot pass. Add support in ConvertTo-RelaunchArgumentText.")
        }
    }
    return $text
}

function Get-SlowCheckBudget {
    # Pure: DISM and SFC share SlowCheckBudgetMinutes; the optional Setup
    # compatibility scan adds its own timeout, but only when media is set and
    # the run is a pre-upgrade run (the scan does not run after the upgrade).
    param([int]$SlowCheckBudget, [int]$CompatScanTimeout, [string]$MediaPath, [string]$Mode)
    $minutes = $SlowCheckBudget
    if ($MediaPath -and $Mode -eq 'Pre') { $minutes += $CompatScanTimeout }
    return $minutes
}

function Get-SlowSecondsLeft {
    param([int]$BudgetMinutes, [double]$ElapsedSeconds)
    return [int](($BudgetMinutes * 60) - $ElapsedSeconds)
}

function Test-SlowCheckSkip {
    # Pure: a slow check needs at least one minute to be worth starting.
    param([int]$SecondsLeft)
    return ($SecondsLeft -lt 60)
}

function Add-SkippedSlowCheck {
    # Records a slow check that was not started because the budget ran out,
    # as a MANUAL finding and a Skipped run, so the gap is visible.
    param($Check, [int]$BudgetMinutes)
    $script:CurrentCheckId = $Check.Id
    Add-Result 'WINDOWS_HEALTH' $Check.Name 'MANUAL' 'Skipped - slow-check time budget used up' ('Budget=' + $BudgetMinutes + ' min') -Recommendation 'Run this check manually, or raise SlowCheckBudgetMinutes (and the SA job timeout).'
    $script:CheckRuns.Add([pscustomobject]@{ Id=$Check.Id; Name=$Check.Name; Phase='Slow'; Outcome='Skipped'; Duration='00:00:00'; Seconds=0; Message='Time budget used up' })
    $script:CurrentCheckId = 'core'
}

function Test-HttpSysBindingBlock {
    # Pure: true for a netsh "http show sslcert" block that describes a
    # binding. The header block ("SSL Certificate bindings:" and its dashes)
    # is not a binding. Labels stay English on localized Windows.
    param([string[]]$Lines)
    return (@($Lines | Where-Object { $_ -match '^\s*(IP:port|Hostname:port|Central Certificate Store)\s*:' }).Count -gt 0)
}

function Get-DefenderEndpointDecision {
    # Pure: the Defender for Endpoint sensor service (Sense) is part of
    # Windows Server 2019 and later even when the server was never
    # onboarded. Only an onboarded or running sensor is an EDR to plan for.
    param([string]$SenseState, $OnboardingState)
    if ([string]$OnboardingState -eq '1') { return [pscustomobject]@{ Status='WARNING'; Active=$true; Text='Onboarded (OnboardingState=1), service ' + $SenseState } }
    if ($SenseState -eq 'Running') { return [pscustomobject]@{ Status='WARNING'; Active=$true; Text='Sensor service running; onboarding state not readable' } }
    $state = 'not readable'; if ($null -ne $OnboardingState -and [string]$OnboardingState -ne '') { $state = [string]$OnboardingState }
    return [pscustomobject]@{ Status='INFO'; Active=$false; Text='Built-in sensor present, not onboarded (service ' + $SenseState + ', OnboardingState ' + $state + ')' }
}

function Get-SecurityToolDecision {
    # Pure: a security or monitoring tool with a kernel or filter driver can
    # break Windows Setup (a common cause of rollback), so it is a finding.
    # A user-mode tool without drivers rarely does; it is listed as an
    # observation to verify after the upgrade (#78).
    param([string[]]$Drivers = @(), [string]$Target = 'the target release')
    $drv = @($Drivers | Where-Object { $_ })
    if ($drv.Count -gt 0) {
        return [pscustomobject]@{ Kind = 'Finding'; Recommendation = ('Installs a driver (' + ($drv -join ', ') + '). Confirm this version supports ' + $Target + ' and whether the vendor wants it updated or stopped during Setup; drivers are a common cause of rollback.') }
    }
    return [pscustomobject]@{ Kind = 'Observation'; Recommendation = ('No driver found, so it rarely affects Setup. Check that it starts and reports again after the upgrade, and that the vendor supports ' + $Target + '.') }
}

function Get-DetectionProductName {
    # Pure: "<Label> <version>" from the first application that matched, so
    # the summary names the product and build that is installed.
    param($Match)
    $versions = @($Match.Apps | Where-Object { $_.Version } | ForEach-Object { ([string]$_.Version).Trim() } | Sort-Object -Unique)
    if ($versions.Count -gt 0) { return ($Match.Label + ' ' + ($versions -join '/')) }
    return [string]$Match.Label
}

function ConvertFrom-SiteDataJson {
    # Pure: parses the text of a site data file and checks its Schema field.
    # Throws a message meant for the report when the file cannot be used.
    param([string]$Text, [string]$Schema)
    if (-not $Text -or -not $Text.Trim()) { throw 'The file is empty.' }
    try { $obj = $Text | ConvertFrom-Json -ErrorAction Stop }
    catch { throw ('The file is not valid JSON: ' + $_.Exception.Message) }
    if ($null -eq $obj -or $obj -isnot [System.Management.Automation.PSCustomObject]) { throw 'The file must contain one JSON object.' }
    $found = $obj.PSObject.Properties | Where-Object { $_.Name -eq 'Schema' }
    if (-not $found -or [string]$found.Value -ne $Schema) { throw ('Schema must be "' + $Schema + '".') }
    return $obj
}

function Merge-DetectionPatternSet {
    # Pure: applies a pattern file (parsed JSON) to the built-in pattern table.
    # Per category, an entry whose Label matches a built-in entry replaces it,
    # Disabled = true removes it, and a new Label is added. Returns the merged
    # table, the changes made and the errors found; with errors, the caller
    # must keep the built-in table (nothing is applied in part).
    param([hashtable]$Default, $Override, [string[]]$Fields = $script:PatternFields)
    $errors = New-Object System.Collections.Generic.List[string]
    $changes = New-Object System.Collections.Generic.List[string]
    $merged = @{}
    foreach ($k in @($Default.Keys)) {
        $merged[$k] = @(foreach ($e in $Default[$k]) { $c = @{}; foreach ($f in @($e.Keys)) { $c[$f] = $e[$f] }; $c })
    }
    foreach ($prop in @($Override.PSObject.Properties)) {
        if ($prop.Name -eq 'Schema') { continue }
        $cat = @($Default.Keys | Where-Object { $_ -eq $prop.Name })
        if ($cat.Count -eq 0) { $errors.Add(('Unknown category "' + $prop.Name + '". Use: ' + ((@($Default.Keys) | Sort-Object) -join ', ') + '.')); continue }
        $cat = $cat[0]
        $entries = @($prop.Value)
        $n = 0
        foreach ($entry in $entries) {
            $n++
            $where = $cat + ' entry ' + $n
            if ($entry -isnot [System.Management.Automation.PSCustomObject]) { $errors.Add($where + ': must be an object.'); continue }
            $names = @($entry.PSObject.Properties | ForEach-Object { $_.Name })
            $unknown = @($names | Where-Object { $Fields -notcontains $_ })
            if ($unknown.Count -gt 0) { $errors.Add(($where + ': unknown field ' + ($unknown -join ', ') + '. Use: ' + ($Fields -join ', ') + '.')) ; continue }
            $label = [string]$entry.Label
            if (-not $label.Trim()) { $errors.Add($where + ': Label is required.'); continue }
            $where = $cat + ' "' + $label + '"'
            $idx = -1
            for ($i = 0; $i -lt $merged[$cat].Count; $i++) { if ($merged[$cat][$i].Label -ieq $label) { $idx = $i; break } }
            if ($names -contains 'Disabled') {
                if ($entry.Disabled -isnot [bool]) { $errors.Add($where + ': Disabled must be true or false.'); continue }
                if ($entry.Disabled) {
                    if ($idx -lt 0) { $errors.Add($where + ': cannot disable, there is no built-in entry with this Label.'); continue }
                    $merged[$cat] = @(for ($i = 0; $i -lt $merged[$cat].Count; $i++) { if ($i -ne $idx) { $merged[$cat][$i] } })
                    $changes.Add(($cat + ': disabled "' + $label + '"'))
                    continue
                }
            }
            $new = @{ Label = $label }
            $bad = $false
            foreach ($f in @('App','Service','Display','Driver')) {
                if ($names -notcontains $f) { continue }
                $value = $entry.$f
                if ($value -isnot [string] -or -not $value.Trim()) { $errors.Add($where + ': ' + $f + ' must be a non-empty text.'); $bad = $true; continue }
                try { $null = New-Object System.Text.RegularExpressions.Regex($value) }
                catch { $errors.Add(($where + ': ' + $f + ' is not a valid regular expression: ' + $_.Exception.InnerException.Message)); $bad = $true; continue }
                $new[$f] = $value
            }
            foreach ($f in @('Link','LinkTitle')) {
                if ($names -notcontains $f) { continue }
                $value = $entry.$f
                if ($value -isnot [string] -or -not $value.Trim()) { $errors.Add($where + ': ' + $f + ' must be a non-empty text.'); $bad = $true; continue }
                if ($f -eq 'Link' -and $value -notmatch '^https://[^\s"<>]+$') { $errors.Add($where + ': Link must be an https URL.'); $bad = $true; continue }
                $new[$f] = $value
            }
            if ($bad) { continue }
            if (@($new.Keys | Where-Object { @('App','Service','Display','Driver') -contains $_ }).Count -eq 0) { $errors.Add($where + ': needs at least one of App, Service, Display, Driver.'); continue }
            if ($idx -ge 0) { $merged[$cat][$idx] = $new; $changes.Add(($cat + ': replaced "' + $label + '"')) }
            else { $merged[$cat] = @($merged[$cat]) + @($new); $changes.Add(($cat + ': added "' + $label + '"')) }
        }
    }
    if ($changes.Count -eq 0 -and $errors.Count -eq 0) { $errors.Add('The file changes no pattern.') }
    return [pscustomobject]@{ Patterns = $merged; Changes = $changes.ToArray(); Errors = $errors.ToArray() }
}

function Get-ProfileSettingDecision {
    # Pure: checks a profile file (parsed JSON) against the settings it may
    # set. Each value is converted and validated with the parameter's own
    # attributes ($Attributes: name -> attribute list), so a profile cannot
    # set what the command line could not. Settings given as arguments
    # ($Bound) win and are listed as Ignored. With errors, apply nothing.
    param($Override, [hashtable]$Attributes, [string[]]$Allowed = $script:ProfileSettingNames, [string[]]$Bound = @())
    $errors = New-Object System.Collections.Generic.List[string]
    $ignored = New-Object System.Collections.Generic.List[string]
    $settings = [ordered]@{}
    foreach ($prop in @($Override.PSObject.Properties)) {
        if ($prop.Name -ne 'Schema' -and $prop.Name -ne 'Settings') { $errors.Add('Unknown field "' + $prop.Name + '". Use: Schema, Settings.') }
    }
    $block = $Override.PSObject.Properties | Where-Object { $_.Name -eq 'Settings' }
    if (-not $block -or $block.Value -isnot [System.Management.Automation.PSCustomObject]) {
        $errors.Add('Settings must be an object, for example "Settings": { "MinimumCFreeGB": 60 }.')
    } else {
        foreach ($s in @($block.Value.PSObject.Properties)) {
            $name = @($Allowed | Where-Object { $_ -eq $s.Name })
            if ($name.Count -eq 0) { $errors.Add(('"' + $s.Name + '" is not a profile setting. Use: ' + ($Allowed -join ', ') + '.')); continue }
            $name = $name[0]
            $attrs = New-Object 'System.Collections.ObjectModel.Collection[Attribute]'
            foreach ($a in @($Attributes[$name])) { if ($a -is [Attribute]) { $attrs.Add($a) } }
            try {
                $probe = New-Object System.Management.Automation.PSVariable($name, $s.Value, ([System.Management.Automation.ScopedItemOptions]::None), $attrs)
            } catch {
                $msg = $_.Exception.Message; if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
                $errors.Add(($name + ': value "' + [string]$s.Value + '" is not allowed. ' + $msg)); continue
            }
            if ($Bound -contains $name) { $ignored.Add($name); continue }
            $settings[$name] = $probe.Value
        }
    }
    if ($settings.Count -eq 0 -and $ignored.Count -eq 0 -and $errors.Count -eq 0) { $errors.Add('The file sets no setting.') }
    return [pscustomobject]@{ Settings = $settings; Ignored = $ignored.ToArray(); Errors = $errors.ToArray() }
}

function New-RedactionContext {
    # Holds the placeholder map for one run, so the same value always gets
    # the same placeholder (in the HTML, the JSON and both report writes).
    param([string]$ComputerName, [string]$DomainFqdn)
    $netbios = @()
    if ($DomainFqdn -and $DomainFqdn -match '\.') { $netbios += ($DomainFqdn -split '\.')[0] }
    if ($ComputerName) { $netbios += $ComputerName }
    return @{ Map = @{}; Counters = @{}; ComputerName = $ComputerName; DomainFqdn = $DomainFqdn; NetBios = $netbios }
}

function Get-RedactionPlaceholder {
    param([hashtable]$Context, [string]$Kind, [string]$Value)
    $key = $Kind + '|' + $Value.ToLowerInvariant()
    if (-not $Context.Map.ContainsKey($key)) {
        $n = 1 + [int]$Context.Counters[$Kind]
        $Context.Counters[$Kind] = $n
        $Context.Map[$key] = $Kind + '-' + $n
    }
    return $Context.Map[$key]
}

function Protect-ReportText {
    # Best-effort redaction of one text. Well-known names (BUILTIN, NT
    # AUTHORITY, S-1-5-32-*, 127.0.0.1, 0.0.0.0), versions and file paths are
    # kept. Pure apart from the shared placeholder map in $Context.
    param([string]$Text, [hashtable]$Context)
    if (-not $Text) { return $Text }
    $ctx = $Context
    $t = $Text
    $ic = [Text.RegularExpressions.RegexOptions]::IgnoreCase

    # Local group members: "name [WinNT://DOMAIN/name]"
    $t = [regex]::Replace($t, '([^\s|>\[\]][^|<>\[\]]*?) \[WinNT://([^/\]]+)/([^\]]+)\]', {
        param($m)
        $acct = Get-RedactionPlaceholder $ctx 'ACCOUNT' ($m.Groups[2].Value + '\' + $m.Groups[3].Value)
        $domKind = 'DOMAIN'; if ($m.Groups[2].Value -ieq $ctx.ComputerName) { $domKind = 'HOST' }
        $dom = Get-RedactionPlaceholder $ctx $domKind $m.Groups[2].Value
        return $acct + ' [WinNT://' + $dom + '/' + $acct + ']'
    })
    # Certificate thumbprints (40 hex characters)
    $t = [regex]::Replace($t, '(?<![0-9A-Fa-f])[0-9A-Fa-f]{40}(?![0-9A-Fa-f])', { param($m) Get-RedactionPlaceholder $ctx 'CERT' $m.Value })
    # Certificate subject and issuer names
    $t = [regex]::Replace($t, '\b(CN|OU|O)=([^,|<>\]\r\n]*[^,|<>\]\r\n\s])', { param($m) $m.Groups[1].Value + '=' + (Get-RedactionPlaceholder $ctx 'NAME' $m.Groups[2].Value) })
    # MAC addresses
    $t = [regex]::Replace($t, '\b([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b', { param($m) Get-RedactionPlaceholder $ctx 'MAC' $m.Value })
    # Domain SIDs (well-known S-1-5-32-*, S-1-5-18 etc. are kept)
    $t = [regex]::Replace($t, '\bS-1-5-21(-\d+){3,4}\b', { param($m) Get-RedactionPlaceholder $ctx 'SID' $m.Value })
    # DOMAIN\user. Not after \ : or / (path segments). The domain part must be
    # a known NetBIOS name or an all-caps name that is not a well-known root.
    $skip = '^(BUILTIN|AUTHORITY|SERVICE|APPPOOL|HKLM|HKCU|HKU|HKCR|HKCC|SYSTEM|SOFTWARE)$'
    $t = [regex]::Replace($t, '(?<![\\:/\w.-])([A-Za-z0-9][A-Za-z0-9-]{1,14})\\([A-Za-z0-9._$-]{1,64})', {
        param($m)
        $d = $m.Groups[1].Value
        $known = @($ctx.NetBios | Where-Object { $_ -and $_ -ieq $d }).Count -gt 0
        $caps = ($d -cmatch '^[A-Z0-9-]+$') -and ($d -notmatch $skip) -and ($d -match '[A-Z]')
        if ($known -or $caps) { return Get-RedactionPlaceholder $ctx 'ACCOUNT' $m.Value }
        return $m.Value
    })
    # UPN-style accounts and e-mail addresses
    $t = [regex]::Replace($t, '\b[\w.+-]+@[\w-]+(\.[\w-]+)+\b', { param($m) Get-RedactionPlaceholder $ctx 'ACCOUNT' $m.Value })
    # FQDNs in the server's domain, the domain itself, then the computer name
    if ($ctx.DomainFqdn) {
        $dom = [regex]::Escape($ctx.DomainFqdn)
        $t = [regex]::Replace($t, '\b[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.' + $dom + '\b', { param($m) Get-RedactionPlaceholder $ctx 'HOST' $m.Value }, $ic)
        $t = [regex]::Replace($t, '\b' + $dom + '\b', { param($m) Get-RedactionPlaceholder $ctx 'DOMAIN' $m.Value }, $ic)
    }
    foreach ($n in @($ctx.NetBios)) {
        if (-not $n) { continue }
        $kind = 'DOMAIN'; if ($n -ieq $ctx.ComputerName) { $kind = 'HOST' }
        $t = [regex]::Replace($t, '(?<![\w-])' + [regex]::Escape($n) + '(?![\w])', { param($m) Get-RedactionPlaceholder $ctx $kind $m.Value }, $ic)
    }
    # IPv4 (not version numbers, masks, loopback or the any-address)
    $t = [regex]::Replace($t, '(?<![\w.])(?<!Version[=: ])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\w.])', {
        param($m)
        $o = @(1..4 | ForEach-Object { [int]$m.Groups[$_].Value })
        if (@($o | Where-Object { $_ -gt 255 }).Count -gt 0) { return $m.Value }
        if ($o[0] -eq 255 -or $m.Value -eq '0.0.0.0' -or $o[0] -eq 127) { return $m.Value }
        return Get-RedactionPlaceholder $ctx 'IP' $m.Value
    })
    # IPv6: contains '::' or at least five colons, and at least one hex letter or '::'
    $t = [regex]::Replace($t, '(?<![\w:.])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![\w:])', {
        param($m)
        $v = $m.Value
        $colons = ($v.ToCharArray() | Where-Object { $_ -eq ':' }).Count
        if ($v -eq '::' -or $v -eq '::1') { return $v }
        if (($v.Contains('::') -and $v.Length -gt 3) -or ($colons -ge 5 -and $v -match '[A-Fa-f]')) { return Get-RedactionPlaceholder $ctx 'IP' $v }
        return $v
    })
    return $t
}

function Protect-ReportObject {
    # Returns a redacted copy of strings, arrays, hashtables and objects.
    param($Value, [hashtable]$Context)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return (Protect-ReportText $Value $Context) }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($k in @($Value.Keys)) { $copy[$k] = Protect-ReportObject $Value[$k] $Context }
        return $copy
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @(foreach ($i in $Value) { , (Protect-ReportObject $i $Context) })
        return ,$items
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $copy = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) { $copy[$p.Name] = Protect-ReportObject $p.Value $Context }
        return [pscustomobject]$copy
    }
    return $Value
}

function Get-OverallStatus {
    param([object[]]$Results)
    $findings = @($Results | Where-Object { $_.Kind -eq 'Finding' })
    foreach ($status in $script:FindingStatuses) {
        if (@($findings | Where-Object { $_.Status -eq $status }).Count -gt 0) { return $status }
    }
    return 'OK'
}

function Get-StatusRank {
    param([string]$Status)
    $i = $script:StatusOrder.IndexOf($Status)
    if ($i -lt 0) { return 99 }
    return $i
}


# =============================================================================
# 5. CHECKS
# =============================================================================
function Register-AssessmentCheck {

# ---------------------------------------------------------------------------
Register-Check -Id 'baseline' -Name 'Baseline inventory' -Script {
    $script:Data.OS       = @(Get-CimRequired 'Win32_OperatingSystem') | Select-Object -First 1
    $script:Data.CS       = @(Get-CimRequired 'Win32_ComputerSystem') | Select-Object -First 1
    $script:Data.BIOS     = @(Get-CimSafe 'Win32_BIOS') | Select-Object -First 1
    $script:Data.CPU      = @(Get-CimSafe 'Win32_Processor')
    $script:Data.Services = @(Get-CimRequired 'Win32_Service')
    $script:Data.Apps     = @(Get-InstalledApplication)
    $script:Data.CV       = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $script:Data.Features = $null
    if (Test-CommandAvailable 'Get-WindowsFeature') {
        $script:Data.Features = @{}
        foreach ($f in @(Get-WindowsFeature -ErrorAction Stop)) { $script:Data.Features[$f.Name] = [bool]$f.Installed }
    }
    # Drivers: file-system filter drivers (fltmc) and running kernel drivers.
    # Used to recognise AV/EDR/security products independently of their names.
    $flt = Invoke-NativeCapture (Join-Path $env:windir 'System32\fltMC.exe') @('filters') 60
    $script:Data.FilterDrivers = @($flt.Lines | Where-Object { $_ -match '^\s*([A-Za-z0-9_.-]+)\s+\d+\s+' } | ForEach-Object { ($_ -split '\s+' | Where-Object { $_ })[0] })
    $script:Data.KernelDrivers = @(Get-CimSafe 'Win32_SystemDriver' "State='Running'")
    $script:Data.DriverNames = @(@($script:Data.FilterDrivers) + @($script:Data.KernelDrivers | ForEach-Object { [string]$_.Name }) | Sort-Object -Unique)

    $platform = Get-PlatformClassification $script:Data.CS.Manufacturer $script:Data.CS.Model
    $script:Data.Platform = $platform
    $script:Data.IsClustered = $false

    # Snapshot used for the post-upgrade comparison (stored in the JSON).
    $script:Data.Snapshot = @{
        Services = @($script:Data.Services | ForEach-Object { [pscustomobject]@{ Name=[string]$_.Name; State=[string]$_.State; StartMode=[string]$_.StartMode } })
        Apps     = @($script:Data.Apps | ForEach-Object { [pscustomobject]@{ Name=$_.Name; Version=$_.Version } })
        Features = @()
        Ports = @(); Routes = @(); IPv4 = @(); Dns = @(); Hosts = @(); Tasks = @()
    }
    if ($script:Data.Features) { $script:Data.Snapshot.Features = @($script:Data.Features.Keys | Where-Object { $script:Data.Features[$_] } | Sort-Object) }

    Add-Result 'ASSESSMENT' 'CollectorVersion' 'INFO' $script:CollectorVersion 'Restructured 4.x edition' -Source 'Script constant'
    Add-Result 'ASSESSMENT' 'Target' 'INFO' (Get-ReleaseDisplayName $TargetServerVersion) ('MediaLanguage=' + $(if ($TargetMediaLanguage) { $TargetMediaLanguage } else { 'not set' })) -Source 'SETTINGS'
    Add-Result 'ASSESSMENT' 'ExecutionContext' 'INFO' ('Identity=' + [Security.Principal.WindowsIdentity]::GetCurrent().Name) @(('PowerShell=' + $PSVersionTable.PSVersion),('LanguageMode=' + $ExecutionContext.SessionState.LanguageMode)) -Source 'Runtime'
    if ($script:Is32BitHost) {
        Add-Result 'COLLECTOR' '32-bit PowerShell host' 'ACTION' 'Running in 32-bit PowerShell on 64-bit Windows and could not relaunch as 64-bit' -Recommendation 'Registry and System32 reads are redirected, so application, SQL and tool results are unreliable. Run the script as a file under 64-bit PowerShell and re-assess.' -Source 'Environment.Is64BitProcess'
    }
    Add-Result 'ASSESSMENT' 'ReportDestination' 'INFO' $ReportDirectory ('Policy evidence: ' + $(if ($EnableRDPPolicyEvidence) { $PolicyEvidenceRoot } else { 'disabled' })) -Source 'SETTINGS'
    $folderState = $script:OutputFolderState
    if (-not $folderState) { $folderState = 'Existing' }
    $readers = @()
    if ($folderState -eq 'Existing') { $readers = @(Get-BroadFolderReader $ReportDirectory) }
    $access = Get-OutputFolderAccessDecision $folderState $readers $ReportDirectory
    if ($access.PSObject.Properties['Command'] -and $access.Command) {
        Add-Result 'ASSESSMENT' 'OutputFolderAccess' $access.Status $ReportDirectory $access.Text -Kind $access.Kind -Source 'Get-Acl' -Command $access.Command -CommandKind 'Change'
    } else {
        Add-Result 'ASSESSMENT' 'OutputFolderAccess' $access.Status $ReportDirectory $access.Text -Kind $access.Kind -Source 'Get-Acl'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'upgradepath' -Name 'Upgrade path, edition and media' -Script {
    $os = $script:Data.OS; $cv = $script:Data.CV
    $buildText = [string]$os.BuildNumber
    if ($cv.UBR) { $buildText += '.' + $cv.UBR }
    $source = Get-WindowsServerRelease $os.BuildNumber $os.Caption
    $script:Data.SourceRelease = $source
    Add-Result 'UPGRADE_PATH' 'CurrentOS' 'INFO' $os.Caption @(('Build=' + $buildText),('Release=' + (Get-ReleaseDisplayName $source)),('Architecture=' + $os.OSArchitecture)) -Source 'Win32_OperatingSystem'

    # The cluster check runs later; read membership here directly so the path
    # decision already knows about it.
    $clustered = $false
    if ((Get-FeatureState 'Failover-Clustering') -eq $true) {
        $clusSvc = @($script:Data.Services | Where-Object { $_.Name -eq 'ClusSvc' -and $_.StartMode -ne 'Disabled' })
        $clusterKey = Test-Path 'HKLM:\Cluster'
        if ($clusSvc.Count -gt 0 -and $clusterKey) { $clustered = $true }
    }
    $script:Data.IsClustered = $clustered
    $path = Get-UpgradePathDecision $source $TargetServerVersion $clustered
    Add-Result 'UPGRADE_PATH' 'TargetUpgradePath' $path.Status $path.Text ('Target=' + (Get-ReleaseDisplayName $TargetServerVersion)) -Source 'Microsoft supported upgrade paths (installation media)' -Link $script:DocLinks.InPlaceUpgrade.Url -LinkTitle $script:DocLinks.InPlaceUpgrade.Title

    $edition = Get-EditionDecision $cv.EditionID $cv.InstallationType $TargetServerVersion
    $script:Data.Edition = $edition
    $mediaText = $edition.MediaImage
    if (-not $mediaText) { $mediaText = 'Not determined' }
    Add-Result 'UPGRADE_PATH' 'EditionAndInstallationType' $edition.Status ('Edition=' + $edition.Edition + ', ' + $edition.Variant) @(('EditionID=' + $cv.EditionID),('InstallationType=' + $cv.InstallationType)) -Recommendation $edition.Text -Source 'HKLM CurrentVersion'

    # Install language (what Setup compares), not the system locale.
    $installLang = ConvertFrom-LanguageId (Get-RegistryValueSafe 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language' 'InstallLanguage').Value 16
    if (-not $installLang) { $installLang = ConvertFrom-LanguageId ([string]$os.OSLanguage) 10 }
    $uiLang = ConvertFrom-LanguageId (Get-RegistryValueSafe 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language' 'Default').Value 16
    $systemLocale = ''
    try { if (Test-CommandAvailable 'Get-WinSystemLocale') { $systemLocale = (Get-WinSystemLocale).Name } } catch { Write-Swallowed $_ }
    $script:Data.InstallLanguage = $installLang
    $langDetails = @(('DefaultUILanguage=' + $uiLang),('SystemLocale=' + $systemLocale + ' (not relevant for media)'))
    if (-not $installLang) {
        Add-Result 'UPGRADE_PATH' 'InstallLanguage' 'MANUAL' 'Install language could not be determined' $langDetails -Recommendation 'Confirm the installed OS language; IPU cannot change language.' -Source 'Nls\Language InstallLanguage'
    } elseif ($TargetMediaLanguage -and $TargetMediaLanguage -ne $installLang) {
        Add-Result 'UPGRADE_PATH' 'InstallLanguage' 'BLOCKER' ('Installed=' + $installLang + ', TargetMedia=' + $TargetMediaLanguage) $langDetails -Recommendation ('Changing language during IPU is not supported. Use ' + $installLang + ' installation media.') -Source 'Nls\Language InstallLanguage'
    } else {
        Add-Result 'UPGRADE_PATH' 'InstallLanguage' 'OK' ('Installed=' + $installLang) $langDetails -Recommendation ('Installation media must be ' + $installLang + '.') -Source 'Nls\Language InstallLanguage'
    }
    $mediaLine = $mediaText
    if ($installLang) { $mediaLine += ' - ' + $installLang + ' media' }
    $script:Data.RecommendedMedia = $mediaLine
    Add-Result 'UPGRADE_PATH' 'RecommendedInstallationImage' 'INFO' $mediaLine 'Select exactly this image in Setup.' -Source 'Derived from edition, installation type and install language'

    # Boot from VHD
    if (Test-CommandAvailable 'Get-Partition') {
        try {
            $cp = Get-Partition -DriveLetter C -ErrorAction Stop
            $disk = Get-Disk -Number $cp.DiskNumber -ErrorAction Stop
            if ([string]$disk.BusType -match 'File Backed Virtual') {
                Add-Result 'UPGRADE_PATH' 'BootFromVHD' 'BLOCKER' ('BusType=' + $disk.BusType) -Recommendation 'In-place upgrade of Windows Server booted from VHD is not supported.' -Source 'Get-Disk'
            }
        } catch { Write-Swallowed $_ }
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'licensing' -Name 'Windows activation' -Script {
    $statusNames = @{ 0='Unlicensed'; 1='Licensed'; 2='OOBGrace'; 3='OOTGrace'; 4='NonGenuineGrace'; 5='Notification'; 6='ExtendedGrace' }
    $products = @()
    $queryError = ''
    try {
        $products = @(Get-CimInstance -Query "SELECT Name,Description,LicenseStatus,PartialProductKey,ProductKeyChannel,GracePeriodRemaining FROM SoftwareLicensingProduct WHERE ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -ErrorAction Stop |
            Where-Object { $_.Name -match '^Windows' })
    } catch {
        # Older builds do not expose ProductKeyChannel; retry with all columns.
        try {
            $products = @(Get-CimInstance -Query "SELECT * FROM SoftwareLicensingProduct WHERE ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" -ErrorAction Stop |
                Where-Object { $_.PartialProductKey -and $_.Name -match '^Windows' })
        } catch { $queryError = $_.Exception.Message }
    }
    $spp = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform' -ErrorAction SilentlyContinue
    $kms = 'Not explicitly configured (DNS auto-discovery or not KMS)'
    if ($spp.KeyManagementServiceName) { $kms = [string]$spp.KeyManagementServiceName; if ($spp.KeyManagementServicePort) { $kms += ':' + $spp.KeyManagementServicePort } }
    $script:Data.KmsEndpoint = $kms

    if ($queryError) {
        Add-Result 'LICENSING' 'CurrentActivation' 'MANUAL' 'Activation state could not be queried' @($queryError,('KMS=' + $kms)) -Recommendation 'Validate activation manually (slmgr /dlv). A query failure does not prove Windows is unlicensed.' -Source 'SoftwareLicensingProduct'
        return
    }
    $primary = @($products | Sort-Object @{Expression={ if ([int]$_.LicenseStatus -eq 1) { 0 } else { 1 } }},Name) | Select-Object -First 1
    if (-not $primary) {
        Add-Result 'LICENSING' 'CurrentActivation' 'ACTION' 'No installed Windows license with a product key was returned' ('KMS=' + $kms) -Recommendation 'Resolve Windows activation before IPU.' -Source 'SoftwareLicensingProduct'
        return
    }
    $state = $statusNames[[int]$primary.LicenseStatus]; if (-not $state) { $state = 'Unknown(' + $primary.LicenseStatus + ')' }
    $channel = [string]$primary.ProductKeyChannel
    if (-not $channel) {
        $d = [string]$primary.Description
        if ($d -match 'VOLUME_KMSCLIENT') { $channel = 'Volume:GVLK (KMS client)' } elseif ($d -match 'VOLUME_MAK') { $channel = 'Volume:MAK' } elseif ($d -match 'OEM') { $channel = 'OEM' } elseif ($d -match 'RETAIL') { $channel = 'Retail' } else { $channel = 'Unknown' }
    }
    $summary = 'Status=' + $state + ', Channel=' + $channel
    $script:Data.ActivationSummary = $summary
    $details = @(('PartialProductKey=' + $primary.PartialProductKey),('KMS=' + $kms))
    if ([int]$primary.LicenseStatus -eq 1) {
        Add-Result 'LICENSING' 'CurrentActivation' 'OK' $summary $details -Source 'SoftwareLicensingProduct (only the last 5 key characters are read)'
    } else {
        Add-Result 'LICENSING' 'CurrentActivation' 'ACTION' $summary $details -Recommendation 'Resolve the current activation state before IPU.' -Source 'SoftwareLicensingProduct'
    }
    if ($channel -match 'OEM') {
        Add-Result 'LICENSING' 'OEMLicense' 'WARNING' $channel -Recommendation 'An OEM licence is tied to the original hardware and release. Confirm the target licence/key before IPU.' -Source 'SoftwareLicensingProduct'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'pendingreboot' -Name 'Pending reboot and uptime' -Script {
    $hard = @(); $soft = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $hard += 'CBS RebootPending' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending') { $hard += 'CBS PackagesPending' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $hard += 'Windows Update RebootRequired' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Updates\UpdateExeVolatile') {
        $v = Get-RegistryValueSafe 'HKLM:\SOFTWARE\Microsoft\Updates\UpdateExeVolatile' 'Flags'
        if ($v.Exists -and [int]$v.Value -ne 0) { $hard += 'UpdateExeVolatile' }
    }
    $active = (Get-RegistryValueSafe 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' 'ComputerName').Value
    $pending = (Get-RegistryValueSafe 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' 'ComputerName').Value
    if ($active -and $pending -and $active -ne $pending) { $hard += ('Pending computer rename ' + $active + ' -> ' + $pending) }
    if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\JoinDomain') { $hard += 'Pending domain join' }
    $renamePaths = @()
    foreach ($name in @('PendingFileRenameOperations','PendingFileRenameOperations2')) {
        $v = Get-RegistryValueSafe 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' $name
        if ($v.Exists -and @($v.Value | Where-Object { $_ }).Count -gt 0) { $soft += $name; $renamePaths += @($v.Value) }
    }
    $renameShown = ConvertTo-PendingRenamePath $renamePaths 5
    try {
        $ccm = Invoke-CimMethod -Namespace 'root\ccm\ClientSDK' -ClassName CCM_ClientUtilities -MethodName DetermineIfRebootPending -ErrorAction Stop
        if ($ccm -and ($ccm.RebootPending -or $ccm.IsHardRebootPending)) { $hard += 'ConfigMgr client reboot pending' }
    } catch { Write-Swallowed $_ }

    if ($hard.Count -gt 0) {
        Add-Result 'WINDOWS_HEALTH' 'PendingReboot' 'ACTION' ($hard -join ' | ') (@($soft) + @($renameShown)) -Recommendation 'Reboot, then re-run the assessment before starting the IPU.' -Source 'CBS, Windows Update, ComputerName, Netlogon, ConfigMgr' -Command (Get-RecommendationCommand 'Restart').Command -CommandKind 'Change'
    } elseif ($soft.Count -gt 0) {
        Add-Result 'WINDOWS_HEALTH' 'PendingReboot' 'WARNING' ($soft -join ' | ') (@('Files waiting to be replaced: ') + @($renameShown)) -Recommendation 'The paths show which product left the pending rename (often AV or an agent update). Reboot in the pre-change window; if the same entries come back, ask that product''s owner.' -Source 'Session Manager' -Command (Get-RecommendationCommand 'PendingRename').Command -CommandKind 'Check'
    } else {
        Add-Result 'WINDOWS_HEALTH' 'PendingReboot' 'OK' 'No pending-reboot indicators detected' -Source 'CBS, Windows Update, Session Manager, ComputerName, Netlogon'
    }

    $boot = ConvertTo-DateTimeValue $script:Data.OS.LastBootUpTime
    if (-not $boot) { throw ('LastBootUpTime could not be read: ' + $script:Data.OS.LastBootUpTime) }
    $days = [math]::Floor(((Get-Date) - $boot).TotalDays)
    if ($days -ge $UptimeWarningDays) {
        Add-Result 'WINDOWS_HEALTH' 'Uptime' 'WARNING' ('UptimeDays=' + $days) ('LastBoot=' + $boot.ToString('yyyy-MM-dd HH:mm')) -Recommendation 'Do a controlled reboot before the change window and re-run the assessment. A long-unrebooted server can hide reboot-time problems that would otherwise surface mid-upgrade.' -Source 'Win32_OperatingSystem'
    } else {
        Add-Result 'WINDOWS_HEALTH' 'Uptime' 'OK' ('UptimeDays=' + $days) ('LastBoot=' + $boot.ToString('yyyy-MM-dd HH:mm')) -Source 'Win32_OperatingSystem'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'patchlevel' -Name 'Patch level' -Script {
    $fixes = @(Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn })
    $latest = $null
    foreach ($f in $fixes) { try { $d = [datetime]$f.InstalledOn; if (-not $latest -or $d -gt $latest.Date) { $latest = [pscustomobject]@{ Date=$d; Id=$f.HotFixID } } } catch { Write-Swallowed $_ } }
    if (-not $latest) {
        Add-Result 'WINDOWS_HEALTH' 'LatestUpdate' 'MANUAL' 'No dated update history returned' -Recommendation 'Confirm the server has the latest cumulative and servicing stack updates before IPU.' -Source 'Get-HotFix'
        return
    }
    $age = [math]::Floor(((Get-Date) - $latest.Date).TotalDays)
    $value = 'LatestInstalled=' + $latest.Date.ToString('yyyy-MM-dd') + ' (' + $latest.Id + ')'
    if ($age -gt $MaxPatchAgeDays) {
        Add-Result 'WINDOWS_HEALTH' 'LatestUpdate' 'WARNING' $value ('AgeDays=' + $age) -Recommendation 'Install the latest cumulative update before IPU; Setup and Dynamic Update are most reliable on a current source OS.' -Source 'Get-HotFix'
    } else {
        Add-Result 'WINDOWS_HEALTH' 'LatestUpdate' 'OK' $value ('AgeDays=' + $age) -Source 'Get-HotFix'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'history' -Name 'Previous upgrade history' -Script {
    $found = $false
    foreach ($key in @(Get-ChildItem 'HKLM:\SYSTEM\Setup' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'Source OS*' } | Sort-Object PSChildName)) {
        $p = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
        $found = $true
        $installed = ''
        if ($p.InstallDate) { try { $installed = (New-Object DateTime 1970,1,1,0,0,0,([DateTimeKind]::Utc)).AddSeconds([int64]$p.InstallDate).ToLocalTime().ToString('yyyy-MM-dd') } catch { Write-Swallowed $_ } }
        Add-Result 'UPGRADE_HISTORY' $key.PSChildName 'INFO' ('Product=' + $p.ProductName) @(('Build=' + $p.CurrentBuild),('InstallDate=' + $installed)) -Source $key.Name
    }
    # Only Source OS registry keys and C:\Windows.old show a completed
    # upgrade. C:\Windows\Panther\setupact.log exists on every server (the
    # original installation writes it), so it is shown as the OS install trace
    # only. C:\$WINDOWS.~BT is left by an aborted setup or a compatibility scan.
    $upgradeHints = @()
    if (Test-Path 'C:\Windows.old') { $upgradeHints += 'C:\Windows.old exists' }
    $osInstall = ''
    $installDate = ConvertTo-DateTimeValue $script:Data.OS.InstallDate
    if ($installDate) { $osInstall = $installDate.ToString('yyyy-MM-dd') }
    Add-Result 'UPGRADE_HISTORY' 'OSInstallDate' 'INFO' $osInstall 'Date of the current OS installation (or of the last in-place upgrade).' -Source 'Win32_OperatingSystem.InstallDate'
    if ($found -or $upgradeHints.Count -gt 0) {
        Add-Result 'UPGRADE_HISTORY' 'PreviousUpgradeEvidence' 'WARNING' ('PriorOSRecords=' + $found) $upgradeHints -Recommendation 'This server has been upgraded in place before. Stacked upgrades carry older settings and drivers along; pay extra attention to the Setup compatibility result and test thoroughly afterwards.' -Kind 'Observation' -Source 'HKLM\SYSTEM\Setup, C:\Windows.old'
    } else {
        Add-Result 'UPGRADE_HISTORY' 'PreviousUpgradeEvidence' 'INFO' 'No previous in-place upgrade recorded' 'Cleanup can remove this evidence; absence does not prove the server was never upgraded.' -Source 'HKLM\SYSTEM\Setup, C:\Windows.old'
    }
    $btLog = 'C:\$WINDOWS.~BT\Sources\Panther\setupact.log'
    if (Test-Path -LiteralPath 'C:\$WINDOWS.~BT') {
        $btDate = ''
        if (Test-Path -LiteralPath $btLog) { $btDate = 'setupact.log LastWrite=' + (Get-Item -LiteralPath $btLog).LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
        Add-Result 'UPGRADE_HISTORY' 'SetupWorkingFolder' 'INFO' 'C:\$WINDOWS.~BT exists' $btDate -Recommendation 'Left by an earlier Setup run: a compatibility scan or an aborted upgrade. If no scan was run, read the Panther logs to see why an upgrade stopped.' -Kind 'Observation' -Source 'C:\$WINDOWS.~BT'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'domain' -Name 'Domain role and access' -Script {
    $cs = $script:Data.CS
    $role = [int]$cs.DomainRole
    $roleNames = @{ 0='Standalone workstation'; 1='Member workstation'; 2='Standalone server'; 3='Member server'; 4='Backup domain controller'; 5='Primary domain controller' }
    $script:Data.DomainRoleText = $roleNames[$role]
    if ($role -ge 4) {
        $status = 'WARNING'; $rec = 'Domain controller: follow the AD DS upgrade guidance (adprep, FSMO, replication health) and engage the AD team.'
        if ($BlockDomainControllerIPU) { $status = 'BLOCKER'; $rec = 'Company standard: do not upgrade domain controllers in place. Build a new DC side-by-side, move roles, demote this DC and swap the IP address.' }
        Add-Result 'DOMAIN_CONTROLLER' 'DomainController' $status $roleNames[$role] ('Domain=' + $cs.Domain) -Recommendation $rec -Source 'Win32_ComputerSystem.DomainRole'
    }

    if ($cs.PartOfDomain) {
        Add-Result 'ACCESS' 'DomainMembership' 'INFO' ('Domain=' + $cs.Domain) ('Role=' + $roleNames[$role]) -Source 'Win32_ComputerSystem'
        if ($role -lt 4) {
            $secure = $null
            if (Test-CommandAvailable 'Test-ComputerSecureChannel') { try { $secure = Test-ComputerSecureChannel -ErrorAction Stop } catch { Write-Swallowed $_ } }
            if ($secure -eq $true) { Add-Result 'ACCESS' 'DomainSecureChannel' 'OK' 'Secure channel verified' -Source 'Test-ComputerSecureChannel' }
            elseif ($secure -eq $false) { Add-Result 'ACCESS' 'DomainSecureChannel' 'ACTION' 'Secure channel test failed' -Recommendation 'Repair the domain trust before IPU; a broken trust can leave you without domain logon after the upgrade.' -Source 'Test-ComputerSecureChannel' }
            else { Add-Result 'ACCESS' 'DomainSecureChannel' 'MANUAL' 'Secure channel could not be tested' -Recommendation 'Verify domain logon manually before the change.' -Source 'Test-ComputerSecureChannel' }
        }
    } else {
        Add-Result 'ACCESS' 'DomainMembership' 'WARNING' ('Workgroup=' + $cs.Domain) -Recommendation 'Workgroup server: confirm it is onboarded in CyberArk/PAM and that local fallback credentials work before IPU.' -Source 'Win32_ComputerSystem'
    }

    # User Account Control (#75). Information, not a finding: UAC does not
    # block an in-place upgrade.
    $uacKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $uacValues = @{}
    foreach ($n in @('EnableLUA','ConsentPromptBehaviorAdmin','PromptOnSecureDesktop','FilterAdministratorToken')) { $uacValues[$n] = (Get-RegistryValueSafe $uacKey $n).Value }
    $uac = Get-UacDecision $uacValues.EnableLUA $uacValues.ConsentPromptBehaviorAdmin $uacValues.PromptOnSecureDesktop $uacValues.FilterAdministratorToken
    $script:Data.UacSummary = $uac.Text
    if ($script:Data.Snapshot) { $script:Data.Snapshot.Uac = $uac.Text }
    Add-Result 'ACCESS' 'UAC' 'INFO' $uac.Text (@($uacValues.Keys | Sort-Object | ForEach-Object { $_ + '=' + $(if ($null -eq $uacValues[$_]) { '(default)' } else { [string]$uacValues[$_] }) }) -join ', ') -Source ($uacKey -replace '^HKLM:','HKLM')

    $rid500 = @(Get-CimSafe 'Win32_UserAccount' 'LocalAccount=True') | Where-Object { $_.SID -match '-500$' } | Select-Object -First 1
    if ($rid500) {
        Add-Result 'ACCESS' 'BuiltInAdministrator' 'INFO' ('Name=' + $rid500.Name) @(('Disabled=' + $rid500.Disabled),('SID=' + $rid500.SID)) -Recommendation 'Record the (possibly renamed) built-in Administrator and confirm PAM/console fallback.' -Source 'Win32_UserAccount'
    }
    $admins = Get-LocalGroupMembersBySid 'S-1-5-32-544'
    foreach ($member in $admins) { Add-Result 'ACCESS' 'LocalAdministratorsMember' 'INFO' $member -Source 'Local group S-1-5-32-544' }
    if ($admins.Count -eq 0) { Add-Result 'ACCESS' 'LocalAdministratorsMember' 'MANUAL' 'No members returned' -Recommendation 'Enumerate local Administrators manually.' -Kind 'Observation' -Source 'Local group S-1-5-32-544' }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'grouppolicy' -Name 'Group Policy and AD groups' -Script {
    # #80: which GPOs apply, which are filtered out and why, WMI filters on the
    # Windows version (they can stop or start matching after the upgrade),
    # the computer's AD groups, and when policy last applied.
    $domainMember = [bool]$script:Data.CS.PartOfDomain
    $gp = $null; $gpError = ''
    try { $gp = ConvertFrom-GpResultXml (Get-GpResultXml) } catch { $gpError = $_.Exception.Message; Write-Swallowed $_ }
    $groups = @(); $filters = @{}; $adError = ''; $adRead = $true
    if ($domainMember) {
        try {
            $groups = @(Get-AdComputerGroup)
            if ($gp) { $filters = Get-WmiFilterQuery @($gp.Gpos | ForEach-Object { $_.Guid }) }
        } catch { $adRead = $false; $adError = $_.Exception.Message; Write-Swallowed $_ }
    }
    $last = $null
    if ($domainMember) { $last = Get-GroupPolicyLastApplied }
    foreach ($row in (Get-GroupPolicyDecision $domainMember ($null -ne $gp) $adRead $last (Get-Date) $GroupPolicyMaxAgeDays $gpError $adError)) {
        Add-Result 'GROUP_POLICY' $row.Item $row.Status $row.Value $row.Details -Recommendation $row.Recommendation -Kind $row.Kind -Source 'gpresult, Active Directory, Group Policy state'
    }
    if ($gp) {
        $target = Get-ReleaseDisplayName $TargetServerVersion
        foreach ($g in @($gp.Gpos)) {
            $state = 'Applied'; if (-not $g.Applied) { $state = $g.Reason }
            $details = @(('Linked at ' + (@($g.Links) -join '; ')))
            $filter = $filters[$g.Guid]
            if ($filter) {
                $details += ('WMI filter: ' + $filter.Name)
                foreach ($q in @($filter.Queries)) { $details += ('Query: ' + $q.Query) }
            } elseif ($g.FilterName) { $details += ('WMI filter: ' + $g.FilterName) }
            $osDependent = $filter -and @($filter.Queries | Where-Object { Test-WmiFilterOsDependent $_.Query }).Count -gt 0
            if ($osDependent) {
                Add-Result 'GROUP_POLICY' ('GPO: ' + $g.Name) 'WARNING' ($state + ' - WMI filter depends on the Windows version') $details -Recommendation ('After the upgrade the server reports ' + $target + '. Check that this filter still matches (or still excludes) it as intended, before the change.') -Source 'gpresult, WMI filter in AD'
            } else {
                Add-Result 'GROUP_POLICY' ('GPO: ' + $g.Name) 'INFO' $state $details -Source 'gpresult'
            }
        }
        if ($domainMember) {
            if ($adRead) {
                foreach ($n in $groups) { Add-Result 'GROUP_POLICY' 'ADGroup' 'INFO' $n -Source 'AD tokenGroups (nested groups included)' }
            }
        } else {
            Add-Result 'GROUP_POLICY' 'ADGroup' 'INFO' 'Not applicable (workgroup)' -Source 'Win32_ComputerSystem'
        }
        if ($script:Data.Snapshot) {
            $script:Data.Snapshot.Gpos = @($gp.Gpos | Where-Object { $_.Applied } | ForEach-Object { $_.Name } | Sort-Object -Unique)
            if ($domainMember -and $adRead) { $script:Data.Snapshot.Groups = @($groups) }
        }
    } elseif (-not $domainMember) {
        # Workgroup server and gpresult failed: still only local policy.
        Add-Result 'GROUP_POLICY' 'LocalPolicy' 'MANUAL' 'Could not list the local policy (gpresult)' $gpError -Recommendation 'The local policy backup in the RDP policy evidence (LGPO) shows the settings. Or run "gpresult /scope computer /h gp.html" as administrator.' -Kind 'Observation' -Source 'gpresult'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'rdp' -Name 'RDP access, policy and evidence' -Script {
    Invoke-RdpPolicyAssessment
}

# ---------------------------------------------------------------------------
Register-Check -Id 'platform' -Name 'Platform and hardware' -Script {
    $cs = $script:Data.CS; $bios = $script:Data.BIOS
    $platform = $script:Data.Platform
    if ($platform.Type -eq 'Virtual') {
        Add-Result 'PLATFORM' 'PhysicalOrVirtual' 'OK' ('Virtual (' + $platform.Hypervisor + ')') @(('Manufacturer=' + $cs.Manufacturer),('Model=' + $cs.Model)) -Source 'Win32_ComputerSystem'
        if ($platform.Hypervisor -match 'AWS|Google|Azure') {
            Add-Result 'PLATFORM' 'CloudProvider' 'MANUAL' $platform.Hypervisor -Recommendation 'Microsoft defers cloud IPU support to the provider. Follow the provider''s documented in-place upgrade procedure and licensing rules.' -Source 'Platform classification'
        }
        return
    }
    if ($platform.Type -eq 'Unknown') {
        Add-Result 'PLATFORM' 'PhysicalOrVirtual' 'MANUAL' 'Could not be determined' -Recommendation 'Confirm the platform manually.' -Source 'Win32_ComputerSystem'
        return
    }
    Add-Result 'PLATFORM' 'PhysicalOrVirtual' 'MANUAL' 'Physical' @(('Manufacturer=' + $cs.Manufacturer),('Model=' + $cs.Model)) -Recommendation ('Validate model, firmware, storage controller and NIC driver support for ' + (Get-ReleaseDisplayName $TargetServerVersion) + ' with the OEM, and confirm a bare-metal recovery path.') -Source 'Local inventory cannot prove OEM certification'

    $product = @(Get-CimSafe 'Win32_ComputerSystemProduct') | Select-Object -First 1
    $board = @(Get-CimSafe 'Win32_BaseBoard') | Select-Object -First 1
    Add-Result 'HARDWARE' 'SystemIdentification' 'INFO' ('Model=' + $cs.Model) @(('SerialOrServiceTag=' + $bios.SerialNumber),('SKU=' + $cs.SystemSKUNumber),('Product=' + $product.Name + ' ' + $product.Version)) -Source 'Win32_ComputerSystem, Win32_BIOS'
    if ($board) { Add-Result 'HARDWARE' 'BaseBoard' 'INFO' ('Manufacturer=' + $board.Manufacturer) @(('Product=' + $board.Product),('Version=' + $board.Version)) -Source 'Win32_BaseBoard' }
    if ($bios) {
        $biosDate = [string]$bios.ReleaseDate
        $releaseDate = ConvertTo-DateTimeValue $bios.ReleaseDate
        if ($releaseDate) { $biosDate = $releaseDate.ToString('yyyy-MM-dd') }
        Add-Result 'HARDWARE' 'BIOS' 'INFO' ('Version=' + $bios.SMBIOSBIOSVersion) @(('Manufacturer=' + $bios.Manufacturer),('ReleaseDate=' + $biosDate)) -Source 'Win32_BIOS'
    }
    $firmware = 'Legacy BIOS or undetermined'
    if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State') { $firmware = 'UEFI' }
    Add-Result 'HARDWARE' 'FirmwareMode' 'INFO' $firmware -Source 'SecureBoot registry presence'
    $i = 0
    foreach ($cpu in $script:Data.CPU) { $i++; Add-Result 'HARDWARE' ('CPU-' + $i) 'INFO' $cpu.Name @(('Cores=' + $cpu.NumberOfCores),('Logical=' + $cpu.NumberOfLogicalProcessors)) -Source 'Win32_Processor' }

    $netDrivers = @(Get-CimSafe 'Win32_PnPSignedDriver' "DeviceClass='NET'")
    foreach ($nic in @(Get-CimSafe 'Win32_NetworkAdapter' | Where-Object { $_.PhysicalAdapter -eq $true })) {
        $drv = @($netDrivers | Where-Object { $_.DeviceID -eq $nic.PNPDeviceID }) | Select-Object -First 1
        $drvText = 'Driver not correlated'
        if ($drv) { $drvText = 'Provider=' + $drv.DriverProviderName + ', Version=' + $drv.DriverVersion + ', Date=' + $drv.DriverDate }
        Add-Result 'HARDWARE' ('NIC: ' + $nic.Name) 'INFO' ('MAC=' + $nic.MACAddress) $drvText -Source 'Win32_NetworkAdapter, Win32_PnPSignedDriver'
    }
    $storageDrivers = @(Get-CimSafe 'Win32_PnPSignedDriver' "DeviceClass='SCSIAdapter'") + @(Get-CimSafe 'Win32_PnPSignedDriver' "DeviceClass='HDC'")
    foreach ($drv in @($storageDrivers | Sort-Object DeviceName,DriverVersion -Unique)) {
        Add-Result 'HARDWARE' ('Storage controller: ' + $drv.DeviceName) 'INFO' ('Provider=' + $drv.DriverProviderName) @(('Version=' + $drv.DriverVersion),('Date=' + $drv.DriverDate)) -Source 'Win32_PnPSignedDriver'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'performance' -Name 'CPU and memory' -Script {
    $cs = $script:Data.CS
    $logical = [int]$cs.NumberOfLogicalProcessors
    if ($logical -le 1) { Add-Result 'PERFORMANCE' 'LogicalProcessors' 'ACTION' $logical -Recommendation 'Add CPU before IPU; setup on a single logical CPU is very slow.' -Source 'Win32_ComputerSystem' }
    elseif ($logical -eq 2) { Add-Result 'PERFORMANCE' 'LogicalProcessors' 'WARNING' $logical -Recommendation 'Setup will be noticeably slower on 2 logical CPUs; consider adding CPU temporarily for the change window.' -Source 'Win32_ComputerSystem' }
    else { Add-Result 'PERFORMANCE' 'LogicalProcessors' 'OK' $logical -Source 'Win32_ComputerSystem' }
    $ramGB = [math]::Round(([double]$cs.TotalPhysicalMemory / 1GB),2)
    if ($ramGB -lt $MinimumMemoryGB) { Add-Result 'PERFORMANCE' 'MemoryGB' 'WARNING' (Format-Number $ramGB) -Recommendation ('Below the project threshold of ' + $MinimumMemoryGB + ' GB; consider adding memory before IPU.') -Source 'Win32_ComputerSystem' }
    else { Add-Result 'PERFORMANCE' 'MemoryGB' 'OK' (Format-Number $ramGB) -Source 'Win32_ComputerSystem' }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'cluster' -Name 'Failover clustering' -Script {
    $feature = Get-FeatureState 'Failover-Clustering'
    if ($feature -ne $true) { Add-Result 'CLUSTER' 'FailoverClustering' 'OK' 'Feature not installed' -Source 'Get-WindowsFeature'; return }
    if (-not (Test-CommandAvailable 'Get-Cluster')) {
        Add-Result 'CLUSTER' 'FailoverClustering' 'ACTION' 'Feature installed; cluster cmdlets unavailable' -Recommendation 'Confirm cluster membership before planning an IPU.' -Source 'Get-WindowsFeature'
        return
    }
    $cluster = $null
    try { $cluster = Get-Cluster -ErrorAction Stop } catch { Write-Swallowed $_ }
    if (-not $cluster) {
        Add-Result 'CLUSTER' 'FailoverClustering' 'WARNING' 'Feature installed but no cluster membership found' -Recommendation 'Remove the feature if unused, or confirm the node is not part of a cluster.' -Source 'Get-Cluster'
        return
    }
    $script:Data.IsClustered = $true
    Add-Result 'CLUSTER' 'ClusterMembership' 'BLOCKER' ('Cluster=' + $cluster.Name) -Recommendation 'Clustered node: use Cluster OS Rolling Upgrade (one version at a time) or a migration plan, not the standalone IPU procedure.' -Source 'Get-Cluster'
    foreach ($n in @(Get-ClusterNode -ErrorAction SilentlyContinue)) { Add-Result 'CLUSTER' ('Node: ' + $n.Name) 'INFO' ('State=' + $n.State) -Source 'Get-ClusterNode' }
    foreach ($g in @(Get-ClusterGroup -ErrorAction SilentlyContinue | Sort-Object Name)) { Add-Result 'CLUSTER' ('Group: ' + $g.Name) 'INFO' ('State=' + $g.State) ('Owner=' + $g.OwnerNode) -Source 'Get-ClusterGroup' }
    $q = Get-ClusterQuorum -ErrorAction SilentlyContinue
    if ($q) { Add-Result 'CLUSTER' 'Quorum' 'INFO' ('Type=' + $q.QuorumType) ('Resource=' + $q.QuorumResource) -Source 'Get-ClusterQuorum' }
    foreach ($csv in @(Get-ClusterSharedVolume -ErrorAction SilentlyContinue)) { Add-Result 'CLUSTER' ('CSV: ' + $csv.Name) 'INFO' ('State=' + $csv.State) ('Owner=' + $csv.OwnerNode) -Source 'Get-ClusterSharedVolume' }
    foreach ($r in @(Get-ClusterResource -ErrorAction SilentlyContinue | Where-Object { [string]$_.ResourceType -eq 'Physical Disk' })) { Add-Result 'CLUSTER' ('Disk: ' + $r.Name) 'INFO' ('State=' + $r.State) ('Group=' + $r.OwnerGroup) -Source 'Get-ClusterResource' }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'storage' -Name 'Storage' -Script {
    $c = @(Get-CimRequired 'Win32_LogicalDisk' "DeviceID='C:'") | Select-Object -First 1
    $sizeGB = [math]::Round(([double]$c.Size / 1GB),2)
    $freeGB = [math]::Round(([double]$c.FreeSpace / 1GB),2)
    $script:Data.CSummary = 'Size ' + (Format-Number $sizeGB) + ' GB, free ' + (Format-Number $freeGB) + ' GB'
    if ($freeGB -lt $MinimumCFreeGB) {
        $needed = [math]::Ceiling(($MinimumCFreeGB - $freeGB) / $ExtendBlockGB) * $ExtendBlockGB
        Add-Result 'STORAGE' 'CFreeSpace' 'ACTION' $script:Data.CSummary ('RequiredExpansionGB=' + $needed) -Recommendation ('Extend C: by at least ' + $needed + ' GB to reach the ' + $MinimumCFreeGB + ' GB free-space target.') -Source 'Win32_LogicalDisk' -Command (Get-RecommendationCommand 'CFreeSpace').Command -CommandKind 'Check'
    } else {
        Add-Result 'STORAGE' 'CFreeSpace' 'OK' $script:Data.CSummary -Source 'Win32_LogicalDisk'
    }

    if (-not (Test-CommandAvailable 'Get-Disk')) {
        foreach ($d in @(Get-CimSafe 'Win32_DiskDrive' | Sort-Object Index)) { Add-Result 'STORAGE' ('Disk' + $d.Index) 'INFO' ('SizeGB=' + (Format-Number ($d.Size/1GB))) ('Model=' + $d.Model) -Source 'Win32_DiskDrive' }
        return
    }
    $cp = Get-Partition -DriveLetter C
    $after = @(Get-Partition -DiskNumber $cp.DiskNumber | Where-Object { $_.Offset -gt $cp.Offset } | Sort-Object Offset)
    if ($after.Count -gt 0) {
        $desc = @($after | ForEach-Object { 'P' + $_.PartitionNumber + ':' + [math]::Round($_.Size/1MB) + 'MB:' + $_.Type })
        Add-Result 'STORAGE' 'PartitionAfterC' 'WARNING' 'Yes' $desc -Recommendation 'A partition after C: (often WinRE) blocks simple extension of C:. Plan the layout change before the window if C: needs to grow.' -Source 'Get-Partition'
    } else {
        Add-Result 'STORAGE' 'PartitionAfterC' 'OK' 'No' -Source 'Get-Partition'
    }
    try {
        $sup = Get-PartitionSupportedSize -DriveLetter C -ErrorAction Stop
        Add-Result 'STORAGE' 'CExtendableNowGB' 'INFO' (Format-Number (($sup.SizeMax - $cp.Size)/1GB)) 'Currently available contiguous space only.' -Source 'Get-PartitionSupportedSize'
    } catch { Write-Swallowed $_ }

    $total = 0
    $recoveryGuid = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
    foreach ($d in @(Get-Disk | Sort-Object Number)) {
        $total += [double]$d.Size
        $parts = @()
        foreach ($p in @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Sort-Object Offset)) {
            $vol = $null
            try { $vol = $p | Get-Volume -ErrorAction Stop } catch { Write-Swallowed $_ }
            $t = 'P' + $p.PartitionNumber + ':' + $p.Type + ':' + [math]::Round($p.Size/1MB) + 'MB'
            if ($p.DriveLetter) { $t += ':' + $p.DriveLetter + ':' }
            $paths = @($p.AccessPaths | Where-Object { $_ -and $_ -notmatch '^\\\\\?\\Volume' -and $_ -notmatch '^[A-Z]:\\$' })
            if ($paths.Count -gt 0) { $t += ':MountedAt=' + ($paths -join ',') }
            if ($vol -and $vol.FileSystemLabel) { $t += ':Label=' + $vol.FileSystemLabel }
            if ($vol -and $vol.FileSystem) { $t += ':' + $vol.FileSystem }
            $parts += $t

            # System partition (EFI or System Reserved) and WinRE recovery
            # partition free space - Setup writes boot files and WinRE to them.
            $isRecovery = ([string]$p.GptType -eq $recoveryGuid) -or ([string]$p.Type -eq 'Recovery') -or ([int]$p.MbrType -eq 39)
            if (($p.IsSystem -or $isRecovery) -and $vol -and $vol.Size -gt 0) {
                $freeMB = [math]::Round($vol.SizeRemaining/1MB)
                $kindName = 'SystemPartition'; $limit = $SystemPartitionMinFreeMB
                $rec = 'Free space on the system (EFI/System Reserved) partition is below the project threshold of ' + $SystemPartitionMinFreeMB + ' MB. Setup writes boot files here; a full system partition is a known cause of upgrade failure. Free space or enlarge it before IPU.'
                if ($isRecovery) { $kindName = 'RecoveryPartition'; $limit = $RecoveryPartitionMinFreeMB; $rec = 'Less than ' + $RecoveryPartitionMinFreeMB + ' MB free on the WinRE recovery partition, the space Microsoft asks for when servicing WinRE. Not an IPU blocker by itself, but WinRE updates may fail.' }
                $value = 'Disk' + $d.Number + ' P' + $p.PartitionNumber + ': ' + [math]::Round($vol.Size/1MB) + ' MB, free ' + $freeMB + ' MB'
                if ($freeMB -lt $limit) {
                    if ($isRecovery) { Add-Result 'STORAGE' $kindName 'WARNING' $value '' -Recommendation $rec -Kind 'Observation' -Source 'Get-Partition, Get-Volume' }
                    else { Add-Result 'STORAGE' $kindName 'WARNING' $value '' -Recommendation $rec -Source 'Get-Partition, Get-Volume' }
                } else {
                    Add-Result 'STORAGE' $kindName 'OK' $value -Source 'Get-Partition, Get-Volume'
                }
            }
        }
        Add-Result 'STORAGE' ('Disk' + $d.Number) 'INFO' ('SizeGB=' + (Format-Number ($d.Size/1GB))) @(('BusType=' + $d.BusType),('Style=' + $d.PartitionStyle),('Offline=' + $d.IsOffline),($parts -join ' | ')) -Source 'Get-Disk, Get-Partition, Get-Volume'
    }
    Add-Result 'STORAGE' 'AllocatedDiskCapacity' 'INFO' ('TotalGB=' + (Format-Number ($total/1GB))) 'Rough indication of VM snapshot exposure; growth depends on changed blocks.' -Source 'Get-Disk'
}

# ---------------------------------------------------------------------------
Register-Check -Id 'network' -Name 'Network, teaming, hosts and routes' -Script {
    foreach ($n in @(Get-CimRequired 'Win32_NetworkAdapterConfiguration' 'IPEnabled=True')) {
        $a = @(Get-CimSafe 'Win32_NetworkAdapter' ('Index=' + $n.Index)) | Select-Object -First 1
        $ipv4 = @($n.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
        $name = [string]$a.NetConnectionID; if (-not $name) { $name = [string]$n.Description }
        $script:Data.Snapshot.IPv4 += $ipv4
        $script:Data.Snapshot.Dns += @($n.DNSServerSearchOrder | Where-Object { $_ })
        Add-Result 'NETWORK' $name 'INFO' ('IPv4=' + ($ipv4 -join ',') + ' / ' + (@($n.IPSubnet) -join ',')) @(('Gateway=' + (@($n.DefaultIPGateway) -join ',')),('DNS=' + (@($n.DNSServerSearchOrder) -join ',')),('DHCP=' + $n.DHCPEnabled),('MAC=' + $n.MACAddress)) -Source 'Win32_NetworkAdapterConfiguration'
    }

    # NIC teaming. Microsoft: disable LBFO teaming before IPU and re-enable
    # after. An LBFO team bound to a Hyper-V vSwitch is not supported on
    # Windows Server 2022/2025 Hyper-V - convert to Switch Embedded Teaming.
    $vSwitchDescriptions = @()
    if (Test-CommandAvailable 'Get-VMSwitch') {
        try { $vSwitchDescriptions = @(Get-VMSwitch -ErrorAction Stop | Where-Object { $_.NetAdapterInterfaceDescription } | ForEach-Object { [string]$_.NetAdapterInterfaceDescription }) } catch { Write-Swallowed $_ }
        try {
            foreach ($set in @(Get-VMSwitchTeam -ErrorAction Stop)) {
                Add-Result 'NETWORK' ('SET: ' + $set.Name) 'INFO' 'Switch Embedded Teaming' ('Members=' + (@($set.NetAdapterInterfaceDescription) -join ', ')) -Source 'Get-VMSwitchTeam'
            }
        } catch { Write-Swallowed $_ }
    }
    $teams = @()
    if (Test-CommandAvailable 'Get-NetLbfoTeam') { $teams = @(Get-NetLbfoTeam -ErrorAction SilentlyContinue) }
    foreach ($t in $teams) {
        $teamNic = Get-NetAdapter -Name $t.Name -ErrorAction SilentlyContinue
        $boundToVSwitch = ($teamNic -and $vSwitchDescriptions -contains [string]$teamNic.InterfaceDescription)
        $details = @(('Mode=' + $t.TeamingMode),('LoadBalancing=' + $t.LoadBalancingAlgorithm),('Members=' + (@($t.Members) -join ',')))
        if ($boundToVSwitch) {
            Add-Result 'NETWORK' ('LBFO team: ' + $t.Name) 'ACTION' 'LBFO team bound to a Hyper-V virtual switch' $details -Recommendation 'LBFO under a Hyper-V vSwitch is not supported on Windows Server 2022/2025. Convert to Switch Embedded Teaming (SET) as a separate, planned change before IPU.' -Source 'Get-NetLbfoTeam, Get-VMSwitch' -Command (Get-RecommendationCommand 'LbfoTeams').Command -CommandKind 'Check'
        } else {
            Add-Result 'NETWORK' ('LBFO team: ' + $t.Name) 'ACTION' ('Status=' + $t.Status) $details -Recommendation 'Microsoft requires NIC Teaming to be disabled before IPU and re-enabled afterwards. Plan console access - the team carries the server''s IP configuration.' -Source 'Get-NetLbfoTeam' -Command (Get-RecommendationCommand 'LbfoTeams').Command -CommandKind 'Check'
        }
    }
    if ($teams.Count -eq 0) { Add-Result 'NETWORK' 'NICTeaming' 'OK' 'No LBFO team detected' -Source 'Get-NetLbfoTeam' }

    # Hosts file - active (non-comment) entries.
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $entries = 0; $lineNo = 0
    $hostsLines = @()
    if (Test-Path -LiteralPath $hostsPath) { $hostsLines = @(Get-Content -LiteralPath $hostsPath) }
    foreach ($line in $hostsLines) {
        $lineNo++
        $active = (([string]$line -split '#',2)[0]).Trim()
        if (-not $active) { continue }
        $entries++
        $script:Data.Snapshot.Hosts += ($active -replace '\s+',' ')
        $tokens = @($active -split '\s+')
        Add-Result 'NETWORK_DEPENDENCY' ('Hosts line ' + $lineNo) 'INFO' ('Address=' + $tokens[0]) ('Names=' + (@($tokens | Select-Object -Skip 1) -join ',')) -Source $hostsPath
    }
    if ($entries -gt 0) {
        Add-Result 'NETWORK_DEPENDENCY' 'HostsFile' 'MANUAL' ('ActiveEntries=' + $entries) $hostsPath -Recommendation 'Confirm owner and purpose of each hosts entry and test the affected name resolution after IPU.' -Source 'hosts file'
    } else {
        Add-Result 'NETWORK_DEPENDENCY' 'HostsFile' 'OK' 'No active entries' -Source $hostsPath
    }

    # Static routes - persistent and active manual (NetMgmt), excluding defaults.
    if (-not (Test-CommandAvailable 'Get-NetRoute')) {
        Add-Result 'NETWORK_DEPENDENCY' 'StaticRoutes' 'MANUAL' 'Get-NetRoute unavailable' -Recommendation 'Run "route print" and document persistent routes manually.' -Source 'NetTCPIP'
        return
    }
    $seen = @{}; $routes = @()
    foreach ($r in @(Get-NetRoute -PolicyStore PersistentStore -ErrorAction SilentlyContinue)) {
        if ($r.DestinationPrefix -in @('0.0.0.0/0','::/0')) { continue }
        $k = [string]$r.DestinationPrefix + '|' + $r.NextHop + '|' + $r.InterfaceIndex
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $routes += [pscustomobject]@{ R=$r; Source='Persistent' } }
    }
    foreach ($r in @(Get-NetRoute -ErrorAction SilentlyContinue | Where-Object { [string]$_.Protocol -eq 'NetMgmt' })) {
        if ($r.DestinationPrefix -in @('0.0.0.0/0','::/0')) { continue }
        $k = [string]$r.DestinationPrefix + '|' + $r.NextHop + '|' + $r.InterfaceIndex
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $routes += [pscustomobject]@{ R=$r; Source='ActiveOnly' } }
    }
    foreach ($x in $routes) {
        $script:Data.Snapshot.Routes += ([string]$x.R.DestinationPrefix + ' via ' + $x.R.NextHop)
        Add-Result 'NETWORK_DEPENDENCY' ('Route ' + $x.R.DestinationPrefix) 'INFO' ('NextHop=' + $x.R.NextHop) @(('Interface=' + $x.R.InterfaceAlias),('Metric=' + $x.R.RouteMetric),('Source=' + $x.Source)) -Source 'Get-NetRoute'
    }
    if ($routes.Count -gt 0) {
        $activeOnly = @($routes | Where-Object { $_.Source -eq 'ActiveOnly' }).Count
        Add-Result 'NETWORK_DEPENDENCY' 'StaticRoutes' 'MANUAL' ('Routes=' + $routes.Count) ('ActiveOnly(non-persistent)=' + $activeOnly) -Recommendation 'Confirm each static route is still needed and test it after IPU. Active-only routes are lost at reboot; persistent routes break if the interface index changes (teaming/driver changes).' -Source 'Get-NetRoute'
    } else {
        Add-Result 'NETWORK_DEPENDENCY' 'StaticRoutes' 'OK' 'No non-default persistent or manual routes' -Source 'Get-NetRoute'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'exchange' -Name 'Exchange Server' -Script {
    $exchangeServices = @($script:Data.Services | Where-Object { $_.Name -match '^MSExchange(IS|Transport|FrontEndTransport|ServiceHost|ADTopology|EdgeSync|MailboxAssistants|RPC)$' })
    $setupKeys = @()
    foreach ($v in @('v15','v14','v8.0')) {
        $k = 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\' + $v + '\Setup'
        $p = Get-RegistryValueSafe $k 'MsiInstallPath'
        if ($p.Exists) { $setupKeys += ($v + ': ' + $p.Value) }
    }
    if ($exchangeServices.Count -gt 0) {
        Add-Result 'EXCHANGE' 'ExchangeServerRole' 'BLOCKER' ('Exchange services: ' + (@($exchangeServices | ForEach-Object { $_.Name }) -join ', ')) $setupKeys -Recommendation 'Microsoft does not support an in-place OS upgrade on a server with Exchange installed. Build a new Exchange server on the target OS and migrate.' -Source 'Win32_Service, ExchangeServer\Setup'
    } elseif ($setupKeys.Count -gt 0) {
        Add-Result 'EXCHANGE' 'ExchangeComponents' 'ACTION' 'Exchange setup registration found without Exchange server services' $setupKeys -Recommendation 'Probably Exchange Management Tools only. Confirm with the messaging team; if a server role is installed, IPU is not supported.' -Source 'ExchangeServer\Setup'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'sql' -Name 'SQL Server' -Script {
    $instances = @()
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server','HKLM:\SOFTWARE\Wow6432Node\Microsoft\Microsoft SQL Server')) {
        foreach ($type in @('SQL','RS','OLAP')) {
            $names = Get-ItemProperty (Join-Path $root ('Instance Names\' + $type)) -ErrorAction SilentlyContinue
            if (-not $names) { continue }
            foreach ($prop in @($names.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })) {
                $setup = Get-ItemProperty (Join-Path $root ([string]$prop.Value + '\Setup')) -ErrorAction SilentlyContinue
                $version = [string]$setup.Version
                if (-not $version) { $version = [string]$setup.PatchLevel }
                $instances += [pscustomobject]@{ Instance=$prop.Name; Type=$type; Id=[string]$prop.Value; Version=$version; Edition=[string]$setup.Edition; Root=$root }
            }
        }
    }
    $instances = @($instances | Sort-Object Type,Instance,Id -Unique)
    $script:Data.SqlSummary = ''
    if ($instances.Count -eq 0) { return }
    $summary = @()
    foreach ($i in $instances) {
        $major = 0
        [void][int]::TryParse((($i.Version -split '\.')[0]), [ref]$major)
        $typeName = @{ SQL='Database Engine'; RS='Reporting Services'; OLAP='Analysis Services' }[$i.Type]
        if ($major -le 0) {
            Add-Result 'SQL' ($typeName + ': ' + $i.Instance) 'MANUAL' 'Version not found' ('InstanceId=' + $i.Id) -Recommendation 'Determine the SQL Server version and check it against the target OS support matrix.' -Source ($i.Root + '\Instance Names')
            continue
        }
        $d = Get-SqlSupportDecision $major $TargetServerVersion
        $summary += ($i.Instance + '=' + $d.Release)
        Add-Result 'SQL' ($typeName + ': ' + $i.Instance) $d.Status $d.Release @(('Version=' + $i.Version),('Edition=' + $i.Edition),('InstanceId=' + $i.Id)) -Recommendation $d.Text -Source 'SQL Server instance registry; Microsoft SQL Server / Windows compatibility matrix'
    }
    $script:Data.SqlSummary = ($summary -join ', ')
}

# ---------------------------------------------------------------------------
Register-Check -Id 'workloads' -Name 'Roles and workloads' -Script {
    if ($null -eq $script:Data.Features) {
        Add-Result 'ROLES' 'Inventory' 'MANUAL' 'Get-WindowsFeature unavailable' -Recommendation 'List installed roles/features manually.' -Kind 'Observation' -Source 'ServerManager'
    } else {
        foreach ($name in @($script:Data.Features.Keys | Where-Object { $script:Data.Features[$_] } | Sort-Object)) {
            Add-Result 'ROLES' $name 'INFO' 'Installed' -Source 'Get-WindowsFeature'
        }
    }
    $roleChecks = @(
        @{ Name='DNS';        Label='DNS Server';  Rec='Confirm DNS zones are AD-integrated or replicated, and that clients can use another DNS server during the window.' },
        @{ Name='DHCP';       Label='DHCP Server'; Rec='Back up DHCP (Export-DhcpServer) and confirm failover/partner coverage for the change window.' },
        @{ Name='Print-Server'; Label='Print Server'; Rec='Export printers (PrintBrm) and confirm that drivers exist for the target OS.' },
        @{ Name='Hyper-V';    Label='Hyper-V host'; Rec='All guests are affected. Plan guest shutdown/migration and confirm vSwitch teaming is SET, not LBFO.' },
        @{ Name='FS-DFS-Replication'; Label='DFS Replication'; Rec='Confirm DFSR health and backlog before IPU; plan to monitor replication afterwards.' },
        @{ Name='WDS';        Label='Windows Deployment Services'; Rec='Validate WDS/PXE dependencies with the deployment team.' },
        @{ Name='UpdateServices'; Label='WSUS'; Rec='Back up the WSUS database/content and confirm the upgrade method with the patch team.' },
        @{ Name='ADFS-Federation'; Label='AD FS'; Rec='AD FS farms are normally upgraded by adding new servers to the farm. Engage the identity team.' },
        @{ Name='NPAS';       Label='Network Policy Server'; Rec='Export the NPS configuration before IPU.' },
        @{ Name='FS-FileServer'; Label='File Server'; Rec='Document shares and permissions; confirm users are informed of the outage.' }
    )
    foreach ($rc in $roleChecks) {
        if ((Get-FeatureState $rc.Name) -eq $true) { Add-Result 'WORKLOAD' $rc.Label 'WARNING' 'Installed' -Recommendation $rc.Rec -Source 'Get-WindowsFeature' }
    }

    # Application workloads (pattern table in section 2), matched on names
    # and service names only - not executable paths - to avoid false positives.
    foreach ($m in (Find-DetectionMatch $script:DetectionPatterns.Workloads $script:Data.Apps $script:Data.Services)) {
        Add-Result 'WORKLOAD' $m.Label 'WARNING' ('Applications=' + @($m.Apps).Count + ', Services=' + @($m.Services).Count) (Get-DetectionEvidence $m) -Recommendation ('Engage the application owner and confirm ' + $m.Label + ' supports ' + (Get-ReleaseDisplayName $TargetServerVersion) + '.') -Source 'Uninstall registry and Win32_Service names'
    }

    # Features removed or no longer developed in the target release.
    if ($null -ne $script:Data.Features) {
        $installed = @($script:Data.Features.Keys | Where-Object { $script:Data.Features[$_] })
        foreach ($f in (Get-FeatureLifecycleFinding $installed $TargetServerVersion)) {
            Add-Result 'FEATURE_LIFECYCLE' $f.Name $f.Status ('Feature ' + $f.Feature + ' is installed') '' -Recommendation $f.Text -Kind $f.Kind -Source 'Microsoft: features removed or no longer developed'
        }
    }
    $browser = @($script:Data.Services | Where-Object { $_.Name -eq 'Browser' -and $_.State -eq 'Running' })
    if ($browser.Count -gt 0) {
        Add-Result 'FEATURE_LIFECYCLE' 'Computer Browser service' 'WARNING' 'Running' '' -Recommendation 'The Computer Browser protocol is no longer developed by Microsoft. Find out what depends on network browsing (often old SMB1 clients).' -Kind 'Observation' -Source 'Win32_Service'
    }
    foreach ($a in $script:Data.Apps) {
        Add-Result 'APPLICATIONS' $a.Name 'INFO' ('Version=' + $a.Version) @(('Publisher=' + $a.Publisher),('InstallDate=' + $a.InstallDate)) -Source 'Uninstall registry (no Win32_Product)'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'iis' -Name 'IIS' -Script {
    if ((Get-FeatureState 'Web-Server') -ne $true) { Add-Result 'IIS' 'Web-Server' 'OK' 'Not installed' -Source 'Get-WindowsFeature'; return }
    Add-Result 'IIS' 'Web-Server' 'WARNING' 'Installed' -Recommendation 'Immediately before the IPU, run the appcmd.exe add backup command shown (the copy in this report is from assessment time), and keep site, binding and certificate documentation.' -Source 'Get-WindowsFeature' -Command (Get-RecommendationCommand 'IisBackup').Command -CommandKind 'Change' -Link $script:DocLinks.AppCmd.Url -LinkTitle $script:DocLinks.AppCmd.Title
    if ($EnableIISConfigEvidence) {
        try {
            $dest = Join-Path $PolicyEvidenceRoot ($script:SafeComputerName + '-IPU-IIS-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
            $null = Initialize-OutputFolder $PolicyEvidenceRoot
            $copy = Save-IISConfigEvidence -Destination $dest -Zip $CreatePolicyEvidenceZip
            $script:Data.IISConfigEvidence = $copy.Location
            Add-Result 'IIS' 'ConfigurationCopy' 'OK' $copy.Location @(('Files=' + ($copy.Files -join ', ')), ('applicationHost.config SHA256=' + $copy.ApplicationHostSha256)) -Recommendation 'Restore: copy the files back to %windir%\System32\inetsrv\config, or put them in a folder under inetsrv\backup and run "appcmd restore backup <folder>". See the user guide.' -Source 'inetsrv\config (copied, not changed)'
            if ($copy.SharedConfigPath) {
                Add-Result 'IIS' 'SharedConfiguration' 'WARNING' ('Enabled: ' + $copy.SharedConfigPath) 'The local files only point to the shared location.' -Recommendation 'Back up the shared configuration at that path as well, and confirm every server that uses it before the change.' -Kind 'Observation' -Source 'redirection.config'
            }
        } catch {
            Add-Result 'IIS' 'ConfigurationCopy' 'MANUAL' 'Could not copy the IIS configuration' $_.Exception.Message -Recommendation 'Back up the IIS configuration manually before the change: appcmd add backup PreIPU, or copy %windir%\System32\inetsrv\config.' -Kind 'Finding' -Source 'inetsrv\config'
        }
    } else {
        Add-Result 'IIS' 'ConfigurationCopy' 'INFO' 'Not taken (EnableIISConfigEvidence is off)' -Source 'SETTINGS'
    }
    if (-not (Get-Module -ListAvailable WebAdministration)) { return }
    Import-Module WebAdministration
    foreach ($site in @(Get-Website)) {
        $bindings = @($site.Bindings.Collection | ForEach-Object { $_.protocol + ':' + $_.bindingInformation }) -join ' | '
        Add-Result 'IIS' ('Site: ' + $site.Name) 'INFO' ('State=' + $site.State) @(('Path=' + $site.PhysicalPath),('Bindings=' + $bindings)) -Source 'WebAdministration'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'rds' -Name 'Remote Desktop Services roles' -Script {
    $rdsh = Get-FeatureState 'RDS-RD-Server'
    $rdlic = Get-FeatureState 'RDS-Licensing'
    if ($rdsh -eq $true) { Add-Result 'RDS' 'RDSessionHost' 'ACTION' 'Installed' -Recommendation ('Plan a longer IPU window, record the licensing configuration, and confirm RDS CALs are valid for ' + (Get-ReleaseDisplayName $TargetServerVersion) + ' (CALs must be the same or newer release as the server).') -Source 'Get-WindowsFeature' }
    else { Add-Result 'RDS' 'RDSessionHost' 'OK' 'Not installed' -Source 'Get-WindowsFeature' }
    if ($rdlic -eq $true) { Add-Result 'RDS' 'RDLicensingServer' 'ACTION' 'Installed' -Recommendation 'This is an RD Licensing server. Upgrading it affects every RDS host that uses it; confirm installed CALs and the order of upgrades with the RDS owner.' -Source 'Get-WindowsFeature' }
    if ($rdsh -eq $true -or $rdlic -eq $true) {
        $ts = @(Get-CimSafe 'Win32_TerminalServiceSetting' '' 'root\cimv2\TerminalServices') | Select-Object -First 1
        if ($ts) {
            $mode = @{ 2='PerDevice'; 4='PerUser'; 5='NotConfigured' }[[int]$ts.LicensingType]
            $servers = @()
            try { $servers = @((Invoke-CimMethod -InputObject $ts -MethodName GetSpecifiedLicenseServerList -ErrorAction Stop).SpecifiedLSList) } catch { Write-Swallowed $_ }
            Add-Result 'RDS' 'LicensingConfiguration' 'INFO' ('Mode=' + $mode) ('LicenseServers=' + ($servers -join ',')) -Source 'Win32_TerminalServiceSetting'
        }
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'pki' -Name 'PKI, certificates and TLS bindings' -Script {
    $adcs = @()
    foreach ($f in @('ADCS-Cert-Authority','ADCS-Web-Enrollment','ADCS-Enroll-Web-Pol','ADCS-Enroll-Web-Svc','ADCS-Device-Enrollment','ADCS-Online-Cert')) {
        if ((Get-FeatureState $f) -eq $true) { $adcs += $f }
    }
    $certSvc = @($script:Data.Services | Where-Object { $_.Name -eq 'CertSvc' }) | Select-Object -First 1
    if ($adcs -contains 'ADCS-Cert-Authority' -or $certSvc) {
        Add-Result 'PKI' 'CertificationAuthority' 'ACTION' 'Certification Authority detected' $adcs -Recommendation 'Engage the PKI team: verify CA database and private-key backup, AIA/CDP dependencies, and a tested recovery procedure before IPU.' -Source 'Get-WindowsFeature, CertSvc'
        $active = (Get-RegistryValueSafe 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' 'Active').Value
        if ($active) {
            $ca = Get-ItemProperty ('HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\' + $active) -ErrorAction SilentlyContinue
            $type = @{ 0='EnterpriseRoot'; 1='EnterpriseSubordinate'; 3='StandaloneRoot'; 4='StandaloneSubordinate' }[[int]$ca.CAType]
            Add-Result 'PKI' ('CA: ' + $active) 'INFO' ('Type=' + $type) @(('DB=' + $ca.DBDirectory),('Log=' + $ca.DBLogDirectory)) -Source 'CertSvc configuration'
        }
    } elseif ($adcs.Count -gt 0) {
        Add-Result 'PKI' 'ADCSRoleServices' 'ACTION' ($adcs -join ', ') -Recommendation 'Engage the PKI team and confirm configuration/recovery requirements before IPU.' -Source 'Get-WindowsFeature'
    }

    # Certificate index across the stores that services bind from.
    $index = @{}
    foreach ($store in @('My','Remote Desktop','WebHosting')) {
        foreach ($cert in @(Get-ChildItem ('Cert:\LocalMachine\' + $store) -ErrorAction SilentlyContinue)) {
            $thumb = ConvertTo-NormalizedThumbprint $cert.Thumbprint
            if ($index.ContainsKey($thumb)) { continue }
            $index[$thumb] = [pscustomobject]@{ Cert=$cert; Store=$store }
            $days = [math]::Floor(($cert.NotAfter - (Get-Date)).TotalDays)
            Add-Result 'CERTIFICATES' $thumb 'INFO' ('Subject=' + $cert.Subject) @(('Store=' + $store),('Issuer=' + $cert.Issuer),('NotAfter=' + $cert.NotAfter.ToString('yyyy-MM-dd')),('HasPrivateKey=' + $cert.HasPrivateKey)) -Source ('Cert:\LocalMachine\' + $store)
            if ($days -lt 0) {
                Add-Result 'CERTIFICATES' ('Expired: ' + $thumb) 'WARNING' ('ExpiredDaysAgo=' + [math]::Abs($days)) ('Subject=' + $cert.Subject) -Recommendation 'Determine whether it is still bound; renew/remove through the owning team.' -Kind 'Observation' -Source ('Cert:\LocalMachine\' + $store)
            } elseif ($days -le $CertificateWarningDays) {
                Add-Result 'CERTIFICATES' ('Expiring: ' + $thumb) 'WARNING' ('ExpiresInDays=' + $days) ('Subject=' + $cert.Subject) -Recommendation 'Confirm ownership and renewal plan. Bound certificates are evaluated separately below.' -Kind 'Observation' -Source ('Cert:\LocalMachine\' + $store)
            }
        }
    }

    # IIS HTTPS bindings.
    if ((Get-FeatureState 'Web-Server') -eq $true -and (Get-Module -ListAvailable WebAdministration)) {
        Import-Module WebAdministration
        foreach ($b in @(Get-WebBinding -Protocol https -ErrorAction SilentlyContinue)) {
            $thumb = ConvertTo-NormalizedThumbprint $b.certificateHash
            $entry = $null
            if ($thumb -and $index.ContainsKey($thumb)) { $entry = $index[$thumb] }
            $item = 'IIS https ' + $b.bindingInformation
            if (-not $thumb) {
                Add-Result 'CERTIFICATES' $item 'MANUAL' 'No certificate hash on binding (possibly Centralized Certificate Store)' ('Store=' + $b.certificateStoreName) -Recommendation 'Verify the binding certificate manually.' -Source 'Get-WebBinding'
            } elseif (-not $entry) {
                Add-Result 'CERTIFICATES' $item 'ACTION' ('Thumbprint=' + $thumb) ('BindingStore=' + $b.certificateStoreName) -Recommendation 'The bound certificate is not in My, WebHosting or Remote Desktop. Fix the binding before IPU.' -Source 'Get-WebBinding'
            } else {
                $days = [math]::Floor(($entry.Cert.NotAfter - (Get-Date)).TotalDays)
                $details = @(('Subject=' + $entry.Cert.Subject),('Store=' + $entry.Store),('DaysLeft=' + $days))
                if ($days -lt 0) { Add-Result 'CERTIFICATES' $item 'ACTION' ('Thumbprint=' + $thumb) $details -Recommendation 'IIS binding uses an expired certificate. Resolve with the application owner before IPU.' -Source 'Get-WebBinding' }
                elseif ($days -le $CertificateWarningDays) { Add-Result 'CERTIFICATES' $item 'WARNING' ('Thumbprint=' + $thumb) $details -Recommendation 'Renew soon and verify the binding after IPU.' -Source 'Get-WebBinding' }
                else { Add-Result 'CERTIFICATES' $item 'OK' ('Thumbprint=' + $thumb) $details -Source 'Get-WebBinding' }
            }
        }
    }

    # RDP listener certificate.
    $rdp = @(Get-CimSafe 'Win32_TSGeneralSetting' "TerminalName='RDP-tcp'" 'root\cimv2\TerminalServices') | Select-Object -First 1
    if ($rdp) {
        $thumb = ConvertTo-NormalizedThumbprint $rdp.SSLCertificateSHA1Hash
        if ($thumb -and $index.ContainsKey($thumb)) {
            $c = $index[$thumb].Cert
            $st = 'OK'; if ($c.NotAfter -lt (Get-Date)) { $st = 'WARNING' }
            Add-Result 'CERTIFICATES' 'RDP-Tcp certificate' $st ('Thumbprint=' + $thumb) @(('Subject=' + $c.Subject),('NotAfter=' + $c.NotAfter.ToString('yyyy-MM-dd'))) -Recommendation 'Verify RDP connects after IPU.' -Kind 'Observation' -Source 'Win32_TSGeneralSetting'
        } elseif ($thumb) {
            Add-Result 'CERTIFICATES' 'RDP-Tcp certificate' 'MANUAL' ('Thumbprint=' + $thumb) 'Not found in My, Remote Desktop or WebHosting' -Recommendation 'Verify the RDP certificate configuration.' -Kind 'Observation' -Source 'Win32_TSGeneralSetting'
        }
    }

    # WinRM HTTPS listeners.
    foreach ($listener in @(Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue)) {
        $keys = @{}; foreach ($k in $listener.Keys) { if ($k -match '^(\w+)=(.*)$') { $keys[$matches[1]] = $matches[2] } }
        if ($keys['Transport'] -eq 'HTTPS') {
            $thumb = ''
            try { $thumb = ConvertTo-NormalizedThumbprint (Get-Item (Join-Path $listener.PSPath 'CertificateThumbprint') -ErrorAction Stop).Value } catch { Write-Swallowed $_ }
            Add-Result 'CERTIFICATES' ('WinRM HTTPS ' + $keys['Address']) 'INFO' ('Thumbprint=' + $thumb) -Recommendation 'Confirm WinRM HTTPS still works after IPU if it is used for management.' -Source 'WSMan:\localhost\Listener'
        }
    }

    # HTTP.sys SSL bindings - preserved verbatim as evidence.
    $netsh = Invoke-NativeCapture (Join-Path $env:windir 'System32\netsh.exe') @('http','show','sslcert') 60
    $block = @(); $n = 0
    foreach ($line in @($netsh.Output -split '\r?\n') + @('')) {
        if ($line.Trim()) { $block += $line.Trim() }
        elseif ($block.Count -gt 0) {
            if (Test-HttpSysBindingBlock $block) { $n++; Add-Result 'CERTIFICATES' ('HTTP.sys binding ' + $n) 'INFO' ($block -join ' | ') -Source 'netsh http show sslcert' }
            $block = @()
        }
        else { $block = @() }
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'agents' -Name 'Management agents (Aeven/OpenText)' -Script {
    $matches_ = Find-DetectionMatch $script:DetectionPatterns.Agents $script:Data.Apps $script:Data.Services
    foreach ($pattern in $script:DetectionPatterns.Agents) {
        $m = @($matches_ | Where-Object { $_.Label -eq $pattern.Label }) | Select-Object -First 1
        if (-not $m) {
            Add-Result 'AGENTS' $pattern.Label 'MANUAL' 'Not identified' '' -Recommendation 'Confirm in the backend whether this agent is expected on this server. If it is installed under another name, add the name to the detection patterns.' -Kind 'Observation' -Source 'Uninstall registry, Win32_Service'
            continue
        }
        foreach ($app in $m.Apps) { Add-Result 'AGENTS' $pattern.Label 'INFO' $app.Name ('Version=' + $app.Version) -Source 'Uninstall registry' }
        foreach ($svc in $m.Services) {
            $st = 'OK'; if ($svc.State -ne 'Running') { $st = 'WARNING' }
            Add-Result 'AGENTS' ($pattern.Label + ' service') $st $svc.DisplayName @(('State=' + $svc.State),('StartMode=' + $svc.StartMode)) -Recommendation 'A stopped agent will not report after IPU either; investigate before the change.' -Kind 'Observation' -Source 'Win32_Service'
        }
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'antivirus' -Name 'Antivirus, EDR and security tools' -Script {
    $target = Get-ReleaseDisplayName $TargetServerVersion
    $protected = $false

    # Microsoft Defender Antivirus. Record WHY its state could not be read
    # instead of silently treating it as absent.
    $defenderService = @($script:Data.Services | Where-Object { $_.Name -eq 'WinDefend' }) | Select-Object -First 1
    if (-not $defenderService) {
        Add-Result 'ANTIVIRUS' 'Microsoft Defender Antivirus' 'INFO' 'Not installed (WinDefend service absent)' -Source 'Win32_Service'
    } elseif (-not (Test-CommandAvailable 'Get-MpComputerStatus')) {
        Add-Result 'ANTIVIRUS' 'Microsoft Defender Antivirus' 'INFO' ('Service ' + $defenderService.State + '; status cmdlet not available on this OS') -Source 'Win32_Service'
    } else {
        try {
            $mp = Get-MpComputerStatus -ErrorAction Stop
            $age = $null
            if ($mp.AntivirusSignatureLastUpdated) { $age = [math]::Floor(((Get-Date) - $mp.AntivirusSignatureLastUpdated).TotalDays) }
            $mode = ''
            if ($mp.PSObject.Properties['AMRunningMode']) { $mode = ', Mode=' + $mp.AMRunningMode }
            $value = 'AVEnabled=' + $mp.AntivirusEnabled + ', RealTime=' + $mp.RealTimeProtectionEnabled + $mode
            if ($mp.AntivirusEnabled -and $mp.RealTimeProtectionEnabled) {
                $protected = $true
                if ($null -ne $age -and $age -le $AVMaxAgeDays) { Add-Result 'ANTIVIRUS' 'Microsoft Defender Antivirus' 'OK' $value ('SignatureAgeDays=' + $age) -Source 'Get-MpComputerStatus' }
                else { Add-Result 'ANTIVIRUS' 'Microsoft Defender Antivirus' 'WARNING' $value ('SignatureAgeDays=' + $age) -Recommendation 'Update Defender signatures before IPU.' -Source 'Get-MpComputerStatus' }
            } else {
                Add-Result 'ANTIVIRUS' 'Microsoft Defender Antivirus' 'INFO' $value 'Passive or disabled - expected when another product is primary.' -Source 'Get-MpComputerStatus'
            }
        } catch {
            Write-Swallowed $_
            Add-Result 'ANTIVIRUS' 'Microsoft Defender Antivirus' 'INFO' ('Service ' + $defenderService.State + ', ' + $defenderService.StartMode) ('Status not readable: ' + $_.Exception.Message) -Recommendation 'Usually means Defender is disabled because another product is primary.' -Source 'Get-MpComputerStatus'
        }
    }

    # Third-party AV/EDR by product name, service and driver.
    $epp = Find-DetectionMatch $script:DetectionPatterns.EndpointProtection $script:Data.Apps $script:Data.Services $script:Data.DriverNames
    $products = @()
    foreach ($m in $epp) {
        $running = @($m.Services | Where-Object { $_.State -eq 'Running' }).Count
        $val = 'Applications=' + @($m.Apps).Count + ', Services=' + @($m.Services).Count + ' (' + $running + ' running), Drivers=' + @($m.Drivers).Count
        if ($m.Label -like 'Microsoft Defender for Endpoint*') {
            $sense = @($m.Services | Where-Object { $_.Name -eq 'Sense' }) | Select-Object -First 1
            $senseState = 'absent'; if ($sense) { $senseState = [string]$sense.State }
            $onboarding = (Get-RegistryValueSafe 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status' 'OnboardingState').Value
            $d = Get-DefenderEndpointDecision $senseState $onboarding
            if (-not $d.Active) {
                Add-Result 'ANTIVIRUS' $m.Label 'INFO' $d.Text (Get-DetectionEvidence $m) -Source 'Win32_Service, Windows Advanced Threat Protection\Status'
                continue
            }
            $val = $d.Text
        }
        $protected = $true
        $products += (Get-DetectionProductName $m)
        Add-Result 'ANTIVIRUS' $m.Label 'WARNING' $val (Get-DetectionEvidence $m) -Recommendation ('Confirm this version supports ' + $target + ' and get the vendor''s IPU procedure. Many AV/EDR agents must be upgraded before, or paused during, Setup; their drivers are a common cause of rollback.') -Source 'Uninstall registry, Win32_Service, drivers' -Link $m.Link -LinkTitle $m.LinkTitle
    }
    $script:Data.EndpointProducts = $products
    if (-not $protected) {
        Add-Result 'ANTIVIRUS' 'EndpointProtection' 'MANUAL' 'No active antivirus or EDR recognised' '' -Recommendation 'Verify endpoint protection manually. If a product is installed under an unknown name, add it to the detection patterns.' -Source 'Get-MpComputerStatus, uninstall registry, services, drivers'
    }

    foreach ($m in (Find-DetectionMatch $script:DetectionPatterns.SecurityTools $script:Data.Apps $script:Data.Services $script:Data.DriverNames)) {
        $tool = Get-SecurityToolDecision @($m.Drivers) $target
        Add-Result 'SECURITY' $m.Label 'WARNING' ('Applications=' + @($m.Apps).Count + ', Services=' + @($m.Services).Count + ', Drivers=' + @($m.Drivers).Count) (Get-DetectionEvidence $m) -Recommendation $tool.Recommendation -Kind $tool.Kind -Source 'Uninstall registry, Win32_Service, drivers'
    }

    if (Test-CommandAvailable 'Get-AppLockerPolicy') {
        try {
            $policy = Get-AppLockerPolicy -Effective -ErrorAction Stop
            $count = 0; foreach ($c in $policy.RuleCollections) { $count += [int]$c.Count }
            if ($count -gt 0) { Add-Result 'SECURITY' 'AppLocker' 'WARNING' ('EffectiveRules=' + $count) '' -Recommendation 'Confirm Windows Setup ($WINDOWS.~BT) and post-upgrade binaries are allowed.' -Source 'Get-AppLockerPolicy' }
            else { Add-Result 'SECURITY' 'AppLocker' 'INFO' 'No effective rules' -Source 'Get-AppLockerPolicy' }
        } catch { Write-Swallowed $_ }
    }
    if (Test-CommandAvailable 'Get-BitLockerVolume') {
        try {
            $bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
            if ([string]$bl.ProtectionStatus -eq 'On') { Add-Result 'SECURITY' 'BitLocker C:' 'WARNING' ('Protection=On, Method=' + $bl.EncryptionMethod) '' -Recommendation 'Confirm the recovery key is escrowed and retrievable before IPU.' -Source 'Get-BitLockerVolume' }
            else { Add-Result 'SECURITY' 'BitLocker C:' 'INFO' ('Protection=' + $bl.ProtectionStatus) -Source 'Get-BitLockerVolume' }
        } catch { Write-Swallowed $_ }
    }
    if (Test-CommandAvailable 'Confirm-SecureBootUEFI') {
        try { Add-Result 'SECURITY' 'SecureBoot' 'INFO' ('Enabled=' + (Confirm-SecureBootUEFI -ErrorAction Stop)) -Source 'Confirm-SecureBootUEFI' }
        catch { Add-Result 'SECURITY' 'SecureBoot' 'INFO' 'Not available (legacy BIOS or not supported)' -Source 'Confirm-SecureBootUEFI' }
    }
    if (Test-CommandAvailable 'Get-Tpm') {
        try { $tpm = Get-Tpm -ErrorAction Stop; Add-Result 'SECURITY' 'TPM' 'INFO' ('Present=' + $tpm.TpmPresent) ('Ready=' + $tpm.TpmReady) -Source 'Get-Tpm' } catch { Write-Swallowed $_ }
    }
    if (@($script:Data.FilterDrivers).Count -gt 0) {
        Add-Result 'SECURITY' 'FileSystemFilterDrivers' 'INFO' ('Count=' + @($script:Data.FilterDrivers).Count) (@($script:Data.FilterDrivers) -join ', ') -Recommendation 'If a previous IPU failed with 0xC1900101 (driver), review the non-Microsoft filter drivers.' -Source 'fltmc filters'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'backup' -Name 'Backup and VSS' -Script {
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
        Add-Result 'BACKUP' 'VSSWriters' 'MANUAL' 'VSS writer state could not be read' @(('TimedOut=' + $vss.TimedOut),$vss.Error) -Recommendation 'Run "vssadmin list writers" manually; failed writers break application-consistent backups and snapshots.' -Kind 'Observation' -Source 'vssadmin list writers'
    }
    $failed = 0
    foreach ($w in $writers) {
        $st = Get-VssWriterStatus $w
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

# ---------------------------------------------------------------------------
Register-Check -Id 'services' -Name 'Services' -Script {
    $auto = @($script:Data.Services | Where-Object { $_.StartMode -eq 'Auto' })
    $autoStopped = @($auto | Where-Object { $_.State -ne 'Running' })
    Add-Result 'SERVICES' 'AutomaticServices' 'INFO' ('Total=' + $auto.Count) ('NotRunning=' + $autoStopped.Count) -Recommendation 'Save this list. After IPU, compare which Automatic services are running to spot what did not come back.' -Source 'Win32_Service'
    foreach ($s in @($script:Data.Services | Where-Object { $_.StartMode -in @('Auto','Manual') } | Sort-Object StartMode,DisplayName)) {
        Add-Result 'SERVICES' $s.Name 'INFO' $s.DisplayName @(('State=' + $s.State),('StartMode=' + $s.StartMode),('LogOnAs=' + $s.StartName)) -Source 'Win32_Service'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'vmware' -Name 'VMware guest readiness' -Script {
    if ($script:Data.Platform.Hypervisor -ne 'VMware') {
        Add-Result 'VMWARE' 'Applicability' 'INFO' ('Not a VMware VM (' + $script:Data.Platform.Type + ')') -Source 'Platform classification'
        return
    }
    $tools = @($script:Data.Apps | Where-Object { $_.Name -eq 'VMware Tools' }) | Select-Object -First 1
    $version = ''
    if ($tools) { $version = [string]$tools.Version }
    else {
        $exe = Join-Path $env:ProgramFiles 'VMware\VMware Tools\vmtoolsd.exe'
        if (Test-Path -LiteralPath $exe) { $version = [string](Get-Item -LiteralPath $exe).VersionInfo.ProductVersion }
    }
    $decision = Get-VMwareToolsDecision $version $TargetServerVersion
    $toolsSvc = @($script:Data.Services | Where-Object { $_.Name -eq 'VMTools' }) | Select-Object -First 1
    $svcText = 'VMTools service not found'
    if ($toolsSvc) { $svcText = 'VMTools service ' + $toolsSvc.State + ', ' + $toolsSvc.StartMode }
    Add-Result 'VMWARE' 'VMwareTools' $decision.Status ('Version=' + $version) $svcText -Recommendation $decision.Text -Source 'Uninstall registry / vmtoolsd.exe'

    $firmware = 'BIOS'
    if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State') { $firmware = 'EFI' }
    Add-Result 'VMWARE' 'VMFirmware' 'INFO' $firmware ('BIOS version=' + $script:Data.BIOS.SMBIOSBIOSVersion) -Recommendation 'BIOS-firmware VMs upgrade in place; Secure Boot and vTPM need EFI firmware.' -Source 'SecureBoot registry, Win32_BIOS'

    foreach ($drv in @($script:Data.KernelDrivers | Where-Object { $_.Name -match '^(pvscsi|vmxnet3|vmxnet3ndis6|vsepflt|vnetflt|vnetWFP|vmci|vsock|vm3dmp|vmmemctl|vmhgfs|vmrawdsk|vmusbmouse|vmmouse|glxgi)' } | Sort-Object Name)) {
        $fileVersion = ''
        $path = ([string]$drv.PathName -replace '^\\\?\?\\','' -replace '^\\SystemRoot', $env:windir -replace '^(?i)system32', (Join-Path $env:windir 'System32'))
        try { if ($path -and (Test-Path -LiteralPath $path)) { $fileVersion = (Get-Item -LiteralPath $path).VersionInfo.FileVersion } } catch { Write-Swallowed $_ }
        Add-Result 'VMWARE' ('Driver: ' + $drv.Name) 'INFO' $drv.DisplayName ('FileVersion=' + $fileVersion) -Source 'Win32_SystemDriver'
    }

    $hostText = 'Confirm the ESXi host version supports ' + (Get-ReleaseDisplayName $TargetServerVersion) + ' guests (VMware Compatibility Guide).'
    if ($TargetServerVersion -eq '2025') { $hostText = 'Windows Server 2025 is certified on vSphere 7.0 U3 and 8.0.x. Confirm the host (and any vMotion/DRS target) runs one of these.' }
    Add-Result 'CHECKLIST' 'VMware host version' 'MANUAL' 'Not visible from inside the guest' '' -Recommendation $hostText -Kind 'Checklist'
    Add-Result 'CHECKLIST' 'VMware guest OS setting' 'MANUAL' 'After the upgrade' '' -Recommendation ('After IPU, power off the VM and change its Guest OS version to Microsoft Windows Server ' + $TargetServerVersion + ' (64-bit), as Broadcom''s IPU KB 374927 instructs.') -Kind 'Checklist'
    Add-Result 'VMWARE' 'BroadcomGuidance' 'INFO' 'Broadcom KB 374927' 'Broadcom recommends a new VM with a clean install over an in-place upgrade of the guest OS.' -Recommendation 'Company decision; listed so the choice to do an IPU is made knowingly.' -Kind 'Observation' -Source 'knowledge.broadcom.com/external/article/374927'
}

# ---------------------------------------------------------------------------
Register-Check -Id 'drivers' -Name 'Non-Microsoft drivers' -Script {
    $unsigned = @()
    $pnp = @(Get-CimSafe 'Win32_PnPSignedDriver' | Where-Object { $_.DeviceName -and $_.DriverProviderName -and $_.DriverProviderName -notmatch '^Microsoft' })
    foreach ($d in @($pnp | Sort-Object DeviceName,DriverVersion -Unique)) {
        $date = [string]$d.DriverDate
        $driverDate = ConvertTo-DateTimeValue $d.DriverDate
        if ($driverDate) { $date = $driverDate.ToString('yyyy-MM-dd') }
        Add-Result 'DRIVERS' ('Device: ' + $d.DeviceName) 'INFO' ('Provider=' + $d.DriverProviderName) @(('Version=' + $d.DriverVersion),('Date=' + $date),('Class=' + $d.DeviceClass),('Signed=' + $d.IsSigned)) -Source 'Win32_PnPSignedDriver'
        if ($d.IsSigned -eq $false) { $unsigned += $d.DeviceName }
    }
    $kernelCount = 0
    foreach ($drv in @($script:Data.KernelDrivers | Sort-Object Name)) {
        $path = ([string]$drv.PathName -replace '^\\\?\?\\','' -replace '^\\SystemRoot', $env:windir -replace '^(?i)system32', (Join-Path $env:windir 'System32'))
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }
        $info = $null
        try { $info = (Get-Item -LiteralPath $path).VersionInfo } catch { Write-Swallowed $_; continue }
        if ($info.CompanyName -and $info.CompanyName -notmatch 'Microsoft') {
            $kernelCount++
            Add-Result 'DRIVERS' ('Kernel driver: ' + $drv.Name) 'INFO' ('Company=' + $info.CompanyName) @(('FileVersion=' + $info.FileVersion),('Path=' + $path)) -Source 'Win32_SystemDriver'
        }
    }
    Add-Result 'DRIVERS' 'Summary' 'INFO' ('NonMicrosoftDevices=' + @($pnp | Sort-Object DeviceName -Unique).Count + ', NonMicrosoftKernelDrivers=' + $kernelCount) -Recommendation 'Old third-party drivers are the most common cause of IPU rollback (0xC1900101). Update them, especially storage, network and security drivers, before IPU.' -Source 'Win32_PnPSignedDriver, Win32_SystemDriver'
    if ($unsigned.Count -gt 0) {
        Add-Result 'DRIVERS' 'UnsignedDrivers' 'WARNING' ('Count=' + $unsigned.Count) ($unsigned -join ', ') -Recommendation 'Unsigned drivers may not load after the upgrade. Replace them with signed versions before IPU.' -Source 'Win32_PnPSignedDriver'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'ports' -Name 'Listening ports' -Script {
    if (-not (Test-CommandAvailable 'Get-NetTCPConnection')) {
        Add-Result 'PORTS' 'ListeningPorts' 'INFO' 'Get-NetTCPConnection unavailable' -Source 'NetTCPIP'
        return
    }
    $procNames = @{}
    foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue)) { $procNames[[int]$proc.Id] = $proc.ProcessName }
    $svcByPid = @{}
    foreach ($svc in $script:Data.Services) {
        if ($svc.ProcessId -and [int]$svc.ProcessId -gt 0) {
            $key = [int]$svc.ProcessId
            if (-not $svcByPid.ContainsKey($key)) { $svcByPid[$key] = @() }
            $svcByPid[$key] += [string]$svc.Name
        }
    }
    $owners = @{}
    $endpoints = @()
    foreach ($c in @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)) { $endpoints += [pscustomobject]@{ Key=('TCP:' + $c.LocalPort); Port=[int]$c.LocalPort; ProcessId=[int]$c.OwningProcess } }
    if (Test-CommandAvailable 'Get-NetUDPEndpoint') {
        foreach ($u in @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue)) { $endpoints += [pscustomobject]@{ Key=('UDP:' + $u.LocalPort); Port=[int]$u.LocalPort; ProcessId=[int]$u.OwningProcess } }
    }
    # Ports from the Windows dynamic range (49152+) change between boots and
    # are left out so the before/after comparison stays meaningful.
    foreach ($ep in @($endpoints | Where-Object { $_.Port -lt 49152 })) {
        $owner = ''
        if ($svcByPid.ContainsKey($ep.ProcessId)) { $owner = 'Service ' + (@($svcByPid[$ep.ProcessId]) -join '/') }
        elseif ($procNames.ContainsKey($ep.ProcessId)) { $owner = 'Process ' + $procNames[$ep.ProcessId] }
        if (-not $owners.ContainsKey($ep.Key)) { $owners[$ep.Key] = @() }
        if ($owner -and $owners[$ep.Key] -notcontains $owner) { $owners[$ep.Key] += $owner }
    }
    foreach ($k in @($owners.Keys | Sort-Object { [int](($_ -split ':')[1]) }, { $_ })) {
        Add-Result 'PORTS' $k 'INFO' (@($owners[$k]) -join ', ') -Source 'Get-NetTCPConnection, Get-NetUDPEndpoint'
    }
    $script:Data.Snapshot.Ports = @($owners.Keys | Sort-Object)
    Add-Result 'PORTS' 'Summary' 'INFO' ('ListeningPorts=' + $owners.Count) 'Use this list for the post-upgrade test plan. Dynamic ports (49152+) are not listed.' -Source 'Get-NetTCPConnection, Get-NetUDPEndpoint'
}

# ---------------------------------------------------------------------------
Register-Check -Id 'tasks' -Name 'Scheduled tasks' -Script {
    if (-not (Test-CommandAvailable 'Get-ScheduledTask')) {
        Add-Result 'TASKS' 'ScheduledTasks' 'INFO' 'Get-ScheduledTask unavailable' -Source 'ScheduledTasks module'
        return
    }
    $builtIn = '^(SYSTEM|NT AUTHORITY\\.*|LOCAL SERVICE|NETWORK SERVICE|S-1-5-(18|19|20)|INTERACTIVE|Users|Administrators|BUILTIN\\.*|Everyone)$'
    $named = @()
    foreach ($t in @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } | Sort-Object TaskPath,TaskName)) {
        $user = [string]$t.Principal.UserId
        if (-not $user) { $user = [string]$t.Principal.GroupId }
        $actions = @($t.Actions | ForEach-Object { (([string]$_.Execute) + ' ' + ([string]$_.Arguments)).Trim() } | Where-Object { $_ }) -join '; '
        $fullName = $t.TaskPath + $t.TaskName
        $script:Data.Snapshot.Tasks += $fullName
        Add-Result 'TASKS' $fullName 'INFO' ('RunAs=' + $user) @(('State=' + $t.State),('Action=' + $actions)) -Source 'Get-ScheduledTask'
        if ($user -and $user -notmatch $builtIn) { $named += ($fullName + ' (' + $user + ')') }
    }
    if ($named.Count -gt 0) {
        Add-Result 'TASKS' 'TasksWithNamedAccounts' 'WARNING' ('Count=' + $named.Count) $named -Recommendation 'These tasks run as named accounts with stored credentials. Confirm the passwords are known/managed and test the tasks after IPU.' -Kind 'Observation' -Source 'Get-ScheduledTask'
    }
}

# ---------------------------------------------------------------------------
Register-Check -Id 'checklist' -Name 'Standard change checklist' -Script {
    $isVM = ($script:Data.Platform.Type -eq 'Virtual')
    $fallback = 'Confirm a tested bare-metal recovery path and a recent successful backup.'
    if ($isVM) { $fallback = 'Confirm a recent successful backup externally, snapshot eligibility (' + $script:Data.Platform.Hypervisor + ') and the approved snapshot procedure.' }
    Add-Result 'CHECKLIST' 'Backup and fallback' 'MANUAL' 'Cannot be proven from inside the guest' -Recommendation $fallback -Kind 'Checklist'
    Add-Result 'CHECKLIST' 'Credentials and console access' 'MANUAL' 'Not provable by an unattended inventory' -Recommendation 'Validate domain logon, PAM checkout and local fallback credentials, plus console (vCenter/iLO/iDRAC) access in case network logon fails.' -Kind 'Checklist'
    Add-Result 'CHECKLIST' 'Target licensing' 'MANUAL' ('KMS: ' + $script:Data.KmsEndpoint) -Recommendation ('Confirm licence entitlement for ' + (Get-ReleaseDisplayName $TargetServerVersion) + ' and that the KMS host/ADBA or MAK can activate it.') -Kind 'Checklist'
    $media = $script:Data.RecommendedMedia; if (-not $media) { $media = 'See Upgrade path section' }
    Add-Result 'CHECKLIST' 'Installation media' 'MANUAL' $media -Recommendation 'Use media with the exact edition, installation type and language listed. Optional pre-flight: setup.exe /auto upgrade /compat scanonly with the same media.' -Kind 'Checklist'
    Add-Result 'CHECKLIST' 'Application owner sign-off' 'MANUAL' 'Required for every listed workload' -Recommendation 'Get sign-off from each workload owner, including a post-upgrade test plan.' -Kind 'Checklist'
    Add-Result 'CHECKLIST' 'Monitoring and management agents' 'MANUAL' 'Backend communication cannot be proven locally' -Recommendation 'Confirm SA, UD and Operations agents are reporting in the backend before the change; verify again afterwards.' -Kind 'Checklist'
}

# ---------------------------------------------------------------------------
# SLOW CHECKS (time-boxed, run after the checkpoint report is written)
# ---------------------------------------------------------------------------
Register-Check -Id 'dism' -Name 'DISM component store scan' -Phase 'Slow' -Script {
    if (-not $RunDISMScanHealth) {
        Add-Result 'WINDOWS_HEALTH' 'DISM ScanHealth' 'MANUAL' 'Skipped by configuration' -Recommendation 'Run the read-only scan before final IPU approval.'
        $script:CurrentCheckMessage = 'Not configured: switched off with -RunDISMScanHealth $false'
        $script:CurrentCheckOutcome = 'Skipped'; return
    }
    $timeout = [math]::Min($DISMTimeoutMinutes * 60, $script:SlowSecondsLeft)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-NativeCapture (Join-Path $env:windir 'System32\dism.exe') @('/English','/Online','/Cleanup-Image','/ScanHealth') $timeout
    $sw.Stop()
    $duration = 'Duration=' + (Format-Duration $sw.Elapsed)
    if ($r.TimedOut) {
        Add-Result 'WINDOWS_HEALTH' 'DISM ScanHealth' 'MANUAL' ('Stopped after ' + [math]::Round($timeout/60) + ' minutes') $duration -Recommendation 'Run "DISM /Online /Cleanup-Image /ScanHealth" manually outside the SA job.' -Source 'dism.exe'
        $script:CurrentCheckOutcome = 'TimedOut'; return
    }
    if ($r.Error) { throw $r.Error }
    $verdict = Get-DismVerdict $r.Output $r.ExitCode
    $summary = @($r.Lines | Where-Object { $_ -notmatch '^\[=*' -and $_ -notmatch '%' } | Select-Object -Last 3) -join ' | '
    $rec = @{ OK=''; ACTION='Repair the component store (DISM /RestoreHealth with matching source) and re-run before IPU - Setup fails on a corrupt component store.'; MANUAL='Result unclear; review the output and %windir%\Logs\DISM\dism.log.' }[$verdict]
    Add-Result 'WINDOWS_HEALTH' 'DISM ScanHealth' $verdict ('ExitCode=' + $r.ExitCode) @($duration,$summary) -Recommendation $rec -Source 'dism.exe /English /Online /Cleanup-Image /ScanHealth'
}

Register-Check -Id 'sfc' -Name 'SFC protected file verification' -Phase 'Slow' -Script {
    if (-not $RunSFCVerifyOnly) {
        Add-Result 'WINDOWS_HEALTH' 'SFC VerifyOnly' 'MANUAL' 'Skipped by configuration' -Recommendation 'Run the read-only verification before final IPU approval.'
        $script:CurrentCheckMessage = 'Not configured: switched off with -RunSFCVerifyOnly $false'
        $script:CurrentCheckOutcome = 'Skipped'; return
    }
    $timeout = [math]::Min($SFCTimeoutMinutes * 60, $script:SlowSecondsLeft)
    $started = Get-Date
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-NativeCapture (Join-Path $env:windir 'System32\sfc.exe') @('/verifyonly') $timeout
    $sw.Stop()
    $duration = 'Duration=' + (Format-Duration $sw.Elapsed)
    if ($r.TimedOut) {
        Add-Result 'WINDOWS_HEALTH' 'SFC VerifyOnly' 'MANUAL' ('Stopped after ' + [math]::Round($timeout/60) + ' minutes') $duration -Recommendation 'Run "sfc /verifyonly" manually outside the SA job.' -Source 'sfc.exe'
        $script:CurrentCheckOutcome = 'TimedOut'; return
    }
    if ($r.Error) { throw $r.Error }
    $cbs = @()
    $stamp = $started.AddMinutes(-1).ToString('yyyy-MM-dd HH:mm')
    foreach ($line in (Read-FileTail (Join-Path $env:windir 'Logs\CBS\CBS.log'))) {
        if ($line.Length -ge 16 -and $line.Substring(0,16) -ge $stamp) { $cbs += $line }
    }
    $verdict = Get-SfcVerdict $r.Output $cbs
    $summary = @($r.Lines | Where-Object { $_ -notmatch '\d{1,3}\s*%' } | Select-Object -Last 2) -join ' | '
    $rec = @{ OK=''; ACTION='Resolve protected-file integrity violations (DISM /RestoreHealth, then sfc /scannow in a change) and re-run before IPU.'; MANUAL='Result could not be classified; review the output and CBS.log.' }[$verdict.Status]
    Add-Result 'WINDOWS_HEALTH' 'SFC VerifyOnly' $verdict.Status ('ExitCode=' + $r.ExitCode + ', Basis=' + $verdict.Basis) @($duration,$summary) -Recommendation $rec -Source 'sfc.exe /verifyonly, CBS.log'
}

Register-Check -Id 'compatscan' -Name 'Setup compatibility scan' -Phase 'Slow' -Script {
    if ($AssessmentMode -eq 'Post') { $script:CurrentCheckMessage = 'Not applicable after the upgrade'; $script:CurrentCheckOutcome = 'Skipped'; return }
    if (-not $TargetMediaPath) {
        Add-Result 'COMPAT_SCAN' 'SetupCompatibilityScan' 'INFO' 'Not run - no installation media given' ('Optional. To let Windows Setup check this server with Microsoft''s own compatibility rules, run again with -TargetMediaPath set to the ' + (Get-ReleaseDisplayName $TargetServerVersion) + ' ISO, or a folder or share with the installation files.') -Source 'SETTINGS' -Link $script:DocLinks.SetupOptions.Url -LinkTitle $script:DocLinks.SetupOptions.Title
        $script:CurrentCheckMessage = 'Not configured: no installation media given (-TargetMediaPath)'
        $script:CurrentCheckOutcome = 'Skipped'; return
    }
    $timeout = [math]::Min($CompatScanTimeoutMinutes * 60, $script:SlowSecondsLeft)
    $mountedIso = $null
    try {
        $mediaRoot = $TargetMediaPath
        if ($TargetMediaPath -match '\.iso$') {
            if (-not (Test-Path -LiteralPath $TargetMediaPath)) { throw ('ISO not found: ' + $TargetMediaPath) }
            $mountedIso = Mount-DiskImage -ImagePath $TargetMediaPath -PassThru -ErrorAction Stop
            $letter = ($mountedIso | Get-Volume -ErrorAction Stop).DriveLetter
            if (-not $letter) { throw 'The mounted ISO received no drive letter.' }
            $mediaRoot = $letter + ':\'
        }
        $setupExe = Join-Path $mediaRoot 'setup.exe'
        if (-not (Test-Path -LiteralPath $setupExe)) { throw ('setup.exe not found in ' + $mediaRoot) }

        # Pick the image that matches this server's edition and installation
        # type; a mismatch is itself a finding (wrong media).
        $imageFile = @('sources\install.wim','sources\install.esd') | ForEach-Object { Join-Path $mediaRoot $_ } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $imageFile) { throw 'No install.wim or install.esd found in the media.' }
        $wantEdition = ([string]$script:Data.CV.EditionID -replace '(Core|Cor)$','')
        $wantType = [string]$script:Data.CV.InstallationType
        $index = 0; $imageNames = @(); $imageLanguages = ''
        foreach ($img in @(Get-WindowsImage -ImagePath $imageFile -ErrorAction Stop)) {
            $detail = Get-WindowsImage -ImagePath $imageFile -Index $img.ImageIndex -ErrorAction Stop
            $imageNames += ('[' + $img.ImageIndex + '] ' + $img.ImageName)
            if (-not $index -and [string]$detail.EditionId -eq $wantEdition -and [string]$detail.InstallationType -eq $wantType) {
                $index = [int]$img.ImageIndex; $imageLanguages = (@($detail.Languages) -join ',')
            }
        }
        if (-not $index) {
            Add-Result 'COMPAT_SCAN' 'MatchingImage' 'ACTION' ('No image for ' + $wantEdition + ' / ' + $wantType + ' in the media') $imageNames -Recommendation 'The media does not contain an image matching this server''s edition and installation type. Use the correct media; IPU cannot switch edition down or between Core and Desktop Experience.' -Source $imageFile
            return
        }
        Add-Result 'COMPAT_SCAN' 'MatchingImage' 'OK' ('Index ' + $index) @(('Languages=' + $imageLanguages),($imageNames -join ' | ')) -Source $imageFile
        if ($script:Data.InstallLanguage -and $imageLanguages -and (@($imageLanguages -split ',') -notcontains $script:Data.InstallLanguage)) {
            Add-Result 'COMPAT_SCAN' 'MediaLanguage' 'BLOCKER' ('Media=' + $imageLanguages + ', Installed=' + $script:Data.InstallLanguage) '' -Recommendation 'Changing language during IPU is not supported. Use media in the installed language.' -Source $imageFile
        }

        $arguments = @('/auto','upgrade','/quiet','/compat','scanonly','/imageindex',[string]$index,'/dynamicupdate','disable')
        if ($TargetServerVersion -eq '2025') { $arguments += @('/eula','accept') }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-NativeCapture $setupExe $arguments $timeout
        $sw.Stop()
        if ($r.TimedOut) {
            Add-Result 'COMPAT_SCAN' 'SetupCompatibilityScan' 'MANUAL' ('Stopped after ' + [math]::Round($timeout/60) + ' minutes') ('Duration=' + (Format-Duration $sw.Elapsed)) -Recommendation 'Run the scan manually: setup.exe /auto upgrade /quiet /compat scanonly /imageindex <n>.' -Source 'setup.exe'
            $script:CurrentCheckOutcome = 'TimedOut'; return
        }
        if ($r.Error) { throw $r.Error }
        $decision = Get-CompatScanDecision $r.ExitCode

        # Keep Setup's CompatData XML and list the hard blocks it names.
        $evidence = Join-Path $ReportDirectory ($script:SafeComputerName + '-CompatData')
        $blocks = @()
        $panther = 'C:\$WINDOWS.~BT\Sources\Panther'
        $xmlFiles = @(Get-ChildItem -LiteralPath $panther -Filter 'CompatData*.xml' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge (Get-Date).AddSeconds(-1 * ($sw.Elapsed.TotalSeconds + 60)) })
        if ($xmlFiles.Count -gt 0) {
            $null = Initialize-OutputFolder $evidence
            foreach ($x in $xmlFiles) {
                Copy-Item -LiteralPath $x.FullName -Destination $evidence -Force
                try {
                    [xml]$doc = Get-Content -LiteralPath $x.FullName -Raw
                    foreach ($node in @($doc.SelectNodes('//*[@BlockingType="Hard"]'))) {
                        $owner = $node.ParentNode
                        $label = @($owner.Attributes['Name'],$owner.Attributes['Title'],$owner.Attributes['Id'] | Where-Object { $_ } | ForEach-Object { $_.Value }) | Select-Object -First 1
                        if (-not $label) { $label = $owner.LocalName }
                        $blocks += $label
                    }
                } catch { Write-Swallowed $_ }
            }
        }
        $details = @(('Duration=' + (Format-Duration $sw.Elapsed)),('ImageIndex=' + $index))
        if ($blocks.Count -gt 0) { $details += ('Hard blocks: ' + (@($blocks | Sort-Object -Unique) -join ', ')) }
        if ($xmlFiles.Count -gt 0) { $details += ('CompatData copied to ' + $evidence) }
        Add-Result 'COMPAT_SCAN' 'SetupCompatibilityScan' $decision.Status ($decision.Code + ' - ' + $decision.Text) $details -Recommendation $(if ($decision.Status -eq 'OK') { '' } else { 'Read the CompatData XML (and Panther setuperr.log) to see exactly what Setup objects to, fix it, and re-run the scan.' }) -Source ('setup.exe /compat scanonly from ' + $TargetMediaPath)
    } finally {
        if ($mountedIso) { try { Dismount-DiskImage -ImagePath $TargetMediaPath -ErrorAction Stop | Out-Null } catch { Write-Swallowed $_ } }
    }
}

} # end Register-AssessmentCheck


# ---------------------------------------------------------------------------
# RDP access / policy evidence (called by the 'rdp' check)
# ---------------------------------------------------------------------------
function Invoke-RdpPolicyAssessment {
    if (-not $EnableRDPPolicyEvidence) {
        Add-Result 'RDP' 'RDPAccessReadiness' 'MANUAL' 'REVIEW' 'Policy evidence disabled in SETTINGS' -Recommendation 'Test RDP end-to-end before relying on it during the change.'
        $script:Data.RdpSummary = 'REVIEW (not assessed)'; $script:Data.DriveRedirection = 'Not assessed'
        return
    }
    $hard = New-Object System.Collections.Generic.List[string]
    $review = New-Object System.Collections.Generic.List[string]
    $driveBlock = New-Object System.Collections.Generic.List[string]

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $root = Join-Path $PolicyEvidenceRoot ($script:SafeComputerName + '-IPU-Policy-' + $stamp)
    $lgpoRoot = Join-Path $root 'LGPO-Backup'
    $zip = $root + '.zip'
    $script:Data.PolicyEvidence = $root
    $folderOk = $true
    try {
        $null = Initialize-OutputFolder $PolicyEvidenceRoot
        $null = Initialize-OutputFolder $root
        New-Item -ItemType Directory -Path $lgpoRoot -Force | Out-Null
    }
    catch { $folderOk = $false; $review.Add('Evidence folder could not be created'); Add-Result 'POLICY_EVIDENCE' 'EvidenceFolder' 'MANUAL' $root $_.Exception.Message -Recommendation 'Make the evidence folder writable and re-run.' -Kind 'Observation' }

    if ($folderOk) {
        # LGPO backup (local policy only; never imports).
        if (Test-Path -LiteralPath $LgpoExe -PathType Leaf) {
            $r = Invoke-NativeCapture $LgpoExe @('/b',$lgpoRoot,'/n',('Pre-IPU-' + $stamp)) 120
            $r.Output | Out-File -LiteralPath (Join-Path $root 'LGPO-Backup-Output.txt') -Encoding UTF8
            if ($r.ExitCode -eq 0) { Add-Result 'POLICY_EVIDENCE' 'LocalGroupPolicyBackup' 'OK' $lgpoRoot -Source 'LGPO.exe /b' }
            else { Add-Result 'POLICY_EVIDENCE' 'LocalGroupPolicyBackup' 'MANUAL' ('ExitCode=' + $r.ExitCode) $r.Error -Recommendation 'Review the LGPO output if a restorable local-policy copy is required.' -Kind 'Observation' -Source 'LGPO.exe /b' }
            foreach ($pol in @(
                @{ Scope='Machine'; Mode='/m'; Path=(Join-Path $env:windir 'System32\GroupPolicy\Machine\Registry.pol') },
                @{ Scope='User'; Mode='/u'; Path=(Join-Path $env:windir 'System32\GroupPolicy\User\Registry.pol') })) {
                if (Test-Path -LiteralPath $pol.Path) {
                    $parsed = Join-Path $root ('Local-Policy-' + $pol.Scope + '-RegistryPol.txt')
                    (Invoke-NativeCapture $LgpoExe @('/parse',$pol.Mode,$pol.Path) 60).Output | Out-File -LiteralPath $parsed -Encoding UTF8
                    Add-Result 'POLICY_EVIDENCE' ('LocalRegistryPolicy-' + $pol.Scope) 'INFO' $parsed -Source 'LGPO.exe /parse'
                }
            }
        } else {
            Add-Result 'POLICY_EVIDENCE' 'LocalGroupPolicyBackup' 'INFO' 'LGPO.exe not present - local policy backup skipped' $LgpoExe -Recommendation 'Optional: place LGPO.exe at this path to keep a restorable local-policy backup.' -Source 'File check'
        }

        # Resultant Set of Policy.
        $gpresult = Join-Path $env:windir 'System32\gpresult.exe'
        $gpText = Invoke-NativeCapture $gpresult @('/Scope','Computer','/Z') 180
        $gpText.Output | Out-File -LiteralPath (Join-Path $root 'GPResult-Computer.txt') -Encoding UTF8
        $gpHtml = Invoke-NativeCapture $gpresult @('/Scope','Computer','/H',(Join-Path $root 'GPResult-Computer.html'),'/F') 180
        if ($gpText.ExitCode -eq 0 -or $gpHtml.ExitCode -eq 0) { Add-Result 'POLICY_EVIDENCE' 'ComputerRSoP' 'OK' (Join-Path $root 'GPResult-Computer.html') -Source 'gpresult' }
        else { $review.Add('gpresult did not return computer policy'); Add-Result 'POLICY_EVIDENCE' 'ComputerRSoP' 'MANUAL' ('Exit=' + $gpText.ExitCode + '/' + $gpHtml.ExitCode) -Recommendation 'Collect RSoP manually.' -Kind 'Observation' -Source 'gpresult' }
    }

    $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    $tsPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    $tcpPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'

    $polDeny = Get-RegistryValueSafe $policyPath 'fDenyTSConnections'
    $effDeny = Get-RegistryValueSafe $tsPath 'fDenyTSConnections'
    if ($polDeny.Exists -and [int]$polDeny.Value -eq 1) { $hard.Add('Group Policy disables incoming RDP') }
    if ($effDeny.Exists -and [int]$effDeny.Value -ne 0) { $hard.Add('Incoming RDP is disabled (fDenyTSConnections)') }
    if (-not $effDeny.Exists) { $review.Add('RDP enablement value not found') }
    Add-Result 'RDP' 'RemoteConnections' 'INFO' ('Policy=' + $(if ($polDeny.Exists) { $polDeny.Value } else { 'NotConfigured' })) ('Effective=' + $(if ($effDeny.Exists) { $effDeny.Value } else { 'Unknown' })) -Source 'Terminal Services registry'

    $port = 3389
    $portValue = Get-RegistryValueSafe $tcpPath 'PortNumber'
    if ($portValue.Exists) { $port = [int]$portValue.Value }
    $nla = Get-RegistryValueSafe $tcpPath 'UserAuthentication'
    Add-Result 'RDP' 'Listener' 'INFO' ('Port=' + $port) ('NLA=' + $(if ($nla.Exists) { $nla.Value } else { 'Unknown' })) -Source 'RDP-Tcp registry'
    if ($nla.Exists -and [int]$nla.Value -eq 0) {
        $nlaPolicy = Get-RegistryValueSafe $policyPath 'UserAuthentication'
        if ($nlaPolicy.Exists) {
            Add-Result 'RDP' 'NetworkLevelAuthentication' 'WARNING' 'Disabled' 'Not an IPU blocker - a security observation. Set by Group Policy.' -Recommendation 'RDP accepts connections before the user is authenticated. NLA is set by Group Policy: change the GPO (Require user authentication for remote connections by using Network Level Authentication), not the server.' -Kind 'Observation' -Source 'Terminal Services policy UserAuthentication'
        } else {
            Add-Result 'RDP' 'NetworkLevelAuthentication' 'WARNING' 'Disabled' 'Not an IPU blocker - a security observation.' -Recommendation 'RDP accepts connections before the user is authenticated. Enable NLA unless a documented client requirement prevents it.' -Kind 'Observation' -Source 'RDP-Tcp UserAuthentication' -Command (Get-RecommendationCommand 'EnableNla').Command -CommandKind 'Change'
        }
    }

    $svc = @($script:Data.Services | Where-Object { $_.Name -eq 'TermService' }) | Select-Object -First 1
    if (-not $svc) { $hard.Add('TermService not found') }
    elseif ($svc.StartMode -eq 'Disabled') { $hard.Add('TermService is disabled') }
    elseif ($svc.State -ne 'Running') { $review.Add('TermService is not running') }

    $listening = $false
    if (Test-CommandAvailable 'Get-NetTCPConnection') {
        try { $listening = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction Stop).Count -gt 0 } catch { Write-Swallowed $_ }
    }
    if (-not $listening) { $hard.Add('Nothing listening on TCP/' + $port) }

    # Firewall: only relevant when at least one profile is enabled.
    if (Test-CommandAvailable 'Get-NetFirewallRule') {
        try {
            $enabledProfiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop | Where-Object { [string]$_.Enabled -eq 'True' })
            if ($enabledProfiles.Count -eq 0) {
                Add-Result 'RDP' 'FirewallRDPAllow' 'INFO' 'Windows Firewall disabled on all profiles' -Source 'Get-NetFirewallProfile'
            } else {
                $rules = @(Get-NetFirewallRule -PolicyStore ActiveStore -ErrorAction Stop | Where-Object { [string]$_.Direction -eq 'Inbound' -and [string]$_.Enabled -eq 'True' -and [string]$_.Action -eq 'Allow' -and ($_.Name -like 'RemoteDesktop*' -or $_.DisplayGroup -match 'Remote Desktop') })
                if ($rules.Count -gt 0) { Add-Result 'RDP' 'FirewallRDPAllow' 'OK' ('EnabledAllowRules=' + $rules.Count) -Source 'Get-NetFirewallRule' }
                else { $review.Add('No enabled standard Remote Desktop firewall rule (a custom rule may exist)'); Add-Result 'RDP' 'FirewallRDPAllow' 'WARNING' 'No enabled standard RDP allow rule' -Recommendation 'Check for a custom rule and upstream firewalls.' -Kind 'Observation' -Source 'Get-NetFirewallRule' }
            }
        } catch { $review.Add('Firewall rules could not be read') }
    }

    # User rights. A populated Deny right is normal hardening and is recorded
    # as evidence only; an empty Allow right is a real problem.
    if ($folderOk) {
        $inf = Join-Path $root 'Effective-User-Rights.inf'
        $null = Invoke-NativeCapture (Join-Path $env:windir 'System32\secedit.exe') @('/export','/cfg',$inf,'/areas','USER_RIGHTS','/quiet') 120
        if (Test-Path -LiteralPath $inf) {
            $lines = @(Get-Content -LiteralPath $inf)
            foreach ($right in @('SeRemoteInteractiveLogonRight','SeDenyRemoteInteractiveLogonRight')) {
                $line = @($lines | Where-Object { $_ -match ('^\s*' + $right + '\s*=') }) | Select-Object -First 1
                $accounts = @()
                if ($line) { foreach ($a in @(((($line -split '=',2)[1]).Trim()) -split ',' | Where-Object { $_.Trim() })) { $accounts += (Resolve-PolicyAccountName $a) } }
                if ($right -eq 'SeRemoteInteractiveLogonRight' -and $accounts.Count -eq 0) { $hard.Add('Nobody holds "Allow log on through Remote Desktop Services"') }
                $text = 'No identities'; if ($accounts.Count -gt 0) { $text = $accounts -join ' | ' }
                Add-Result 'RDP' $right 'INFO' $text -Recommendation 'Check the change engineer''s account (and nested groups) against Allow and Deny.' -Source 'secedit /export'
            }
        } else { $review.Add('User rights could not be exported') }
    }
    $rdu = Get-LocalGroupMembersBySid 'S-1-5-32-555'
    Add-Result 'RDP' 'RemoteDesktopUsersGroup' 'INFO' $(if ($rdu.Count -gt 0) { $rdu -join ' | ' } else { 'No members' }) -Source 'Local group S-1-5-32-555'

    # Drive redirection (machine policy, listener, loaded user policies).
    $polCdm = Get-RegistryValueSafe $policyPath 'fDisableCdm'
    $tcpCdm = Get-RegistryValueSafe $tcpPath 'fDisableCdm'
    if ($polCdm.Exists -and [int]$polCdm.Value -eq 1) { $driveBlock.Add('Machine policy fDisableCdm=1') }
    if ($tcpCdm.Exists -and [int]$tcpCdm.Value -eq 1) { $driveBlock.Add('RDP-Tcp fDisableCdm=1') }
    foreach ($sid in @(Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } | ForEach-Object { $_.PSChildName })) {
        $u = Get-RegistryValueSafe ('Registry::HKEY_USERS\' + $sid + '\Software\Policies\Microsoft\Windows NT\Terminal Services') 'fDisableCdm'
        if ($u.Exists -and [int]$u.Value -eq 1) { $driveBlock.Add('User ' + (Resolve-PolicyAccountName $sid) + ' fDisableCdm=1') }
    }

    if ($hard.Count -gt 0) {
        $script:Data.RdpSummary = 'NO-GO: ' + ($hard -join '; ')
        Add-Result 'RDP' 'RDPAccessReadiness' 'ACTION' 'NO-GO' @(($hard -join ' | '),($review -join ' | ')) -Recommendation 'Fix the local RDP block and test an end-to-end logon, or plan console-only access for the change.' -Source 'Registry, service, listener, user rights'
    } elseif ($review.Count -gt 0) {
        $script:Data.RdpSummary = 'REVIEW: ' + ($review -join '; ')
        Add-Result 'RDP' 'RDPAccessReadiness' 'MANUAL' 'REVIEW' ($review -join ' | ') -Recommendation 'Test an end-to-end RDP logon with the account that will be used in the change window.' -Source 'Registry, service, listener, firewall'
    } else {
        $script:Data.RdpSummary = 'GO (no local blocker)'
        Add-Result 'RDP' 'RDPAccessReadiness' 'OK' 'GO' 'No local RDP blocker detected' -Recommendation 'Upstream firewalls, PAM and credentials are outside this check.' -Source 'Registry, service, listener, firewall'
    }
    if ($driveBlock.Count -gt 0) {
        $script:Data.DriveRedirection = 'BLOCKED: ' + ($driveBlock -join '; ')
        Add-Result 'RDP' 'DriveRedirection' 'WARNING' 'BLOCKED' ($driveBlock -join ' | ') -Recommendation 'If you plan to copy media or tools over an RDP-mapped drive, use another route (SA file transfer, share, mounted ISO).' -Source 'Terminal Services policy'
    } else {
        $script:Data.DriveRedirection = 'Allowed locally'
        Add-Result 'RDP' 'DriveRedirection' 'OK' 'ALLOWED LOCALLY' 'Destination/client policy not tested' -Source 'Terminal Services policy'
    }

    if ($folderOk) {
        try {
            @($script:Results | Where-Object { $_.Area -in @('RDP','POLICY_EVIDENCE') }) | Export-Csv -LiteralPath (Join-Path $root 'RDP-Policy-Assessment.csv') -Delimiter ';' -NoTypeInformation -Encoding UTF8
        } catch { Write-Swallowed $_ }
        if ($CreatePolicyEvidenceZip) {
            try {
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
                [IO.Compression.ZipFile]::CreateFromDirectory($root,$zip,[IO.Compression.CompressionLevel]::Optimal,$false)
                $script:Data.PolicyEvidence = $zip
            } catch { Add-Result 'POLICY_EVIDENCE' 'EvidenceArchive' 'MANUAL' 'ZIP creation failed' $_.Exception.Message -Recommendation 'Retrieve the folder directly.' -Kind 'Observation' }
        }
        Add-Result 'POLICY_EVIDENCE' 'EvidenceLocation' 'INFO' $script:Data.PolicyEvidence $root -Source 'Local filesystem'
    }
}


# =============================================================================
# 6. HTML/JSON REPORT
# =============================================================================
function ConvertTo-HtmlText {
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function New-StatusBadge {
    param([string]$Status)
    return '<span class="badge s-' + (ConvertTo-HtmlText $Status.ToLowerInvariant()) + '">' + (ConvertTo-HtmlText $Status) + '</span>'
}

function Get-AreaName {
    param([string]$Area)
    if ($script:AreaMap.ContainsKey($Area)) { return $script:AreaMap[$Area].Name }
    return $Area
}

function Get-ResultText {
    param($Results, [string]$Area, [string]$Item)
    $r = @($Results | Where-Object { $_.Area -eq $Area -and $_.Item -eq $Item }) | Select-Object -First 1
    if (-not $r) { return '' }
    return (@($r.Value,$r.Details) | Where-Object { $_ }) -join ' | '
}

function Get-CoverageNotice {
    # Pure: splits the checks that did not complete into problems (failed,
    # timed out, or skipped because the time budget ran out - their areas are
    # incomplete) and checks not run by choice (switched off, no media,
    # not applicable), each with a plain-language sentence.
    param([object[]]$CheckRuns, [string]$Target = 'the target release')
    $problems = @(); $byChoice = @()
    foreach ($run in @($CheckRuns)) {
        if ($run.Outcome -eq 'Completed') { continue }
        $msg = [string]$run.Message
        if ($run.Outcome -eq 'Skipped' -and $msg -like 'Not applicable*') { continue }
        if ($run.Outcome -eq 'Skipped' -and $msg -like 'Not configured*') {
            if ($run.Id -eq 'compatscan') {
                $byChoice += ('Microsoft''s own upgrade check (Setup compatibility scan) was not run, because no ' + $Target + ' installation media was given. This is optional: to include it, run the assessment again with -TargetMediaPath set to the ISO, or a folder or share with the installation files.')
            } else {
                $byChoice += ($run.Name + ' was switched off for this run (' + ($msg -replace '^Not configured:\s*','') + '). Run it before the final go/no-go.')
            }
            continue
        }
        $why = 'did not finish'
        if ($run.Outcome -eq 'Failed') { $why = 'stopped with an error' }
        elseif ($run.Outcome -eq 'TimedOut') { $why = 'ran out of time' }
        elseif ($run.Outcome -eq 'Skipped') { $why = 'was not started, the time budget was used up' }
        $problems += ($run.Name + ' ' + $why)
    }
    return [pscustomobject]@{ Problems = $problems; ByChoice = $byChoice }
}

function New-RecommendationHtml {
    # The "What to do" cell: recommendation text, then the command (labelled
    # Check or Change, with a copy button) and the documentation link (#79).
    param($Row)
    $html = ConvertTo-HtmlText $Row.Recommendation
    if ($Row.PSObject.Properties['Command'] -and $Row.Command) {
        $label = 'Check'; $hint = 'read-only'
        if ($Row.CommandKind -eq 'Change') { $label = 'Change'; $hint = 'run in the change window' }
        $cmd = ConvertTo-HtmlText $Row.Command
        $html += '<div class="cmd"><span class="ck ck-' + $label.ToLowerInvariant() + '" title="' + $hint + '">' + $label + '</span><code>' + $cmd + '</code><button type="button" class="copy" data-cmd="' + $cmd + '" aria-label="Copy the ' + $label.ToLowerInvariant() + ' command">Copy</button></div>'
    }
    if ($Row.PSObject.Properties['Link'] -and $Row.Link) {
        $title = $Row.LinkTitle; if (-not $title) { $title = $Row.Link }
        $html += '<div class="more">Read more: <a class="ext" href="' + (ConvertTo-HtmlText $Row.Link) + '" target="_blank" rel="noopener noreferrer">' + (ConvertTo-HtmlText $title) + '</a></div>'
    }
    return $html
}

function New-FindingTable {
    param($Rows, [switch]$WithCheckbox, [string]$Caption = 'Findings')
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="scroll"><table><caption class="sr">' + (ConvertTo-HtmlText $Caption) + '</caption><thead><tr>')
    if ($WithCheckbox) { [void]$sb.Append('<th scope="col" class="cb">Done</th>') }
    [void]$sb.Append('<th scope="col">Status</th><th scope="col">Area</th><th scope="col">Item</th><th scope="col">Finding</th><th scope="col">What to do</th></tr></thead><tbody>')
    foreach ($r in $Rows) {
        [void]$sb.Append('<tr>')
        # A printable tick box: the glyph is hidden from screen readers, which
        # read the visible word "open" instead.
        if ($WithCheckbox) { [void]$sb.Append('<td class="cb"><span aria-hidden="true">&#x2610;</span> <span class="cbt">open</span></td>') }
        $finding = (@($r.Value,$r.Details) | Where-Object { $_ }) -join ' | '
        [void]$sb.Append('<td class="nw">' + (New-StatusBadge $r.Status) + '</td><td class="nw">' + (ConvertTo-HtmlText (Get-AreaName $r.Area)) + '</td><td class="item">' + (ConvertTo-HtmlText $r.Item) + '</td><td class="txt">' + (ConvertTo-HtmlText $finding) + '</td><td class="txt">' + (New-RecommendationHtml $r) + '</td></tr>')
    }
    [void]$sb.Append('</tbody></table></div>')
    return $sb.ToString()
}

function New-IPUReportHtml {
    param(
        [object[]]$Results,
        [object[]]$CheckRuns,
        [string]$OverallStatus,
        [datetime]$CompletedTime,
        [switch]$Partial
    )
    $ErrorActionPreference = 'Stop'
    $e = ${function:ConvertTo-HtmlText}
    $findings = @($Results | Where-Object { $_.Kind -eq 'Finding' })
    $counts = @{}
    foreach ($s in $script:FindingStatuses) { $counts[$s] = @($findings | Where-Object { $_.Status -eq $s }).Count }
    $decision = @($findings | Where-Object { $_.Status -in @('BLOCKER','ACTION') } | Sort-Object @{Expression={Get-StatusRank $_.Status}},Area,Item)
    $planning = @($findings | Where-Object { $_.Status -in @('WARNING','MANUAL') } | Sort-Object @{Expression={Get-StatusRank $_.Status}},Area,Item)
    $checklist = @($Results | Where-Object { $_.Kind -eq 'Checklist' })
    $coverage = Get-CoverageNotice $CheckRuns (Get-ReleaseDisplayName $TargetServerVersion)
    $duration = Format-Duration ($CompletedTime - $script:CollectionStarted)
    $target = Get-ReleaseDisplayName $TargetServerVersion
    $isPost = ($AssessmentMode -eq 'Post')
    $title = 'Windows Server IPU Readiness Assessment'
    if ($isPost) { $title = 'Windows Server Post-Upgrade Verification' }
    # A fact a check sets: 'None detected' when the check completed without
    # finding anything, 'Not assessed' when the check did not complete.
    $factValue = {
        param($Value, [string]$CheckId)
        if ($Value) { return [string]$Value }
        $run = @($CheckRuns | Where-Object { $_.Id -eq $CheckId }) | Select-Object -First 1
        if ($run -and $run.Outcome -eq 'Completed') { return 'None detected' }
        return 'Not assessed'
    }
    $eppNames = @($Results | Where-Object { $_.Area -eq 'ANTIVIRUS' -and $_.Item -eq 'Microsoft Defender Antivirus' -and ($_.Status -eq 'OK' -or $_.Status -eq 'WARNING') } | ForEach-Object { $_.Item })
    if ($script:Data.EndpointProducts) { $eppNames += @($script:Data.EndpointProducts) }
    else { $eppNames += @($Results | Where-Object { $_.Area -eq 'ANTIVIRUS' -and $_.Status -eq 'WARNING' -and $_.Item -ne 'Microsoft Defender Antivirus' } | ForEach-Object { $_.Item }) }
    $epp = $eppNames -join ', '

    $facts = @(
        @('Current OS', (Get-ResultText $Results 'UPGRADE_PATH' 'CurrentOS')),
        @('Target', $target),
        @('Upgrade path', (Get-ResultText $Results 'UPGRADE_PATH' 'TargetUpgradePath')),
        @('Installation image to use', $script:Data.RecommendedMedia),
        @('Windows activation', (Get-ResultText $Results 'LICENSING' 'CurrentActivation')),
        @('Platform', (Get-ResultText $Results 'PLATFORM' 'PhysicalOrVirtual')),
        @('Domain role', $script:Data.DomainRoleText),
        @('UAC', $script:Data.UacSummary),
        @('SQL Server', (& $factValue $script:Data.SqlSummary 'sql')),
        @('Endpoint protection', (& $factValue $epp 'antivirus')),
        @('VMware Tools', (Get-ResultText $Results 'VMWARE' 'VMwareTools')),
        @('Setup compatibility scan', (Get-ResultText $Results 'COMPAT_SCAN' 'SetupCompatibilityScan')),
        @('RDP access', $script:Data.RdpSummary),
        @('RDP drive redirection', $script:Data.DriveRedirection),
        @('C: drive', $script:Data.CSummary),
        @('Memory GB / logical CPUs', ((Get-ResultText $Results 'PERFORMANCE' 'MemoryGB') + ' / ' + (Get-ResultText $Results 'PERFORMANCE' 'LogicalProcessors'))),
        @('Policy evidence', $script:Data.PolicyEvidence),
        @('Machine-readable result', $(if ($WriteJson) { $script:JsonPath } else { 'Disabled' }))
    )
    if ($isPost) {
        $facts = @(
            @('Current OS', (Get-ResultText $Results 'UPGRADE_PATH' 'CurrentOS')),
            @('Target', $target),
            @('Upgrade result', (Get-ResultText $Results 'POST_UPGRADE' 'UpgradeReachedTarget')),
            @('Baseline', (Get-ResultText $Results 'POST_UPGRADE' 'Baseline')),
            @('Windows activation', (Get-ResultText $Results 'LICENSING' 'CurrentActivation')),
            @('RDP access', $script:Data.RdpSummary),
            @('UAC', $script:Data.UacSummary),
            @('C: drive', $script:Data.CSummary),
            @('Endpoint protection', (& $factValue $epp 'antivirus'))
        )
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">')
    [void]$sb.AppendLine('<title>' + (& $e $(if ($isPost) { 'IPU Post-Upgrade' } else { 'IPU Assessment' })) + ' - ' + (& $e $script:ComputerName) + '</title>')
    [void]$sb.AppendLine(@'
<style>
/* Colour tokens. Contrast (WCAG 2.1) is checked by the tests: text >= 4.5:1, focus outline >= 3:1, in both themes. */
:root{--ink:#16202e;--muted:#5d6a79;--line:#dde3ea;--bg:#f3f5f8;--panel:#ffffff;--navy:#16365f;--heading:#16365f;--th-bg:#eef2f7;--th-ink:#30475f;--focus:#16365f;--partial-bg:#fff4d6;--partial-ink:#5c4400;--partial-line:#e6c46a;--blocker:#7a1717;--action:#b42318;--warning:#9a5800;--manual:#5b47a0;--ok:#17703a;--info:#4a6578}
@media (prefers-color-scheme: dark){:root{--ink:#e6edf5;--muted:#a9b6c4;--line:#2c3947;--bg:#0e141b;--panel:#16202b;--heading:#a9c8f0;--th-bg:#1e2a37;--th-ink:#c5d3e0;--focus:#8fb8ff;--partial-bg:#3a2e0b;--partial-ink:#ffe08a;--partial-line:#7a6220}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.5 "Segoe UI",Arial,sans-serif}
.wrap{max-width:1440px;margin:auto;padding:24px 16px}
.hero{background:var(--navy);color:#fff;padding:24px 28px;border-radius:12px}
.hero h1{margin:0 0 6px;font-size:24px;font-weight:600}.hero p{margin:3px 0;color:#d5e1ee}
.verdict{margin-top:12px;font-size:16px}.verdict .badge{font-size:14px;padding:5px 12px}
.partial{background:var(--partial-bg);border:1px solid var(--partial-line);color:var(--partial-ink);border-radius:10px;padding:12px 16px;margin:14px 0;font-weight:600}
.cards{display:grid;grid-template-columns:repeat(6,minmax(0,1fr));gap:10px;margin:16px 0}
.card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:12px 14px;color:inherit;text-decoration:none;display:block}a.card:hover{border-color:var(--heading)}a.card:focus-visible{outline:3px solid var(--focus);outline-offset:2px}a.card b::after{content:" \2192";font-size:14px;color:var(--muted)}
.cmd{margin-top:6px;display:flex;flex-wrap:wrap;gap:6px;align-items:flex-start}.cmd code{flex:1 1 260px;font:12px/1.45 Consolas,'Cascadia Mono',monospace;background:var(--th-bg);color:var(--ink);border:1px solid var(--line);border-radius:6px;padding:4px 6px;overflow-wrap:anywhere;white-space:pre-wrap}
.ck{font-size:11px;font-weight:700;border-radius:4px;padding:2px 6px;border:1px solid var(--line);color:var(--ink)}.ck-change{border-color:var(--action);color:var(--action)}
.copy{display:none;font:inherit;font-size:12px;border:1px solid var(--line);background:var(--panel);color:var(--ink);border-radius:6px;padding:2px 8px;cursor:pointer}.js .copy{display:inline-block}.copy:focus-visible{outline:3px solid var(--focus);outline-offset:2px}
.more{margin-top:4px;font-size:12px}.more a{color:var(--heading)}
.note{background:var(--panel);border:1px solid var(--line);border-left:4px solid var(--info);border-radius:10px;padding:12px 16px;margin:14px 0}.card b{display:block;font-size:24px;font-weight:650}.card small{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.04em}
section,details{background:var(--panel);border:1px solid var(--line);border-radius:10px;margin:14px 0}
section{padding:18px 20px}h2{font-size:18px;margin:0 0 6px;color:var(--heading)}.lead{color:var(--muted);margin:0 0 12px}
summary{cursor:pointer;font-size:16px;font-weight:600;color:var(--heading);padding:14px 20px}summary:focus-visible{outline:3px solid var(--focus);outline-offset:2px;border-radius:8px}details>div{padding:0 20px 18px}
.badge{display:inline-block;color:#fff;font-weight:700;font-size:11px;letter-spacing:.03em;padding:3px 8px;border-radius:999px;white-space:nowrap}
.s-blocker{background:var(--blocker)}.s-action{background:var(--action)}.s-warning{background:var(--warning)}.s-manual{background:var(--manual)}.s-ok{background:var(--ok)}.s-info{background:var(--info)}
.scroll{width:100%;overflow-x:auto}table{width:100%;border-collapse:collapse;min-width:860px}
th,td{text-align:left;vertical-align:top;border-bottom:1px solid var(--line);padding:8px}
th{background:var(--th-bg);color:var(--th-ink);font-size:11px;text-transform:uppercase;letter-spacing:.04em}
.nw{white-space:nowrap}.txt{overflow-wrap:anywhere}.item{min-width:150px;overflow-wrap:break-word}.cb{width:64px;white-space:nowrap;color:var(--muted)}.cb span[aria-hidden]{font-size:18px}.cbt{font-size:11px}
.sr{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}
.facts{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:0 24px}.fact{border-bottom:1px solid var(--line);padding:8px 0}.fact b{display:block;color:var(--muted);font-size:12px;font-weight:600}
.legend p{margin:6px 0}.muted{color:var(--muted)}footer{padding:16px 2px;color:var(--muted);font-size:12px}
@media(max-width:900px){.cards{grid-template-columns:repeat(2,1fr)}.facts{grid-template-columns:1fr}}
@media print{.copy{display:none!important}a.ext::after{content:" (" attr(href) ")";font-size:9px;overflow-wrap:anywhere}:root{--ink:#16202e;--muted:#5d6a79;--line:#dde3ea;--bg:#ffffff;--panel:#ffffff;--heading:#16365f;--th-bg:#eef2f7;--th-ink:#30475f;--partial-bg:#fff4d6;--partial-ink:#5c4400;--partial-line:#e6c46a}body{background:#fff;color:#16202e}.wrap{max-width:none;padding:0}details{break-inside:avoid}.scroll{overflow:visible}table{min-width:0;font-size:10px}}
</style></head><body><div class="wrap">
'@)
    [void]$sb.AppendLine('<div class="hero"><h1>' + (& $e $title) + '</h1>')
    [void]$sb.AppendLine('<p><strong>' + (& $e $script:ComputerName) + '</strong> &nbsp;&rarr;&nbsp; ' + (& $e $target) + '</p>')
    [void]$sb.AppendLine('<p>Started ' + (& $e $script:CollectionStarted.ToString('yyyy-MM-dd HH:mm')) + ' &nbsp;|&nbsp; Completed ' + (& $e $CompletedTime.ToString('yyyy-MM-dd HH:mm')) + ' &nbsp;|&nbsp; Runtime ' + (& $e $duration) + ' &nbsp;|&nbsp; Collector ' + (& $e $script:CollectorVersion) + '</p>')
    [void]$sb.AppendLine('<p class="verdict">' + $(if ($isPost) { 'Overall post-upgrade result: ' } else { 'Overall IPU assessment: ' }) + (New-StatusBadge $OverallStatus) + '</p></div>')
    if ($Partial) {
        [void]$sb.AppendLine('<div class="partial">PARTIAL REPORT - the slow checks (DISM, SFC, Setup compatibility scan) had not finished when this was written. If this is the newest report, the SA job was stopped before they completed.</div>')
    }
    if ($script:LogWriteFailures -gt 0) {
        [void]$sb.AppendLine('<div class="partial">The collector log is incomplete: ' + $script:LogWriteFailures + ' line(s) could not be written to ' + (& $e $script:LogPath) + '.</div>')
    }
    if (@($coverage.Problems).Count -gt 0) {
        [void]$sb.AppendLine('<div class="partial">Not fully assessed: ' + (& $e (@($coverage.Problems) -join '; ')) + '. The results for these areas may be incomplete - absence of findings there is not evidence of readiness. Details: <a href="#coverage">Collector coverage</a>.</div>')
    }
    foreach ($note in @($coverage.ByChoice)) { [void]$sb.AppendLine('<div class="note"><strong>Not run by choice:</strong> ' + (& $e $note) + '</div>') }

    # Counter cards link to the rows behind them (#77); a zero is not a link.
    $cardTarget = @{ BLOCKER = 'decision'; ACTION = 'decision'; WARNING = 'planning'; MANUAL = 'planning' }
    $card = {
        param([string]$Label, $Count, [string]$Anchor, [string]$What)
        if ($Anchor -and [int]("0" + ([string]$Count -replace '\s.*$','')) -gt 0) {
            return ('<a class="card" href="#' + $Anchor + '" aria-label="' + (& $e ([string]$Count + ' ' + $What + ' - go to the list')) + '"><small>' + (& $e $Label) + '</small><b>' + (& $e ([string]$Count)) + '</b></a>')
        }
        return ('<div class="card"><small>' + (& $e $Label) + '</small><b>' + (& $e ([string]$Count)) + '</b></div>')
    }
    [void]$sb.AppendLine('<div class="cards">')
    foreach ($s in $script:FindingStatuses) { [void]$sb.AppendLine((& $card $s $counts[$s] $cardTarget[$s] ($s + ' findings'))) }
    [void]$sb.AppendLine((& $card 'Checklist items' $checklist.Count 'checklist' 'checklist items'))
    [void]$sb.AppendLine((& $card 'Checks run' (([string]@($CheckRuns | Where-Object { $_.Outcome -eq 'Completed' }).Count) + ' / ' + @($CheckRuns).Count) 'coverage' 'checks completed') + '</div>')

    [void]$sb.AppendLine('<section><h2>Summary</h2><div class="facts">')
    foreach ($f in $facts) {
        $v = [string]$f[1]; if (-not $v) { $v = 'Not reported' }
        [void]$sb.AppendLine('<div class="fact"><b>' + (& $e $f[0]) + '</b>' + (& $e $v) + '</div>')
    }
    [void]$sb.AppendLine('</div></section>')

    if ($isPost) { [void]$sb.AppendLine('<section id="decision"><h2>Must be resolved</h2><p class="lead">Problems found after the upgrade, including what changed compared with the pre-upgrade snapshot.</p>') }
    else { [void]$sb.AppendLine('<section id="decision"><h2>IPU decision - must be resolved</h2><p class="lead">BLOCKER: this server cannot follow the standard IPU path as configured. ACTION: must be fixed or investigated before the change.</p>') }
    if ($decision.Count -eq 0) { [void]$sb.AppendLine('<p>No BLOCKER or ACTION findings.</p>') } else { [void]$sb.AppendLine((New-FindingTable $decision -WithCheckbox -Caption 'Findings that must be resolved')) }
    [void]$sb.AppendLine('</section>')

    if ($isPost) { [void]$sb.AppendLine('<section id="planning"><h2>Verify</h2><p class="lead">WARNING: check that this is expected. MANUAL: needs a human or external check.</p>') }
    else { [void]$sb.AppendLine('<section id="planning"><h2>IPU planning - validate before the change</h2><p class="lead">WARNING: risk to plan for. MANUAL: needs a human or external check.</p>') }
    if ($planning.Count -eq 0) { [void]$sb.AppendLine('<p>No planning findings.</p>') } else { [void]$sb.AppendLine((New-FindingTable $planning -WithCheckbox -Caption 'Findings to validate before the change')) }
    [void]$sb.AppendLine('</section>')

    if ($checklist.Count -gt 0) {
        [void]$sb.AppendLine('<section id="checklist"><h2>Standard change checklist</h2><p class="lead">Required for every IPU. These do not affect the overall status.</p>')
        [void]$sb.AppendLine((New-FindingTable $checklist -WithCheckbox -Caption 'Standard change checklist'))
        [void]$sb.AppendLine('</section>')
    }

    [void]$sb.AppendLine('<section class="legend"><h2>Status meaning</h2>')
    [void]$sb.AppendLine('<p>' + (New-StatusBadge 'BLOCKER') + ' The selected IPU path or standard procedure does not apply.</p>')
    [void]$sb.AppendLine('<p>' + (New-StatusBadge 'ACTION') + ' Must be fixed or investigated before IPU.</p>')
    [void]$sb.AppendLine('<p>' + (New-StatusBadge 'WARNING') + ' Planning risk.</p>')
    [void]$sb.AppendLine('<p>' + (New-StatusBadge 'MANUAL') + ' Needs human or external verification, or the check could not complete.</p>')
    [void]$sb.AppendLine('<p>' + (New-StatusBadge 'OK') + ' Check passed. ' + (New-StatusBadge 'INFO') + ' Documentation only. Rows marked <em>Observation</em> in the sections below have a status for visibility but do not affect the overall result.</p></section>')

    foreach ($chapter in $script:ChapterOrder) {
        $areas = @($script:AreaMap.Keys | Where-Object { $script:AreaMap[$_].Chapter -eq $chapter })
        $rows = @($Results | Where-Object { $areas -contains $_.Area -and $_.Kind -ne 'Checklist' } | Sort-Object @{Expression={Get-AreaName $_.Area}},@{Expression={Get-StatusRank $_.Status}},Item)
        if ($rows.Count -eq 0 -and $chapter -ne 'Assessment and Collector') { continue }
        $open = ''
        if (@($rows | Where-Object { $_.Kind -eq 'Finding' -and $_.Status -in @('BLOCKER','ACTION') }).Count -gt 0) { $open = ' open' }
        $chapterId = ''
        if ($chapter -eq 'Assessment and Collector') {
            $chapterId = ' id="coverage"'
            if (@($coverage.Problems).Count -gt 0) { $open = ' open' }
        }
        [void]$sb.AppendLine('<details' + $chapterId + $open + '><summary>' + (& $e $chapter) + ' (' + $rows.Count + ')</summary><div>')
        if ($chapter -eq 'Assessment and Collector') {
            [void]$sb.AppendLine('<h2>Collector coverage</h2><div class="scroll"><table><caption class="sr">Collector coverage: outcome of every check</caption><thead><tr><th scope="col">Check</th><th scope="col">Phase</th><th scope="col">Outcome</th><th scope="col">Duration</th><th scope="col">Message</th></tr></thead><tbody>')
            foreach ($run in $CheckRuns) {
                $st = 'OK'; if ($run.Outcome -eq 'Failed') { $st = 'MANUAL' } elseif ($run.Outcome -ne 'Completed') { $st = 'WARNING' }
                [void]$sb.AppendLine('<tr><td>' + (& $e $run.Name) + '</td><td>' + (& $e $run.Phase) + '</td><td class="nw">' + (New-StatusBadge $st) + ' ' + (& $e $run.Outcome) + '</td><td class="nw">' + (& $e $run.Duration) + '</td><td class="txt">' + (& $e $run.Message) + '</td></tr>')
            }
            [void]$sb.AppendLine('</tbody></table></div><h2 style="margin-top:16px">Records</h2>')
        }
        if ($rows.Count -gt 0) {
            [void]$sb.AppendLine('<div class="scroll"><table><caption class="sr">' + (& $e ($chapter + ': all records')) + '</caption><thead><tr><th scope="col">Status</th><th scope="col">Area</th><th scope="col">Item</th><th scope="col">Value</th><th scope="col">Details</th><th scope="col">Recommendation</th><th scope="col">Source</th></tr></thead><tbody>')
            foreach ($r in $rows) {
                $kindNote = ''; if ($r.Kind -eq 'Observation') { $kindNote = '<br><em class="muted">Observation</em>' }
                [void]$sb.AppendLine('<tr><td class="nw">' + (New-StatusBadge $r.Status) + $kindNote + '</td><td class="nw">' + (& $e (Get-AreaName $r.Area)) + '</td><td class="item">' + (& $e $r.Item) + '</td><td class="txt">' + (& $e $r.Value) + '</td><td class="txt">' + (& $e $r.Details) + '</td><td class="txt">' + (New-RecommendationHtml $r) + '</td><td class="txt muted">' + (& $e $r.Source) + '</td></tr>')
            }
            [void]$sb.AppendLine('</tbody></table></div>')
        }
        [void]$sb.AppendLine('</div></details>')
    }
    [void]$sb.AppendLine('<footer>Collector ' + (& $e $script:CollectorVersion) + ' | ' + @($Results).Count + ' records | Read-only local assessment. It does not prove backups, credentials, licensing or application/vendor support. Commands are shown, never run, by this script.</footer></div>')
    # Copy buttons (#79). Without JavaScript the buttons stay hidden and the
    # command text can be selected as usual.
    [void]$sb.AppendLine('<script type="text/javascript">document.documentElement.className+=" js";document.addEventListener("click",function(e){var b=e.target;if(!b||!b.classList||!b.classList.contains("copy"))return;var t=b.getAttribute("data-cmd");var done=function(){b.textContent="Copied";setTimeout(function(){b.textContent="Copy"},1500)};if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(t).then(done,function(){})}else{var a=document.createElement("textarea");a.value=t;document.body.appendChild(a);a.select();try{document.execCommand("copy");done()}catch(x){}document.body.removeChild(a)}});</script>')
    [void]$sb.AppendLine('</body></html>')
    return $sb.ToString()
}

function Write-AssessmentReport {
    param([switch]$Partial)
    $completed = Get-Date
    $results = $script:Results.ToArray()
    $overall = Get-OverallStatus $results
    $html = New-IPUReportHtml -Results $results -CheckRuns $script:CheckRuns.ToArray() -OverallStatus $overall -CompletedTime $completed -Partial:$Partial
    if ($RedactReport) { $html = Protect-ReportText $html (Get-RedactionContext) }
    if ($html.Length -lt 2048 -or $html -notmatch '(?is)^\s*<!doctype html' -or $html -notmatch '(?is)</html>\s*$') {
        throw ('HTML validation failed (length {0}).' -f $html.Length)
    }
    $temp = $script:ReportPath + '.writing'
    [IO.File]::WriteAllText($temp,$html,(New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $script:ReportPath -Force -ErrorAction Stop
    $info = Get-Item -LiteralPath $script:ReportPath -ErrorAction Stop
    Write-AssessmentLog 'INFO' 'REPORT' ('Written. Partial={0} | Overall={1} | Bytes={2}' -f [bool]$Partial,$overall,$info.Length)
    if ($WriteJson) {
        try { Write-AssessmentJson -Results $results -Overall $overall -Completed $completed -Partial:$Partial }
        catch { Write-AssessmentLog 'WARNING' 'JSON' ('JSON result could not be written: ' + $_.Exception.Message) }
    }
    return [pscustomobject]@{ Overall=$overall; Completed=$completed; Bytes=$info.Length }
}

function New-AssessmentJsonObject {
    # The machine-readable result: used by Merge-IPUAssessments.ps1 for the
    # fleet overview, and as the baseline for the post-upgrade comparison.
    param([object[]]$Results, [string]$Overall, [datetime]$Completed, [switch]$Partial)
    $counts = [ordered]@{}
    foreach ($s in $script:FindingStatuses) { $counts[$s] = @($Results | Where-Object { $_.Kind -eq 'Finding' -and $_.Status -eq $s }).Count }
    $snapshot = $script:Data.Snapshot
    if (-not $snapshot) { $snapshot = @{} }
    return [pscustomobject][ordered]@{
        Schema              = 'IPU-Assessment/1'
        CollectorVersion    = $script:CollectorVersion
        ComputerName        = $script:ComputerName
        Mode                = $AssessmentMode
        TargetServerVersion = $TargetServerVersion
        Started             = $script:CollectionStarted.ToString('yyyy-MM-dd HH:mm:ss')
        Completed           = $Completed.ToString('yyyy-MM-dd HH:mm:ss')
        Partial             = [bool]$Partial
        Redacted            = $false
        Overall             = $Overall
        Counts              = [pscustomobject]$counts
        Facts               = [pscustomobject][ordered]@{
            CurrentOS        = (Get-ResultText $Results 'UPGRADE_PATH' 'CurrentOS')
            SourceRelease    = $script:Data.SourceRelease
            UpgradePath      = (Get-ResultText $Results 'UPGRADE_PATH' 'TargetUpgradePath')
            RecommendedMedia = $script:Data.RecommendedMedia
            Platform         = (Get-ResultText $Results 'PLATFORM' 'PhysicalOrVirtual')
            DomainRole       = $script:Data.DomainRoleText
            Uac              = $script:Data.UacSummary
            SqlServer        = $script:Data.SqlSummary
            Activation       = $script:Data.ActivationSummary
            CDrive           = $script:Data.CSummary
            CompatScan       = (Get-ResultText $Results 'COMPAT_SCAN' 'SetupCompatibilityScan')
        }
        Results             = @($Results | Select-Object CheckId,Area,Item,Status,Kind,Value,Details,Recommendation,Source,Command,CommandKind,Link,LinkTitle)
        CheckRuns           = @($script:CheckRuns.ToArray() | Select-Object Id,Name,Phase,Outcome,Duration,Message)
        Snapshot            = [pscustomobject]$snapshot
    }
}

function Get-RedactionContext {
    # One context per run, so placeholders match between the checkpoint and
    # the final report, and between the HTML and the JSON.
    if (-not $script:RedactionContext) {
        $domain = ''
        if ($script:Data.CS -and $script:Data.CS.PartOfDomain) { $domain = [string]$script:Data.CS.Domain }
        $script:RedactionContext = New-RedactionContext $script:ComputerName $domain
    }
    return $script:RedactionContext
}

function Write-AssessmentJson {
    param([object[]]$Results, [string]$Overall, [datetime]$Completed, [switch]$Partial)
    $obj = New-AssessmentJsonObject -Results $Results -Overall $Overall -Completed $Completed -Partial:$Partial
    if ($RedactReport) {
        $obj = Protect-ReportObject $obj (Get-RedactionContext)
        $obj.Redacted = $true
    }
    $json = $obj | ConvertTo-Json -Depth 6
    $temp = $script:JsonPath + '.writing'
    [IO.File]::WriteAllText($temp,$json,(New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $script:JsonPath -Force -ErrorAction Stop
}

function Import-SiteDataFile {
    # Reads -PatternFile and -ProfileFile (both optional) and applies them,
    # all or nothing. Without either file, nothing changes and no row is
    # written. A file that cannot be used gives a MANUAL finding.
    if ($PatternFile) {
        $hash = ''
        try {
            $text = [IO.File]::ReadAllText($PatternFile)
            try { $hash = (Get-FileHash -LiteralPath $PatternFile -Algorithm SHA256 -ErrorAction Stop).Hash } catch { Write-Swallowed $_ }
            $obj = ConvertFrom-SiteDataJson $text 'IPU-Patterns/1'
            $merge = Merge-DetectionPatternSet $script:DetectionPatterns $obj
            if (@($merge.Errors).Count -gt 0) { throw (@($merge.Errors) -join ' | ') }
            $script:DetectionPatterns = $merge.Patterns
            Add-Result 'COLLECTOR' 'Pattern file' 'INFO' ('Applied, ' + @($merge.Changes).Count + ' change(s)') (@($merge.Changes) + @('SHA256=' + $hash)) -Source $PatternFile
            Write-AssessmentLog 'INFO' 'SITEDATA' ('Pattern file applied: ' + $PatternFile + ' | ' + (@($merge.Changes) -join '; '))
        } catch {
            Add-Result 'COLLECTOR' 'Pattern file' 'MANUAL' 'Not applied; the built-in detection patterns were used' @($_.Exception.Message, $(if ($hash) { 'SHA256=' + $hash })) -Recommendation 'Fix the file (user guide, "Site data files") and re-run. Until then, products your site added to the file are not detected.' -Kind 'Finding' -Source $PatternFile
            Write-AssessmentLog 'WARNING' 'SITEDATA' ('Pattern file not applied: ' + $_.Exception.Message)
        }
    }
    if ($ProfileFile) {
        $hash = ''
        try {
            $text = [IO.File]::ReadAllText($ProfileFile)
            try { $hash = (Get-FileHash -LiteralPath $ProfileFile -Algorithm SHA256 -ErrorAction Stop).Hash } catch { Write-Swallowed $_ }
            $obj = ConvertFrom-SiteDataJson $text 'IPU-Profile/1'
            $attributes = @{}
            foreach ($n in $script:ProfileSettingNames) {
                $v = Get-Variable -Name $n -ErrorAction SilentlyContinue
                if ($v) { $attributes[$n] = @($v.Attributes) }
            }
            $decision = Get-ProfileSettingDecision $obj $attributes $script:ProfileSettingNames $script:BoundParameterNames
            if (@($decision.Errors).Count -gt 0) { throw (@($decision.Errors) -join ' | ') }
            $details = @()
            foreach ($k in @($decision.Settings.Keys)) {
                Set-Variable -Name $k -Value $decision.Settings[$k] -Scope Script
                $details += ($k + '=' + [string]$decision.Settings[$k])
            }
            foreach ($k in @($decision.Ignored)) { $details += ($k + ': the argument given to the script was used') }
            if ($decision.Settings.Contains('NumberCultureName')) {
                try { $script:NumberCulture = New-Object System.Globalization.CultureInfo($decision.Settings['NumberCultureName']) }
                catch { $script:NumberCulture = [System.Globalization.CultureInfo]::InvariantCulture }
            }
            Add-Result 'COLLECTOR' 'Profile file' 'INFO' ('Applied, ' + $decision.Settings.Count + ' setting(s)') ($details + @('SHA256=' + $hash)) -Source $ProfileFile
            Write-AssessmentLog 'INFO' 'SITEDATA' ('Profile file applied: ' + $ProfileFile + ' | ' + ($details -join '; '))
        } catch {
            Add-Result 'COLLECTOR' 'Profile file' 'MANUAL' 'Not applied; the built-in defaults and the arguments were used' @($_.Exception.Message, $(if ($hash) { 'SHA256=' + $hash })) -Recommendation 'Fix the file (user guide, "Site data files") and re-run. Until then, thresholds and policy are the built-in defaults, not your site''s.' -Kind 'Finding' -Source $ProfileFile
            Write-AssessmentLog 'WARNING' 'SITEDATA' ('Profile file not applied: ' + $_.Exception.Message)
        }
    }
}

function Invoke-PostUpgradeComparison {
    $script:CurrentCheckId = 'postcompare'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $outcome = 'Completed'; $message = ''
    try {
        $reached = ($script:Data.SourceRelease -eq $TargetServerVersion)
        if ($reached) { Add-Result 'POST_UPGRADE' 'UpgradeReachedTarget' 'OK' ('Now ' + (Get-ReleaseDisplayName $script:Data.SourceRelease)) -Source 'Win32_OperatingSystem build' }
        else { Add-Result 'POST_UPGRADE' 'UpgradeReachedTarget' 'ACTION' ('Now ' + (Get-ReleaseDisplayName $script:Data.SourceRelease) + ', expected ' + (Get-ReleaseDisplayName $TargetServerVersion)) '' -Recommendation 'The upgrade did not complete or was rolled back. Read C:\$WINDOWS.~BT\Sources\Panther\setuperr.log and C:\Windows\Panther\setuperr.log.' -Source 'Win32_OperatingSystem build' }

        if (-not (Test-Path -LiteralPath $script:BaselinePath)) {
            Add-Result 'POST_UPGRADE' 'Baseline' 'MANUAL' 'No pre-upgrade result found' $script:BaselinePath -Recommendation 'Without the pre-upgrade JSON the before/after comparison cannot run. Compare services, ports and routes manually with the pre-upgrade HTML report.' -Source 'File check'
            return
        }
        $baseline = Get-Content -LiteralPath $script:BaselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($baseline.Redacted) {
            Add-Result 'POST_UPGRADE' 'Baseline' 'MANUAL' 'The pre-upgrade result is redacted' $script:BaselinePath -Recommendation 'A redacted result has its names and addresses replaced, so it cannot be compared with this server. Keep an unredacted pre-upgrade run (without -RedactReport) as the baseline and redact only copies you share.' -Source 'File check'
            return
        }
        Add-Result 'POST_UPGRADE' 'Baseline' 'INFO' ('Pre-upgrade run ' + $baseline.Completed + ' (collector ' + $baseline.CollectorVersion + ')') @(('Overall then=' + $baseline.Overall),('OS then=' + $baseline.Facts.CurrentOS)) -Source $script:BaselinePath
        if ($baseline.Partial) {
            Add-Result 'POST_UPGRADE' 'BaselineComplete' 'WARNING' 'The pre-upgrade result was a partial (checkpoint) report' '' -Recommendation 'The snapshot data is still complete (it is collected by the fast checks); only the slow checks were missing.' -Kind 'Observation' -Source $script:BaselinePath
        }
        $diffs = Compare-IPUSnapshot $baseline.Snapshot ([pscustomobject]$script:Data.Snapshot)
        foreach ($d in $diffs) { Add-Result 'POST_UPGRADE' $d.Item $d.Status $d.Value $d.Details -Recommendation $d.Recommendation -Source 'Pre-upgrade snapshot vs now' }
        if ($diffs.Count -eq 0) { Add-Result 'POST_UPGRADE' 'Comparison' 'OK' 'No lost services, ports, routes, IP/DNS settings, hosts entries, applications, features or tasks' -Source 'Pre-upgrade snapshot vs now' }
    } catch {
        $outcome = 'Failed'; $message = $_.Exception.Message
        Add-Result 'COLLECTOR' 'Post-upgrade comparison' 'MANUAL' 'Check did not complete' $message -Recommendation 'Compare manually with the pre-upgrade report.' -Kind 'Finding'
    } finally {
        $sw.Stop()
        $script:CheckRuns.Add([pscustomobject]@{ Id='postcompare'; Name='Post-upgrade comparison'; Phase='Fast'; Outcome=$outcome; Duration=(Format-Duration $sw.Elapsed); Seconds=[math]::Round($sw.Elapsed.TotalSeconds,1); Message=$message })
        $script:CurrentCheckId = 'core'
    }
}


# =============================================================================
# 7. MAIN
# =============================================================================
function Invoke-Assessment {
    $header = 'ComputerName;RunStatus;AssessmentStatus;ReportPath;LogPath;ReportSizeKB;Records;Started;Completed;Duration;CollectorVersion;Message'
    try {
        $script:OutputFolderState = Initialize-OutputFolder $ReportDirectory
        [IO.File]::WriteAllText($script:LogPath,('Timestamp;Level;Phase;Message' + [Environment]::NewLine),(New-Object System.Text.UTF8Encoding($false)))
    } catch { Write-Swallowed $_ }
    Write-AssessmentLog 'INFO' 'START' ('Collector={0} | Mode={1} | Target={2} | PowerShell={3}' -f $script:CollectorVersion,$AssessmentMode,$TargetServerVersion,$PSVersionTable.PSVersion)

    Import-SiteDataFile
    Register-AssessmentCheck
    $skip = @()
    if ($AssessmentMode -eq 'Post') { $skip = @('checklist','compatscan') }
    foreach ($check in @($script:Checks | Where-Object { $_.Phase -eq 'Fast' -and $skip -notcontains $_.Id })) { Invoke-Check $check }
    if ($AssessmentMode -eq 'Post') { Invoke-PostUpgradeComparison }

    try { $null = Write-AssessmentReport -Partial } catch { Write-AssessmentLog 'WARNING' 'REPORT' ('Checkpoint report failed: ' + $_.Exception.Message) }

    $budgetMinutes = Get-SlowCheckBudget $SlowCheckBudgetMinutes $CompatScanTimeoutMinutes $TargetMediaPath $AssessmentMode
    $slowWatch = [Diagnostics.Stopwatch]::StartNew()
    foreach ($check in @($script:Checks | Where-Object { $_.Phase -eq 'Slow' -and $skip -notcontains $_.Id })) {
        $script:SlowSecondsLeft = Get-SlowSecondsLeft $budgetMinutes $slowWatch.Elapsed.TotalSeconds
        if (Test-SlowCheckSkip $script:SlowSecondsLeft) {
            Add-SkippedSlowCheck $check $budgetMinutes
            continue
        }
        Invoke-Check $check
    }

    $records = $script:Results.Count
    $failedChecks = @($script:CheckRuns | Where-Object { $_.Outcome -ne 'Completed' }).Count
    try {
        $final = Write-AssessmentReport
        $msg = 'Mode=' + $AssessmentMode + ', Checks=' + $script:CheckRuns.Count + ', NotCompleted=' + $failedChecks + $(if ($WriteJson) { ', JSON=' + $script:JsonPath } else { '' }) + '. Retrieve the HTML via the approved SA process.'
        [Console]::Out.WriteLine($header)
        [Console]::Out.WriteLine((@(
            $script:ComputerName,'SUCCEEDED',$final.Overall,$script:ReportPath,$script:LogPath,
            ([Math]::Round($final.Bytes/1KB,1)).ToString('N1',$script:NumberCulture),$records,
            $script:CollectionStarted.ToString('yyyy-MM-dd HH:mm:ss'),$final.Completed.ToString('yyyy-MM-dd HH:mm:ss'),
            (Format-Duration ($final.Completed - $script:CollectionStarted)),$script:CollectorVersion,$msg
        ) | ForEach-Object { ConvertTo-SAField $_ }) -join ';')
        $script:ExitCode = 0
    } catch {
        $msg = $_.Exception.GetType().Name + ': ' + $_.Exception.Message
        Write-AssessmentLog 'ERROR' 'FAILED' $msg
        Remove-Item -LiteralPath ($script:ReportPath + '.writing') -Force -ErrorAction SilentlyContinue
        $now = Get-Date
        [Console]::Out.WriteLine($header)
        [Console]::Out.WriteLine((@(
            $script:ComputerName,'FAILED',(Get-OverallStatus $script:Results.ToArray()),$script:ReportPath,$script:LogPath,'',$records,
            $script:CollectionStarted.ToString('yyyy-MM-dd HH:mm:ss'),$now.ToString('yyyy-MM-dd HH:mm:ss'),
            (Format-Duration ($now - $script:CollectionStarted)),$script:CollectorVersion,$msg
        ) | ForEach-Object { ConvertTo-SAField $_ }) -join ';')
        $script:ExitCode = 1
    }
}

if ($env:IPU_ASSESSMENT_LIBRARY_ONLY -eq '1') { return }

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
        # Pass through every parameter the caller gave, typed correctly.
        $argText = ConvertTo-RelaunchArgumentText $PSBoundParameters
        $command = "& '" + ($selfPath -replace "'","''") + "'" + $argText + '; exit $LASTEXITCODE'
        & $ps64 -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $command
        exit $LASTEXITCODE
    }
}

$script:ExitCode = 1
$null = Invoke-Assessment
exit $script:ExitCode
