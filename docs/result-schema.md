# Result file format (`IPU-Assessment/1`)

Every run writes a JSON file next to the HTML report:

| Run | File |
|---|---|
| `-AssessmentMode Pre` (default) | `<Computer>-IPU-Assessment.json` |
| `-AssessmentMode Post` | `<Computer>-IPU-PostUpgrade.json` |

The JSON holds the same rows as the HTML report plus a **snapshot** of the server. It is used for two
things:

- `Merge-IPUAssessments.ps1` combines the files of many servers into a fleet overview.
- The post-upgrade run reads the pre-upgrade file of the same server as its **baseline** and reports what
  changed. Keep the pre-upgrade file on the server (in the report folder) until after the upgrade.

The formal definition is [`result-schema.json`](result-schema.json) (JSON Schema draft-07). CI runs the
real script on Windows PowerShell 5.1 and PowerShell 7 and validates both files against it.

## Top level

| Field | Type | Meaning |
|---|---|---|
| `Schema` | `"IPU-Assessment/1"` | Format version. Readers must reject other values |
| `CollectorVersion` | string, `x.y.z` | Script version that wrote the file |
| `ComputerName` | string | Server name |
| `Mode` | `Pre` or `Post` | Which run wrote the file |
| `TargetServerVersion` | `2025` or `2022` | Planned target |
| `Started`, `Completed` | `yyyy-MM-dd HH:mm:ss` | Local time on the server |
| `Partial` | boolean | `true` for the checkpoint written before the slow checks finished. If this is the newest file, the run was stopped early |
| `Redacted` | boolean, optional | `true` when the run used `-RedactReport` (see the [user guide](user-guide.md#sharing-a-report-redaction)). A redacted file cannot be the post-upgrade baseline, and the fleet overview treats each redacted file as its own server |
| `Overall` | `BLOCKER`, `ACTION`, `WARNING`, `MANUAL`, `OK` | Worst status among rows of kind `Finding` |
| `Counts` | object | Number of `Finding` rows per status: `BLOCKER`, `ACTION`, `WARNING`, `MANUAL` |
| `Facts` | object | The summary at the top of the report (below) |
| `Results` | array | Every row of the report (below) |
| `CheckRuns` | array | One entry per check: did it complete (below) |
| `Snapshot` | object | Server state used by the post-upgrade comparison (below) |

## `Facts`

Strings, empty or `null` when the check that sets them did not run.

| Field | Example |
|---|---|
| `CurrentOS` | `Microsoft Windows Server 2016 Standard \| Build=14393.7428 \| ...` |
| `SourceRelease` | `2016` |
| `UpgradePath` | `Supported in-place upgrade path: Windows Server 2016 to Windows Server 2025.` |
| `RecommendedMedia` | `Windows Server 2025 Standard (Desktop Experience) - en-US media` |
| `Platform` | `Virtual (VMware) \| Manufacturer=VMware, Inc. \| ...` |
| `DomainRole` | `Member server` |
| `SqlServer` | `MSSQLSERVER=SQL Server 2017` |
| `Activation` | `Status=Licensed, Channel=Volume:GVLK` |
| `CDrive` | `Size 100,00 GB, free 55,00 GB` |
| `CompatScan` | `0xC1900210 - Setup found no compatibility issues.` |

## `Results[]`

| Field | Meaning |
|---|---|
| `CheckId` | Check that wrote the row (see [checks reference](checks.md)); `core` or `postcompare` for rows written outside a check |
| `Area` | Report area, upper case (for example `UPGRADE_PATH`, `STORAGE`) |
| `Item` | What the row is about |
| `Status` | `BLOCKER`, `ACTION`, `WARNING`, `MANUAL`, `OK`, `INFO` |
| `Kind` | `Finding` (counts towards `Overall`), `Observation` (status for visibility only), `Checklist` (standard change step), `Evidence` (inventory) |
| `Value`, `Details` | What was found; `Details` joins several parts with ` \| ` |
| `Recommendation` | What to do, empty when nothing is needed |
| `Source` | Where the value came from |

## `CheckRuns[]`

| Field | Meaning |
|---|---|
| `Id`, `Name` | Check id and display name |
| `Phase` | `Fast` or `Slow` |
| `Outcome` | `Completed`; `Failed` (the check threw; a `MANUAL` row explains it); `Skipped` (switched off, no media, or time budget used up); `TimedOut` (DISM, SFC or Setup stopped at its time limit) |
| `Duration` | `hh:mm:ss`, or `d.hh:mm:ss` |
| `Message` | Error message for a failed check |

## `Snapshot`

Lists may be empty or `null`.

| Field | Content |
|---|---|
| `Services` | `Name`, `State`, `StartMode` of every service |
| `Apps` | `Name`, `Version` of installed applications |
| `Features` | Installed Windows feature names |
| `Ports` | Listening ports below 49152, for example `TCP:443` |
| `Routes` | Static routes, for example `10.50.0.0/16 via 10.20.30.1` |
| `IPv4`, `Dns` | IPv4 addresses and DNS servers of enabled adapters |
| `Hosts` | Active hosts-file entries |
| `Tasks` | Non-Microsoft scheduled tasks, for example `\Example\Nightly export` |

## Compatibility rules

- Adding an optional field keeps `IPU-Assessment/1`; readers must ignore what they do not know. The schema
  is updated in the same change.
- Removing or renaming a field, or changing its type or meaning, needs a new version (`IPU-Assessment/2`).
  `Merge-IPUAssessments.ps1` and the post-upgrade comparison must then handle both versions or say clearly
  which one they need.

## Example

[`samples/sample-result.json`](samples/sample-result.json) is a synthetic result for a fictional server,
generated by `build/New-SampleReport.ps1` together with [`samples/sample-report.html`](samples/sample-report.html).
