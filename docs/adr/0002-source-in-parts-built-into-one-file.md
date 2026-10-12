# ADR 0002: Keep the source in parts, build the single file SA runs

- **Status:** Accepted
- **Date:** 2026-10-12
- **Decided by:** maintainer (Micker71), on issue #125
- **Supersedes:** [ADR 0001](0001-single-file-script.md)

## Context

ADR 0001 kept the assessment as one hand-written file and set a trigger to revisit the decision at about
4,000 lines. `src/Windows-IPU-Readiness-Assessment.ps1` reached 4,243 lines in 4.3.0, and reviews of the
one file are heavy.

A second script is planned: a dedicated assessment for cluster nodes (#153). It must look and behave like
the main script (report, statuses, JSON, redaction, logging, prerequisites). With one hand-written file per
script, the second script would start as a copy and the two would drift apart.

What must not change: operators run one `.ps1` file through OpenText Server Automation (SA) ad-hoc
scripting. SA does not install modules on the target.

## Decision

Option 3 from ADR 0001: **keep the source in several files and let a build step join them into the single
file that SA runs.**

- The source lives in parts under `src/` (shared parts such as report, redaction, JSON, logging and
  prerequisites, plus the checks of each script). A manifest lists the parts and their order.
- A build script joins the parts into one `.ps1` per script. The output is reproducible: the same parts give
  the same file.
- CI builds first and runs every check (Pester, smoke, lint including the PowerShell 4.0 pass) against the
  **built** file, so the tests check exactly what operators run.
- The Release workflow publishes the built files with their SHA256 checksums.
- Operators see no change: download the `.ps1` from the Release page and run it through SA.

## Consequences

- Smaller files and smaller review diffs. Shared parts are fixed once and every script gets the fix in the
  next release.
- The cluster script (#153) is built from the same shared parts, so it has the same design by construction.
- A built file must never be edited by hand. CI fails when the built output is edited or out of date.
- There is one more moving part (the build step) and maintainers need to know it exists; `docs/build.md`
  explains it in plain words.
- Until the build step lands (#151), `src/Windows-IPU-Readiness-Assessment.ps1` stays one file. The first
  split is mechanical (along the existing numbered sections, no code changes) and is proven by a built file
  that matches the previous single file.
