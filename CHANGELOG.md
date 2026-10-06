# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
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
