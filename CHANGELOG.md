# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Checks reference (`docs/checks.md`), result format description and JSON Schema (`docs/result-schema.md`, `docs/result-schema.json`), synthetic sample report (`docs/samples/`), and ADR 0001 (#16, #25, #26).
- Standard repository structure, CI, and collaboration files (#1, #3).
- Pester tests for `Merge-IPUAssessments.ps1` (#13).

### Changed
- WMI cmdlets replaced by CIM cmdlets (`Get-CimInstance`, `Invoke-CimMethod`); dates are read through one helper that accepts CIM and WMI formats (#18).
- Parameters are validated: thresholds and timeouts must be within sensible ranges, paths must be absolute, the media language must look like a culture name. Invalid values stop the script before it collects anything (#18).
- No silent `catch {}` remains: ignored optional failures are logged, and an incomplete log is flagged in the report (#18).
- `Normalize-Thumbprint` renamed to `ConvertTo-NormalizedThumbprint` (#18).
- Eight internal functions renamed to singular nouns (for example `Find-DetectionMatch`, `Register-AssessmentCheck`); the `ShouldProcess` lint rule is suppressed with a recorded reason (#29).

### Security
- Output folders the script creates are limited to SYSTEM and Administrators; the report warns when an existing output folder is readable by ordinary users. Opt out with `-RestrictOutputAcl $false` (#12).

### Fixed
- `Merge-IPUAssessments.ps1` 1.0.2: CSV cells that start with `=`, `+`, `-`, `@`, tab or CR are prefixed with an apostrophe, so data from a server cannot run as an Excel formula (#41).
- `Merge-IPUAssessments.ps1` 1.0.1: the findings CSV no longer includes findings from an older, superseded result for the same server (#13).
