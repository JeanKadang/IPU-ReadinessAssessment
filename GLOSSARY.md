# IPU Readiness Assessment

A read-only assessment of a Windows Server before an in-place upgrade (IPU): what would block the upgrade, what needs
work first, and what a person must still check. This file fixes the words used in the code, the result JSON, the
report and the guides.

## Language

### Results

**Result**:
One row the assessment records for one thing it looked at, with a status and a kind.
_Avoid_: row, line, item, check result

**Status**:
How serious a result is: `SPECIAL`, `BLOCKER`, `ACTION`, `WARNING`, `MANUAL`, `OK` or `INFO`, most serious first.
_Avoid_: severity, level, state

**Kind**:
What a result is for: a finding, an observation, a checklist item or evidence.
_Avoid_: type, category

**Finding**:
A result that counts towards the overall status. Its status is `SPECIAL`, `BLOCKER`, `ACTION`, `WARNING` or `MANUAL`.
_Avoid_: issue, problem, error

**Observation**:
A result that shows a status without changing the overall status.
_Avoid_: note, warning (a warning is a status)

**Evidence**:
A result that only documents what was found, such as an inventory entry.
_Avoid_: info, data, evidence copy (that is a file saved from the server)

**Overall status**:
The most serious status among the findings of one server, or `OK` when there are none.
_Avoid_: verdict, score, result (a result is one row)

### Collecting

**Check**:
One unit of collection with a stable id (for example `baseline`) that reads one part of the server and records results. A check that fails to complete is reported as `MANUAL`.
_Avoid_: test, probe, scan (a scan is one tool a check may run)

**Phase**:
Whether a check runs among the fast checks or last among the slow ones, which have a time budget.
_Avoid_: stage, pass

**Area**:
A named label on a result that says what it is about, such as the installed applications or the network. Each area belongs to exactly one chapter.
_Avoid_: category, section, group

**Chapter**:
A collapsible section of the report that holds the results of one or more areas.
_Avoid_: section, tab, page

**Check data**:
The facts the checks hand to each other and to the report while a run is in progress, such as the installed applications or the source release. Each piece has one owner.
_Avoid_: state, globals, context

**Owner**:
The one check (or, outside the checks, the runner, the report or the redaction code) that may write a piece of check data. Any check may read it.
_Avoid_: producer, writer, source
**Blocked check**:
A check that was not run because a check it needs stopped with an error or ran out of time. It is recorded as skipped, with a `MANUAL` result that names the check it needs.
_Avoid_: dependent check, failed check (it never ran)
**Checklist item**:
A result of kind checklist: a standard step of the change procedure. It never counts towards the overall status.
_Avoid_: task, to-do

### Recommended commands

**Read-only command**:
A command the report shows that only reads state and is safe to run at any time. The report labels it "Check".
_Avoid_: check (a check collects data), query

**Change command**:
A command the report shows that alters the server, to run in the change window after reading it. The report labels it "Change".
_Avoid_: fix, remediation (the assessment never changes a server itself)

### Runs and files

**Assessment script**:
The single PowerShell file that runs on one server, reads it without changing anything, and writes a report and a result JSON. Its fixed name is `Windows-IPU-Readiness-Assessment.ps1`.
_Avoid_: collector (kept only in names that exist: the `CollectorVersion` field, Collector coverage), tool, the assessment

**Merge script**:
The script that reads the result JSON files of many servers on an analysis machine and writes the fleet overview.
_Avoid_: aggregator, fleet tool

**EOL script**:
The script that makes the end-of-life data file and judges products against it, on an analysis machine.
_Avoid_: lifecycle tool

**Run**:
One execution of the assessment script on one server, in one mode.
_Avoid_: scan, job (a job belongs to the automation tool that starts the script), assessment

**Pre run**:
A run before the upgrade. It assesses readiness and writes the baseline.
_Avoid_: pre-check, before run

**Post run**:
A run after the upgrade. It verifies the server and compares it with the baseline.
_Avoid_: post-check, after run

**Baseline**:
The unredacted result JSON of a Pre run, which a Post run compares against.
_Avoid_: reference, before report

**Result JSON**:
The machine-readable file a run writes, holding all of its results. The Post run and the merge script read it.
_Avoid_: data file, output, assessment record

**Report**:
The HTML page a run writes for people to read, with the overall status, the chapters and the results.
_Avoid_: output, dashboard, summary

### The upgrade

**In-place upgrade (IPU)**:
Upgrading the operating system of a server by running Setup on it, keeping its roles, data and settings.
_Avoid_: update, upgrade in place (write it as one term), migration

**Migration**:
Building a new server and moving the workload to it, instead of upgrading the old one. The assessment does not assess it.
_Avoid_: clean install, side-by-side upgrade

**Source release**:
The Windows Server release installed on the server being assessed, for example 2016. The Post run reads the new release in the same place.
_Avoid_: current OS, current version, old version, from-version

**Target release**:
The Windows Server release the server is to be upgraded to: 2019, 2022 or 2025.
_Avoid_: destination, new version, target OS

**Upgrade path**:
A source release and a target release taken together, which is either supported for an in-place upgrade or not. It has nothing to do with file paths.
_Avoid_: route, supported combination

**Edition**:
The product tier of the operating system, such as Standard or Datacenter.
_Avoid_: SKU, flavour

**Installation option**:
Whether the server is Server Core or Desktop Experience.
_Avoid_: mode (a mode is Pre or Post), flavour

**Installation media**:
The folder, share or ISO that holds `setup.exe` for the target release.
_Avoid_: media image, install disk

**Installation image**:
The one edition inside the installation media's `install.wim` that Setup must be told to select. The report names it.
_Avoid_: media image, ISO

**Special server**:
A server that is not a standard in-place upgrade: a cluster node, or by site policy a domain controller. It needs its own plan, and its overall status is `SPECIAL`.
_Avoid_: exception, edge case

### End of life

**End of life (EOL)**:
The date after which the vendor no longer provides security fixes for a release. For Windows Server it is the end of extended support; paid Extended Security Updates run past it.
_Avoid_: end of support, expiry, sunset

**Product**:
A vendor product or platform, such as PHP, Veeam or Windows Server. The end-of-life data covers some products and names them as endoflife.date does.
_Avoid_: application, package, software (an application is one installed entry)

**Release**:
One version line of a product that is supported as a unit, such as PHP 8.2 or Windows Server 2022. The source release and the target release are releases of Windows Server.
_Avoid_: cycle (kept only in data and code names), branch, major version

**Tool release**:
A published version of these scripts, such as 4.6.0, with its zip and checksums.
_Avoid_: release (alone), build, version drop

**Candidate**:
A product the assessment script found on the server, with its version and how it was found. A candidate is only a candidate until it is compared with the EOL snapshot.
_Avoid_: detected product, inventory item

**EOL snapshot**:
The dated file of end-of-life data, made on a machine with internet access and copied to where the verdicts are made. The assessed server never fetches it.
_Avoid_: snapshot (alone), EOL database, lifecycle file

**EOL verdict**:
The judgement of one candidate against the EOL snapshot: supported, security-only, ending soon, end of life or unknown. A snapshot too old to confirm support turns supported and security-only into unconfirmed.
_Avoid_: result (a result is one row), status (a status is how serious a result is)

### Comparing

**Server snapshot**:
The state of one server recorded by a Pre run, such as ports, routes, tasks and printers, so that a Post run can report what changed.
_Avoid_: snapshot (alone), backup, image

**Comparison**:
What a Post run does: it reads the baseline and reports what was lost or changed since. `Comparison OK` means every compared list was compared and nothing was lost.
_Avoid_: diff, regression check

**Compared list**:
One kind of thing a Post run compares with the baseline: services, ports, routes, adapters, printers, tasks, applied policies and so on. It is compared only when both runs read it.
_Avoid_: item set, inventory (an inventory is evidence)

**Coverage**:
Whether a compared list could be compared. Baseline coverage is missing when the Pre run did not collect the list; current coverage is missing when the Post run could not read it. A list without coverage is named in a `MANUAL` result, never shown as nothing lost or everything lost.
_Avoid_: completeness, scope

### Saved from the server

**Evidence copy**:
A file or archive a run saves from the server for the change record, such as the exported Group Policy, the IIS configuration, the network configuration or the printer backup. It is not a result.
_Avoid_: evidence (alone, that is a result kind), attachment, dump

**Evidence folder**:
The restricted folder, readable by SYSTEM and Administrators only, that holds evidence copies.
_Avoid_: output folder, report folder

### Sharing a report

**Redaction**:
Replacing names, addresses and accounts in a report with placeholders so it can be shared outside the team. It is best effort: read the copy before sharing it.
_Avoid_: anonymisation, scrubbing, masking

**Placeholder**:
The stand-in for one original value, such as `HOST-1` or `IP-3`. The same original always gets the same placeholder within one redaction.
_Avoid_: token, alias, mask

**Redaction key**:
The file that says which placeholder stands for which original. It holds the real names, so it never leaves the team.
_Avoid_: translator, lookup table, map file

**Redacted copy**:
A copy of a report, result JSON or run log in which the identifying values are replaced. The original is not changed. A redacted copy cannot be a baseline.
_Avoid_: sanitised copy, anonymised report

### Site data

**Site data file**:
A JSON file that keeps a site's own settings or product patterns outside the script: a profile or a pattern file. If any entry is invalid, nothing from the file is applied and a `MANUAL` finding says why.
_Avoid_: config file, settings file

**Profile**:
A site data file with the site's defaults for parameters and its site policy.
_Avoid_: config, preset

**Pattern file**:
A site data file that adds, replaces or disables detection patterns.
_Avoid_: rules file, signature file

**Detection pattern**:
A name, service or driver pattern by which the assessment script recognises a vendor product.
_Avoid_: signature, rule (a rule decides, a pattern recognises)

**Site policy**:
A decision that belongs to the site rather than to Microsoft, such as which releases a PKI server may be upgraded to, or whether a domain controller is upgraded in place.
_Avoid_: custom rule, exception
