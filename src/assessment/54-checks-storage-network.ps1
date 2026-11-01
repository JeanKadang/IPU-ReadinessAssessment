# Chapter: Storage, clustering and network (docs/checks.md).
# Each check is one function; Register-AssessmentCheck (50-checks.ps1) lists them in run order.

function Invoke-ClusterCheck {
    $clusSvcPresent = @($script:Data.Services | Where-Object { $_.Name -eq 'ClusSvc' -and $_.StartMode -ne 'Disabled' }).Count -gt 0
    $feature = Resolve-ClusterFeatureState (Get-FeatureState 'Failover-Clustering') $clusSvcPresent ([bool](Test-Path 'HKLM:\Cluster'))
    if ($null -eq $feature) { Add-Result 'CLUSTER' 'FailoverClustering' 'MANUAL' 'Feature state unknown: the role inventory failed' -Recommendation 'Confirm by hand whether this server is a cluster node (Get-Cluster, the Cluster service) before planning an IPU.' -Source 'Get-WindowsFeature'; return }
    if ($feature -ne $true) { Add-Result 'CLUSTER' 'FailoverClustering' 'OK' 'Feature not installed' -Source 'Get-WindowsFeature'; return }
    if (-not (Test-CommandAvailable 'Get-Cluster')) {
        Add-Result 'CLUSTER' 'FailoverClustering' 'ACTION' 'Feature installed; cluster cmdlets unavailable' -Recommendation 'Confirm cluster membership before planning an IPU.' -Source 'Get-WindowsFeature'
        return
    }
    $cluster = $null
    try { $cluster = Get-Cluster -ErrorAction Stop } catch { Write-Swallowed $_ }
    if (-not $cluster) {
        Add-Result 'CLUSTER' 'FailoverClustering' 'WARNING' 'Feature installed but no cluster membership found' -Recommendation 'Remove the feature if unused, or confirm the node is not part of a cluster.' -Source 'Get-Cluster'
        return
    }
    # Reported as SPECIAL with its own plan (#152); names are site data.
    Add-RedactionLiteral ([string]$cluster.Name) 'HOST'
    Add-Result 'CLUSTER' 'ClusterMembership' 'INFO' ('Cluster=' + $cluster.Name) -Recommendation 'Cluster node: not a standard in-place upgrade - see the SPECIAL section.' -Source 'Get-Cluster'
    # The details are optional, but one that cannot be read is named, never
    # left out silently (#306).
    $unread = @()
    try { foreach ($n in @(Get-ClusterNode -ErrorAction Stop)) { Add-RedactionLiteral ([string]$n.Name) 'HOST'; Add-Result 'CLUSTER' ('Node: ' + $n.Name) 'INFO' ('State=' + $n.State) -Source 'Get-ClusterNode' } } catch { $unread += ('nodes: ' + $_.Exception.Message) }
    try { foreach ($g in @(Get-ClusterGroup -ErrorAction Stop | Sort-Object Name)) { Add-Result 'CLUSTER' ('Group: ' + $g.Name) 'INFO' ('State=' + $g.State) ('Owner=' + $g.OwnerNode) -Source 'Get-ClusterGroup' } } catch { $unread += ('roles: ' + $_.Exception.Message) }
    try { $q = Get-ClusterQuorum -ErrorAction Stop; if ($q) { Add-Result 'CLUSTER' 'Quorum' 'INFO' ('Type=' + $q.QuorumType) ('Resource=' + $q.QuorumResource) -Source 'Get-ClusterQuorum' } } catch { $unread += ('quorum: ' + $_.Exception.Message) }
    try { foreach ($csv in @(Get-ClusterSharedVolume -ErrorAction Stop)) { Add-Result 'CLUSTER' ('CSV: ' + $csv.Name) 'INFO' ('State=' + $csv.State) ('Owner=' + $csv.OwnerNode) -Source 'Get-ClusterSharedVolume' } } catch { $unread += ('shared volumes: ' + $_.Exception.Message) }
    try { foreach ($r in @(Get-ClusterResource -ErrorAction Stop | Where-Object { [string]$_.ResourceType -eq 'Physical Disk' })) { Add-Result 'CLUSTER' ('Disk: ' + $r.Name) 'INFO' ('State=' + $r.State) ('Group=' + $r.OwnerGroup) -Source 'Get-ClusterResource' } } catch { $unread += ('disks: ' + $_.Exception.Message) }
    if ($unread.Count -gt 0) {
        Add-Result 'CLUSTER' 'ClusterDetails' 'MANUAL' ('Not readable: ' + $unread.Count + ' of 5 detail lists') $unread -Recommendation 'Read the nodes, roles, quorum and storage in Failover Cluster Manager before planning; the SPECIAL plan depends on them.' -Source 'Failover Clustering cmdlets'
    }
}

function Invoke-SpecialCheck {
    # #152: a cluster node or a domain controller is not a standard IPU. The
    # main flow has decided the kind after the baseline; this check writes
    # the SPECIAL row and what the report tells the project and the customer.
    $kind = [string]$script:Data.SpecialKind
    if (-not $kind) { return }
    if ($kind -eq 'Undecided') {
        Add-Result 'SPECIAL' 'ClusterMembership' 'MANUAL' 'Cluster membership could not be decided' 'The Failover Clustering feature is installed, but the cluster service and the cluster registry key disagree.' -Recommendation 'Check in Failover Cluster Manager whether this server is a cluster node. A cluster node is not a standard in-place upgrade.' -Source 'Get-WindowsFeature, Win32_Service, HKLM:\Cluster'
        return
    }
    $content = Get-SpecialServerContent $kind ([string]$script:Data.SourceRelease) $TargetServerVersion
    $facts = Get-SpecialServerFact $kind
    $content | Add-Member -NotePropertyName Facts -NotePropertyValue @($facts) -Force
    $script:Data.Special = $content
    $first = @($content.Options | Where-Object { $_.Url }) | Select-Object -First 1
    Add-Result 'SPECIAL' $content.Title 'SPECIAL' 'Not a standard in-place upgrade: expensive and risky' @($facts) -Recommendation 'Separate plan needed. Tell the project and the customer. See the SPECIAL section for the risks and the options.' -Source 'Domain role, cluster' -Link $first.Url -LinkTitle $first.Title
}

function Invoke-StorageCheck {
    $c = @(Get-CimRequired 'Win32_LogicalDisk' "DeviceID='C:'") | Select-Object -First 1
    $sizeGB = [math]::Round(([double]$c.Size / 1GB),2)
    $freeGB = [math]::Round(([double]$c.FreeSpace / 1GB),2)
    $script:Data.CSummary = 'Size ' + (Format-Number $sizeGB) + ' GB, free ' + (Format-Number $freeGB) + ' GB'
    if ($freeGB -lt $MinimumCFreeGB) {
        $needed = [math]::Ceiling(($MinimumCFreeGB - $freeGB) / $ExtendBlockGB) * $ExtendBlockGB
        Add-Result 'STORAGE' 'CFreeSpace' 'ACTION' $script:Data.CSummary ('RequiredExpansionGB=' + $needed) -Recommendation ('Extend C: by at least ' + $needed + ' GB to reach the ' + $MinimumCFreeGB + ' GB free-space target.') -Source 'Win32_LogicalDisk' -Command (Get-RecommendationCommand 'CFreeSpace').Command -CommandKind 'Check'
    } else {
        Add-Result 'STORAGE' 'CFreeSpace' 'OK' $script:Data.CSummary -Source 'Win32_LogicalDisk'
    }

    if (-not (Test-CommandAvailable 'Get-Disk')) {
        foreach ($d in @(Get-CimSafe 'Win32_DiskDrive' | Sort-Object Index)) { Add-Result 'STORAGE' ('Disk' + $d.Index) 'INFO' ('SizeGB=' + (Format-Number ($d.Size/1GB))) ('Model=' + $d.Model) -Source 'Win32_DiskDrive' }
        return
    }
    $cp = Get-Partition -DriveLetter C
    $after = @(Get-Partition -DiskNumber $cp.DiskNumber | Where-Object { $_.Offset -gt $cp.Offset } | Sort-Object Offset)
    if ($after.Count -gt 0) {
        $desc = @($after | ForEach-Object { 'P' + $_.PartitionNumber + ':' + [math]::Round($_.Size/1MB) + 'MB:' + $_.Type })
        Add-Result 'STORAGE' 'PartitionAfterC' 'WARNING' 'Yes' $desc -Recommendation 'A partition after C: (often WinRE) blocks simple extension of C:. Plan the layout change before the window if C: needs to grow.' -Source 'Get-Partition'
    } else {
        Add-Result 'STORAGE' 'PartitionAfterC' 'OK' 'No' -Source 'Get-Partition'
    }
    # Recovery partition layout (#161): reagentc /info is read-only.
    $winRe = $null
    $ra = Invoke-NativeCapture (Join-Path $env:windir 'System32\reagentc.exe') @('/info') 60
    if ($ra.TimedOut -or $ra.Error -or ($null -ne $ra.ExitCode -and [int]$ra.ExitCode -ne 0)) {
        Add-Result 'STORAGE' 'WinREStatus' 'MANUAL' 'reagentc /info failed' ([string]$ra.Error + ' ExitCode=' + $ra.ExitCode) -Recommendation 'Run "reagentc /info" as administrator to see where WinRE is before changing partitions.' -Kind 'Finding' -Source 'reagentc /info'
    } else {
        $winRe = ConvertFrom-ReagentcInfo $ra.Output (Read-ReAgentXml)
        if ($null -eq $winRe.Partition -and $null -eq $winRe.Enabled) {
            Add-Result 'STORAGE' 'WinREStatus' 'MANUAL' 'The Windows RE status could not be read' -Recommendation 'Run "reagentc /info" as administrator to see where WinRE is before changing partitions.' -Kind 'Finding' -Source 'reagentc /info, ReAgent.xml'
        } else {
            $where = 'Location not reported'; if ($null -ne $winRe.Partition) { $where = 'Disk' + $winRe.Disk + ' P' + $winRe.Partition }
            $state = 'Unknown'; if ($winRe.Enabled -eq $true) { $state = 'Enabled' } elseif ($winRe.Enabled -eq $false) { $state = 'Disabled' }
            Add-Result 'STORAGE' 'WinREStatus' 'INFO' ($state + ', ' + $where) -Source 'reagentc /info'
        }
    }
    # The first Get-Partition of this check (without SilentlyContinue) already stops the check when the layout cannot be read; it is then reported as not completed.
    $layout = @(Get-Partition -DiskNumber $cp.DiskNumber -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{ PartitionNumber = $_.PartitionNumber; Offset = [double]$_.Offset; SizeMB = [double]$_.Size / 1MB; IsRecovery = (([string]$_.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}') -or ([string]$_.Type -eq 'Recovery') -or ([int]$_.MbrType -eq 39)) }
    })
    $wrePart = $null; if ($winRe -and $winRe.Disk -eq $cp.DiskNumber) { $wrePart = $winRe.Partition }
    $rd = Get-RecoveryPartitionDecision $layout ([int]$cp.PartitionNumber) $wrePart $AssessmentMode
    if ($rd.Kind -eq 'AfterC') {
        Add-Result 'STORAGE' 'RecoveryPartitionAfterC' $rd.Status $rd.Value -Recommendation $rd.Text -Source 'Get-Partition, reagentc /info' -Command (Get-RecommendationCommand 'RemoveRecoveryPartition' @{ Disk = $cp.DiskNumber; Partition = $rd.PartitionNumber }).Command -CommandKind 'Change' -Link $script:DocLinks.WinReResize.Url -LinkTitle $script:DocLinks.WinReResize.Title
    } elseif ($rd.Kind -eq 'LikelyNew') {
        Add-Result 'STORAGE' 'RecoveryPartitionAfterC' $rd.Status $rd.Value -Recommendation $rd.Text -Source 'Get-Partition' -Command (Get-RecommendationCommand 'SetupNoRecoveryPartition').Command -CommandKind 'Change' -Link $script:DocLinks.SetupOptions.Url -LinkTitle $script:DocLinks.SetupOptions.Title
    } else {
        Add-Result 'STORAGE' 'RecoveryPartitionAfterC' 'OK' $rd.Value -Source 'Get-Partition'
    }
    try {
        # Worked out from the partition layout: Get-PartitionSupportedSize
        # computes the shrink size too and can take minutes on a large volume (#241).
        $diskSize = [double](Get-Disk -Number $cp.DiskNumber -ErrorAction Stop).Size
        $spaceAfterC = Get-SpaceAfterPartition ([double]$cp.Offset) ([double]$cp.Size) @($layout | ForEach-Object { $_.Offset }) $diskSize
        Add-Result 'STORAGE' 'CExtendableNowGB' 'INFO' (Format-Number ($spaceAfterC / 1GB)) 'Currently available contiguous space only.' -Source 'Get-Partition, Get-Disk'
    } catch { Write-Swallowed $_ }

    $total = 0
    $recoveryGuid = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
    foreach ($d in @(Get-Disk | Sort-Object Number)) {
        $total += [double]$d.Size
        $parts = @()
        # SilentlyContinue: a disk without partitions (raw, offline) is normal; the disk row below still lists it.
        foreach ($p in @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Sort-Object Offset)) {
            $vol = $null; $volError = ''
            try { $vol = $p | Get-Volume -ErrorAction Stop } catch { $volError = $_.Exception.Message; Write-Swallowed $_ }
            $t = 'P' + $p.PartitionNumber + ':' + $p.Type + ':' + [math]::Round($p.Size/1MB) + 'MB'
            if ($p.DriveLetter) { $t += ':' + $p.DriveLetter + ':' }
            $paths = @($p.AccessPaths | Where-Object { $_ -and $_ -notmatch '^\\\\\?\\Volume' -and $_ -notmatch '^[A-Z]:\\$' })
            if ($paths.Count -gt 0) { $t += ':MountedAt=' + ($paths -join ',') }
            if ($vol -and $vol.FileSystemLabel) { $t += ':Label=' + $vol.FileSystemLabel }
            if ($vol -and $vol.FileSystem) { $t += ':' + $vol.FileSystem }
            $parts += $t

            # System partition (EFI or System Reserved) and WinRE recovery
            # partition free space - Setup writes boot files and WinRE to them.
            $isRecovery = ([string]$p.GptType -eq $recoveryGuid) -or ([string]$p.Type -eq 'Recovery') -or ([int]$p.MbrType -eq 39)
            if (($p.IsSystem -or $isRecovery) -and -not $vol) {
                # Free space is what Setup needs here; a partition whose volume cannot be read is not "fine" (#242).
                $unreadName = 'SystemPartition'
                if ($isRecovery) { $unreadName = 'RecoveryPartition' }
                Add-Result 'STORAGE' $unreadName 'MANUAL' ('Disk' + $d.Number + ' P' + $p.PartitionNumber + ': free space not readable') $volError -Recommendation 'Check the free space of this partition by hand (diskpart, or mountvol) before the change; Setup writes boot files and WinRE to it.' -Kind 'Finding' -Source 'Get-Partition, Get-Volume'
            }
            if (($p.IsSystem -or $isRecovery) -and $vol -and $vol.Size -gt 0) {
                $freeMB = [math]::Round($vol.SizeRemaining/1MB)
                $kindName = 'SystemPartition'; $limit = $SystemPartitionMinFreeMB
                $rec = 'Free space on the system (EFI/System Reserved) partition is below the project threshold of ' + $SystemPartitionMinFreeMB + ' MB. Setup writes boot files here; a full system partition is a known cause of upgrade failure. Free space or enlarge it before IPU.'
                if ($isRecovery) { $kindName = 'RecoveryPartition'; $limit = $RecoveryPartitionMinFreeMB; $rec = 'Less than ' + $RecoveryPartitionMinFreeMB + ' MB free on the WinRE recovery partition, the space Microsoft asks for when servicing WinRE. Not an IPU blocker by itself, but WinRE updates may fail.' }
                $value = 'Disk' + $d.Number + ' P' + $p.PartitionNumber + ': ' + [math]::Round($vol.Size/1MB) + ' MB, free ' + $freeMB + ' MB'
                if ($freeMB -lt $limit) {
                    if ($isRecovery) { Add-Result 'STORAGE' $kindName 'WARNING' $value '' -Recommendation $rec -Kind 'Observation' -Source 'Get-Partition, Get-Volume' }
                    else { Add-Result 'STORAGE' $kindName 'WARNING' $value '' -Recommendation $rec -Source 'Get-Partition, Get-Volume' }
                } else {
                    Add-Result 'STORAGE' $kindName 'OK' $value -Source 'Get-Partition, Get-Volume'
                }
            }
        }
        Add-Result 'STORAGE' ('Disk' + $d.Number) 'INFO' ('SizeGB=' + (Format-Number ($d.Size/1GB))) @(('BusType=' + $d.BusType),('Style=' + $d.PartitionStyle),('Offline=' + $d.IsOffline),($parts -join ' | ')) -Source 'Get-Disk, Get-Partition, Get-Volume'
    }
    Add-Result 'STORAGE' 'AllocatedDiskCapacity' 'INFO' ('TotalGB=' + (Format-Number ($total/1GB))) 'Rough indication of VM snapshot exposure; growth depends on changed blocks.' -Source 'Get-Disk'
}

function Invoke-NetworkCheck {
    # VLAN IDs come from the NetAdapter module (optional, #94), by MAC (#149).
    $vlanByMac = @{}
    if (Test-CommandAvailable 'Get-NetAdapter') {
        try {
            foreach ($na in @(Get-NetAdapter -ErrorAction Stop)) {
                if ($na -and $na.MacAddress) { $vlanByMac[(ConvertTo-MacKey ([string]$na.MacAddress))] = $na.VlanID }
            }
        } catch { Write-Swallowed $_ }
    }
    foreach ($n in @(Get-CimRequired 'Win32_NetworkAdapterConfiguration' 'IPEnabled=True')) {
        $a = @(Get-CimSafe 'Win32_NetworkAdapter' ('Index=' + $n.Index)) | Select-Object -First 1
        $name = [string]$a.NetConnectionID; if (-not $name) { $name = [string]$n.Description }
        $rec = ConvertTo-NetworkAdapterRecord $n $name $vlanByMac[(ConvertTo-MacKey ([string]$n.MACAddress))]
        $script:Data.Snapshot.IPv4 += $rec.IPv4
        $script:Data.Snapshot.Dns += $rec.Dns
        $script:Data.Snapshot.Adapters += $rec
        Add-Result 'NETWORK' $name 'INFO' ('IPv4=' + ($rec.IPv4 -join ',') + ' / ' + ($rec.Mask -join ',')) (Get-NetworkAdapterDetail $rec) -Source 'Win32_NetworkAdapterConfiguration'
    }

    # A local copy of the full network configuration (#149), for the network
    # team if the upgrade resets an adapter. Read-only commands.
    if ($EnableNetworkEvidence) {
        try {
            $dest = Join-Path (Initialize-EvidenceFolder 'Network') ($script:SafeComputerName + '-IPU-Network-' + (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture))
            $copy = Save-NetworkEvidence -Destination $dest -Zip $CreatePolicyEvidenceZip
            $script:Data.NetworkEvidence = $copy.Location
            $keep = 'Copy it off the server before the change: it holds the full IP configuration, is not redacted and must not be shared outside the team. netsh-interface-dump.txt is a netsh script that can put the configuration back (read it first; see the user guide).'
            if (@($copy.Failed).Count -gt 0) {
                Add-Result 'NETWORK' 'NetworkEvidence' 'MANUAL' $copy.Location (@(('Saved=' + ($copy.Files -join ', '))) + @($copy.Failed | ForEach-Object { 'Failed: ' + $_ })) -Recommendation ('Run the failed commands by hand and keep their output with the file. ' + $keep) -Kind 'Finding' -Source 'ipconfig, route, netsh (read-only)'
            } else {
                Add-Result 'NETWORK' 'NetworkEvidence' 'OK' $copy.Location ('Files=' + ($copy.Files -join ', ')) -Recommendation $keep -Source 'ipconfig, route, netsh (read-only)'
            }
        } catch {
            Add-Result 'NETWORK' 'NetworkEvidence' 'MANUAL' 'Could not save the network configuration' $_.Exception.Message -Recommendation 'Before the change, save the output of "ipconfig /all", "route print" and "netsh -c interface dump" by hand and keep it off the server.' -Kind 'Finding' -Source 'ipconfig, route, netsh'
        }
    } else {
        Add-Result 'NETWORK' 'NetworkEvidence' 'INFO' 'Not taken (EnableNetworkEvidence is off)' -Source 'SETTINGS'
    }

    # NIC teaming. Microsoft: disable LBFO teaming before IPU and re-enable
    # after. An LBFO team bound to a Hyper-V vSwitch is not supported on
    # Windows Server 2022/2025 Hyper-V - convert to Switch Embedded Teaming.
    $vSwitchDescriptions = @()
    if (Test-CommandAvailable 'Get-VMSwitch') {
        try { $vSwitchDescriptions = @(Get-VMSwitch -ErrorAction Stop | Where-Object { $_.NetAdapterInterfaceDescription } | ForEach-Object { [string]$_.NetAdapterInterfaceDescription }) } catch { Write-Swallowed $_ }
        try {
            foreach ($set in @(Get-VMSwitchTeam -ErrorAction Stop)) {
                Add-Result 'NETWORK' ('SET: ' + $set.Name) 'INFO' 'Switch Embedded Teaming' ('Members=' + (@($set.NetAdapterInterfaceDescription) -join ', ')) -Source 'Get-VMSwitchTeam'
            }
        } catch { Write-Swallowed $_ }
    }
    $teams = @(); $lbfoError = ''
    if (Test-CommandAvailable 'Get-NetLbfoTeam') {
        try { $teams = @(Get-NetLbfoTeam -ErrorAction Stop) }
        catch { if (-not (Test-NotFoundError $_)) { $lbfoError = $_.Exception.Message; Write-Swallowed $_ } }
    } else { $lbfoError = 'Get-NetLbfoTeam is not available (NetLbfo module)' }
    foreach ($t in $teams) {
        # SilentlyContinue: only decides whether the team is bound to a vSwitch; no adapter means "not bound".
        $teamNic = Get-NetAdapter -Name $t.Name -ErrorAction SilentlyContinue
        $boundToVSwitch = ($teamNic -and $vSwitchDescriptions -contains [string]$teamNic.InterfaceDescription)
        $details = @(('Mode=' + $t.TeamingMode),('LoadBalancing=' + $t.LoadBalancingAlgorithm),('Members=' + (@($t.Members) -join ',')))
        # A Hyper-V switch on LBFO is supported up to 2019 and removed from 2022 on (#332).
        if ($boundToVSwitch -and $TargetServerVersion -ne '2019') {
            Add-Result 'NETWORK' ('LBFO team: ' + $t.Name) 'ACTION' 'LBFO team bound to a Hyper-V virtual switch' $details -Recommendation 'LBFO under a Hyper-V vSwitch is not supported on Windows Server 2022/2025. Convert to Switch Embedded Teaming (SET) as a separate, planned change before IPU.' -Source 'Get-NetLbfoTeam, Get-VMSwitch' -Command (Get-RecommendationCommand 'LbfoTeams').Command -CommandKind 'Check'
        } else {
            Add-Result 'NETWORK' ('LBFO team: ' + $t.Name) 'ACTION' ('Status=' + $t.Status) $details -Recommendation 'Microsoft requires NIC Teaming to be disabled before IPU and re-enabled afterwards. Plan console access - the team carries the server''s IP configuration.' -Source 'Get-NetLbfoTeam' -Command (Get-RecommendationCommand 'LbfoTeams').Command -CommandKind 'Check'
        }
    }
    if ($lbfoError) {
        # An LBFO team that was not seen is an upgrade blocker; never report "none" when the query failed (#242).
        Add-Result 'NETWORK' 'NICTeaming' 'MANUAL' 'LBFO teams could not be read' $lbfoError -Recommendation 'Run Get-NetLbfoTeam (or look in Server Manager > NIC Teaming) by hand. Microsoft requires NIC Teaming to be disabled before IPU.' -Kind 'Finding' -Source 'Get-NetLbfoTeam'
    } elseif ($teams.Count -eq 0) { Add-Result 'NETWORK' 'NICTeaming' 'OK' 'No LBFO team detected' -Source 'Get-NetLbfoTeam' }

    # Hosts file - active (non-comment) entries.
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $entries = 0; $lineNo = 0
    $hostsLines = @()
    if (Test-Path -LiteralPath $hostsPath) { $hostsLines = @(Get-Content -LiteralPath $hostsPath) }
    foreach ($line in $hostsLines) {
        $lineNo++
        $active = (([string]$line -split '#',2)[0]).Trim()
        if (-not $active) { continue }
        $entries++
        $script:Data.Snapshot.Hosts += ($active -replace '\s+',' ')
        $tokens = @($active -split '\s+')
        Add-Result 'NETWORK_DEPENDENCY' ('Hosts line ' + $lineNo) 'INFO' ('Address=' + $tokens[0]) ('Names=' + (@($tokens | Select-Object -Skip 1) -join ',')) -Source $hostsPath
    }
    if ($entries -gt 0) {
        Add-Result 'NETWORK_DEPENDENCY' 'HostsFile' 'MANUAL' ('ActiveEntries=' + $entries) $hostsPath -Recommendation 'Confirm owner and purpose of each hosts entry and test the affected name resolution after IPU.' -Source 'hosts file'
    } else {
        Add-Result 'NETWORK_DEPENDENCY' 'HostsFile' 'OK' 'No active entries' -Source $hostsPath
    }

    # Static routes - persistent and active manual (NetMgmt), excluding defaults.
    if (-not (Test-CommandAvailable 'Get-NetRoute')) {
        Add-Result 'NETWORK_DEPENDENCY' 'StaticRoutes' 'MANUAL' 'Get-NetRoute unavailable' -Recommendation 'Run "route print" and document persistent routes manually.' -Source 'NetTCPIP'
        return
    }
    $seen = @{}; $routes = @(); $routeError = ''
    # No persistent route (or none matching) is an ObjectNotFound answer: empty, not failed (#242).
    $persistentRoutes = @()
    try { $persistentRoutes = @(Get-NetRoute -PolicyStore PersistentStore -ErrorAction Stop) }
    catch { if (-not (Test-NotFoundError $_)) { $routeError = $_.Exception.Message; Write-Swallowed $_ } }
    $activeRoutes = @()
    try { $activeRoutes = @(Get-NetRoute -ErrorAction Stop | Where-Object { [string]$_.Protocol -eq 'NetMgmt' }) }
    catch { if (-not (Test-NotFoundError $_)) { $routeError = $_.Exception.Message; Write-Swallowed $_ } }
    foreach ($r in $persistentRoutes) {
        if ($r.DestinationPrefix -in @('0.0.0.0/0','::/0')) { continue }
        $k = [string]$r.DestinationPrefix + '|' + $r.NextHop + '|' + $r.InterfaceIndex
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $routes += [pscustomobject]@{ R=$r; Source='Persistent' } }
    }
    foreach ($r in $activeRoutes) {
        if ($r.DestinationPrefix -in @('0.0.0.0/0','::/0')) { continue }
        $k = [string]$r.DestinationPrefix + '|' + $r.NextHop + '|' + $r.InterfaceIndex
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $routes += [pscustomobject]@{ R=$r; Source='ActiveOnly' } }
    }
    foreach ($x in $routes) {
        $script:Data.Snapshot.Routes += ([string]$x.R.DestinationPrefix + ' via ' + $x.R.NextHop)
        Add-Result 'NETWORK_DEPENDENCY' ('Route ' + $x.R.DestinationPrefix) 'INFO' ('NextHop=' + $x.R.NextHop) @(('Interface=' + $x.R.InterfaceAlias),('Metric=' + $x.R.RouteMetric),('Source=' + $x.Source)) -Source 'Get-NetRoute'
    }
    if ($routeError) {
        # The routes list is left out of the snapshot: the post-upgrade comparison then names it as not compared (#239).
        $script:Data.Snapshot.Remove('Routes')
        Add-Result 'NETWORK_DEPENDENCY' 'StaticRoutes' 'MANUAL' 'Static routes could not be read completely' @($routeError, ('Routes found=' + $routes.Count)) -Recommendation 'Run "route print" and Get-NetRoute -PolicyStore PersistentStore by hand and document the persistent routes.' -Kind 'Finding' -Source 'Get-NetRoute'
    } elseif ($routes.Count -gt 0) {
        $activeOnly = @($routes | Where-Object { $_.Source -eq 'ActiveOnly' }).Count
        Add-Result 'NETWORK_DEPENDENCY' 'StaticRoutes' 'MANUAL' ('Routes=' + $routes.Count) ('ActiveOnly(non-persistent)=' + $activeOnly) -Recommendation 'Confirm each static route is still needed and test it after IPU. Active-only routes are lost at reboot; persistent routes break if the interface index changes (teaming/driver changes).' -Source 'Get-NetRoute'
    } else {
        Add-Result 'NETWORK_DEPENDENCY' 'StaticRoutes' 'OK' 'No non-default persistent or manual routes' -Source 'Get-NetRoute'
    }
}

function Invoke-PortsCheck {
    if (-not (Test-CommandAvailable 'Get-NetTCPConnection')) {
        $script:Data.Snapshot.Remove('Ports')
        Add-Result 'PORTS' 'ListeningPorts' 'MANUAL' 'Get-NetTCPConnection unavailable' -Recommendation 'List the listening ports by hand (netstat -ano) for the post-upgrade test plan.' -Kind 'Finding' -Source 'NetTCPIP'
        return
    }
    $procNames = @{}
    # SilentlyContinue: process names only label the owners; a process that ended meanwhile is normal.
    foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue)) { $procNames[[int]$proc.Id] = $proc.ProcessName }
    $svcByPid = @{}
    foreach ($svc in $script:Data.Services) {
        if ($svc.ProcessId -and [int]$svc.ProcessId -gt 0) {
            $key = [int]$svc.ProcessId
            if (-not $svcByPid.ContainsKey($key)) { $svcByPid[$key] = @() }
            $svcByPid[$key] += [string]$svc.Name
        }
    }
    $owners = @{}
    $endpoints = @()
    # A failed query stops the check (reported as not completed); only "nothing found" is an empty list (#242).
    $tcpListeners = @()
    try { $tcpListeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop) } catch { if (-not (Test-NotFoundError $_)) { throw } }
    foreach ($c in $tcpListeners) { $endpoints += [pscustomobject]@{ Key=('TCP:' + $c.LocalPort); Port=[int]$c.LocalPort; ProcessId=[int]$c.OwningProcess } }
    if (Test-CommandAvailable 'Get-NetUDPEndpoint') {
        $udpEndpoints = @()
        try { $udpEndpoints = @(Get-NetUDPEndpoint -ErrorAction Stop) } catch { if (-not (Test-NotFoundError $_)) { throw } }
        foreach ($u in $udpEndpoints) { $endpoints += [pscustomobject]@{ Key=('UDP:' + $u.LocalPort); Port=[int]$u.LocalPort; ProcessId=[int]$u.OwningProcess } }
    }
    # Ports from the Windows dynamic range (49152+) change between boots and
    # are left out so the before/after comparison stays meaningful.
    foreach ($ep in @($endpoints | Where-Object { $_.Port -lt 49152 })) {
        $owner = ''
        if ($svcByPid.ContainsKey($ep.ProcessId)) { $owner = 'Service ' + (@($svcByPid[$ep.ProcessId]) -join '/') }
        elseif ($procNames.ContainsKey($ep.ProcessId)) { $owner = 'Process ' + $procNames[$ep.ProcessId] }
        if (-not $owners.ContainsKey($ep.Key)) { $owners[$ep.Key] = @() }
        if ($owner -and $owners[$ep.Key] -notcontains $owner) { $owners[$ep.Key] += $owner }
    }
    foreach ($k in @($owners.Keys | Sort-Object { [int](($_ -split ':')[1]) }, { $_ })) {
        Add-Result 'PORTS' $k 'INFO' (@($owners[$k]) -join ', ') -Source 'Get-NetTCPConnection, Get-NetUDPEndpoint'
    }
    $script:Data.Snapshot.Ports = @($owners.Keys | Sort-Object)
    # Who opened each port, so the comparison can pair a closed port with a
    # disabled service (#158).
    $po = [ordered]@{}; foreach ($k in @($owners.Keys | Sort-Object)) { $po[$k] = (@($owners[$k]) -join ', ') }
    $script:Data.Snapshot.PortOwners = $po
    Add-Result 'PORTS' 'Summary' 'INFO' ('ListeningPorts=' + $owners.Count) 'Use this list for the post-upgrade test plan. Dynamic ports (49152+) are not listed.' -Source 'Get-NetTCPConnection, Get-NetUDPEndpoint'
}
