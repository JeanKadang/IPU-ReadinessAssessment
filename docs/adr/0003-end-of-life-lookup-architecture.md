# ADR 0003: Architecture and Licensing for End-of-Life (EOL) Lookups

- **Status:** Proposed
- **Date:** 2026-10-23
- **Decided by:** Maintainers, addressing issue #266

## Context

Assessing Windows In-Place Upgrade (IPU) readiness requires identifying installed applications and runtimes that have reached or are approaching End-of-Life (EOL). Running unsupported runtimes on newly upgraded Windows Server instances introduces compliance and security risks.

Constraints:
1. Target servers evaluated by OpenText Server Automation (SA) are frequently in isolated or air-gapped network segments with no outbound internet connectivity.
2. Direct on-box outbound HTTP calls to third-party APIs during the assessment script execution would violate zero-egress policies and risk leaking installed inventory metadata.
3. Third-party EOL data from `endoflife.date` is licensed under Creative Commons Attribution 4.0 International (CC BY 4.0). Use in commercial or open-source tools requires explicit attribution, license notice, and indication of changes.

## Decision

Adopt **Option 3: Offline Bundled Snapshot with Optional Central Aggregator Lookup**:

1. **Architecture**:
   - The on-target assessment script (`Windows-IPU-Readiness-Assessment.ps1`) remains strictly offline and self-contained. It collects normalized product names and version strings via registry/WMI as part of existing inventory checks.
   - EOL evaluation is decoupled into an offline snapshot lookup or performed centrally during report merging (`Merge-IPUAssessments.ps1`).
   - A curated snapshot `eol-cache.json` is generated periodically at build/release time from `endoflife.date` and embedded/bundled.
   - For environments with controlled proxy access, a standalone lookup tool `Get-EolStatus.ps1` is provided for central analysis servers.

2. **Curated Product Whitelist**:
   To prevent false positives from generic registry display names, lookups are restricted to an explicit whitelist of 5 core enterprise runtimes:
   - Microsoft .NET / .NET Framework (`dotnet`, `dotnetfx`)
   - PowerShell (`powershell`)
   - Java / OpenJDK (`temurin`, `oracle-jdk`)
   - Python (`python`)
   - Node.js (`nodejs`)

3. **CC BY 4.0 Compliance**:
   - In accordance with CC BY 4.0 Section 3(a)(1), the documentation, release notes, and report output must include:
     `"End-of-life data sourced from endoflife.date under CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/)"`.

## Consequences

- Target execution remains 100% air-gap compliant with no outbound network dependencies.
- No third-party API keys or rate limits impact target node assessment execution.
- CC BY 4.0 legal requirements are fully respected without encumbering the project's Apache 2.0 / MIT licensing.
