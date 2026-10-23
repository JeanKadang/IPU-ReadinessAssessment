## Summary

<!-- What and why -->

Refs #

## Validation

- [ ] `Invoke-Pester .\tests` passes
- [ ] `build/Invoke-CiLint.ps1 -FailOn Warning` passes
- [ ] Source changes were made in `src/assessment/` and `build/Build-Script.ps1` was run (the built file is committed)
- [ ] `CHANGELOG.md` has an entry under *Unreleased* (user-visible changes)
- [ ] `docs/checks.md` is updated for a new or changed check
- [ ] The sample was regenerated (`build/New-SampleReport.ps1`) if the report changed
- [ ] Docs updated if behaviour changed
- [ ] No host data in this PR (hostnames, accounts, report output, customer names)
- [ ] Redaction was considered for any newly collected name, address or account
