# Chapter: Access, certificates and security (docs/checks.md).
# Each check is one function; Register-AssessmentCheck (50-checks.ps1) lists them in run order.

function Invoke-GroupPolicyCheck {
    # #80: which GPOs apply, which are filtered out and why, WMI filters on the
    # Windows version (they can stop or start matching after the upgrade),
    # the computer's AD groups, and when policy last applied.
    $domainMember = [bool]$script:Data.CS.PartOfDomain
    $gp = $null; $gpError = ''
    try { $gp = ConvertFrom-GpResultXml (Get-GpResultXml) } catch { $gpError = $_.Exception.Message; Write-Swallowed $_ }
    # gpresult run as SYSTEM can answer "does not have RSoP data" on 2012 R2
    # to 2019 (#160). The Group Policy service's own record of the applied
    # GPOs is the fallback; MANUAL stays only when both fail.
    $gpSource = 'gpresult'
    if (-not $gp -and $domainMember) {
        $fbEntries = 0; $fbNamed = 0; $fbError = ''; $fbMissing = $false
        try {
            $entries = Get-GpoListRegistryEntry
            $fbEntries = @($entries | Where-Object { $_ }).Count
            $fallback = ConvertFrom-GpoListEntry @($entries)
            $fbNamed = @($fallback.Gpos).Count
            if ($fbNamed -gt 0) { $gp = $fallback; $gpSource = 'registry' }
        } catch {
            $fbError = $_.Exception.Message
            $fbMissing = ($_.Exception -is [System.Management.Automation.ItemNotFoundException])
            Write-Swallowed $_
        }
        # Say what the fallback found, so a MANUAL row can be followed up (#215).
        if (-not $gp) { $gpError = ($gpError + ' | ' + (Get-GpoFallbackNote $fbEntries $fbNamed $fbError $fbMissing)).Trim(' |') }
    }
    $groups = @(); $filters = @{}; $adError = ''; $adRead = $true
    if ($domainMember) {
        try {
            # Assign first: the function returns the list as one object.
            $groups = Get-AdComputerGroup
            $groups = @($groups | Where-Object { $_ })
            if ($gp) { $filters = Get-WmiFilterQuery @($gp.Gpos | ForEach-Object { $_.Guid }) }
        } catch { $adRead = $false; $adError = $_.Exception.Message; Write-Swallowed $_ }
    }
    # Where the computer object is in AD (#99): the OU decides which GPOs link.
    $dn = ''
    if ($domainMember -and $adRead) {
        try { $dn = Get-AdComputerDn } catch { Write-Swallowed $_ }
    }
    if ($dn) {
        $script:Data.AdLocation = ConvertTo-AdLocation $dn
        Add-Result 'GROUP_POLICY' 'ComputerOU' 'INFO' $script:Data.AdLocation ('DistinguishedName=' + $dn) -Source 'AD computer object (distinguishedName)'
        if ($script:Data.Snapshot) { $script:Data.Snapshot.Ou = $dn }
    } elseif (-not $domainMember) {
        $script:Data.AdLocation = 'Not applicable (workgroup)'
    } elseif ($adRead) {
        $script:Data.AdLocation = 'Not readable'
    } else {
        $script:Data.AdLocation = 'Not readable (domain not reachable)'
    }
    $last = $null
    if ($domainMember) { $last = Get-GroupPolicyLastApplied }
    foreach ($row in (Get-GroupPolicyDecision $domainMember ($null -ne $gp) $adRead $last (Get-Date) $GroupPolicyMaxAgeDays $gpError $adError)) {
        Add-Result 'GROUP_POLICY' $row.Item $row.Status $row.Value $row.Details -Recommendation $row.Recommendation -Kind $row.Kind -Source 'gpresult, Active Directory, Group Policy state'
    }
    if ($gpSource -eq 'registry') {
        Add-Result 'GROUP_POLICY' 'GroupPolicySource' 'INFO' 'Applied GPOs read from the Group Policy state in the registry' @('gpresult: ' + $gpError, 'Only applied GPOs are recorded there: GPOs filtered out (and why) are not listed.') -Source 'HKLM\...\Group Policy\State\Machine\GPO-List'
    }
    if ($gp) {
        $target = Get-ReleaseDisplayName $TargetServerVersion
        foreach ($g in @($gp.Gpos)) {
            Add-RedactionLiteral $g.Name 'GPO'
            if ($g.FilterName) { Add-RedactionLiteral $g.FilterName 'NAME' }
            $state = 'Applied'; if (-not $g.Applied) { $state = $g.Reason }
            $details = @(('Linked at ' + (@($g.Links) -join '; ')))
            $filter = $filters[$g.Guid]
            if ($filter) {
                Add-RedactionLiteral $filter.Name 'NAME'
                $details += ('WMI filter: ' + $filter.Name)
                foreach ($q in @($filter.Queries)) { $details += ('Query: ' + $q.Query) }
            } elseif ($g.FilterName) { $details += ('WMI filter: ' + $g.FilterName) }
            $osDependent = $filter -and @($filter.Queries | Where-Object { Test-WmiFilterOsDependent $_.Query }).Count -gt 0
            if ($osDependent) {
                Add-Result 'GROUP_POLICY' ('GPO: ' + $g.Name) 'WARNING' ($state + ' - WMI filter depends on the Windows version') $details -Recommendation ('After the upgrade the server reports ' + $target + '. Check that this filter still matches (or still excludes) it as intended, before the change.') -Source 'gpresult, WMI filter in AD'
            } else {
                Add-Result 'GROUP_POLICY' ('GPO: ' + $g.Name) 'INFO' $state $details -Source $gpSource
            }
        }
        if (-not $domainMember) {
            Add-Result 'GROUP_POLICY' 'ADGroup' 'INFO' 'Not applicable (workgroup)' -Source 'Win32_ComputerSystem'
        }
        if ($script:Data.Snapshot) {
            $script:Data.Snapshot.Gpos = @($gp.Gpos | Where-Object { $_.Applied } | ForEach-Object { $_.Name } | Sort-Object -Unique)
        }
    } elseif (-not $domainMember) {
        # Workgroup server and gpresult failed: still only local policy.
        Add-Result 'GROUP_POLICY' 'LocalPolicy' 'MANUAL' 'Could not list the local policy (gpresult)' $gpError -Recommendation (Get-LocalPolicyAdvice (Test-LgpoAvailable) $EnableRDPPolicyEvidence) -Kind 'Finding' -Source 'gpresult'
    }
    # The AD groups come from AD, not gpresult: list them even when no GPO
    # list could be read (#160).
    if ($domainMember -and $adRead) {
        foreach ($n in $groups) { Add-Result 'GROUP_POLICY' 'ADGroup' 'INFO' $n -Source 'AD tokenGroups (nested groups included)' }
        if ($script:Data.Snapshot) { $script:Data.Snapshot.Groups = @($groups) }
    }
}

function Invoke-PkiCheck {
    $adcs = @()
    foreach ($f in @('ADCS-Cert-Authority','ADCS-Web-Enrollment','ADCS-Enroll-Web-Pol','ADCS-Enroll-Web-Svc','ADCS-Device-Enrollment','ADCS-Online-Cert')) {
        if ((Get-FeatureState $f) -eq $true) { $adcs += $f }
    }
    $certSvc = @($script:Data.Services | Where-Object { $_.Name -eq 'CertSvc' }) | Select-Object -First 1
    if ($adcs -contains 'ADCS-Cert-Authority' -or $certSvc) {
        Add-Result 'PKI' 'CertificationAuthority' 'ACTION' 'Certification Authority detected' $adcs -Recommendation 'Engage the PKI team: verify CA database and private-key backup, AIA/CDP dependencies, and a tested recovery procedure before IPU.' -Source 'Get-WindowsFeature, CertSvc'
        # Site policy (#322): the PKI team allows an in-place upgrade only to
        # the releases in PkiAllowedTargets. Pre runs only.
        if ($AssessmentMode -ne 'Post') {
            $pkiSource = $script:Data.SourceRelease
            if (-not $pkiSource -and $script:Data.OS) { $pkiSource = Get-WindowsServerRelease $script:Data.OS.BuildNumber $script:Data.OS.Caption }
            $policy = Get-PkiTargetDecision $pkiSource $TargetServerVersion (ConvertTo-ReleaseList $PkiAllowedTargets)
            if ($policy.Kind -ne 'Allowed') { Add-Result 'PKI' 'PkiSitePolicy' $policy.Status $policy.Text ('PkiAllowedTargets=' + ((ConvertTo-ReleaseList $PkiAllowedTargets) -join ',')) -Recommendation $policy.Recommendation -Kind 'Finding' -Source 'Site policy (PkiAllowedTargets)' }
        }
        $active = (Get-RegistryValueSafe 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' 'Active').Value
        if ($active) {
            $ca = $null
            try { $ca = Get-ItemProperty ('HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\' + $active) -ErrorAction Stop } catch { Write-Swallowed $_ }
            $type = ''; if ($ca) { $type = Get-CaTypeName $ca.CAType }
            if ($type) {
                Add-Result 'PKI' ('CA: ' + $active) 'INFO' ('Type=' + $type) @(('DB=' + $ca.DBDirectory),('Log=' + $ca.DBLogDirectory)) -Source 'CertSvc configuration'
            } else {
                # An unreadable configuration must not look like an enterprise root CA (#242).
                Add-Result 'PKI' ('CA: ' + $active) 'MANUAL' 'The CA configuration or its type could not be read' -Recommendation 'Check the CA type, database and log folders by hand (certutil -getreg CA) before the change.' -Kind 'Finding' -Source 'CertSvc configuration'
            }
        }
    } elseif ($adcs.Count -gt 0) {
        Add-Result 'PKI' 'ADCSRoleServices' 'ACTION' ($adcs -join ', ') -Recommendation 'Engage the PKI team and confirm configuration/recovery requirements before IPU.' -Source 'Get-WindowsFeature'
    }

    # Certificate index across the stores that services bind from.
    $index = @{}
    foreach ($store in @('My','Remote Desktop','WebHosting')) {
        # SilentlyContinue: the WebHosting and Remote Desktop stores do not exist until used; a missing store is empty.
        foreach ($cert in @(Get-ChildItem ('Cert:\LocalMachine\' + $store) -ErrorAction SilentlyContinue)) {
            $thumb = ConvertTo-NormalizedThumbprint $cert.Thumbprint
            if ($index.ContainsKey($thumb)) { continue }
            $index[$thumb] = [pscustomobject]@{ Cert=$cert; Store=$store }
            $days = [math]::Floor(($cert.NotAfter - (Get-Date)).TotalDays)
            Add-Result 'CERTIFICATES' $thumb 'INFO' ('Subject=' + $cert.Subject) @(('Store=' + $store),('Issuer=' + $cert.Issuer),('NotAfter=' + $cert.NotAfter.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)),('HasPrivateKey=' + $cert.HasPrivateKey)) -Source ('Cert:\LocalMachine\' + $store)
            if ($days -lt 0) {
                Add-Result 'CERTIFICATES' ('Expired: ' + $thumb) 'WARNING' ('ExpiredDaysAgo=' + [math]::Abs($days)) ('Subject=' + $cert.Subject) -Recommendation 'Determine whether it is still bound; renew/remove through the owning team.' -Kind 'Observation' -Source ('Cert:\LocalMachine\' + $store)
            } elseif ($days -le $CertificateWarningDays) {
                Add-Result 'CERTIFICATES' ('Expiring: ' + $thumb) 'WARNING' ('ExpiresInDays=' + $days) ('Subject=' + $cert.Subject) -Recommendation 'Confirm ownership and renewal plan. Bound certificates are evaluated separately below.' -Kind 'Observation' -Source ('Cert:\LocalMachine\' + $store)
            }
        }
    }

    # IIS HTTPS bindings.
    $httpsBindings = @()
    if ((Get-FeatureState 'Web-Server') -eq $true) {
        $bindingsManual = 'Check the HTTPS bindings and their certificates by hand (IIS Manager, or netsh http show sslcert) before the change.'
        if (-not (Get-Module -ListAvailable WebAdministration)) {
            Add-Result 'CERTIFICATES' 'IIS https bindings' 'MANUAL' 'HTTPS bindings not listed (WebAdministration module missing)' -Recommendation $bindingsManual -Kind 'Finding' -Source 'WebAdministration'
        } else {
            try { Import-Module WebAdministration -ErrorAction Stop; $httpsBindings = @(Get-WebBinding -Protocol https -ErrorAction Stop) }
            catch {
                if (-not (Test-NotFoundError $_)) {
                    Write-Swallowed $_
                    Add-Result 'CERTIFICATES' 'IIS https bindings' 'MANUAL' 'HTTPS bindings could not be read' $_.Exception.Message -Recommendation $bindingsManual -Kind 'Finding' -Source 'Get-WebBinding'
                }
            }
        }
    }
    if ($httpsBindings.Count -gt 0) {
        foreach ($b in $httpsBindings) {
            $thumb = ConvertTo-NormalizedThumbprint $b.certificateHash
            $entry = $null
            if ($thumb -and $index.ContainsKey($thumb)) { $entry = $index[$thumb] }
            $item = 'IIS https ' + $b.bindingInformation
            if (-not $thumb) {
                Add-Result 'CERTIFICATES' $item 'MANUAL' 'No certificate hash on binding (possibly Centralized Certificate Store)' ('Store=' + $b.certificateStoreName) -Recommendation 'Verify the binding certificate manually.' -Source 'Get-WebBinding'
            } elseif (-not $entry) {
                Add-Result 'CERTIFICATES' $item 'ACTION' ('Thumbprint=' + $thumb) ('BindingStore=' + $b.certificateStoreName) -Recommendation 'The bound certificate is not in My, WebHosting or Remote Desktop. Fix the binding before IPU.' -Source 'Get-WebBinding'
            } else {
                $days = [math]::Floor(($entry.Cert.NotAfter - (Get-Date)).TotalDays)
                $details = @(('Subject=' + $entry.Cert.Subject),('Store=' + $entry.Store),('DaysLeft=' + $days))
                if ($days -lt 0) { Add-Result 'CERTIFICATES' $item 'ACTION' ('Thumbprint=' + $thumb) $details -Recommendation 'IIS binding uses an expired certificate. Resolve with the application owner before IPU.' -Source 'Get-WebBinding' }
                elseif ($days -le $CertificateWarningDays) { Add-Result 'CERTIFICATES' $item 'WARNING' ('Thumbprint=' + $thumb) $details -Recommendation 'Renew soon and verify the binding after IPU.' -Source 'Get-WebBinding' }
                else { Add-Result 'CERTIFICATES' $item 'OK' ('Thumbprint=' + $thumb) $details -Source 'Get-WebBinding' }
            }
        }
    }

    # RDP listener certificate.
    $rdp = @(Get-CimSafe 'Win32_TSGeneralSetting' "TerminalName='RDP-tcp'" 'root\cimv2\TerminalServices') | Select-Object -First 1
    if ($rdp) {
        $thumb = ConvertTo-NormalizedThumbprint $rdp.SSLCertificateSHA1Hash
        if ($thumb -and $index.ContainsKey($thumb)) {
            $c = $index[$thumb].Cert
            $st = 'OK'; if ($c.NotAfter -lt (Get-Date)) { $st = 'WARNING' }
            Add-Result 'CERTIFICATES' 'RDP-Tcp certificate' $st ('Thumbprint=' + $thumb) @(('Subject=' + $c.Subject),('NotAfter=' + $c.NotAfter.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture))) -Recommendation 'Verify RDP connects after IPU.' -Kind 'Observation' -Source 'Win32_TSGeneralSetting'
        } elseif ($thumb) {
            Add-Result 'CERTIFICATES' 'RDP-Tcp certificate' 'MANUAL' ('Thumbprint=' + $thumb) 'Not found in My, Remote Desktop or WebHosting' -Recommendation 'Verify the RDP certificate configuration.' -Kind 'Finding' -Source 'Win32_TSGeneralSetting'
        }
    }

    # WinRM HTTPS listeners.
    foreach ($listener in @(Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue)) {
        $keys = @{}; foreach ($k in $listener.Keys) { if ($k -match '^(\w+)=(.*)$') { $keys[$matches[1]] = $matches[2] } }
        if ($keys['Transport'] -eq 'HTTPS') {
            $thumb = ''
            try { $thumb = ConvertTo-NormalizedThumbprint (Get-Item (Join-Path $listener.PSPath 'CertificateThumbprint') -ErrorAction Stop).Value } catch { Write-Swallowed $_ }
            Add-Result 'CERTIFICATES' ('WinRM HTTPS ' + $keys['Address']) 'INFO' ('Thumbprint=' + $thumb) -Recommendation 'Confirm WinRM HTTPS still works after IPU if it is used for management.' -Source 'WSMan:\localhost\Listener'
        }
    }

    # HTTP.sys SSL bindings - preserved verbatim as evidence.
    $netsh = Invoke-NativeCapture (Join-Path $env:windir 'System32\netsh.exe') @('http','show','sslcert') 60
    $block = @(); $n = 0
    foreach ($line in @($netsh.Output -split '\r?\n') + @('')) {
        if ($line.Trim()) { $block += $line.Trim() }
        elseif ($block.Count -gt 0) {
            if (Test-HttpSysBindingBlock $block) { $n++; Add-Result 'CERTIFICATES' ('HTTP.sys binding ' + $n) 'INFO' ($block -join ' | ') -Source 'netsh http show sslcert' }
            $block = @()
        }
        else { $block = @() }
    }
}

function Invoke-AgentsCheck {
    $matches_ = Find-DetectionMatch $script:DetectionPatterns.Agents $script:Data.Apps $script:Data.Services
    foreach ($pattern in $script:DetectionPatterns.Agents) {
        $m = @($matches_ | Where-Object { $_.Label -eq $pattern.Label }) | Select-Object -First 1
        if (-not $m) {
            Add-Result 'AGENTS' $pattern.Label 'MANUAL' 'Not identified' '' -Recommendation 'Confirm in the backend whether this agent is expected on this server. If it is installed under another name, add the name to the detection patterns.' -Kind 'Observation' -Source 'Uninstall registry, Win32_Service'
            continue
        }
        foreach ($app in $m.Apps) { Add-Result 'AGENTS' $pattern.Label 'INFO' $app.Name ('Version=' + $app.Version) -Source 'Uninstall registry' }
        foreach ($svc in $m.Services) {
            $st = 'OK'; if ($svc.State -ne 'Running') { $st = 'WARNING' }
            Add-Result 'AGENTS' ($pattern.Label + ' service') $st $svc.DisplayName @(('State=' + $svc.State),('StartMode=' + $svc.StartMode)) -Recommendation 'A stopped agent will not report after IPU either; investigate before the change.' -Kind 'Observation' -Source 'Win32_Service'
        }
    }
}

function Invoke-AntivirusCheck {
    $target = Get-ReleaseDisplayName $TargetServerVersion
    $protected = $false

    # Microsoft Defender Antivirus. Record WHY its state could not be read
    # instead of silently treating it as absent.
    $defenderService = @($script:Data.Services | Where-Object { $_.Name -eq 'WinDefend' }) | Select-Object -First 1
    if (-not $defenderService) {
        Add-Result 'ANTIVIRUS' 'Microsoft Defender Antivirus' 'INFO' 'Not installed (WinDefend service absent)' -Source 'Win32_Service'
    } elseif (-not (Test-CommandAvailable 'Get-MpComputerStatus')) {
        Add-Result 'ANTIVIRUS' 'Microsoft Defender Antivirus' 'INFO' ('Service ' + $defenderService.State + '; status cmdlet not available on this OS') -Source 'Win32_Service'
    } else {
        try {
            $mp = Get-MpComputerStatus -ErrorAction Stop
            $age = $null
            if ($mp.AntivirusSignatureLastUpdated) { $age = [math]::Floor(((Get-Date) - $mp.AntivirusSignatureLastUpdated).TotalDays) }
            $mode = ''
            if ($mp.PSObject.Properties['AMRunningMode']) { $mode = ', Mode=' + $mp.AMRunningMode }
            $value = 'AVEnabled=' + $mp.AntivirusEnabled + ', RealTime=' + $mp.RealTimeProtectionEnabled + $mode
            if ($mp.AntivirusEnabled -and $mp.RealTimeProtectionEnabled) {
                $protected = $true
                if ($null -ne $age -and $age -le $AVMaxAgeDays) { Add-Result 'ANTIVIRUS' 'Microsoft Defender Antivirus' 'OK' $value ('SignatureAgeDays=' + $age) -Source 'Get-MpComputerStatus' }
                else { Add-Result 'ANTIVIRUS' 'Microsoft Defender Antivirus' 'WARNING' $value ('SignatureAgeDays=' + $age) -Recommendation 'Update Defender signatures before IPU.' -Source 'Get-MpComputerStatus' }
            } else {
                Add-Result 'ANTIVIRUS' 'Microsoft Defender Antivirus' 'INFO' $value 'Passive or disabled - expected when another product is primary.' -Source 'Get-MpComputerStatus'
            }
        } catch {
            Write-Swallowed $_
            Add-Result 'ANTIVIRUS' 'Microsoft Defender Antivirus' 'INFO' ('Service ' + $defenderService.State + ', ' + $defenderService.StartMode) ('Status not readable: ' + $_.Exception.Message) -Recommendation 'Usually means Defender is disabled because another product is primary.' -Source 'Get-MpComputerStatus'
        }
    }

    # Third-party AV/EDR by product name, service and driver.
    $epp = Find-DetectionMatch $script:DetectionPatterns.EndpointProtection $script:Data.Apps $script:Data.Services $script:Data.DriverNames
    $products = @()
    foreach ($m in $epp) {
        $running = @($m.Services | Where-Object { $_.State -eq 'Running' }).Count
        $val = 'Applications=' + @($m.Apps).Count + ', Services=' + @($m.Services).Count + ' (' + $running + ' running), Drivers=' + @($m.Drivers).Count
        if ($m.Label -like 'Microsoft Defender for Endpoint*') {
            $sense = @($m.Services | Where-Object { $_.Name -eq 'Sense' }) | Select-Object -First 1
            $senseState = 'absent'; if ($sense) { $senseState = [string]$sense.State }
            $onboarding = (Get-RegistryValueSafe 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status' 'OnboardingState').Value
            $d = Get-DefenderEndpointDecision $senseState $onboarding
            if (-not $d.Active) {
                Add-Result 'ANTIVIRUS' $m.Label 'INFO' $d.Text (Get-DetectionEvidence $m) -Source 'Win32_Service, Windows Advanced Threat Protection\Status'
                continue
            }
            $val = $d.Text
        }
        $protected = $true
        $products += (Get-DetectionProductName $m)
        Add-Result 'ANTIVIRUS' $m.Label 'WARNING' $val (Get-DetectionEvidence $m) -Recommendation ('Confirm this version supports ' + $target + ' and get the vendor''s IPU procedure. Many AV/EDR agents must be upgraded before, or paused during, Setup; their drivers are a common cause of rollback.') -Source 'Uninstall registry, Win32_Service, drivers' -Link $m.Link -LinkTitle $m.LinkTitle
    }
    $script:Data.EndpointProducts = $products
    if (-not $protected) {
        Add-Result 'ANTIVIRUS' 'EndpointProtection' 'MANUAL' 'No active antivirus or EDR recognised' '' -Recommendation 'Verify endpoint protection manually. If a product is installed under an unknown name, add it to the detection patterns.' -Source 'Get-MpComputerStatus, uninstall registry, services, drivers'
    }

    foreach ($m in (Find-DetectionMatch $script:DetectionPatterns.SecurityTools $script:Data.Apps $script:Data.Services $script:Data.DriverNames)) {
        $tool = Get-SecurityToolDecision @($m.Drivers) $target
        Add-Result 'SECURITY' $m.Label 'WARNING' ('Applications=' + @($m.Apps).Count + ', Services=' + @($m.Services).Count + ', Drivers=' + @($m.Drivers).Count) (Get-DetectionEvidence $m) -Recommendation $tool.Recommendation -Kind $tool.Kind -Source 'Uninstall registry, Win32_Service, drivers'
    }

    if (Test-CommandAvailable 'Get-AppLockerPolicy') {
        try {
            $policy = Get-AppLockerPolicy -Effective -ErrorAction Stop
            $count = 0; foreach ($c in $policy.RuleCollections) { $count += [int]$c.Count }
            if ($count -gt 0) { Add-Result 'SECURITY' 'AppLocker' 'WARNING' ('EffectiveRules=' + $count) '' -Recommendation 'Confirm Windows Setup ($WINDOWS.~BT) and post-upgrade binaries are allowed.' -Source 'Get-AppLockerPolicy' }
            else { Add-Result 'SECURITY' 'AppLocker' 'INFO' 'No effective rules' -Source 'Get-AppLockerPolicy' }
        } catch { Write-Swallowed $_; Add-Result 'SECURITY' 'AppLocker' 'MANUAL' 'The effective AppLocker policy could not be read' $_.Exception.Message -Recommendation 'Check Local Security Policy > Application Control Policies by hand: Setup and the new binaries must be allowed.' -Kind 'Finding' -Source 'Get-AppLockerPolicy' }
    }
    if (Test-CommandAvailable 'Get-BitLockerVolume') {
        try {
            $bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
            if ([string]$bl.ProtectionStatus -eq 'On') { Add-Result 'SECURITY' 'BitLocker C:' 'WARNING' ('Protection=On, Method=' + $bl.EncryptionMethod) '' -Recommendation 'Confirm the recovery key is escrowed and retrievable before IPU.' -Source 'Get-BitLockerVolume' }
            else { Add-Result 'SECURITY' 'BitLocker C:' 'INFO' ('Protection=' + $bl.ProtectionStatus) -Source 'Get-BitLockerVolume' }
        } catch { Write-Swallowed $_; Add-Result 'SECURITY' 'BitLocker C:' 'MANUAL' 'The BitLocker state of C: could not be read' $_.Exception.Message -Recommendation 'Run manage-bde -status C: by hand; confirm the recovery key is escrowed if protection is on.' -Kind 'Finding' -Source 'Get-BitLockerVolume' }
    }
    if (Test-CommandAvailable 'Confirm-SecureBootUEFI') {
        try { Add-Result 'SECURITY' 'SecureBoot' 'INFO' ('Enabled=' + (Confirm-SecureBootUEFI -ErrorAction Stop)) -Source 'Confirm-SecureBootUEFI' }
        catch {
            $sb = Get-SecureBootDecision $_.Exception.GetType().Name $_.Exception.Message
            if ($sb.Kind -eq 'LegacyBios') { Add-Result 'SECURITY' 'SecureBoot' $sb.Status $sb.Value -Source 'Confirm-SecureBootUEFI' }
            else { Write-Swallowed $_; Add-Result 'SECURITY' 'SecureBoot' $sb.Status $sb.Value $_.Exception.Message -Recommendation 'Run Confirm-SecureBootUEFI in an elevated session by hand.' -Kind 'Finding' -Source 'Confirm-SecureBootUEFI' }
        }
    }
    if (Test-CommandAvailable 'Get-Tpm') {
        try { $tpm = Get-Tpm -ErrorAction Stop; Add-Result 'SECURITY' 'TPM' 'INFO' ('Present=' + $tpm.TpmPresent) ('Ready=' + $tpm.TpmReady) -Source 'Get-Tpm' } catch { Write-Swallowed $_; Add-Result 'SECURITY' 'TPM' 'MANUAL' 'The TPM state could not be read' $_.Exception.Message -Recommendation 'Run Get-Tpm (or tpm.msc) by hand.' -Kind 'Finding' -Source 'Get-Tpm' }
    }
    if (@($script:Data.FilterDrivers).Count -gt 0) {
        Add-Result 'SECURITY' 'FileSystemFilterDrivers' 'INFO' ('Count=' + @($script:Data.FilterDrivers).Count) (@($script:Data.FilterDrivers) -join ', ') -Recommendation 'If a previous IPU failed with 0xC1900101 (driver), review the non-Microsoft filter drivers.' -Source 'fltmc filters'
    }
}

# ---------------------------------------------------------------------------
# RDP access / policy evidence (called by the 'rdp' check)
# ---------------------------------------------------------------------------
function Invoke-RdpPolicyAssessment {
    if (-not $EnableRDPPolicyEvidence) {
        Add-Result 'RDP' 'RDPAccessReadiness' 'MANUAL' 'REVIEW' 'Policy evidence disabled in SETTINGS' -Recommendation 'Test RDP end-to-end before relying on it during the change.'
        $script:Data.RdpSummary = 'REVIEW (not assessed)'; $script:Data.DriveRedirection = 'Not assessed'
        return
    }
    $hard = New-Object System.Collections.Generic.List[string]
    $review = New-Object System.Collections.Generic.List[string]
    $driveBlock = New-Object System.Collections.Generic.List[string]

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
    $root = Join-Path (Get-EvidenceFolderPath $EvidenceRoot 'Policy' $PolicyEvidenceRoot) ($script:SafeComputerName + '-IPU-Policy-' + $stamp)
    $lgpoRoot = Join-Path $root 'LGPO-Backup'
    $zip = $root + '.zip'
    $script:Data.PolicyEvidence = $root
    $folderOk = $true
    try {
        $null = Initialize-EvidenceFolder 'Policy'
        $null = Initialize-OutputFolder $root
        New-Item -ItemType Directory -Path $lgpoRoot -Force | Out-Null
    }
    catch { $folderOk = $false; $review.Add('Evidence folder could not be created'); Add-Result 'POLICY_EVIDENCE' 'EvidenceFolder' 'MANUAL' $root $_.Exception.Message -Recommendation 'Make the evidence folder writable and re-run.' -Kind 'Finding' }

    if ($folderOk) {
        # LGPO backup (local policy only; never imports).
        # An empty -LgpoExe skips LGPO on purpose (#150). Windows PowerShell
        # rejects Test-Path with an empty path, so test for it first.
        if (-not $LgpoExe) {
            Add-Result 'POLICY_EVIDENCE' 'LocalGroupPolicyBackup' 'INFO' 'LGPO disabled (-LgpoExe is empty) - local policy backup skipped' -Source 'Parameter'
        } elseif (Test-Path -LiteralPath $LgpoExe -PathType Leaf) {
            $r = Invoke-NativeCapture $LgpoExe @('/b',$lgpoRoot,'/n',('Pre-IPU-' + $stamp)) 120
            $r.Output | Out-File -LiteralPath (Join-Path $root 'LGPO-Backup-Output.txt') -Encoding UTF8
            if ($r.ExitCode -eq 0) { Add-Result 'POLICY_EVIDENCE' 'LocalGroupPolicyBackup' 'OK' $lgpoRoot -Source 'LGPO.exe /b' }
            else { Add-Result 'POLICY_EVIDENCE' 'LocalGroupPolicyBackup' 'MANUAL' ('ExitCode=' + $r.ExitCode) $r.Error -Recommendation 'Review the LGPO output if a restorable local-policy copy is required.' -Kind 'Finding' -Source 'LGPO.exe /b' }
            foreach ($pol in @(
                @{ Scope='Machine'; Mode='/m'; Path=(Join-Path $env:windir 'System32\GroupPolicy\Machine\Registry.pol') },
                @{ Scope='User'; Mode='/u'; Path=(Join-Path $env:windir 'System32\GroupPolicy\User\Registry.pol') })) {
                if (Test-Path -LiteralPath $pol.Path) {
                    $parsed = Join-Path $root ('Local-Policy-' + $pol.Scope + '-RegistryPol.txt')
                    (Invoke-NativeCapture $LgpoExe @('/parse',$pol.Mode,$pol.Path) 60).Output | Out-File -LiteralPath $parsed -Encoding UTF8
                    Add-Result 'POLICY_EVIDENCE' ('LocalRegistryPolicy-' + $pol.Scope) 'INFO' $parsed -Source 'LGPO.exe /parse'
                }
            }
        } else {
            Add-Result 'POLICY_EVIDENCE' 'LocalGroupPolicyBackup' 'INFO' 'LGPO.exe not present - local policy backup skipped' $LgpoExe -Recommendation 'Optional: place LGPO.exe at this path to keep a restorable local-policy backup.' -Source 'File check'
        }

        # Resultant Set of Policy.
        $gpresult = Join-Path $env:windir 'System32\gpresult.exe'
        $gpText = Invoke-NativeCapture $gpresult @('/Scope','Computer','/Z') 180
        $gpText.Output | Out-File -LiteralPath (Join-Path $root 'GPResult-Computer.txt') -Encoding UTF8
        $gpHtml = Invoke-NativeCapture $gpresult @('/Scope','Computer','/H',(Join-Path $root 'GPResult-Computer.html'),'/F') 180
        if ($gpText.ExitCode -eq 0 -or $gpHtml.ExitCode -eq 0) { Add-Result 'POLICY_EVIDENCE' 'ComputerRSoP' 'OK' (Join-Path $root 'GPResult-Computer.html') -Source 'gpresult' }
        else { $review.Add('gpresult did not return computer policy'); Add-Result 'POLICY_EVIDENCE' 'ComputerRSoP' 'MANUAL' ('Exit=' + $gpText.ExitCode + '/' + $gpHtml.ExitCode) -Recommendation 'Collect RSoP manually.' -Kind 'Finding' -Source 'gpresult' }
    }

    $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    $tsPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    $tcpPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'

    $polDeny = Get-RegistryValueSafe $policyPath 'fDenyTSConnections'
    $effDeny = Get-RegistryValueSafe $tsPath 'fDenyTSConnections'
    if ($polDeny.Exists -and [int]$polDeny.Value -eq 1) { $hard.Add('Group Policy disables incoming RDP') }
    if ($effDeny.Exists -and [int]$effDeny.Value -ne 0) { $hard.Add('Incoming RDP is disabled (fDenyTSConnections)') }
    if (-not $effDeny.Exists) { $review.Add('RDP enablement value not found') }
    Add-Result 'RDP' 'RemoteConnections' 'INFO' ('Policy=' + $(if ($polDeny.Exists) { $polDeny.Value } else { 'NotConfigured' })) ('Effective=' + $(if ($effDeny.Exists) { $effDeny.Value } else { 'Unknown' })) -Source 'Terminal Services registry'

    $port = 3389
    $portValue = Get-RegistryValueSafe $tcpPath 'PortNumber'
    if ($portValue.Exists) { $port = [int]$portValue.Value }
    $nla = Get-RegistryValueSafe $tcpPath 'UserAuthentication'
    $script:Data.NlaState = 'Unknown'
    if ($nla.Exists) { $script:Data.NlaState = $(if ([int]$nla.Value -eq 0) { 'Off' } else { 'On' }) }
    if ($nla.Exists -and $script:Data.Snapshot) { $script:Data.Snapshot.Nla = $script:Data.NlaState }
    Add-Result 'RDP' 'Listener' 'INFO' ('Port=' + $port) ('NLA=' + $(if ($nla.Exists) { $nla.Value } else { 'Unknown' })) -Source 'RDP-Tcp registry'
    if ($nla.Exists -and [int]$nla.Value -eq 0) {
        $nlaPolicy = Get-RegistryValueSafe $policyPath 'UserAuthentication'
        if ($nlaPolicy.Exists) {
            Add-Result 'RDP' 'NetworkLevelAuthentication' 'WARNING' 'Disabled' 'Not an IPU blocker - a security observation. Set by Group Policy.' -Recommendation 'RDP accepts connections before the user is authenticated. NLA is set by Group Policy: change the GPO (Require user authentication for remote connections by using Network Level Authentication), not the server.' -Kind 'Observation' -Source 'Terminal Services policy UserAuthentication'
        } else {
            Add-Result 'RDP' 'NetworkLevelAuthentication' 'WARNING' 'Disabled' 'Not an IPU blocker - a security observation.' -Recommendation 'RDP accepts connections before the user is authenticated. Enable NLA unless a documented client requirement prevents it.' -Kind 'Observation' -Source 'RDP-Tcp UserAuthentication' -Command (Get-RecommendationCommand 'EnableNla').Command -CommandKind 'Change'
        }
    }

    $svc = @($script:Data.Services | Where-Object { $_.Name -eq 'TermService' }) | Select-Object -First 1
    if (-not $svc) { $hard.Add('TermService not found') }
    elseif ($svc.StartMode -eq 'Disabled') { $hard.Add('TermService is disabled') }
    elseif ($svc.State -ne 'Running') { $review.Add('TermService is not running') }

    $listening = $false; $listenerUnknown = $false
    if (Test-CommandAvailable 'Get-NetTCPConnection') {
        try { $listening = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction Stop).Count -gt 0 }
        catch {
            # No listener raises ObjectNotFound; any other error means the query failed, which says nothing about the port (#242).
            if (-not (Test-NotFoundError $_)) { $listenerUnknown = $true; Write-Swallowed $_; $review.Add('The listener query failed: ' + $_.Exception.Message) }
        }
    }
    if (-not $listening -and -not $listenerUnknown) { $hard.Add('Nothing listening on TCP/' + $port) }

    # Firewall: only relevant when at least one profile is enabled.
    if (Test-CommandAvailable 'Get-NetFirewallRule') {
        try {
            $enabledProfiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop | Where-Object { [string]$_.Enabled -eq 'True' })
            if ($enabledProfiles.Count -eq 0) {
                Add-Result 'RDP' 'FirewallRDPAllow' 'INFO' 'Windows Firewall disabled on all profiles' -Source 'Get-NetFirewallProfile'
            } else {
                $rules = @(Get-NetFirewallRule -PolicyStore ActiveStore -ErrorAction Stop | Where-Object { [string]$_.Direction -eq 'Inbound' -and [string]$_.Enabled -eq 'True' -and [string]$_.Action -eq 'Allow' -and ($_.Name -like 'RemoteDesktop*' -or $_.DisplayGroup -match 'Remote Desktop') })
                if ($rules.Count -gt 0) { Add-Result 'RDP' 'FirewallRDPAllow' 'OK' ('EnabledAllowRules=' + $rules.Count) -Source 'Get-NetFirewallRule' }
                else { $review.Add('No enabled standard Remote Desktop firewall rule (a custom rule may exist)'); Add-Result 'RDP' 'FirewallRDPAllow' 'WARNING' 'No enabled standard RDP allow rule' -Recommendation 'Check for a custom rule and upstream firewalls.' -Kind 'Observation' -Source 'Get-NetFirewallRule' }
            }
        } catch { $review.Add('Firewall rules could not be read') }
    }

    # User rights. A populated Deny right is normal hardening and is recorded
    # as evidence only; an empty Allow right is a real problem.
    if ($folderOk) {
        $inf = Join-Path $root 'Effective-User-Rights.inf'
        $null = Invoke-NativeCapture (Join-Path $env:windir 'System32\secedit.exe') @('/export','/cfg',$inf,'/areas','USER_RIGHTS','/quiet') 120
        if (Test-Path -LiteralPath $inf) {
            $lines = @(Get-Content -LiteralPath $inf)
            foreach ($right in @('SeRemoteInteractiveLogonRight','SeDenyRemoteInteractiveLogonRight')) {
                $line = @($lines | Where-Object { $_ -match ('^\s*' + $right + '\s*=') }) | Select-Object -First 1
                $accounts = @()
                if ($line) { foreach ($a in @(((($line -split '=',2)[1]).Trim()) -split ',' | Where-Object { $_.Trim() })) { $accounts += (Resolve-PolicyAccountName $a) } }
                if ($right -eq 'SeRemoteInteractiveLogonRight' -and $accounts.Count -eq 0) { $hard.Add('Nobody holds "Allow log on through Remote Desktop Services"') }
                $text = 'No identities'; if ($accounts.Count -gt 0) { $text = $accounts -join ' | ' }
                Add-Result 'RDP' $right 'INFO' $text -Recommendation 'Check the change engineer''s account (and nested groups) against Allow and Deny.' -Source 'secedit /export'
            }
        } else { $review.Add('User rights could not be exported') }
    }
    $rdu = Get-LocalGroupMembersBySid 'S-1-5-32-555'
    Add-Result 'RDP' 'RemoteDesktopUsersGroup' 'INFO' $(if ($rdu.Count -gt 0) { $rdu -join ' | ' } else { 'No members' }) -Source 'Local group S-1-5-32-555'

    # Drive redirection (machine policy, listener, loaded user policies).
    $polCdm = Get-RegistryValueSafe $policyPath 'fDisableCdm'
    $tcpCdm = Get-RegistryValueSafe $tcpPath 'fDisableCdm'
    if ($polCdm.Exists -and [int]$polCdm.Value -eq 1) { $driveBlock.Add('Machine policy fDisableCdm=1') }
    if ($tcpCdm.Exists -and [int]$tcpCdm.Value -eq 1) { $driveBlock.Add('RDP-Tcp fDisableCdm=1') }
    # SilentlyContinue: Loaded user hives only add per-user policy evidence; the machine settings are read above.
    foreach ($sid in @(Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } | ForEach-Object { $_.PSChildName })) {
        $u = Get-RegistryValueSafe ('Registry::HKEY_USERS\' + $sid + '\Software\Policies\Microsoft\Windows NT\Terminal Services') 'fDisableCdm'
        if ($u.Exists -and [int]$u.Value -eq 1) { $driveBlock.Add('User ' + (Resolve-PolicyAccountName $sid) + ' fDisableCdm=1') }
    }

    if ($hard.Count -gt 0) {
        $script:Data.RdpSummary = 'NO-GO: ' + ($hard -join '; ')
        Add-Result 'RDP' 'RDPAccessReadiness' 'ACTION' 'NO-GO' @(($hard -join ' | '),($review -join ' | ')) -Recommendation 'Fix the local RDP block and test an end-to-end logon, or plan console-only access for the change.' -Source 'Registry, service, listener, user rights'
    } elseif ($review.Count -gt 0) {
        $script:Data.RdpSummary = 'REVIEW: ' + ($review -join '; ')
        Add-Result 'RDP' 'RDPAccessReadiness' 'MANUAL' 'REVIEW' ($review -join ' | ') -Recommendation 'Test an end-to-end RDP logon with the account that will be used in the change window.' -Source 'Registry, service, listener, firewall'
    } else {
        $script:Data.RdpSummary = 'GO (no local blocker)'
        Add-Result 'RDP' 'RDPAccessReadiness' 'OK' 'GO' 'No local RDP blocker detected' -Recommendation 'Upstream firewalls, PAM and credentials are outside this check.' -Source 'Registry, service, listener, firewall'
    }
    if ($driveBlock.Count -gt 0) {
        $script:Data.DriveRedirection = 'BLOCKED: ' + ($driveBlock -join '; ')
        Add-Result 'RDP' 'DriveRedirection' 'WARNING' 'BLOCKED' ($driveBlock -join ' | ') -Recommendation 'If you plan to copy media or tools over an RDP-mapped drive, use another route (SA file transfer, share, mounted ISO).' -Source 'Terminal Services policy'
    } else {
        $script:Data.DriveRedirection = 'Allowed locally'
        Add-Result 'RDP' 'DriveRedirection' 'OK' 'ALLOWED LOCALLY' 'Destination/client policy not tested' -Source 'Terminal Services policy'
    }

    if ($folderOk) {
        try {
            @($script:Results | Where-Object { $_.Area -in @('RDP','POLICY_EVIDENCE') }) | Export-Csv -LiteralPath (Join-Path $root 'RDP-Policy-Assessment.csv') -Delimiter ';' -NoTypeInformation -Encoding UTF8
        } catch { Write-Swallowed $_ }
        if ($CreatePolicyEvidenceZip) {
            try {
                if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
                New-ZipFromFolder $root $zip
                $script:Data.PolicyEvidence = $zip
            } catch { Add-Result 'POLICY_EVIDENCE' 'EvidenceArchive' 'MANUAL' 'ZIP creation failed' $_.Exception.Message -Recommendation 'Retrieve the folder directly.' -Kind 'Finding' }
        }
        Add-Result 'POLICY_EVIDENCE' 'EvidenceLocation' 'INFO' $script:Data.PolicyEvidence $root -Source 'Local filesystem'
    }
}
