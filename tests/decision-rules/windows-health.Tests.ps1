# Pester 5 tests. Decision rules: DISM, SFC and VSS verdicts, language-neutral parsing.
# The script is loaded in library mode by ..\TestSetup.ps1: functions only, nothing is collected.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
param()

BeforeAll { . (Join-Path $PSScriptRoot '..\TestSetup.ps1') }

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'Get-DismVerdict' {
    It 'healthy' { (Get-DismVerdict 'No component store corruption detected.' 0).Status | Should -Be 'OK' }
    It 'repairable' {
        $v = Get-DismVerdict 'The component store is repairable.' 0
        $v.Status | Should -Be 'ACTION'; $v.Recommendation | Should -Match 'RestoreHealth'
    }
    It 'a component store that cannot be repaired is an ACTION' { (Get-DismVerdict 'The component store cannot be repaired.' 0).Status | Should -Be 'ACTION' }
    It 'a plain error code is MANUAL, not a repair (#249)' {
        $v = Get-DismVerdict 'Error: 87' 87
        $v.Status | Should -Be 'MANUAL'; $v.Basis | Should -Match 'exit code 87'
        $v.Recommendation | Should -Not -Match 'RestoreHealth'; $v.Recommendation | Should -Match 'not evidence of corruption'
    }
    It 'a pending servicing operation (0x800f082f) is a WARNING to reboot, not a repair (#249)' {
        $v = Get-DismVerdict "Error: 0x800f082f`r`nA servicing operation requires a reboot to complete." (-2146498513)
        $v.Status | Should -Be 'WARNING'; $v.Basis | Should -Be 'Servicing pending reboot'
        $v.Recommendation | Should -Match 'restart'; $v.Recommendation | Should -Not -Match 'RestoreHealth'
    }
    It 'the pending code alone is enough, whatever the language of the text' { (Get-DismVerdict '0x800f082f' 1).Status | Should -Be 'WARNING' }
    It 'exit code 3010 (restart required) is pending too' { (Get-DismVerdict '' 3010).Status | Should -Be 'WARNING' }
    It 'DISM text about corruption wins over a non-zero exit code' { (Get-DismVerdict 'The component store is repairable.' 1).Status | Should -Be 'ACTION' }
    It 'unclear' { (Get-DismVerdict '' 0).Status | Should -Be 'MANUAL' }
    It 'no exit code and no text is unclear' { (Get-DismVerdict '' $null).Basis | Should -Be 'Unclassified' }
}

Describe 'Get-SfcVerdict' {
    It 'English clean output' { (Get-SfcVerdict 'Windows Resource Protection did not find any integrity violations.' @()).Status | Should -Be 'OK' }
    It 'English violations' { (Get-SfcVerdict 'Windows Resource Protection found integrity violations.' @()).Status | Should -Be 'ACTION' }
    It 'a repair waiting for a reboot is a WARNING, not violations (#159)' {
        $cbs = @('2026-10-09 08:20:00, Info CSI 00000001 [SR] Cannot repair member file [l:10]"x.dll" of y, file is missing')
        $v = Get-SfcVerdict ('There is a system repair pending which requires reboot to complete.  Restart' + [Environment]::NewLine + 'Windows and run sfc again.') $cbs
        $v.Status | Should -Be 'WARNING'
        $v.Basis | Should -Be 'Repair pending reboot'
    }
    It 'localized output falls back to clean CBS.log' {
        $cbs = @('2026-10-06 09:00:01, Info                  CSI    00000005 [SR] Verifying 100 components',
                 '2026-10-06 09:05:01, Info                  CSI    00000099 [SR] Verify complete')
        $v = Get-SfcVerdict 'Windows-ressourcebeskyttelse fandt ingen integritetskraenkelser.' $cbs
        $v.Status | Should -Be 'OK'; $v.Basis | Should -Be 'CBS.log'
    }
    It 'localized output with corruption in CBS.log' {
        $cbs = @('2026-10-06 09:02:01, Info  CSI  0000001 Hashes for file member \SystemRoot\x.dll do not match actual file',
                 '2026-10-06 09:05:01, Info  CSI  00000099 [SR] Verify complete')
        (Get-SfcVerdict 'lokaliseret tekst' $cbs).Status | Should -Be 'ACTION'
    }
    It 'localized output with a damaged manifest in CBS.log is not OK (#249)' {
        $cbs = @('2026-10-06 09:02:01, Info  CSI  0000001 [SR] Cannot verify component files for Microsoft-Windows-Foo, Version = 10.0.1.0, pa = 9 (x64), manifest is damaged (TRUE)',
                 '2026-10-06 09:05:01, Info  CSI  00000099 [SR] Verify complete')
        (Get-SfcVerdict 'lokaliseret tekst' $cbs).Status | Should -Be 'ACTION'
    }
    It 'localized output where SFC could not verify a component is not OK (#249)' {
        $cbs = @('2026-10-06 09:02:01, Info  CSI  0000001 [SR] Cannot verify component files for Microsoft-Windows-Foo',
                 '2026-10-06 09:05:01, Info  CSI  00000099 [SR] Verify complete')
        (Get-SfcVerdict 'lokaliseret tekst' $cbs).Status | Should -Be 'ACTION'
    }
    It 'nothing usable' { (Get-SfcVerdict '' @()).Status | Should -Be 'MANUAL' }
}

Describe 'VSS writer parsing' {
    BeforeAll {
        $script:sample = @(
            "Writer name: 'Task Scheduler Writer'",
            '   Writer Id: {d61d61c8-d73a-4eee-8cdd-f6f9786b7124}',
            '   Writer Instance Id: {1bddd48e-5052-49db-9b07-b96f96727e6b}',
            '   State: [1] Stable',
            '   Last error: No error',
            "Writer name: 'SqlServerWriter'",
            '   Writer Id: {a65faa63-5ea8-4ebc-9dbd-a0c4db26912a}',
            '   Writer Instance Id: {9075d8d5-a7d9-4d3d-8d82-7e8c2d0e71bc}',
            '   State: [8] Failed',
            '   Last error: Retryable error'
        )
    }
    It 'parses two writers' {
        $w = ConvertFrom-VssWriterOutput $script:sample
        $w.Count | Should -Be 2
        $w[0].Name | Should -Be 'Task Scheduler Writer'
        $w[1].StateCode | Should -Be 8
    }
    It 'classifies stable/no error as OK and failed as ACTION' {
        $w = ConvertFrom-VssWriterOutput $script:sample
        Get-VssWriterStatus $w[0] | Should -Be 'OK'
        Get-VssWriterStatus $w[1] | Should -Be 'ACTION'
    }
    It 'parses localized labels by structure' {
        $w = ConvertFrom-VssWriterOutput @("Skrivernavn: 'System Writer'", '   Tilstand: [1] Stabil', '   Seneste fejl: Ingen fejl')
        $w[0].Name | Should -Be 'System Writer'
        $w[0].StateCode | Should -Be 1
        $w[0].LastError | Should -Be 'Ingen fejl'
    }
}

Describe 'Language-neutral parsing (#246)' {
    BeforeAll {
        function New-VssWriter([string]$Name, $Code, [string]$Err) { [pscustomobject]@{ Name = $Name; StateCode = $Code; StateText = ''; LastError = $Err } }
    }
    Context 'VSS writers' {
        It 'English "No error" is OK' { Get-VssWriterStatus (New-VssWriter 'A' 1 'No error') | Should -Be 'OK' }
        It 'a writer that is not stable is an ACTION whatever the language' { Get-VssWriterStatus (New-VssWriter 'A' 8 'Kein Fehler') 'kein fehler' | Should -Be 'ACTION' }
        It 'the most common text among the stable writers is the local "no error" (German)' {
            $w = @((New-VssWriter 'A' 1 'Kein Fehler'), (New-VssWriter 'B' 1 'Kein Fehler'), (New-VssWriter 'C' 1 'Kein Fehler'), (New-VssWriter 'D' 1 'Wiederholbarer Fehler'))
            Get-VssNoErrorText $w | Should -Be 'kein fehler'
            Get-VssWriterStatus $w[0] 'kein fehler' | Should -Be 'OK'
            Get-VssWriterStatus $w[3] 'kein fehler' | Should -Be 'ACTION'
        }
        It 'Italian "Nessun errore" contains "error" but is OK; a different text is an ACTION' {
            $w = @((New-VssWriter 'A' 1 'Nessun errore'), (New-VssWriter 'B' 1 'Nessun errore'), (New-VssWriter 'C' 1 'Errore non ripetibile'))
            $no = Get-VssNoErrorText $w
            $no | Should -Be 'nessun errore'
            Get-VssWriterStatus $w[0] $no | Should -Be 'OK'
            Get-VssWriterStatus $w[2] $no | Should -Be 'ACTION'
        }
        It 'without the local text a German writer is MANUAL, not OK' { Get-VssWriterStatus (New-VssWriter 'A' 1 'Kein Fehler') | Should -Be 'MANUAL' }
        It 'one stable writer is too few to learn the text' { Get-VssNoErrorText @((New-VssWriter 'A' 1 'Kein Fehler')) | Should -Be '' }
        It 'no clear majority learns nothing' {
            Get-VssNoErrorText @((New-VssWriter 'A' 1 'x'), (New-VssWriter 'B' 1 'x'), (New-VssWriter 'C' 1 'y'), (New-VssWriter 'D' 1 'z')) | Should -Be ''
        }
        It 'a majority that reads like an English error is never "no error"' {
            Get-VssNoErrorText @((New-VssWriter 'A' 1 'Retryable error'), (New-VssWriter 'B' 1 'Retryable error')) | Should -Be ''
        }
        It 'writers that are not stable are left out when learning' {
            Get-VssNoErrorText @((New-VssWriter 'A' 8 'Timed out'), (New-VssWriter 'B' 8 'Timed out'), (New-VssWriter 'C' 1 'Aucune erreur'), (New-VssWriter 'D' 1 'Aucune erreur')) | Should -Be 'aucune erreur'
        }
    }
    Context 'WinRE' {
        BeforeAll {
            $script:ReXml = "<WindowsRE version=`"2.0`">`r`n  <WinreLocation path=`"\Recovery\WindowsRE`" id=`"0`" offset=`"499218644992`"/>`r`n  <InstallState state=`"1`"/>`r`n</WindowsRE>"
            $script:ReXmlOff = "<WindowsRE version=`"2.0`"><InstallState state=`"0`"/></WindowsRE>"
            $script:GermanText = "Windows-Wiederherstellungsumgebung (Windows RE)`r`nInformationen:`r`n    Status der Windows RE:  Aktiviert`r`n    Windows RE-Speicherort:  \\?\GLOBALROOT\device\harddisk0\partition4\Recovery\WindowsRE"
        }
        It 'German reagentc text: the location is read, the status comes from ReAgent.xml' {
            $r = ConvertFrom-ReagentcInfo $script:GermanText $script:ReXml
            $r.Enabled | Should -BeTrue; $r.Disk | Should -Be 0; $r.Partition | Should -Be 4
        }
        It 'a disabled state in ReAgent.xml is read' { (ConvertFrom-ReagentcInfo '' $script:ReXmlOff).Enabled | Should -BeFalse }
        It 'German text alone leaves the status unknown, not guessed' { (ConvertFrom-ReagentcInfo $script:GermanText).Enabled | Should -BeNullOrEmpty }
        It 'ReAgent.xml wins over the English words' { (ConvertFrom-ReagentcInfo 'Windows RE status:  Enabled' $script:ReXmlOff).Enabled | Should -BeFalse }
        It 'the location can come from the XML when the text has none' {
            $x = '<WinreLocation path="\\?\GLOBALROOT\device\harddisk1\partition2\Recovery\WindowsRE" id="0"/><InstallState state="1"/>'
            $r = ConvertFrom-ReagentcInfo '' $x
            $r.Disk | Should -Be 1; $r.Partition | Should -Be 2
        }
    }
    Context 'Read-ReAgentXml' {
        It 'returns the text of the file' {
            $p = Join-Path $TestDrive 'ReAgent.xml'
            Set-Content -LiteralPath $p -Value '<WindowsRE><InstallState state="1"/></WindowsRE>'
            (Read-ReAgentXml $p) | Should -Match 'InstallState state="1"'
        }
        It 'a missing file is empty text, not an error' { Read-ReAgentXml (Join-Path $TestDrive 'nothing.xml') | Should -Be '' }
        It 'the default path is the system file and never throws' { { $null = Read-ReAgentXml } | Should -Not -Throw }
    }
    Context 'scheduled task accounts' {
        It 'ServiceAccount and Group are built in, whatever the name (German)' {
            Test-BuiltInTaskAccount 'NT-AUTORITAET\SYSTEM' 'ServiceAccount' | Should -BeTrue
            Test-BuiltInTaskAccount 'LOKALER DIENST' 'ServiceAccount' | Should -BeTrue
            Test-BuiltInTaskAccount 'Benutzer' 'Group' | Should -BeTrue
        }
        It 'a named account is not built in' {
            Test-BuiltInTaskAccount 'CORP\svc-backup' 'Password' | Should -BeFalse
            Test-BuiltInTaskAccount 'CORP\svc-backup' '' | Should -BeFalse
        }
        It 'the English names and SIDs are the second signal' {
            foreach ($n in 'SYSTEM', 'NT AUTHORITY\SYSTEM', 'LOCAL SERVICE', 'S-1-5-18', 'BUILTIN\Users', 'S-1-5-32-545', 'Everyone') { Test-BuiltInTaskAccount $n '' | Should -BeTrue }
        }
        It 'no account at all is not a named account' { Test-BuiltInTaskAccount '' '' | Should -BeTrue }
    }
    Context 'native output code page' {
        It 'decodes with the given code page' {
            $bytes = [byte[]](0x61, 0xD5, 0x62)
            (ConvertFrom-NativeByteArray $bytes 850) | Should -Be ('a' + [string][char]0x0131 + 'b')   # CP850 0xD5 = dotless i
            (ConvertFrom-NativeByteArray $bytes 437) | Should -Be ('a' + [string][char]0x2552 + 'b')   # CP437 0xD5 = box drawing
        }
        It 'defaults to the system OEM code page, not the current user''s' {
            $bytes = [byte[]](0x61, 0x84, 0x62)
            $expect = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::InstalledUICulture.TextInfo.OEMCodePage).GetString($bytes)
            (ConvertFrom-NativeByteArray $bytes) | Should -Be $expect
        }
        It 'UTF-16 output is still detected' { (ConvertFrom-NativeByteArray ([Text.Encoding]::Unicode.GetBytes('Abc')) 850) | Should -Be 'Abc' }
    }
    Context 'dates are written in the invariant culture' {
        It 'a Danish time separator and a Thai calendar do not change the SA line format' {
            $d = Get-Date -Year 2026 -Month 10 -Day 24 -Hour 9 -Minute 5 -Second 7
            $old = [Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('th-TH')
                $d.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) | Should -Be '2026-10-24 09:05:07'
                $d.ToString('yyyy-MM-dd HH:mm:ss') | Should -Not -Be '2026-10-24 09:05:07'
            } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $old }
        }
        It 'no date is formatted with the current culture in the collector' {
            $src = [IO.File]::ReadAllLines((Join-Path $PSScriptRoot '..\..\src\Windows-IPU-Readiness-Assessment.ps1'))
            $bad = @($src | Where-Object { $_ -match "\.ToString\('yyyy[^']*'\)" -or $_ -match "Get-Date -Format" })
            $bad | Should -BeNullOrEmpty
        }
    }
}
