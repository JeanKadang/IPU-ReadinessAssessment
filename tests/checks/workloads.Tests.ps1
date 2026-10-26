# Pester 5 tests for the check bodies: workloads
# They run against the fake server in FakeServer.ps1 (Windows only).

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'The fake server deliberately shadows system cmdlets for the script under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-ins mirror the parameters the script passes to the real cmdlets.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Stand-ins return fixture objects.')]
param()

BeforeAll { . (Join-Path $PSScriptRoot 'FakeServer.ps1') }

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'Checks on a fake server: workloads' -Skip:($env:OS -ne 'Windows_NT') {
    BeforeEach { Reset-FakeServer }

    Context 'printers (#148)' {
        BeforeEach {
            function New-FakePrintServer {
                $script:Fake.Features['Print-Server'] = $true
                $script:Fake.PrintInv = [pscustomobject]@{
                    Source = 'Get-Printer, Get-PrinterPort, Get-PrinterDriver'
                    Printers = @(
                        [pscustomobject]@{ Name = 'Floor2-Color'; ShareName = 'Floor2C'; Shared = $true; Published = $true; DriverName = 'Example PCL6 Universal'; PortName = 'IP_10.20.40.11' }
                        [pscustomobject]@{ Name = 'Label-Line'; ShareName = ''; Shared = $false; Published = $false; DriverName = 'Example Label v4'; PortName = 'lpr-label' }
                        [pscustomobject]@{ Name = 'Microsoft Print to PDF'; ShareName = ''; Shared = $false; Published = $false; DriverName = 'Microsoft Print To PDF'; PortName = 'PORTPROMPT:' }
                    )
                    Ports = @(
                        [pscustomobject]@{ Name = 'IP_10.20.40.11'; Description = 'Standard TCP/IP Port'; Monitor = 'TCPMON.DLL'; Address = '10.20.40.11'; PortNumber = '9100'; Protocol = '1'; Queue = '' }
                        [pscustomobject]@{ Name = 'lpr-label'; Description = 'LPR Port'; Monitor = 'LPR Port'; Address = 'labelhost.corp.example.test'; PortNumber = ''; Protocol = ''; Queue = 'labels' }
                        [pscustomobject]@{ Name = 'COM1:'; Description = 'Local Port'; Monitor = 'Local Port'; Address = ''; PortNumber = ''; Protocol = ''; Queue = '' }
                    )
                    Drivers = @(
                        [pscustomobject]@{ Name = 'Example PCL6 Universal'; Environment = 'Windows x64'; Major = '3'; Manufacturer = 'Example Inc' }
                        [pscustomobject]@{ Name = 'Example Label v4'; Environment = 'Windows x64'; Major = '4'; Manufacturer = 'Example Labels' }
                        [pscustomobject]@{ Name = 'Example Old x86'; Environment = 'Windows NT x86'; Major = '3'; Manufacturer = 'Example Inc' }
                        [pscustomobject]@{ Name = 'Microsoft Print To PDF'; Environment = 'Windows x64'; Major = '4'; Manufacturer = 'Microsoft' }
                    )
                }
                $script:Fake.PrintComponents = @(
                    [pscustomobject]@{ Type = 'PortMonitor'; Name = 'Standard TCP/IP Port'; Driver = 'tcpmon.dll'; Company = 'Microsoft Corporation' }
                    [pscustomobject]@{ Type = 'PortMonitor'; Name = 'Example Port Monitor'; Driver = 'exmon.dll'; Company = 'Example Inc' }
                    [pscustomobject]@{ Type = 'PrintProcessor'; Name = 'winprint'; Driver = 'winprint.dll'; Company = 'Microsoft Corporation' }
                )
                Reset-FakeServerKeep
            }
        }
        It 'not a print server: one OK row and no backup' {
            (Invoke-TestCheck 'printers').Outcome | Should -Be 'Completed'
            (Get-Row 'PRINTING' 'PrintServer')[0].Value | Should -Be 'Not a print server'
            $script:Data.PrintServer | Should -BeFalse
            $run = Invoke-TestCheck 'printbackup'
            $run.Outcome | Should -Be 'Skipped'
            $run.Message | Should -Be 'Not applicable: not a print server'
            @((Get-CoverageNotice @($run)).Problems).Count | Should -Be 0
        }
        It 'a print server: printers, ports, drivers and components, virtual printers left out' {
            New-FakePrintServer
            (Invoke-TestCheck 'printers').Outcome | Should -Be 'Completed'
            (Get-Row 'PRINTING' 'Printers')[0].Value | Should -Be 'Count=2, shared=1'
            (Get-Row 'PRINTING' 'Printer: Floor2-Color')[0].Details | Should -Match 'Share=Floor2C'
            (Get-Row 'PRINTING' 'Printer: Microsoft Print to PDF').Count | Should -Be 0
            (Get-Row 'PRINTING' 'Port: IP_10.20.40.11')[0].Value | Should -Be 'Standard TCP/IP (RAW)'
            (Get-Row 'PRINTING' 'Port: lpr-label')[0].Status | Should -Be 'WARNING'
            (Get-Row 'PRINTING' 'Port: COM1:').Count | Should -Be 0
            $drv = (Get-Row 'PRINTING' 'PrinterDrivers')[0]
            $drv.Status | Should -Be 'WARNING'
            $drv.Value | Should -Be 'Third-party=2 of 2 (x64)'   # Print to PDF is left out
            $drv.Recommendation | Should -Match '15 January 2026'
            (Get-Row 'PRINTING' 'PrinterDriversX86Only')[0].Details | Should -Be 'Example Old x86'
            (Get-Row 'PRINTING' 'Port monitor: Example Port Monitor')[0].Status | Should -Be 'WARNING'
            (Get-Row 'PRINTING' 'Print processor: winprint').Count | Should -Be 0
            $script:Data.Snapshot.Printers | Should -Be @('Floor2-Color', 'Label-Line')
            $script:Data.Snapshot.PrinterPorts | Should -Be @('IP_10.20.40.11', 'lpr-label')
            @($script:Data.Snapshot.PrinterDrivers | Where-Object { $_.Printer -eq 'Label-Line' })[0].Driver | Should -Be 'Example Label v4'
            foreach ($n in 'Floor2-Color', 'Floor2C', 'Label-Line', 'IP_10.20.40.11', 'lpr-label') { $script:Data.RedactLiterals[$n] | Should -Be 'NAME' }
            $script:Data.RedactLiterals['labelhost.corp.example.test'] | Should -Be 'HOST'
        }
        It 'the LPD service is a WARNING' {
            New-FakePrintServer
            $script:Fake.Features['Print-LPD-Service'] = $true
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'printers'
            (Get-Row 'PRINTING' 'LPD Service')[0].Status | Should -Be 'WARNING'
        }
        It 'printers that cannot be read on a print server are MANUAL' {
            $script:Fake.Features['Print-Server'] = $true
            $script:Fake.PrintInvError = 'The spooler service is not reachable'
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'printers'
            $r = (Get-Row 'PRINTING' 'Printers')[0]
            $r.Status | Should -Be 'MANUAL'
            $r.Details | Should -Match 'spooler'
        }
    }

    Context 'printbackup (#148)' {
        BeforeEach {
            $script:SlowSecondsLeft = 3000
            $script:Fake.Paths[(Join-Path $env:windir 'System32\spool\tools\PrintBrm.exe')] = $true
            $script:Data.PrintServer = $true
            $script:Fake.Cim['Win32_LogicalDisk'] = [pscustomobject]@{ Size = [double]100GB; FreeSpace = [double]50GB }
            $script:Fake.Cim["Win32_LogicalDisk|DeviceID='C:'"].FreeSpace = [double]50GB
        }
        It 'exports with PrintBrm -B into the evidence folder' {
            $EvidenceRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:Fake.Native['printbrm.exe'] = { param($a) [IO.File]::WriteAllText($a[2], 'export'); @{ Output = 'Successfully finished operation.' } }
            (Invoke-TestCheck 'printbackup').Outcome | Should -Be 'Completed'
            $call = @($script:Fake.NativeCalls | Where-Object { $_.Exe -eq 'printbrm.exe' })[0]
            $call.Args[0] | Should -Be '-B'
            $call.Args[1] | Should -Be '-F'
            $row = (Get-Row 'PRINTING' 'PrintBackup')[0]
            $row.Status | Should -Be 'OK'
            $row.Value | Should -BeLike (Join-Path $EvidenceRoot 'Printers\*-IPU-Print-*\*-printers.printerExport')
            $row.Recommendation | Should -Match 'off the server'
            $row.Recommendation | Should -Match 'PrintBrm -R -F'
        }
        It 'not enough free space: skipped as MANUAL with the command to run elsewhere' {
            $script:Fake.DriverStoreBytes = [long]4GB
            $script:Fake.Cim['Win32_LogicalDisk'].FreeSpace = [double]6GB
            $script:Fake.Cim["Win32_LogicalDisk|DeviceID='C:'"].FreeSpace = [double]6GB
            $EvidenceRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $null = Invoke-TestCheck 'printbackup'
            $row = (Get-Row 'PRINTING' 'PrintBackup')[0]
            $row.Status | Should -Be 'MANUAL'
            $row.Value | Should -Match 'not enough free space'
            $row.Command | Should -Match 'PrintBrm\.exe -B -F'
            @($script:Fake.NativeCalls | Where-Object { $_.Exe -eq 'printbrm.exe' }).Count | Should -Be 0
        }
        It 'a timeout is MANUAL, never OK' {
            $EvidenceRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:Fake.Native['printbrm.exe'] = @{ TimedOut = $true; ExitCode = $null }
            $run = Invoke-TestCheck 'printbackup'
            $run.Outcome | Should -Be 'TimedOut'
            (Get-Row 'PRINTING' 'PrintBackup')[0].Status | Should -Be 'MANUAL'
        }
        It 'a failed export is MANUAL' {
            $EvidenceRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:Fake.Native['printbrm.exe'] = @{ ExitCode = 1; Output = 'Operation failed.' }
            $null = Invoke-TestCheck 'printbackup'
            (Get-Row 'PRINTING' 'PrintBackup')[0].Value | Should -Be 'PrintBrm failed (exit code 1)'
        }
        It 'switched off: MANUAL with the command' {
            $EnablePrintBackup = $false
            $null = Invoke-TestCheck 'printbackup'
            $row = (Get-Row 'PRINTING' 'PrintBackup')[0]
            $row.Status | Should -Be 'MANUAL'
            $row.Value | Should -Match 'EnablePrintBackup is off'
        }
        It 'not run after the upgrade' {
            $AssessmentMode = 'Post'
            (Invoke-TestCheck 'printbackup').Message | Should -Be 'Not applicable: not needed after the upgrade'
        }
    }

    Context 'exchange' {
        It 'no Exchange gives no rows' {
            (Invoke-TestCheck 'exchange').Outcome | Should -Be 'Completed'
            $script:Results.Count | Should -Be 0
        }
        It 'Exchange services are a BLOCKER' {
            $script:Fake.Cim['Win32_Service'] = @($script:Fake.Cim['Win32_Service']) + @(New-FakeService 'MSExchangeIS')
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'exchange'
            (Get-Row 'EXCHANGE' 'ExchangeServerRole')[0].Status | Should -Be 'BLOCKER'
        }
        It 'Exchange tools without services are an ACTION' {
            $script:Fake.Registry['HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup|MsiInstallPath'] = 'C:\Program Files\Microsoft\Exchange Server\V15\'
            $null = Invoke-TestCheck 'exchange'
            (Get-Row 'EXCHANGE' 'ExchangeComponents')[0].Status | Should -Be 'ACTION'
        }
    }

    Context 'sql' {
        It 'no SQL Server gives no rows' {
            (Invoke-TestCheck 'sql').Outcome | Should -Be 'Completed'
            $script:Results.Count | Should -Be 0
        }
        It 'SQL Server 2017 is a BLOCKER for a 2025 target' {
            $root = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server'
            $script:Fake.ItemProperty[$root + '\Instance Names\SQL'] = [pscustomobject]@{ MSSQLSERVER = 'MSSQL14.MSSQLSERVER' }
            $script:Fake.ItemProperty[$root + '\MSSQL14.MSSQLSERVER\Setup'] = [pscustomobject]@{ Version = '14.0.3485.1'; Edition = 'Standard Edition' }
            $null = Invoke-TestCheck 'sql'
            $r = (Get-Row 'SQL' 'Database Engine: MSSQLSERVER')[0]
            $r.Status | Should -Be 'BLOCKER'
            $r.Recommendation | Should -Match 'Windows Server 2022'
            $script:Data.SqlSummary | Should -Be 'MSSQLSERVER=SQL Server 2017'
        }
        It 'named instances are redaction literals; the default instance is not (#195)' {
            $root = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server'
            $script:Fake.ItemProperty[$root + '\Instance Names\SQL'] = [pscustomobject]@{ MSSQLSERVER = 'MSSQL16.MSSQLSERVER'; APPDB = 'MSSQL16.APPDB' }
            $script:Fake.ItemProperty[$root + '\MSSQL16.MSSQLSERVER\Setup'] = [pscustomobject]@{ Version = '16.0.1000.6'; Edition = 'Standard Edition' }
            $script:Fake.ItemProperty[$root + '\MSSQL16.APPDB\Setup'] = [pscustomobject]@{ Version = '16.0.1000.6'; Edition = 'Standard Edition' }
            $null = Invoke-TestCheck 'sql'
            $script:Data.RedactLiterals['APPDB'] | Should -Be 'NAME'
            $script:Data.RedactLiterals['MSSQL16.APPDB'] | Should -Be 'NAME'
            $script:Data.RedactLiterals.ContainsKey('MSSQLSERVER') | Should -BeFalse
            $ctx = New-RedactionContext 'SRV01' 'corp.example.test'
            foreach ($k in @($script:Data.RedactLiterals.Keys)) { $ctx.Literals[$k] = $script:Data.RedactLiterals[$k] }
            $t = Protect-ReportText 'APPDB=SQL Server 2022 | MSSQL$APPDB | SQLAgent$APPDB | InstanceId=MSSQL16.APPDB | MSSQLSERVER' $ctx
            $t | Should -Not -Match 'APPDB'
            $t | Should -Match 'MSSQLSERVER'
        }
    }

    Context 'workloads' {
        It 'roles, application workloads and removed features' {
            $script:Fake.Features['SMTP-Server'] = $true
            $script:Fake.Apps += [pscustomobject]@{ Name = 'Eclipse Temurin JDK with Hotspot 17.0.12'; Version = '17.0.12'; Publisher = 'Eclipse Adoptium'; InstallDate = '' }
            Reset-FakeServerKeep
            (Invoke-TestCheck 'workloads').Outcome | Should -Be 'Completed'
            (Get-Row 'WORKLOAD' 'File Server')[0].Status | Should -Be 'WARNING'
            (Get-Row 'WORKLOAD' 'Java runtime')[0].Status | Should -Be 'WARNING'
            (Get-Row 'FEATURE_LIFECYCLE' 'SMTP Server')[0].Status | Should -Be 'ACTION'
            (Get-Row 'ROLES' 'FS-FileServer').Count | Should -Be 1
            (Get-Row 'APPLICATIONS' 'SA Agent').Count | Should -Be 1
        }
        It 'without Get-WindowsFeature the role inventory is MANUAL' {
            $script:Fake.MissingCommands += 'Get-WindowsFeature'
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'workloads'
            (Get-Row 'ROLES' 'Inventory')[0].Status | Should -Be 'MANUAL'
        }
    }

    Context 'fileshares' {
        BeforeEach {
            $script:Fake.Shares = @(
                [pscustomobject]@{ Name = 'ADMIN$'; Path = 'C:\Windows'; Description = 'Remote Admin'; Special = $true },
                [pscustomobject]@{ Name = 'C$'; Path = 'C:\'; Description = 'Default share'; Special = $true },
                [pscustomobject]@{ Name = 'Data'; Path = 'D:\Data'; Description = 'Team data'; Special = $false },
                [pscustomobject]@{ Name = 'print$'; Path = 'C:\Windows\system32\spool\drivers'; Description = 'Printer Drivers'; Special = $false }
            )
            $script:Fake.ShareAccess = @{ 'Data' = @([pscustomobject]@{ AccountName = 'CORP\Data Owners'; AccessRight = 'Full'; AccessControlType = 'Allow' }, [pscustomobject]@{ AccountName = 'Everyone'; AccessRight = 'Read'; AccessControlType = 'Allow' }) }
        }
        It 'lists shares with path and permissions, without administrative shares, and keeps them in the snapshot (#95)' {
            $script:Fake.Features['FS-FileServer'] = $true
            Reset-FakeServerKeep
            (Invoke-TestCheck 'fileshares').Outcome | Should -Be 'Completed'
            $sum = (Get-Row 'FILE_SHARES' 'FileShares')[0]
            $sum.Status | Should -Be 'WARNING'
            $sum.Details | Should -Be 'Data'
            $row = (Get-Row 'FILE_SHARES' 'Share: Data')[0]
            $row.Value | Should -Be 'D:\Data'
            $row.Details | Should -Be 'Path=D:\Data | Description=Team data | Share permissions: CORP\Data Owners: Full; Everyone: Read'
            (Get-Row 'FILE_SHARES' 'Share: ADMIN$').Count | Should -Be 0
            (Get-Row 'FILE_SHARES' 'Share: print$').Count | Should -Be 0
            ($script:Data.Snapshot.Shares -join ',') | Should -Be 'Data'
        }
        It 'shows print$ when the Print Server role is installed (#95)' {
            $script:Fake.Features['Print-Server'] = $true
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'fileshares'
            (Get-Row 'FILE_SHARES' 'Share: print$').Count | Should -Be 1
        }
        It 'the role without shares says so (#95)' {
            $script:Fake.Features['FS-FileServer'] = $true
            $script:Fake.Shares = @($script:Fake.Shares | Where-Object { $_.Special })
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'fileshares'
            $row = (Get-Row 'FILE_SHARES' 'FileShares')[0]
            $row.Status | Should -Be 'INFO'
            $row.Details | Should -Match 'role is installed but shares nothing'
        }
        It 'no role and no shares: one INFO row (#95)' {
            $script:Fake.Features['FS-FileServer'] = $false
            $script:Fake.Shares = @($script:Fake.Shares | Where-Object { $_.Special })
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'fileshares'
            @($script:Results | Where-Object { $_.Area -eq 'FILE_SHARES' }).Count | Should -Be 1
            (Get-Row 'FILE_SHARES' 'FileShares')[0].Status | Should -Be 'INFO'
        }
        It 'missing Get-SmbShare with the role is MANUAL (#95)' {
            $script:Fake.Features['FS-FileServer'] = $true
            $script:Fake.MissingCommands = @($script:Fake.MissingCommands) + 'Get-SmbShare'
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'fileshares'
            (Get-Row 'FILE_SHARES' 'FileShares')[0].Status | Should -Be 'MANUAL'
        }
    }

    Context 'iis' {
        It 'no IIS is OK' {
            (Invoke-TestCheck 'iis').Outcome | Should -Be 'Completed'
            (Get-Row 'IIS' 'Web-Server')[0].Status | Should -Be 'OK'
        }
        It 'IIS lists its sites' {
            $script:Fake.Features['Web-Server'] = $true
            $script:Fake.Modules = @('WebAdministration')
            $binding = [pscustomobject]@{ protocol = 'https'; bindingInformation = '*:443:' }
            $script:Fake.Websites = @([pscustomobject]@{ Name = 'Default Web Site'; State = 'Started'; PhysicalPath = 'C:\inetpub\wwwroot'; Bindings = [pscustomobject]@{ Collection = @($binding) } })
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'iis'
            (Get-Row 'IIS' 'Web-Server')[0].Status | Should -Be 'WARNING'
            (Get-Row 'IIS' 'Site: Default Web Site')[0].Details | Should -Match 'https:\*:443:'
        }
        It 'IIS installed: the configuration is copied into the evidence folder (#76)' {
            $EvidenceRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:Fake.Features['Web-Server'] = $true
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'iis'
            $row = (Get-Row 'IIS' 'ConfigurationCopy')[0]
            $row.Status | Should -Be 'OK'
            $row.Value | Should -BeLike '*-IPU-IIS-*.zip'
            $row.Details | Should -Match 'applicationHost.config SHA256=(AB){32}'
            (Get-Row 'IIS' 'SharedConfiguration').Count | Should -Be 0
            (Get-Row 'IIS' 'Web-Server')[0].Recommendation | Should -Match 'appcmd.exe add backup'
        }
        It 'IIS with shared configuration is a WARNING observation (#76)' {
            $EvidenceRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:Fake.Features['Web-Server'] = $true
            $script:Fake.IISShared = '\\files.example.test\iisconfig'
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'iis'
            $row = (Get-Row 'IIS' 'SharedConfiguration')[0]
            $row.Status | Should -Be 'WARNING'
            $row.Kind | Should -Be 'Observation'
        }
        It 'a failed copy is MANUAL, not silence (#76)' {
            $EvidenceRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:Fake.Features['Web-Server'] = $true
            $script:Fake.IISCopyError = 'Access is denied'
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'iis'
            $row = (Get-Row 'IIS' 'ConfigurationCopy')[0]
            $row.Status | Should -Be 'MANUAL'
            $row.Kind | Should -Be 'Finding'
            $row.Details | Should -Match 'Access is denied'
        }
        It 'switched off: no copy, and said so (#76)' {
            $EnableIISConfigEvidence = $false
            $script:Fake.Features['Web-Server'] = $true
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'iis'
            (Get-Row 'IIS' 'ConfigurationCopy')[0].Status | Should -Be 'INFO'
        }
        It 'no IIS: nothing is copied (#76)' {
            $null = Invoke-TestCheck 'iis'
            (Get-Row 'IIS' 'ConfigurationCopy').Count | Should -Be 0
        }
    }

    Context 'rds' {
        It 'no RDS roles is OK' {
            (Invoke-TestCheck 'rds').Outcome | Should -Be 'Completed'
            (Get-Row 'RDS' 'RDSessionHost')[0].Status | Should -Be 'OK'
        }
        It 'a session host is an ACTION and shows its licensing' {
            $script:Fake.Features['RDS-RD-Server'] = $true
            $script:Fake.Cim['Win32_TerminalServiceSetting'] = [pscustomobject]@{ LicensingType = 4 }
            $script:Fake.CimMethod['GetSpecifiedLicenseServerList'] = [pscustomobject]@{ SpecifiedLSList = @('lic01.corp.example.test') }
            Reset-FakeServerKeep
            $null = Invoke-TestCheck 'rds'
            (Get-Row 'RDS' 'RDSessionHost')[0].Status | Should -Be 'ACTION'
            $lic = (Get-Row 'RDS' 'LicensingConfiguration')[0]
            $lic.Value | Should -Be 'Mode=PerUser'
            $lic.Details | Should -Match 'lic01'
        }
    }

    Context 'eolcandidates (#286)' {
        BeforeEach {
            $script:SavedEolDetection = $script:EolDetection
            $script:ProbeRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $script:ProbeRoot
        }
        AfterEach { $script:EolDetection = $script:SavedEolDetection }
        It 'products in the uninstall list become candidates with their version' {
            $script:Data.Apps = @($script:Data.Apps) + @([pscustomobject]@{ Name = 'PostgreSQL 16'; Version = '16.2-1' }, [pscustomobject]@{ Name = 'Node.js'; Version = '20.11.0' })
            (Invoke-TestCheck 'eolcandidates').Outcome | Should -Be 'Completed'
            ($script:Data.EolCandidates | Where-Object Product -eq 'postgresql').Version | Should -Be '16.2'
            (Get-Row 'APPLICATIONS' 'EOL candidate: PostgreSQL')[0].Value | Should -Be '16.2'
            (Get-Row 'APPLICATIONS' 'EOL candidate: Node.js')[0].Kind | Should -Be 'Observation'
        }
        It 'an unpacked product with no uninstall entry is found by file probe, version from the file' {
            $dir = Join-Path $script:ProbeRoot 'php8'; $null = New-Item -ItemType Directory -Path $dir
            Copy-Item -LiteralPath ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -Destination (Join-Path $dir 'php.exe')
            $script:EolDetection = @(@{ Product = 'php'; Name = 'PHP'; Probe = @(($script:ProbeRoot + '\php*\php.exe')) })
            $null = Invoke-TestCheck 'eolcandidates'
            $c = @($script:Data.EolCandidates | Where-Object Product -eq 'php')
            $c.Count | Should -Be 1; $c[0].Version | Should -Match '^\d+\.\d+'; $c[0].Source | Should -Be 'File probe'
            (Get-Row 'APPLICATIONS' 'EOL candidate: PHP')[0].Details | Should -Match 'php.exe'
        }
        It 'a service executable gives the version' {
            $dir = Join-Path $script:ProbeRoot 'tc'; $null = New-Item -ItemType Directory -Path $dir
            Copy-Item -LiteralPath ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -Destination (Join-Path $dir 'tomcat9.exe')
            $script:Data.Services = @($script:Data.Services) + @([pscustomobject]@{ Name = 'Tomcat9'; PathName = ('"' + (Join-Path $dir 'tomcat9.exe') + '" //RS//Tomcat9') })
            $null = Invoke-TestCheck 'eolcandidates'
            $c = @($script:Data.EolCandidates | Where-Object Product -eq 'tomcat')
            $c.Count | Should -Be 1; $c[0].Source | Should -Be 'Service file'; $c[0].Evidence | Should -Be 'Tomcat9'
        }
        It 'a product found but with no readable version is MANUAL, never silent and never run' {
            $dir = Join-Path $script:ProbeRoot 'nginx-1'; $null = New-Item -ItemType Directory -Path $dir
            Set-Content -LiteralPath (Join-Path $dir 'nginx.exe') -Value 'no version resource'
            $script:EolDetection = @(@{ Product = 'nginx'; Name = 'nginx'; Probe = @(($script:ProbeRoot + '\nginx*\nginx.exe')) })
            $null = Invoke-TestCheck 'eolcandidates'
            @($script:Data.EolCandidates).Count | Should -Be 0
            $r = (Get-Row 'APPLICATIONS' 'EOL detection: nginx')[0]
            $r.Status | Should -Be 'MANUAL'; $r.Kind | Should -Be 'Finding'; $r.Value | Should -Match 'version not known'
            $r.Recommendation | Should -Match 'never runs a product'
        }
        It 'nothing found is no rows and an empty list' {
            $script:EolDetection = @(@{ Product = 'php'; Name = 'PHP'; Probe = @(($script:ProbeRoot + '\php*\php.exe')) })
            $null = Invoke-TestCheck 'eolcandidates'
            @($script:Data.EolCandidates).Count | Should -Be 0
            @($script:Results | Where-Object { $_.Item -like 'EOL *' }).Count | Should -Be 0
        }
        It '.NET Framework comes from the registry Release value' {
            $script:Fake.ItemProperty['HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'] = [pscustomobject]@{ Release = 528040 }
            $null = Invoke-TestCheck 'eolcandidates'
            ($script:Data.EolCandidates | Where-Object Product -eq 'dotnetfx').Version | Should -Be '4.8'
            (Get-Row 'APPLICATIONS' 'EOL candidate: .NET Framework')[0].Value | Should -Be '4.8'
        }
    }

    Context 'EOL verdicts per product (#275)' {
        BeforeEach {
            $script:SnapDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $script:SnapDir
            $script:ScriptFolder = $script:SnapDir
            $EolSnapshotPath = ''
            $ReportDirectory = Join-Path $TestDrive 'no-reports'
            $today = (Get-Date).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
            $json = '{"asOf":"' + $today + '","products":{"php":[{"cycle":"7.4","eol":"2022-11-28","support":"2021-11-28"},{"cycle":"8.9","eol":"2099-01-01","support":"2098-01-01"}],"redis":[]}}'
            Set-Content -LiteralPath (Join-Path $script:SnapDir 'eol-snapshot.json') -Value $json
            $script:Data.EolCandidates = @(
                [pscustomobject]@{ Product = 'php'; Version = '7.4.33'; Source = 'File probe'; Evidence = 'php.exe' },
                [pscustomobject]@{ Product = 'php'; Version = '8.9.1'; Source = 'Uninstall entry'; Evidence = 'PHP 8.9' },
                [pscustomobject]@{ Product = 'redis'; Version = '7.0.1'; Source = 'Service file'; Evidence = 'Redis' })
        }
        It 'each product gets a row: end of life WARNING with advice, supported OK, no data MANUAL' {
            (Invoke-TestCheck 'eolsnapshot').Outcome | Should -Be 'Completed'
            $eol = (Get-Row 'APPLICATIONS' 'EOL: PHP 7.4.33')[0]
            $eol.Status | Should -Be 'WARNING'; $eol.Kind | Should -Be 'Finding'; $eol.Recommendation | Should -Match 'Plan the upgrade'
            $ok = (Get-Row 'APPLICATIONS' 'EOL: PHP 8.9.1')[0]
            $ok.Status | Should -Be 'OK'; $ok.Kind | Should -Be 'Evidence'
            $none = (Get-Row 'APPLICATIONS' 'EOL: Redis 7.0.1')[0]
            $none.Status | Should -Be 'MANUAL'; $none.Kind | Should -Be 'Finding'
            (Get-Row 'APPLICATIONS' 'EOL snapshot')[0].Status | Should -Be 'INFO'
        }
        It 'without a snapshot the products are not checked and nothing says supported' {
            Remove-Item -LiteralPath (Join-Path $script:SnapDir 'eol-snapshot.json')
            $null = Invoke-TestCheck 'eolsnapshot'
            @($script:Results | Where-Object { $_.Item -like 'EOL: *' }).Count | Should -Be 0
            (Get-Row 'APPLICATIONS' 'EOL snapshot')[0].Value | Should -Match 'No EOL snapshot found'
        }
        It 'an unreadable snapshot gives one MANUAL row and no product rows' {
            Set-Content -LiteralPath (Join-Path $script:SnapDir 'eol-snapshot.json') -Value '{ broken'
            $null = Invoke-TestCheck 'eolsnapshot'
            @($script:Results | Where-Object { $_.Item -like 'EOL: *' }).Count | Should -Be 0
            (Get-Row 'APPLICATIONS' 'EOL snapshot')[0].Status | Should -Be 'MANUAL'
        }
        It 'an old snapshot: supported becomes MANUAL, end of life stays a WARNING' {
            Set-Content -LiteralPath (Join-Path $script:SnapDir 'eol-snapshot.json') -Value '{"asOf":"2020-01-01","products":{"php":[{"cycle":"7.4","eol":"2022-11-28"},{"cycle":"8.9","eol":"2099-01-01"}]}}'
            $null = Invoke-TestCheck 'eolsnapshot'
            (Get-Row 'APPLICATIONS' 'EOL: PHP 8.9.1')[0].Status | Should -Be 'MANUAL'
            (Get-Row 'APPLICATIONS' 'EOL: PHP 7.4.33')[0].Status | Should -Be 'WARNING'
            (Get-Row 'APPLICATIONS' 'EOL snapshot')[0].Status | Should -Be 'MANUAL'
        }
        It 'no products found: only the snapshot row' {
            $script:Data.EolCandidates = @()
            $null = Invoke-TestCheck 'eolsnapshot'
            @($script:Results | Where-Object { $_.Item -like 'EOL: *' }).Count | Should -Be 0
        }
    }

    Context 'eolsnapshot (#285)' {
        BeforeEach {
            $script:SnapDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $script:SnapDir
            $script:ScriptFolder = $script:SnapDir
            $EolSnapshotPath = ''
            $ReportDirectory = Join-Path $TestDrive 'no-reports'
        }
        It 'a snapshot next to the script is found and its date shown' {
            $today = (Get-Date).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
            Set-Content -LiteralPath (Join-Path $script:SnapDir 'eol-snapshot.json') -Value ('{"asOf":"' + $today + '","products":{}}')
            (Invoke-TestCheck 'eolsnapshot').Outcome | Should -Be 'Completed'
            $r = (Get-Row 'APPLICATIONS' 'EOL snapshot')[0]
            $r.Status | Should -Be 'INFO'; $r.Value | Should -Be ('EOL snapshot from ' + $today)
        }
        It 'a snapshot in the report folder is found when none is beside the script' {
            $ReportDirectory = $script:SnapDir
            $script:ScriptFolder = Join-Path $TestDrive 'elsewhere'
            Set-Content -LiteralPath (Join-Path $script:SnapDir 'eol-snapshot.json') -Value '{"asOf":"2020-01-01"}'
            $null = Invoke-TestCheck 'eolsnapshot'
            (Get-Row 'APPLICATIONS' 'EOL snapshot')[0].Status | Should -Be 'MANUAL'
        }
        It 'no snapshot anywhere: INFO that names the places it looked' {
            $null = Invoke-TestCheck 'eolsnapshot'
            $r = (Get-Row 'APPLICATIONS' 'EOL snapshot')[0]
            $r.Status | Should -Be 'INFO'; $r.Value | Should -Match 'No EOL snapshot found'
            ($r.Details -join ' ') | Should -Match 'eol-snapshot.json'
        }
        It 'a named path is used first; a missing one is MANUAL' {
            $EolSnapshotPath = Join-Path $script:SnapDir 'missing.json'
            $null = Invoke-TestCheck 'eolsnapshot'
            (Get-Row 'APPLICATIONS' 'EOL snapshot')[0].Status | Should -Be 'MANUAL'
        }
        It 'a file that is not JSON is MANUAL, not a clean result' {
            Set-Content -LiteralPath (Join-Path $script:SnapDir 'eol-snapshot.json') -Value 'not json {'
            (Invoke-TestCheck 'eolsnapshot').Outcome | Should -Be 'Completed'
            $r = (Get-Row 'APPLICATIONS' 'EOL snapshot')[0]
            $r.Status | Should -Be 'MANUAL'; $r.Value | Should -Match 'could not be read'
        }
    }
}
