# Pester 5 test: the rows of a Post run on the fake server (#445). The checks of
# the Pre run are repeated after the upgrade; a row whose advice is for before
# the upgrade must not come out as a finding.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'The fake server deliberately shadows system cmdlets for the script under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-ins mirror the parameters the script passes to the real cmdlets.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Stand-ins return fixture objects.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'FakeServer.ps1')
    function Resolve-EolProbePath {
        param([string]$Pattern)
        return [pscustomobject]@{ Paths = @(); Error = '' }
    }
    function Invoke-AllCheck {
        # Every check the main script runs in this mode, on a fresh fake server.
        param([string]$Mode)
        $AssessmentMode = $Mode
        $EvidenceRoot = Join-Path $TestDrive ('evidence-' + $Mode)
        $script:Fake = New-FakeMachine
        $script:Data = @{}
        $script:Results.Clear(); $script:CheckRuns.Clear()
        foreach ($check in $script:AllChecks) {
            if ($Mode -eq 'Post' -and @('checklist', 'compatscan') -contains $check.Id) { continue }
            Invoke-Check $check
        }
        return @($script:Results.ToArray())
    }
    $script:PreRows = @(Invoke-AllCheck 'Pre')
    $script:PostRows = @(Invoke-AllCheck 'Post')
    $script:BeforeWording = 'before (the )?(IPU|upgrade|change)|change window|pre-change|Setup will|outage|IPU procedure'
    function Get-PostRow { param([string]$Area, [string]$Item) return ,@($script:PostRows | Where-Object { $_.Area -eq $Area -and $_.Item -eq $Item }) }
}

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'A Post run on the fake server (#445)' -Skip:($env:OS -ne 'Windows_NT') {
    It 'the Pre run of the same server does have findings with advice for before the upgrade' {
        # Otherwise the tests below would pass on an empty fixture.
        @($script:PreRows | Where-Object { $_.Kind -eq 'Finding' -and $_.Recommendation -match $script:BeforeWording }).Count | Should -BeGreaterThan 1
    }
    It 'no finding of the Post run tells the reader to do something before the upgrade' {
        $left = @($script:PostRows | Where-Object { $_.Kind -eq 'Finding' -and $_.Recommendation -match $script:BeforeWording } | ForEach-Object { $_.Area + ' / ' + $_.Item + ': ' + $_.Recommendation })
        $left | Should -BeNullOrEmpty -Because 'each of these needs a rule in $script:PostModeRules, or wording that fits after the upgrade'
    }
    It '<Area> / <Item> is INFO after the upgrade, with a note on what to test' -TestCases @(
        @{ Area = 'WORKLOAD';           Item = 'File Server';  Note = '^Test File Server after the upgrade' }
        @{ Area = 'NETWORK_DEPENDENCY'; Item = 'HostsFile';    Note = 'post-upgrade comparison' }
        @{ Area = 'NETWORK_DEPENDENCY'; Item = 'StaticRoutes'; Note = 'post-upgrade comparison' }
    ) {
        $row = (Get-PostRow $Area $Item)[0]
        $row.Status | Should -Be 'INFO'
        $row.Kind | Should -Be 'Evidence'
        $row.Recommendation | Should -Match $Note
        @($script:PreRows | Where-Object { $_.Area -eq $Area -and $_.Item -eq $Item })[0].Kind | Should -Be 'Finding'
    }
    It 'the antivirus agent is INFO after the upgrade' {
        $pre = @($script:PreRows | Where-Object { $_.Area -eq 'ANTIVIRUS' -and $_.Kind -eq 'Finding' -and $_.Recommendation -match '^Confirm this version supports' })
        $pre.Count | Should -BeGreaterThan 0
        foreach ($p in $pre) {
            $row = (Get-PostRow 'ANTIVIRUS' $p.Item)[0]
            $row.Status | Should -Be 'INFO'
            $row.Recommendation | Should -Match 'reports again'
        }
    }
    It 'a WMI filter that names a Windows version stays a WARNING, worded for after the upgrade' {
        $row = (Get-PostRow 'GROUP_POLICY' 'GPO: Server Baseline')[0]
        $row.Status | Should -Be 'WARNING'; $row.Kind | Should -Be 'Finding'
        $row.Recommendation | Should -Match 'now reports the new release'
    }
    It 'a problem the server has now keeps its status' {
        (Get-PostRow 'STORAGE' 'WinREStatus')[0].Status | Should -Be 'MANUAL'
    }
    It 'the Post run has fewer findings than the Pre run, and none that the Pre run did not have' {
        $key = { param($r) $r.Area + '|' + $r.Item }
        $pre = @($script:PreRows | Where-Object { $_.Kind -eq 'Finding' } | ForEach-Object { & $key $_ })
        $post = @($script:PostRows | Where-Object { $_.Kind -eq 'Finding' } | ForEach-Object { & $key $_ })
        $post.Count | Should -BeLessThan $pre.Count
        @($post | Where-Object { $pre -notcontains $_ }) | Should -BeNullOrEmpty
    }
}
