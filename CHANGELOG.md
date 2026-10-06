# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Standard repository structure, CI, and collaboration files (#1, #3).
- Pester tests for `Merge-IPUAssessments.ps1` (#13).

### Changed
- WMI cmdlets replaced by CIM cmdlets (`Get-CimInstance`, `Invoke-CimMethod`); dates are read through one helper that accepts CIM and WMI formats (#18).
- Parameters are validated: thresholds and timeouts must be within sensible ranges, paths must be absolute, the media language must look like a culture name. Invalid values stop the script before it collects anything (#18).
- No silent `catch {}` remains: ignored optional failures are logged, and an incomplete log is flagged in the report (#18).
- `Normalize-Thumbprint` renamed to `ConvertTo-NormalizedThumbprint` (#18).

### Security
- Output folders the script creates are limited to SYSTEM and Administrators; the report warns when an existing output folder is readable by ordinary users. Opt out with `-RestrictOutputAcl $false` (#12).

### Fixed
- `Merge-IPUAssessments.ps1` 1.0.1: the findings CSV no longer includes findings from an older, superseded result for the same server (#13).
