# ADR 0005: Redaction is opt-in, best effort, and comes with a key

- **Status:** Accepted (recorded afterwards, 2026-11-10; redaction added 2026-10-06, key file in 4.5.3)
- **Decided by:** maintainers; written down from the user guide (*Sharing a report: redaction*), the parameter help and issues #100, #101, #211, #329, for issue #264. Confirmed by the repository owner (JeanKadang), 2026-11-12.

## Context

A report describes a server in detail: host and domain names, addresses, accounts, SIDs, certificates, group policy
and OU names. People need to share reports outside the team (a vendor, a forum). No set of rules can recognise every
name in free text, so complete anonymisation cannot be promised.

## Decision

1. **Opt-in.** `-RedactReport` redacts the HTML and JSON of a run; `-RedactExisting` writes redacted copies of
   reports that already exist, without collecting anything. The original files stay.
2. **Best effort, said so.** Names the script collected itself are replaced exactly; other names are found by
   patterns. The script's messages (`-RedactExisting` prints it) and the user guide say that redaction is best effort and that the copy must be read before it is shared.
3. **Stable placeholders** (`HOST-1`, `IP-3`, ...) keep a redacted report readable.
4. **A key file** (`DO-NOT-SHARE-REDACTION-KEY-<time>.csv`, `-WriteRedactionKey`, on by default) maps each
   placeholder to its original. It stays in the team; only `REDACTED-*` files are shared.
5. **The log and the evidence files** are not redacted, because they are needed for troubleshooting and for the
   change. The log gets a separate redacted copy to share; the evidence folder is never shared.
6. **A redacted result cannot be the post-upgrade baseline** (`Redacted: true`); the Post run says so.

## Consequences

- A leak is a defect to fix with a test, not a broken promise; the smoke test checks the redacted files for the
  accounts the run collected (service logon accounts and non-Microsoft task accounts).
- Keep an unredacted Pre run for the comparison and redact a second run or only the copies.
- Anything newly collected that holds a name needs a redaction rule (a question on the pull request template).
