# How the build works

The assessment that operators run through OpenText Server Automation (SA) is one file,
`src/Windows-IPU-Readiness-Assessment.ps1`. Since 4.5.0 its source is kept in **parts**, and a small build
script joins them into that one file ([ADR 0002](adr/0002-source-in-parts-built-into-one-file.md)).

**For operators nothing changes:** download `Windows-IPU-Readiness-Assessment.ps1` from the Release page and run it
through SA, as before.

## The parts

`src/assessment/` holds the parts, one per numbered section of the script:

| Part | Contents |
|---|---|
| `00-header.ps1` | Comment header, synopsis, parameters help, version history |
| `10-parameters.ps1` | The `param()` block (the defaults SA uses) |
| `20-detection-patterns.ps1` | Built-in detection patterns |
| `25-eol-core.ps1` | End-of-life rules and product tables, **shared** with `Get-IPUEolStatus.ps1` and `Merge-IPUAssessments.ps1` (see below) |
| `30-core.ps1` | Shared helpers: results, logging, CIM/registry access, redaction |
| `40-decision-rules.ps1` | Pure decision functions (unit-tested) |
| `50-checks.ps1` | The checks that collect data |
| `60-report.ps1` | HTML and JSON report |
| `70-main.ps1` | Main flow |

`src/assessment/manifest.txt` lists the parts in build order. Parts can be split further later; add the new file to
the manifest.

## Making a change

1. Edit the part (never the built file).
2. Build: `pwsh ./build/Build-Script.ps1`
3. Run the tests: `Invoke-Pester ./tests`
4. Commit the changed part **and** the rebuilt `src/Windows-IPU-Readiness-Assessment.ps1`.

## What the build does and checks

- Joins the parts in manifest order, byte for byte. The same parts always give the same file.
- Refuses a part with LF line endings, non-ASCII text or a byte-order mark, a part listed twice, a missing part, and a
  `.ps1` in `src/assessment/` that the manifest does not list.
- `-Check` builds in memory and compares with the committed file. CI runs it in the `lint` job, so a hand edit of the
  built file or a forgotten rebuild fails the pull request.

The built file stays committed at its old path, so the tests, the smoke test, the release workflow, the checksums and
every link in the documentation keep working unchanged. Tests and CI test exactly the file operators run.

## Three more built scripts (ADR 0003, #275)

`Get-IPUEolStatus.ps1` and `Merge-IPUAssessments.ps1` are built the same way, from `src/eol/` and `src/merge/` (each
with its own `manifest.txt`):

```powershell
pwsh ./build/Build-Script.ps1 -Manifest src/eol/manifest.txt   -OutputPath src/Get-IPUEolStatus.ps1
pwsh ./build/Build-Script.ps1 -Manifest src/merge/manifest.txt -OutputPath src/Merge-IPUAssessments.ps1
```

The end-of-life functions (the verdict rules and the product tables) are one shared part,
`src/assessment/25-eol-core.ps1`, listed in all three manifests as `../assessment/25-eol-core.ps1`, so the
assessment, the EOL script and the merge step give the same verdict and cannot drift apart. Edit it once, then rebuild
all three. CI checks each built file against its parts.

## Later: a second script

A dedicated cluster assessment (#153) can get its own manifest that lists the shared parts (report, redaction, JSON,
logging, prerequisites) plus its own checks, built into a second single file.
