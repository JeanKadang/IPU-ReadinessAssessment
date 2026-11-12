# User guide: test and contribute

For the developer who changes the scripts or runs the tests. Part of the [user guide](user-guide.md). The other parts: [run the assessment](user-guide-run.md), [read the result](user-guide-read-result.md), [fleet overview](user-guide-fleet.md).

## Running the tests

```powershell
Invoke-Pester .\tests -Output Detailed
```

Requires Pester 5 or newer (CI uses 6.2.0) on Windows. The tests load the script in library mode by setting
`IPU_ASSESSMENT_LIBRARY_ONLY=1`, so functions are defined but nothing is collected from the machine.

| Folder or file | Covers |
|---|---|
| `tests/core/` | The runtime (check runner, native tools, time limits, output folders, the SA result line, prerequisites), read-only system helpers and evidence copies, site data files, and repository-wide rules (version consistency, no host data, dated facts) |
| `tests/decision-rules/` | The pure decision functions, one file per topic: upgrade path and edition, licensing, Windows health (DISM, SFC, VSS), workloads and detection patterns, Group Policy and access, end of life |
| `tests/checks/` | Every check body, run against a simulated server (`FakeServer.ps1`: stand-ins for CIM, registry, native tools and cmdlets), one file per chapter of `docs/checks.md`; also that `docs/checks.md` lists every check and that the sample result matches the JSON Schema |
| `tests/report/` | Result model, overall status, the HTML report and the result JSON |
| `tests/redaction/` | Redaction of a live run, the redaction key, and `-RedactExisting` |
| `tests/post-upgrade/` | The post-upgrade comparison rules and the Post run |
| `tests/Merge-IPUAssessments.Tests.ps1` | The fleet overview, CSV formula protection, redacted results |
| `tests/Eol.Tests.ps1` | The end-of-life lookup script |

The full suite runs in an elevated or a normal (unelevated) session, with the same result: CI runs it both ways, the
second time as a standard local user (`pester (unelevated)`, #126). Unelevated, the folders that the tests limit to
SYSTEM and Administrators also keep your own account, so the tests can use and remove them; a real assessment run
never does that. Tests tagged
`Integration` start real processes and read the real registry, local accounts and Group Policy; skip them with:

```powershell
Invoke-Pester .\tests -Output Detailed -ExcludeTagFilter Integration
```

CI also runs PSScriptAnalyzer (`build/Invoke-CiLint.ps1`) and an end-to-end smoke test of the real script
(`build/Invoke-SmokeTest.ps1`); see [CONTRIBUTING.md](../CONTRIBUTING.md#what-ci-runs).
