# ADR 0007: A failure is reported as MANUAL, never as a clean result

- **Status:** Accepted (recorded afterwards, 2026-11-10; in force since 2026-10-06, extended in #242, #306 and #360)
- **Decided by:** maintainers; written down from `AGENTS.md`, the check runner and issues #242, #306 and #360, for issue #264. To be confirmed when this record is merged.

## Context

A readiness report is trusted for what it does not flag. If a query fails and the check reports OK, zero or an empty
list, the server looks ready when it was never looked at.

## Decision

**When the script could not look, the result says so (`MANUAL`); it never turns an error, a timeout or missing data
into OK, 0 or "none found".**

- Inside a check every error stops the check (`$ErrorActionPreference = 'Stop'`). The runner catches it and writes
  a MANUAL row, *Check did not complete*, so the area shows as not fully assessed.
- A slow check that does not fit the time budget is recorded as skipped with a MANUAL row.
- A check that reads another check's data is not run when that check failed; it is recorded as skipped with a
  MANUAL row, *Check not run*.
- A read that is allowed to fail (`-ErrorAction SilentlyContinue`) says in a comment why absence is normal there,
  and a test keeps it that way. Anything else that fails is a MANUAL row with the error.
- `MANUAL` ranks above `OK` in the overall status (`SPECIAL`, `BLOCKER`, `ACTION`, `WARNING`, `MANUAL`, `OK`), so a
  server with an unread area cannot read as OK.
- The decision (what a result means) is a pure function with a test; reading the system is kept out of it.

## Consequences

- More MANUAL rows, and a MANUAL overall status, on servers where a read fails. This is intended.
- A new check that reads system state needs a failure path and a test for it.
- The SA line counts checks that left a gap (`NotCompleted`) separately from checks switched off (`Skipped`).
