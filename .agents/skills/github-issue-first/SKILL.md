---
name: github-issue-first
description: Use whenever you are working in a git repository that has a GitHub remote and you notice a bug, gap, stale doc, missing test, CI failure, or any other improvement worth doing. Before fixing it, discussing it at length, or otherwise acting on it, file it as a GitHub issue first via gh issue create — labeled (priority + category) and assigned to the current user. Trigger this proactively when you spot something worth tracking, not only when the user explicitly says "file an issue" or "track this" — but file only in a repo where you have write or triage permission, and confirm once per repo per session before the first filing. In someone else's repo, use github-contributing instead. Also use this skill when the user asks you to prioritize, triage, reprioritize, or map dependencies between existing issues on a repo.
---

# GitHub issue-first workflow

When you're working in a repo and you notice something worth fixing that isn't
the exact thing you were asked to do right now — a bug, a stale doc, a missing
test, a CI failure, a backlog item, anything — the default move is: **file the
issue before you do anything else with it.** Not after you fix it, not only
when the user remembers to ask. The issue tracker is the source of truth for
"things we know about," and if a finding only ever lived in chat, it's gone
the moment the conversation scrolls past. Spotting it is automatic; filing it is gated by the
Preconditions below (permission first, then one confirmation per repo per session).

The one exception: if the user has explicitly said "just fix it" / "don't
bother filing an issue for this" / equivalent, for this specific thing, skip
the ceremony and just do the work. Read that as scoped to what they said, not
a blanket opt-out for the rest of the session.

## Preconditions

Filing an issue is an outward-facing record, and on a public repo it is public.
Check all three before the first `gh issue create` in a repo:

1. **A GitHub-backed repo.** `git remote -v` shows a `github.com` remote, or
   `gh repo view` succeeds. If there's no GitHub remote (no repo, or a
   non-GitHub host), this workflow doesn't apply; don't invent an issue tracker
   that isn't there. If `gh auth status` isn't logged in, say so and ask before
   proceeding rather than silently skipping.
2. **Permission to file here.** Look at what the viewer can do:

   ```bash
   gh repo view --json viewerPermission,visibility,isFork
   ```

   `viewerPermission` is `ADMIN`, `MAINTAIN`, `WRITE`, `TRIAGE`, or `READ`. File
   only with `TRIAGE` or higher, in a repo the user maintains or belongs to.
   With `READ`, or when the problem is in someone else's upstream repo (including
   a fork you are contributing from), **do not file**. You are an outside
   contributor there: hand off to `github-contributing` and follow that repo's own
   `CONTRIBUTING.md` for how to report it.
3. **Confirm once per repo per session.** The first time in a session you
   would file in a given repo, say where (repo and visibility) and what (the
   title), and get a yes. After that, further issues in that repo this session
   need no new confirmation unless the user says otherwise. Three things already
   count as the confirmation and need no extra question: the user asked you to
   file this issue; the maintainer approved an issue-creation plan
   (`github-repo-review`); or it is the bootstrap issue under
   `github-repo-bootstrap`.

If a precondition fails, put the finding in your reply instead (what, where,
why it matters) and do not file it.

| Situation | Permission | What you do |
|---|---|---|
| The user's own repo; you notice a stale doc | `ADMIN` | Confirm once (repo, visibility, title), then file |
| A teammate's private repo where you have triage | `TRIAGE` | Same: confirm once, then file |
| An open-source repo you only cloned; you hit a bug | `READ` | Do not file. Report it the way that repo asks, via `github-contributing` |
| Your fork of someone else's repo; the bug is upstream's | fork (`isFork`) | Do not file. Same hand-off |
| The user says "file an issue for this" | `TRIAGE` or higher | File it; the request is the confirmation |

## Scaling ceremony to repo risk

Not every repo warrants full issue-first ceremony by default. A repo with
no CI, no branch protection, and no code that gets built, deployed, or
tested — a static team-description page, a wiki-style content repo — is
lower-stakes than one with real branch protection and required checks.
These read-only checks show which category a repo falls into, so you don't
assume either way:

```bash
gh repo view --json visibility,defaultBranchRef,deleteBranchOnMerge
gh api repos/{owner}/{repo}/rulesets      # a 403 means plan-gated, not "none"
gh api repos/{owner}/{repo}/actions/workflows --jq '.workflows[].name'
```

No rulesets (and no 403), no workflows, and no tests points to low-stakes.

For a repo that's clearly low-stakes by that check, **ask the maintainer
once, up front**, whether they want the full issue → branch → PR ceremony
or a lighter touch (e.g. direct edits with a clear commit message) — don't
unilaterally decide to skip it, and don't ask again once they've told you
for that repo. Any repo with CI, tests, deployment, or existing branch
protection keeps the default full ceremony without asking; that signal
alone is enough to know it's warranted.

## Filing a single issue

```bash
gh issue create \
  --title "<short, specific, states the problem not the fix>" \
  --body "<what's wrong, where (file:line if applicable), how you found it, and what fixing it would involve>" \
  --assignee "@me" \
  --label "<priority-label>" \
  --label "<category-label(s)>"
```

PowerShell:

```powershell
gh issue create `
  --title "<short, specific, states the problem not the fix>" `
  --body "<what's wrong, where (file:line if applicable), how you found it, and what fixing it would involve>" `
  --assignee "@me" `
  --label "<priority-label>" `
  --label "<category-label(s)>"
```

**Title** states the defect or gap, not the task of fixing it — "Status badge
falls through to the default color" not "Fix badge bug." **Body** gives enough
for someone (including future-you) to act without re-deriving the finding:
what's broken, concrete location, how it was found, rough scope of the fix.

Every actionable issue also carries testable **acceptance criteria**. These are
the issue's completion contract, not an optional checklist. Phrase each criterion
as an observable outcome that can later be supported by a test, CI run, diff,
document, screenshot, or reproducible verification. Investigation and
decision-needed issues use explicit exit criteria for the evidence or decision
they must produce. An issue that arrives through an intake form collecting only
an expected outcome (the `github-repo-configure` forms) gets its criteria at
triage: write them into the issue body before implementation starts.

### Labels

Every issue needs exactly one priority label and at least one category label.
Create labels that don't exist yet on the repo before using them:

```bash
gh label list   # check what already exists first
gh label create P0 --color B60205 --description "Critical bug, security risk, data loss risk, broken build, or production-blocking issue"
gh label create P1 --color D93F0B --description "Important quality, reliability, maintainability, or user-facing improvement"
gh label create P2 --color FBCA04 --description "Valuable enhancement, cleanup, documentation, testing, or developer-experience improvement"
gh label create P3 --color C2E0C6 --description "Nice-to-have polish, future idea, or low-impact improvement"
```

`gh label create` **fails if the label already exists**, which aborts a batch
half-done and makes the bootstrap unsafe to re-run. Use the create-or-update form
when you can't be sure of the starting state:

```bash
gh label create P0 --color B60205 --description "..." 2>/dev/null \
  || gh label edit  P0 --color B60205 --description "..."
```

PowerShell:

```powershell
gh label create P0 --color B60205 --description "..." 2>$null `
  || gh label edit  P0 --color B60205 --description "..."
```

Only overwrite colour/description this way for labels you are bootstrapping. Don't
"correct" the description of a label the repo already curated.

### Milestone

Every filed issue also gets a milestone before you move on — not just labels
and an assignee. `gh issue create` supports `--milestone "<title>"` directly
when you already know which existing milestone the issue belongs to; when
you don't (or the right milestone doesn't exist yet), attach it as a
follow-up instead: `gh issue edit <N> --milestone "<title>"`. Full milestone
conventions (what to name it, when to reuse vs. create, when to close it) live
in `github-releases` — check there rather than improvising a naming scheme.

Priority tiers:
- **P0** — critical bug, security risk, data loss risk, broken build, or production-blocking issue.
- **P1** — important quality, reliability, maintainability, or user-facing improvement.
- **P2** — valuable enhancement, cleanup, documentation, testing, or developer-experience improvement.
- **P3** — nice-to-have polish, future idea, or low-impact improvement.

If a repo already has a different priority label scheme in place when you
start working in it (e.g. an existing `priority-high`/`medium`/`low` set, or
someone else's convention), match what's already there rather than
introducing a second competing scheme — consistency within a repo matters
more than which specific scheme is used. Only switch a repo to P0–P3 if the
user asks for it explicitly.

Category labels depend on the repo, but default to GitHub's common set plus
whatever fits the project's domain: `bug`, `documentation`, `enhancement`,
`testing`, `tooling` (CI/scripts/build), `process` (needs a human owner,
not code), and any project-specific categories you notice recurring (e.g. a
content-heavy repo might want a `backfill` or `content` label, a UI-heavy repo
might want `visualization` or `accessibility`). Reuse an existing label if a
close match already exists rather than creating near-duplicates — check
`gh label list` first.

### Issue types (organization repos)

Separate from labels, GitHub has a first-class **issue type** field — the closest
equivalent to a work-item type in Azure DevOps or Jira. Set it at creation:

```bash
gh issue create --type Bug --title "..." --body "..." --assignee "@me" --label P1
gh issue edit <N> --type Feature      # or --remove-type
```

**Issue types are defined at the organization level.** On a personal account the
endpoint 404s and the flag has nothing to select:

```bash
gh api "orgs/<org>/issue-types" --jq '.[].name'
```

So: on an org repo, use the type field for *what kind of work this is* and keep
labels for priority and area. On a personal repo, encode the kind as a category
label — don't invent a parallel scheme. The axes are:

| Axis | Where | Example |
|---|---|---|
| Kind of work | Issue type (org) or category label | Bug, Feature, Task, Epic |
| Urgency/importance | Priority label | P0–P3 |
| Area/domain | Category label | `tooling`, `documentation`, `visualization` |

Keep types coarse. A dozen types is a taxonomy nobody applies consistently.

### Issue templates and forms

Check `.github/ISSUE_TEMPLATE/` before filing. If the repo has templates, **fill
out the fields they define** rather than free-forming a body — a repo that asks
for reproduction steps and version wants those on every issue, including yours.
Use `gh issue create --template <name>.yml` (non-interactive `--body` bypasses
the template entirely, so paste the template's sections into the body yourself).

If a repo has no templates and is about to take outside contributors, that is
worth recommending: issue *forms* (`.github/ISSUE_TEMPLATE/*.yml` with `body:`
fields) beat markdown templates because required fields are actually enforced and
`labels:`/`assignees:` are applied automatically. Add `config.yml` with
`blank_issues_enabled: false` plus contact links to route questions away from the
tracker. Recommend it, don't silently add it — templates change what every future
contributor sees. `github-repo-configure` ships ready-to-copy, generic
Bug Report/Improvement forms plus a matching `config.yml` — reuse those
rather than drafting new ones from scratch.

### Assignment

Always `--assignee "@me"` (it needs `TRIAGE` or higher, which the Preconditions already
require; if `gh` still refuses the assignment, file without it and say so) unless the user
has told you a different assignee
convention for this repo (e.g. "assign backend issues to X"). Don't leave
issues unassigned — an unassigned finding is easy to lose track of.

## Filing a batch (backlog docs, review passes, multi-finding sessions)

When a single pass turns up many issues at once — converting a TODO list or
backlog doc, running a code review, auditing test coverage — file one issue
per distinct actionable item rather than one giant issue. Granular issues are
individually closeable and trackable; a mega-issue just becomes a second copy
of the doc you started from. Use your judgment on granularity: a doc section
with five tightly-coupled sub-bullets that will obviously be fixed together in
one PR is one issue, not five.

For each issue, reference where it came from in the body (source doc, file
path, or "found during review of X") so the trail back to the original
finding isn't lost.

## Dependencies between issues

Real dependencies come in two flavors, and both are worth surfacing — but
only when they're real, not speculative. Don't invent a dependency to seem
thorough.

1. **Hard blocks** — issue B literally cannot be implemented until issue A
   lands (A adds a library B needs, A defines a schema B consumes, A must be
   merged before B's code even compiles).
2. **Soft/efficiency dependencies** — A and B touch the same files, or B's
   quality depends on A's content being current (a chart built from a doc
   should wait until that doc is updated, or you're just visualizing stale
   data). These aren't blocking in the strict sense but doing them in the
   wrong order means redoing work or shipping something built on the old data.

When you notice either kind (at issue-filing time, or later when the user
asks you to prioritize/organize a backlog), record it **on the issues
themselves**, not only in chat — GitHub issue comments outlive the
conversation and are what future-you (or a teammate) will actually see:

```bash
gh issue comment <B> --body "**Blocked by #<A>.** <why — one sentence>"
gh issue comment <A> --body "**Sequencing note:** do before #<B> — <why>."
```

Cross-reference by issue number so GitHub auto-links them.

### Let dependencies inform priority, not just order

If a low- or medium-priority issue is a hard blocker for several other
issues, its priority should reflect that — bump it up a tier even if its own
content looks minor in isolation, so it doesn't sit at the bottom of the
queue while everything downstream waits on it. A rule of thumb: an issue that
blocks N ≥ 2 other issues is a reasonable candidate for a one-tier bump. When
you bump a priority for this reason, say so in a comment on that issue (see
above) so the reasoning is visible, not just the label change.

Conversely, don't bump an issue's priority tier purely because it's early in
a sequence — sequencing (do A before B) and priority (how urgent/important)
are different axes. Only bump for real blocking fan-out.

## Windows / Git Bash gotcha

If you're running `gh` through Git Bash on Windows (MSYS), an issue title or
body argument that *starts* with something that looks like an absolute path
(e.g. `/api/export is broken`) can get silently mangled by MSYS's path
conversion into a Windows path (`C:/Program Files/Git/api/export is broken`).
Avoid leading your title/body with a bare `/segment/...` — rephrase so it
doesn't start with a slash (`Bug: /api/export ...`, `The /api/export endpoint
...`), or set `MSYS_NO_PATHCONV=1` for the command if you need the literal
string preserved.

## Sanity check before moving on

After filing a batch, list the open issues back with their labels and
assignee to confirm nothing slipped through unlabeled or unassigned:

```bash
gh issue list --state open --json number,title,labels,assignees \
  -q 'sort_by(.number) | .[] | "\(.number)\t\(.assignees[0].login)\t\([.labels[].name]|join(","))"'
```

PowerShell:

```powershell
gh issue list --state open --json number,title,labels,assignees `
  -q 'sort_by(.number) | .[] | "\(.number)\t\(.assignees[0].login)\t\([.labels[].name]|join(","))"'
```

If anything comes back with no priority label, no category label, or no
assignee, fix it before considering the batch done.

If the repo has a Projects board, the batch is not done until the new issues are
on it — see the `github-projects` skill. Branch/PR conventions for acting on
these issues live in `github-hygiene`, release conventions live in
`github-releases`, and reviewing a PR is `github-pr-review`.

**Security findings are the exception to filing publicly.** An unpatched
vulnerability, an exploitable defect, or a committed credential must not go into a
public issue — that is disclosure. Use `github-security-response` instead.

## Decisions, brainstorming, and what does *not* belong in an issue

Not every durable thought is an issue. Three different things get confused, and
putting them all in the tracker is what turns a backlog into noise.

| Thing | Home | Why |
|---|---|---|
| Committed work | **Issue** | Has an assignee, a priority, an end state |
| Open exploration | **Discussion** | Threaded, votable, no "when is this done" |
| A decision that was made | **ADR file in `docs/adr/`** | Immutable record, versioned with the code it constrains |
| A decision that must be made | **Issue labeled `decision-needed`** | It *is* actionable work: someone must decide |

### Architecture Decision Records

A single growing `decisions.md` is the anti-pattern — append-only, unreadable,
and edits silently rewrite a record that was supposed to be permanent. Use one
immutable file per decision:

```
docs/adr/0001-use-postgres-over-mongo.md
docs/adr/0014-move-session-store-to-redis.md
```

Each file: **Context / Decision / Consequences / Status** (`Proposed`, `Accepted`,
`Superseded by 0014`). **Never edit a decided ADR to reverse it** — write a new
one that supersedes it, and set the old one's status. The history of what you
believed and when is the point.

The GitHub lifecycle maps onto this cleanly:

1. Question arises → issue labeled `decision-needed` (it needs a human, not code)
2. Options explored → Discussion, or a draft ADR PR with `Status: Proposed`
3. **The PR that adds the ADR is the deliberation record** — review comments are
   the debate, preserved and linked, without any extra ceremony
4. Merged with `Status: Accepted`, PR body carries `Closes #<decision-needed>`
5. Reversed later → new ADR supersedes it; the old file is never touched

Why `docs/adr/` and not the GitHub Wiki: the Wiki is a separate repo with no PRs,
no review, and no coupling to the branch that changed the behaviour. An ADR in the
repo branches with the change that motivated it.

### Discussions (brainstorming and open-ended questions)

`brainstorm.md` in a repo has no threading, no voting, no answer-marking, and
every edit costs a PR. Use **Discussions** instead — enable it under
**Settings → General → Features** if the repo doesn't have it yet.

**Categories** (create the ones a repo actually needs, don't cargo-cult all of
them):

| Category | For | Typical shape |
|---|---|---|
| `Ideas` | An unshaped proposal, "what if we..." | Open-ended, may never converge — that's fine |
| `Q&A` | A question with one right answer | Gets an accepted answer, then closes itself |
| `RFC` | A proposal specific enough to have real trade-offs | Converges to a decision — accept, reject, or convert to a `decision-needed` issue |
| `Announcements` (maintainer-only posting) | Release notes, deprecations, policy changes | One-way; use sparingly, don't duplicate `CHANGELOG.md` |

**Triage cadence:** when you touch a repo's Discussions (same moment as an
issue triage pass, not a separate ritual), check for: a `Q&A` post with a
correct answer buried in replies that was never marked accepted (mark it —
that's what makes it findable later), an `RFC` that's converged but nobody
converted it, and an `Ideas` post that's been actionable for a while without
anyone noticing.

**Convert a discussion to an issue at the moment it becomes actionable** — that
conversion is the boundary between exploring and committing, and it is the whole
reason to keep them separate. Exploration that never converges stays a discussion
instead of rotting as a stale issue nobody can close. `gh discussion` is
preview/GraphQL-only with no built-in convert command, so do it explicitly:

1. File the issue normally (title, body, labels, assignee, milestone — the
   same as any other issue in this skill), with a line in the body linking
   back: `Converted from discussion #<N>.`
2. Comment on the discussion linking forward to the new issue (`Converted to
   #<N>.`) so anyone landing on the discussion later finds the live work.
3. Mark the discussion's status: an `RFC` that converged gets its accepted
   answer noted (or is closed, if the category supports it); don't just
   abandon it mid-thread once the issue exists.

Never let a discussion silently duplicate an issue that already tracks the
same work — link them together the moment you notice, the same way you'd
record a dependency between two issues (see below).

Coming from Azure DevOps or Jira, see `github-for-ado-users` for how these map to
what you had.

## Closing issues: the other half of the job

A backlog that only ever grows stops being a source of truth and becomes a
graveyard nobody reads. Filing well is half the discipline; pruning is the other
half. When you touch a repo's issue list — during triage, a review pass, or a
release — check the open issues for these and act:

- **Already fixed.** The code changed and nobody closed the issue. Close it with
  the commit or PR that fixed it: `gh issue close <N> -c "Fixed by #<PR>."`
  First evaluate every acceptance criterion against concrete evidence. Record
  that evidence in a completion comment, then check every satisfied criterion
  using a newline-preserving body file and
  `gh issue edit <N> --body-file <file>`. Close as completed only when every
  in-scope criterion is satisfied and checked. If even one is unmet or
  unevaluated, keep the issue open. A merged PR, green CI, release deadline, or
  tidy-backlog goal is not evidence for criteria it did not evaluate.
- **Scope changed.** Record the decision, rationale, and date on the issue before
  closure. Mark a removed or superseded criterion explicitly; never check it as
  though it was delivered. Deferred work gets a linked follow-up issue and does
  not silently disappear from the original scope.
- **No longer relevant.** The feature was removed, the dependency dropped, the
  approach abandoned. Close with the reason, not silently.
- **Duplicate.** Close the newer one pointing at the older
  (`gh issue close <N> -c "Duplicate of #<M>."`), and move any unique detail into
  the survivor first.
- **Unactionable as written.** Vague or missing context — ask the author for what
  is needed rather than closing outright; close only if nothing comes back and the
  issue can't be acted on by anyone.
- **Stale but still valid.** Don't close it for age. Age is not a reason; an issue
  that is still true stays open. If nothing has happened in a year and it is
  P3, that's a signal the priority was wrong, not that it should vanish.

Never bulk-close to shrink a number, and don't add a stale-bot that closes on a
timer — it destroys real reports and trains contributors that filing is pointless.
Every close carries a reason a human can read.

GitHub closing keywords do not evaluate the issue. Before allowing `Closes #N`
to merge, use `github-hygiene` to perform its acceptance-criteria closure gate.
Use `Refs #N` while any criterion remains unmet or unevaluated.

`Refs #N` avoids a PR-body closing keyword; it does not guarantee the issue
stays open when GitHub has a connected development branch. After every merge,
immediately audit the linked issue state and body. If it is closed while any
in-scope acceptance criterion is unchecked, unmet, or unevaluated, reopen it
immediately and record the reason. For work that spans the PR merge, either use
this audit-and-reopen flow or track the PR-scoped work in a child issue and leave
the release-spanning parent unconnected. Every PR-scoped criterion still needs
evidence before merge.
