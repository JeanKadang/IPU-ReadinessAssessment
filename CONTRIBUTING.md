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

## Where a new test goes

The tests mirror the source parts, so a change and its test sit side by side (#254). Put a new `Describe` in the file
for its topic, or start a new file in the folder:

| You changed | Add the test to |
|---|---|
| `30-core.ps1`, `70-main.ps1` (runner, helpers, output, SA line) | `tests/core/` |
| `20-detection-patterns.ps1`, `40-decision-rules.ps1` (a pure decision function) | `tests/decision-rules/<topic>.Tests.ps1` |
| `50-checks.ps1` (a check body) | `tests/checks/<chapter>.Tests.ps1`, the chapter of the check in `docs/checks.md`; it runs on the fake server in `tests/checks/FakeServer.ps1` |
| `60-report.ps1` (HTML, JSON) | `tests/report/` |
| Redaction | `tests/redaction/` |
| The post-upgrade comparison or the Post run | `tests/post-upgrade/` |
| `src/merge/`, `src/eol/` | `tests/Merge-IPUAssessments.Tests.ps1`, `tests/Eol.Tests.ps1` |

A new test file starts like the others in its folder: the header comment, the `param()` with its attributes, and
`BeforeAll { . (Join-Path $PSScriptRoot '..\TestSetup.ps1') }` (in `tests/checks/`: `FakeServer.ps1`). Paths to the
repository go two levels up: `Join-Path $PSScriptRoot '..\..\docs\checks.md'`. Pester finds every `*.Tests.ps1`
under `tests/`, so nothing else needs to change.

## Pull requests from outside

This project has two maintainers, Jean and Micker71, and builds and maintains its own code. Ideas and pull requests
from outside are welcome and get read, but we do not promise a merge or a timeline, and we do not ask a contributor to
rework a pull request or to carry follow-up work.

When an outside pull request has something we want, a maintainer builds it on a branch in this repository. The
contributor's commit stays in the history, so the credit stays with them, and the original pull request is closed with
a thank-you once ours is merged. Anything that touches the hard rules in `AGENTS.md` (read-only, no network access from
the assessed server, no host data) is changed to fit them, or left out.

For a larger idea, open an issue first and say what you would like to see; that is easier for us to act on than a
finished change.

## What CI runs

| Job | Runs on | What it does |
|---|---|---|
| `pester (unelevated)` | windows-2025 | All Pester tests with Windows PowerShell 5.1 as a temporary standard local user (no admin token), through a scheduled task (`build/Invoke-UnelevatedTests.ps1`, CI only). Fails if the run was elevated after all (#126) |
| `pester (Windows PowerShell 5.1)`, `pester (PowerShell 7)` | windows-2025 | All Pester tests; coverage on PowerShell 7, which fails below a floor of 85 % of `src/*.ps1` commands or when a function in `src/` has no executed command (#127). Raise the floor in `ci.yml` as coverage grows |
| `pester (strict-mode finder)` | windows-2025 | All Pester tests with Windows PowerShell 5.1 under `Set-StrictMode -Version 2` (`build/Invoke-CiTests.ps1 -StrictModeFinder`, #256). A finder, not a gate: it never fails and is not a required check. Each failing test is a warning annotation; a real defect becomes its own issue. The assessment itself never runs in strict mode |
| `smoke (<shell>, windows-2025)`, `smoke (<shell>, windows-2022)` | Both Windows Server images, on every pull request, push to `main`, weekly run and manual run (#122) | The real script end to end (Pre, Post, redacted, site data files), JSON checked against the schema |
| `lint (PSScriptAnalyzer)` | windows-2025 | First checks that `src/Windows-IPU-Readiness-Assessment.ps1` is exactly the build of its parts (`build/Build-Script.ps1 -Check`, see [docs/build.md](docs/build.md)). Then checks that the two copies of the workflow skills are identical (`build/Sync-Skills.ps1 -Check`, #129). Fails on any warning. Also checks `src/` against Windows Server 2012 R2 / Windows PowerShell 4.0 (`PSScriptAnalyzerSettings.PS4.psd1`): a command, type or syntax that does not exist there fails the job |
| `label` (workflow *Label pull requests*) | ubuntu-latest | Adds labels to each pull request |
| `release` (workflow *Release*) | ubuntu-latest | Publishes a release: **Actions → Release → Run workflow** on `main` with the version (for example `4.1.0`), or push a tag `v4.1.0`. The version must match the script header and CHANGELOG, and the CI run for the push of that commit to `main` must have succeeded: the workflow waits for a running one (up to 45 minutes) and refuses a failed, cancelled or missing one (#121). Tick *dry_run* to do every check and build the files without publishing; a dry run may start from any ref |
| `gate` (workflow *Closure gate*) | ubuntu-latest | Weekly (Monday) and on demand: lists issues closed as completed that still have unchecked task boxes (`build/Find-UncheckedClosedIssue.ps1`, #263) and keeps one issue, "Closed issues with unchecked criteria", up to date with them. The issue closes itself when the list is empty. Issues closed as not planned are ignored. When it lists one of yours: tick the box if the work is done, reopen the issue, or move the open item to a new issue and tick it with a link |
| `notify (failed run on main)` | ubuntu-latest | For the weekly run and for every push to `main` (#123): when a job failed, opens or updates the issue "CI failed on main" (push) or "Scheduled CI run failed" (weekly run) |

Pester and PSScriptAnalyzer are installed by `build/Install-CiModule.ps1` at the versions pinned in `ci.yml`. It tries three times, five seconds apart, and writes one log line per attempt, so a truncated download from the PowerShell Gallery no longer turns a required check red (#141).

A newer push cancels the run still in progress on the same branch. Job names are stable, so the ruleset on `main` requires them by name: pester on both shells, smoke on both shells and both images, and lint. When GitHub retires or adds a Windows Server image, change
the `smoke` matrix in `.github/workflows/ci.yml` and this table in the same pull request.

## Release checklist

CI covers Windows PowerShell 5.1 and PowerShell 7 on Windows Server 2022 and 2025. It has **no PowerShell 4.0** (Windows
Server 2012 R2), which the script supports. The PowerShell 4.0 lint profile (`PSScriptAnalyzerSettings.PS4.psd1`) finds
commands, types and syntax that do not exist there, but not differences in behaviour (for example .NET 4.5 ZIP handling,
`ConvertTo-Json` depth, CIM). A self-hosted 2012 R2 runner is not advisable on a public repository, so one step is manual:

1. `CHANGELOG.md`, the script header version and the version you give the Release workflow agree.
2. CI is green on `main` for the commit you release.
3. **PowerShell 4.0 check, by hand, before every release that changes `src/`:** on a Windows Server 2012 R2 test VM
   (`$PSVersionTable.PSVersion` shows 4.0), copy the repository or the release zip and run
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build\Invoke-SmokeTest.ps1`. If the smoke script itself
   does not run on 4.0 (it was written for CI), run the assessment directly instead:
   `.\src\Windows-IPU-Readiness-Assessment.ps1 -AssessmentMode Pre -RunDISMScanHealth $false -RunSFCVerifyOnly $false`,
   then check that the SA result line says `SUCCEEDED`, the HTML opens, and the log has no `ERROR` lines.
4. Put the result in the release pull request: the PowerShell version, the Windows build, and either the smoke script's
   summary line or the SA result line (no host names; use a test VM).
5. Run the Release workflow with *dry_run* ticked first, then for real.

## Conventions
- Scripts live in `src/`, tests in `tests/`, docs in `docs/`.
- **Edit the assessment in its parts**, `src/assessment/*.ps1`, then run `pwsh ./build/Build-Script.ps1` and commit both the parts and the rebuilt `src/Windows-IPU-Readiness-Assessment.ps1`. Never edit the built file by hand: CI fails when it does not match its parts. See [docs/build.md](docs/build.md).
- Every new check needs a Pester test and a named recommendation.
- Do not commit assessment output, hostnames, credentials or other host data.

## Dated facts

Section 4 of the assessment (and the feature list in section 2) holds facts that Microsoft or a vendor can change:
supported upgrade paths, the SQL Server matrix, end-of-support dates, removed and deprecated features, the VMware Tools
minimum, the changes Windows makes during an upgrade, and the documentation links. `$script:FactSources` in
`src/assessment/40-decision-rules.ps1` names the source of each table and the day it was last checked.

A test fails when a check is older than six months (the weekly CI run then opens an issue). To re-verify a table: open
its source, update the table if the facts changed (with a test for any new behaviour), and set `Verified` to the day you
checked. Bump the date only after reading the source.

## Working with Claude Code

The repo ships the team's GitHub workflow so your AI assistant follows the same rules as everyone else:

- `.claude/skills/` (read by Claude Code) and `.agents/skills/` (read by OpenAI Codex): the same `github-*` skills (issue first, PR flow, releases, reviews, security response), kept identical. Source of truth is [DOC-GitHub-Practice-Skills](https://github.com/JeanKadang/DOC-GitHub-Practice-Skills): change them there, then copy both with `pwsh ./build/Sync-Skills.ps1 -Source <clone>\<skills folder>` on a branch and open a PR. Never edit one copy by hand: the lint job runs `build/Sync-Skills.ps1 -Check` and fails when the copies differ (#129).
- `.claude/settings.json`: enables the shared plugins (`superpowers`, `code-review`, `code-simplifier`). Claude Code asks you to approve them on first open.
- `AGENTS.md` (imported by `CLAUDE.md`): commands, hard rules and workflow summary, read by Claude Code, Codex and Copilot.

Keep personal preferences in your own user settings or `.claude/settings.local.json` (git-ignored).

## Reporting security problems

See [SECURITY.md](SECURITY.md). Do not use public issues.
