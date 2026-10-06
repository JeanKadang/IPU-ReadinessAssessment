# Contributing

## Workflow

1. Open (or pick) an issue first. Every change starts from an issue.
2. Branch from a fresh `main`: `fix/…`, `feat/…`, `docs/…`, `ci/…`, `test/…`, `release/x.y.z`. Never commit to `main`.
3. Commit with conventional prefixes (`fix:`, `feat:`, `docs:`, `ci:`, `test:`, `release:`). Subject 50 characters or fewer; the body says why.
4. Run the tests before pushing:
   ```powershell
   Invoke-Pester .\tests -Output Detailed
   ```
5. Open a pull request using the template. Reference the issue with `Refs #N`. Label the PR; release notes are built from PR labels.
6. Merge with a merge commit once CI is green and the other maintainer has reviewed.

## Conventions

- Scripts live in `src/`, tests in `tests/`, docs in `docs/`.
- Every new check needs a Pester test and a named recommendation.
- Do not commit assessment output, hostnames, credentials or other host data.

## Reporting security problems

See [SECURITY.md](SECURITY.md). Do not use public issues.
