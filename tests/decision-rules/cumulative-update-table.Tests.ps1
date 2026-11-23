# Pester 5 tests. The cumulative update table (#267, #457): build and UBR to KB, release month, months behind.
# The script is loaded in library mode by ..\TestSetup.ps1: functions only, nothing is collected.
# The table below is test data, not the shipped table.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestSetup.ps1')
    $script:Json = @'
{
  "schema": "IPU-CuTable/1",
  "asOf": "2026-11-20",
  "source": "test data",
  "releases": {
    "20348": [
      { "ubr": 2113, "kb": "KB1000001", "released": "2023-11-14" },
      { "ubr": 2200, "kb": "KB1000002", "released": "2024-01-09" },
      { "ubr": 2250, "kb": "KB1000003", "released": "2024-01-23", "type": "D" },
      { "ubr": 2300, "kb": "KB1000004", "released": "2024-02-13", "type": "B" },
      { "ubr": 2310, "kb": "KB1000005", "released": "2024-02-20", "type": "OOB" }
    ],
    "26100": [
      { "ubr": 1, "kb": "KB2000001", "released": "2024-11-12" }
    ]
  }
}
'@
    $script:Table = $script:Json | ConvertFrom-Json
}

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'Get-CumulativeUpdateLookup (#267)' {
    It 'a build and UBR in the table give the KB, the release month and the months behind the newest' {
        $r = Get-CumulativeUpdateLookup $script:Table '20348.2113'
        $r.Kind | Should -Be 'Found'
        $r.Kb | Should -Be 'KB1000001'
        $r.Month | Should -Be '2023-11'
        $r.MonthsBehind | Should -Be 3
        $r.NewestKb | Should -Be 'KB1000004'
        $r.TableDate | Should -Be '2026-11-20'
    }
    It 'the newest monthly release is 0 months behind' {
        $r = Get-CumulativeUpdateLookup $script:Table '20348.2300'
        $r.Kind | Should -Be 'Found'; $r.MonthsBehind | Should -Be 0
    }
    It 'a preview or out-of-band release is found; only a monthly release is the newest unless the server is on a later one' {
        (Get-CumulativeUpdateLookup $script:Table '20348.2250').MonthsBehind | Should -Be 1
        $oob = Get-CumulativeUpdateLookup $script:Table '20348.2310'
        $oob.Kind | Should -Be 'Found'; $oob.MonthsBehind | Should -Be 0; $oob.NewestKb | Should -Be 'KB1000005'
    }
    It 'a build with one row is its own newest' {
        $r = Get-CumulativeUpdateLookup $script:Table '26100.1'
        $r.Kind | Should -Be 'Found'; $r.MonthsBehind | Should -Be 0
    }
    It 'a UBR that is not in the table for a covered build is MANUAL, never OK' {
        $r = Get-CumulativeUpdateLookup $script:Table '20348.9999'
        $r.Kind | Should -Be 'UnknownUbr'; $r.Status | Should -Be 'MANUAL'
        $r.MonthsBehind | Should -BeNullOrEmpty
    }
    It 'a build the table does not cover is INFO, so the update date stays the only age' {
        $r = Get-CumulativeUpdateLookup $script:Table '9600.20000'
        $r.Kind | Should -Be 'NoRelease'; $r.Status | Should -Be 'INFO'
    }
    It 'a build text that cannot be read is MANUAL' {
        foreach ($text in @('', '20348', 'abc.def', '20348.')) {
            $r = Get-CumulativeUpdateLookup $script:Table $text
            $r.Kind | Should -Be 'BadBuild'; $r.Status | Should -Be 'MANUAL'
        }
    }
    It 'no table is INFO and says where to get it' {
        $r = Get-CumulativeUpdateLookup $null '20348.2113'
        $r.Kind | Should -Be 'NoTable'; $r.Status | Should -Be 'INFO'; $r.Recommendation | Should -Match 'cu-table.json'
    }
    It 'a table that fails the check is MANUAL with the problems, not read half' {
        $bad = $script:Json.Replace('KB1000002', 'nonsense') | ConvertFrom-Json
        $r = Get-CumulativeUpdateLookup $bad '20348.2113'
        $r.Kind | Should -Be 'BadTable'; $r.Status | Should -Be 'MANUAL'
        ($r.Details -join ' ') | Should -Match 'nonsense'
    }
    It 'a date that ConvertFrom-Json already turned into a [datetime] works the same' {
        $dated = $script:Json | ConvertFrom-Json
        $dated.asOf = [datetime]'2026-11-20'
        $dated.releases.'20348'[0].released = [datetime]'2023-11-14'
        (Get-CumulativeUpdateLookup $dated '20348.2113').Month | Should -Be '2023-11'
    }
    It 'months are counted across a year boundary' {
        $cross = $script:Json | ConvertFrom-Json
        $cross.releases.'20348'[0].released = '2023-12-12'
        (Get-CumulativeUpdateLookup $cross '20348.2113').MonthsBehind | Should -Be 2
        $cross.releases.'20348'[0].released = '2022-12-13'
        (Get-CumulativeUpdateLookup $cross '20348.2113').MonthsBehind | Should -Be 14
    }
}

Describe 'Test-CuTableContent (#267)' {
    It 'the test table is fine' { @(Test-CuTableContent $script:Table).Count | Should -Be 0 }
    It 'an empty or schema-less table is not' {
        @(Test-CuTableContent $null).Count | Should -BeGreaterThan 0
        @(Test-CuTableContent ('{"releases":{}}' | ConvertFrom-Json)).Count | Should -BeGreaterThan 0
    }
    It 'each kind of bad row is named' {
        $cases = @(
            @{ From = '"ubr": 2113'; To = '"ubr": "x"'; Match = 'ubr' },
            @{ From = 'KB1000001'; To = 'KB1'; Match = 'kb' },
            @{ From = '2023-11-14'; To = '14/11/2023'; Match = 'released' },
            @{ From = '"type": "D"'; To = '"type": "Z"'; Match = 'type' },
            @{ From = '"ubr": 2200'; To = '"ubr": 2113'; Match = 'twice' },
            @{ From = '"26100"'; To = '"win11"'; Match = 'build number' },
            @{ From = '2026-11-20'; To = 'yesterday'; Match = 'asOf' }
        )
        foreach ($c in $cases) {
            $t = $script:Json.Replace($c.From, $c.To) | ConvertFrom-Json
            (@(Test-CuTableContent $t) -join ' ') | Should -Match $c.Match
        }
    }
}

Describe 'Get-CuTableSearchPath (#267)' {
    It 'an explicit file or folder comes first, then the script folder, then the report folder' {
        @(Get-CuTableSearchPath 'D:\data\t.json' 'C:\s' 'C:\r') | Should -Be @('D:\data\t.json', 'C:\s\cu-table.json', 'C:\r\cu-table.json')
        @(Get-CuTableSearchPath 'D:\data' 'C:\s' 'C:\r')[0] | Should -Be 'D:\data\cu-table.json'
    }
    It 'folders that are blank or the same are listed once' {
        @(Get-CuTableSearchPath '' 'C:\s' 'C:\s').Count | Should -Be 1
        @(Get-CuTableSearchPath '' '' '').Count | Should -Be 0
    }
}

Describe 'Get-CumulativeUpdateDecision (#267, #458)' {
    BeforeAll { $script:Now = [datetime]'2026-11-23' }
    It 'the newest update is OK, and says so' {
        $d = Get-CumulativeUpdateDecision (Get-CumulativeUpdateLookup $script:Table '20348.2300') 2 $script:Now
        $d.Status | Should -Be 'OK'; $d.Kind | Should -Be 'Observation'; $d.Value | Should -Match 'KB1000004 released 2024-02'
    }
    It 'up to the limit is OK, and names the months behind' {
        $d = Get-CumulativeUpdateDecision (Get-CumulativeUpdateLookup $script:Table '20348.2200') 2 $script:Now
        $d.Status | Should -Be 'OK'; $d.Value | Should -Match '1 month\(s\) behind'
    }
    It 'more than the limit is a WARNING that names the update to install' {
        $d = Get-CumulativeUpdateDecision (Get-CumulativeUpdateLookup $script:Table '20348.2113') 2 $script:Now
        $d.Status | Should -Be 'WARNING'; $d.Kind | Should -Be 'Finding'
        $d.Value | Should -Match '3 months behind'; $d.Recommendation | Should -Match 'KB1000004'
    }
    It 'an unknown UBR is a MANUAL finding' {
        $d = Get-CumulativeUpdateDecision (Get-CumulativeUpdateLookup $script:Table '20348.9999') 2 $script:Now
        $d.Status | Should -Be 'MANUAL'; $d.Kind | Should -Be 'Finding'
    }
    It 'no table and an uncovered build are observations, not findings' {
        foreach ($lookup in @((Get-CumulativeUpdateLookup $null '20348.1'), (Get-CumulativeUpdateLookup $script:Table '9600.1'))) {
            $d = Get-CumulativeUpdateDecision $lookup 2 $script:Now
            $d.Status | Should -Be 'INFO'; $d.Kind | Should -Be 'Observation'
        }
    }
    It 'a bad build text and a bad table are MANUAL findings' {
        (Get-CumulativeUpdateDecision (Get-CumulativeUpdateLookup $script:Table 'x') 2 $script:Now).Status | Should -Be 'MANUAL'
        $bad = $script:Json.Replace('KB1000002', 'zzz') | ConvertFrom-Json
        (Get-CumulativeUpdateDecision (Get-CumulativeUpdateLookup $bad '20348.2113') 2 $script:Now).Status | Should -Be 'MANUAL'
    }
    It 'a table older than 60 days says so; a fresh one does not' {
        $old = Get-CumulativeUpdateDecision (Get-CumulativeUpdateLookup $script:Table '20348.2300') 2 ([datetime]'2027-03-01')
        ($old.Details -join ' ') | Should -Match 'table is dated 2026-11-20'
        $fresh = Get-CumulativeUpdateDecision (Get-CumulativeUpdateLookup $script:Table '20348.2300') 2 $script:Now
        ($fresh.Details -join ' ') | Should -Not -Match 'table is dated'
    }
}
