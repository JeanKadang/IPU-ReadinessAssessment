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
6. Merge with a merge commit once CI is green. A review by the other maintainer is welcome, but not required.

## What CI runs

| Job | Runs on | What it does |
|---|---|---|
| `pester (Windows PowerShell 5.1)`, `pester (PowerShell 7)` | windows-2025 | All Pester tests; coverage on PowerShell 7 |
| `smoke (<shell>, windows-2025)`, `smoke (<shell>, windows-2022)` | windows-2025 on pull requests; both Windows Server images on pushes to `main`, the weekly run and manual runs | The real script end to end (Pre, Post, redacted, site data files), JSON checked against the schema |
| `lint (PSScriptAnalyzer)` | windows-2025 | Fails on any warning. Also checks `src/` against Windows Server 2012 R2 / Windows PowerShell 4.0 (`PSScriptAnalyzerSettings.PS4.psd1`): a command, type or syntax that does not exist there fails the job |
| `label` (workflow *Label pull requests*) | ubuntu-latest | Adds labels to each pull request |
| `release` (workflow *Release*) | ubuntu-latest | Publishes a release: **Actions → Release → Run workflow** on `main` with the version (for example `4.1.0`), or push a tag `v4.1.0`. The version must match the script header and CHANGELOG, and the CI run for the push of that commit to `main` must have succeeded: the workflow waits for a running one (up to 45 minutes) and refuses a failed, cancelled or missing one (#121). Tick *dry_run* to do every check and build the files without publishing; a dry run may start from any ref |
| `notify (scheduled run failed)` | ubuntu-latest | Only for the weekly run on `main` (Mondays): opens or updates the issue "Scheduled CI run failed" |

Pull requests currently skip the windows-2022 smoke jobs (a cost saving from when the repository was private, #85), and a newer push cancels the run still in progress on the same branch. Job names are stable, so the ruleset on `main` requires them by name: only the jobs that run on pull requests are required (pester on both shells, smoke on windows-2025, lint). When GitHub retires or adds a Windows Server image, change
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
