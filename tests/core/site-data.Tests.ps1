# Pester 5 tests. Site data files: profile and detection-pattern files.
# The script is loaded in library mode by ..\TestSetup.ps1: functions only, nothing is collected.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
param()

BeforeAll { . (Join-Path $PSScriptRoot '..\TestSetup.ps1') }

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'Site data files (#32)' {
    Context 'ConvertFrom-SiteDataJson' {
        It 'returns the object when the schema matches' {
            (ConvertFrom-SiteDataJson '{ "Schema": "IPU-Profile/1", "Settings": {} }' 'IPU-Profile/1').Schema | Should -Be 'IPU-Profile/1'
        }
        It 'rejects <Case>' -TestCases @(
            @{ Case = 'an empty file';      Text = '   ';                              Message = 'empty' }
            @{ Case = 'invalid JSON';       Text = '{ "Schema": ';                     Message = 'not valid JSON' }
            @{ Case = 'a JSON array';       Text = '[ 1, 2 ]';                          Message = 'one JSON object' }
            @{ Case = 'a missing schema';   Text = '{ "Settings": {} }';                Message = 'Schema must be' }
            @{ Case = 'another schema';     Text = '{ "Schema": "IPU-Patterns/1" }';    Message = 'Schema must be' }
        ) {
            { ConvertFrom-SiteDataJson $Text 'IPU-Profile/1' } | Should -Throw ('*' + $Message + '*')
        }
    }

    Context 'Merge-DetectionPatternSet' {
        BeforeAll {
            function New-PatternFile([string]$Json) { ConvertFrom-SiteDataJson ('{ "Schema": "IPU-Patterns/1", ' + $Json + ' }') 'IPU-Patterns/1' }
        }
        It 'adds, replaces and disables entries by Label and leaves the built-in table untouched' {
            $before = @($script:DetectionPatterns.Workloads).Count
            $file = New-PatternFile '"EndpointProtection": [ { "Label": "Contoso EDR", "Service": "^CtsEdr$" }, { "Label": "sophos", "App": "^Sophos Central" } ], "Workloads": [ { "Label": "Boomi", "Disabled": true } ]'
            $r = Merge-DetectionPatternSet $script:DetectionPatterns $file
            @($r.Errors).Count | Should -Be 0
            ($r.Changes -join '; ') | Should -Be 'EndpointProtection: added "Contoso EDR"; EndpointProtection: replaced "sophos"; Workloads: disabled "Boomi"'
            @($r.Patterns.EndpointProtection | Where-Object { $_.Label -eq 'Contoso EDR' }).Count | Should -Be 1
            $sophos = @($r.Patterns.EndpointProtection | Where-Object { $_.Label -ieq 'Sophos' })
            $sophos.Count | Should -Be 1
            $sophos[0].App | Should -Be '^Sophos Central'
            $sophos[0].ContainsKey('Driver') | Should -BeFalse
            @($r.Patterns.Workloads | Where-Object { $_.Label -eq 'Boomi' }).Count | Should -Be 0
            @($script:DetectionPatterns.Workloads).Count | Should -Be $before
            @($script:DetectionPatterns.Workloads | Where-Object { $_.Label -eq 'Boomi' }).Count | Should -Be 1
            @($script:DetectionPatterns.EndpointProtection | Where-Object { $_.Label -eq 'Sophos' })[0].Driver | Should -Be '^Sophos'
        }
        It 'keeps every other category as it was' {
            $r = Merge-DetectionPatternSet $script:DetectionPatterns (New-PatternFile '"Backup": [ { "Label": "Contoso Backup", "App": "^Contoso Backup" } ]')
            foreach ($k in @('Agents', 'EndpointProtection', 'SecurityTools', 'Workloads')) {
                (@($r.Patterns[$k] | ForEach-Object { $_.Label }) -join '; ') | Should -Be (@($script:DetectionPatterns[$k] | ForEach-Object { $_.Label }) -join '; ')
            }
        }
        It 'merged patterns are used by Find-DetectionMatch' {
            $r = Merge-DetectionPatternSet $script:DetectionPatterns (New-PatternFile '"Workloads": [ { "Label": "Contoso ERP", "Service": "^CtsErp$" } ]')
            $services = @([pscustomobject]@{ Name = 'CtsErp'; DisplayName = 'Contoso ERP'; State = 'Running' })
            $found = Find-DetectionMatch $r.Patterns.Workloads @() $services
            @($found | ForEach-Object { $_.Label }) | Should -Be @('Contoso ERP')
        }
        It 'reports <Case>' -TestCases @(
            @{ Case = 'an unknown category';          Json = '"Antivirus": [ { "Label": "X", "App": "X" } ]';           Message = 'Unknown category "Antivirus"' }
            @{ Case = 'an unknown field';             Json = '"Backup": [ { "Label": "X", "Product": "X" } ]';          Message = 'unknown field Product' }
            @{ Case = 'an invalid regular expression';Json = '"Backup": [ { "Label": "X", "App": "Veeam[" } ]';         Message = 'not a valid regular expression' }
            @{ Case = 'a missing Label';              Json = '"Backup": [ { "App": "X" } ]';                            Message = 'Label is required' }
            @{ Case = 'an entry without a match field';Json = '"Backup": [ { "Label": "X" } ]';                         Message = 'needs at least one of' }
            @{ Case = 'disabling an unknown entry';   Json = '"Backup": [ { "Label": "Not there", "Disabled": true } ]'; Message = 'no built-in entry' }
            @{ Case = 'Disabled that is not a boolean';Json = '"Backup": [ { "Label": "Veeam", "Disabled": "yes" } ]';  Message = 'true or false' }
            @{ Case = 'a pattern that is not text';   Json = '"Backup": [ { "Label": "X", "App": 5 } ]';                Message = 'non-empty text' }
            @{ Case = 'an entry that is not an object';Json = '"Backup": [ "Veeam" ]';                                  Message = 'must be an object' }
            @{ Case = 'a file that changes nothing';  Json = '"Backup": [ ]';                                           Message = 'changes no pattern' }
        ) {
            $r = Merge-DetectionPatternSet $script:DetectionPatterns (New-PatternFile $Json)
            ($r.Errors -join ' | ') | Should -BeLike ('*' + $Message + '*')
        }
    }

    Context 'Get-ProfileSettingDecision' {
        BeforeAll {
            function New-ProfileFile([string]$Json) { ConvertFrom-SiteDataJson ('{ "Schema": "IPU-Profile/1", ' + $Json + ' }') 'IPU-Profile/1' }
            $script:ProfileAttributes = @{}
            foreach ($n in $script:ProfileSettingNames) { $script:ProfileAttributes[$n] = @((Get-Variable -Name $n).Attributes) }
        }
        It 'every profile setting is a script parameter' {
            foreach ($n in $script:ProfileSettingNames) { Get-Variable -Name $n -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because $n }
        }
        It 'converts values to the parameter types' {
            $d = Get-ProfileSettingDecision (New-ProfileFile '"Settings": { "MinimumCFreeGB": 60, "WriteJson": false, "NumberCultureName": "en-GB" }') $script:ProfileAttributes
            @($d.Errors).Count | Should -Be 0
            $d.Settings['MinimumCFreeGB'] | Should -Be 60
            $d.Settings['MinimumCFreeGB'] | Should -BeOfType ([int])
            $d.Settings['WriteJson'] | Should -BeFalse
            $d.Settings['WriteJson'] | Should -BeOfType ([bool])
            $d.Settings['NumberCultureName'] | Should -Be 'en-GB'
        }
        It 'an argument given to the script wins over the profile' {
            $d = Get-ProfileSettingDecision (New-ProfileFile '"Settings": { "MinimumCFreeGB": 60, "MaxPatchAgeDays": 30 }') $script:ProfileAttributes -Bound @('MinimumCFreeGB')
            $d.Settings.Contains('MinimumCFreeGB') | Should -BeFalse
            $d.Settings['MaxPatchAgeDays'] | Should -Be 30
            $d.Ignored | Should -Be @('MinimumCFreeGB')
        }
        It 'reports <Case>' -TestCases @(
            @{ Case = 'a value outside the parameter range'; Json = '"Settings": { "MinimumCFreeGB": 5000 }';          Message = 'MinimumCFreeGB: value "5000" is not allowed' }
            @{ Case = 'a value of the wrong type';           Json = '"Settings": { "MinimumMemoryGB": "lots" }';      Message = 'MinimumMemoryGB: value "lots"' }
            @{ Case = 'text for a boolean';                  Json = '"Settings": { "WriteJson": "no" }';              Message = 'WriteJson: value "no"' }
            @{ Case = 'a relative path';                     Json = '"Settings": { "LgpoExe": "LGPO.exe" }';          Message = 'LgpoExe: value "LGPO.exe"' }
            @{ Case = 'an unknown setting';                  Json = '"Settings": { "MinimumCFree": 60 }';             Message = '"MinimumCFree" is not a profile setting' }
            @{ Case = 'a per-run argument';                  Json = '"Settings": { "AssessmentMode": "Post" }';       Message = '"AssessmentMode" is not a profile setting' }
            @{ Case = 'a missing Settings object';           Json = '"Thresholds": { "MinimumCFreeGB": 60 }';         Message = 'Settings must be an object' }
            @{ Case = 'an empty Settings object';            Json = '"Settings": { }';                                Message = 'sets no setting' }
        ) {
            $d = Get-ProfileSettingDecision (New-ProfileFile $Json) $script:ProfileAttributes
            ($d.Errors -join ' | ') | Should -BeLike ('*' + $Message + '*')
            $d.Settings.Count | Should -Be 0
        }
    }

    It 'the example files in docs/examples are valid and apply cleanly' {
        $dir = Join-Path $PSScriptRoot '..\..\docs\examples'
        $patterns = ConvertFrom-SiteDataJson ([IO.File]::ReadAllText((Join-Path $dir 'site-patterns.example.json'))) 'IPU-Patterns/1'
        @((Merge-DetectionPatternSet $script:DetectionPatterns $patterns).Errors).Count | Should -Be 0
        $profileObj = ConvertFrom-SiteDataJson ([IO.File]::ReadAllText((Join-Path $dir 'site-profile.example.json'))) 'IPU-Profile/1'
        $attributes = @{}
        foreach ($n in $script:ProfileSettingNames) { $attributes[$n] = @((Get-Variable -Name $n).Attributes) }
        $d = Get-ProfileSettingDecision $profileObj $attributes
        @($d.Errors).Count | Should -Be 0
        $d.Settings.Count | Should -Be 4
    }

    Context 'Import-SiteDataFile' {
        BeforeEach {
            $script:Results.Clear()
            $script:SavedPatterns = $script:DetectionPatterns
        }
        AfterEach { $script:DetectionPatterns = $script:SavedPatterns }

        It 'without files changes nothing and writes no row' {
            $PatternFile = ''; $ProfileFile = ''
            Import-SiteDataFile
            $script:Results.Count | Should -Be 0
            [object]::ReferenceEquals($script:DetectionPatterns, $script:SavedPatterns) | Should -BeTrue
        }
        It 'a malformed pattern file is MANUAL and the built-in patterns stay' {
            $PatternFile = Join-Path $TestDrive 'bad-patterns.json'; $ProfileFile = ''
            Set-Content -LiteralPath $PatternFile -Value '{ "Schema": "IPU-Patterns/1", "Backup": [ { "Label": "X", "App": "Veeam[" } ] }'
            Import-SiteDataFile
            $row = @($script:Results | Where-Object { $_.Item -eq 'Pattern file' })[0]
            $row.Status | Should -Be 'MANUAL'
            $row.Kind | Should -Be 'Finding'
            $row.Details | Should -Match 'not a valid regular expression'
            $row.Details | Should -Match 'SHA256=[0-9A-F]{64}'
            [object]::ReferenceEquals($script:DetectionPatterns, $script:SavedPatterns) | Should -BeTrue
        }
        It 'a missing pattern file is MANUAL' {
            $PatternFile = Join-Path $TestDrive 'not-there.json'; $ProfileFile = ''
            Import-SiteDataFile
            @($script:Results | Where-Object { $_.Item -eq 'Pattern file' })[0].Status | Should -Be 'MANUAL'
        }
        It 'a valid pattern file is applied and listed' {
            $PatternFile = Join-Path $TestDrive 'patterns.json'; $ProfileFile = ''
            Set-Content -LiteralPath $PatternFile -Value '{ "Schema": "IPU-Patterns/1", "Workloads": [ { "Label": "Contoso ERP", "Service": "^CtsErp$" } ] }'
            Import-SiteDataFile
            $row = @($script:Results | Where-Object { $_.Item -eq 'Pattern file' })[0]
            $row.Status | Should -Be 'INFO'
            $row.Details | Should -Match 'Workloads: added "Contoso ERP"'
            @($script:DetectionPatterns.Workloads | Where-Object { $_.Label -eq 'Contoso ERP' }).Count | Should -Be 1
        }
        It 'a malformed profile file is MANUAL' {
            $PatternFile = ''; $ProfileFile = Join-Path $TestDrive 'bad-profile.json'
            Set-Content -LiteralPath $ProfileFile -Value '{ "Schema": "IPU-Profile/1", "Settings": { "MinimumCFreeGB": 0 } }'
            Import-SiteDataFile
            $row = @($script:Results | Where-Object { $_.Item -eq 'Profile file' })[0]
            $row.Status | Should -Be 'MANUAL'
            $row.Details | Should -Match 'MinimumCFreeGB'
        }
        It 'a valid profile file is applied and listed' {
            $PatternFile = ''; $ProfileFile = Join-Path $TestDrive 'profile.json'
            Set-Content -LiteralPath $ProfileFile -Value '{ "Schema": "IPU-Profile/1", "Settings": { "MaxPatchAgeDays": 45 } }'
            Import-SiteDataFile
            $row = @($script:Results | Where-Object { $_.Item -eq 'Profile file' })[0]
            $row.Status | Should -Be 'INFO'
            $row.Details | Should -Match 'MaxPatchAgeDays=45'
        }
    }
}
