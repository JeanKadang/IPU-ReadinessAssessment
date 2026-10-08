# Full Repository Quality Review — v2

Please perform a full repository quality review of this GitHub repo:

<INSERT_REPOSITORY_URL_HERE>

Your goal: a high-quality, prioritized, dependency-aware project roadmap — not the maximum number of issues. Raise the repo's quality, maintainability, reliability, security, accessibility, developer experience, and long-term value.

## Operating rules (read these first)

1. **Analysis only.** Do not change code unless explicitly asked. Issue/label/milestone edits are allowed per the gates below.
2. **Evidence over speculation.** Every recommendation cites the files, workflows, runs, or issues that support it. Mark speculative items as such.
3. **Verify before filing.** If a suspected bug can be confirmed with a safe read-only check — calling the real API the code targets, running the test suite, reproducing a parse — do it and record the result. A confirmed defect with reproduction beats ten "possibly wrong" guesses. Label findings CONFIRMED (verified live) or PLAUSIBLE (code-read only), and set Confidence accordingly.
4. **Reuse existing schemes.** Inspect labels, milestones (`state=all`, including closed), issue types, and Projects before creating anything. Never introduce a second scheme beside an existing one (e.g. don't add `vX.Y.Z` milestones next to thematic ones) — consistency inside the repo beats your preferred convention. Missing pieces go in the final summary as recommendations, not silent inventions.
5. **Confirmation gate.** Produce an issue-creation plan before creating issues. Up to 10 clearly justified issues: proceed after showing the plan. More than 10: group by milestone and priority and wait for maintainer confirmation.
6. **Assign every issue** you create (to yourself or per the repo's convention). Unassigned findings get lost.

## Phase 1 — Understand the repository

Read enough to know: what the project does, who uses it, the feature set, code structure, how it's built/configured/tested/deployed, which areas are mature vs fragile vs missing, and what quality standards already exist. Include TODO/FIXME/HACK comments in the sweep.

## Phase 2 — Audit the project infrastructure

Beyond the code, review:

- **CI/CD**: coverage of platforms actually supported (e.g. cross-platform code tested on one OS only), what's measured (is code coverage pointed at the real source?), scheduled automation opportunities (reports, syncs, stale checks). Also check that the language runtime versions CI tests are still supported (look up the project's published support schedule instead of assuming one), that the declared minimum (for example `engines` in `package.json`) agrees with what CI tests and with what the lockfile's own dependencies require, and that every required check name in the ruleset still matches a job that runs.
- **Supply chain & settings**: actions pinned to commit SHAs vs mutable tags; dependency-update automation (Dependabot/Renovate); unpinned tool installs in CI; `delete_branch_on_merge`; branch protection; secrets referenced but never documented.
- **Workflow permissions & secrets**: every workflow should declare an explicit least-privilege `permissions:` block — an absent one inherits the repo default, which is often write-all. Flag `pull_request_target` combined with a checkout of untrusted head code (the classic token-exfiltration path), `GITHUB_TOKEN` handed to third-party actions, `secrets` interpolated into `run:` strings where they can leak into logs, and self-hosted runners on a public repo. Cross-check `gh secret list` against the secrets workflows actually reference: secrets set but unused, and referenced but unset, are both defects — the second fails only at release time.
- **Release health**: does the version in the manifest/package file match the latest tag? Are there merged changes with no release? Is there a CHANGELOG, and does release automation exist and actually work?
- **Repo hygiene**: stale merged branches (fetch with prune, or query the API — local listings lie); template files left unedited (a boilerplate SECURITY.md with a fictitious version table is worse than none); LICENSE and manifest metadata.
- **Scaffolding baseline**: check each of the files in the table below. A missing one is a finding; a present-but-boilerplate one is a worse finding. Report them as a single grouped recommendation rather than one issue per file — they are usually one PR.
- **Generated artifacts**: if the project emits HTML/reports/UI, check accessibility basics — keyboard operability, labeled inputs, WCAG AA contrast — and offline/self-containment claims.
- **Existing issues**: for each, is it clear, actionable, still relevant, duplicated, mis-sized, missing context/acceptance criteria/labels/milestone/priority/dependencies? Is it already fixed? Improve existing issues rather than duplicating them; recommend closing outdated ones with reasons. Also audit issues closed as completed that still contain unchecked task boxes. A merged PR or green CI is only a lead: evaluate every acceptance criterion against concrete evidence, reopen any issue with unmet or unevaluated in-scope criteria, and check criteria only when the evidence supports them.

### The scaffolding baseline

| File / setting | Purpose | Warranted when |
|---|---|---|
| `README.md` | What it is, install, usage | Always |
| `LICENSE` | Legal reuse terms | Always for public |
| `CHANGELOG.md` | What changed and why, per release | Anything versioned or released |
| `.github/ISSUE_TEMPLATE/*.yml` | Issue forms with enforced required fields | Any repo taking reports from others |
| `.github/ISSUE_TEMPLATE/config.yml` | `blank_issues_enabled: false` + contact links | With the above |
| `.github/PULL_REQUEST_TEMPLATE.md` | What changed, how verified, `Closes #N` | Always — cheapest consistency win |
| `.github/release.yml` | Maps PR labels to release-note sections | Anything that cuts releases |
| `.github/dependabot.yml` | Dependency + action update PRs | Any repo with dependencies or Actions |
| `CODEOWNERS` | Automatic review routing by path | Two or more maintainers |
| `CONTRIBUTING.md` | Branch/commit/PR conventions | Any outside contributors |
| `CODE_OF_CONDUCT.md` | Community behavior standards + a working enforcement contact | Any public repo — one of GitHub's own Community Standards checklist items |
| `SECURITY.md` + private vulnerability reporting | Where to report privately | Any public repo |
| `docs/adr/` | Immutable architecture decision records | Any repo where design choices get re-litigated |
| Ruleset on the default branch | Required checks, no force-push | Public repos, or private on Pro/Team — see below; review requirement only with 2+ maintainers |
| `delete_branch_on_merge` | Branch cleanup | Always |

Two rules when reporting these:

1. **A boilerplate file is worse than a missing one** — an unedited SECURITY.md
   with a fictitious version table tells a reporter nobody reads it. Flag
   unedited templates as defects, not as satisfied requirements.
2. **Don't recommend the whole table for every repo.** A solo internal script repo
   needs a README and a LICENSE; recommending CODEOWNERS and a CONTRIBUTING.md for
   it is noise that trains the maintainer to ignore you. Judge each row against the
   "warranted when" column and say why for the ones you keep.
3. **Check that a recommendation is even available before making it.** Branch
   protection — rulesets *and* classic — requires a public repo or GitHub
   Pro/Team/Enterprise; on a free-plan private repo the API returns `403 Upgrade to
   GitHub Pro or make this repository public`. Confirm with
   `gh api repos/{owner}/{repo}/rulesets` before recommending one. Note that
   `gh ruleset list` prints nothing and exits 0 in that situation, which looks
   identical to "none configured." Where it is unavailable, report it as a
   constraint on the repo — required checks are advisory, merge discipline is the
   only control — not as a defect the maintainer failed to fix.

Creating these is a change to the repo, so it falls under the analysis-only rule:
propose them, show the content, and let the maintainer decide — unless they have
explicitly asked you to scaffold.

## Phase 3 — Priority model

This is the same P0–P3 model used for ordinary issue filing, with two review-specific refinements called out below (security/accessibility named explicitly in P1, and the silent-data-quality rule). Where a repo already carries P0–P3 label descriptions, those are authoritative for the label text; this section governs how you *assign* the tier.

- **P0**: critical bug, security risk, data-loss risk, broken build, or production/usability blocker.
- **P1**: important quality, reliability, security, accessibility, or user-facing improvement. Silent data-quality defects (output looks fine but is wrong) belong here or higher — they're the ones nobody notices until it matters.
- **P2**: valuable enhancement, cleanup, documentation, testing, automation, or DX improvement.
- **P3**: nice-to-have polish or future idea.

Adjust for structure: an issue that hard-blocks two or more others deserves a one-tier bump, with the reasoning noted on the issue. Sequencing alone (A before B) is not a bump. Use the repo's existing priority-label format; if none exists, put priority in the issue body and recommend labels in the summary.

## Phase 4 — Roadmap structure

- **Milestones** = delivery phase or release grouping. **Priority** = importance. Never conflate them.
- Reuse existing milestones (check closed ones too — the naming scheme may live there). If none exist, recommend either phase-based (Phase 0: critical fixes & hygiene → Phase 3: polish) or release-based (v0.1 … v1.0, Future) depending on whether the project is release-driven.
- **Dependencies**: use native blocked-by/blocks where available, plus explicit body lines (`Depends on: #123`, `Blocks: #456`, `Part of: #999`). Create or recommend foundational issues before dependent ones; never file implementation issues that assume missing groundwork.
- **Epics/parent issues** for large work: parent states the goal, why it matters, child list, out-of-scope, milestone, and definition of done. Children must be independently implementable. Use GitHub sub-issues where available. No vague container epics.
- **Projects boards**: recommend only when the repo has (or expects) multiple contributors or the maintainer asks — for a solo maintainer, milestones + labels are the whole system and a board is unmaintained overhead. When recommending one, propose fields: Status, Priority, Effort, Confidence, and milestone/iteration mapping, with the board's Priority options matching the repo's existing priority labels rather than introducing a second vocabulary. Note that the board mirrors issue metadata and never replaces it, that the `project` token scope is needed to script it, and that the auto-add / closed→Done / auto-archive workflows must be enabled in the web UI. If a board already exists, audit it: draft items standing in for real issues, items whose board Priority contradicts their label, stale Done columns never archived, and open issues missing from the board entirely.

## Phase 5 — Issue quality bar and structure

Create an issue only if it is actionable, valuable, non-duplicate, evidence-backed, and appropriately sized. Useful-but-unactionable ideas become investigation issues; interesting-but-low-value ideas go in the summary only.

Each issue: **Title** (states the defect/gap, not the task); **Description** (what's wrong, where — file:line, how found); **Why this matters**; **Suggested approach**; **Acceptance criteria** expressed as observable, independently verifiable outcomes; **Relevant files/areas**; **Issue type** (existing types, else bug/enhancement/documentation/testing/security/performance/accessibility/ci-cd/refactor/epic/investigation/decision-needed); **Priority** with justification; **Impact** High/Medium/Low; **Effort** Small/Medium/Large/Unknown; **Confidence** High/Medium/Low (High only for CONFIRMED findings or direct code evidence); **Milestone**; **Dependencies/Blocks**; **Labels** (existing only).

Acceptance criteria are the completion contract. Closing as completed requires every in-scope criterion to be evaluated, supported by evidence, and checked before closure. Scope changes need an explicit rationale; removed or deferred criteria are not checked as delivered. Use `Refs #N` for partial PRs and reserve `Closes #N` for work that has passed the full closure gate in `github-hygiene`.

## Phase 6 — Final summary

1. Most important quality risks (CONFIRMED findings first)
2. Highest-value improvements
3. Existing issues improved / to improve
4. Existing issues to close, reopen, merge, split, or clarify — with criterion-level evidence and reasons
5. New issues by priority, and by milestone
6. Dependency map (what blocks what)
7. Epics created or recommended
8. Recommended milestone / roadmap structure
9. Recommended Projects structure or fields, only if multi-contributor
10. Missing labels, issue types, or repo settings worth enabling (with the exact setting/command)
11. Larger architectural or product questions needing maintainer decisions
12. Ideas deliberately not filed, with reasons

Be selective, practical, and evidence-driven.
