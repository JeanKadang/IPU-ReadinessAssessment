# Architecture decision records

Short records of decisions that were argued and settled, so the same debate does not start again. Each is about half
a page: context, decision, consequences. A new record gets the next number; a decision that changes is not edited, it
is superseded by a new record.

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-single-file-script.md) | Keep the assessment as one PowerShell file | Superseded by 0002 |
| [0002](0002-source-in-parts-built-into-one-file.md) | Source in parts, built into one file | Accepted |
| [0003](0003-end-of-life-lookup-architecture.md) | End-of-life lookups: offline snapshot, evaluated centrally | Accepted |
| [0004](0004-non-remediating-script.md) | The assessment only reads; it never changes the server | Accepted |
| [0005](0005-redaction-is-best-effort.md) | Redaction is opt-in, best effort, and comes with a key | Accepted |
| [0006](0006-result-schema-versioning.md) | The result file has a version; the Post run compares only what both runs read | Accepted |
| [0007](0007-failures-are-manual.md) | A failure is reported as MANUAL, never as a clean result | Accepted |
| [0008](0008-site-neutral-defaults.md) | Defaults and wording stay neutral; a site keeps its own values in data files | Accepted |

Records 0004 to 0008 were written afterwards (2026-11-10, issue #264) from rules and code that were already in force.
