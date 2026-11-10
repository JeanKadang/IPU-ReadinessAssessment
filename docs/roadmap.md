# Roadmap

Snapshot of the open issues by milestone, written 2026-11-10. The live view, with status, is the
[Roadmap project board](https://github.com/users/JeanKadang/projects/4). Priorities: P0 critical bug or
security risk, P1 important quality, reliability or user-facing improvement, P2 valuable enhancement, cleanup or testing,
P3 nice-to-have. Refresh this page when milestones change: the weekly "Roadmap drift" workflow (`build/Find-RoadmapDrift.ps1`, #395)
compares it with the open issues and opens an issue when they differ.

Latest release: [4.8.0](https://github.com/JeanKadang/IPU-ReadinessAssessment/releases/tag/v4.8.0) (2026-11-10). What it
contains is in the [changelog](../CHANGELOG.md).

## 4.9.0

Next minor: the cluster node script, the end-of-life check on a real server with the products in question,
and the findings of the repository review of 2026-11-10 (fleet overview accessibility, CI and assistant guidance).

| Issue | Priority | Owner | Title |
|---|---|---|---|
| [#349](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/349) | P2 | Micker71 | Confirm the EOL candidates and verdicts on a real Windows Server |
| [#393](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/393) | P2 | JeanKadang | Fleet overview lacks the accessibility work the server report has |
| [#153](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/153) | P3 | Micker71 | Dedicated cluster node assessment script |
| [#394](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/394) | P3 | JeanKadang | CI job pester (unelevated) can fail without blocking a merge |
| [#396](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/396) | P3 | JeanKadang | AGENTS.md still describes a one-script repository |

## Future

No date: needs a decision first, or depends on something outside the repo.

| Issue | Priority | Owner | Title |
|---|---|---|---|
| [#14](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/14) | P1 | JeanKadang | Sign the script and publish its hash with releases |
| [#155](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/155) | P2 | Micker71 | Effort estimate per server and per batch, as ranges |
| [#175](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/175) | P2 | Micker71 | Protocols, ciphers, SMB and NTLM: who breaks after the upgrade |
| [#134](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/134) | P3 | JeanKadang | Releases have hashes but no build provenance |
| [#264](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/264) | P3 | JeanKadang | Settled decisions have no architecture decision record |
| [#265](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/265) | P3 | JeanKadang | User guide is one 839-line file |
| [#267](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/267) | P3 | JeanKadang | Identify the installed cumulative update by build and UBR, and say how many months behind it is |
| [#388](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/388) | P3 | Micker71 | End-of-life cycle match takes the first of two equal matches |
