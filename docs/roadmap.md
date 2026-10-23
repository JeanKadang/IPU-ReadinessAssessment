# Roadmap

Snapshot of the open issues by milestone, written 2026-10-23. The live view, with status, is the
[Roadmap project board](https://github.com/users/JeanKadang/projects/4). Priorities: P0 critical bug or
security risk, P1 important quality, reliability or user-facing improvement, P2 valuable enhancement, cleanup or testing,
P3 nice-to-have. Refresh this page when milestones change.

## 4.5.4

Next patch release: P1 correctness and failure-visibility fixes in the assessment, plus small CI and docs items.

| Issue | Priority | Owner | Title |
|---|---|---|---|
| [#239](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/239) | P1 | Micker71 | Post-upgrade comparison is clean against an empty, partial or overwritten baseline |
| [#130](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/130) | P2 | JeanKadang | PowerShell 4.0 support is only checked statically |
| [#236](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/236) | P2 | JeanKadang | README lags behind 4.4.0 to 4.5.3: SPECIAL, evidence, redaction, build step |
| [#250](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/250) | P2 | Micker71 | An unwritable output folder is noticed at the end; the SA line says SUCCEEDED when the JSON write failed |
| [#252](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/252) | P2 | Micker71 | Fleet CSV files have no byte-order mark under PowerShell 7; JSON times have no time-zone offset |
| [#136](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/136) | P3 | Micker71 | Native argument quoting does not escape quotes or trailing backslashes |
| [#138](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/138) | P3 | Micker71 | Fleet overview counts a server twice when its redacted copy is present |
| [#139](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/139) | P3 | Micker71 | NumberCultureName is unvalidated and new folders are restricted after creation |
| [#280](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/280) | P3 | JeanKadang | Add docs/roadmap.md with the milestone plan |

## 4.6.0

Next minor: P2 correctness, test structure and tooling from the 4.5.3 reviews.

| Issue | Priority | Owner | Title |
|---|---|---|---|
| [#242](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/242) | P2 | Micker71 | Failed queries become OK or 0 (LBFO, routes, ports, drivers, IIS, security reads, CA config) |
| [#243](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/243) | P2 | Micker71 | Redaction slows down with many names; four-part versions in free text are redacted as IP addresses |
| [#244](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/244) | P2 | Micker71 | Slow-phase budget does not reserve the Setup scan; a timeout can leave DISM or SFC running |
| [#245](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/245) | P2 | Micker71 | Media language check may raise a false BLOCKER |
| [#246](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/246) | P2 | Micker71 | Checks parse English text: VSS writers, reagentc, task accounts, culture and code page |
| [#247](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/247) | P2 | Micker71 | Post comparison misses subnet mask and DNS registration changes; services with a hex-like suffix are called per-user |
| [#248](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/248) | P2 | Micker71 | Licensing: KMS renewal warning comes late; an ESU add-on can be read as the Windows licence |
| [#249](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/249) | P2 | Micker71 | DISM and SFC verdict gaps: 'manifest is damaged', pending servicing, plain error codes |
| [#253](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/253) | P2 | Micker71 | VMware Tools: no minimum version for a 2022 target; two-part versions compare below |
| [#254](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/254) | P2 | Micker71 | Split the two large test files to mirror the source |
| [#256](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/256) | P2 | Micker71 | Run the test suite under strict mode to find hidden defects |
| [#140](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/140) | P3 | JeanKadang | No single command to run CI checks locally |
| [#141](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/141) | P3 | JeanKadang | CI module install has no retry; a truncated Gallery download fails the job |
| [#262](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/262) | P3 | JeanKadang | Pinned CI tool versions have no update path |
| [#263](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/263) | P3 | JeanKadang | Issues closed as completed with unchecked criteria go unnoticed |

## 4.7.0

End-of-life reporting (ADR 0003), larger refactors and the cluster node script.

| Issue | Priority | Owner | Title |
|---|---|---|---|
| [#255](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/255) | P2 | Micker71 | Split Register-AssessmentCheck into one function per check |
| [#275](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/275) | P2 | Micker71 | Show end-of-life verdicts in the result JSON and the merged report |
| [#285](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/285) | P2 | JeanKadang | Ship an EOL snapshot with the scripts and refresh it monthly |
| [#286](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/286) | P2 | Micker71 | Detect the products for EOL checks in the pre-run and record them |
| [#137](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/137) | P3 | Micker71 | Report builder and RDP evidence functions are too large |
| [#153](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/153) | P3 | Micker71 | Dedicated cluster node assessment script |
| [#257](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/257) | P3 | Micker71 | Patch level uses the newest update of any kind |
| [#258](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/258) | P3 | Micker71 | Storage and platform: hard-coded C:, firmware type guess, PnP drivers enumerated repeatedly |
| [#259](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/259) | P3 | Micker71 | Group Policy and AD: a lookup failure drops groups already read; OS-dependent WMI filters; future dates |
| [#260](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/260) | P3 | Micker71 | SQL Server: an unknown future major version is a BLOCKER; PrintBrm edge cases |
| [#261](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/261) | P3 | Micker71 | Small runtime items: requires version, profile order, NotCompleted count, skipped-slow area, unelevated message |
| [#266](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/266) | P3 | JeanKadang | End-of-life dates for installed applications and runtimes, looked up off the server |
| [#276](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/276) | P3 | Micker71 | Recognise Windows Server 2008 and 2008 R2 as a source release |
| [#279](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/279) | P3 | Micker71 | VMware Tools: show how far behind the installed version is |
| [#287](https://github.com/JeanKadang/IPU-ReadinessAssessment/issues/287) | P3 | JeanKadang | ADR 0003: let the assessment read a local EOL snapshot |

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
