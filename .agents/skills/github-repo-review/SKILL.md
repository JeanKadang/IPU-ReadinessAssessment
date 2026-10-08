---
name: github-repo-review
description: Use when asked for a full repository quality review, repo audit, backlog/roadmap overhaul, or "look through this repo and file issues" — before filing the first issue or judging existing ones.
---

# GitHub Repository Quality Review

Run the complete methodology in [review-prompt.md](review-prompt.md) — read that file now; it is the skill. It covers operating rules (analysis-only, evidence, live verification of suspected bugs, reuse of existing label/milestone schemes, the >10-issue confirmation gate), the audit phases (code, CI/CD, supply chain, release health, repo hygiene, generated-artifact accessibility, existing-issue triage), the P0–P3 priority model with blocking-fan-out bumps, roadmap structure (milestones vs priority, dependencies, epics, when Projects boards are and are not worth it), the per-issue quality bar and template, and the final summary format.

`review-prompt.md` is also the standalone, tool-agnostic version shared with colleagues who are not running these skills — keep it self-contained. It deliberately restates the priority model and Projects guidance that also appear in the companion skills; don't DRY that duplication away by moving content out of it into this wrapper.

**Companion skills:** `github-issue-first` (file-before-fix reflex, single-issue mechanics, label bootstrap, issue types, ADR/decision lifecycle, closing criteria), `github-hygiene` (PR/merge/branch conventions, the closure gate), `github-releases` (milestones, rulesets, release-note config, the release recipe), `github-contributing` (submitting a PR to a repo you don't maintain), `github-pr-review` (reviewing an individual PR), `github-projects` (board setup and audit for multi-maintainer repos), `github-security-response` (what to do when the audit finds something live — a committed secret, an exploitable defect, an alert to triage), `github-repo-bootstrap` (the initial shell of a new repository), `github-repo-configure` (org-optional settings and templates for an existing repository), `github-for-ado-users` (mapping for maintainers arriving from Azure DevOps/Jira), and `github-for-gitlab-users` (mapping for maintainers arriving from GitLab). During a review use their rules for anything you create; this skill governs the review process itself.

**A finding that is exploitable does not go in a public issue.** Hand it to `github-security-response` and keep it out of the plan you post.
