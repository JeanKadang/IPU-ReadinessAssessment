# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [4.5.4] - 2026-10-23

Fixes from the 4.5.3 script evaluation: failures that read as a clean result, time limits for the fast phase, a trustworthy post-upgrade comparison and clear SA result lines. It also lays the groundwork for end-of-life checks (ADR 0003, a separate script that is not wired into the assessment yet).

### Added
- `Get-IPUEolStatus.ps1 -Update -SnapshotPath <file>` fetches the lifecycle data of all supported products into one dated JSON snapshot, to be copied to where the verdicts are made. The data is MIT-licensed (endoflife.date); the snapshot carries the copyright line and licence notice. A folder as -SnapshotPath gets `eol-snapshot.json` inside it, and a write that fails stops the script instead of reporting a snapshot. A snapshot older than `-MaxAgeMonths` (default 6) cannot confirm that a release is still supported (MANUAL); end-of-life verdicts still show (#283).
- End-of-life status for products and Windows Server 2008 to 2025, evaluated off the server from an endoflife.date snapshot (ADR 0003, `src/Get-IPUEolStatus.ps1`, first part of #266). Not yet wired into the assessment or the merged report. Based on the proof of concept from pull request #271.

### Changed
- `docs/roadmap.md` lists the open issues by milestone, with a link to the project board (#280).
- ADR 0003 (still Proposed): the assessment may read a local end-of-life snapshot file at the end of a run, the EOL functions become one shared source part, and the detected products are recorded in the result JSON (#287).
- `CONTRIBUTING.md` has a release checklist with the manual PowerShell 4.0 check on a Windows Server 2012 R2 test VM, because CI has no PowerShell 4.0 (#130).
- The release zip now includes `docs/samples/` (sample report and result), so the sample links in the bundled docs work offline (#135). `docs/adr/` and `docs/git-setup.md` stay out: they are for contributors.
- `CONTRIBUTING.md` says how pull requests from outside are handled (#277).

### Fixed
- The post-upgrade comparison no longer says `Comparison OK` against a baseline that could not be compared. It reports MANUAL when the Pre result has no snapshot, is not a Pre result of this server, was a SPECIAL short report, or was taken after the upgrade, and names each list (ports, routes, adapters, tasks, shares, printers ...) whose check did not complete or that the baseline lacks. `Comparison OK` is written only when every list was compared (#239).
- Running Pre again no longer silently replaces a complete baseline: before a checkpoint or a run on another release replaces `<Computer>-IPU-Assessment.json`, the earlier file is kept as `<Computer>-IPU-Assessment-<date>-<time>.json` (#239).
- The fleet overview no longer counts a server twice when its redacted copy (`REDACTED-...`) is in the same folder: redacted copies are skipped when original results are present, the console says how many, and `-IncludeRedacted` keeps them. A folder with only redacted results is used as before (#138).
- A folder the script creates (report and evidence folders) is created together with its restricted access list, so it never exists with inherited permissions for a moment; where that is not possible it falls back to create-then-restrict as before. A `-NumberCultureName` that is not a culture on the server is now reported in the baseline (INFO) instead of silently using the invariant format (#139).
- Arguments to native tools are escaped the way Windows reads them back: a path with a space and a trailing backslash (`C:\Install Media\`) no longer swallows its closing quote, and an embedded quote is escaped. Before, only white space triggered quoting (#136).
- The fleet CSV files are written as UTF-8 with a byte-order mark on PowerShell 7 too (`Export-Csv -Encoding UTF8` only wrote one on 5.1), so Excel with Danish regional settings no longer garbles æ, ø and å. The result JSON has an optional `UtcOffset` (for example `+02:00`) next to `Started` and `Completed`, and the fleet merge picks the newest result per server by UTC instead of by the text of the local time (#252).
- An output folder that cannot be written is found at the start: the run stops at once with a FAILED SA line and exit code 1, instead of doing up to an hour of checks and failing at the end. The SA line also carries the outcome of the JSON file: when a JSON was asked for and could not be written the line says `FAILED` and `JSON=FAILED`, and a checkpoint-only file is called `PARTIAL` (#250).
- A throw outside a check (loading the site data file, registering the checks, the SPECIAL decision, skipping a slow check, building the 64-bit relaunch command) now ends in a report and an SA result line: the line says FAILED, the report has a MANUAL row "The run stopped early", and the exit code is 1. Before, SA got no result line. A `break` or `continue` inside a check no longer ends the whole fast phase: that check is reported as failed (MANUAL) and the next one runs (#251).
- The fast phase has time limits: CIM queries stop after 120 seconds, the Group Policy WMI-filter lookups after 30 seconds, and the domain controller facts (FSMO roles, global catalog) after 60 seconds, so a hung provider or an unreachable domain controller can no longer stall a run until SA's job timeout. A required query that times out is a failed check (MANUAL). The built-in Administrator is looked up by SID, and not at all on a domain controller (where it listed every domain account); the free space after C: is worked out from the partition layout instead of `Get-PartitionSupportedSize`, which can take minutes on a large volume (#241).
- A failed role and feature inventory (`Get-WindowsFeature` throwing) no longer reads as "not installed". The inventory is kept only when the whole list was read, so every role stays unknown instead of absent, the rest of the baseline (platform, snapshot) still runs, and the cluster, IIS and RDS rows report MANUAL. A server with the Cluster service and `HKLM:\Cluster` is still treated as a cluster node when the feature list cannot be read (#238).
- A row that says a read failed (`MANUAL`) now counts towards the overall status. Eleven such rows were tagged Observation or Evidence, which the overall status ignores, so a server whose role inventory, shares, printers, IIS copy, VSS writers, local policy, WinRE, RDP certificate or evidence copy could not be read could still end as `OK`. They are now Findings, and `Add-Result` refuses a `MANUAL` Observation or Evidence row; the only exception is a missing management agent, which stays an observation (#240).
- SFC: when the console text is not English, the CBS.log fallback no longer reports OK for a run that logged Cannot verify component files ... manifest is damaged. Such a run is now ACTION (#249).
- Post-upgrade comparison: only Windows' own per-user services (CDPUserSvc, OneSyncSvc and the other templates Microsoft lists) are treated as per-user. A service whose name only ends in a hex-like suffix, such as `AppSvc_DB01`, is no longer filed as "exists only while a user is signed in" when it is gone after the upgrade: it is reported as a missing service (#247).
- A two-part VMware Tools version such as `12.5` is compared as `12.5.0`, so it no longer counts as older than the 12.5.0 minimum for a Windows Server 2025 target (#253).
- Removed and deprecated features follow Microsoft's page per target release (#232). A target 2022 no longer gets "no longer developed" notes for Network Load Balancing, WebDAV Redirector and Windows Internal Database: the page lists them for 2025 only. iSNS (removed in 2022) and WINS (no longer developed in 2022) are now reported.

## [4.5.3] - 2026-10-15

A redaction key for the team, and fixes from a review of five real reports (Windows Server 2016, redacted with 4.5.2).

### Added
- Redaction key (#211): with `-RedactExisting` or `-RedactReport`, a `DO-NOT-SHARE-...-REDACTION-KEY.csv` next to the redacted copies says which placeholder stands for which original (`HOST-1;HOST;<name>`), so answers about a shared copy can be mapped back. `;` separated, UTF-8 with BOM, readable by SYSTEM, Administrators and the current user only. Share only the `REDACTED-*` files. `-WriteRedactionKey $false` switches it off.

### Changed
- "Tasks with named accounts" no longer lists Windows' per-user `User_Feed_Synchronization-{GUID}` tasks (61 on one file server); one INFO line counts them (#214).
- When gpresult and the Group Policy registry fallback both give nothing, the MANUAL row says what the fallback found (key missing, empty, unreadable), so it can be followed up (#215).

### Fixed
- The Group Policy registry fallback (#160) now works on servers with more than ten applied GPOs: their registry subkeys are numbered in hexadecimal (`a`, `b`, ...), which stopped the read, so Group Policy stayed MANUAL when gpresult had no data as SYSTEM (#223).
- A version with a build suffix (`11.0.16.1+1`) is no longer redacted as an IPv4 address (#213).

### Security
- Certificate subjects: locality, state, street, postal code, e-mail and serial number are redacted too; a real redacted report showed the city. The country code stays (#212).

## [4.5.2] - 2026-10-14

### Fixed
- A server that is not a print server no longer gets "Not fully assessed: Print server backup (PrintBrm) was not started, the time budget was used up" at the top of the report; the backup simply does not apply there. The time-budget wording is now used only when the budget really ran out (#206).

## [4.5.1] - 2026-10-14

Fixes from a review of real redacted reports (4.3.0 pre-upgrade, 4.4.0 post-upgrade, redacted with 4.5.0), and evidence folders named after their contents.

### Changed
- Evidence copies have a folder of their own, named after their contents (#198): `C:\Temp\IPU-Evidence` (new parameter `-EvidenceRoot`) with `Policy`, `IIS`, `Network` and `Printers` subfolders and a README that says the copies are unredacted. Before, all of them went to `C:\Temp\Tools\PolBackup`; the IIS, network and printer copies move. `-PolicyEvidenceRoot` now defaults to blank (= `EvidenceRoot\Policy`); a site that sets it keeps its policy evidence there. `LGPO.exe` stays in `C:\Temp\Tools`.

### Fixed
- Redacted reports no longer replace version numbers as if they were IPv4 addresses: version fields in the JSON, product versions in detection evidence (now written `<name> version <v>`) and version folders in paths stay readable; addresses, including UNC hosts, are still replaced (#194).
- Post-upgrade comparison: a scheduled task renamed only by its version or GUID (as some updaters do) is no longer reported missing (#196).
- Post-upgrade comparison: `AzureArcSetup` missing after an upgrade to Windows Server 2025 is INFO, not WARNING; Azure Arc Setup became a Feature on Demand in 2025 (#197).

### Security
- Named SQL Server instances and their instance ids are redacted in the Summary, SQL, service and port rows, live and with `-RedactExisting`; a real redacted report had shown one. Default instance names stay readable (#195).

## [4.5.0] - 2026-10-14

Cluster nodes and domain controllers become SPECIAL, network and print servers get the evidence needed to put them back by hand, and the review items are closed. The source is now built from parts; operators still run one file. `Merge-IPUAssessments.ps1` 1.1.0 ships with it.

### Changed
- Cluster nodes and domain controllers are no longer reported as BLOCKER; they are SPECIAL (#152). `-BlockDomainControllerIPU $false` still gives the full report with a WARNING for a domain controller.
- The assessment's source is kept in parts (`src/assessment/`, one per numbered section) and `build/Build-Script.ps1` joins them into `src/Windows-IPU-Readiness-Assessment.ps1`, which stays committed at the same path. CI checks that the built file matches its parts. Nothing changes for operators: still one `.ps1` from the Release page (ADR 0002, #151).

### Added
- **SPECIAL** status and verdict for servers that are not a standard in-place upgrade: cluster nodes and (with `-BlockDomainControllerIPU`, the default) domain controllers (#152). The report is short on purpose and says plainly "expensive and risky" for the project and the customer, lists the facts needed to choose a plan, the risks and the options to evaluate with Microsoft links. SA line, JSON (`Overall`, `Counts.SPECIAL`, `Special`) and the fleet overview (`Merge-IPUAssessments.ps1`: SPECIAL first, `Special` column) support it. Undecided cluster signals are MANUAL. Cluster and node names are redacted.
- Network (#149): each adapter now also shows IPv6 addresses, DNS suffix and search list, DNS registration, WINS, NetBIOS over TCP/IP, metric and VLAN (report, JSON `Snapshot.Adapters`). The post-upgrade comparison matches adapters by MAC address, since Setup can rename them, and lists every difference per adapter (a static adapter switched to DHCP or without its addresses is an ACTION). A network configuration copy (`ipconfig /all`, `route print`, `netsh interface ipv4 show config`, `netsh -c interface dump`, advanced adapter properties) is saved into the restricted evidence folder (`-EnableNetworkEvidence`, on by default); it is not redacted and not part of the report, so copy it off the server before the change.
- Print servers (#148): new `printers` check lists printers, the ports they use, drivers, port monitors and print processors. Third-party drivers (with the Windows Server 2025 Windows Update note), third-party port monitors and print processors, LPR ports and the LPD Service are WARNINGs. New slow check `printbackup` exports the print configuration with `PrintBrm -B` into the restricted evidence folder (`-EnablePrintBackup`, on by default; `-PrintBackupTimeoutMinutes`, 30), skipped as MANUAL when the drive lacks 1.5 x the size of `spool\drivers` + 1 GB. The post-upgrade comparison reports printers and ports that are gone (ACTION) and changed drivers (WARNING). Printer, share and port names and port host names are redacted.
- Windows activation in plain words per channel (#171). A KMS client shows the KMS host that activated it, whether it was found via DNS or set on the server, and the days until the activation must be renewed (WARNING under 30 days); "Not explicitly configured (DNS auto-discovery or not KMS)" is gone. MAK, AVMA, OEM and retail get their own text, e.g. "Licensed (MAK), activated permanently - no renewal needed". The KMS host name is redacted in shared copies.
- RDP Network Level Authentication in the Summary ("RDP access: GO, NLA on"; after the upgrade "NLA off (was on before the upgrade)" when it changed), as `Facts.Nla` in the JSON, and as an "RDP NLA" column in the fleet overview and servers CSV (`Merge-IPUAssessments.ps1` 1.1.0) (#174).
- Every dated fact table (upgrade paths, SQL matrix, end-of-support dates, removed/deprecated features, VMware Tools minimum, expected Windows changes, documentation links) has a source and a verification date in `$script:FactSources`; a test fails when one is older than six months (#132). All were checked on 2026-10-13.
- CI: the PowerShell 7 pester job fails when coverage of `src/*.ps1` drops below 85 % or a function has no executed command; tests added for the read-only helpers that had none (#127).
- `build/Sync-Skills.ps1` keeps the two vendored copies of the GitHub workflow skills (`.claude/skills` for Claude Code, `.agents/skills` for Codex) identical; CI fails when they differ (#129).

### Fixed
- The test suite passes in a normal, unelevated session; before, the tests after the first restricted folder failed in a cascade. A new CI job, `pester (unelevated)`, runs the whole suite as a standard local user (#126).
- Wording: defaults that come from one site are described as such (#131). `BlockDomainControllerIPU` is "site policy", not "company policy"; the merge script's `;` CSV separator is explained without naming a country. The defaults themselves (`da-DK`, the DC policy on, `;`) are unchanged, and the user guide shows how a site sets its own in a profile file. docs/checks.md no longer calls a domain controller a BLOCKER.
- Post-upgrade comparison: per-user services (e.g. CDPUserSvc) that exist only while a user is signed in, and ports whose service no longer starts automatically (e.g. SSDP Discovery, Function Discovery), are INFO instead of WARNING (#173).

### Security
- `-RedactExisting` now also replaces the first label of a KMS host name (`kms01` as well as `kms01.corp.example`), as the live run does. Found by a new test suite that runs a synthetic worst-case report with random names through the live JSON and HTML redaction and through `-RedactExisting`, and fails when any input value survives (#124).
- `Merge-IPUAssessments.ps1` (1.1.0) limits an output folder it creates to SYSTEM, Administrators and the current user, and warns when an existing output folder can be read by Everyone, Authenticated Users or Users: the overview combines findings from every server (#128).
- `-RedactExisting` now replaces file share names and descriptions; a live run had left share names readable in a redacted copy. A test fails when a new collector name source has no matching recovery rule. Servers are numbered `HOST-1..HOST-n` in the file names (#172).

## [4.4.0] - 2026-10-13

Fixes from a live run of four upgrades (Windows Server 2016 and 2019 to 2025). The build step, the new checks (print servers, network, SPECIAL) and the review items moved to 4.5.0.

### Added
- Recovery partition after C: (#161). Setup silently creates one when no recovery partition is big enough for the new WinRE, which blocks extending C: later. The pre-upgrade report warns when this is likely and the checklist shows `setup.exe /ResizeRecoveryPartition Disable`; a recovery partition after C: is reported with its number and the removal steps (`reagentc /disable` first). WinRE status from `reagentc /info` (read-only). New user-guide section "Recovery partition after an upgrade".

### Fixed
- Post-upgrade comparison (#158): a live run of four clean upgrades was ACTION from expected changes alone. Services now disabled (often by hardening) are a WARNING of their own; Microsoft start-type changes and removals (IKEEXT and NlaSvc now Manual, tiledatamodelsvc) are INFO; per-user services are compared without their random suffix; ports closed together with such a service are INFO; features removed or renamed by Microsoft (PowerShell 2.0, PowerShell ISE, Defender) are INFO, while .NET Framework 3.5 removed by the upgrade is a WARNING with the reinstall command. In Post mode, previous-upgrade evidence and MSI rollback leftovers are INFO and the upgrade-path row says "Now Windows Server 2025".
- RDP Network Level Authentication turned off between the pre- and post-upgrade run is now an ACTION (it had gone from on to off on four servers unnoticed). The snapshot records `Nla` and `PortOwners`; for older baselines NLA is read from the pre-upgrade RDP row (#158).
- `-RedactExisting` on a folder uses one placeholder map for all reports: a server keeps the same placeholder in its pre- and post-upgrade copy, different servers get different ones, and the placeholder is in the file name (`REDACTED-<time>-HOST-2-IPU-PostUpgrade.json`). Before, every copy said `HOST-1`, so a shared fleet overview could not tell the servers apart (#157).
- Group Policy as SYSTEM on Windows Server 2012 R2-2019: when gpresult answers "does not have RSoP data", the applied GPOs are read from the Group Policy service's own record in the registry (WMI filters are still checked in AD), with a row saying so. The computer's AD groups are listed even when no GPO list can be read. A live run on 2016 had lost the GPO list and AD groups before the upgrade (#160).
- An empty `-LgpoExe` now switches LGPO off with an INFO row. On Windows PowerShell it made the whole RDP/policy evidence check MANUAL. When gpresult cannot list the local policy, the report points to the LGPO backup only when the run makes one (#150).
- System File Checker output "a system repair is pending which requires reboot" is now a WARNING with reboot advice. It was reported as integrity violations (ACTION) with repair advice, although SFC had checked nothing (#159).

### Security
- Redaction now replaces custom AD group and account names in the RDP user-rights rows (`DOMAIN\Name [SID]`, names with spaces and full DNS domain names), and a domain name together with any DNS suffix. Built-in domain groups such as Domain Admins keep their name. A live run had shown custom group names in a redacted report; the smoke test now checks user-rights names too (#156).

### Decisions
- ADR 0002 supersedes ADR 0001: the source may be kept in parts that a build step joins into the single `.ps1` that SA runs, and CI tests the built file. Nothing changes for operators. Until the build step lands (#151) the script stays one file (#125).

### CI
- Pull requests now run the end-to-end smoke test on both Windows Server 2025 and 2022, not only after the merge. The repository is public, so the runners are free; the 2022-only redaction false alarm (#114) had reached `main` because pull requests skipped that image (#122).
- The release workflow now requires a green CI run for the push of the release commit to `main`: it waits while CI runs and refuses a failed, cancelled or missing run. v4.3.0 had been published from a commit whose CI run failed. A `dry_run` option does every check and builds the files without publishing (#121).
- A failed CI run for a push to `main` now opens or updates an issue "CI failed on main", with the commit. Until now only the weekly run did, so `main` stayed red unnoticed on two merges in a row (#123).
- The smoke test's redaction leak check failed on Windows Server 2022 although nothing leaked. A built-in Microsoft scheduled task there runs as an account named like an ordinary word, which matched product names such as "Windows Installer". The check now looks only for the accounts the script collects (service logon accounts and non-Microsoft task accounts). When a real leak is found, it reports the source and the report rows that hold it, with the name masked (#114).

## [4.3.0] - 2026-10-08

Findings and requests from a live run on Windows Server 2012 R2 (Windows PowerShell 4.0).

### Added
- Prerequisites check before anything is collected: PowerShell 4.0 or later, .NET Framework 4.5 or later and administrator rights. If one is missing, the run stops with a clear `FAILED` SA line and report text naming what is missing and what to do; a missing optional module is a MANUAL row naming the affected checks. CI checks `src/` against Windows Server 2012 R2 / Windows PowerShell 4.0 (#94).
- New check `fileshares`: shared folders with path, description and share permissions (default administrative shares left out); a share missing after the upgrade is an ACTION in the post-upgrade comparison (#95).
- The computer object's OU path in AD, in the summary ("AD location (OU)"), the Group Policy section and the JSON; the post-upgrade comparison reports a moved computer object (#99).
- `-RedactExisting <folder or report>` writes redacted copies of existing reports in seconds, without collecting anything; the originals are not changed (#101).
- The source OS end of extended support: an INFO row while supported, a WARNING observation (with a note on Extended Security Updates) once it has ended, and the patch-level row says why updates are old on an out-of-support source (#102).
- The *Target licensing* checklist item now says what the target release needs for the current activation channel (KMS client, MAK, AVMA, OEM, retail), instead of always showing the KMS host (#102).

### Changed
- "Status meaning" is shown right after the Summary, before the tables that use the statuses (#96).
- Report chapters open when they hold a finding to act on (WARNING and MANUAL too, not only BLOCKER and ACTION); a line explains the rule, *Expand all* / *Collapse all* buttons were added, and printing includes closed chapters (#97).
- A server that is not in a domain is called "Workgroup server (standalone)" with its workgroup name, instead of "Standalone server" (#98).

### Security
- Redaction now also replaces host names in any domain (except documentation and vendor sites), the bare names of service and scheduled-task accounts, GPO and WMI filter names, OU names in Group Policy link paths and `DC=` components. A live run had shown these in a redacted report. The smoke test checks the redacted output for leftover host and account names (#100).

## [4.2.0] - 2026-10-07

Improvements from the first live run of 4.1.0. `Merge-IPUAssessments.ps1` 1.0.4 ships with it.

### Security
- The `agents` check is named "Management agents (OpenText)"; a test keeps company and host names out of the repository now that it is public (#90).

### Added
- New check `grouppolicy`: applied and filtered GPOs with the reason, a WARNING for each GPO whose WMI filter depends on the Windows version, the computer's AD groups (nested included), and when Group Policy last applied (`-GroupPolicyMaxAgeDays`, default 7). Workgroup servers show local policy only; an unreachable domain is MANUAL. The post-upgrade comparison reports GPOs and groups that changed (#80).
- Recommendations can show the exact command (labelled Check or Change, with a copy button) and a link to the official documentation. First set: pending reboot, report folder permissions, RDP NLA (or "change the GPO" when set by policy), LBFO teams, C: free space, IIS backup, upgrade path, compatibility scan and Trend Micro products. The JSON results and the fleet findings CSV carry `Command` and `Link`; pattern files may add `Link` (#79). `Merge-IPUAssessments.ps1` 1.0.4.
- When IIS is installed, its configuration files are copied into a restricted evidence folder and ZIP (`-EnableIISConfigEvidence`, default on); the report shows the location and the SHA-256 of `applicationHost.config`, and flags shared configuration (#76).
- User Account Control status in plain words in the summary, the JSON facts and the snapshot; the post-upgrade comparison reports a change (#75).

### CI
- Pull requests run the smoke test on windows-2025 only; windows-2022 runs on main, weekly and on demand. A newer push cancels the older run (#85).

### Changed
- Security and monitoring tools without a driver (for example Nessus, NXLog) are observations to verify after the upgrade instead of planning warnings; tools with a driver (for example Sysmon) stay warnings and name the driver (#78).
- Report header: the counters link to the rows behind them. A check skipped by choice (for example the Setup compatibility scan without installation media) is a plain-language note that says what to do, instead of the "Not fully assessed" banner, which is now only for checks that failed, ran out of time or were not started (#77).

### Fixed
- Endpoint protection names the installed product: Trend Micro Deep Security Agent, Apex One and Vision One Endpoint Basecamp are separate rows, and the summary shows product and version. The built-in Defender for Endpoint sensor is no longer a WARNING when it is not onboarded and not running (#74).

## [4.1.0] - 2026-10-06

First tagged release. `Merge-IPUAssessments.ps1` 1.0.3 ships with it.

### Added
- Release workflow: a tag `vX.Y.Z` that matches the script version publishes a zip, the two scripts and `SHA256SUMS.txt`; a test keeps the header version, `$script:CollectorVersion` and the changelog in step (#19).
- Pull requests are labelled automatically from the branch name and changed paths, so release notes are grouped (#31).
- CI runs the end-to-end smoke test on Windows Server 2025 and 2022 images, pins images instead of `windows-latest`, and runs weekly on `main`; a failed weekly run opens an issue (#27).
- Optional site data files: `-PatternFile` adds, replaces or disables detection patterns and `-ProfileFile` sets site defaults for the settings (an argument still wins). All or nothing: a file that cannot be used is reported as `MANUAL` and the built-in values are used. Examples in `docs/examples/` (#32).
- Opt-in report redaction (`-RedactReport $true`): names, addresses, accounts, SIDs and certificate details become placeholders in the HTML and JSON; the JSON has `Redacted`; redacted files get a neutral name. Best effort (#30).
- Checks reference (`docs/checks.md`), result format description and JSON Schema (`docs/result-schema.md`, `docs/result-schema.json`), synthetic sample report (`docs/samples/`), and ADR 0001 (#16, #25, #26).
- Standard repository structure, CI, and collaboration files (#1, #3).
- Pester tests for `Merge-IPUAssessments.ps1` (#13).

### Changed
- HTML report accessibility: every table has a caption and column scopes, the checklist box reads as "open" to screen readers, collapsible sections show a keyboard focus outline, and the report follows the system dark mode. Contrast is tested (WCAG AA) in both themes (#28).
- WMI cmdlets replaced by CIM cmdlets (`Get-CimInstance`, `Invoke-CimMethod`); dates are read through one helper that accepts CIM and WMI formats (#18).
- Parameters are validated: thresholds and timeouts must be within sensible ranges, paths must be absolute, the media language must look like a culture name. Invalid values stop the script before it collects anything (#18).
- No silent `catch {}` remains: ignored optional failures are logged, and an incomplete log is flagged in the report (#18).
- `Normalize-Thumbprint` renamed to `ConvertTo-NormalizedThumbprint` (#18).
- Eight internal functions renamed to singular nouns (for example `Find-DetectionMatch`, `Register-AssessmentCheck`); the `ShouldProcess` lint rule is suppressed with a recorded reason (#29).

### Security
- Output folders the script creates are limited to SYSTEM and Administrators; the report warns when an existing output folder is readable by ordinary users. Opt out with `-RestrictOutputAcl $false` (#12).

### Fixed
- External tools (DISM, SFC, netsh, ...) that exit at once no longer lose their exit code on Windows PowerShell 5.1: processes are started through `System.Diagnostics.Process` instead of `Start-Process -PassThru`, and output is read without temp files (#66).
- `Merge-IPUAssessments.ps1` 1.0.2: CSV cells that start with `=`, `+`, `-`, `@`, tab or CR are prefixed with an apostrophe, so data from a server cannot run as an Excel formula (#41).
- `Merge-IPUAssessments.ps1` 1.0.1: the findings CSV no longer includes findings from an older, superseded result for the same server (#13).

## [4.0.1] - 2026-10-06

Fixes from the first live run and the 4.0.0 review (released as a script file only, before this repository).

### Added
- `param()` block: every setting is a parameter with a default, so SA runs the script unchanged.
- JSON result (`IPU-Assessment/1`) next to the HTML, for the fleet overview and as the post-upgrade baseline.
- Post-upgrade mode (`-AssessmentMode Post`) that compares against the pre-upgrade result.
- VMware guest readiness (VMware Tools 12.5.0 or later for 2025, certified vSphere versions).
- Optional Setup compatibility scan with the target media (`-TargetMediaPath`).
- Features removed or deprecated in the target release; non-Microsoft driver inventory; listening ports; non-Microsoft scheduled tasks; system and recovery partition free space.
- `Merge-IPUAssessments.ps1` 1.0.0: fleet overview from many JSON results.

### Changed
- One central detection pattern table for agents, AV/EDR, backup and workloads.
- AV/EDR detection by product name, service and filter driver (Trend Micro/TrendAI, Defender for Endpoint, CrowdStrike, SentinelOne, ...), with the reason when Defender status cannot be read.
- Sysmon and RDP NLA reported as observations; clearer "None detected" wording.
- Ignored errors are logged; `Recommendation` is a named parameter of `Add-Result`.

### Fixed
- `C:\Windows\Panther\setupact.log` is no longer counted as evidence of an earlier upgrade.
- Mount points and volume labels are shown again; OpenText SA and Operations agent names are recognised.
- Pending file rename operations show the file paths.

## [4.0.0]

Restructure of the 3.x script (released as a script file only).

### Changed
- Check registry and runner: each area is a registered check; a check that throws is reported as `MANUAL`, never as a clean result.
- One area map for the whole report; decision rules are pure functions with Pester tests.
- DISM and SFC run time-boxed inside one budget; a checkpoint report is written before the slow checks.
- Standard change checklist separated from findings; result kinds Finding, Observation, Checklist and Evidence.
- Upgrade path, edition, Exchange, SQL Server and NIC teaming rules checked against Microsoft documentation.

## [3.5.0]

Local Group Policy backup and RDP readiness. Superseded by 4.0.0.

[Unreleased]: https://github.com/JeanKadang/IPU-ReadinessAssessment/compare/v4.5.4...HEAD
[4.5.4]: https://github.com/JeanKadang/IPU-ReadinessAssessment/releases/tag/v4.5.4
[4.5.3]: https://github.com/JeanKadang/IPU-ReadinessAssessment/releases/tag/v4.5.3
[4.5.2]: https://github.com/JeanKadang/IPU-ReadinessAssessment/releases/tag/v4.5.2
[4.5.1]: https://github.com/JeanKadang/IPU-ReadinessAssessment/releases/tag/v4.5.1
[4.5.0]: https://github.com/JeanKadang/IPU-ReadinessAssessment/releases/tag/v4.5.0
[4.4.0]: https://github.com/JeanKadang/IPU-ReadinessAssessment/releases/tag/v4.4.0
[4.3.0]: https://github.com/JeanKadang/IPU-ReadinessAssessment/releases/tag/v4.3.0
[4.2.0]: https://github.com/JeanKadang/IPU-ReadinessAssessment/releases/tag/v4.2.0
[4.1.0]: https://github.com/JeanKadang/IPU-ReadinessAssessment/releases/tag/v4.1.0
