# Pester 5 tests for the check data owners (#360): src/assessment/35-check-data.ps1.
# The check bodies (one function each in src/assessment/5?-checks-*.ps1, registered in 50-checks.ps1) are READ (parsed), not run:
# the test fails when a check writes a key of $script:Data that it does not own,
# when an owner no longer writes its key, or when a key declared unused is read.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestSetup.ps1')
    $script:Parts = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src\assessment'

    function Get-DataPath {
        # The member path of an expression rooted at $script:Data, for example
        # Snapshot.Ports for $script:Data.Snapshot.Ports; $null when it is not.
        param($Expression)
        $path = @()
        $e = $Expression
        while ($e) {
            if ($e -is [Management.Automation.Language.MemberExpressionAst]) {
                if ($e.Member -isnot [Management.Automation.Language.StringConstantExpressionAst]) { return $null }
                $path = @($e.Member.Value) + $path
                $e = $e.Expression
            } elseif ($e -is [Management.Automation.Language.IndexExpressionAst]) {
                if ($e.Index -isnot [Management.Automation.Language.StringConstantExpressionAst]) { return $null }
                $path = @($e.Index.Value) + $path
                $e = $e.Target
            } elseif ($e -is [Management.Automation.Language.ConvertExpressionAst]) {
                $e = $e.Child
            } elseif ($e -is [Management.Automation.Language.VariableExpressionAst]) {
                if ($e.VariablePath.UserPath -eq 'script:Data') { return , $path }
                return $null
            } else { return $null }
        }
        return $null
    }

    function Get-DataWrite {
        # What a block of code writes: Keys (Data keys), Lists (Snapshot lists
        # assigned or removed) and Seeds (lists created empty by assigning a
        # table to Snapshot).
        param($Ast)
        $keys = New-Object Collections.Generic.HashSet[string]
        $lists = New-Object Collections.Generic.HashSet[string]
        $seeds = New-Object Collections.Generic.HashSet[string]
        $assignments = $Ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] }, $true)
        foreach ($a in $assignments) {
            $path = Get-DataPath $a.Left
            if ($null -eq $path -or $path.Count -eq 0) { continue }
            if ($path[0] -eq 'Snapshot' -and $path.Count -ge 2) { $null = $lists.Add([string]$path[1]); continue }
            $null = $keys.Add([string]$path[0])
            if ($path[0] -eq 'Snapshot') {
                $table = $a.Right.Find({ param($n) $n -is [Management.Automation.Language.HashtableAst] }, $false)
                if ($table) { foreach ($pair in $table.KeyValuePairs) { $null = $seeds.Add([string]$pair.Item1.Value) } }
            }
        }
        $calls = $Ast.FindAll({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -in @('Remove', 'Add', 'Clear') }, $true)
        foreach ($c in $calls) {
            $path = Get-DataPath $c.Expression
            if ($null -eq $path) { continue }
            if ($c.Arguments.Count -eq 0 -or $c.Arguments[0] -isnot [Management.Automation.Language.StringConstantExpressionAst]) { continue }
            if ($path.Count -eq 1 -and $path[0] -eq 'Snapshot') { $null = $lists.Add([string]$c.Arguments[0].Value) }
            elseif ($path.Count -eq 0) { $null = $keys.Add([string]$c.Arguments[0].Value) }
        }
        return [pscustomobject]@{ Keys = @($keys); Lists = @($lists); Seeds = @($seeds) }
    }

    # The writes of every check body, by check id. Invoke-RdpPolicyAssessment is
    # the body of the rdp check, in steps (Invoke-Rdp*, Save-Rdp*, Find-Rdp*).
    $script:FileAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Parts '50-checks.ps1'), [ref]$null, [ref]$null)
    # Every function of the check parts: the registry (50-checks.ps1) and one function per check.
    $script:CheckPartFiles = @(Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $script:Parts -Filter '5*-checks*.ps1')
    $script:CheckPartFunctions = @{}
    foreach ($file in $script:CheckPartFiles) {
        $partAst = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
        foreach ($fn in $partAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { $script:CheckPartFunctions[$fn.Name] = $fn }
    }
    function Get-CheckBody {
        # The code of a registered check: the function its script block calls,
        # or the script block itself when it calls a helper (rdp).
        param($Register)
        $block = $null
        foreach ($el in @($Register.CommandElements)) { if ($el -is [Management.Automation.Language.ScriptBlockExpressionAst]) { $block = $el } }
        $called = @($block.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true))
        if ($called.Count -eq 1 -and $script:CheckPartFunctions.ContainsKey($called[0].GetCommandName()) -and $called[0].GetCommandName() -like 'Invoke-*Check') { return $script:CheckPartFunctions[$called[0].GetCommandName()] }
        return $block
    }
    function Get-CheckId {
        param($Register)
        $els = @($Register.CommandElements)
        for ($i = 0; $i -lt $els.Count; $i++) { if ($els[$i] -is [Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq 'Id') { return [string]$els[$i + 1].Value } }
    }
    $script:Writes = @{}
    $script:CheckBodyFunction = @{}
    $registers = $script:FileAst.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Register-Check' }, $true)
    foreach ($r in $registers) {
        $id = Get-CheckId $r
        $body = Get-CheckBody $r
        if ($body -is [Management.Automation.Language.FunctionDefinitionAst]) { $script:CheckBodyFunction[$body.Name] = $id }
        $script:Writes[$id] = Get-DataWrite $body
    }
    $script:CheckIds = @($script:Writes.Keys)
    $script:FunctionOwner = @{}
    foreach ($name in 'Invoke-RdpPolicyAssessment', 'Save-RdpPolicyEvidence', 'Invoke-RdpEnablementAssessment', 'Invoke-RdpNlaAssessment', 'Invoke-RdpListenerAssessment', 'Invoke-RdpUserRightAssessment', 'Find-RdpDriveBlock', 'Add-RdpVerdictResult', 'Close-RdpPolicyEvidence') { $script:FunctionOwner[$name] = 'rdp' }
    $script:OtherFunctions = @($script:CheckPartFunctions.Values | Where-Object { $_.Name -ne 'Register-AssessmentCheck' -and -not $script:CheckBodyFunction.ContainsKey($_.Name) })
    foreach ($f in $script:OtherFunctions) {
        if ($script:FunctionOwner.ContainsKey($f.Name)) {
            $w = Get-DataWrite $f
            $have = $script:Writes[$script:FunctionOwner[$f.Name]]
            $script:Writes[$script:FunctionOwner[$f.Name]] = [pscustomobject]@{
                Keys = @($have.Keys + $w.Keys | Select-Object -Unique)
                Lists = @($have.Lists + $w.Lists | Select-Object -Unique)
                Seeds = @($have.Seeds + $w.Seeds | Select-Object -Unique)
            }
        }
    }
}

Describe 'Check data owners: keys of $script:Data (#360)' {
    It 'found the checks and the writes (the parser sees what it should)' {
        $script:CheckIds.Count | Should -Be 38
        $script:Writes['baseline'].Keys | Should -Contain 'OS'
        $script:Writes['rdp'].Keys | Should -Contain 'NlaState' -Because 'Invoke-RdpPolicyAssessment counts as the rdp check'
        $script:Writes['network'].Lists | Should -Contain 'Routes'
    }
    It 'every function of the check parts other than the registry and the check functions is attributed to a check' {
        $unmapped = @($script:OtherFunctions | Where-Object { -not $script:FunctionOwner.ContainsKey($_.Name) } | ForEach-Object { $_.Name })
        $unmapped | Should -BeNullOrEmpty -Because ('functions whose writes are not attributed: ' + ($unmapped -join ', '))
    }
    It 'a check writes only keys it owns' {
        $violations = @()
        foreach ($id in $script:CheckIds) {
            foreach ($key in $script:Writes[$id].Keys) {
                if (@(Get-CheckDataOwner $key) -notcontains $id) { $violations += ('check ' + $id + ' writes Data.' + $key + ' (owner: ' + ((@(Get-CheckDataOwner $key)) -join ', ') + ')') }
            }
        }
        $violations | Should -BeNullOrEmpty -Because ('declare the owner in src/assessment/35-check-data.ps1, or move the write: ' + ($violations -join '; '))
    }
    It 'an owner that is a check still writes its key' {
        $stale = @()
        foreach ($key in $script:CheckDataOwners.Keys) {
            foreach ($owner in @(Get-CheckDataOwner $key)) {
                if ($script:CheckDataNonCheckOwners -contains $owner) { continue }
                if ($script:CheckIds -notcontains $owner) { $stale += ('Data.' + $key + ' is owned by ' + $owner + ', which is not a check'); continue }
                if ($script:Writes[$owner].Keys -notcontains $key) { $stale += ('check ' + $owner + ' owns Data.' + $key + ' but does not write it') }
            }
        }
        $stale | Should -BeNullOrEmpty -Because ($stale -join '; ')
    }
    It 'an owner outside the checks is main, report or rules, and no check body writes the key' {
        foreach ($key in $script:CheckDataOwners.Keys) {
            $owners = @(Get-CheckDataOwner $key)
            $owners.Count | Should -BeGreaterThan 0
            foreach ($owner in $owners) { ($script:CheckIds + $script:CheckDataNonCheckOwners) | Should -Contain $owner }
        }
    }
    It 'Get-CheckDataOwner: one owner, several owners, unknown key' {
        @(Get-CheckDataOwner 'OS') | Should -Be @('baseline')
        $script:CheckDataOwners['SeveralOwnersProbe'] = 'baseline, upgradepath ,cluster'
        try { @(Get-CheckDataOwner 'SeveralOwnersProbe') | Should -Be @('baseline', 'upgradepath', 'cluster') }
        finally { $script:CheckDataOwners.Remove('SeveralOwnersProbe') }
        @(Get-CheckDataOwner 'NoSuchKey').Count | Should -Be 0
    }
}

Describe 'Check data owners: the unused keys (#360)' {
    It 'a key declared unused is read nowhere in the source parts' {
        $reads = @()
        foreach ($file in (Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $script:Parts -Filter '*.ps1')) {
            if ($file.Name -eq '35-check-data.ps1') { continue }
            $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $assignedLeft = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] }, $true) | ForEach-Object { $_.Left.Extent.StartOffset })
            $members = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.MemberExpressionAst] -or $n -is [Management.Automation.Language.IndexExpressionAst] }, $true)
            foreach ($m in $members) {
                $path = Get-DataPath $m
                if ($null -eq $path -or $path.Count -eq 0) { continue }
                if ($script:CheckDataUnused -notcontains $path[0]) { continue }
                if ($assignedLeft -contains $m.Extent.StartOffset) { continue }
                $reads += ($file.Name + ' reads Data.' + $path[0])
            }
        }
        $reads | Should -BeNullOrEmpty -Because ('a key listed in CheckDataUnused is read now; remove it from that list: ' + ($reads -join '; '))
    }
    It 'every unused key is a declared key' {
        foreach ($key in $script:CheckDataUnused) { $script:CheckDataOwners.Contains($key) | Should -BeTrue -Because $key }
    }
}

Describe 'Check data owners: the lists of the snapshot (#360)' {
    It 'every list a check writes is declared, and its owner is the writer' {
        $violations = @()
        foreach ($id in $script:CheckIds) {
            foreach ($list in $script:Writes[$id].Lists) {
                if (-not $script:SnapshotListOwners.Contains($list)) { $violations += ('check ' + $id + ' writes Snapshot.' + $list + ', which is not declared'); continue }
                if ($script:SnapshotListOwners[$list].Owner -ne $id) { $violations += ('check ' + $id + ' writes Snapshot.' + $list + ' (owner: ' + $script:SnapshotListOwners[$list].Owner + ')') }
            }
        }
        $violations | Should -BeNullOrEmpty -Because ($violations -join '; ')
    }
    It 'a declared list is written by its owner, or created by baseline when baseline owns it' {
        $stale = @()
        foreach ($list in $script:SnapshotListOwners.Keys) {
            $owner = $script:SnapshotListOwners[$list].Owner
            if ($script:CheckIds -notcontains $owner) { $stale += ('Snapshot.' + $list + ' is owned by ' + $owner + ', which is not a check'); continue }
            $writes = $script:Writes[$owner]
            $seededByOwner = ($owner -eq 'baseline') -and ($writes.Seeds -contains $list)
            if (($writes.Lists -notcontains $list) -and -not $seededByOwner) { $stale += ('check ' + $owner + ' owns Snapshot.' + $list + ' but does not write it') }
        }
        $stale | Should -BeNullOrEmpty -Because ($stale -join '; ')
    }
    It 'baseline creates every declared list' {
        foreach ($list in $script:SnapshotListOwners.Keys) {
            # Features is added only when the inventory was read (#361): not seeded.
            if ($list -in @('Gpos', 'Groups', 'Shares', 'Uac', 'Ou', 'Nla', 'PortOwners', 'Features')) { continue }
            $script:Writes['baseline'].Seeds | Should -Contain $list -Because ('baseline seeds Snapshot.' + $list + ' empty so a failed check leaves the list empty, which CheckRuns then flags')
        }
    }
}

Describe 'The Features list is created only when it was read (#361)' {
    It 'baseline assigns Snapshot.Features after the table, and does not seed it' {
        $script:Writes['baseline'].Lists | Should -Contain 'Features'
        $script:Writes['baseline'].Seeds | Should -Not -Contain 'Features' -Because 'a list seeded empty cannot be told from a list that was read and is empty'
    }
}

Describe 'Get-SnapshotListSourceMap (#360)' {
    It 'gives the lists the Post run compares, with the check that collects each, in the old order' {
        $map = Get-SnapshotListSourceMap -Compare Both
        @($map.Keys) | Should -Be @('Services', 'Apps', 'Features', 'Ports', 'IPv4', 'Dns', 'Adapters', 'Hosts', 'Routes', 'Tasks', 'Shares', 'Printers', 'PrinterPorts', 'PrinterDrivers')
        $map['Services'] | Should -Be 'baseline'
        $map['Routes'] | Should -Be 'network'
        $map['Printers'] | Should -Be 'printers'
        $map['Shares'] | Should -Be 'fileshares'
    }
    It 'gives the lists checked on the current side only' {
        $map = Get-SnapshotListSourceMap -Compare Current
        @($map.Keys) | Should -Be @('Gpos', 'Groups')
        $map['Gpos'] | Should -Be 'grouppolicy'
    }
    It 'the maps the comparison uses are these maps' {
        @($script:SnapshotListSources.Keys) | Should -Be @((Get-SnapshotListSourceMap -Compare Both).Keys)
        @($script:SnapshotCurrentListSources.Keys) | Should -Be @((Get-SnapshotListSourceMap -Compare Current).Keys)
    }
    It 'every source is a registered check' {
        foreach ($id in @($script:SnapshotListSources.Values) + @($script:SnapshotCurrentListSources.Values)) { $script:CheckIds | Should -Contain $id }
    }
    It 'refuses another Compare value' {
        { Get-SnapshotListSourceMap -Compare 'None' } | Should -Throw
    }
}

Describe 'Check data owners: every read is of a declared key (#360)' {
    BeforeAll {
        $script:UndeclaredReads = @()
        foreach ($file in (Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $script:Parts -Filter '*.ps1')) {
            if ($file.Name -eq '35-check-data.ps1') { continue }
            $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $members = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.MemberExpressionAst] -and $n -isnot [Management.Automation.Language.InvokeMemberExpressionAst] }, $true)
            foreach ($m in $members) {
                $path = Get-DataPath $m
                if ($null -eq $path -or $path.Count -eq 0) { continue }
                if (-not $script:CheckDataOwners.Contains([string]$path[0])) {
                    $script:UndeclaredReads += ($file.Name + ' line ' + $m.Extent.StartLineNumber + ': Data.' + $path[0]); continue
                }
                if ($path[0] -eq 'Snapshot' -and $path.Count -ge 2 -and -not $script:SnapshotListOwners.Contains([string]$path[1])) {
                    $script:UndeclaredReads += ($file.Name + ' line ' + $m.Extent.StartLineNumber + ': Data.Snapshot.' + $path[1])
                }
            }
        }
    }
    It 'no source part reads a key of $script:Data or a snapshot list that is not declared (a misspelled key reads as $null without an error)' {
        $script:UndeclaredReads | Should -BeNullOrEmpty -Because ($script:UndeclaredReads -join '; ')
    }
    It 'the scan sees reads (it is not vacuous)' {
        $count = 0
        foreach ($file in $script:CheckPartFiles) {
            $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $count += @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.MemberExpressionAst] -and $n -isnot [Management.Automation.Language.InvokeMemberExpressionAst] }, $true) | Where-Object { $null -ne (Get-DataPath $_) }).Count
        }
        $count | Should -BeGreaterThan 100
    }
}

Describe 'Check needs: what a check cannot run without (#360, step 3)' {
    BeforeAll {
        $parser = [Management.Automation.Language.Parser]
        # Every function in the parts, to follow a check into the helpers it calls.
        $script:PartFunctions = @{}
        foreach ($file in (Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $script:Parts -Filter '*.ps1')) {
            $partAst = $parser::ParseFile($file.FullName, [ref]$null, [ref]$null)
            foreach ($fn in $partAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
                if ($fn.Name -ne 'Register-AssessmentCheck') { $script:PartFunctions[$fn.Name] = $fn }
            }
        }
        function Get-DataRead {
            # The first member of every read of $script:Data in a block of code.
            # A compound assignment (+=) reads the value it extends, so it counts.
            param($Ast)
            $plainLeft = @($Ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Operator -eq [Management.Automation.Language.TokenKind]::Equals }, $true) | ForEach-Object { $_.Left.Extent.StartOffset })
            $set = New-Object Collections.Generic.HashSet[string]
            foreach ($m in $Ast.FindAll({ param($n) $n -is [Management.Automation.Language.MemberExpressionAst] -and $n -isnot [Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
                $path = Get-DataPath $m
                if ($null -eq $path -or $path.Count -eq 0) { continue }
                if ($plainLeft -contains $m.Extent.StartOffset) { continue }
                $null = $set.Add([string]$path[0])
            }
            return @($set)
        }
        $script:ReadMemo = @{}
        function Get-FunctionRead {
            param([string]$Name, [string[]]$Stack = @())
            if ($script:ReadMemo.ContainsKey($Name)) { return $script:ReadMemo[$Name] }
            if ($Stack -contains $Name) { return @() }
            $fn = $script:PartFunctions[$Name]
            $set = New-Object Collections.Generic.HashSet[string]
            foreach ($k in (Get-DataRead $fn)) { $null = $set.Add($k) }
            foreach ($c in $fn.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)) {
                $called = $c.GetCommandName()
                if ($called -and $script:PartFunctions.ContainsKey($called)) { foreach ($k in (Get-FunctionRead $called ($Stack + $Name))) { $null = $set.Add($k) } }
            }
            $script:ReadMemo[$Name] = @($set)
            return $script:ReadMemo[$Name]
        }
        # The keys each check reads, in registration order.
        $script:CheckReads = [ordered]@{}
        foreach ($r in $script:FileAst.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Register-Check' }, $true)) {
            $id = Get-CheckId $r
            $body = Get-CheckBody $r
            $set = New-Object Collections.Generic.HashSet[string]
            foreach ($k in (Get-DataRead $body)) { $null = $set.Add($k) }
            foreach ($c in $body.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)) {
                $called = $c.GetCommandName()
                if ($called -and $script:PartFunctions.ContainsKey($called)) { foreach ($k in (Get-FunctionRead $called)) { $null = $set.Add($k) } }
            }
            $script:CheckReads[$id] = @($set)
        }
        $script:BaselineKeys = @($script:CheckDataOwners.Keys | Where-Object { @(Get-CheckDataOwner $_) -eq 'baseline' })
        $script:DerivedBaselineNeeds = @($script:CheckReads.Keys | Where-Object { $_ -ne 'baseline' -and @($script:CheckReads[$_] | Where-Object { $script:BaselineKeys -contains $_ }).Count -gt 0 })
        $script:DeclaredBaselineNeeds = @($script:CheckNeeds.Keys | Where-Object { @(Get-CheckNeed $_) -contains 'baseline' })
    }
    It 'the scan sees the checks and what they read (it is not vacuous)' {
        @($script:CheckReads.Keys).Count | Should -Be 38
        $script:CheckReads['upgradepath'] | Should -Contain 'OS'
        $script:CheckReads['upgradepath'] | Should -Contain 'Features' -Because 'Get-FeatureState is a helper that reads Data.Features'
        $script:CheckReads['tasks'] | Should -Contain 'Snapshot' -Because 'a += on a snapshot list extends what baseline created'
        $script:DerivedBaselineNeeds.Count | Should -BeGreaterThan 20
    }
    It 'every check that reads what baseline collects needs baseline' {
        $missing = @($script:DerivedBaselineNeeds | Where-Object { $script:DeclaredBaselineNeeds -notcontains $_ })
        $missing | Should -BeNullOrEmpty -Because ('declare them in $script:CheckNeeds (35-check-data.ps1): ' + ($missing -join ', '))
    }
    It 'no check needs baseline without reading what it collects' {
        $extra = @($script:DeclaredBaselineNeeds | Where-Object { $script:DerivedBaselineNeeds -notcontains $_ })
        $extra | Should -BeNullOrEmpty -Because ('these read nothing from baseline, so a failed baseline must not stop them: ' + ($extra -join ', '))
    }
    It 'every other need is a read of a key the needed check owns' {
        $wrong = @()
        foreach ($id in $script:CheckNeeds.Keys) {
            foreach ($source in @(Get-CheckNeed $id)) {
                if ($source -eq 'baseline') { continue }
                $owned = @($script:CheckDataOwners.Keys | Where-Object { @(Get-CheckDataOwner $_) -contains $source })
                if (@($script:CheckReads[$id] | Where-Object { $owned -contains $_ }).Count -eq 0) { $wrong += ($id + ' needs ' + $source + ' but reads nothing it owns') }
            }
        }
        $wrong | Should -BeNullOrEmpty -Because ($wrong -join '; ')
    }
    It 'the needs name real checks, never the check itself, and the needed check runs first' {
        $order = @($script:CheckReads.Keys)
        foreach ($id in $script:CheckNeeds.Keys) {
            $order | Should -Contain $id
            foreach ($source in @(Get-CheckNeed $id)) {
                $source | Should -Not -Be $id
                $order | Should -Contain $source
                $order.IndexOf($source) | Should -BeLessThan $order.IndexOf($id) -Because ($source + ' must be registered before ' + $id)
            }
        }
    }
    It 'the checks that run their own queries need nothing' {
        foreach ($id in 'baseline', 'licensing', 'patchlevel', 'storage', 'sql', 'dism', 'sfc') { @(Get-CheckNeed $id).Count | Should -Be 0 -Because $id }
    }
}

Describe 'Get-BlockingCheckRun and Get-BlockedCheckMessage (#360, step 3)' {
    BeforeAll {
        function New-Run([string]$Id, [string]$Outcome, [string]$Message = '') { [pscustomobject]@{ Id = $Id; Outcome = $Outcome; Message = $Message } }
    }
    It 'a check whose source stopped with an error is blocked' {
        $b = @(Get-BlockingCheckRun 'upgradepath' @((New-Run 'baseline' 'Failed')))
        $b.Count | Should -Be 1
        $b[0].Id | Should -Be 'baseline'
    }
    It 'a source that ran out of time blocks too' {
        @(Get-BlockingCheckRun 'upgradepath' @((New-Run 'baseline' 'TimedOut'))).Count | Should -Be 1
    }
    It 'a source that completed does not block' {
        @(Get-BlockingCheckRun 'upgradepath' @((New-Run 'baseline' 'Completed'))).Count | Should -Be 0
    }
    It 'a source skipped by design does not block (a SPECIAL short report, a switch)' {
        @(Get-BlockingCheckRun 'printbackup' @((New-Run 'printers' 'Skipped' 'Not applicable: cluster node'))).Count | Should -Be 0
    }
    It 'a source that was itself blocked blocks the checks that need it' {
        $b = @(Get-BlockingCheckRun 'printbackup' @((New-Run 'baseline' 'Failed'), (New-Run 'printers' 'Skipped' 'Needs baseline, which stopped with an error')))
        $b.Count | Should -Be 1
        $b[0].Id | Should -Be 'printers'
    }
    It 'a source that has not run yet does not block (the order is checked by a test)' {
        @(Get-BlockingCheckRun 'upgradepath' @()).Count | Should -Be 0
    }
    It 'a check that needs nothing is never blocked' {
        @(Get-BlockingCheckRun 'licensing' @((New-Run 'baseline' 'Failed'))).Count | Should -Be 0
        @(Get-BlockingCheckRun 'baseline' @((New-Run 'baseline' 'Failed'))).Count | Should -Be 0
    }
    It 'uses the latest run of a source' {
        @(Get-BlockingCheckRun 'upgradepath' @((New-Run 'baseline' 'Failed'), (New-Run 'baseline' 'Completed'))).Count | Should -Be 0
    }
    It 'says why in a sentence for each blocking run' {
        Get-BlockedCheckMessage @((New-Run 'baseline' 'Failed')) | Should -Be 'Needs baseline, which stopped with an error'
        Get-BlockedCheckMessage @((New-Run 'baseline' 'TimedOut')) | Should -Be 'Needs baseline, which ran out of time'
        Get-BlockedCheckMessage @((New-Run 'printers' 'Skipped' 'Needs baseline, which stopped with an error')) | Should -Be 'Needs printers, which was not run'
        Get-BlockedCheckMessage @((New-Run 'a' 'Failed'), (New-Run 'b' 'TimedOut')) | Should -Be 'Needs a, which stopped with an error; Needs b, which ran out of time'
    }
    It 'Get-CheckNeed: one need, none, unknown check' {
        @(Get-CheckNeed 'printbackup') | Should -Be @('printers')
        @(Get-CheckNeed 'licensing').Count | Should -Be 0
        @(Get-CheckNeed 'NoSuchCheck').Count | Should -Be 0
    }
}

Describe 'Invoke-Check does not run a check whose source failed (#360, step 3)' {
    BeforeEach {
        $script:Results.Clear(); $script:CheckRuns.Clear()
        $script:Ran = $false
        $script:Probe = [pscustomobject]@{ Id = 'upgradepath'; Name = 'Upgrade path, edition and media'; Phase = 'Fast'; Script = { $script:Ran = $true; Add-Result 'UPGRADE_PATH' 'Probe' 'OK' 'ran' } }
    }
    It 'runs the check normally when baseline completed' {
        $script:CheckRuns.Add([pscustomobject]@{ Id = 'baseline'; Name = 'Baseline'; Phase = 'Fast'; Outcome = 'Completed'; Message = '' })
        Invoke-Check $script:Probe
        $script:Ran | Should -BeTrue
        $script:CheckRuns[-1].Outcome | Should -Be 'Completed'
    }
    It 'does not run it when baseline stopped with an error: skipped, with a MANUAL result naming baseline' {
        $script:CheckRuns.Add([pscustomobject]@{ Id = 'baseline'; Name = 'Baseline'; Phase = 'Fast'; Outcome = 'Failed'; Message = 'boom' })
        Invoke-Check $script:Probe
        $script:Ran | Should -BeFalse
        $run = $script:CheckRuns[-1]
        $run.Id | Should -Be 'upgradepath'
        $run.Outcome | Should -Be 'Skipped'
        $run.Message | Should -Be 'Needs baseline, which stopped with an error'
        $rows = @($script:Results.ToArray())
        $rows.Count | Should -Be 1
        $rows[0].Status | Should -Be 'MANUAL'
        $rows[0].Kind | Should -Be 'Finding'
        $rows[0].Area | Should -Be 'COLLECTOR'
        $rows[0].Value | Should -Be 'Check not run'
        $rows[0].Recommendation | Should -Match 'NOT assessed'
        $rows[0].Recommendation | Should -Match 'baseline'
    }
    It 'the coverage notice lists it as a problem, not as a choice' {
        $script:CheckRuns.Add([pscustomobject]@{ Id = 'baseline'; Name = 'Baseline'; Phase = 'Fast'; Outcome = 'Failed'; Message = 'boom' })
        Invoke-Check $script:Probe
        $notice = Get-CoverageNotice @($script:CheckRuns.ToArray())
        ($notice.Problems -join '|') | Should -Match 'Upgrade path, edition and media was skipped \(Needs baseline, which stopped with an error\)'
        $notice.ByChoice.Count | Should -Be 0
    }
    It 'leaves the current check id as core, like a check that ran' {
        $script:CheckRuns.Add([pscustomobject]@{ Id = 'baseline'; Name = 'Baseline'; Phase = 'Fast'; Outcome = 'Failed'; Message = 'boom' })
        Invoke-Check $script:Probe
        $script:CurrentCheckId | Should -Be 'core'
    }
    It 'still runs a check that needs nothing' {
        $script:CheckRuns.Add([pscustomobject]@{ Id = 'baseline'; Name = 'Baseline'; Phase = 'Fast'; Outcome = 'Failed'; Message = 'boom' })
        $free = [pscustomobject]@{ Id = 'licensing'; Name = 'Windows activation'; Phase = 'Fast'; Script = { $script:Ran = $true } }
        Invoke-Check $free
        $script:Ran | Should -BeTrue
    }
}
