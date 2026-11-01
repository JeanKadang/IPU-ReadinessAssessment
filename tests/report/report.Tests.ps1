# Pester 5 tests. Result model, overall status, the HTML report and the JSON result.
# The script is loaded in library mode by ..\TestSetup.ps1: functions only, nothing is collected.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
param()

BeforeAll { . (Join-Path $PSScriptRoot '..\TestSetup.ps1') }

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'Result model' {
    BeforeEach { $script:Results.Clear() }
    It 'rejects unknown areas (typo protection)' {
        { Add-Result 'NOT_AN_AREA' 'x' 'INFO' } | Should -Throw
    }
    It 'defaults finding statuses to Finding and OK/INFO to Evidence' {
        Add-Result 'STORAGE' 'a' 'ACTION' 'v'
        Add-Result 'STORAGE' 'b' 'OK' 'v'
        $script:Results[0].Kind | Should -Be 'Finding'
        $script:Results[1].Kind | Should -Be 'Evidence'
    }
    It 'joins details and removes control characters' {
        Add-Result 'STORAGE' 'c' 'INFO' "line1`r`nline2" @('one','','two')
        $script:Results[0].Value | Should -Be 'line1 | line2'
        $script:Results[0].Details | Should -Be 'one | two'
    }
    It 'every area has a chapter that is in the chapter order' {
        foreach ($k in $script:AreaMap.Keys) { $script:ChapterOrder | Should -Contain $script:AreaMap[$k].Chapter }
    }
}

Describe 'Get-OverallStatus' {
    It 'ignores Observations and Checklist items' {
        $r = @(
            [pscustomobject]@{ Kind='Observation'; Status='ACTION' },
            [pscustomobject]@{ Kind='Checklist';   Status='MANUAL' },
            [pscustomobject]@{ Kind='Evidence';    Status='INFO' }
        )
        Get-OverallStatus $r | Should -Be 'OK'
    }
    It 'returns the most severe finding' {
        $r = @(
            [pscustomobject]@{ Kind='Finding'; Status='MANUAL' },
            [pscustomobject]@{ Kind='Finding'; Status='BLOCKER' },
            [pscustomobject]@{ Kind='Finding'; Status='WARNING' }
        )
        Get-OverallStatus $r | Should -Be 'BLOCKER'
    }
}

Describe 'HTML report' {
    BeforeAll {
        $script:Results.Clear(); $script:CheckRuns.Clear()
        Add-Result 'UPGRADE_PATH' 'TargetUpgradePath' 'BLOCKER' 'Not supported <script>' 'detail & more'
        Add-Result 'STORAGE' 'CFreeSpace' 'WARNING' 'low'
        Add-Result 'CHECKLIST' 'Backup and fallback' 'MANUAL' 'x' -Kind 'Checklist'
        $script:CheckRuns.Add([pscustomobject]@{ Id='a'; Name='A'; Phase='Fast'; Outcome='Failed'; Duration='00:00:01'; Seconds=1; Message='m' })
        $script:html = New-IPUReportHtml -Results $script:Results.ToArray() -CheckRuns $script:CheckRuns.ToArray() -OverallStatus 'BLOCKER' -CompletedTime (Get-Date) -Partial
    }
    It 'is a complete document' {
        $script:html | Should -Match '(?is)^\s*<!doctype html'
        $script:html | Should -Match '(?is)</html>\s*$'
    }
    It 'HTML-encodes values' {
        $script:html | Should -Not -Match 'Not supported <script>'
        $script:html | Should -Match 'Not supported &lt;script&gt;'
    }
    It 'shows the partial banner and the not-assessed warning' {
        $script:html | Should -Match 'PARTIAL REPORT'
        $script:html | Should -Match 'Not fully assessed'
    }
    It 'contains no external resources' {
        # Documentation links (#79) are plain <a href>; nothing is loaded.
        $script:html | Should -Not -Match 'src="https?:'
        $script:html | Should -Not -Match '<link[^>]+href="https?:'
        $script:html | Should -Not -Match '@import'
    }
}

Describe 'JSON result' {
    BeforeAll {
        $script:Results.Clear(); $script:CheckRuns.Clear()
        $script:Data.Snapshot = @{ Services=@(); Ports=@('TCP:3389'); Routes=@(); IPv4=@('10.0.0.1'); Dns=@(); Hosts=@(); Apps=@(); Features=@(); Tasks=@() }
        Add-Result 'STORAGE' 'CFreeSpace' 'ACTION' 'low'
        Add-Result 'CHECKLIST' 'x' 'MANUAL' 'y' -Kind 'Checklist'
        $script:obj = New-AssessmentJsonObject -Results $script:Results.ToArray() -Overall 'ACTION' -Completed (Get-Date)
        $script:round = ($script:obj | ConvertTo-Json -Depth 6) | ConvertFrom-Json
    }
    It 'counts only findings' {
        $script:round.Counts.ACTION | Should -Be 1
        $script:round.Counts.MANUAL | Should -Be 0
    }
    It 'carries results and snapshot' {
        @($script:round.Results).Count | Should -Be 2
        @($script:round.Snapshot.Ports)[0] | Should -Be 'TCP:3389'
    }
}

Describe 'A MANUAL row counts towards the overall status (#240)' {
    BeforeEach { $script:Results.Clear() }
    It 'Add-Result refuses a MANUAL Observation' {
        { Add-Result 'ROLES' 'Inventory' 'MANUAL' 'x' -Recommendation 'r' -Kind 'Observation' } | Should -Throw '*must be a Finding*'
    }
    It 'Add-Result refuses a MANUAL Evidence row' {
        { Add-Result 'BACKUP' 'VSSWriters' 'MANUAL' 'x' -Recommendation 'r' -Kind 'Evidence' } | Should -Throw '*must be a Finding*'
    }
    It 'a MANUAL row without a Kind is a Finding and makes the overall status MANUAL' {
        Add-Result 'ROLES' 'Inventory' 'MANUAL' 'Get-WindowsFeature unavailable' -Recommendation 'List the roles by hand.'
        Add-Result 'ROLES' 'Other' 'OK' 'fine'
        $script:Results[0].Kind | Should -Be 'Finding'
        Get-OverallStatus $script:Results | Should -Be 'MANUAL'
    }
    It 'a listed area keeps its MANUAL Observation, with the reason on record' {
        { Add-Result 'AGENTS' 'Some agent' 'MANUAL' 'Not identified' -Recommendation 'Confirm in the backend.' -Kind 'Observation' } | Should -Not -Throw
        $script:ManualNotCounted['AGENTS'] | Should -Not -BeNullOrEmpty
    }
    It 'Checklist rows stay MANUAL by design' {
        { Add-Result 'CHECKLIST' 'Backup and fallback' 'MANUAL' 'x' -Recommendation 'r' -Kind 'Checklist' } | Should -Not -Throw
    }
    It 'no MANUAL call in the checks hides a failure as an Observation or Evidence row' {
        $src = (@(Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\..\src\assessment') -Filter '5*-checks*.ps1') | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
        $bad = @([regex]::Matches($src, "Add-Result '(\w+)'[^\r\n]*'MANUAL'[^\r\n]*-Kind '(Observation|Evidence)'") | Where-Object { -not $script:ManualNotCounted.ContainsKey($_.Groups[1].Value) })
        $bad.Count | Should -Be 0 -Because (($bad | ForEach-Object { $_.Value.Substring(0, [math]::Min(80, $_.Value.Length)) }) -join '; ')
    }
}

Describe 'Report and JSON writers (#36)' {
    BeforeEach {
        $script:Results.Clear(); $script:CheckRuns.Clear(); $script:Data = @{}
        $script:CollectionStarted = (Get-Date).AddMinutes(-1)
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $script:ReportPath = Join-Path $dir 'SRV-IPU-Assessment.html'
        $script:JsonPath = Join-Path $dir 'SRV-IPU-Assessment.json'
        $script:LogPath = Join-Path $dir 'SRV-IPU-Assessment.log'
        $script:WriteJson = $true
        Add-Result 'STORAGE' 'CFreeSpace' 'ACTION' 'low'
    }

    It 'writes HTML and JSON and leaves no .writing file' {
        $r = Write-AssessmentReport
        $r.Overall | Should -Be 'ACTION'
        $script:ReportPath | Should -Exist
        $script:JsonPath | Should -Exist
        @(Get-ChildItem -LiteralPath (Split-Path $script:ReportPath) -Filter '*.writing').Count | Should -Be 0
        (Get-Content -LiteralPath $script:JsonPath -Raw | ConvertFrom-Json).Overall | Should -Be 'ACTION'
    }
    It 'replaces an existing report instead of appending' {
        Set-Content -LiteralPath $script:ReportPath -Value 'OLD REPORT CONTENT'
        Set-Content -LiteralPath $script:JsonPath -Value '{"Overall":"OLD"}'
        $null = Write-AssessmentReport
        $html = Get-Content -LiteralPath $script:ReportPath -Raw
        $html | Should -Not -Match 'OLD REPORT CONTENT'
        $html | Should -Match '(?is)^\s*<!doctype html'
        (Get-Content -LiteralPath $script:JsonPath -Raw | ConvertFrom-Json).Overall | Should -Be 'ACTION'
    }
    It 'refuses a <Case> document and leaves the previous report untouched' -TestCases @(
        @{ Case = 'short';             Html = '<!doctype html><html></html>' }
        @{ Case = 'unterminated';      Html = '<!doctype html><html>' + ('x' * 3000) }
        @{ Case = 'non-HTML';          Html = ('x' * 3000) + '</html>' }
    ) {
        Set-Content -LiteralPath $script:ReportPath -Value 'PREVIOUS GOOD REPORT'
        $script:FakeHtml = $Html
        Mock New-IPUReportHtml { $script:FakeHtml }
        { Write-AssessmentReport } | Should -Throw -ExpectedMessage '*HTML validation failed*'
        Get-Content -LiteralPath $script:ReportPath -Raw | Should -Match 'PREVIOUS GOOD REPORT'
        @(Get-ChildItem -LiteralPath (Split-Path $script:ReportPath) -Filter '*.writing').Count | Should -Be 0
    }
    It 'writes UTF-8 without a byte-order mark' {
        Add-Result 'STORAGE' 'Unicode' 'INFO' ('Caf' + [char]0xE9)
        $null = Write-AssessmentReport
        foreach ($p in $script:ReportPath, $script:JsonPath) {
            $bytes = [IO.File]::ReadAllBytes($p)
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        }
        # The HTML encodes the character (&#233;); the JSON keeps it as UTF-8.
        [IO.File]::ReadAllText($script:JsonPath, [Text.Encoding]::UTF8) | Should -Match ('Caf' + [char]0xE9)
        [IO.File]::ReadAllText($script:ReportPath) | Should -Match 'Caf&#233;'
    }
    It 'logs a JSON failure as a warning and still writes the HTML' {
        Mock Write-AssessmentJson { throw 'disk full' }
        $r = Write-AssessmentReport
        $script:ReportPath | Should -Exist
        $r.Bytes | Should -BeGreaterThan 2048
        Get-Content -LiteralPath $script:LogPath -Raw | Should -Match 'WARNING;JSON;JSON result could not be written: disk full'
    }
    It 'does not write JSON when WriteJson is off' {
        # A local variable shadows the script parameter for calls made from here.
        $WriteJson = $false
        $null = Write-AssessmentReport
        $script:JsonPath | Should -Not -Exist
    }
}

Describe 'HTML report accessibility (#28)' {
    BeforeAll {
        $script:Results.Clear(); $script:CheckRuns.Clear()
        Add-Result 'STORAGE' 'CFreeSpace' 'ACTION' 'low'
        Add-Result 'STORAGE' 'PartitionAfterC' 'WARNING' 'Yes'
        Add-Result 'CHECKLIST' 'Backup and fallback' 'MANUAL' 'x' -Kind 'Checklist'
        $script:CheckRuns.Add([pscustomobject]@{ Id = 'storage'; Name = 'Storage'; Phase = 'Fast'; Outcome = 'Completed'; Duration = '00:00:01'; Seconds = 1; Message = '' })
        $script:A11yHtml = New-IPUReportHtml -Results $script:Results.ToArray() -CheckRuns $script:CheckRuns.ToArray() -OverallStatus 'ACTION' -CompletedTime (Get-Date)

        function Get-Luminance([string]$Hex) {
            $h = $Hex.TrimStart('#')
            $c = foreach ($i in 0, 2, 4) {
                $v = [Convert]::ToInt32($h.Substring($i, 2), 16) / 255
                if ($v -le 0.03928) { $v / 12.92 } else { [math]::Pow(($v + 0.055) / 1.055, 2.4) }
            }
            return 0.2126 * $c[0] + 0.7152 * $c[1] + 0.0722 * $c[2]
        }
        function Get-ContrastRatio([string]$A, [string]$B) {
            $la = Get-Luminance $A; $lb = Get-Luminance $B
            return ([math]::Max($la, $lb) + 0.05) / ([math]::Min($la, $lb) + 0.05)
        }
        function Get-CssToken([string]$Block) {
            $t = @{}
            foreach ($m in [regex]::Matches($Block, '--([a-z-]+):(#[0-9a-fA-F]{6})')) { $t[$m.Groups[1].Value] = $m.Groups[2].Value }
            return $t
        }
        $script:Light = Get-CssToken ([regex]::Match($script:A11yHtml, ':root\{[^}]*\}').Value)
        $script:Dark = $script:Light.Clone()
        $darkBlock = Get-CssToken ([regex]::Match($script:A11yHtml, '@media \(prefers-color-scheme: dark\)\{:root\{[^}]*\}').Value)
        foreach ($k in $darkBlock.Keys) { $script:Dark[$k] = $darkBlock[$k] }
    }

    It 'every table has a caption and every header cell a column scope' {
        $tables = [regex]::Matches($script:A11yHtml, '<table>').Count
        $tables | Should -BeGreaterThan 3
        [regex]::Matches($script:A11yHtml, '<table><caption').Count | Should -Be $tables
        [regex]::Matches($script:A11yHtml, '<th[\s>]').Count | Should -BeGreaterThan 10
        [regex]::Matches($script:A11yHtml, '<th(?=[\s>])(?![^>]*scope="col")').Count | Should -Be 0
    }
    It 'the checklist glyph is hidden from screen readers and has a text status' {
        $script:A11yHtml | Should -Match '<span aria-hidden="true">&#x2610;</span> <span class="cbt">open</span>'
        $script:A11yHtml | Should -Match '<th scope="col" class="cb">Done</th>'
    }
    It 'collapsible sections have a visible keyboard focus style' {
        $script:A11yHtml | Should -Match 'summary:focus-visible\{outline:3px solid var\(--focus\)'
    }
    It 'defines a dark theme' {
        $script:Dark.Count | Should -BeGreaterThan 10
        $script:Dark['bg'] | Should -Not -Be $script:Light['bg']
    }
    It 'text contrast is at least 4.5:1 in the <Theme> theme' -TestCases @(@{ Theme = 'light' }, @{ Theme = 'dark' }) {
        $t = $script:Light; if ($Theme -eq 'dark') { $t = $script:Dark }
        foreach ($pair in @(@('ink', 'panel'), @('ink', 'bg'), @('muted', 'panel'), @('heading', 'panel'), @('th-ink', 'th-bg'), @('partial-ink', 'partial-bg'))) {
            Get-ContrastRatio $t[$pair[0]] $t[$pair[1]] | Should -BeGreaterOrEqual 4.5 -Because ($Theme + ': ' + ($pair -join ' on '))
        }
    }
    It 'focus outline contrast is at least 3:1 in the <Theme> theme' -TestCases @(@{ Theme = 'light' }, @{ Theme = 'dark' }) {
        $t = $script:Light; if ($Theme -eq 'dark') { $t = $script:Dark }
        Get-ContrastRatio $t['focus'] $t['panel'] | Should -BeGreaterOrEqual 3
        Get-ContrastRatio $t['focus'] $t['bg'] | Should -BeGreaterOrEqual 3
    }
    It 'white badge text meets 4.5:1 on every status colour' {
        foreach ($s in 'special', 'blocker', 'action', 'warning', 'manual', 'ok', 'info') {
            Get-ContrastRatio '#ffffff' $script:Light[$s] | Should -BeGreaterOrEqual 4.5 -Because $s
        }
    }
}

Describe 'Report header: linked counters and plain coverage notes (#77)' {
    BeforeAll {
        function New-Run([string]$Id, [string]$Name, [string]$Outcome, [string]$Message = '') {
            [pscustomobject]@{ Id = $Id; Name = $Name; Phase = 'Slow'; Outcome = $Outcome; Duration = '00:00:00'; Seconds = 0; Message = $Message }
        }
    }
    It 'a scan skipped for lack of media is a note, not a problem' {
        $n = Get-CoverageNotice @((New-Run 'compatscan' 'Setup compatibility scan' 'Skipped' 'Not configured: no installation media given (-TargetMediaPath)')) 'Windows Server 2025'
        @($n.Problems).Count | Should -Be 0
        @($n.ByChoice).Count | Should -Be 1
        $n.ByChoice[0] | Should -Match 'no Windows Server 2025 installation media was given'
        $n.ByChoice[0] | Should -Match '-TargetMediaPath'
    }
    It 'a check switched off is a note that says to run it before go/no-go' {
        $n = Get-CoverageNotice @((New-Run 'dism' 'DISM component store scan' 'Skipped' 'Not configured: switched off with -RunDISMScanHealth $false'))
        $n.ByChoice[0] | Should -Be 'DISM component store scan was switched off for this run (switched off with -RunDISMScanHealth $false). Run it before the final go/no-go.'
    }
    It 'a print backup on a server that is not a print server is not mentioned (#206)' {
        $n = Get-CoverageNotice @((New-Run 'printbackup' 'Print server backup (PrintBrm)' 'Skipped' 'Not applicable: not a print server'))
        @($n.Problems).Count + @($n.ByChoice).Count | Should -Be 0
    }
    It 'a check that does not apply (Post mode) is not mentioned' {
        $n = Get-CoverageNotice @((New-Run 'compatscan' 'Setup compatibility scan' 'Skipped' 'Not applicable after the upgrade'))
        @($n.Problems).Count + @($n.ByChoice).Count | Should -Be 0
    }
    It '<Outcome> is a problem: "<Text>"' -TestCases @(
        @{ Outcome = 'Failed';   Message = 'IOException: x';      Text = 'Storage stopped with an error' }
        @{ Outcome = 'TimedOut'; Message = '';                    Text = 'Storage ran out of time' }
        @{ Outcome = 'Skipped';  Message = 'Time budget used up'; Text = 'Storage was not started, the time budget was used up' }
        @{ Outcome = 'Skipped';  Message = 'Something else';      Text = 'Storage was skipped (Something else)' }
    ) {
        $n = Get-CoverageNotice @((New-Run 'storage' 'Storage' $Outcome $Message))
        $n.Problems | Should -Be @($Text)
        @($n.ByChoice).Count | Should -Be 0
    }
    Context 'generated HTML' {
        BeforeAll {
            $script:Results.Clear(); $script:CheckRuns.Clear()
            Add-Result 'STORAGE' 'PartitionAfterC' 'WARNING' 'Yes'
            Add-Result 'CHECKLIST' 'Backup and fallback' 'MANUAL' 'x' -Kind 'Checklist'
            $script:CheckRuns.Add((New-Run 'storage' 'Storage' 'Completed'))
            $script:CheckRuns.Add((New-Run 'compatscan' 'Setup compatibility scan' 'Skipped' 'Not configured: no installation media given (-TargetMediaPath)'))
            $TargetServerVersion = '2025'
            $script:HeaderHtml = New-IPUReportHtml -Results $script:Results.ToArray() -CheckRuns $script:CheckRuns.ToArray() -OverallStatus 'WARNING' -CompletedTime (Get-Date)
        }
        It 'shows no "Not fully assessed" banner when a check was only skipped by choice' {
            $script:HeaderHtml | Should -Not -Match 'Not fully assessed'
            $script:HeaderHtml | Should -Match '<div class="note"><strong>Not run by choice:</strong> Microsoft&#39;s own upgrade check'
        }
        It 'links a non-zero counter to its section and leaves a zero counter plain' {
            $script:HeaderHtml | Should -Match '<a class="card" href="#planning" aria-label="1 WARNING findings - go to the list">'
            $script:HeaderHtml | Should -Match '<div class="card"><small>BLOCKER</small><b>0</b></div>'
            $script:HeaderHtml | Should -Match '<a class="card" href="#checklist"'
            $script:HeaderHtml | Should -Match '<a class="card" href="#coverage"'
        }
        It 'every link target exists' {
            foreach ($m in [regex]::Matches($script:HeaderHtml, 'href="#([a-z]+)"')) {
                $script:HeaderHtml | Should -Match ('id="' + $m.Groups[1].Value + '"')
            }
        }
        It 'a failed check gives the banner and opens the coverage section' {
            $runs = @($script:CheckRuns.ToArray()) + @(New-Run 'iis' 'IIS' 'Failed' 'boom')
            $html = New-IPUReportHtml -Results $script:Results.ToArray() -CheckRuns $runs -OverallStatus 'MANUAL' -CompletedTime (Get-Date)
            $html | Should -Match 'Not fully assessed: IIS stopped with an error'
            $html | Should -Match '<details id="coverage" open>'
        }
    }
}

Describe 'Commands and links with recommendations (#79)' {
    It 'builds the exact <Id> command' -TestCases @(
        @{ Id = 'PendingRename'; Kind = 'Check';  Values = @{}; Expected = "Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PendingFileRenameOperations" }
        @{ Id = 'Restart';       Kind = 'Change'; Values = @{}; Expected = 'Restart-Computer' }
        @{ Id = 'IisBackup';     Kind = 'Change'; Values = @{}; Expected = '& "$env:windir\system32\inetsrv\appcmd.exe" add backup "PreIPU"' }
        @{ Id = 'FolderAcl';     Kind = 'Change'; Values = @{ Path = 'C:\Temp\IPU-Assessment' }; Expected = 'icacls "C:\Temp\IPU-Assessment" /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F' }
        @{ Id = 'EnableNla';     Kind = 'Change'; Values = @{}; Expected = 'Get-CimInstance -Namespace root\cimv2\TerminalServices -ClassName Win32_TSGeneralSetting -Filter "TerminalName=''RDP-tcp''" | Invoke-CimMethod -MethodName SetUserAuthenticationRequired -Arguments @{ UserAuthenticationRequired = 1 }' }
        @{ Id = 'LbfoTeams';     Kind = 'Check';  Values = @{}; Expected = 'Get-NetLbfoTeam | Format-List Name, Status, TeamingMode, LoadBalancingAlgorithm, Members' }
        @{ Id = 'CFreeSpace';    Kind = 'Check';  Values = @{}; Expected = 'Get-Volume -DriveLetter C | Format-List DriveLetter, FileSystemLabel, @{ n = ''SizeGB''; e = { [math]::Round($_.Size / 1GB, 1) } }, @{ n = ''FreeGB''; e = { [math]::Round($_.SizeRemaining / 1GB, 1) } }' }
    ) {
        $c = Get-RecommendationCommand $Id $Values
        $c.Kind | Should -Be $Kind
        $c.Command | Should -BeExactly $Expected
    }
    It 'every generated PowerShell command parses' {
        foreach ($id in 'PendingRename', 'Restart', 'IisBackup', 'EnableNla', 'LbfoTeams', 'CFreeSpace') {
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseInput((Get-RecommendationCommand $id).Command, [ref]$null, [ref]$errors)
            @($errors).Count | Should -Be 0 -Because $id
        }
    }
    It 'an unknown command id throws' {
        { Get-RecommendationCommand 'Nope' } | Should -Throw '*Unknown recommendation command*'
    }
    It 'commands in the script come from Get-RecommendationCommand only' {
        $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\..\src\Windows-IPU-Readiness-Assessment.ps1'))
        [regex]::Matches($text, "-Command\s+['""]").Count | Should -Be 0
    }
    Context 'Add-Result' {
        BeforeEach { $script:Results.Clear() }
        It 'stores command, kind, link and title' {
            Add-Result 'STORAGE' 'x' 'WARNING' 'v' -Recommendation 'r' -Command 'Get-Volume' -CommandKind 'Check' -Link 'https://learn.microsoft.com/x' -LinkTitle 'Doc'
            $r = $script:Results[0]
            "$($r.Command)|$($r.CommandKind)|$($r.Link)|$($r.LinkTitle)" | Should -Be 'Get-Volume|Check|https://learn.microsoft.com/x|Doc'
        }
        It 'leaves the fields empty when not given, and uses the URL as title when none is given' {
            Add-Result 'STORAGE' 'x' 'WARNING' 'v'
            Add-Result 'STORAGE' 'y' 'WARNING' 'v' -Link 'https://learn.microsoft.com/y'
            "$($script:Results[0].Command)|$($script:Results[0].CommandKind)|$($script:Results[0].Link)" | Should -Be '||'
            $script:Results[1].LinkTitle | Should -Be 'https://learn.microsoft.com/y'
        }
        It 'refuses a command without a kind and a link that is not https' {
            { Add-Result 'STORAGE' 'x' 'WARNING' -Command 'Get-Volume' } | Should -Throw '*CommandKind*'
            { Add-Result 'STORAGE' 'x' 'WARNING' -Link 'javascript:alert(1)' } | Should -Throw '*https*'
            { Add-Result 'STORAGE' 'x' 'WARNING' -Link 'http://example.test' } | Should -Throw '*https*'
        }
    }
    Context 'HTML' {
        It 'shows the command encoded, labelled, with a copy button, and the link' {
            $row = [pscustomobject]@{ Recommendation = 'Do it <now>'; Command = 'icacls "C:\R" /grant:r x'; CommandKind = 'Change'; Link = 'https://learn.microsoft.com/a?b=1&c=2'; LinkTitle = 'Doc & more' }
            $h = New-RecommendationHtml $row
            $h.StartsWith('Do it &lt;now&gt;') | Should -BeTrue
            $h.Contains('<span class="ck ck-change" title="run in the change window">Change</span><code>icacls &quot;C:\R&quot; /grant:r x</code>') | Should -BeTrue
            $h.Contains('data-cmd="icacls &quot;C:\R&quot; /grant:r x" aria-label="Copy the change command"') | Should -BeTrue
            $h.Contains('<a class="ext" href="https://learn.microsoft.com/a?b=1&amp;c=2" target="_blank" rel="noopener noreferrer">Doc &amp; more</a>') | Should -BeTrue
        }
        It 'shows only the text when there is no command or link' {
            New-RecommendationHtml ([pscustomobject]@{ Recommendation = 'Plain' }) | Should -Be 'Plain'
        }
        It 'the report carries the copy script and still ends as a complete document' {
            $script:Results.Clear(); $script:CheckRuns.Clear()
            Add-Result 'STORAGE' 'CFreeSpace' 'ACTION' 'low' -Recommendation 'Extend C:' -Command (Get-RecommendationCommand 'CFreeSpace').Command -CommandKind 'Check'
            $html = New-IPUReportHtml -Results $script:Results.ToArray() -CheckRuns $script:CheckRuns.ToArray() -OverallStatus 'ACTION' -CompletedTime (Get-Date)
            $html.Contains('<script type="text/javascript">document.documentElement.className+=" js"') | Should -BeTrue
            $html | Should -Match '(?is)</html>\s*$'
            ([regex]::Matches($html, 'class="cmd"')).Count | Should -Be 2   # decision table and chapter table
        }
    }
    Context 'pattern files' {
        It 'accepts an https Link and refuses another scheme' {
            $ok = ConvertFrom-SiteDataJson '{ "Schema": "IPU-Patterns/1", "Backup": [ { "Label": "Contoso Backup", "App": "^Contoso Backup", "Link": "https://docs.example.test/support", "LinkTitle": "Contoso: support matrix" } ] }' 'IPU-Patterns/1'
            $r = Merge-DetectionPatternSet $script:DetectionPatterns $ok
            @($r.Errors).Count | Should -Be 0
            @($r.Patterns.Backup | Where-Object { $_.Label -eq 'Contoso Backup' })[0].Link | Should -Be 'https://docs.example.test/support'
            $bad = ConvertFrom-SiteDataJson '{ "Schema": "IPU-Patterns/1", "Backup": [ { "Label": "Contoso Backup", "App": "x", "Link": "file://share/x" } ] }' 'IPU-Patterns/1'
            ((Merge-DetectionPatternSet $script:DetectionPatterns $bad).Errors -join ' ') | Should -Match 'Link must be an https URL'
        }
        It 'Find-DetectionMatch passes the link on' {
            $apps = @([pscustomobject]@{ Name = 'TrendAI Deep Security Agent'; Version = '20.0' })
            $m = Find-DetectionMatch $script:DetectionPatterns.EndpointProtection $apps @()
            $m[0].Link | Should -BeLike 'https://docs.trendmicro.com/*'
        }
    }
}

Describe 'Status meaning right after the Summary (#96)' {
    It 'orders the report: Summary, Status meaning, decision, planning, checklist, chapters (<Mode>)' -TestCases @(@{ Mode = 'Pre' }, @{ Mode = 'Post' }) {
        $script:Results.Clear(); $script:CheckRuns.Clear()
        Add-Result 'STORAGE' 'CFreeSpace' 'ACTION' 'low'
        Add-Result 'STORAGE' 'PartitionAfterC' 'WARNING' 'Yes'
        Add-Result 'CHECKLIST' 'Backup and fallback' 'MANUAL' 'x' -Kind 'Checklist'
        $AssessmentMode = $Mode
        $html = New-IPUReportHtml -Results $script:Results.ToArray() -CheckRuns $script:CheckRuns.ToArray() -OverallStatus 'ACTION' -CompletedTime (Get-Date)
        $positions = @('<h2>Summary</h2>', '<h2>Status meaning</h2>', '<section id="decision">', '<section id="planning">', '<details') | ForEach-Object { $html.IndexOf($_) }
        foreach ($p in $positions) { $p | Should -BeGreaterThan -1 }
        for ($i = 1; $i -lt $positions.Count; $i++) { $positions[$i] | Should -BeGreaterThan $positions[$i - 1] }
        if ($Mode -eq 'Pre') { $html.IndexOf('<section id="checklist">') | Should -BeGreaterThan $positions[3] }
    }
}

Describe 'Report chapters open and closed (#97)' {
    BeforeAll {
        $script:Results.Clear(); $script:CheckRuns.Clear()
        Add-Result 'STORAGE' 'PartitionAfterC' 'WARNING' 'Yes'                                    # finding -> Storage open
        Add-Result 'SERVICES' 'AutomaticServices' 'INFO' 'Total=10'                              # evidence only -> closed
        Add-Result 'RDP' 'NetworkLevelAuthentication' 'WARNING' 'Disabled' -Kind 'Observation'  # observation only -> closed
        Add-Result 'BACKUP' 'VSSWriters' 'MANUAL' 'Unreadable'                                  # MANUAL finding -> open
        $script:ChapterHtml = New-IPUReportHtml -Results $script:Results.ToArray() -CheckRuns $script:CheckRuns.ToArray() -OverallStatus 'WARNING' -CompletedTime (Get-Date)
    }
    It '<Chapter> is <State>' -TestCases @(
        @{ Chapter = 'Storage';                        State = 'open' }
        @{ Chapter = 'Backup and Recovery';            State = 'open' }
        @{ Chapter = 'Services and Scheduled Tasks';   State = 'closed' }
        @{ Chapter = 'Access and Remote Desktop';      State = 'closed' }
    ) {
        $tag = [string][regex]::Match([string]$script:ChapterHtml, '<details[^>]*><summary>' + [regex]::Escape($Chapter) + ' \(').Value
        $tag | Should -Not -BeNullOrEmpty
        [regex]::IsMatch($tag, '<details[^>]*\sopen[\s>]') | Should -Be ($State -eq 'open')
    }
    It 'explains the rule and offers Expand all / Collapse all buttons (hidden without JavaScript)' {
        $script:ChapterHtml | Should -Match '<p class="chapters-note">Chapters with findings to act on are open'
        $script:ChapterHtml | Should -Match '<button type="button" class="tgl" data-open="1">Expand all</button>'
        $script:ChapterHtml | Should -Match '<button type="button" class="tgl" data-open="0">Collapse all</button>'
        $script:ChapterHtml | Should -Match '\.js-only\{display:none\}'
    }
    It 'opens every chapter for printing and restores them afterwards' {
        $script:ChapterHtml | Should -Match 'addEventListener\("beforeprint"'
        $script:ChapterHtml | Should -Match 'addEventListener\("afterprint"'
    }
}

Describe 'RDP NLA in the Summary (#174)' {
    It '<Now> / <Before> -> <Text>' -TestCases @(
        @{ Now = 'On';  Before = '';    Text = 'NLA on' }
        @{ Now = 'Off'; Before = '';    Text = 'NLA off' }
        @{ Now = 'Off'; Before = 'On';  Text = 'NLA off (was on before the upgrade)' }
        @{ Now = 'On';  Before = 'Off'; Text = 'NLA on (was off before the upgrade)' }
        @{ Now = 'On';  Before = 'On';  Text = 'NLA on' }
        @{ Now = '';    Before = 'On';  Text = 'NLA unknown' }
        @{ Now = 'Unknown'; Before = ''; Text = 'NLA unknown' }
    ) {
        Get-NlaFactText $Now $Before | Should -Be $Text
    }
    It 'folds NLA into the RDP access line' {
        $script:Data = @{ RdpSummary = 'GO (no local blocker)'; NlaState = 'Off'; NlaBefore = 'On' }
        Get-RdpAccessFact | Should -Be 'GO (no local blocker), NLA off (was on before the upgrade)'
        $script:Data = @{}
        Get-RdpAccessFact | Should -Be 'Not reported, NLA unknown'
    }
}

Describe 'SA line counts and fields (#261)' {
    BeforeAll {
        function New-Run([string]$Id, [string]$Outcome, [string]$Message = '') {
            [pscustomobject]@{ Id = $Id; Name = $Id; Phase = 'Slow'; Outcome = $Outcome; Duration = '00:00:00'; Seconds = 0; Message = $Message }
        }
    }
    It 'checks skipped by choice or not applicable are Skipped, not NotCompleted' {
        $runs = @(
            (New-Run 'baseline' 'Completed'),
            (New-Run 'dism' 'Skipped' 'Not configured: switched off with -RunDISMScanHealth $false'),
            (New-Run 'sfc' 'Skipped' 'Not configured: switched off with -RunSFCVerifyOnly $false'),
            (New-Run 'printbackup' 'Skipped' 'Not applicable: not a print server'),
            (New-Run 'compatscan' 'Skipped' 'Not configured: no installation media given (-TargetMediaPath)'),
            (New-Run 'iis' 'Skipped' 'Not applicable: SPECIAL server, short report')
        )
        $c = Get-CheckRunCount $runs
        $c.Total | Should -Be 6
        $c.NotCompleted | Should -Be 0
        $c.Skipped | Should -Be 5
    }
    It 'failed, timed out and budget-skipped checks are NotCompleted' {
        $c = Get-CheckRunCount @((New-Run 'a' 'Failed'), (New-Run 'b' 'TimedOut'), (New-Run 'c' 'Skipped' 'Time budget used up'), (New-Run 'd' 'Completed'))
        $c.NotCompleted | Should -Be 3
        $c.Skipped | Should -Be 0
    }
    It 'no runs' {
        $c = Get-CheckRunCount @()
        $c.Total | Should -Be 0; $c.NotCompleted | Should -Be 0; $c.Skipped | Should -Be 0
    }
    It 'the LogPath field names the log only when it exists' {
        Get-SaLogPathField 'C:\x\SRV-IPU-Assessment.log' $true | Should -Be 'C:\x\SRV-IPU-Assessment.log'
        Get-SaLogPathField 'C:\x\SRV-IPU-Assessment.log' $false | Should -Be ''
        Get-SaLogPathField '' $true | Should -Be ''
    }
    It 'RestrictOutputAcl from a profile says it reaches the evidence folders only' {
        Get-ProfileAclNote $false 'CreatedRestricted' | Should -Be ''
        $n = Get-ProfileAclNote $true 'Existing'
        $n | Should -Match 'evidence folders only'
        $n | Should -Match '\(Existing\)'
        $n | Should -Match '-RestrictOutputAcl as an argument'
        Get-ProfileAclNote $true '' | Should -Match '\(unknown\)'
    }
}
