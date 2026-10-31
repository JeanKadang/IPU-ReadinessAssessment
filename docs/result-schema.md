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
| `TargetServerVersion` | `2025`, `2022` or `2019` | Planned target |
| `Started`, `Completed` | `yyyy-MM-dd HH:mm:ss` | Local time on the server |
| `UtcOffset` | `+02:00`, `-05:30`, optional | The server's offset from UTC when it finished, so results from different time zones can be sorted as dates. Files from before 4.5.4 have none; readers then compare the local times as they are |
| `Partial` | boolean | `true` for the checkpoint written before the slow checks finished. If this is the newest file, the run was stopped early |
| `Redacted` | boolean, optional | `true` when the run used `-RedactReport` (see the [user guide](user-guide.md#sharing-a-report-redaction)). A redacted file cannot be the post-upgrade baseline, and the fleet overview treats each redacted file as its own server |
| `Overall` | `BLOCKER`, `ACTION`, `WARNING`, `MANUAL`, `OK` | Worst status among rows of kind `Finding` |
| `Counts` | object | Number of `Finding` rows per status: `BLOCKER`, `ACTION`, `WARNING`, `MANUAL` |
| `Facts` | object | The summary at the top of the report (below) |
| `Results` | array | Every row of the report (below) |
| `CheckRuns` | array | One entry per check: did it complete (below) |
| `Snapshot` | object | Server state used by the post-upgrade comparison (below) |
| `EolCandidates` | array, optional | Products with an end-of-life date found on the server, from 4.6.0 (below). Files from older versions have none |

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
| `Uac` | `On - prompt for consent for non-Windows programs (Windows default)` (from 4.2.0) |
| `AdLocation` | `corp.example.test/Servers/Web` (from 4.3.0; `Not applicable (workgroup)` for a workgroup server) |
| `SqlServer` | `MSSQLSERVER=SQL Server 2017` |
| `Activation` | `Licensed (KMS client), activated by kms01.corp.example.test:1688, found via DNS. Renewal due in 173 days` (from 4.5.0; before: `Status=Licensed, Channel=Volume:GVLK`) |
| `Nla` | `On`, `Off` or `Unknown`: RDP Network Level Authentication (from 4.5.0) |
| `CDrive` | `Size 100,00 GB, free 55,00 GB` |
| `CompatScan` | `0xC1900210 - Setup found no compatibility issues.` |

## `Special` (from 4.5.0)

`null` for a standard server. For a SPECIAL server (cluster node, or domain controller with `-BlockDomainControllerIPU`): `Kind` (`Cluster` or `DomainController`), `Title`, `Banner` (the plain-language text for the project and the customer), `Facts`, `Risks`, and `Options` (`Text`, `Url`, `Title`). `Overall` is then `SPECIAL` and `Counts.SPECIAL` is 1.

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
| `Command`, `CommandKind` | Optional (from 4.2.0). The exact command for the recommendation; `Check` = read-only, `Change` = run in the change window. The script only shows it, it never runs it |
| `Link`, `LinkTitle` | Optional (from 4.2.0). An official documentation page (https) and its title |

## `CheckRuns[]`

| Field | Meaning |
|---|---|
| `Id`, `Name` | Check id and display name |
| `Phase` | `Fast` or `Slow` |
| `Outcome` | `Completed`; `Failed` (the check threw; a `MANUAL` row explains it); `Skipped` (switched off, no media, or time budget used up); `TimedOut` (DISM, SFC or Setup stopped at its time limit) |
| `Duration` | `hh:mm:ss`, or `d.hh:mm:ss` |
| `Message` | Error message for a failed check |

## `EolCandidates`

One entry per product and version that the `eolcandidates` check found (ADR 0003, #286). The merge step and the assessment
compare them with an end-of-life snapshot (#275). A product that was not found is not listed, so an empty list means
"none found where the check looks", not "none installed". The version is never read by running the product.

| Field | Meaning |
|---|---|
| `Product` | [endoflife.date](https://endoflife.date) identifier: `mssqlserver`, `mysql`, `mariadb`, `postgresql`, `mongodb`, `oracle-database`, `ibm-db2`, `redis`, `apache-http-server`, `tomcat`, `nginx`, `php`, `dotnet`, `dotnetfx`, `powershell`, `python`, `nodejs`, `eclipse-temurin`, `oracle-jdk`, `amazon-corretto`, `microsoft-build-of-openjdk`, `openssl` |
| `Version` | Dotted number, for example `8.2.12` |
| `Source` | `Uninstall entry`, `Service file`, `File probe` or `Registry` |
| `Evidence` | The application name, service name or file name that matched (no path, no host name) |

## `Snapshot`

Lists may be empty or `null`.

| Field | Content |
|---|---|
| `Services` | `Name`, `State`, `StartMode` of every service |
| `Apps` | `Name`, `Version` of installed applications |
| `Features` | Installed Windows feature names. Left out when the feature inventory could not be read (the cmdlet failed or is missing), so the post-upgrade comparison names it as not compared; an empty list means the inventory was read and nothing is installed (#361) |
| `Ports` | Listening ports below 49152, for example `TCP:443` |
| `Routes` | Static routes, for example `10.50.0.0/16 via 10.20.30.1` |
| `IPv4`, `Dns` | IPv4 addresses and DNS servers of enabled adapters |
| `Adapters` | Per enabled adapter (from 4.5.0): `Name`, `Mac`, `IPv4`, `Mask`, `IPv6`, `Gateway`, `Dns`, `Suffix`, `SuffixSearch`, `RegisterInDns`, `RegisterSuffix`, `Wins`, `NetBios`, `Metric`, `Dhcp`, `Vlan`. The post-upgrade comparison matches adapters by `Mac` |
| `Hosts` | Active hosts-file entries |
| `Printers`, `PrinterPorts`, `PrinterDrivers` | On a print server (from 4.5.0): printer names, the ports they use, and `Printer`/`Driver` pairs. The post-upgrade comparison reports printers and ports that are gone and changed drivers |
| `Tasks` | Non-Microsoft scheduled tasks, for example `\Example\Nightly export` |
| `Ou` | The computer object's distinguished name in AD (from 4.3.0); the post-upgrade comparison reports a move |
| `Shares` | Names of shared folders (from 4.3.0); the post-upgrade comparison reports shares that are gone |
| `Gpos`, `Groups` | Applied GPO names and the computer's AD groups (from 4.2.0; absent when they could not be read). The post-upgrade comparison reports differences |
| `Uac` | User Account Control in plain words (from 4.2.0); the post-upgrade comparison reports a change |
| `Nla` | RDP Network Level Authentication, `On` or `Off` (from 4.4.0); the post-upgrade comparison reports NLA turned off as ACTION |
| `PortOwners` | For each listening port, the service or process that opened it (from 4.4.0); used to pair a closed port with a disabled service |

## Compatibility rules

- Adding an optional field keeps `IPU-Assessment/1`; readers must ignore what they do not know. The schema
  is updated in the same change.
- Removing or renaming a field, or changing its type or meaning, needs a new version (`IPU-Assessment/2`).
  `Merge-IPUAssessments.ps1` and the post-upgrade comparison must then handle both versions or say clearly
  which one they need.

## Example

[`samples/sample-result.json`](samples/sample-result.json) is a synthetic result for a fictional server,
generated by `build/New-SampleReport.ps1` together with [`samples/sample-report.html`](samples/sample-report.html).
