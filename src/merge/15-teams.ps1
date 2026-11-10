# ==============================================================================
# Teams needed (#323, #374): which OTHER teams a server needs before its upgrade,
# read from the rows of its result. Work the Windows Team does itself (VMware
# Tools, RDS, IIS, NIC teaming without switch changes, a plain backup client,
# the monitoring agent) is not listed. One table, in one place: a site that has
# other teams, or names them differently, edits $script:TeamRules here and
# rebuilds (docs/build.md). Pure functions and data only.
# ==============================================================================

# Each rule: the Team, and what a row must match. Area and Item are regular
# expressions (case-insensitive); Status lists the statuses that count (empty =
# any status); Value and Details are optional regular expressions on the row's
# value and on its details (joined with " | "). Detail is an optional word
# shown after the team name, for example the database type: "DBA Team (SQL
# Server/Oracle)". Several rules may name the same team. Order is the order
# teams are shown in.
$script:TeamRules = @(
    @{ Team = 'PKI Team';          Area = '^PKI$';                Item = '^(CertificationAuthority|ADCSRoleServices|PkiSitePolicy)$'; Status = @() }
    @{ Team = 'AD Projects';       Area = '^DOMAIN_CONTROLLER$';  Item = '.';                         Status = @() }
    @{ Team = 'AD Projects';       Area = '^SPECIAL$';            Item = '^Domain controller$';       Status = @() }
    # The base cluster; what runs on it (SQL, file server) adds its own team.
    @{ Team = 'Windows Projects';  Area = '^SPECIAL$';            Item = '^(Failover cluster node|ClusterMembership)$'; Status = @() }
    @{ Team = 'DBA Team';          Area = '^SQL$';                Item = '.';                         Status = @(); Detail = 'SQL Server' }
    # Oracle: the database, not a client-only install.
    @{ Team = 'DBA Team';          Area = '^WORKLOAD$';           Item = '^Oracle Database$';         Status = @(); Details = 'OracleService|OracleOraDB|Oracle Database'; Detail = 'Oracle' }
    @{ Team = 'DBA Team';          Area = '^WORKLOAD$';           Item = '^MySQL$';                   Status = @(); Detail = 'MySQL' }
    @{ Team = 'DBA Team';          Area = '^WORKLOAD$';           Item = '^PostgreSQL$';              Status = @(); Detail = 'PostgreSQL' }
    @{ Team = 'DBA Team';          Area = '^WORKLOAD$';           Item = '^IBM Db2$';                 Status = @(); Detail = 'Db2' }
    @{ Team = 'Exchange';          Area = '^EXCHANGE$';           Item = '.';                         Status = @('BLOCKER', 'ACTION') }
    # Only backup infrastructure (server, proxy, storage agent, media agent);
    # a plain backup client is the Windows Team's.
    @{ Team = 'Team Backup';       Area = '^BACKUP$';             Item = '^(?!VSS|GuestBackupAgent$)'; Status = @('INFO'); Details = 'Veeam Backup (&|and) Replication|Veeam Backup Proxy|Veeam Backup Transport|VeeamTransportSvc|VeeamProxySvc|VeeamBackupSvc|Spectrum Protect Server|Storage Protect Server|Tivoli Storage Manager Server|Storage Agent|dsmsta|MediaAgent|GxMMM|CommServe' }
    # The agent is deployed by the Windows Team; the backend and policy are the Security Team's.
    @{ Team = 'Security Team (AV)'; Area = '^ANTIVIRUS$';         Item = '.';                         Status = @('WARNING') }
    @{ Team = 'Security Team (AV)'; Area = '^SECURITY$';          Item = '^(?!AppLocker$|SecureBoot$|TPM$|BitLocker|FileSystemFilterDrivers$)'; Status = @('WARNING') }
    # A switch-dependent team (LACP or Static) needs the switch ports changed before and after.
    @{ Team = 'Network Team';      Area = '^NETWORK$';            Item = '^LBFO team: ';              Status = @('ACTION'); Details = 'Mode=(Lacp|Static)\b' }
    # VDI hosts (#376): the VDI / Endpoint Team owns them; no IPU.
    @{ Team = 'VDI / Endpoint Team'; Area = '^WORKLOAD$';         Item = '^VDI: ';                    Status = @() }
    @{ Team = 'Application owner'; Area = '^APPLICATIONS$';       Item = '^EOL: ';                    Status = @('WARNING') }
)

function Get-TeamsNeeded {
    # Pure (#323, #374): the teams one server needs, in the order of $Rules,
    # each with the items that called for it and any details (database type).
    # Label is what the server list shows: "DBA Team (SQL Server)". An empty
    # list means no other team.
    param([object[]]$Rows, [object[]]$Rules = $script:TeamRules)
    $items = [ordered]@{}; $details = @{}
    foreach ($rule in @($Rules)) {
        if (-not $items.Contains($rule.Team)) { $items[$rule.Team] = New-Object System.Collections.Generic.List[string]; $details[$rule.Team] = New-Object System.Collections.Generic.List[string] }
    }
    foreach ($row in @($Rows)) {
        if (-not $row) { continue }
        $area = [string]$row.Area; $item = [string]$row.Item; $status = [string]$row.Status
        $rowDetails = ''; if ($row.PSObject.Properties['Details']) { $rowDetails = (@($row.Details) | ForEach-Object { [string]$_ }) -join ' | ' }
        $rowValue = ''; if ($row.PSObject.Properties['Value']) { $rowValue = [string]$row.Value }
        foreach ($rule in @($Rules)) {
            if ($area -notmatch $rule.Area -or $item -notmatch $rule.Item) { continue }
            if (@($rule.Status).Count -gt 0 -and @($rule.Status) -notcontains $status) { continue }
            if ($rule.Contains('Value') -and $rule['Value'] -and $rowValue -notmatch $rule['Value']) { continue }
            if ($rule.Contains('Details') -and $rule['Details'] -and $rowDetails -notmatch $rule['Details']) { continue }
            if (-not $items[$rule.Team].Contains($item)) { $items[$rule.Team].Add($item) }
            if ($rule.Contains('Detail') -and $rule['Detail'] -and -not $details[$rule.Team].Contains($rule['Detail'])) { $details[$rule.Team].Add($rule['Detail']) }
        }
    }
    $out = @()
    foreach ($team in @($items.Keys)) {
        if ($items[$team].Count -eq 0) { continue }
        $label = $team; if ($details[$team].Count -gt 0) { $label = $team + ' (' + ($details[$team].ToArray() -join '/') + ')' }
        $out += [pscustomobject]@{ Team = $team; Label = $label; Details = $details[$team].ToArray(); Items = $items[$team].ToArray() }
    }
    return $out
}

function Get-TeamsSummary {
    # Pure (#323, #374): one row per team with the servers that need it, in the
    # order of $Rules. $Servers: objects with ComputerName and Teams (the
    # output of Get-TeamsNeeded). Why lists the details first, then the items.
    param([object[]]$Servers, [object[]]$Rules = $script:TeamRules)
    $order = @(); foreach ($rule in @($Rules)) { if ($order -notcontains $rule.Team) { $order += $rule.Team } }
    $rows = @()
    foreach ($team in $order) {
        $names = @(); $items = @(); $kinds = @()
        foreach ($s in @($Servers)) {
            foreach ($t in @($s.Teams)) {
                if (-not $t -or $t.Team -ne $team) { continue }
                if ($names -notcontains $s.ComputerName) { $names += $s.ComputerName }
                foreach ($d in @($t.Details)) { if ($d -and $kinds -notcontains $d) { $kinds += $d } }
                foreach ($i in @($t.Items)) { if ($items -notcontains $i) { $items += $i } }
            }
        }
        if ($names.Count -gt 0) {
            $label = $team; if ($kinds.Count -gt 0) { $label = $team + ' (' + ($kinds -join '/') + ')' }
            $rows += [pscustomobject]@{ Team = $label; ServerCount = $names.Count; Servers = (@($names | Sort-Object) -join ', '); Why = ($items -join ' | ') }
        }
    }
    return $rows
}
