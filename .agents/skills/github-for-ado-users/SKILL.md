---
name: github-for-ado-users
description: Use when someone coming from Azure DevOps, TFS, Jira, or another tracker asks how a concept maps to GitHub — "what's the GitHub equivalent of a sprint / work item type / area path / query", why milestones don't behave like iterations, where a wiki or test plan should go, or how to set up GitHub tracking the way they had it in ADO.
---

# GitHub for Azure DevOps migrants

GitHub and ADO cover the same ground with a much smaller feature set. The danger
is not the concepts that are missing — those are obvious. It is the ones that map
*almost*, where a familiar word means something different and the process quietly
breaks weeks later.

**If your team's Azure DevOps or TFS project uses TFVC rather than Git
repos, everything below is the wrong layer to start at.** This mapping
table is GitHub-vs-ADO *process* vocabulary — work items, boards, pipelines.
TFVC vs Git is a different, more fundamental jump: TFVC checks files out
from one central server one at a time, and only one person can hold the
lock on a file at once; Git gives every clone the entire history, and
every commit happens locally, before anyone pushes anywhere — there's no
central lock to wait for. No amount of relabeling nouns bridges that gap;
it has to be learned as its own concept before the table below is useful.
If this repository's colleague-training program is available, its
`education/0_prerequisites/module-0-1-what-is-version-control.md` (this repository only) covers the
concept in plain terms — but the two sentences above are enough to name
the jump even without it.

**The single most expensive mistake (once you're on Git): treating
milestones as sprints.** See below.

## Mapping table

| Azure DevOps | GitHub | Notes |
|---|---|---|
| Work Item | Issue | Straight mapping |
| **Work Item Type** (Bug/Task/Feature) | **Issue Types** | Real first-class field, but **org-only** — personal accounts get labels instead |
| **Iteration / Sprint** | **Projects iteration field** | **Not milestones.** See below |
| Area Path | Labels | Flat, not hierarchical — encode area as `area:auth` if you need the prefix |
| Epic → Feature → Story | Epic issue + native **sub-issues** | One practical nesting level; don't rebuild three tiers |
| Boards | Projects v2 | A *view* over issues, never the source of truth |
| Backlog | Issue list, ordered by priority label | No ranked backlog with drag-order outside a board |
| Queries (WIQL) | `gh issue list --search`, Projects saved views | Far weaker; no cross-repo query language |
| Wiki | `docs/` in the repo | GitHub's Wiki exists, but don't start a new one; see below |
| Pipelines | Actions | YAML in `.github/workflows/` |
| Branch policies | **Rulesets** | Supersede branch protection; `gh ruleset` is view-only |
| Pull Request | Pull Request | Straight mapping |
| Release pipeline | Releases + a tag-triggered workflow | |
| **Test Plans** | **No equivalent** | Genuine hole — plan for it |
| Dashboards | Projects charts (weak), or nothing | Insights are thin by ADO standards |
| Service hooks | Webhooks / Actions | |
| Delivery Plans | No equivalent | |

## The three traps

### 1. Milestones are not sprints

A milestone is a **delivery bucket** — a release, or a phase. It closes when the
thing ships. It has a due date, which makes it *look* like an iteration, and that
is the trap.

Time-boxed iterations belong in a **Projects iteration field**. Using milestones
as sprints leaves a graveyard of stale, half-empty `Sprint 14` milestones that
nobody closes, and destroys the one thing milestones are good at: answering "what
is in the next release?"

If you want both — you probably do — run milestones for releases and an iteration
field on the board for cadence. They are different axes, like priority and
milestone. Note that the iteration field **cannot be created from the CLI**
(`gh project field-create` supports only TEXT, SINGLE_SELECT, DATE, NUMBER);
use the web UI or a GraphQL mutation. See `github-projects`.

### 2. Issue types are org-only

`gh issue create --type Bug` sets a first-class type, separate from labels — the
closest thing to a Work Item Type. But issue types are defined **at the
organization level**. On a personal account the API returns 404 and the flag has
nothing to select:

```bash
gh api "orgs/<org>/issue-types" --jq '.[].name'    # 404 on a personal account
```

On a personal repo, encode the type as a category label and move on. If you are
setting up an org, define issue types early — retrofitting them across an existing
backlog is manual. Keep them coarse (Bug, Feature, Task, Epic); the priority and
area axes stay on labels.

### 3. A new Wiki is a trap; an established one is not

GitHub's Wiki is a separate git repo with no pull requests, no review, no CI, and
no coupling to the branch that changed the behaviour it documents. For a repository
with no Wiki in use, docs that matter go in `docs/` in the repo, where they are
versioned with the code, reviewed in the same PR, and greppable. Don't enable a
Wiki to hold them.

That is a rule about *starting* one, not about an existing one. Azure DevOps also
has a Git-backed project Wiki, so a team arriving with an established,
actively-used Wiki (here or there) may keep it: leave it alone and treat its
content as the source of truth for what it covers, as `github-repo-bootstrap`
does. If they are migrating because the wiki
sprawled unreviewed, that is the moment to suggest `docs/`, but it is a call
about their wiki, not about wikis in general.

Use Discussions for the conversational content that would have been a wiki page in
ADO (how-do-I, RFCs, announcements).

## What GitHub has that ADO does not

**Discussions** is the one to actually learn. ADO has no equivalent, so migrants
tend to keep putting exploratory work into issues, where it rots as a stale
never-closeable ticket.

- Discussion = exploring. Threaded, votable, answer-markable, no assignee, no
  "when will this be done."
- Issue = committed to doing. Assignee, priority, milestone.
- **Converting a discussion to an issue is the moment exploration became
  commitment** — that boundary is the whole value.

Categories worth having: `Ideas`, `Q&A`, `RFC`, `Announcements`.

Caveat: `gh discussion` is **in preview and subject to change**. Script against
the GraphQL API if you need stability; the web UI is fine for humans.

Also new relative to ADO: **CODEOWNERS** (automatic review routing by path),
**Dependabot** (dependency PRs raised for you), **auto-generated release notes**,
and **native sub-issues**.

## The traceability chain

The consistency that ADO gave you through work-item links, GitHub gives through
one chain. Every change follows it, and each link is enforced by the tool rather
than by discipline:

```
issue (#N, priority + category labels, milestone)
  → gh issue develop <N>        # branch created AND linked to the issue
  → PR with "Refs #N"           # links partial or in-progress delivery
  → criteria + evidence reviewed # acceptance contract must pass
  → change "Refs" to "Closes"   # completed issue may now auto-close
  → milestone                   # groups the release
  → auto-generated release notes # built from merged PRs
```

Break any link and traceability is back to human memory. `gh issue develop` is the
one most often skipped and the one that does the most work — it is the equivalent
of creating a branch from a work item in ADO.

GitHub does not enforce acceptance criteria the way a configured ADO process can.
`Closes #N` merely changes state when the PR merges; it does not evaluate a
checkbox. Treat each criterion as part of the work: map it to concrete evidence,
check it only when satisfied, and keep `Refs #N` plus an open issue while any
in-scope criterion is unmet or unevaluated. Scope changes require a recorded
decision, not a checkbox that falsely implies delivery. The exact merge and
closure gate lives in `github-hygiene`.

## Setting up a repo the way you had it in ADO

Rough order, with the skill that covers each:

1. Labels (priority + category) — `github-issue-first`
2. Issue types, if you are in an org — `github-issue-first`
3. Milestones for releases, **not** sprints — `github-releases`
4. Ruleset on the default branch (required checks + review) — `github-releases`
5. Issue forms and PR template — `github-repo-configure`; CODEOWNERS and
   CONTRIBUTING.md — `github-repo-bootstrap` for a new repository,
   `github-repo-review` to audit an existing one
6. `.github/release.yml` for categorised release notes — `github-releases`
7. Projects board **only if more than one maintainer** — `github-projects`
8. Discussions enabled, with categories

## Common mistakes

| Mistake | Fix |
|---|---|
| Milestones used as sprints | Milestones = releases; iterations = Projects iteration field |
| Rebuilding Epic→Feature→Story as three issue levels | Epic + sub-issues, one level |
| Expecting `gh issue create --type` to work on a personal repo | Issue types are org-only; use labels |
| Starting a new GitHub Wiki for docs | `docs/` in the repo — versioned, reviewable, greppable (an established, actively-used Wiki can stay) |
| Exploratory ideas filed as issues | Discussions; convert when it becomes actionable |
| Looking for Test Plans | No equivalent — decide where test cases live before you need them |
| Expecting WIQL-grade queries | `gh issue list --search` + Projects views; plan for less |
| A board as the source of truth | The board mirrors issues; labels and milestones are authoritative |
| Assuming a merged PR means its issue met acceptance criteria | Review every criterion with evidence; use `Refs #N` until the completion contract passes |
