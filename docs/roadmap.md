# Roadmap

Snapshot of the open issues by milestone, written 2026-10-31. The live view, with status, is the
[Roadmap project board](https://github.com/users/JeanKadang/projects/4). Priorities: P0 critical bug or
security risk, P1 important quality, reliability or user-facing improvement, P2 valuable enhancement, cleanup or testing,
P3 nice-to-have. Refresh this page when milestones change.

Latest release: [4.6.0](https://github.com/JeanKadang/IPU-ReadinessAssessment/releases/tag/v4.6.0) (2026-10-29). What it
contains is in the [changelog](../CHANGELOG.md).

## 4.7.0

Next minor: larger refactors, the cluster node script, VMware Tools and patch-level detail, and the rest of the end-of-life work.

| Issue | Priority | Owner | Title |
|---|---|---|---|
| [#255](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/255) | P2 | Micker71 | Split Register-AssessmentCheck into one function per check |
| [#137](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/137) | P3 | Micker71 | Report builder and RDP evidence functions are too large |
| [#140](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/140) | P3 | JeanKadang | No single command to run CI checks locally |
| [#141](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/141) | P3 | JeanKadang | CI module install has no retry; a truncated Gallery download fails the job |
| [#153](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/153) | P3 | Micker71 | Dedicated cluster node assessment script |
| [#257](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/257) | P3 | Micker71 | Patch level uses the newest update of any kind |
| [#258](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/258) | P3 | Micker71 | Storage and platform: hard-coded C:, firmware type guess, PnP drivers enumerated repeatedly |
| [#259](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/259) | P3 | Micker71 | Group Policy and AD: a lookup failure drops groups already read; OS-dependent WMI filters; future dates |
| [#260](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/260) | P3 | Micker71 | SQL Server: an unknown future major version is a BLOCKER; PrintBrm edge cases |
| [#262](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/262) | P3 | JeanKadang | Pinned CI tool versions have no update path |
| [#263](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/263) | P3 | JeanKadang | Issues closed as completed with unchecked criteria go unnoticed |
| [#266](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/266) | P3 | JeanKadang | End-of-life dates for installed applications and runtimes, looked up off the server |
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
