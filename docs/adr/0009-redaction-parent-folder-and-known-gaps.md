# ADR 0009: The parent of the output folder is not checked; three redaction gaps stay best effort

- **Status:** Accepted (2026-11-23, issue #451)
- **Decided by:** maintainers; proposed with the fix for #451 and open for the repository owner (JeanKadang) to confirm on the pull request.

## Context

Four advisories were fixed in 4.9.0. Issue #451 kept what they left open: whether the output-folder check should
also look at the parent folder, and three kinds of name that redaction still misses.

## Decision

1. **The parent folder is not checked.** The default folder is `C:\Temp\IPU-Assessment`, and `C:\Temp` is normally a
   folder every user may create folders in. A check that refuses an ordinary-user parent would stop every run with
   the default settings. It would also gain little: the folder itself is checked when it exists (junction, owner)
   and created with a restricted access list when it does not, and a parent cannot be made trustworthy by the
   script, because it does not own it. The user guide tells an operator who needs more to give `-ReportDirectory`
   a folder under a parent only administrators control.
2. **Three kinds of name stay best effort** ([ADR 0005](0005-redaction-is-best-effort.md)), because no rule finds
   them without also hiding ordinary text:
   - the name of another server in free text with no `\`, URL or full host name around it;
   - application and service display names that contain a customer name;
   - a domain the run does not know.

   Names the run collects itself are still replaced exactly, and the read-through of the copy before sharing is the
   control for the rest.

## Consequences

- Not checking the parent leaves a window for a user who can replace a restricted folder in a shared parent
  between runs. The next run catches a replacement (owner, junction), so it can read nothing it should not.
- A new rule for one of the three kinds needs a pattern that does not hit ordinary words, and a test; until then
  they are documented, not defects.
