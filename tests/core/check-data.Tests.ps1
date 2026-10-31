# Pester 5 tests for the check data owners (#360): src/assessment/35-check-data.ps1.
# The check bodies in src/assessment/50-checks.ps1 are READ (parsed), not run:
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
    # the body of the rdp check, kept as a function of its own.
    $script:FileAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Parts '50-checks.ps1'), [ref]$null, [ref]$null)
    $script:Writes = @{}
    $registers = $script:FileAst.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Register-Check' }, $true)
    foreach ($r in $registers) {
        $elements = @($r.CommandElements)
        $id = $null; $body = $null
        for ($i = 0; $i -lt $elements.Count; $i++) {
            if ($elements[$i] -is [Management.Automation.Language.CommandParameterAst] -and $elements[$i].ParameterName -eq 'Id') { $id = [string]$elements[$i + 1].Value }
            if ($elements[$i] -is [Management.Automation.Language.ScriptBlockExpressionAst]) { $body = $elements[$i] }
        }
        $script:Writes[$id] = Get-DataWrite $body
    }
    $script:CheckIds = @($script:Writes.Keys)
    $script:FunctionOwner = @{ 'Invoke-RdpPolicyAssessment' = 'rdp' }
    $script:OtherFunctions = @($script:FileAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) | Where-Object { $_.Name -ne 'Register-AssessmentCheck' })
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
    It 'every function in 50-checks.ps1 other than the registry is attributed to a check' {
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
            if ($list -in @('Gpos', 'Groups', 'Shares', 'Uac', 'Ou', 'Nla', 'PortOwners')) { continue }
            $script:Writes['baseline'].Seeds | Should -Contain $list -Because ('baseline seeds Snapshot.' + $list + ' empty so a failed check leaves the list empty, which CheckRuns then flags')
        }
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
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Parts '50-checks.ps1'), [ref]$null, [ref]$null)
        $members = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.MemberExpressionAst] -and $n -isnot [Management.Automation.Language.InvokeMemberExpressionAst] }, $true) | Where-Object { $null -ne (Get-DataPath $_) })
        $members.Count | Should -BeGreaterThan 100
    }
}
