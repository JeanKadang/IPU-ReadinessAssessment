# Project guidance for AI coding assistants

Read by Claude Code (via `CLAUDE.md`), OpenAI Codex and GitHub Copilot. Edit this file, not `CLAUDE.md`.

## What this repo is

A read-only Windows Server in-place upgrade (IPU) readiness assessment. The script that runs on each server is
`src/Windows-IPU-Readiness-Assessment.ps1`. Two more scripts run on an analysis machine, never on a server:
`src/Merge-IPUAssessments.ps1` (fleet overview from the result files) and `src/Get-IPUEolStatus.ps1` (end-of-life
status from the shipped `src/eol-snapshot.json`). All three are built from parts (below). Pester tests are in `tests/`.
See `README.md` and `docs/user-guide.md`.

## Commands

```powershell
# Tests (Pester 5 or newer; CI pins the version in ci.yml). Tests dot-source the script in library mode; nothing is collected.
Invoke-Pester .\tests -Output Detailed
# Skip the tests that start real processes (tagged Integration):
Invoke-Pester .\tests -Output Detailed -ExcludeTagFilter Integration
# The CI checks (lint, tests, smoke test) in one command, at the pinned tool versions:
pwsh ./build/Invoke-Local.ps1 -Task Lint,Test,Smoke
```

If the machine enforces signed scripts, start the session with `pwsh -ExecutionPolicy Bypass`
(process scope only). Never change the machine-wide execution policy.

## Hard rules

- **The script must stay non-remediating.** No installs, removals or configuration changes. DISM `/ScanHealth` and SFC `/verifyonly` only; `LGPO.exe` only with `/b` and `/parse`. No `Win32_Product`.
- **Windows PowerShell 4.0 compatibility.** The target hosts run Windows PowerShell, not PowerShell 7. Avoid newer syntax and cmdlets without a fallback.
- **One file for SA, source in parts.** Operators run one `.ps1` from OpenText Server Automation. Decided in [ADR 0002](docs/adr/0002-source-in-parts-built-into-one-file.md) and [ADR 0003](docs/adr/0003-end-of-life-lookup-architecture.md): all three scripts in `src/` are built. Edit the parts (`src/assessment/`, `src/merge/`, `src/eol/`; order in each `manifest.txt`), run `build/Build-Script.ps1` (for the other two scripts with `-Manifest` and `-OutputPath`, see `docs/build.md`), and commit the parts together with the rebuilt script. Never edit a built file by hand; CI (`Build-Script.ps1 -Check`, three times) fails when one does not match its parts. `src/assessment/25-eol-core.ps1` is shared by all three.
- **Failures stay visible.** A check that errors must report `MANUAL`; never turn an error into a clean result.
- **New decision logic is a pure function with a Pester test.** Keep system access out of `Get-*Decision` style functions.
- **No host data in the repo.** No real hostnames, credentials, report output or customer names in code, tests or docs.
- Line endings: `.ps1` is CRLF, ASCII only (see `.editorconfig`, `.gitattributes`).

## Workflow (GitHub)

The repo follows the GitHub workflow skills in `.claude/skills/` (source of truth:
`JeanKadang/DOC-GitHub-Practice-Skills`). In short:

1. **Issue first.** File a labelled (one of P0-P3 plus a category), assigned issue with acceptance criteria and a milestone before changing anything.
2. **One branch per issue**, created with `gh issue develop <N> --name <type>/<N>-<slug> --base main --checkout`. Never commit to `main`.
3. **Conventional commits**, subject 50 characters or fewer, body says why. End with the co-author trailer your tool requires.
4. **PR body starts with `Refs #N`.** Use `Closes #N` only after every acceptance criterion has evidence.
5. **CI must be green** (`gh pr checks`) before merge. Merge with `gh pr merge <N> --merge`. A ruleset on `main` enforces this: changes go through a pull request, the PR checks must pass, and force-push and deletion are blocked. Reviews are encouraged but not required.
6. **Security findings** that are exploitable never go in a public issue; report them privately through the Security tab (see `SECURITY.md`).

| Task | Skill |
|---|---|
| Notice a bug or gap | `github-issue-first` |
| Merge, close issues, clean branches | `github-hygiene` |
| Review a PR | `github-pr-review` |
| Release, milestones, rulesets | `github-releases` |
| Board changes | `github-projects` |
| Security event | `github-security-response` |
| Full repo audit | `github-repo-review` |

## Plugins

`.claude/settings.json` enables `superpowers`, `code-review` and `code-simplifier` from the official
marketplace. Claude Code asks you to approve them the first time you open the repo. Personal preference plugins
belong in your own user settings, not here.

## Agent skills

### Issue tracker

GitHub Issues through the `gh` CLI, with this repo's issue rules on top. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default triage roles, used next to the P0-P3 and category labels. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` at the root and `docs/adr/`. See `docs/agents/domain.md`.
