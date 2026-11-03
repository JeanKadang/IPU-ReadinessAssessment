# Roadmap

Snapshot of the open issues by milestone, written 2026-11-03. The live view, with status, is the
[Roadmap project board](https://github.com/users/JeanKadang/projects/4). Priorities: P0 critical bug or
security risk, P1 important quality, reliability or user-facing improvement, P2 valuable enhancement, cleanup or testing,
P3 nice-to-have. Refresh this page when milestones change.

Latest release: [4.7.0](https://github.com/JeanKadang/IPU-ReadinessAssessment/releases/tag/v4.7.0) (2026-11-03). What it
contains is in the [changelog](../CHANGELOG.md).

## 4.8.0

Next minor: the remaining bug fixes from the 4.5.3 evaluation, Windows Server 2008 as a source, VMware Tools detail, the cluster node script, and the end-of-life check on a real SQL Server.

| Issue | Priority | Owner | Title |
|---|---|---|---|
| [#349](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/349) | P3 | Micker71 | Confirm the EOL candidates and verdicts on a real Windows Server |
| [#153](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/153) | P3 | Micker71 | Dedicated cluster node assessment script |
| [#257](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/257) | P3 | Micker71 | Patch level uses the newest update of any kind |
| [#258](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/258) | P3 | Micker71 | Storage and platform: hard-coded C:, firmware type guess, PnP drivers enumerated repeatedly |
| [#259](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/259) | P3 | Micker71 | Group Policy and AD: a lookup failure drops groups already read; OS-dependent WMI filters; future dates |
| [#260](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/260) | P3 | Micker71 | SQL Server: an unknown future major version is a BLOCKER; PrintBrm edge cases |
| [#276](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/276) | P3 | Micker71 | Recognise Windows Server 2008 and 2008 R2 as a source release |
| [#279](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/279) | P3 | Micker71 | VMware Tools: show how far behind the installed version is |

## Future

No date: needs a decision first, or depends on something outside the repo.

| Issue | Priority | Owner | Title |
|---|---|---|---|
| [#14](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/14) | P1 | JeanKadang | Sign the script and publish its hash with releases |
| [#90](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/90) | P1 | Micker71 | Remove company and host names now the repo is public |
| [#155](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/155) | P2 | Micker71 | Effort estimate per server and per batch, as ranges |
| [#175](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/175) | P2 | Micker71 | Protocols, ciphers, SMB and NTLM: who breaks after the upgrade |
| [#134](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/134) | P3 | JeanKadang | Releases have hashes but no build provenance |
| [#264](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/264) | P3 | JeanKadang | Settled decisions have no architecture decision record |
| [#265](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/265) | P3 | JeanKadang | User guide is one 839-line file |
| [#267](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/267) | P3 | JeanKadang | Identify the installed cumulative update by build and UBR, and say how many months behind it is |
