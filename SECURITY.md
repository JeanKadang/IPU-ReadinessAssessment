# Security policy

## Reporting a vulnerability

Do **not** open a public issue for a vulnerability.

This repository is private and GitHub private vulnerability reporting is not
available on it. Contact the maintainer directly ([@JeanKadang](https://github.com/JeanKadang))
and include the affected file or check, what an attacker could do, and steps to
reproduce. Never include real credentials or host data in a report.

## Scope

The assessment script runs with administrative rights on servers. In scope:
command or path injection, unsafe handling of collected data, and anything that
changes host state during a read-only assessment.

## Supported versions

No tagged release exists yet. Only `main` is supported.
