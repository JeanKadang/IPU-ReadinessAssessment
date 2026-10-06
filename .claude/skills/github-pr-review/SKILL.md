---
name: github-pr-review
description: Use when reviewing someone else's pull request, checking out a contributor's branch to test it, or handling a PR that came from a fork — before approving, requesting changes, or leaving line comments.
---

# Reviewing pull requests

Merging conventions live in `github-hygiene`; this skill covers the review that
happens before a merge is even on the table. The goal of a review is a decision —
approve, request changes, or comment — backed by evidence that you actually ran or
read the thing.

## Read the PR before reading the diff

```bash
gh pr view <N>                     # title, body, linked issue, checks, reviewers
gh pr diff <N>                     # the change itself
gh pr checks <N>                   # CI state, per leg
```

Three questions, in order:

1. **Does it match a filed issue?** If the PR closes nothing and fixes something
   real, the issue is missing — say so (see `github-issue-first`). If it closes an
   issue, does it do what the issue asked, and only that? Read the full issue body;
   a closing reference is not proof its acceptance criteria passed.
2. **Is the change bigger than its stated scope?** Unrelated refactors bundled
   into a fix are the most common reason a PR should be split.
3. **How was it verified?** The PR body should say. "Tests pass" without a new
   test on a bugfix PR means the bug can silently return.

## Review the closing issue as part of the PR

For every issue the PR proposes to close, evaluate every acceptance criterion.
Record the review in this shape:

| Criterion | Evidence | Result |
|---|---|---|
| Exact criterion text or concise identifier | Diff, test, CI run, document, screenshot, or reproduction | Met / Unmet / Unevaluated |

The PR may carry `Closes #N` only when every in-scope criterion is **Met**. If a
criterion is Unmet or Unevaluated:

- request removal of the closing keyword or replacement with `Refs #N`;
- keep the issue open;
- do not check the criterion; and
- identify the missing evidence or work precisely.

A sound partial PR can still be approved after it changes `Closes` to `Refs`.
Green CI proves only what the CI jobs exercised; it does not automatically prove
each issue criterion. Scope removal requires an explicit issue decision and
rationale before approval, not a checkbox made to look delivered.

## Run it, don't just read it

For anything beyond a typo, check the branch out. This is the difference between
a review and a skim.

```bash
gh pr checkout <N>                 # works for fork PRs too — sets up the remote
<run the repo's test suite>
git checkout <default-branch>      # switch back: `gh pr checkout` left you on the PR's branch
```

`gh pr checkout` puts a contributor's code on your machine. Treat it as untrusted:
read the diff *before* running the test suite or any build script, and look
specifically at changes to CI workflows, `package.json` scripts, hooks, and
anything that executes at install time. A PR that edits `.github/workflows/` is a
privilege change, not a code change — review it as such.

## Leaving the review

```bash
gh pr review <N> --approve  -b "<why it's good to go>"
gh pr review <N> --request-changes -b "<what must change, specifically>"
gh pr review <N> --comment  -b "<observations, no verdict>"
gh pr comment <N> -b "<general discussion, not a review verdict>"
```

**Pick the verdict deliberately** — `--comment` is not a soft "request changes".
A PR sitting with only comments looks unreviewed to the author.

| Verdict | Use when |
|---|---|
| Request changes | Correctness bug, security issue, missing test for a fixed bug, breaks a documented contract, scope needs splitting, or `Closes #N` remains while an in-scope criterion is unmet/unevaluated |
| Comment | Questions you need answered before deciding; observations that don't block |
| Approve | You'd merge it as-is. Approving "with nits" means the nits are genuinely optional |

**Don't block on style a linter should catch.** If formatting keeps coming up in
reviews, the fix is a linter in CI, not a reviewer repeating themselves — file it.

**Separate blocking from non-blocking explicitly** in the body. Prefix optional
remarks with `nit:` so the author knows what actually holds up the merge.

**Anything you find that is out of scope for this PR becomes an issue**, not a
review comment demanding it be fixed here. Review scope is the diff in front of
you; `github-issue-first` handles the rest.

## Approving is not merging

Approval and merge are separate decisions. Never merge straight off your own
approval — `github-hygiene`'s rule (ask the maintainer once per batch) still
applies. On a repo with branch protection, approve and let the author or
maintainer merge.

**Never approve your own PR to satisfy a required-review rule**, and never use an
admin override to merge past one. If you are the only reviewer available, say the
PR is unreviewed rather than manufacturing an approval.

## Fork PRs

Contributions from forks behave differently and the differences bite:

- **The fork's `GITHUB_TOKEN` is read-only.** Workflows triggered by
  `pull_request` from a fork cannot write comments, push, or read secrets — a
  workflow that works on branch PRs may appear broken on fork PRs. That is
  expected, not a defect in the contributor's PR.
- **Secrets are not available** to fork PR workflows. Any job needing them will
  skip or fail; don't ask the contributor to "fix" it.
- **Never "fix" this with `pull_request_target`** plus a checkout of the PR head.
  That combination runs untrusted code with a write token and repo secrets — it is
  the standard GitHub Actions exfiltration path. See `github-security-response`.
- **Maintainers can push to the fork branch** if the contributor left "allow edits
  by maintainers" on — useful for a last-mile fix, but push a commit rather than
  rewriting their history.
- **Ask for a rebase, don't rebase for them**, unless the branch is stale enough
  that CI can't run.

Submitting a PR from a fork, syncing it with upstream, or responding to review on your own PR is `github-contributing`; this section covers reviewing someone else's fork PR, not submitting your own.

## Common mistakes

| Mistake | Fix |
|---|---|
| Approving without checking the branch out | `gh pr checkout <N>` and run the suite for anything non-trivial |
| Running a contributor's test suite before reading the diff | Read first — install scripts and workflow edits execute code |
| `--comment` when you mean "this can't merge" | Use `--request-changes`; comments read as "reviewed, no objection" |
| Blocking on formatting | Add a linter to CI and file the issue |
| Demanding out-of-scope fixes in review | File an issue; keep the review to the diff |
| Approving own PR to clear branch protection | Say it's unreviewed instead |
| Treating `Closes #N` as proof the issue is complete | Evaluate every criterion and cite evidence; use `Refs #N` for partial work |
| Treating green CI as evidence for criteria it never exercised | Map each criterion to a specific test, diff, document, or reproduction |
| Treating a fork PR's failing secret-dependent job as the contributor's bug | Fork PRs get no secrets and a read-only token by design |
| Reaching for `pull_request_target` to give fork CI more power | Don't — it's the classic exfiltration path |
