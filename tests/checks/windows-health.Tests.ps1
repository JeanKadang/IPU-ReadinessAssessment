# Pester 5 tests for the check bodies: windows health
# They run against the fake server in FakeServer.ps1 (Windows only).

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'The fake server deliberately shadows system cmdlets for the script under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-ins mirror the parameters the script passes to the real cmdlets.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Stand-ins return fixture objects.')]
param()

BeforeAll { . (Join-Path $PSScriptRoot 'FakeServer.ps1') }

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'Checks on a fake server: windows health' -Skip:($env:OS -ne 'Windows_NT') {
    BeforeEach { Reset-FakeServer }

    Context 'baseline' {
        It 'collects the inventory and classifies the platform' {
            (Invoke-TestCheck 'baseline').Outcome | Should -Be 'Completed'
            $script:Data.Platform.Hypervisor | Should -Be 'VMware'
            $script:Data.FilterDrivers | Should -Contain 'tmeyes'
            $script:Data.DriverNames | Should -Contain 'pvscsi'
            $script:Data.Snapshot.Features | Should -Contain 'FS-FileServer'
            (Get-Row 'ASSESSMENT' 'CollectorVersion')[0].Value | Should -Be $script:CollectorVersion
        }
        It 'fails visibly when an essential query fails' {
            $script:Fake.CimThrow = @('Win32_OperatingSystem')
            $run = Invoke-TestCheck 'baseline'
            $run.Outcome | Should -Be 'Failed'
            (Get-Row 'COLLECTOR' 'Baseline inventory')[0].Status | Should -Be 'MANUAL'
        }
    }

    Context 'feature inventory fails (#238)' {
        BeforeEach {
            $script:Fake.FeaturesThrow = $true
            $script:Data = @{}
            $script:BaselineRun = Invoke-TestCheck 'baseline'
            $script:BaselineRows = $script:Results.ToArray()
        }
        It 'leaves the features unknown, not empty, and the rest of the baseline still runs' {
            $script:BaselineRun.Outcome | Should -Be 'Completed'
            $script:Data.Features | Should -BeNullOrEmpty
            $null -eq $script:Data.Features | Should -BeTrue
            $script:Data.Platform.Hypervisor | Should -Be 'VMware'
            $script:Data.Snapshot | Should -Not -BeNullOrEmpty
            @($script:Data.Snapshot.Features).Count | Should -Be 0
        }
        It 'says so in one MANUAL row' {
            $row = @($script:BaselineRows | Where-Object { $_.Area -eq 'ASSESSMENT' -and $_.Item -eq 'FeatureInventory' })
            $row.Count | Should -Be 1; $row[0].Status | Should -Be 'MANUAL'; $row[0].Kind | Should -Be 'Finding'
            $row[0].Details | Should -Match 'ServerManager provider failed'
        }
        It 'IIS is MANUAL, not "Not installed"' {
            $null = Invoke-TestCheck 'iis'
            (Get-Row 'IIS' 'Web-Server')[0].Status | Should -Be 'MANUAL'
        }
        It 'RDS is MANUAL, not "Not installed"' {
            $null = Invoke-TestCheck 'rds'
            (Get-Row 'RDS' 'RDSRoles')[0].Status | Should -Be 'MANUAL'
            (Get-Row 'RDS' 'RDSessionHost').Count | Should -Be 0
        }
        It 'the cluster check is MANUAL, not "Feature not installed"' {
            $null = Invoke-TestCheck 'cluster'
            (Get-Row 'CLUSTER' 'FailoverClustering')[0].Status | Should -Be 'MANUAL'
        }
        It 'the overall status is not OK' {
            Get-OverallStatus $script:BaselineRows | Should -Be 'MANUAL'
        }
    }

    Context 'number format that does not exist (#139)' {
        It 'says so in the report instead of falling back silently' {
            $script:NumberCultureResolved = [pscustomobject]@{ Culture = [Globalization.CultureInfo]::InvariantCulture; Known = $false }
            $script:Data = @{}
            $null = Invoke-TestCheck 'baseline'
            $row = (Get-Row 'ASSESSMENT' 'NumberCulture')
            $row.Count | Should -Be 1
            $row[0].Status | Should -Be 'INFO'
            $row[0].Value | Should -Match 'is not a culture on this server'
            $script:NumberCultureResolved = Resolve-NumberCulture 'da-DK'
        }
        It 'no row for a known culture' {
            $script:NumberCultureResolved = Resolve-NumberCulture 'da-DK'
            $script:Data = @{}
            $null = Invoke-TestCheck 'baseline'
            (Get-Row 'ASSESSMENT' 'NumberCulture').Count | Should -Be 0
        }
    }

    Context 'upgradepath' {
        It 'a healthy 2016 Standard server has a supported path and the right media' {
            (Invoke-TestCheck 'upgradepath').Outcome | Should -Be 'Completed'
            (Get-Row 'UPGRADE_PATH' 'TargetUpgradePath')[0].Status | Should -Be 'OK'
            (Get-Row 'UPGRADE_PATH' 'InstallLanguage')[0].Status | Should -Be 'OK'
            (Get-Row 'UPGRADE_PATH' 'RecommendedInstallationImage')[0].Value | Should -Be 'Windows Server 2025 Standard (Desktop Experience) - en-US media'
            (Get-Row 'UPGRADE_PATH' 'BootFromVHD').Count | Should -Be 0
            $script:Data.SourceRelease | Should -Be '2016'
            $life = (Get-Row 'UPGRADE_PATH' 'SourceEndOfSupport')[0]
            $life.Status | Should -Be 'INFO'
            $life.Value | Should -Match 'supported until 2027-01-12'
        }
        It 'a 2012 R2 CA server is not told to go to 2025 (#322)' {
            $script:Fake.Cim['Win32_OperatingSystem'].BuildNumber = '9600'
            $script:Fake.Cim['Win32_OperatingSystem'].Caption = 'Microsoft Windows Server 2012 R2 Standard'
            $script:Fake.Cim['Win32_Service'] = @($script:Fake.Cim['Win32_Service']) + @(New-FakeService 'CertSvc')
            Reset-FakeServerKeep
            $TargetServerVersion = '2022'
            $null = Invoke-TestCheck 'upgradepath'
            $r = (Get-Row 'UPGRADE_PATH' 'TargetUpgradePath')[0]
            $r.Status | Should -Be 'BLOCKER'
            $r.Value | Should -Match 'PKI site policy does not allow'
        }
        It 'a 2012 R2 source is out of support: WARNING observation, not a finding (#102)' {
            $script:Fake.Cim['Win32_OperatingSystem'].BuildNumber = '9600'
            $script:Fake.Cim['Win32_OperatingSystem'].Caption = 'Microsoft Windows Server 2012 R2 Standard'
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'upgradepath'
            $life = (Get-Row 'UPGRADE_PATH' 'SourceEndOfSupport')[0]
            $life.Status | Should -Be 'WARNING'
            $life.Kind | Should -Be 'Observation'
            $life.Value | Should -Match 'out of support since 2023-10-10'
            $life.Recommendation | Should -Match 'Extended Security Updates'
            $script:Data.SourceSupport.Ended | Should -BeTrue
        }
        It 'in a post-upgrade run on the target release the path row says so (#158)' {
            $script:Fake.Cim['Win32_OperatingSystem'].BuildNumber = '26100'
            $script:Fake.Cim['Win32_OperatingSystem'].Caption = 'Microsoft Windows Server 2025 Standard'
            Reset-FakeServerKeep
            $AssessmentMode = 'Post'
            $null = Invoke-TestCheck 'upgradepath'
            (Get-Row 'UPGRADE_PATH' 'TargetUpgradePath')[0].Value | Should -Be 'Now Windows Server 2025 (post-upgrade run).'
        }
        It 'a different media language is a BLOCKER' {
            $script:Fake.Registry['HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language|InstallLanguage'] = '0406'
            $TargetMediaLanguage = 'en-US'
            $null = Invoke-TestCheck 'upgradepath'
            $r = (Get-Row 'UPGRADE_PATH' 'InstallLanguage')[0]
            $r.Status | Should -Be 'BLOCKER'
            $r.Value | Should -Match 'Installed=da-DK'
        }
        It 'a server booted from VHD is a BLOCKER' {
            $script:Fake.Disks[0].BusType = 'File Backed Virtual'
            $null = Invoke-TestCheck 'upgradepath'
            (Get-Row 'UPGRADE_PATH' 'BootFromVHD')[0].Status | Should -Be 'BLOCKER'
        }
        It 'a clustered node points to the SPECIAL section (#152)' {
            $script:Fake.Features['Failover-Clustering'] = $true
            $script:Fake.Paths['HKLM:\Cluster'] = $true
            $script:Fake.Cim['Win32_Service'] = @($script:Fake.Cim['Win32_Service']) + @(New-FakeService 'ClusSvc')
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'upgradepath'
            (Get-Row 'UPGRADE_PATH' 'TargetUpgradePath')[0].Value | Should -Match 'SPECIAL'
            $script:Data.IsClustered | Should -BeTrue
        }
    }

    Context 'licensing: an ESU add-on is not the OS licence (#248)' {
        It 'an unlicensed OS with a licensed ESU add-on is not shown as Licensed' {
            $os = $script:Fake.Licensing[0]; $os.LicenseStatus = 5
            $esu = [pscustomobject]@{ Name = 'Windows(R), ServerStandard-ESU-Year1 add-on'; Description = 'Windows(R) Operating System, ESU add-on'; LicenseStatus = 1; LicenseIsAddon = $true; PartialProductKey = 'ZZZZZ'; ProductKeyChannel = 'Volume:MAK'; GracePeriodRemaining = 0 }
            $script:Fake.Licensing = @($esu, $os)
            (Invoke-TestCheck 'licensing').Outcome | Should -Be 'Completed'
            (Get-Row 'LICENSING' 'CurrentActivation')[0].Status | Should -Be 'ACTION'
            (Get-Row 'LICENSING' 'CurrentActivation')[0].Value | Should -Match 'Notification'
            $row = (Get-Row 'LICENSING' 'Add-on licence: Windows(R), ServerStandard-ESU-Year1 add-on')
            $row.Count | Should -Be 1; $row[0].Value | Should -Be 'Licensed'
        }
        It 'a KMS client with 45 days left warns in the check too' {
            $script:Fake.Licensing[0].GracePeriodRemaining = 45 * 1440
            $null = Invoke-TestCheck 'licensing'
            (Get-Row 'LICENSING' 'CurrentActivation')[0].Status | Should -Be 'WARNING'
        }
    }

    Context 'licensing' {
        It 'a licensed KMS client is OK and records the KMS host' {
            (Invoke-TestCheck 'licensing').Outcome | Should -Be 'Completed'
            (Get-Row 'LICENSING' 'CurrentActivation')[0].Status | Should -Be 'OK'
            $script:Data.KmsEndpoint | Should -Be 'kms.example.test:1688'
        }
        It 'a KMS client found via DNS shows the host and the renewal days (#171)' {
            $script:Fake.ItemProperty['HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform'] = [pscustomobject]@{}
            $script:Fake.Licensing[0] | Add-Member -NotePropertyName DiscoveredKeyManagementServiceMachineName -NotePropertyValue 'kms01.corp.example.test' -Force
            $script:Fake.Licensing[0] | Add-Member -NotePropertyName DiscoveredKeyManagementServiceMachinePort -NotePropertyValue 1688 -Force
            $script:Fake.Licensing[0].GracePeriodRemaining = 250000
            $null = Invoke-TestCheck 'licensing'
            $r = (Get-Row 'LICENSING' 'CurrentActivation')[0]
            $r.Status | Should -Be 'OK'
            $r.Value | Should -Be 'Licensed (KMS client), activated by kms01.corp.example.test:1688, found via DNS. Renewal due in 173 days'
            $script:Data.KmsEndpoint | Should -Be 'kms01.corp.example.test:1688'
            $script:Data.RedactLiterals.ContainsKey('kms01') | Should -BeTrue
        }
        It 'an unlicensed server is an ACTION' {
            $script:Fake.Licensing[0].LicenseStatus = 0
            $null = Invoke-TestCheck 'licensing'
            (Get-Row 'LICENSING' 'CurrentActivation')[0].Status | Should -Be 'ACTION'
        }
        It 'an OEM licence gets a WARNING' {
            $script:Fake.Licensing[0].ProductKeyChannel = 'OEM:DM'
            $null = Invoke-TestCheck 'licensing'
            (Get-Row 'LICENSING' 'OEMLicense')[0].Status | Should -Be 'WARNING'
        }
        It 'a failed query is MANUAL, never "unlicensed"' {
            $script:Fake.LicensingThrow = $true
            $null = Invoke-TestCheck 'licensing'
            (Get-Row 'LICENSING' 'CurrentActivation')[0].Status | Should -Be 'MANUAL'
        }
    }

    Context 'pendingreboot' {
        It 'a clean server is OK with a short uptime' {
            (Invoke-TestCheck 'pendingreboot').Outcome | Should -Be 'Completed'
            (Get-Row 'WINDOWS_HEALTH' 'PendingReboot')[0].Status | Should -Be 'OK'
            (Get-Row 'WINDOWS_HEALTH' 'Uptime')[0].Status | Should -Be 'OK'
        }
        It 'a CBS reboot flag is an ACTION' {
            $script:Fake.Paths['HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'] = $true
            $null = Invoke-TestCheck 'pendingreboot'
            (Get-Row 'WINDOWS_HEALTH' 'PendingReboot')[0].Status | Should -Be 'ACTION'
        }
        It 'pending file renames are a WARNING that names the file' {
            $script:Fake.Registry['HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager|PendingFileRenameOperations'] = @('\??\C:\Program Files\Example\agent.dll', '')
            $null = Invoke-TestCheck 'pendingreboot'
            $r = (Get-Row 'WINDOWS_HEALTH' 'PendingReboot')[0]
            $r.Status | Should -Be 'WARNING'
            $r.Details | Should -Match 'C:\\Program Files\\Example\\agent\.dll'
        }
        It 'a pending computer rename and a ConfigMgr reboot are reported' {
            $script:Fake.Registry['HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName|ComputerName'] = 'SRV02'
            $script:Fake.CimMethod['DetermineIfRebootPending'] = [pscustomobject]@{ RebootPending = $true; IsHardRebootPending = $false }
            $null = Invoke-TestCheck 'pendingreboot'
            $r = (Get-Row 'WINDOWS_HEALTH' 'PendingReboot')[0]
            $r.Value | Should -Match 'SRV01 -> SRV02'
            $r.Value | Should -Match 'ConfigMgr'
        }
        It 'in a post-upgrade run, MSI rollback leftovers alone are INFO (#158)' {
            $script:Fake.Registry['HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager|PendingFileRenameOperations'] = @('\??\C:\Config.Msi\1bc393.rbf', '', '\??\C:\Config.Msi\1bc399.rbf', '')
            $AssessmentMode = 'Post'
            $null = Invoke-TestCheck 'pendingreboot'
            (Get-Row 'WINDOWS_HEALTH' 'PendingReboot')[0].Status | Should -Be 'INFO'
        }
        It 'a long uptime is a WARNING' {
            $script:Fake.Cim['Win32_OperatingSystem'].LastBootUpTime = (Get-Date).AddDays(-120)
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'pendingreboot'
            (Get-Row 'WINDOWS_HEALTH' 'Uptime')[0].Status | Should -Be 'WARNING'
        }
    }

    Context 'patchlevel' {
        It 'a recent update is OK and names the newest KB' {
            (Invoke-TestCheck 'patchlevel').Outcome | Should -Be 'Completed'
            $r = (Get-Row 'WINDOWS_HEALTH' 'LatestUpdate')[0]
            $r.Status | Should -Be 'OK'
            $r.Value | Should -Match 'KB5000002'
        }
        It 'old updates are a WARNING' {
            $script:Fake.HotFixes = @([pscustomobject]@{ HotFixID = 'KB4000001'; InstalledOn = (Get-Date).AddDays(-200) })
            $null = Invoke-TestCheck 'patchlevel'
            $r = (Get-Row 'WINDOWS_HEALTH' 'LatestUpdate')[0]
            $r.Status | Should -Be 'WARNING'
            ($r.Recommendation -match 'out of support') | Should -BeFalse
        }
        It 'old updates on an out-of-support source say why (#102)' {
            $script:Fake.HotFixes = @([pscustomobject]@{ HotFixID = 'KB4000001'; InstalledOn = (Get-Date).AddDays(-900) })
            $script:Data.SourceSupport = Get-SupportLifecycleDecision '2012R2' (Get-Date)
            $null = Invoke-TestCheck 'patchlevel'
            $r = (Get-Row 'WINDOWS_HEALTH' 'LatestUpdate')[0]
            $r.Status | Should -Be 'WARNING'
            $r.Recommendation | Should -Match 'out of support since 2023-10-10'
            ($r.Details -join ' ') | Should -Match 'SourceOutOfSupportSince=2023-10-10'
        }
        It 'no dated history is MANUAL' {
            $script:Fake.HotFixes = @()
            $null = Invoke-TestCheck 'patchlevel'
            (Get-Row 'WINDOWS_HEALTH' 'LatestUpdate')[0].Status | Should -Be 'MANUAL'
        }
    }

    Context 'history' {
        It 'no upgrade evidence on a clean install' {
            (Invoke-TestCheck 'history').Outcome | Should -Be 'Completed'
            (Get-Row 'UPGRADE_HISTORY' 'PreviousUpgradeEvidence')[0].Status | Should -Be 'INFO'
            (Get-Row 'UPGRADE_HISTORY' 'OSInstallDate')[0].Value | Should -Be '2019-03-01'
            (Get-Row 'UPGRADE_HISTORY' 'SetupWorkingFolder').Count | Should -Be 0
        }
        It 'Source OS keys show a previous upgrade' {
            $key = [pscustomobject]@{ PSChildName = 'Source OS (Updated on 1/2/2022 03:04:05)'; PSPath = 'HKLM:\SYSTEM\Setup\Source OS (Updated on 1/2/2022 03:04:05)'; Name = 'HKEY_LOCAL_MACHINE\SYSTEM\Setup\Source OS' }
            $script:Fake.Children['HKLM:\SYSTEM\Setup'] = @($key)
            $script:Fake.ItemProperty[$key.PSPath] = [pscustomobject]@{ ProductName = 'Windows Server 2012 R2 Standard'; CurrentBuild = '9600'; InstallDate = 1400000000 }
            $null = Invoke-TestCheck 'history'
            $r = (Get-Row 'UPGRADE_HISTORY' 'PreviousUpgradeEvidence')[0]
            $r.Status | Should -Be 'WARNING'
            $r.Kind | Should -Be 'Observation'
            (Get-Row 'UPGRADE_HISTORY' $key.PSChildName)[0].Value | Should -Match '2012 R2'
        }
        It 'in a post-upgrade run the previous-upgrade evidence is expected: INFO (#158)' {
            $key = [pscustomobject]@{ PSChildName = 'Source OS (Updated on 1/2/2022 03:04:05)'; PSPath = 'HKLM:\SYSTEM\Setup\Source OS (Updated on 1/2/2022 03:04:05)'; Name = 'HKEY_LOCAL_MACHINE\SYSTEM\Setup\Source OS' }
            $script:Fake.Children['HKLM:\SYSTEM\Setup'] = @($key)
            $script:Fake.ItemProperty[$key.PSPath] = [pscustomobject]@{ ProductName = 'Windows Server 2016 Standard'; CurrentBuild = '14393'; InstallDate = 1400000000 }
            $AssessmentMode = 'Post'
            $null = Invoke-TestCheck 'history'
            $r = (Get-Row 'UPGRADE_HISTORY' 'PreviousUpgradeEvidence')[0]
            $r.Status | Should -Be 'INFO'
            $r.Recommendation | Should -Match 'just been upgraded'
        }
        It 'an unreadable Setup key fails the check instead of reporting a clean install (#306)' {
            $script:Fake.Fail['Get-ChildItem:HKLM:\SYSTEM\Setup'] = 'Error'
            (Invoke-TestCheck 'history').Outcome | Should -Be 'Failed'
            (Get-Row 'UPGRADE_HISTORY' 'PreviousUpgradeEvidence').Count | Should -Be 0
        }
        It 'a leftover Setup working folder is shown' {
            $script:Fake.Paths['C:\$WINDOWS.~BT'] = $true
            $null = Invoke-TestCheck 'history'
            (Get-Row 'UPGRADE_HISTORY' 'SetupWorkingFolder').Count | Should -Be 1
        }
    }

    Context 'dism' {
        BeforeEach { $script:SlowSecondsLeft = 3000 }
        It 'a healthy component store is OK' {
            (Invoke-TestCheck 'dism').Outcome | Should -Be 'Completed'
            (Get-Row 'WINDOWS_HEALTH' 'DISM ScanHealth')[0].Status | Should -Be 'OK'
            @($script:Fake.NativeCalls | Where-Object { $_.Exe -eq 'dism.exe' })[0].Args | Should -Contain '/ScanHealth'
        }
        It 'truncated output with no verdict is MANUAL, never OK' {
            $script:Fake.Native['dism.exe'] = @{ ExitCode = 0; Output = "Deployment Image Servicing and Management tool`r`nVersion: 10.0.14393.0`r`n[=====      20.0%" }
            $null = Invoke-TestCheck 'dism'
            (Get-Row 'WINDOWS_HEALTH' 'DISM ScanHealth')[0].Status | Should -Be 'MANUAL'
        }
        It 'a plain error code is MANUAL and does not recommend a repair (#249)' {
            $script:Fake.Native['dism.exe'] = @{ ExitCode = 87; Output = 'Error: 87' }
            $null = Invoke-TestCheck 'dism'
            $r = (Get-Row 'WINDOWS_HEALTH' 'DISM ScanHealth')[0]
            $r.Status | Should -Be 'MANUAL'
            $r.Recommendation | Should -Not -Match 'RestoreHealth'
            $r.Details | Should -Match 'Basis=DISM error, exit code 87'
        }
        It 'a pending servicing operation is a WARNING to restart (#249)' {
            $script:Fake.Native['dism.exe'] = @{ ExitCode = -2146498513; Output = 'Error: 0x800f082f' }
            $null = Invoke-TestCheck 'dism'
            $r = (Get-Row 'WINDOWS_HEALTH' 'DISM ScanHealth')[0]
            $r.Status | Should -Be 'WARNING'
            $r.Recommendation | Should -Match 'restart'
        }
        It 'a repairable store is an ACTION' {
            $script:Fake.Native['dism.exe'] = @{ ExitCode = 0; Output = 'The component store is repairable.' }
            $null = Invoke-TestCheck 'dism'
            (Get-Row 'WINDOWS_HEALTH' 'DISM ScanHealth')[0].Status | Should -Be 'ACTION'
        }
        It 'a timeout that could not stop the process says so (#244)' {
            $script:Fake.Native['dism.exe'] = @{ TimedOut = $true; StillRunning = $true; ExitCode = $null; Output = '' }
            (Invoke-TestCheck 'dism').Outcome | Should -Be 'TimedOut'
            (Get-Row 'WINDOWS_HEALTH' 'DISM ScanHealth')[0].Details | Should -Match 'could not be stopped'
            $script:Fake.Native['dism.exe'] = @{ TimedOut = $true; ExitCode = $null; Output = '' }
            $null = Invoke-TestCheck 'dism'
            (Get-Row 'WINDOWS_HEALTH' 'DISM ScanHealth')[0].Details | Should -Not -Match 'could not be stopped'
        }
        It 'a timeout is MANUAL and marks the run TimedOut' {
            $script:Fake.Native['dism.exe'] = @{ TimedOut = $true; ExitCode = $null; Output = '' }
            (Invoke-TestCheck 'dism').Outcome | Should -Be 'TimedOut'
            (Get-Row 'WINDOWS_HEALTH' 'DISM ScanHealth')[0].Status | Should -Be 'MANUAL'
        }
        It 'can be skipped by configuration' {
            $RunDISMScanHealth = $false
            (Invoke-TestCheck 'dism').Outcome | Should -Be 'Skipped'
            @($script:Fake.NativeCalls | Where-Object { $_.Exe -eq 'dism.exe' }).Count | Should -Be 0
        }
    }

    Context 'sfc' {
        BeforeEach { $script:SlowSecondsLeft = 3000 }
        It 'clean English output is OK' {
            (Invoke-TestCheck 'sfc').Outcome | Should -Be 'Completed'
            (Get-Row 'WINDOWS_HEALTH' 'SFC VerifyOnly')[0].Status | Should -Be 'OK'
        }
        It 'truncated localized output without CBS evidence is MANUAL' {
            $script:Fake.Native['sfc.exe'] = @{ ExitCode = 0; Output = 'Systemscanningen startes. Denne proces tager noget tid.' }
            $null = Invoke-TestCheck 'sfc'
            (Get-Row 'WINDOWS_HEALTH' 'SFC VerifyOnly')[0].Status | Should -Be 'MANUAL'
        }
        It 'localized output is classified from CBS.log lines of this run' {
            $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            $script:Fake.Native['sfc.exe'] = @{ ExitCode = 0; Output = 'Windows-ressourcebeskyttelse fandt ingen problemer.' }
            $script:Fake.CbsLines = @('2001-01-01 00:00:00, Info  CSI  00000001 [SR] Verify complete', ($now + ', Info  CSI  00000099 [SR] Verify complete'))
            $null = Invoke-TestCheck 'sfc'
            $r = (Get-Row 'WINDOWS_HEALTH' 'SFC VerifyOnly')[0]
            $r.Status | Should -Be 'OK'
            $r.Value | Should -Match 'Basis=CBS.log'
        }
        It 'a repair waiting for a reboot is a WARNING with reboot advice, not repair advice (#159)' {
            $script:Fake.Native['sfc.exe'] = @{ ExitCode = 1; Output = 'There is a system repair pending which requires reboot to complete.  Restart Windows and run sfc again.' }
            $null = Invoke-TestCheck 'sfc'
            $r = (Get-Row 'WINDOWS_HEALTH' 'SFC VerifyOnly')[0]
            $r.Status | Should -Be 'WARNING'
            $r.Recommendation | Should -Match 'Reboot'
            $r.Recommendation | Should -Not -Match 'RestoreHealth'
        }
        It 'a timeout is MANUAL' {
            $script:Fake.Native['sfc.exe'] = @{ TimedOut = $true; ExitCode = $null; Output = '' }
            (Invoke-TestCheck 'sfc').Outcome | Should -Be 'TimedOut'
        }
    }

    Context 'compatscan' {
        BeforeEach {
            $script:SlowSecondsLeft = 6000
            $script:Media = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $script:Media 'sources') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:Media 'setup.exe') -Value 'fake'
            Set-Content -LiteralPath (Join-Path $script:Media 'sources\install.wim') -Value 'fake'
            $script:Fake.Images = @(
                [pscustomobject]@{ ImageIndex = 1; ImageName = 'Windows Server 2025 Standard'; EditionId = 'ServerStandard'; InstallationType = 'Server Core'; Languages = @('en-US') },
                [pscustomobject]@{ ImageIndex = 2; ImageName = 'Windows Server 2025 Standard (Desktop Experience)'; EditionId = 'ServerStandard'; InstallationType = 'Server'; Languages = @('en-US') })
            $script:Data.InstallLanguage = 'en-US'
            $script:Out = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        }
        It 'is skipped when no media is configured' {
            (Invoke-TestCheck 'compatscan').Outcome | Should -Be 'Skipped'
            (Get-Row 'COMPAT_SCAN' 'SetupCompatibilityScan')[0].Status | Should -Be 'INFO'
        }
        It 'a clean scan with the matching image is OK' {
            $TargetMediaPath = $script:Media
            $ReportDirectory = $script:Out
            $script:Fake.Native['setup.exe'] = @{ ExitCode = -1047526896 }
            (Invoke-TestCheck 'compatscan').Outcome | Should -Be 'Completed'
            (Get-Row 'COMPAT_SCAN' 'MatchingImage')[0].Value | Should -Be 'Index 2'
            (Get-Row 'COMPAT_SCAN' 'SetupCompatibilityScan')[0].Status | Should -Be 'OK'
            $setupArgs = @($script:Fake.NativeCalls | Where-Object { $_.Exe -eq 'setup.exe' })[0].Args
            $setupArgs -join ' ' | Should -Match '/compat scanonly /imageindex 2'
        }
        It 'a hard block is an ACTION that names the blocking item' {
            $TargetMediaPath = $script:Media
            $ReportDirectory = $script:Out
            $xml = Join-Path $TestDrive ('CompatData_' + [guid]::NewGuid().ToString('N') + '.xml')
            Set-Content -LiteralPath $xml -Value '<CompatReport><Programs><Program Name="Example Agent 1.0"><CompatibilityInfo BlockingType="Hard" /></Program></Programs></CompatReport>'
            $script:Fake.Children['C:\$WINDOWS.~BT\Sources\Panther'] = @(Microsoft.PowerShell.Management\Get-Item -LiteralPath $xml)
            $script:Fake.Native['setup.exe'] = @{ ExitCode = -1047526904 }
            $null = Invoke-TestCheck 'compatscan'
            $r = (Get-Row 'COMPAT_SCAN' 'SetupCompatibilityScan')[0]
            $r.Status | Should -Be 'ACTION'
            $r.Details | Should -Match 'Hard blocks: Example Agent 1.0'
            Join-Path $script:Out ($script:SafeComputerName + '-CompatData') | Should -Exist
        }
        It 'media without a matching image is an ACTION' {
            $TargetMediaPath = $script:Media
            $ReportDirectory = $script:Out
            $script:Fake.Images = @([pscustomobject]@{ ImageIndex = 1; ImageName = 'Windows Server 2025 Datacenter'; EditionId = 'ServerDatacenter'; InstallationType = 'Server'; Languages = @('en-US') })
            $null = Invoke-TestCheck 'compatscan'
            (Get-Row 'COMPAT_SCAN' 'MatchingImage')[0].Status | Should -Be 'ACTION'
            @($script:Fake.NativeCalls | Where-Object { $_.Exe -eq 'setup.exe' }).Count | Should -Be 0
        }
        It 'the image language in the form Get-WindowsImage lists it ("en-US (Default)") is not a mismatch (#245)' {
            $TargetMediaPath = $script:Media
            $ReportDirectory = $script:Out
            $script:Fake.Images = @($script:Fake.Images | ForEach-Object { $_.Languages = @('en-US (Default)'); $_ })
            $script:Data.InstallLanguage = 'en-US'
            $script:Fake.Native['setup.exe'] = @{ ExitCode = -1047526908 }
            $null = Invoke-TestCheck 'compatscan'
            (Get-Row 'COMPAT_SCAN' 'MediaLanguage').Count | Should -Be 0
            (Get-Row 'COMPAT_SCAN' 'MatchingImage')[0].Status | Should -Be 'OK'
        }
        It 'media in another language is a BLOCKER' {
            $TargetMediaPath = $script:Media
            $ReportDirectory = $script:Out
            $script:Data.InstallLanguage = 'da-DK'
            $script:Fake.Native['setup.exe'] = @{ ExitCode = -1047526908 }
            $null = Invoke-TestCheck 'compatscan'
            (Get-Row 'COMPAT_SCAN' 'MediaLanguage')[0].Status | Should -Be 'BLOCKER'
        }
    }
}
