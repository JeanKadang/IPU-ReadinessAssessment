---
name: github-hygiene
description: Use when merging PRs, closing issues, reconciling acceptance criteria, decomposing large work into sub-issues, or cleaning up branches at the end of a session — before running gh pr merge, gh issue close, or any merge step.
---

# GitHub Hygiene

Conventions for PR flow, closure, and cleanup. Follow this instead of re-deriving from git history. Issue filing/triage is covered by the separate `github-issue-first` skill — file the issue first, then start work here. Cutting a release, tagging, branch protection, and milestones are `github-releases` — merge here, then ship there. Reviewing a PR before it reaches the merge decision is `github-pr-review`; multi-maintainer board setup is `github-projects`; a release that contains a security fix goes through `github-security-response` first.

This skill's PR/merge ceremony assumes a repo that warrants it. For a
clearly low-stakes repo (no CI, no branch protection, no code that gets
built/deployed/tested), see `github-issue-first`'s "Scaling ceremony to
repo risk" section before applying the full flow below by default.

## The traceability chain

Every change follows one path, and each link is enforced by the tool rather than by memory:

```
issue (#N, priority + category labels, milestone)
  → gh issue develop <N>         # branch created AND linked to the issue
  → PR with "Refs #N"            # links work without promising completion
  → acceptance criteria verified # each criterion has concrete evidence
  → change "Refs" to "Closes"    # only now may merge close the issue
  → milestone                    # groups the release
  → auto-generated release notes # built from the merged PRs
```

Skipping a link doesn't fail loudly — it just quietly returns traceability to human memory. `gh issue develop` is the one most often skipped and the one that buys the most.

## Acceptance criteria are closure gates

Acceptance criteria belong to the issue's implementation work. A completed issue
means every in-scope criterion was evaluated, supported by concrete evidence, and
checked before closure. A green PR, merged code, elapsed time, sunk effort, or a
release deadline does not substitute for that evaluation.

Before approving a merge that would close an issue:

1. Read every closing issue body and identify its acceptance criteria.
2. Map each criterion to evidence in the diff, tests, CI, documentation, or a
   reproducible verification result.
3. Record a concise completion comment linking that evidence.
4. Update satisfied checkboxes with a newline-preserving body file:
   `gh issue edit <N> --body-file <file>`. Do not round-trip multiline Markdown
   through a PowerShell string array; it can flatten the issue body.
5. If any in-scope criterion is unmet or unevaluated, keep it unchecked and use
   `Refs #N` in the PR. The PR may merge, but do not assume the issue stays open.
6. Only when every in-scope criterion passes, change `Refs #N` to `Closes #N`
   and proceed with the ordinary merge gate.

If a criterion is no longer required, record the scope decision and rationale on
the issue before merge. Mark it explicitly as removed or superseded; never check
it as though it was delivered. Deferred work gets a linked follow-up issue and
the original issue remains open unless its recorded scope is formally changed.

`Refs #N` avoids a PR-body closing keyword; it does not guarantee the issue
stays open when GitHub has a connected development branch. After every merge,
immediately audit the linked issue state and body. If it is closed while any
in-scope acceptance criterion is unchecked, unmet, or unevaluated, reopen it
immediately and record the reason. For work that spans the PR merge, either use
this audit-and-reopen flow or track the PR-scoped work in a child issue and leave
the release-spanning parent unconnected. Every PR-scoped criterion still needs
evidence before merge.

Closing as duplicate, invalid, or not planned is different from completed: use
the appropriate state reason and a human-readable explanation; do not check
criteria that were not delivered.

Audit for completed closures with unchecked task boxes:

```bash
gh issue list --state closed --limit 1000 --json number,title,body,stateReason \
  --jq '.[] | select(.stateReason=="COMPLETED") | select(.body | test("(?m)^\\s*- \\[ \\]")) | "#\(.number)\t\(.title)"'
```

PowerShell:

```powershell
gh issue list --state closed --limit 1000 --json number,title,body,stateReason `
  --jq '.[] | select(.stateReason=="COMPLETED") | select(.body | test("(?m)^\\s*- \\[ \\]")) | "#\(.number)\t\(.title)"'
```

## PR flow

- One branch per issue: `fix/…`, `feat/…`, `ci/…`, `test/…`, `docs/…`, `release/x.y.z`. Branch from a fresh `git pull`ed main — never commit on main.
- `main` throughout this skill means the repo's default branch. Look it up with `gh repo view --json defaultBranchRef -q .defaultBranchRef.name` and substitute it where it differs.
- Prefer `gh issue develop <N> --name <branch> --base main --checkout` to start work: it creates the branch and links it to the issue. Start the PR body with `Refs #N`; replace it with `Closes #N` only after the acceptance gate passes. When falling back to `git checkout -b`, add the same `Refs #N` link manually.
- Commit style: conventional (`fix:`, `feat:`, `ci:`, `test:`, `release:`), subject ≤ 50 chars, body says why. PR body states what changed and how it was verified.
- Wait for CI green on **every** matrix leg (e.g. windows + ubuntu) before merge — `gh pr checks <N> --watch`. Never merge on a red or pending check, and never bypass required checks with an admin merge.
- **Merging needs the maintainer's explicit approval — ask once per batch** ("merge these N when green?"). The maintainer sometimes merges from the GitHub UI mid-session: before acting on a PR, `git pull` and re-check `gh pr view <N>` state rather than assuming.
- **A closing keyword needs acceptance approval too.** Do not merge a PR carrying
  `Closes #N` until the closure-gate procedure above passes for issue #N.
- **Auto-merge is the maintainer's switch, not the agent's.** GitHub's auto-merge merges a pull request the moment its required checks pass, so enabling it is the merge approval. Turn it on only when the maintainer has said to, only on a pull request whose acceptance criteria already have recorded evidence, and never on one carrying `Closes #N` unless every in-scope criterion is met: an auto-merged `Closes` closes the issue with no chance to run the closure gate first. Otherwise leave it off, merge by hand after approval, and audit the issue afterwards. Check whether the repo allows it with `gh api repos/{owner}/{repo} --jq .allow_auto_merge`; enabling it on a pull request is `gh pr merge <N> --auto` with the repo's merge flag.
- Merge with the repo's configured method. Check `gh repo view --json mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed`, use the matching flag (`gh pr merge <N> --merge`, `--squash`, or `--rebase`), and when several are allowed follow the repo's existing history. If `gh repo view --json deleteBranchOnMerge` reports false, delete the merged remote branch yourself.

### When CI goes red

Never re-run a red job hoping it turns green. Read the failure first:

```bash
gh run list --branch <branch> --limit 5
gh run view <run-id> --log-failed          # only the failing steps
```

- **Genuine failure** (test, lint, build): fix it on the same branch with its own commit; the fix rides the existing PR, no new issue needed — it is the same unit of work.
- **Flake** (network blip, runner timeout, race): `gh run rerun <run-id> --failed`. If the same job flakes twice, that is a real defect in the test suite — file it (`github-issue-first`) rather than re-running a third time.
- **Infrastructure/config break** (missing secret, expired token, action removed): file it as its own issue; it will hit every future PR, not just this one.

## Solo vs multi-contributor tracking

- **Solo repo (default)**: no Projects boards — milestones + labels are the whole tracking system; a board is unmaintained overhead.
- **When the repo gains (or expects) additional contributors**, upgrade the scaffolding — board setup, fields, automation and the rest of the multi-maintainer checklist live in the `github-projects` skill; use it rather than improvising a board here. The parts that belong to this skill either way:
  - A **ruleset** on main: require the CI status checks and at least one PR review; contributors never push to main. See `github-releases`.
  - Native blocked-by/blocks relations plus `Depends on: #N` body lines, so pick-up order is visible.
  - CODEOWNERS for review routing; CONTRIBUTING.md pointing at the conventions in this skill.
  - Assign every issue at triage — unassigned means unowned.

## Sub-issues for any large-scope issue, solo repo included

Use native GitHub sub-issues whenever a single issue's work will span
multiple PRs or sessions — not only when contributors need to pick up
children independently. In a solo repo, the reason isn't parallelization,
it's **resumability and blast-radius control**: if a session ends mid-work,
the next one reads the parent issue's sub-issue list and knows exactly
which units are done, in-flight, or untouched, instead of re-deriving state
from chat history or a half-finished diff. If a bad batch ships, it's
isolated to one sub-issue and one PR, not tangled into a giant one-shot
change.

Trigger: a mechanical or repetitive task decomposes naturally into batches
(one per chapter, module, service, file group, etc.) and doing it all in one
PR would be unreviewable or too risky to revert as a unit.

**Mechanics:**

```bash
# 1. File one issue per batch (same title/label/assignee conventions as
#    github-issue-first), then link each as a native sub-issue of the parent:
id=$(gh api repos/{owner}/{repo}/issues/<child-number> --jq .id)
gh api -X POST repos/{owner}/{repo}/issues/<parent-number>/sub_issues -F sub_issue_id="$id"

# 2. Verify the link:
gh api repos/{owner}/{repo}/issues/<parent-number>/sub_issues --jq '.[].number'
```

**Gotcha:** the endpoint wants the child's internal `id` (a large opaque
number), not its `number` (the small one everyone reads/types) — fetch it
first. And it must be sent as a *typed* field with `-F` (capital), not `-f`
(lowercase, which sends it as a string and gets rejected with `Invalid
property /sub_issue_id: "..." is not of type integer`).

Keep a **checklist in the parent issue's body** alongside the native links —
`- [x] #84 -- batch name (16 files) -- done, PR #90` — since the native
sub-issue UI shows open/closed state but not which PR closed it; the
checklist is what a human skimming the issue actually reads. Update it each
time a batch merges. Edit it through a newline-preserving body file, not an
inline `--body "..."` string (same hazard as the closure-evidence step above):

```bash
gh issue view <parent> --json body --jq .body > parent-body.md
# edit parent-body.md: tick the finished child, add the PR number
gh issue edit <parent> --body-file parent-body.md
```

PowerShell:

```powershell
gh issue view <parent> --json body --jq .body | Set-Content -Encoding utf8 parent-body.md
# edit parent-body.md: tick the finished child, add the PR number
gh issue edit <parent> --body-file parent-body.md
```

Close each child issue individually as its PR merges (`Closes #<child>` in
the PR body does this automatically); leave the parent open until every
child is closed.

## Cleanup checklist (end of session / after release)

- `git checkout main && git pull && git fetch --prune` — local branch listings lie until pruned; verify remote state with `gh api repos/{owner}/{repo}/branches` before reporting leftover branches.
- Delete merged local branches: `git branch --merged main | grep -v main | xargs -r git branch -d`.
- Working tree clean, everything pushed, no open PRs left unmentioned.
- Run the closed-with-unchecked-boxes audit query (above, under "Acceptance
  criteria are closure gates") against any issue closed this session — the
  PR template's checkbox catches it at merge time for one PR, but this
  catches anything closed a different way (bulk triage, manual `gh issue
  close`) that skipped the reminder.

## Common mistakes

| Mistake | Fix |
|---|---|
| Trusting `git branch -r` for remote state | `git fetch --prune` first, or query the API |
| Merging own PR without asking | Ask once per batch; check whether the maintainer already merged it |
| Treating merged PR or green CI as proof every criterion passed | Evaluate each criterion, record evidence, and keep the issue open until all in-scope criteria pass |
| Checking a removed or deferred criterion as delivered | Record the scope decision; link follow-up work; never falsify completion |
| Letting `Closes #N` auto-close an unevaluated issue | Use `Refs #N` until the acceptance gate passes; reopen immediately if it closes early |
| Committing on main before branching | Branch first; if it happens: branch from the commit, then `git reset --hard origin/main` on main |
| `gh api -f sub_issue_id=<id>` rejected with "not of type integer" | Use `-F` (capital), not `-f` — sub_issue_id must be sent as a typed integer, not a string |
| Linking a sub-issue by its `number` instead of its `id` | The sub-issues endpoint wants the internal `id` — `gh api repos/{owner}/{repo}/issues/<number> --jq .id` first |
| Re-running a red CI job without reading the log | `gh run view <id> --log-failed` first; rerun only a diagnosed flake |
