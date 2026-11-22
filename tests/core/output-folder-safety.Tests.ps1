# Pester 5 tests. An existing output folder is used only when it is safe (GHSA-38wc-349v-wg27).
# The script is loaded in library mode by ..\TestSetup.ps1: functions only, nothing is collected.

BeforeAll { . (Join-Path $PSScriptRoot '..\TestSetup.ps1') }

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'Get-OutputFolderSafetyDecision' {
    BeforeAll {
        $script:Trusted = @('S-1-5-18', 'S-1-5-32-544')
        $script:UserSid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
    }

    It 'accepts a folder owned by SYSTEM' {
        (Get-OutputFolderSafetyDecision $false 'S-1-5-18' $script:Trusted).Safe | Should -BeTrue
    }
    It 'accepts a folder owned by Administrators' {
        (Get-OutputFolderSafetyDecision $false 'S-1-5-32-544' $script:Trusted).Safe | Should -BeTrue
    }
    It 'refuses a folder owned by an ordinary user' {
        $d = Get-OutputFolderSafetyDecision $false $script:UserSid $script:Trusted
        $d.Safe | Should -BeFalse
        $d.Reason | Should -Match 'owned by'
    }
    It 'refuses a junction or symbolic link, whoever owns it' {
        $d = Get-OutputFolderSafetyDecision $true 'S-1-5-18' $script:Trusted
        $d.Safe | Should -BeFalse
        $d.Reason | Should -Match 'junction'
    }
    It 'refuses a folder whose owner cannot be read' {
        (Get-OutputFolderSafetyDecision $false '' $script:Trusted).Safe | Should -BeFalse
    }
    It 'does not judge the owner of a network path, but still refuses a link' {
        (Get-OutputFolderSafetyDecision $false $script:UserSid $script:Trusted $true).Safe | Should -BeTrue
        (Get-OutputFolderSafetyDecision $true $script:UserSid $script:Trusted $true).Safe | Should -BeFalse
    }
}

Describe 'Initialize-OutputFolder with an existing folder' {
    BeforeEach {
        Mock Set-RestrictedFolderAcl { }
        Mock New-RestrictedFolder { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    }

    It 'uses a folder owned by the account running the test' {
        $p = Join-Path $TestDrive 'mine'
        New-Item -ItemType Directory -Path $p | Out-Null
        Initialize-OutputFolder $p $true | Should -Be 'Existing'
    }

    It 'refuses a folder owned by somebody else' {
        $p = Join-Path $TestDrive 'foreign'
        New-Item -ItemType Directory -Path $p | Out-Null
        Mock Get-OutputFolderFact { [pscustomobject]@{ IsReparsePoint = $false; OwnerSid = 'S-1-5-21-1-2-3-1001'; TrustedSids = @('S-1-5-18'); IsRemote = $false } }
        { Initialize-OutputFolder $p $true } | Should -Throw '*already exists and is not used*'
    }

    It 'refuses a junction to another folder' {
        $target = Join-Path $TestDrive 'target'
        $link = Join-Path $TestDrive 'link'
        New-Item -ItemType Directory -Path $target | Out-Null
        & cmd.exe /c mklink /J "$link" "$target" | Out-Null
        $link | Should -Exist
        { Initialize-OutputFolder $link $true } | Should -Throw '*junction*'
        { Initialize-OutputFolder (Join-Path $link 'sub') $true } | Should -Not -Throw
    }
}
