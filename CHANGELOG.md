# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Standard repository structure, CI, and collaboration files (#1, #3).
- Pester tests for `Merge-IPUAssessments.ps1` (#13).

### Security
- Output folders the script creates are limited to SYSTEM and Administrators; the report warns when an existing output folder is readable by ordinary users. Opt out with `-RestrictOutputAcl $false` (#12).

### Fixed
- `Merge-IPUAssessments.ps1` 1.0.1: the findings CSV no longer includes findings from an older, superseded result for the same server (#13).
