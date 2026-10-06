# IPU-ReadinessAssessment

In-place upgrade (IPU) readiness assessment suite for Windows Server. Collects
host data, checks it against Microsoft's supported upgrade paths and known
blockers, and produces an HTML and JSON report with a named recommendation per
finding.

## Repository layout

| Path | Contents |
|---|---|
| `src/` | Assessment script(s) |
| `tests/` | Pester 5 tests |
| `docs/` | Documentation |
| `.github/` | CI workflow and PR template |

## Requirements

- Windows PowerShell 5.1 or PowerShell 7
- [Pester](https://pester.dev) 5 (tests only)

## Usage

```powershell
.\src\Windows-IPU-Readiness-Assessment.ps1
```

## Testing

```powershell
Invoke-Pester .\tests -Output Detailed
```

Tests load the script in library mode (`IPU_ASSESSMENT_LIBRARY_ONLY=1`):
functions only, nothing is collected.

## License

GPL-3.0. See [LICENSE](LICENSE).
