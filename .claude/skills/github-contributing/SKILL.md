---
name: github-contributing
description: Use when submitting a pull request to a repository you don't maintain — forking, syncing a fork with upstream, creating a PR as an outside contributor, or responding to review feedback on your own PR in someone else's repo — before running gh repo fork, git push to a fork, or gh pr create against an upstream repository.
---

# Contributing to someone else's repository

Every other skill in this set assumes maintainer authority — merge, tag, release.
This one is the other side: you're proposing a change to a repo you don't own.
The target repo's own `CONTRIBUTING.md`, issue templates, and conventions govern,
not this repository's. Read them before opening anything.

That includes problems you notice along the way. With only read access, a bug
you hit or a doc error you spot is reported through that repo's own channels,
not through `github-issue-first`, whose Preconditions stop at repos you can
write to or triage.

## Forking and staying in sync

```bash
gh repo fork <owner>/<repo> --clone --remote      # creates your fork, clones it,
                                                    # and wires up both remotes
cd <repo>
git remote -v                                      # origin = your fork, upstream = the source
```

If `gh repo fork` wasn't used to clone, wire the remotes by hand:

```bash
git remote add upstream https://github.com/<owner>/<repo>.git
```

Before starting new work, sync your fork's default branch with upstream — don't
build on a stale base:

```bash
git fetch upstream
git checkout main
git merge upstream/main       # or: git rebase upstream/main, if you haven't pushed main
git push origin main
```

In these commands `main` stands for the default branch. Upstream and your fork
may call it something else (`trunk`, `master`); look it up with
`gh repo view <owner>/<repo> --json defaultBranchRef -q .defaultBranchRef.name`
and use that name wherever `main` appears here.

**Sync before every new branch, not just once.** A fork that drifts weeks behind
upstream turns an easy PR into a painful rebase later.

## Branching and submitting

Branch from your synced fork's default branch, same conventions as working in your own repo
(see `github-hygiene`'s PR flow for the general shape) — but the commit and PR
body conventions are the **target repo's**, not this one's. Don't impose `Refs #N`
/ `Closes #N` discipline on a repo that doesn't use it; check its `CONTRIBUTING.md`
and existing merged PRs first.

```bash
git checkout -b fix/<short-description>
# ... make the change, commit ...
git push -u origin fix/<short-description>
gh pr create --repo <owner>/<repo> --title "..." --body "..."
```

`gh pr create` without `--repo` targets the fork itself if run from inside it and
`origin` is the fork — pass `--repo <owner>/<repo>` explicitly, or `--base` and
let `gh` infer the upstream base, to avoid accidentally opening the PR against
your own fork's main instead of upstream.

**Draft PRs** (`gh pr create --draft`) signal work-in-progress or "review the
approach before I finish" — use one when you want early feedback rather than a
merge-ready review. Mark it ready with `gh pr ready <N>` when done.

## What you don't control

You have no merge authority and usually no repo secrets. Concretely:

- **Your fork PR's `GITHUB_TOKEN` is read-only** in the target repo's workflows,
  and secrets are not available to them — a CI job that needs a secret will skip
  or fail on your PR, and that's expected, not something to "fix" by asking a
  maintainer to change the workflow. See `github-pr-review`'s "Fork PRs" section
  for the maintainer's-side view of the same mechanic.
- **You can't merge your own PR** into a repo you don't have write access to, and
  shouldn't ask to be added as a maintainer just to self-merge — that defeats the
  review the process exists for.
- **A maintainer may push to your PR branch** if you left "Allow edits by
  maintainers" checked (the default) — expect commits from them on your branch,
  and `git pull` before pushing again to avoid a diverging history.

## Responding to review on your own PR

The short version: verify each point technically before implementing it, push back with evidence when
a suggestion is wrong, and never make a change you can't explain. Reply to each
thread and resolve it only once the change is pushed.

Push additional commits to the same branch rather than force-pushing over review
history, unless the maintainer's conventions ask for a clean/squashed history
before merge — check their `CONTRIBUTING.md` or ask.

## Common mistakes

| Mistake | Fix |
|---|---|
| Building new work on a stale fork main | `git fetch upstream && git merge upstream/main` before every new branch |
| `gh pr create` opens against your own fork instead of upstream | Pass `--repo <owner>/<repo>` explicitly |
| Asking a maintainer to "fix" a fork PR's failing secret-dependent job | Fork PRs get no secrets and a read-only token by design — expected, not a bug |
| Imposing this repo's `Refs #N`/`Closes #N` convention on the target repo | Follow the target repo's own `CONTRIBUTING.md` and observed PR conventions |
| Force-pushing over a maintainer's review comments or their pushed commits | Push additional commits; `git pull` first if they pushed to your branch |
| Asking for maintainer access to self-merge | Let the maintainer merge — review authority isn't yours to grant yourself |
