# ==============================================================================
# Teams needed (#323): which other teams a server needs before its upgrade,
# read from the rows of its result. One table, in one place: a site that has
# other teams, or names them differently, edits $script:TeamRules here and
# rebuilds (docs/build.md). Pure functions and data only.
# ==============================================================================

# Each rule: the Team, and what a row must match. Area and Item are regular
# expressions (case-insensitive); Status lists the statuses that count (empty =
# any status); Value is an optional regular expression on the row's value.
# Several rules may name the same team. Order is the order teams are shown in.
$script:TeamRules = @(
    @{ Team = 'PKI';               Area = '^PKI$';                Item = '^(CertificationAuthority|ADCSRoleServices|PkiSitePolicy)$'; Status = @() }
    @{ Team = 'AD';                Area = '^DOMAIN_CONTROLLER$';  Item = '.';                         Status = @() }
    @{ Team = 'AD';                Area = '^SPECIAL$';            Item = '^Domain controller$';       Status = @() }
    @{ Team = 'Cluster / storage'; Area = '^SPECIAL$';            Item = '^(Failover cluster node|ClusterMembership)$'; Status = @() }
    @{ Team = 'Cluster / storage'; Area = '^CLUSTER$';            Item = '^FailoverClustering$';      Status = @('ACTION', 'WARNING') }
    @{ Team = 'SQL / DBA';         Area = '^SQL$';                Item = '.';                         Status = @() }
    @{ Team = 'Exchange';          Area = '^EXCHANGE$';           Item = '.';                         Status = @('BLOCKER', 'ACTION') }
    @{ Team = 'Backup';            Area = '^BACKUP$';             Item = '^VSSWriters$';              Status = @('ACTION') }
    # A backup product found on the server (not the VSS evidence rows).
    @{ Team = 'Backup';            Area = '^BACKUP$';             Item = '^(?!VSS|GuestBackupAgent$)'; Status = @('INFO') }
    @{ Team = 'Antivirus / EDR';   Area = '^ANTIVIRUS$';          Item = '.';                         Status = @('WARNING') }
    @{ Team = 'Antivirus / EDR';   Area = '^SECURITY$';           Item = '^(?!AppLocker$|SecureBoot$|TPM$|BitLocker|FileSystemFilterDrivers$)'; Status = @('WARNING') }
    @{ Team = 'Network';           Area = '^NETWORK$';            Item = '^LBFO team: ';              Status = @('ACTION') }
    @{ Team = 'Network';           Area = '^NETWORK_DEPENDENCY$'; Item = '^StaticRoutes$';            Status = @('MANUAL'); Value = '^Routes=' }
    @{ Team = 'Virtualization';    Area = '^VMWARE$';             Item = '^VMwareTools$';             Status = @('BLOCKER', 'ACTION', 'WARNING') }
    @{ Team = 'Application owner'; Area = '^IIS$';                Item = '^Web-Server$';              Status = @('WARNING') }
    @{ Team = 'Application owner'; Area = '^RDS$';                Item = '^(RDSessionHost|RDLicensingServer)$'; Status = @('ACTION') }
    @{ Team = 'Application owner'; Area = '^APPLICATIONS$';       Item = '^EOL: ';                    Status = @('WARNING') }
)

function Get-TeamsNeeded {
    # Pure (#323): the teams one server needs, in the order of $Rules, each
    # with the items that called for it. An empty list means no other team.
    param([object[]]$Rows, [object[]]$Rules = $script:TeamRules)
    $byTeam = [ordered]@{}
    foreach ($rule in @($Rules)) { if (-not $byTeam.Contains($rule.Team)) { $byTeam[$rule.Team] = New-Object System.Collections.Generic.List[string] } }
    foreach ($row in @($Rows)) {
        if (-not $row) { continue }
        $area = [string]$row.Area; $item = [string]$row.Item; $status = [string]$row.Status
        foreach ($rule in @($Rules)) {
            if ($area -notmatch $rule.Area -or $item -notmatch $rule.Item) { continue }
            if (@($rule.Status).Count -gt 0 -and @($rule.Status) -notcontains $status) { continue }
            if ($rule.Contains('Value') -and $rule['Value'] -and ([string]$row.Value) -notmatch $rule['Value']) { continue }
            if (-not $byTeam[$rule.Team].Contains($item)) { $byTeam[$rule.Team].Add($item) }
        }
    }
    $out = @()
    foreach ($team in @($byTeam.Keys)) {
        if ($byTeam[$team].Count -gt 0) { $out += [pscustomobject]@{ Team = $team; Items = $byTeam[$team].ToArray() } }
    }
    return $out
}

function Get-TeamsSummary {
    # Pure (#323): one row per team with the servers that need it, in the
    # order of $Rules. $Servers: objects with ComputerName and Teams (the
    # output of Get-TeamsNeeded).
    param([object[]]$Servers, [object[]]$Rules = $script:TeamRules)
    $order = @(); foreach ($rule in @($Rules)) { if ($order -notcontains $rule.Team) { $order += $rule.Team } }
    $rows = @()
    foreach ($team in $order) {
        $names = @(); $items = @()
        foreach ($s in @($Servers)) {
            foreach ($t in @($s.Teams)) {
                if (-not $t -or $t.Team -ne $team) { continue }
                if ($names -notcontains $s.ComputerName) { $names += $s.ComputerName }
                foreach ($i in @($t.Items)) { if ($items -notcontains $i) { $items += $i } }
            }
        }
        if ($names.Count -gt 0) { $rows += [pscustomobject]@{ Team = $team; ServerCount = $names.Count; Servers = (@($names | Sort-Object) -join ', '); Why = ($items -join ' | ') } }
    }
    return $rows
}
