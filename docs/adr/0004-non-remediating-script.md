# ADR 0004: The assessment only reads; it never changes the server

- **Status:** Accepted (recorded afterwards, 2026-11-10; in force since the first version, 2026-10-06)
- **Decided by:** maintainers; written down from the hard rule in `AGENTS.md`, the script header (`.SAFETY`) and the code, for issue #264. Confirmed by the repository owner (JeanKadang), 2026-11-12.

## Context

The script runs on production servers, normally as LocalSystem through OpenText Server Automation (SA), before a
change window. If an assessment could change a server, nobody could say afterwards what was assessed and what was
altered, and a readiness check would need the same approval as the change it prepares.

## Decision

**The script is non-remediating. It installs, removes and reconfigures nothing.**

- The only external tools it starts are read-only forms: `DISM /ScanHealth`, `sfc /verifyonly`, and `LGPO.exe` with
  `/b` (backup) and `/parse` only, never `/g` or `/m`. It never queries `Win32_Product`, which is known to trigger
  Windows Installer consistency checks.
- Commands in a recommendation are shown, never run. Each says whether it only checks (`Check`) or changes
  something in the change window (`Change`).
- Auditing, logging and policies are not switched on. Where a change would help (for example SMB1 auditing), the
  report recommends it as a separate step.
- The side effects that remain are listed in the script header and are the only ones allowed: report, log, JSON and
  evidence files; with `-TargetMediaPath`, an ISO is mounted and dismounted again, and Setup's compatibility scan
  creates `C:\$WINDOWS.~BT`. The scan never starts an upgrade.

## Consequences

- Fixing what the report finds is the operator's job, outside this script. A new idea that needs a change becomes a
  recommendation, or a separate tool.
- The rule is in `AGENTS.md` and applies to every change, including assistants' changes.
- The script is safe to run again, and to run on a server before approval of the change.
