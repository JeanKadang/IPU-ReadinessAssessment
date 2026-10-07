# Contributing

## Before your first commit

Set up Git once (install, name and email, GitHub sign-in): [docs/git-setup.md](docs/git-setup.md). Without it your
commits show the wrong author.

## Workflow

1. Open (or pick) an issue first. Every change starts from an issue.
2. Branch from a fresh `main`: `fix/…`, `feat/…`, `docs/…`, `ci/…`, `test/…`, `release/x.y.z`. Never commit to `main`.
3. Commit with conventional prefixes (`fix:`, `feat:`, `docs:`, `ci:`, `test:`, `release:`). Subject 50 characters or fewer; the body says why.
4. Run the tests before pushing:
   ```powershell
   Invoke-Pester .\tests -Output Detailed
   ```
5. Open a pull request using the template. Reference the issue with `Refs #N`. Release notes are built from PR labels: a workflow adds them automatically (`feat/` branch → `enhancement`, `fix/` → `bug`, changed paths → `documentation`, `testing`, `tooling`; see `.github/labeler.yml`). Check them and add or remove labels by hand when they don't fit; the workflow never removes a label.
6. Merge with a merge commit once CI is green and the other maintainer has reviewed.

## What CI runs

| Job | Runs on | What it does |
|---|---|---|
| `pester (Windows PowerShell 5.1)`, `pester (PowerShell 7)` | windows-2025 | All Pester tests; coverage on PowerShell 7 |
| `smoke (<shell>, windows-2025)`, `smoke (<shell>, windows-2022)` | windows-2025 on pull requests; both Windows Server images on pushes to `main`, the weekly run and manual runs | The real script end to end (Pre, Post, redacted, site data files), JSON checked against the schema |
| `lint (PSScriptAnalyzer)` | windows-2025 | Fails on any warning |
| `label` (workflow *Label pull requests*) | ubuntu-latest | Adds labels to each pull request |
| `release` (workflow *Release*) | ubuntu-latest | Publishes a release: **Actions → Release → Run workflow** on `main` with the version (for example `4.1.0`), or push a tag `v4.1.0`. The version must match the script header and CHANGELOG |
| `notify (scheduled run failed)` | ubuntu-latest | Only for the weekly run on `main` (Mondays): opens or updates the issue "Scheduled CI run failed" |

The repository is private, so Actions minutes are limited and Windows minutes count double. Pull requests therefore skip the windows-2022 smoke jobs, and a newer push cancels the run still in progress on the same branch. Job names are stable, so a ruleset can require them (require only the jobs that run on pull requests). When GitHub retires or adds a Windows Server image, change
the `smoke` matrix in `.github/workflows/ci.yml` and this table in the same pull request.

## Conventions

- Scripts live in `src/`, tests in `tests/`, docs in `docs/`.
- Every new check needs a Pester test and a named recommendation.
- Do not commit assessment output, hostnames, credentials or other host data.

## Working with Claude Code

The repo ships the team's GitHub workflow so your AI assistant follows the same rules as everyone else:

- `.claude/skills/`: the `github-*` skills (issue first, PR flow, releases, reviews, security response). Source of truth is [DOC-GitHub-Practice-Skills](https://github.com/JeanKadang/DOC-GitHub-Practice-Skills); change them there, then re-copy.
- `.claude/settings.json`: enables the shared plugins (`superpowers`, `code-review`, `code-simplifier`). Claude Code asks you to approve them on first open.
- `AGENTS.md` (imported by `CLAUDE.md`): commands, hard rules and workflow summary, read by Claude Code, Codex and Copilot.

Keep personal preferences in your own user settings or `.claude/settings.local.json` (git-ignored).

## Reporting security problems

See [SECURITY.md](SECURITY.md). Do not use public issues.
