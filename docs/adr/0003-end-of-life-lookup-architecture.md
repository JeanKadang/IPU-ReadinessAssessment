# ADR 0003: Architecture and licensing for end-of-life (EOL) lookups

- **Status:** Proposed
- **Date:** 2026-10-23
- **Decided by:** maintainers (open), addressing issue #266
- **Origin:** first draft and proof of concept from pull request #271 (ayushkrsingh946), extended by the maintainers

## Context

Assessing Windows In-Place Upgrade (IPU) readiness means finding out what on a server is out of support or will
be soon: the operating system itself, and the products and runtimes on it (databases, web servers, PHP, Java,
.NET and so on). Software that is already past its end of life when the server is upgraded adds security and
compliance risk, and often cannot be fixed by the upgrade.

Constraints:

1. Target servers assessed through OpenText Server Automation (SA) are often in isolated network segments with
   no outbound internet access.
2. A call from the assessment script to a third-party API would break zero-egress policies and could leak the
   server's software inventory. The script stays read-only and offline (see `AGENTS.md`).
3. The data comes from `endoflife.date`. Its repository (`endoflife-date/endoflife.date`) states "Licensed under the MIT
   License" (Copyright 2020 endoflife.date contributors); its product descriptions are adapted from Wikipedia under
   CC BY-SA 3.0, which we do not use (we copy release names and dates only). The MIT licence lets us copy and
   redistribute the data if the copyright and permission notice come with it. (The first draft of this ADR, in
   pull request #271, said CC BY 4.0; that was checked against the source and is wrong.)
4. This project is licensed under GPL-3.0. MIT data is compatible with that: it is facts used as input, not code
   merged into the program. This is the maintainers' reading, not legal advice.

## Decision

**Offline snapshot. The assessed server never calls the network; it may read a local snapshot file.**

1. **The assessment script on the server makes no network call and fetches nothing.** It detects the products in
   scope and records them and their versions in the result JSON as EolCandidates (#286). It may *read* a snapshot
   file that is already on the server (decision 6): reading a file is no network access and leaks nothing.
2. **The operating system's own end-of-support date stays on the server** as the small verified fact table
   `$script:ReleaseEndOfSupport` (`Get-SupportLifecycleDecision`, #232). It is the one date that matters on
   every run, it needs no data file, and it changes about once a year.
3. **Everything else is evaluated centrally** by `src/Get-IPUEolStatus.ps1`, on an analysis machine, from a
   snapshot file (`asOf`, `source`, `products.<slug>` = the releases from `endoflife.date`). The merge step
   (`Merge-IPUAssessments.ps1`) will call the same function for a fleet report.
4. **The snapshot is one dated JSON file** made by `Get-IPUEolStatus.ps1 -Update -SnapshotPath <file>` on a machine
   with internet access and copied by hand to where the verdicts are made (#283). It is not fetched by the assessed
   server. A snapshot older than `-MaxAgeMonths` (default 6, like the dated facts in `FactSources`) cannot confirm
   that a release is still supported: Supported and SecurityOnly become MANUAL with the snapshot age, while
   EndOfLife and EndingSoon still show, because end dates rarely move earlier. A snapshot without a usable date
   counts as too old. `-Online` is a one-off lookup for an analysis machine with internet access; the assessment
   script never calls it.
5. **The verdict is a pure function** (`Get-EolDecision`: releases, version and today's date in, verdict out)
   with Pester tests, as the hard rules require.
6. **The assessment looks for a local snapshot at the end of a run** (decided by the maintainers on 2026-10-23, #287)
   in this order: `-EolSnapshotPath`, the folder the script is in, the report folder. It compares the
   `EolCandidates` with it and adds EOL rows, with the same age limit and the same MANUAL-when-too-old rule as
   decision 4. No snapshot found is one INFO row saying where it looked, never a clean result. SA may deploy only
   the `.ps1`, so the user guide tells operators to copy the snapshot next to it (#285).
7. **The EOL functions are one shared source part**, built into both the assessment (a single file for SA, ADR
   0002) and `Get-IPUEolStatus.ps1`, so the two cannot drift apart. The merge step reads the snapshot too and
   gives the fleet view (#275).

**Verdicts.** `Supported` (OK), `SecurityOnly` (INFO: active support is over, end of life is later),
`EndingSoon` (INFO: end of life within 180 days), `EndOfLife` (WARNING), `Unknown` (MANUAL). A product or
version that cannot be matched is MANUAL, never OK. `eol: false` in the data means no end date is published;
it is shown as supported with a note that this is not a promise.

**Matching.** A version matches the release whose number is the longest prefix of it, compared segment by
segment (`1.10.3` is release `1.10`, not `1.1`). A suffix on the release name (`13.0-sp3`) is ignored for the
match. Windows Server is matched by release name, because `2012` and `2012-r2` are different releases: the build
number is mapped to the name (`10.0.20348` is `2022`, `6.3.9600` is `2012-r2`). All of Windows Server 2008,
2008 R2, 2012, 2012 R2, 2016, 2019, 2022 and 2025 are covered; `endoflife.date` lists 2008 and 2008 R2 by
service pack (`2008-sp2`, `2008-r2-sp1`). The `eol` date is the end of extended support; paid Extended
Security Updates (2008 to 2012 R2) run past it and are not in the data, so the text for those releases must
not say a server is unprotected.

**Product list.** Identifiers are checked against `https://endoflife.date/api/all.json` before they are added,
because a wrong one fails quietly. First list:

- Operating system: `windows-server` (2008, 2008 R2, 2012, 2012 R2, 2016, 2019, 2022, 2025)
- Databases: `mssqlserver`, `mysql`, `mariadb`, `postgresql`, `mongodb`, `oracle-database`, `ibm-db2`, `redis`
- Web and application servers: `apache-http-server`, `tomcat`, `nginx`
- Languages and runtimes: `php`, `dotnet`, `dotnetfx`, `powershell`, `python`, `nodejs`, `openssl`, and Java
  as `eclipse-temurin`, `oracle-jdk`, `amazon-corretto`, `microsoft-build-of-openjdk`

Not in the first list: SharePoint, Citrix, Veeam and Commvault (their release names are not plain numbers and
need their own matching), IIS (follows the operating system), and products `endoflife.date` does not track.

**Attribution and licence notice (MIT).** Every snapshot carries the licence name, the copyright line and the full MIT
permission notice (`license`, `attribution`, `licenseNotice`). Documentation, release notes and report output that
show EOL data carry: `End-of-life data from endoflife.date (https://endoflife.date), MIT License, Copyright 2020
endoflife.date contributors.` The snapshot file also records the date it was taken.

## Consequences

- The assessed server stays 100% offline and read-only; EOL needs no network, API key or rate limit there.
- Verdicts are only as fresh as the snapshot. The shown snapshot date and the refresh pull request are the
  mitigation; a snapshot more than a few months old should be called out in the report.
- Detection is the larger open problem. A product that leaves no uninstall entry (PHP and Apache HTTP Server on
  Windows are often unpacked folders) will not be seen until the script learns to probe for it. Until then the
  report cannot say a server has no such software, only that none was found.
- The assessment script itself does not yet recognise 2008 and 2008 R2 as a source release (its release table
  starts at 2012), so on those servers the upgrade-path and support rows fall back to MANUAL. Teaching it the two
  releases (#276) is a separate change, because it touches the upgrade-path rules.
- Follow-up work: the shared source part and the build change for it (#275), the shipped snapshot and its monthly
  refresh (#285), detection of the products and the `EolCandidates` field in the result JSON (#286), the verdicts in
  the merged report (#275), and recognising 2008 and 2008 R2 as a source release (#276). Tracked on #266.
