# Security policy

## Reporting a vulnerability

Do **not** open a public issue, pull request or discussion for a vulnerability.

Report it privately through GitHub: open the repository's **Security** tab and choose
**Report a vulnerability** ([direct link](https://github.com/JeanKadang/IPU-ReadinessAssessment/security/advisories/new)).
Only the maintainers can see the report.

Include:

- the affected file, check or parameter, and the version (`CollectorVersion` in the report or JSON);
- what an attacker could do, and what access they need first;
- steps to reproduce.

Never include real credentials, host names, reports or other host data. Use placeholders.

## What happens next

1. A maintainer acknowledges the report, aiming for within a week.
2. The fix is developed in a private security advisory, not in public issues or pull requests.
3. A patched release is published, and the advisory is published with it. It names the affected versions and
   the fixed version, and credits you unless you ask not to be named.

## Supported versions

Only the **latest release** gets security fixes. This matches the README: take the script from the
[latest release](https://github.com/JeanKadang/IPU-ReadinessAssessment/releases/latest), not from `main`.

| Version | Supported |
|---|---|
| Latest release | Yes |
| Older releases | No: upgrade to the latest release |
| `main` between releases | No: may hold unreleased changes |

## Scope

The assessment script runs with administrative rights (usually as SYSTEM) on servers. In scope:

- command or path injection;
- unsafe handling of collected data, including report, log and evidence file permissions;
- redaction that leaves names, addresses or accounts in a report created with `-RedactReport` or `-RedactExisting`;
- anything that changes host state during the read-only assessment;
- the fleet merge script (`Merge-IPUAssessments.ps1`), including formula injection in its CSV files.

Out of scope: findings that need administrator rights on the server already, and bugs inside the third-party tools
the script calls (DISM, SFC, LGPO.exe, Setup); report those to their vendors.
