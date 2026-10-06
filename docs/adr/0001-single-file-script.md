# ADR 0001: Keep the assessment as one PowerShell file

- **Status:** Accepted
- **Date:** 2026-10-06
- **Decided by:** maintainer, on issue #25

## Context

`src/Windows-IPU-Readiness-Assessment.ps1` runs on each server as an OpenText Server Automation (SA)
ad-hoc script. SA delivers and runs a single script file; it does not install modules on the target.
The file is about 2,700 lines, organised in numbered sections (parameters, detection patterns, core,
decision rules, checks, report, main).

Three options were considered:

1. **Keep one file.** No change to how SA runs it.
2. **Module only.** Cleanest code, but breaks SA ad-hoc delivery.
3. **Module with a build step** that concatenates the module into the single file SA runs.

## Decision

Option 1: keep one file.

## Consequences

- SA usage stays exactly as it is: paste or attach one file, no build artifact to manage.
- Tests keep loading the script in library mode (`IPU_ASSESSMENT_LIBRARY_ONLY=1`) and dot-sourcing it.
- Readability is kept through the numbered sections, the single area map, pure decision functions and
  the detection-pattern table. Review diffs of the one file can be large; keep pull requests small.
- Data that changes more often than code (detection patterns, site policy) may move to optional data
  files with built-in defaults (#32), so the single file still runs on its own.
- Revisit this decision (option 3) if the file passes roughly 4,000 lines or reviews become hard to do.
  A change of decision needs a new ADR that supersedes this one.
