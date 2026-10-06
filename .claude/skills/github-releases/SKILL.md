---
name: github-releases
description: Use when cutting a release, tagging a version, configuring branch protection or rulesets, or creating/closing milestones — before running git tag, gh api .../rulesets, or any release step.
---

# GitHub Releases

Conventions for milestones, branch protection, and cutting a release. Issue filing/triage is `github-issue-first`; PR flow and the acceptance-criteria closure gate are `github-hygiene` — file the issue and merge the PR there, then use this skill to ship it. Reviewing a PR before it reaches the merge decision is `github-pr-review`; multi-maintainer board setup is `github-projects`; a release that contains a security fix goes through `github-security-response` first.

## Milestones

- **Attach at filing time, not just at scoping.** Every `gh issue create` (from `github-issue-first`) should leave the issue with a milestone before moving on — an issue with no milestone is as incomplete as one with no priority label. Check what exists first (next bullet); if nothing fits yet, create one rather than leaving the issue unbucketed.
- **Check what exists before creating one**: `gh api "repos/{owner}/{repo}/milestones?state=all"`. The repo may have thematic milestones already (e.g. "Reliability Hardening"); attach to the existing bucket rather than minting a competing `vX.Y.Z` one. Two schemes in one repo is worse than either.
- Absent any existing scheme, group each planned release's issues under a milestone named `vX.Y.Z`. A batch of related findings that isn't yet tied to a specific release version can use a short thematic name instead (e.g. "Naming Consistency") — rename or fold it into a `vX.Y.Z` milestone once a release actually scopes it.
- Attach with `gh issue edit <N> --milestone "<title>"` — including already-closed issues that ship in that release.
- Close the milestone right after the release publishes: `gh api -X PATCH repos/{owner}/{repo}/milestones/<id> -f state=closed`.

## Rulesets (protecting main)

Throughout this skill `main` means the repository's default branch. If yours is
named differently, find it with `gh repo view --json defaultBranchRef -q
.defaultBranchRef.name` and use that name in the commands.

**Rulesets supersede classic branch protection.** They stack (several can apply to
one branch), support bypass actors, and can be scoped by name pattern. Prefer them
for anything new; a repo already on classic branch protection works fine, just
don't run both schemes against the same branch.

### Check the plan first — this is gated

**Branch protection of any kind requires a public repo, or GitHub Pro/Team/Enterprise
on a private one.** On a free-plan private repo both endpoints refuse:

```
403  Upgrade to GitHub Pro or make this repository public to enable this feature.
```

That applies to rulesets *and* classic branch protection alike. Verify before
recommending or scripting either:

```bash
gh api repos/{owner}/{repo}/rulesets    # 403 = unavailable on this repo's plan
```

If it 403s, say so plainly rather than filing an issue the maintainer cannot act
on without paying. On a free private repo, required checks are advisory: CI still
runs and still reports, but nothing *enforces* green-before-merge, so merge
discipline (see `github-hygiene`'s PR flow) is the only control there is. That is
worth stating in a review, but as a constraint, not a defect.

**`gh ruleset` is read-only** — it can inspect, not create:

```bash
gh ruleset list
gh ruleset view <id>
gh ruleset check main          # which rules would apply to this branch
```

**Don't trust `gh ruleset list` for "are any configured?"** — on a plan-gated repo
it prints nothing and exits 0, which reads identically to "none configured." The
API call above is the one that distinguishes *none* from *unavailable*.

Creating one goes through the API:

```bash
gh api -X POST repos/{owner}/{repo}/rulesets --input ruleset.json
```

A minimal `ruleset.json` for main — PR required, one approval, CI green, no force
push:

```json
{
  "name": "main protection",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false
      } },
    { "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": [{ "context": "build (ubuntu-latest)" }]
      } }
  ]
}
```

**On a solo repo, requiring one approval locks you out of your own repo** unless
you add yourself as a bypass actor — which makes the rule advisory. For a solo
maintainer, require the status checks and skip the review requirement; add the
review rule when a second maintainer arrives.

`~DEFAULT_BRANCH` and `~ALL` are the two special ref names. Status-check contexts
must match the **job name** as it appears in `gh pr checks`, not the workflow name.

**Renaming a job, or changing a CI matrix, changes the check names.** A required
check that no job produces never reports, so it blocks every pull request until
the ruleset changes. Change the ruleset in the same change as the workflow, in
this order: add a new name only after a pull request has shown that check passing,
and remove an old name only when its job is gone. Read the current requirements
before and after:

```bash
gh api repos/{owner}/{repo}/rulesets/<id> --jq '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context'
```

Editing a ruleset is a repository-settings change, so get the maintainer's
approval first, and keep a copy of the old definition so it can be restored.

## Release notes configuration

GitHub generates release notes from merged PRs for free — but unconfigured, it is
a flat list. `.github/release.yml` turns it into a real changelog by mapping labels
to sections:

```yaml
changelog:
  exclude:
    labels: [ignore-for-release]
  categories:
    - title: Breaking Changes
      labels: [breaking]        # not in the default label bootstrap — create it
    - title: Security
      labels: [security]
    - title: Features
      labels: [enhancement]
    - title: Fixes
      labels: [bug]
    - title: Documentation
      labels: [documentation]
    - title: Other Changes
      labels: ["*"]
```

Categories are matched in order and `"*"` catches the rest, so it must be last.
Labels here are the **PR's** labels, not the issue's — label PRs at open time or
the categorisation silently falls through to Other. A repo can automate this: a
`pull_request_target` workflow that reads the PR body's `Refs #N`/`Closes #N`
line, copies the linked issue's category labels onto the PR, and skips
gracefully when no reference or no matching label exists. Don't rely on this
alone in a repo without it — confirm the automation exists before assuming
labels appear automatically.

**Every label named here must exist on the repo and actually be applied**, or the
category silently never matches — a category keyed on a label nobody creates is
indistinguishable from a working one until a release ships without it. Cross-check
the config against `gh label list` before trusting it.

Preview what it would produce before tagging:

```bash
gh api repos/{owner}/{repo}/releases/generate-notes -f tag_name=v1.2.0 --jq .body
```

This does not replace a hand-written `CHANGELOG.md` — generated notes list *what
merged*, a changelog says *what changed and why*. Keep both; they serve different
readers.

## Release recipe (generic)

A release is its own PR, separate from feature PRs, then a tag. The shape is the same in every repo; only the version file and the verification command change.

1. **Pick the version**: patch = fixes only; minor = new behavior; major = breaking. Read the current value from the repo's version source (`*.psd1` `ModuleVersion`, `package.json` `version`, `pyproject.toml`, etc.), not from the last tag — they drift.
2. **Check the release trigger first**: `cat .github/workflows/release.yml` (or equivalent). Does it fire on tag push or on a published release? Does it extract a CHANGELOG section? Whatever it parses is load-bearing — a missing section means a hard fail after the tag is already public. Also check that the workflow does not run dependency code (install, build, tests) while holding a write token: verify in a read-only job, with credentials not persisted and install scripts disabled, and publish from a separate job that needs it and alone has write permission. Verify the tagged commit is on the default branch and that the changelog section exists before publishing.
3. **Branch `release/x.y.z`**: bump the version file; add a `## [x.y.z] - YYYY-MM-DD` section at the top of `CHANGELOG.md` (Added/Changed/Fixed/Security, referencing issue numbers).
4. **Verify locally** before the PR: the repo's manifest/lint check plus its full test suite.
5. **PR titled `release: x.y.z`**; merge on green (with approval, per `github-hygiene`'s PR flow).
6. **Tag on updated default branch**: `git checkout main && git pull && git tag vx.y.z && git push origin vx.y.z`. Tagging a stale local main ships the wrong commit.
7. **Confirm and close out**: `gh release view vx.y.z` (and `gh run list --workflow release.yml` if it did not appear), then close the milestone.

**Worked example — a small PowerShell module, `example-module`:** version lives in `ModuleVersion` in `ExampleModule.psd1`; `release.yml` extracts the CHANGELOG section on tag push and hard-fails if it is missing; verification is `Test-ModuleManifest ./ExampleModule.psd1` plus a full Pester run.

## Common mistakes

| Mistake | Fix |
|---|---|
| Tagging before the CHANGELOG section exists | release.yml exits 1; add section in the release PR first |
| Forgetting the milestone | Create/attach at scoping time, close after release |
| `gh ruleset create` | Doesn't exist — `gh ruleset` is read-only; create via `gh api -X POST .../rulesets` |
| Recommending a ruleset on a free-plan private repo | 403 — branch protection needs a public repo or Pro/Team; check `gh api .../rulesets` first |
| Reading `gh ruleset list`'s empty output as "none configured" | It prints nothing and exits 0 when the plan blocks it — use the API call to tell *none* from *unavailable* |
| Renaming a CI job or matrix leg without updating the ruleset | The old required check never reports and blocks every PR; update the ruleset in the same change (add the new name after it passes, drop the old when its job is gone) |
| Requiring 1 approval on a solo repo | Locks you out; require status checks only until a second maintainer exists |
| Release notes all landing in "Other Changes" | Categories match **PR** labels — label the PR, not just the issue |
| A `release.yml` category keyed on a label that doesn't exist | Silently never matches; cross-check against `gh label list` |
| Tagging from a stale local main | `git checkout main && git pull` immediately before `git tag` |
| Reading the current version from the last tag | Read the repo's version file — tag and manifest drift apart |
| Using milestones as sprints | Milestones are release buckets; iterations belong on a Projects board |
