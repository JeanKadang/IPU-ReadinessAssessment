function Find-EolSnapshotFile {
    # Pure (#275): -EolSnapshot if given, else the first eol-snapshot.json in
    # the folders (this script's folder, then the input folder). '' when none.
    param([string]$Explicit, [string[]]$Folders)
    if ($Explicit) { return $Explicit }
    foreach ($folder in @($Folders)) {
        if (-not $folder) { continue }
        $candidate = [IO.Path]::Combine($folder, 'eol-snapshot.json')
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return ''
}

function Get-EolFleetRow {
    # Pure (#275): the products found on the servers -> one row per product and
    # version with its verdict and the servers it is on. Servers = objects with
    # ComputerName and Candidates (the EolCandidates of the result). Without a
    # snapshot every row is MANUAL ("not checked"), never supported.
    param([object[]]$Servers, $Snapshot, [datetime]$Today)
    $groups = @{}
    foreach ($s in @($Servers)) {
        foreach ($c in @($s.Candidates)) {
            if (-not $c) { continue }
            $key = [string]$c.Product + '|' + [string]$c.Version
            if (-not $groups.ContainsKey($key)) { $groups[$key] = [pscustomobject]@{ Candidate = $c; Names = New-Object System.Collections.Generic.List[string] } }
            if (-not $groups[$key].Names.Contains([string]$s.ComputerName)) { $groups[$key].Names.Add([string]$s.ComputerName) }
        }
    }
    $rank = @{ WARNING = 0; MANUAL = 1; INFO = 2; OK = 3 }
    $rows = @()
    foreach ($g in $groups.Values) {
        if ($Snapshot) { $v = Get-EolCandidateVerdict $g.Candidate $Snapshot $Today }
        else {
            $name = [string]$g.Candidate.Product
            if ($script:EolProducts.Contains($name)) { $name = [string]$script:EolProducts[$name] }
            $v = [pscustomobject]@{ Product = [string]$g.Candidate.Product; Name = $name; Version = [string]$g.Candidate.Version; Cycle = ''; State = 'Unknown'; Status = 'MANUAL'; EolDate = ''; DaysLeft = $null; Text = 'Not checked: no end-of-life snapshot was found.' }
        }
        $names = @($g.Names | Sort-Object)
        $rows += [pscustomobject][ordered]@{
            Status = $v.Status; Product = $v.Name; Version = [string]$g.Candidate.Version; Release = $v.Cycle; State = $v.State
            EndOfLife = $v.EolDate; DaysLeft = $v.DaysLeft; ServerCount = $names.Count; Servers = ($names -join ', '); Text = $v.Text
        }
    }
    return @($rows | Sort-Object @{ Expression = { $rank[[string]$_.Status] } }, Product, Version)
}

function Get-EolServerFinding {
    # Pure (#275): findings for one server from the merge step's snapshot, for
    # products the server's own report did not already judge (the assessment
    # adds "EOL: ..." rows itself when it finds a snapshot). Only past end of
    # life and what could not be confirmed count as findings.
    param([object[]]$Candidates, [string[]]$ExistingItems, $Snapshot, [datetime]$Today)
    $out = @()
    if (-not $Snapshot) { return $out }
    foreach ($c in @($Candidates)) {
        if (-not $c) { continue }
        $v = Get-EolCandidateVerdict $c $Snapshot $Today
        if ((Get-EolResultKind $v) -ne 'Finding') { continue }
        $item = 'EOL: ' + $v.Name + ' ' + [string]$c.Version
        if (@($ExistingItems) -contains $item) { continue }
        $out += [pscustomobject]@{ Status = $v.Status; Area = 'APPLICATIONS'; Item = $item; Value = $v.Text; Details = ([string]$c.Source + ': ' + [string]$c.Evidence); Recommendation = (Get-EolRecommendation $v) }
    }
    return $out
}

function Get-EolServerSummary {
    # Pure (#275): the products of one server that are past end of life, for the
    # server list ("PHP 7.4.33 | Redis 6.0.1"). '' when none or no snapshot.
    param([object[]]$Candidates, $Snapshot, [datetime]$Today)
    if (-not $Snapshot) { return '' }
    $names = @()
    foreach ($c in @($Candidates)) {
        if (-not $c) { continue }
        $v = Get-EolCandidateVerdict $c $Snapshot $Today
        if ($v.State -eq 'EndOfLife') { $names += ($v.Name + ' ' + [string]$c.Version) }
    }
    return ($names -join ' | ')
}
