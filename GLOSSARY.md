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
_Avoid_: info, data

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
