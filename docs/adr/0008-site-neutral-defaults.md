# ADR 0008: Defaults and wording stay neutral; a site keeps its own values in data files

- **Status:** Accepted (recorded afterwards, 2026-11-10; decided on issue #131, 2026-10-13)
- **Decided by:** a maintainer, on issue #131 (option 1: kept the defaults, neutralised the wording); recorded here for issue #264. Confirmed by the repository owner (JeanKadang), 2026-11-12.

## Context

The repository is public and general-purpose, but it began as one organisation's tool. Some defaults and words came
from that site (`NumberCultureName` defaulting to `da-DK`, a domain controller treated as a blocked upgrade, the
word "company policy", a CSV separator explained by Danish regional settings). No company, host or customer name may
be in the repository (`AGENTS.md`; the test in `tests/core/repository.Tests.ps1`, from #90).

## Decision

1. **Existing defaults stay, so existing SA jobs that pass no arguments behave the same.** This was decided for the
   culture and the domain controller policy; the later site policies (`BlockVdiIPU`, `PkiAllowedTargets`) follow
   the same pattern.
2. **They are described neutrally** as site policy or project values, never as one organisation's rule, and the
   documentation shows how a site sets its own.
3. **Site values live outside the script:** a profile file (`-ProfileFile`, #32) for settings and a pattern file
   (`-PatternFile`) for detection patterns. An argument still wins over the profile. A file that cannot be used is a
   MANUAL row and nothing from it is applied.

## Consequences

- A site can run the same script as everyone else and set its policy in one file.
- Option 2 on #131 (move the site to a profile file, then switch to neutral defaults in a minor release with a
  *Changed* entry in the CHANGELOG) was not chosen and stays open for the owner. Changing a default changes the
  behaviour of existing SA jobs, so it would be an announced change.
- New site-specific wording or names are caught in review and by the repository test.
