# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Security
- Redaction now also replaces host names in any domain (except documentation and vendor sites), the bare names of service and scheduled-task accounts, GPO and WMI filter names, OU names in Group Policy link paths and `DC=` components. A live run had shown these in a redacted report. The smoke test checks the redacted output for leftover host and account names (#100).

### Added
- Prerequisites check before anything is collected: PowerShell 4.0 or later, .NET Framework 4.5 or later and administrator rights. If one is missing, the run stops with a clear `FAILED` SA line and report text naming what is missing and what to do; a missing optional module is a MANUAL row naming the affected checks. CI checks `src/` against Windows Server 2012 R2 / Windows PowerShell 4.0 (#94).

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

[Unreleased]: https://github.com/JeanKadang/IPU-ReadinessAssessment/compare/v4.2.0...HEAD
[4.2.0]: https://github.com/JeanKadang/IPU-ReadinessAssessment/releases/tag/v4.2.0
[4.1.0]: https://github.com/JeanKadang/IPU-ReadinessAssessment/releases/tag/v4.1.0
