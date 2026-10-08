---
name: github-projects
description: Use when a GitHub repo has (or is about to have) more than one maintainer and work needs a shared board — setting up a GitHub Projects v2 board, adding fields, adding issues or PRs to a board, updating Status/Priority/Effort on items, auditing a board that has drifted out of sync with the Issues tab, or deciding whether a board is warranted at all.
---

# GitHub Projects v2 (multi-maintainer repos)

A Projects board is a **view over issues**, never a replacement for them. Labels,
milestones, assignees, and issue bodies stay the source of truth; the board
mirrors them so several maintainers can see who is doing what without reading
every issue. If a fact lives only on the board, it is lost to anyone reading the
repo through the API, the Issues tab, or `gh`.

Companion skills: `github-issue-first` (filing, labels, assignment, dependencies),
`github-hygiene` (branch/PR conventions), and `github-releases` (milestones —
this skill's iteration-field guidance is the Projects-board complement to
`github-releases`'s milestone conventions). Anything you create here still
follows those.

## Decide whether a board is warranted

| Situation | Do this |
|---|---|
| Solo maintainer | **No board.** Milestones + labels are the whole system; an unmaintained board is worse than none. |
| Second maintainer joining, or an outside contributor picking up issues | Create the board *before* they arrive, so it is populated on day one. |
| Multiple maintainers, work already spans several repos | One **org-level** board linked to each repo, not one board per repo. |
| Maintainer explicitly asks for a board | Create it, and say what the ongoing upkeep is. |

Never create a board silently as part of some other task. Boards are visible,
shared, and annoying to unwind — confirm with the maintainer first.

## Prerequisite: token scope

`gh project` needs the `project` scope, which the default `gh auth login` token
does **not** include. Check before you start; every project command fails with a
scope error otherwise.

```bash
gh auth status                 # look for 'project' in Token scopes
gh auth refresh -s project     # add it (interactive — the user must run this)
```

For org-owned projects add `read:org` as well. If the scope is missing, stop and
tell the user the exact command — do not work around it by editing issues instead.

## Creating and wiring up a board

```bash
# 1. Create. --owner is a user login or an org login, not the repo.
gh project create --owner "@me" --title "Roadmap"          # personal
gh project create --owner <org> --title "Roadmap"          # org-owned (preferred for teams)

# 2. Link it to the repo(s) so it appears on the repo's Projects tab.
gh project link <number> --owner <org> --repo <repo>
gh project link <number> --owner <org> --team <team>       # org boards: give the team access

# 3. Confirm.
gh project list --owner <org>
gh project view <number> --owner <org>
```

New boards ship with a `Status` single-select field (`Todo`/`In Progress`/`Done`).
Add the rest:

```bash
gh project field-create <number> --owner <org> --name "Priority" \
  --data-type SINGLE_SELECT --single-select-options "P0,P1,P2,P3"
gh project field-create <number> --owner <org> --name "Effort" \
  --data-type SINGLE_SELECT --single-select-options "Small,Medium,Large,Unknown"
gh project field-create <number> --owner <org> --name "Confidence" \
  --data-type SINGLE_SELECT --single-select-options "High,Medium,Low"
gh project field-create <number> --owner <org> --name "Target date" --data-type DATE
```

PowerShell:

```powershell
gh project field-create <number> --owner <org> --name "Priority" `
  --data-type SINGLE_SELECT --single-select-options "P0,P1,P2,P3"
gh project field-create <number> --owner <org> --name "Effort" `
  --data-type SINGLE_SELECT --single-select-options "Small,Medium,Large,Unknown"
gh project field-create <number> --owner <org> --name "Confidence" `
  --data-type SINGLE_SELECT --single-select-options "High,Medium,Low"
gh project field-create <number> --owner <org> --name "Target date" --data-type DATE
```

Match the `Priority` options to the repo's existing priority **labels** — if the
repo uses `priority-high/medium/low`, the field options are those, not P0–P3. Two
schemes side by side is the failure mode.

**Iteration fields cannot be created from the CLI.** `gh project field-create`
only accepts `TEXT`, `SINGLE_SELECT`, `DATE`, `NUMBER`. Iterations must be added
in the web UI (or via a GraphQL `createProjectV2Field` mutation). Don't fake one
with a text field, and don't repurpose milestones for it: milestones are delivery
buckets, not cadence (see `github-releases`). Say it needs the UI or GraphQL, or
agree with the maintainer to go without cadence tracking.

### Multi-repo boards

The org-level pattern from the decision table above (one board linked to
several repos, not one board per repo) is the same `gh project create` and
`gh project link` primitives shown earlier — just called once per repo
instead of once total (this is a how-to for an already-decided
pattern, not a policy question):

```bash
gh project create --owner <org> --title "Team roadmap"
gh project link <number> --owner <org> --repo <org>/<repo-a>
gh project link <number> --owner <org> --repo <org>/<repo-b>
gh project link <number> --owner <org> --repo <org>/<repo-c>
```

Every field created above (`Priority`, `Effort`, `Confidence`, `Target date`)
is shared across every linked repo's items automatically — there's no
per-repo field configuration. The one thing a single-repo board doesn't
need: keep the board's built-in **`Repository`** field visible in every
view. Nothing else on a shared board tells you which repo an item belongs
to, and a filtered/grouped view (group by `Repository`, or a saved view per
repo) is what keeps a multi-repo board readable once it has more than a
handful of items.

## Adding and updating items

```bash
# Add an existing issue or PR
gh project item-add <number> --owner <org> --url https://github.com/<org>/<repo>/issues/<N>
```

Setting a field value needs **IDs, not names**, and one field per invocation.
Resolve them first. Dump the raw JSON once (`gh project field-list <number>
--owner <org> --format json`) and read the shape before relying on the jq paths
below — if a key differs on your `gh` version, adjust the filter rather than
assuming the command is broken:

```bash
project_id=$(gh project view <number> --owner <org> --format json --jq .id)
field_id=$(gh project field-list <number> --owner <org> --format json \
  --jq '.fields[] | select(.name=="Priority") | .id')
option_id=$(gh project field-list <number> --owner <org> --format json \
  --jq '.fields[] | select(.name=="Priority") | .options[] | select(.name=="P1") | .id')
item_id=$(gh project item-list <number> --owner <org> --format json -L 200 \
  --jq '.items[] | select(.content.number==<N>) | .id')

gh project item-edit --id "$item_id" --project-id "$project_id" \
  --field-id "$field_id" --single-select-option-id "$option_id"
```

PowerShell:

```powershell
$projectId = gh project view <number> --owner <org> --format json --jq .id
$fieldId = gh project field-list <number> --owner <org> --format json `
  --jq '.fields[] | select(.name=="Priority") | .id'
$optionId = gh project field-list <number> --owner <org> --format json `
  --jq '.fields[] | select(.name=="Priority") | .options[] | select(.name=="P1") | .id'
$itemId = gh project item-list <number> --owner <org> --format json -L 200 `
  --jq '.items[] | select(.content.number==<N>) | .id'

gh project item-edit --id "$itemId" --project-id "$projectId" `
  --field-id "$fieldId" --single-select-option-id "$optionId"
```

`--text` / `--number` / `--date` set the other field types; `--clear` removes a
value. There is no name-based shortcut — every one of these is an ID lookup.

**Don't create draft items** (`gh project item-create`) for real work. A draft
lives only on the board: no labels, no assignee, no URL, invisible to `gh issue
list`, and it silently violates issue-first. File a real issue and add it.

## Board hygiene

- **Every item is a real issue or PR.** Audit for drafts periodically and convert
  or delete them.
- **Every item has an assignee** — on the *issue*, not just a board column.
  Unassigned means unowned, board or not.
- **Board fields mirror issue metadata.** When you change an issue's priority
  label, change the board's Priority field in the same breath; when they disagree,
  the label wins.
- **Nothing on the board that isn't in the repo.** Decisions, blockers, and
  sequencing go in issue comments (see `github-issue-first`) — a note typed into a
  board field is invisible to anyone reading the issue.
- **Archive, don't delete, finished items**: `gh project item-archive`. Deleting
  loses the history; the Done column silently becomes the board's whole weight
  otherwise.
- **Close the board when the phase ends**: `gh project close <number> --owner <org>`.

## Automation (must be enabled in the web UI)

Built-in workflows — *auto-add items matching a filter*, *item closed → Status:
Done*, *PR merged → Status: Done*, *auto-archive Done after N days* — are not
exposed through `gh project`. Turn them on under **Project → ⋯ → Workflows**.
Recommend them explicitly rather than hand-syncing the board:

| Workflow | Why |
|---|---|
| Auto-add: `is:issue is:open` for the repo | New issues land on the board without anyone remembering |
| Item closed → Done | Board stops lying the moment an issue closes |
| PR merged → Done | Keeps PR items in step with merges |
| Auto-archive Done after 14 days | Board stays readable |

Anything more (cross-field rules, notifications) is a GitHub Actions job using the
`actions/add-to-project` action, which needs a PAT with `project` scope stored as
a repo secret — document the secret if you add it.

## Multi-maintainer scaffolding that goes with the board

A board without these is just a nicer-looking backlog:

- **Branch protection on the default branch**: required CI status checks + at
  least one review; nobody pushes to it directly.
- **CODEOWNERS** so reviews route automatically.
- **CONTRIBUTING.md** stating the branch/commit/PR conventions (see `github-hygiene`).
- **Native blocked-by/blocks relations** plus `Depends on: #N` body lines, so
  pick-up order is visible from the board.
- **Assign at triage**, always.

## Common mistakes

| Mistake | Fix |
|---|---|
| `gh project ...` fails with a scope error | `gh auth refresh -s project` (`read:org` too for org boards) — the user must run it |
| Creating a board for a solo repo | Don't; milestones + labels are the system |
| `item-edit --field-id Priority` | Field, option, item and project all need real IDs — resolve via `field-list`/`item-list --format json` |
| Trying to create an Iteration field from the CLI | Not supported; use the web UI or GraphQL, or go without cadence tracking. Don't repurpose milestones |
| Draft items standing in for issues | File the issue, then `item-add` the URL |
| Board Priority drifting from the priority label | Label is source of truth; fix the field |
| One board per repo for a team working across repos | One org board, linked to each repo |
| Setting priority only on the board | Set the label too — API/`gh` users never see the board |
