# Chapter: Workloads and applications (docs/checks.md).
# Each check is one function; Register-AssessmentCheck (50-checks.ps1) lists them in run order.

function Invoke-DomainCheck {
    $cs = $script:Data.CS
    $role = [int]$cs.DomainRole
    $roleNames = @{ 0='Workgroup computer (standalone)'; 1='Member workstation'; 2='Workgroup server (standalone)'; 3='Member server'; 4='Backup domain controller'; 5='Primary domain controller' }
    $script:Data.DomainRoleText = Get-DomainRoleText $role ([string]$cs.Domain)
    if ($role -ge 4) {
        $status = 'WARNING'; $rec = 'Domain controller: follow the AD DS upgrade guidance (adprep, FSMO, replication health) and engage the AD team.'
        # With -BlockDomainControllerIPU (the default) a domain controller is
        # SPECIAL (#152): the SPECIAL section carries the plan; this row is
        # evidence only.
        if ($BlockDomainControllerIPU) { $status = 'INFO'; $rec = 'Domain controller: not a standard in-place upgrade (site policy) - see the SPECIAL section.' }
        Add-Result 'DOMAIN_CONTROLLER' 'DomainController' $status $roleNames[$role] ('Domain=' + $cs.Domain) -Recommendation $rec -Source 'Win32_ComputerSystem.DomainRole'
    }

    if ($cs.PartOfDomain) {
        Add-Result 'ACCESS' 'DomainMembership' 'INFO' ('Domain=' + $cs.Domain) ('Role=' + $roleNames[$role]) -Source 'Win32_ComputerSystem'
        if ($role -lt 4) {
            $secure = $null
            if (Test-CommandAvailable 'Test-ComputerSecureChannel') { try { $secure = Test-ComputerSecureChannel -ErrorAction Stop } catch { Write-Swallowed $_ } }
            if ($secure -eq $true) { Add-Result 'ACCESS' 'DomainSecureChannel' 'OK' 'Secure channel verified' -Source 'Test-ComputerSecureChannel' }
            elseif ($secure -eq $false) { Add-Result 'ACCESS' 'DomainSecureChannel' 'ACTION' 'Secure channel test failed' -Recommendation 'Repair the domain trust before IPU; a broken trust can leave you without domain logon after the upgrade.' -Source 'Test-ComputerSecureChannel' }
            else { Add-Result 'ACCESS' 'DomainSecureChannel' 'MANUAL' 'Secure channel could not be tested' -Recommendation 'Verify domain logon manually before the change.' -Source 'Test-ComputerSecureChannel' }
        }
    } else {
        Add-Result 'ACCESS' 'DomainMembership' 'WARNING' ('Workgroup=' + $cs.Domain) ('Role=' + $script:Data.DomainRoleText) -Recommendation 'Workgroup server: confirm it is onboarded in CyberArk/PAM and that local fallback credentials work before IPU.' -Source 'Win32_ComputerSystem'
    }

    # User Account Control (#75). Information, not a finding: UAC does not
    # block an in-place upgrade.
    $uacKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $uacValues = @{}
    foreach ($n in @('EnableLUA','ConsentPromptBehaviorAdmin','PromptOnSecureDesktop','FilterAdministratorToken')) { $uacValues[$n] = (Get-RegistryValueSafe $uacKey $n).Value }
    $uac = Get-UacDecision $uacValues.EnableLUA $uacValues.ConsentPromptBehaviorAdmin $uacValues.PromptOnSecureDesktop $uacValues.FilterAdministratorToken
    $script:Data.UacSummary = $uac.Text
    if ($script:Data.Snapshot) { $script:Data.Snapshot.Uac = $uac.Text }
    Add-Result 'ACCESS' 'UAC' 'INFO' $uac.Text (@($uacValues.Keys | Sort-Object | ForEach-Object { $_ + '=' + $(if ($null -eq $uacValues[$_]) { '(default)' } else { [string]$uacValues[$_] }) }) -join ', ') -Source ($uacKey -replace '^HKLM:','HKLM')

    # On a domain controller "local" accounts are the domain's accounts, and
    # listing them can take minutes (#241): skip the lookup there. Elsewhere
    # ask for the one account by SID instead of listing all of them.
    $rid500 = $null
    if ($script:Data.CS -and [int]$script:Data.CS.DomainRole -ge 4) {
        Add-Result 'ACCESS' 'BuiltInAdministrator' 'INFO' 'Not looked up on a domain controller' 'Its accounts are the domain accounts; the domain Administrator account is the one to record.' -Source 'Win32_ComputerSystem'
    } else {
        $rid500 = @(Get-CimSafe 'Win32_UserAccount' "LocalAccount=True AND SID LIKE '%-500'") | Where-Object { $_.SID -match '-500$' } | Select-Object -First 1
    }
    if ($rid500) {
        Add-Result 'ACCESS' 'BuiltInAdministrator' 'INFO' ('Name=' + $rid500.Name) @(('Disabled=' + $rid500.Disabled),('SID=' + $rid500.SID)) -Recommendation 'Record the (possibly renamed) built-in Administrator and confirm PAM/console fallback.' -Source 'Win32_UserAccount'
    }
    $admins = Get-LocalGroupMembersBySid 'S-1-5-32-544'
    foreach ($member in $admins) { Add-Result 'ACCESS' 'LocalAdministratorsMember' 'INFO' $member -Source 'Local group S-1-5-32-544' }
    if ($admins.Count -eq 0) { Add-Result 'ACCESS' 'LocalAdministratorsMember' 'MANUAL' 'No members returned' -Recommendation 'Enumerate local Administrators manually.' -Kind 'Finding' -Source 'Local group S-1-5-32-544' }
}

function Invoke-ExchangeCheck {
    $exchangeServices = @($script:Data.Services | Where-Object { $_.Name -match '^MSExchange(IS|Transport|FrontEndTransport|ServiceHost|ADTopology|EdgeSync|MailboxAssistants|RPC)$' })
    $setupKeys = @()
    foreach ($v in @('v15','v14','v8.0')) {
        $k = 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\' + $v + '\Setup'
        $p = Get-RegistryValueSafe $k 'MsiInstallPath'
        if ($p.Exists) { $setupKeys += ($v + ': ' + $p.Value) }
    }
    if ($exchangeServices.Count -gt 0) {
        Add-Result 'EXCHANGE' 'ExchangeServerRole' 'BLOCKER' ('Exchange services: ' + (@($exchangeServices | ForEach-Object { $_.Name }) -join ', ')) $setupKeys -Recommendation 'Microsoft does not support an in-place OS upgrade on a server with Exchange installed. Build a new Exchange server on the target OS and migrate.' -Source 'Win32_Service, ExchangeServer\Setup'
    } elseif ($setupKeys.Count -gt 0) {
        Add-Result 'EXCHANGE' 'ExchangeComponents' 'ACTION' 'Exchange setup registration found without Exchange server services' $setupKeys -Recommendation 'Probably Exchange Management Tools only. Confirm with the messaging team; if a server role is installed, IPU is not supported.' -Source 'ExchangeServer\Setup'
    }
}

function Invoke-SqlCheck {
    $instances = @()
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server','HKLM:\SOFTWARE\Wow6432Node\Microsoft\Microsoft SQL Server')) {
        foreach ($type in @('SQL','RS','OLAP')) {
            # SilentlyContinue: No Instance Names key means no instance of this type (absence is normal).
            $names = Get-ItemProperty (Join-Path $root ('Instance Names\' + $type)) -ErrorAction SilentlyContinue
            if (-not $names) { continue }
            foreach ($prop in @($names.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })) {
                # SilentlyContinue: A missing Setup key leaves the version empty, which is reported as MANUAL below.
                $setup = Get-ItemProperty (Join-Path $root ([string]$prop.Value + '\Setup')) -ErrorAction SilentlyContinue
                $version = [string]$setup.Version
                if (-not $version) { $version = [string]$setup.PatchLevel }
                $instances += [pscustomobject]@{ Instance=$prop.Name; Type=$type; Id=[string]$prop.Value; Version=$version; Edition=[string]$setup.Edition; Root=$root }
            }
        }
    }
    $instances = @($instances | Sort-Object Type,Instance,Id -Unique)
    $script:Data.SqlSummary = ''
    if ($instances.Count -eq 0) { return }
    # Named instances are often named after the application or the customer (#195).
    foreach ($i in $instances) { if ($script:SqlDefaultInstanceNames -notcontains $i.Instance) { Add-RedactionLiteral $i.Instance 'NAME'; Add-RedactionLiteral $i.Id 'NAME' } }
    $summary = @()
    foreach ($i in $instances) {
        $major = 0
        [void][int]::TryParse((($i.Version -split '\.')[0]), [ref]$major)
        $typeName = @{ SQL='Database Engine'; RS='Reporting Services'; OLAP='Analysis Services' }[$i.Type]
        if ($major -le 0) {
            Add-Result 'SQL' ($typeName + ': ' + $i.Instance) 'MANUAL' 'Version not found' ('InstanceId=' + $i.Id) -Recommendation 'Determine the SQL Server version and check it against the target OS support matrix.' -Source ($i.Root + '\Instance Names')
            continue
        }
        $d = Get-SqlSupportDecision $major $TargetServerVersion ([string]$i.Version)
        $summary += ($i.Instance + '=' + $d.Release)
        Add-Result 'SQL' ($typeName + ': ' + $i.Instance) $d.Status $d.Release @(('Version=' + $i.Version),('Edition=' + $i.Edition),('InstanceId=' + $i.Id)) -Recommendation $d.Text -Source 'SQL Server instance registry; Microsoft SQL Server / Windows compatibility matrix'
    }
    $script:Data.SqlSummary = ($summary -join ', ')
}

function Invoke-WorkloadsCheck {
    if ($null -eq $script:Data.Features) {
        Add-Result 'ROLES' 'Inventory' 'MANUAL' 'Get-WindowsFeature unavailable' -Recommendation 'List installed roles/features manually.' -Kind 'Finding' -Source 'ServerManager'
    } else {
        foreach ($name in @($script:Data.Features.Keys | Where-Object { $script:Data.Features[$_] } | Sort-Object)) {
            Add-Result 'ROLES' $name 'INFO' 'Installed' -Source 'Get-WindowsFeature'
        }
    }
    $roleChecks = @(
        @{ Name='DNS';        Label='DNS Server';  Rec='Confirm DNS zones are AD-integrated or replicated, and that clients can use another DNS server during the window.' },
        @{ Name='DHCP';       Label='DHCP Server'; Rec='Back up DHCP (Export-DhcpServer) and confirm failover/partner coverage for the change window.' },
        @{ Name='Print-Server'; Label='Print Server'; Rec='See the Print server section: printers, ports, drivers and the PrintBrm backup.' },
        @{ Name='Hyper-V';    Label='Hyper-V host'; Rec='All guests are affected. Plan guest shutdown/migration and confirm vSwitch teaming is SET, not LBFO.' },
        @{ Name='FS-DFS-Replication'; Label='DFS Replication'; Rec='Confirm DFSR health and backlog before IPU; plan to monitor replication afterwards.' },
        @{ Name='WDS';        Label='Windows Deployment Services'; Rec='Validate WDS/PXE dependencies with the deployment team.' },
        @{ Name='UpdateServices'; Label='WSUS'; Rec='Back up the WSUS database/content and confirm the upgrade method with the patch team.' },
        @{ Name='ADFS-Federation'; Label='AD FS'; Rec='AD FS farms are normally upgraded by adding new servers to the farm. Engage the identity team.' },
        @{ Name='NPAS';       Label='Network Policy Server'; Rec='Export the NPS configuration before IPU.' },
        @{ Name='FS-FileServer'; Label='File Server'; Rec='Document shares and permissions; confirm users are informed of the outage.' }
    )
    foreach ($rc in $roleChecks) {
        if ((Get-FeatureState $rc.Name) -eq $true) { Add-Result 'WORKLOAD' $rc.Label 'WARNING' 'Installed' -Recommendation $rc.Rec -Source 'Get-WindowsFeature' }
    }

    # Application workloads (pattern table in section 2), matched on names
    # and service names only - not executable paths - to avoid false positives.
    foreach ($m in (Find-DetectionMatch $script:DetectionPatterns.Workloads $script:Data.Apps $script:Data.Services)) {
        Add-Result 'WORKLOAD' $m.Label 'WARNING' ('Applications=' + @($m.Apps).Count + ', Services=' + @($m.Services).Count) (Get-DetectionEvidence $m) -Recommendation ('Engage the application owner and confirm ' + $m.Label + ' supports ' + (Get-ReleaseDisplayName $TargetServerVersion) + '.') -Source 'Uninstall registry and Win32_Service names'
    }

    # Features removed or no longer developed in the target release.
    if ($null -ne $script:Data.Features) {
        $installed = @($script:Data.Features.Keys | Where-Object { $script:Data.Features[$_] })
        foreach ($f in (Get-FeatureLifecycleFinding $installed $TargetServerVersion)) {
            Add-Result 'FEATURE_LIFECYCLE' $f.Name $f.Status ('Feature ' + $f.Feature + ' is installed') '' -Recommendation $f.Text -Kind $f.Kind -Source 'Microsoft: features removed or no longer developed'
        }
    }
    $browser = @($script:Data.Services | Where-Object { $_.Name -eq 'Browser' -and $_.State -eq 'Running' })
    if ($browser.Count -gt 0) {
        Add-Result 'FEATURE_LIFECYCLE' 'Computer Browser service' 'WARNING' 'Running' '' -Recommendation 'The Computer Browser protocol is no longer developed by Microsoft. Find out what depends on network browsing (often old SMB1 clients).' -Kind 'Observation' -Source 'Win32_Service'
    }
    foreach ($a in $script:Data.Apps) {
        Add-Result 'APPLICATIONS' $a.Name 'INFO' ('Version=' + $a.Version) @(('Publisher=' + $a.Publisher),('InstallDate=' + $a.InstallDate)) -Source 'Uninstall registry (no Win32_Product)'
    }
}

function Invoke-FileSharesCheck {
    # #95: what is shared, from where and to whom, so owners can plan and
    # test, and the post-upgrade run can report a share that is gone.
    $role = Get-FeatureState 'FS-FileServer'
    if (-not (Test-CommandAvailable 'Get-SmbShare')) {
        if ($role -eq $true) { Add-Result 'FILE_SHARES' 'FileShares' 'MANUAL' 'Get-SmbShare is not available' -Recommendation 'List the shares manually (net share) and record their share permissions before the change.' -Kind 'Finding' -Source 'SmbShare module' }
        return
    }
    $printing = (Get-FeatureState 'Print-Server') -eq $true
    $shares = @(Get-SmbShare -ErrorAction Stop | Where-Object { -not $_.Special -and ($printing -or $_.Name -ne 'print$') } | Sort-Object Name)
    if ($shares.Count -eq 0) {
        $note = 'No shares besides the default administrative shares'
        if ($role -eq $true) { Add-Result 'FILE_SHARES' 'FileShares' 'INFO' $note 'The File Server role is installed but shares nothing.' -Source 'Get-SmbShare' }
        else { Add-Result 'FILE_SHARES' 'FileShares' 'INFO' $note -Source 'Get-SmbShare' }
        return
    }
    Add-Result 'FILE_SHARES' 'FileShares' 'WARNING' ('Count=' + $shares.Count) (@($shares | ForEach-Object { $_.Name }) -join ', ') -Recommendation 'Shared folders must be reachable again right after the upgrade. Test access from a client with the share owners, and keep this list (with permissions) for the comparison afterwards.' -Source 'Get-SmbShare'
    foreach ($sh in $shares) {
        Add-RedactionLiteral ([string]$sh.Name) 'NAME'
        if ($sh.Description) { Add-RedactionLiteral ([string]$sh.Description) 'NAME' }
        $access = @()
        if (Test-CommandAvailable 'Get-SmbShareAccess') {
            try {
                $access = @(Get-SmbShareAccess -Name $sh.Name -ErrorAction Stop | ForEach-Object { [string]$_.AccountName + ': ' + [string]$_.AccessRight + $(if ([string]$_.AccessControlType -eq 'Deny') { ' (Deny)' } else { '' }) })
            } catch { Write-Swallowed $_ }
        }
        $details = @(('Path=' + $sh.Path))
        if ($sh.Description) { $details += ('Description=' + $sh.Description) }
        $details += ('Share permissions: ' + $(if ($access.Count) { $access -join '; ' } else { 'not readable' }))
        Add-Result 'FILE_SHARES' ('Share: ' + $sh.Name) 'INFO' ([string]$sh.Path) $details -Source 'Get-SmbShare, Get-SmbShareAccess'
    }
    if ($script:Data.Snapshot) { $script:Data.Snapshot.Shares = @($shares | ForEach-Object { [string]$_.Name }) }
}

function Invoke-PrintersCheck {
    # #148: what a print server holds, so it can be checked after the
    # upgrade and the driver work planned. Read-only.
    $role = (Get-FeatureState 'Print-Server') -eq $true
    $script:Data.PrintServer = $false
    try { $inv = Get-PrinterInventory }
    catch {
        $spooler = @($script:Data.Services | Where-Object { $_.Name -eq 'Spooler' }) | Select-Object -First 1
        $startMode = ''; if ($spooler) { $startMode = [string]$spooler.StartMode }
        if ((Get-PrinterReadFailureDecision $role $startMode ($null -ne $spooler)) -eq 'Manual') {
            Add-Result 'PRINTING' 'Printers' 'MANUAL' 'Could not read the printers' $_.Exception.Message -Recommendation 'Check that the Print Spooler service runs, and list printers, ports and drivers in Print Management before the change.' -Kind 'Finding' -Source 'PrintManagement, Win32_Printer'
        } else {
            Add-Result 'PRINTING' 'PrintServer' 'OK' 'Not a print server' 'Print Server role not installed and the Print Spooler service is disabled or missing' -Source 'Win32_Service'
        }
        return
    }
    $printers = @($inv.Printers | Where-Object { $_ -and [string]$_.DriverName -notmatch $script:VirtualPrinterDrivers } | Sort-Object Name)
    $shared = @($printers | Where-Object { $_.Shared })
    if (-not $role -and $shared.Count -eq 0) {
        Add-Result 'PRINTING' 'PrintServer' 'OK' 'Not a print server' ('Print Server role not installed, shared printers=0, local printers=' + $printers.Count) -Source $inv.Source
        return
    }
    $script:Data.PrintServer = $true
    $target = Get-ReleaseDisplayName $TargetServerVersion
    Add-Result 'PRINTING' 'Printers' 'WARNING' ('Count=' + $printers.Count + ', shared=' + $shared.Count) ('Print Server role=' + $role) -Recommendation 'Keep the PrintBrm backup and this list. After the upgrade, print a test page on each shared printer and test from a client; the post-upgrade run reports printers and ports that are gone.' -Source $inv.Source
    foreach ($p in $printers) { Add-RedactionLiteral $p.Name 'NAME'; if ($p.ShareName) { Add-RedactionLiteral $p.ShareName 'NAME' } }
    foreach ($p in $printers) {
        $details = @(('Share=' + $(if ($p.Shared -and $p.ShareName) { $p.ShareName } else { '(not shared)' })), ('Published in AD=' + $p.Published))
        Add-Result 'PRINTING' ('Printer: ' + $p.Name) 'INFO' ('Driver=' + $p.DriverName + '; Port=' + $p.PortName) $details -Source $inv.Source
    }

    # Ports in use by a printer, and every LPR port.
    $usedNames = @($printers | ForEach-Object { @(([string]$_.PortName) -split ',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $ports = @($inv.Ports | Where-Object { $_ -and ($usedNames -contains [string]$_.Name -or (Get-PrinterPortKind $_.Description $_.Monitor $_.Protocol) -eq 'LPR port monitor') } | Sort-Object Name)
    foreach ($pt in $ports) { Add-RedactionLiteral $pt.Name 'NAME'; if ($pt.Address -and $pt.Address -notmatch '^[0-9.:]+$') { Add-RedactionLiteral $pt.Address 'HOST' } }
    foreach ($pt in $ports) {
        $kind = Get-PrinterPortKind $pt.Description $pt.Monitor $pt.Protocol
        $details = @()
        if ($pt.Address) { $details += ('Address=' + $pt.Address + $(if ($pt.PortNumber) { ':' + $pt.PortNumber } else { '' })) }
        if ($pt.Queue) { $details += ('Queue=' + $pt.Queue) }
        if ($pt.Monitor) { $details += ('Monitor=' + $pt.Monitor) }
        if ($kind -eq 'LPR port monitor') {
            Add-Result 'PRINTING' ('Port: ' + $pt.Name) 'WARNING' $kind $details -Recommendation 'Microsoft deprecated LPR/LPD and plans to remove it. Move the printer to a Standard TCP/IP port (RAW, or LPR protocol on the standard port) and test before the upgrade.' -Kind 'Observation' -Source 'Get-PrinterPort' -Link 'https://learn.microsoft.com/en-us/windows/whats-new/deprecated-features' -LinkTitle 'Deprecated Windows features'
        } else {
            Add-Result 'PRINTING' ('Port: ' + $pt.Name) 'INFO' $kind $details -Source 'Get-PrinterPort'
        }
    }
    if ((Get-FeatureState 'Print-LPD-Service') -eq $true) {
        Add-Result 'PRINTING' 'LPD Service' 'WARNING' 'Installed' 'UNIX and other clients can print to this server over LPD.' -Recommendation 'Microsoft deprecated LPR/LPD and plans to remove it. Find the clients that use it and move them to IPP or a Standard TCP/IP port.' -Kind 'Observation' -Source 'Get-WindowsFeature' -Link 'https://learn.microsoft.com/en-us/windows/whats-new/deprecated-features' -LinkTitle 'Deprecated Windows features'
    }

    # Drivers.
    foreach ($r in @(Get-PrinterDriverDecision $inv.Drivers $target $TargetServerVersion)) {
        if ($r.Item -eq 'PrinterDrivers' -and $r.Status -eq 'WARNING') { Add-Result 'PRINTING' $r.Item $r.Status $r.Value $r.Details -Recommendation $r.Recommendation -Source $inv.Source -Link $script:PrinterDriverDocUrl -LinkTitle 'End of servicing plan for third-party printer drivers' }
        else { Add-Result 'PRINTING' $r.Item $r.Status $r.Value $r.Details -Recommendation $r.Recommendation -Source $inv.Source }
    }

    # Port monitors and print processors.
    try {
        foreach ($r in @(Get-PrintComponentDecision (Get-PrintMonitorInventory) $target)) {
            Add-Result 'PRINTING' $r.Item $r.Status $r.Value $r.Details -Recommendation $r.Recommendation -Source 'HKLM\SYSTEM\CurrentControlSet\Control\Print'
        }
    } catch {
        Add-Result 'PRINTING' 'PrintComponents' 'MANUAL' 'Could not read the port monitors and print processors' $_.Exception.Message -Recommendation 'Check Print Management > Print Servers > Ports and the registry key HKLM\SYSTEM\CurrentControlSet\Control\Print\Monitors for monitors that are not from Microsoft.' -Kind 'Finding' -Source 'HKLM\SYSTEM\CurrentControlSet\Control\Print'
    }

    if ($script:Data.Snapshot) {
        $script:Data.Snapshot.Printers = @($printers | ForEach-Object { [string]$_.Name })
        $script:Data.Snapshot.PrinterPorts = @($ports | ForEach-Object { [string]$_.Name })
        $script:Data.Snapshot.PrinterDrivers = @($printers | ForEach-Object { [pscustomobject]@{ Printer = [string]$_.Name; Driver = [string]$_.DriverName } })
    }
}

function Invoke-IisCheck {
    $iisState = Get-FeatureState 'Web-Server'
    if ($null -eq $iisState) { Add-Result 'IIS' 'Web-Server' 'MANUAL' 'Feature state unknown: the role inventory failed' -Recommendation 'Check by hand whether IIS is installed (Get-WindowsFeature Web-Server, or the W3SVC service).' -Source 'Get-WindowsFeature'; return }
    if ($iisState -ne $true) { Add-Result 'IIS' 'Web-Server' 'OK' 'Not installed' -Source 'Get-WindowsFeature'; return }
    Add-Result 'IIS' 'Web-Server' 'WARNING' 'Installed' -Recommendation 'Immediately before the IPU, run the appcmd.exe add backup command shown (the copy in this report is from assessment time), and keep site, binding and certificate documentation.' -Source 'Get-WindowsFeature' -Command (Get-RecommendationCommand 'IisBackup').Command -CommandKind 'Change' -Link $script:DocLinks.AppCmd.Url -LinkTitle $script:DocLinks.AppCmd.Title
    if ($EnableIISConfigEvidence) {
        try {
            $dest = Join-Path (Initialize-EvidenceFolder 'IIS') ($script:SafeComputerName + '-IPU-IIS-' + (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture))
            $copy = Save-IISConfigEvidence -Destination $dest -Zip $CreatePolicyEvidenceZip
            Add-Result 'IIS' 'ConfigurationCopy' 'OK' $copy.Location @(('Files=' + ($copy.Files -join ', ')), ('applicationHost.config SHA256=' + $copy.ApplicationHostSha256)) -Recommendation 'Restore: copy the files back to %windir%\System32\inetsrv\config, or put them in a folder under inetsrv\backup and run "appcmd restore backup <folder>". See the user guide.' -Source 'inetsrv\config (copied, not changed)'
            if ($copy.SharedConfigPath) {
                Add-Result 'IIS' 'SharedConfiguration' 'WARNING' ('Enabled: ' + $copy.SharedConfigPath) 'The local files only point to the shared location.' -Recommendation 'Back up the shared configuration at that path as well, and confirm every server that uses it before the change.' -Kind 'Observation' -Source 'redirection.config'
            }
        } catch {
            Add-Result 'IIS' 'ConfigurationCopy' 'MANUAL' 'Could not copy the IIS configuration' $_.Exception.Message -Recommendation 'Back up the IIS configuration manually before the change: appcmd add backup PreIPU, or copy %windir%\System32\inetsrv\config.' -Kind 'Finding' -Source 'inetsrv\config'
        }
    } else {
        Add-Result 'IIS' 'ConfigurationCopy' 'INFO' 'Not taken (EnableIISConfigEvidence is off)' -Source 'SETTINGS'
    }
    $iisManual = 'List the sites and bindings by hand (appcmd list site, or IIS Manager) before the change.'
    if (-not (Get-Module -ListAvailable WebAdministration)) {
        Add-Result 'IIS' 'Sites' 'MANUAL' 'Sites and bindings not listed (WebAdministration module missing)' -Recommendation $iisManual -Kind 'Finding' -Source 'WebAdministration'
        return
    }
    $sites = @()
    try { Import-Module WebAdministration -ErrorAction Stop; $sites = @(Get-Website -ErrorAction Stop) }
    catch {
        Write-Swallowed $_
        Add-Result 'IIS' 'Sites' 'MANUAL' 'Sites and bindings could not be read' $_.Exception.Message -Recommendation $iisManual -Kind 'Finding' -Source 'WebAdministration'
        return
    }
    foreach ($site in $sites) {
        $bindings = @($site.Bindings.Collection | ForEach-Object { $_.protocol + ':' + $_.bindingInformation }) -join ' | '
        Add-Result 'IIS' ('Site: ' + $site.Name) 'INFO' ('State=' + $site.State) @(('Path=' + $site.PhysicalPath),('Bindings=' + $bindings)) -Source 'WebAdministration'
    }
}

function Invoke-RdsCheck {
    $rdsh = Get-FeatureState 'RDS-RD-Server'
    $rdlic = Get-FeatureState 'RDS-Licensing'
    if ($null -eq $rdsh -or $null -eq $rdlic) { Add-Result 'RDS' 'RDSRoles' 'MANUAL' 'Feature state unknown: the role inventory failed' -Recommendation 'Check by hand whether the Remote Desktop Session Host and Licensing roles are installed (Get-WindowsFeature RDS-*).' -Source 'Get-WindowsFeature'; return }
    if ($rdsh -eq $true) { Add-Result 'RDS' 'RDSessionHost' 'ACTION' 'Installed' -Recommendation ('Plan a longer IPU window, record the licensing configuration, and confirm RDS CALs are valid for ' + (Get-ReleaseDisplayName $TargetServerVersion) + ' (CALs must be the same or newer release as the server).') -Source 'Get-WindowsFeature' }
    else { Add-Result 'RDS' 'RDSessionHost' 'OK' 'Not installed' -Source 'Get-WindowsFeature' }
    if ($rdlic -eq $true) { Add-Result 'RDS' 'RDLicensingServer' 'ACTION' 'Installed' -Recommendation 'This is an RD Licensing server. Upgrading it affects every RDS host that uses it; confirm installed CALs and the order of upgrades with the RDS owner.' -Source 'Get-WindowsFeature' }
    if ($rdsh -eq $true -or $rdlic -eq $true) {
        $ts = @(Get-CimSafe 'Win32_TerminalServiceSetting' '' 'root\cimv2\TerminalServices') | Select-Object -First 1
        if ($ts) {
            $mode = @{ 2='PerDevice'; 4='PerUser'; 5='NotConfigured' }[[int]$ts.LicensingType]
            $servers = @()
            try { $servers = @((Invoke-CimMethod -InputObject $ts -MethodName GetSpecifiedLicenseServerList -ErrorAction Stop).SpecifiedLSList) } catch { Write-Swallowed $_ }
            Add-Result 'RDS' 'LicensingConfiguration' 'INFO' ('Mode=' + $mode) ('LicenseServers=' + ($servers -join ',')) -Source 'Win32_TerminalServiceSetting'
        }
    }
}

function Invoke-EolCandidatesCheck {
    # Which products with an end-of-life date are on the server (#286, ADR
    # 0003). Only reads: uninstall entries, service command lines, file version
    # resources, one registry value. A product is never run to ask its version.
    $found = @(Find-EolAppCandidate $script:EolDetection $script:Data.Apps)
    $targets = @(Get-EolServiceTarget $script:EolDetection $script:Data.Services)
    foreach ($d in @($script:EolDetection)) {
        if (-not $d.Probe) { continue }
        foreach ($pattern in @($d.Probe)) {
            $r = Resolve-EolProbePath $pattern
            foreach ($p in @($r.Paths)) { $targets += [pscustomobject]@{ Product = [string]$d.Product; Name = [string]$d.Name; Path = $p; Source = 'File probe'; Evidence = (Split-Path -Leaf $p) } }
            if ($r.Error) { $found += [pscustomobject]@{ Product = [string]$d.Product; Name = [string]$d.Name; Version = ''; Source = 'File probe'; Evidence = $pattern; Error = $r.Error } }
        }
    }
    foreach ($t in $targets) {
        $v = Get-FileVersionText $t.Path
        $found += [pscustomobject]@{ Product = $t.Product; Name = $t.Name; Version = $v.Version; Source = $t.Source; Evidence = $t.Evidence; Error = $v.Error }
    }
    $netfxError = ''
    try {
        $nd = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop
        $fx = ConvertFrom-DotNetFrameworkRelease $nd.Release
        if ($fx) { $found += [pscustomobject]@{ Product = 'dotnetfx'; Name = '.NET Framework'; Version = $fx; Source = 'Registry'; Evidence = 'NDP\v4\Full Release' } }
    } catch { if (-not (Test-NotFoundError $_)) { $netfxError = $_.Exception.Message } }

    $script:Data.EolCandidates = @(Merge-EolCandidate $found)
    foreach ($c in $script:Data.EolCandidates) {
        $name = @($script:EolDetection | Where-Object { $_.Product -eq $c.Product } | ForEach-Object { $_.Name })[0]
        if (-not $name) { $name = $(if ($c.Product -eq 'dotnetfx') { '.NET Framework' } else { $c.Product }) }
        Add-Result 'APPLICATIONS' ('EOL candidate: ' + $name) 'INFO' $c.Version ($c.Source + ': ' + $c.Evidence) -Kind 'Observation' -Source 'Uninstall registry, service files, file versions'
    }
    # A product seen but without a version is a MANUAL finding, not silence.
    $have = @{}; foreach ($c in $script:Data.EolCandidates) { $have[$c.Product] = $true }
    $reported = @{}
    foreach ($f in @($found | Where-Object { -not $_.Version })) {
        if ($have.ContainsKey($f.Product) -or $reported.ContainsKey($f.Product)) { continue }
        $reported[$f.Product] = $true
        $why = 'The version could not be read.'
        if ($f.PSObject.Properties['Error'] -and $f.Error) { $why = [string]$f.Error }
        Add-Result 'APPLICATIONS' ('EOL detection: ' + $f.Name) 'MANUAL' ($f.Name + ' found, version not known') ($f.Source + ': ' + $f.Evidence + '. ' + $why) -Recommendation ('Read the version of ' + $f.Name + ' by hand (its file properties or its own documentation) and check its end-of-life date. The assessment never runs a product to ask.') -Kind 'Finding' -Source $f.Source
    }
    if ($netfxError) {
        Add-Result 'APPLICATIONS' 'EOL detection: .NET Framework' 'MANUAL' '.NET Framework version could not be read' $netfxError -Recommendation 'Check the .NET Framework version by hand (Release value under HKLM\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full).' -Kind 'Finding' -Source 'Registry'
    }
}

function Invoke-EolSnapshotCheck {
    $scriptFolder = ''
    if ($script:ScriptFolder) { $scriptFolder = $script:ScriptFolder }
    $searched = @(Get-EolSnapshotSearchPath $EolSnapshotPath $scriptFolder $ReportDirectory)
    $found = ''; $asOf = ''; $readError = ''; $snap = $null
    foreach ($candidate in $searched) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $found = $candidate; break }
    }
    if ($found) {
        try {
            $snap = Get-Content -LiteralPath $found -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $asOf = $snap.asOf
            if ($asOf -is [datetime]) { $asOf = $asOf.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
            $asOf = [string]$asOf
        } catch { $readError = $_.Exception.Message }
    }
    $today = Get-Date
    $d = Get-EolSnapshotDecision $searched $found $asOf $readError ([bool]$EolSnapshotPath) $today
    Add-Result 'APPLICATIONS' 'EOL snapshot' $d.Status $d.Value $d.Details -Recommendation $d.Recommendation -Kind $d.Kind -Source 'eol-snapshot.json'
    # With a readable snapshot, every product the eolcandidates check found gets a verdict (#275).
    if (-not $found -or $readError -or -not $snap) { return }
    foreach ($c in @($script:Data.EolCandidates)) {
        $v = Get-EolCandidateVerdict $c $snap $today
        $recommendation = Get-EolRecommendation $v
        $kind = Get-EolResultKind $v
        Add-Result 'APPLICATIONS' ('EOL: ' + $v.Name + ' ' + $c.Version) $v.Status $v.Text ($c.Source + ': ' + $c.Evidence) -Recommendation $recommendation -Kind $kind -Source 'eol-snapshot.json'
    }
}

function Invoke-PrintBackupCheck {
    # #148: PrintBrm -B exports printers, ports, drivers and queues into one
    # file. It only reads the spooler configuration. The file is not redacted
    # and is never part of the report.
    if ($AssessmentMode -eq 'Post') { $script:CurrentCheckMessage = 'Not applicable: not needed after the upgrade'; $script:CurrentCheckOutcome = 'Skipped'; return }
    if (-not $script:Data.PrintServer) { $script:CurrentCheckMessage = 'Not applicable: not a print server'; $script:CurrentCheckOutcome = 'Skipped'; return }
    $cmd = Get-PrintBackupCommand
    if (-not $EnablePrintBackup) {
        Add-Result 'PRINTING' 'PrintBackup' 'MANUAL' 'Not taken (EnablePrintBackup is off)' -Recommendation 'Export the print configuration before the change, to a drive with enough free space, and keep the file off the server.' -Kind 'Finding' -Source 'SETTINGS' -Command $cmd -CommandKind 'Check'
        return
    }
    $brm = Join-Path $env:windir 'System32\spool\tools\PrintBrm.exe'
    if (-not (Test-Path -LiteralPath $brm -PathType Leaf)) {
        Add-Result 'PRINTING' 'PrintBackup' 'MANUAL' 'PrintBrm.exe not found' $brm -Recommendation 'Export the printers with Print Management (Export printers to a file) before the change, and keep the file off the server.' -Kind 'Finding' -Source 'PrintBrm.exe'
        return
    }
    $root = [IO.Path]::GetPathRoot($EvidenceRoot).TrimEnd('\')
    $disk = @(Get-CimRequired 'Win32_LogicalDisk' ("DeviceID='" + $root + "'")) | Select-Object -First 1
    if (-not $disk -or $null -eq $disk.FreeSpace) { throw ('Could not read the free space of ' + $root) }
    $space = Get-PrintBackupSpaceDecision (Get-PrintDriverStoreSize) ([long]$disk.FreeSpace)
    if (-not $space.Proceed) {
        Add-Result 'PRINTING' 'PrintBackup' 'MANUAL' ('Skipped: not enough free space on ' + $root) $space.Text -Recommendation 'Run the export to a drive or share with enough free space before the change, and keep the file off the server.' -Kind 'Finding' -Source 'spool\drivers, Win32_LogicalDisk' -Command $cmd -CommandKind 'Check'
        return
    }
    $timeout = [math]::Min($PrintBackupTimeoutMinutes * 60, $script:SlowSecondsLeft)
    $dest = Join-Path (Initialize-EvidenceFolder 'Printers') ($script:SafeComputerName + '-IPU-Print-' + (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture))
    $null = Initialize-OutputFolder $dest
    $file = Join-Path $dest ($script:SafeComputerName + '-printers.printerExport')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-NativeCapture $brm @('-B', '-F', $file) $timeout
    $sw.Stop()
    $duration = 'Duration=' + (Format-Duration $sw.Elapsed)
    if ($r.TimedOut) {
        # A cut-off export is not a backup; remove this run's partial file.
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
        Add-Result 'PRINTING' 'PrintBackup' 'MANUAL' ('Stopped after ' + [math]::Round($timeout / 60) + ' minutes') @($duration, $space.Text, (Get-StopFailureText $r.StillRunning)) -Recommendation 'Run the export by hand outside the SA job, before the change, and keep the file off the server.' -Kind 'Finding' -Source 'PrintBrm.exe -B' -Command $cmd -CommandKind 'Check'
        $script:CurrentCheckOutcome = 'TimedOut'; return
    }
    if ($r.Error) { throw $r.Error }
    if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $file -PathType Leaf)) {
        Add-Result 'PRINTING' 'PrintBackup' 'MANUAL' ('PrintBrm failed (exit code ' + $r.ExitCode + ')') @($duration, (@($r.Lines | Select-Object -Last 3) -join ' | ')) -Recommendation 'Read the PrintBrm output and the PrintBrm event log (Applications and Services Logs > Microsoft > Windows > PrintBRM), then export by hand before the change.' -Kind 'Finding' -Source 'PrintBrm.exe -B' -Command $cmd -CommandKind 'Check'
        return
    }
    $size = [math]::Round(([double](Get-Item -LiteralPath $file).Length / 1MB), 1)
    Add-Result 'PRINTING' 'PrintBackup' 'OK' $file @(('SizeMB=' + $size), $duration, $space.Text) -Recommendation 'Copy the file off the server before the change: a backup on C: does not survive a failed upgrade that needs a rebuild. It holds the full print configuration and is not redacted. Restore: PrintBrm -R -F <file> (see the user guide).' -Source 'PrintBrm.exe -B (reads the spooler configuration)'
}
