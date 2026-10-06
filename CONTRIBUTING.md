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
5. Open a pull request using the template. Reference the issue with `Refs #N`. Label the PR; release notes are built from PR labels.
6. Merge with a merge commit once CI is green and the other maintainer has reviewed.

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
