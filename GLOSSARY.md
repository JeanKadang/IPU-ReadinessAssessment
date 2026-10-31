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
