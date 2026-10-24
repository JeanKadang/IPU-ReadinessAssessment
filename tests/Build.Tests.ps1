# Pester 5 tests for build/Build-Script.ps1 (ADR 0002, #151). Builds into
# the test drive; the committed file is only read.

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Build = Join-Path $script:Root 'build\Build-Script.ps1'
    $script:Manifest = Join-Path $script:Root 'src\assessment\manifest.txt'
    $script:Committed = Join-Path $script:Root 'src\Windows-IPU-Readiness-Assessment.ps1'
}

Describe 'Build step: parts -> single file (#151)' {
    It 'the committed script is exactly the build of its parts' {
        $out = Join-Path $TestDrive 'built.ps1'
        $null = & $script:Build -Manifest $script:Manifest -OutputPath $out
        (Get-FileHash -LiteralPath $out).Hash | Should -Be (Get-FileHash -LiteralPath $script:Committed).Hash
    }
    It 'is reproducible: the same parts give the same bytes' {
        $a = Join-Path $TestDrive 'a.ps1'; $b = Join-Path $TestDrive 'b.ps1'
        $null = & $script:Build -Manifest $script:Manifest -OutputPath $a
        $null = & $script:Build -Manifest $script:Manifest -OutputPath $b
        (Get-FileHash -LiteralPath $a).Hash | Should -Be (Get-FileHash -LiteralPath $b).Hash
    }
    It 'says where the parts are, in the built file' {
        [IO.File]::ReadAllText($script:Committed) | Should -Match 'BUILT FROM  : src/assessment/\*\.ps1 by build/Build-Script\.ps1'
    }
    It 'Get-IPUEolStatus.ps1 is exactly the build of its parts, and shares the core with the assessment (#275)' {
        $manifest = Join-Path $script:Root 'src\eol\manifest.txt'
        $out = Join-Path $TestDrive 'eol.ps1'
        $null = & $script:Build -Manifest $manifest -OutputPath $out
        (Get-FileHash -LiteralPath $out).Hash | Should -Be (Get-FileHash -LiteralPath (Join-Path $script:Root 'src\Get-IPUEolStatus.ps1')).Hash
        [IO.File]::ReadAllText($manifest) | Should -Match '\.\./assessment/25-eol-core\.ps1'
    }
    It 'Merge-IPUAssessments.ps1 is exactly the build of its parts, and shares the core too (#275)' {
        $manifest = Join-Path $script:Root 'src\merge\manifest.txt'
        $out = Join-Path $TestDrive 'merge.ps1'
        $null = & $script:Build -Manifest $manifest -OutputPath $out
        (Get-FileHash -LiteralPath $out).Hash | Should -Be (Get-FileHash -LiteralPath (Join-Path $script:Root 'src\Merge-IPUAssessments.ps1')).Hash
        [IO.File]::ReadAllText($manifest) | Should -Match '\.\./assessment/25-eol-core\.ps1'
    }
    Context 'checks on a copy of the parts' {
        BeforeEach {
            $script:Copy = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            Copy-Item -LiteralPath (Join-Path $script:Root 'src\assessment') -Destination $script:Copy -Recurse
            $script:CopyManifest = Join-Path $script:Copy 'manifest.txt'
            $script:CopyOut = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.ps1')
            $null = & $script:Build -Manifest $script:CopyManifest -OutputPath $script:CopyOut
        }
        It '-Check fails when the built file was edited by hand' {
            Add-Content -LiteralPath $script:CopyOut -Value '# hand edit'
            $null = & $script:Build -Manifest $script:CopyManifest -OutputPath $script:CopyOut -Check
            $LASTEXITCODE | Should -Be 1
        }
        It '-Check fails when a part changed and the file was not rebuilt' {
            [IO.File]::AppendAllText((Join-Path $script:Copy '70-main.ps1'), "# changed`r`n")
            $null = & $script:Build -Manifest $script:CopyManifest -OutputPath $script:CopyOut -Check
            $LASTEXITCODE | Should -Be 1
        }
        It '-Check passes when nothing changed' {
            $null = & $script:Build -Manifest $script:CopyManifest -OutputPath $script:CopyOut -Check
            $LASTEXITCODE | Should -Be 0
        }
        It 'refuses a part that is not in the manifest' {
            [IO.File]::WriteAllText((Join-Path $script:Copy '99-extra.ps1'), "# extra`r`n")
            { & $script:Build -Manifest $script:CopyManifest -OutputPath $script:CopyOut } | Should -Throw '*not in the manifest*'
        }
        It 'refuses LF line endings and non-ASCII text' {
            [IO.File]::WriteAllText((Join-Path $script:Copy '70-main.ps1'), "# lf only`n")
            { & $script:Build -Manifest $script:CopyManifest -OutputPath $script:CopyOut } | Should -Throw '*LF line endings*'
            [IO.File]::WriteAllBytes((Join-Path $script:Copy '70-main.ps1'), [byte[]](0x23, 0x20, 0xE6, 0x0D, 0x0A))
            { & $script:Build -Manifest $script:CopyManifest -OutputPath $script:CopyOut } | Should -Throw '*not ASCII*'
        }
    }
}
