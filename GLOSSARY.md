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
