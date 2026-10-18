<#
===============================================================================
 SCRIPT NAME : Windows-IPU-Readiness-Assessment.ps1
 VERSION     : 4.5.3
 RELEASE DATE: 2026-10-15
 PURPOSE     : Windows Server in-place upgrade (IPU) readiness assessment and
               post-upgrade verification, with a self-contained HTML report
               and a JSON result file written on the assessed server.
 EXECUTION   : OpenText Server Automation (SA) Ad-Hoc Scripting, normally as
               the SA Agent / LocalSystem account. Windows PowerShell 4.0+.
 BUILT FROM  : src/assessment/*.ps1 by build/Build-Script.ps1. Edit the parts,
               not this file (ADR 0002).
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

    Evidence copies (unredacted) go to timestamped folders and ZIPs under
    C:\Temp\IPU-Evidence, one subfolder per topic: Policy (RDP and Group
    Policy), IIS, Network, Printers. The optional Setup compatibility scan
    keeps Setup's CompatData XML next to the report.

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
    4.5.3 - Redaction key (DO-NOT-SHARE-...-REDACTION-KEY.csv) next to
            redacted copies. Certificate locality and other subject
            fields redacted; versions with a build suffix kept. Windows
            per-user feed tasks summarised. The Group Policy registry
            fallback works with more than ten GPOs and says what it found.
    4.5.2 - A server that is not a print server no longer reports the
            print server backup as "not started, time budget used up".
    4.5.1 - Fixes from real redacted reports: evidence copies in
            C:\Temp\IPU-Evidence with a folder per topic and a README;
            named SQL Server instances redacted; version numbers no
            longer redacted as addresses; tasks renamed by version and
            AzureArcSetup (a Feature on Demand in 2025) not reported
            missing after the upgrade.
    4.5.0 - Cluster nodes and domain controllers are SPECIAL: a short
            report with the facts, risks and options ("expensive and
            risky"); undecided signals are MANUAL. Network: IPv6, DNS
            suffix, WINS, NetBIOS, metric and VLAN per adapter, compared
            by MAC after the upgrade, and a local copy of the network
            configuration. Print servers: printers, ports, drivers, port
            monitors and a PrintBrm backup. Activation per channel in
            plain words, NLA in the Summary. Built from parts (ADR 0002).
    4.4.0 - Fixes from a live run of four upgrades 2016/2019 -> 2025.
            Redaction covers custom names in RDP user rights and whole DNS
            domain names; -RedactExisting keeps one placeholder per server.
            Post-upgrade comparison separates expected changes (INFO) and
            disabled services from real problems, and reports RDP NLA
            turned off. Recovery partition: Setup switch before, removal
            steps after. Group Policy read from the registry when gpresult
            has no RSoP data as SYSTEM. SFC "repair pending reboot" and an
            empty -LgpoExe handled correctly.
    4.3.0 - Findings and requests from a Windows Server 2012 R2 live run.
            Prerequisites check (PowerShell 4.0, .NET 4.5, administrator)
            with a clear stop message; PS 4.0 compatibility checked in CI.
            New file shares check; computer OU path; workgroup wording;
            Status meaning after the Summary; chapters open only with
            findings, Expand/Collapse all, full print. Redaction covers more
            names and -RedactExisting redacts reports already written.
            Target licensing per activation channel; source OS end of
            support.
    4.2.0 - Feedback from the first live run of 4.1.0. Endpoint protection
            names each product and version (Trend Deep Security Agent, Apex
            One, Vision One Basecamp separately); the unused built-in
            Defender for Endpoint sensor is no longer a warning; security
            tools without a driver are observations. New: Group Policy check
            (GPOs, OS-version WMI filters, AD groups, last applied), UAC in
            the summary, IIS configuration copy, commands and documentation
            links with recommendations, linked counters and plain-language
            notes for checks skipped by choice.
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

