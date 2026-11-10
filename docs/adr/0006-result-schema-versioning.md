# ADR 0006: The result file has a version, and the Post run compares only what both runs read

- **Status:** Accepted (recorded afterwards, 2026-11-10; `IPU-Assessment/1` since 2026-10-06)
- **Decided by:** maintainers; written down from `docs/result-schema.md` (*Compatibility rules*), the code and issues #306 and #361, for issue #264. To be confirmed when this record is merged.

## Context

The JSON result is read by two things the server run does not control: the fleet overview (many servers, many script
versions) and the post-upgrade run, which uses the server's own Pre result as its baseline, weeks later, possibly
after a script update.

## Decision

1. **The format has a version in the file:** `Schema` is `IPU-Assessment/1`. A reader rejects any other value.
2. **Additive changes keep version 1.** A new field is optional, the schema is updated in the same change, and
   readers ignore what they do not know. Removing or renaming a field, or changing its type or meaning, needs
   `IPU-Assessment/2`, and the fleet overview and the Post run must then handle both versions or say which they need.
3. **The Post run reads the Pre result of the same server** from the report folder (`<Computer>-IPU-Assessment.json`).
4. **It compares only what both runs read.** A snapshot list that is missing from the baseline (an older version, or
   a failed read) or that this run could not read is left out and named in a MANUAL row (`BaselineCoverage`,
   `CurrentCoverage`). It is never read as an empty list: that would report everything as lost or new.
5. **A redacted result is refused as a baseline** (ADR 0005).

## Consequences

- A new snapshot list needs an owner and a coverage rule (the check-data tests enforce owners).
- A baseline from an older version still works and compares what it has.
- Version 2 is a deliberate, documented step, not a side effect of a field change.
