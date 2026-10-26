# Pester 5 tests. Read-only system helpers and evidence copies (registry, accounts, Group Policy, network, IIS, LGPO).
# The script is loaded in library mode by ..\TestSetup.ps1: functions only, nothing is collected.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
param()

BeforeAll { . (Join-Path $PSScriptRoot '..\TestSetup.ps1') }

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'System access helpers (#33)' {
    It 'ConvertTo-SAField keeps the SA result line one field per value' {
        ConvertTo-SAField "a;b`r`nc" | Should -Be 'a,b | c'
        ConvertTo-SAField $null | Should -Be ''
    }
    It 'Test-CommandAvailable finds a cmdlet and not a missing one' {
        Test-CommandAvailable 'Get-Date' | Should -BeTrue
        Test-CommandAvailable 'Get-IpuNoSuchCommand' | Should -BeFalse
    }
    Context 'Read-FileTail' {
        It 'returns nothing for a missing file' {
            $lines = Read-FileTail (Join-Path $TestDrive 'missing.log')
            $lines.Count | Should -Be 0
        }
        It 'returns the lines of a small file' {
            $path = Join-Path $TestDrive 'small.log'
            [IO.File]::WriteAllText($path, "one`r`ntwo`r`nthree")
            (Read-FileTail $path) -join ',' | Should -Be 'one,two,three'
        }
        It 'returns only the end of a file larger than MaxBytes' {
            $path = Join-Path $TestDrive 'large.log'
            [IO.File]::WriteAllText($path, "first-line`nsecond-line`nlast-line")
            $lines = Read-FileTail $path 9
            $lines[-1] | Should -Be 'last-line'
            ($lines -join ',') | Should -Not -Match 'first-line'
        }
        It 'reads a file another process holds open for writing' {
            $path = Join-Path $TestDrive 'open.log'
            $writer = New-Object IO.FileStream($path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
            try {
                $bytes = [Text.Encoding]::ASCII.GetBytes("held-open`n")
                $writer.Write($bytes, 0, $bytes.Length); $writer.Flush()
                (Read-FileTail $path) | Should -Contain 'held-open'
            } finally { $writer.Dispose() }
        }
    }
}

Describe 'Registry and local account helpers (#33)' -Tag 'Integration' {
    It 'Get-RegistryValueSafe reads an existing value' -Skip:($env:OS -ne 'Windows_NT') {
        $r = Get-RegistryValueSafe 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuild'
        $r.Exists | Should -BeTrue
        [string]$r.Value | Should -Match '^\d+$'
    }
    It 'Get-RegistryValueSafe reports a missing value and a missing key without throwing' -Skip:($env:OS -ne 'Windows_NT') {
        (Get-RegistryValueSafe 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'IpuNoSuchValue').Exists | Should -BeFalse
        $r = Get-RegistryValueSafe 'HKLM:\SOFTWARE\IpuNoSuchKey' 'Anything'
        $r.Exists | Should -BeFalse
        $r.Value | Should -BeNullOrEmpty
    }
    It 'Get-InstalledApplication lists named applications, sorted, without duplicates' -Skip:($env:OS -ne 'Windows_NT') {
        $apps = @(Get-InstalledApplication)
        $apps.Count | Should -BeGreaterThan 0
        @($apps | Where-Object { -not $_.Name }).Count | Should -Be 0
        $keys = @($apps | ForEach-Object { $_.Name + '|' + $_.Version })
        @($keys | Sort-Object -Unique).Count | Should -Be $keys.Count
        ($apps[0].PSObject.Properties.Name -join ',') | Should -Be 'Name,Version,Publisher,InstallDate'
    }
    It 'Get-LocalGroupMembersBySid lists the local Administrators' -Skip:($env:OS -ne 'Windows_NT') {
        $members = Get-LocalGroupMembersBySid 'S-1-5-32-544'
        $members.Count | Should -BeGreaterThan 0
        $members[0] | Should -Match '\[WinNT://'
    }
    It 'Get-LocalGroupMembersBySid returns an empty list for an unknown group' -Skip:($env:OS -ne 'Windows_NT') {
        $members = Get-LocalGroupMembersBySid 'S-1-5-32-999'
        $members.Count | Should -Be 0
    }
}

Describe 'Save-IISConfigEvidence (#76)' {
    BeforeAll {
        $script:IisSource = Join-Path $TestDrive 'inetsrv-config'
        New-Item -ItemType Directory -Path $script:IisSource | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:IisSource 'applicationHost.config'), '<configuration><system.applicationHost /></configuration>')
        [IO.File]::WriteAllText((Join-Path $script:IisSource 'administration.config'), '<configuration />')
        [IO.File]::WriteAllText((Join-Path $script:IisSource 'redirection.config'), '<configuration><configSections /><configurationRedirection /></configuration>')
        [IO.File]::WriteAllText((Join-Path $script:IisSource 'notes.txt'), 'not a config file')
        $script:IisBefore = @(Get-ChildItem -LiteralPath $script:IisSource | ForEach-Object { $_.Name + '|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks })
    }
    It 'copies every .config file, hashes applicationHost.config and zips the folder' {
        $dest = Join-Path $TestDrive 'evidence\SRV-IPU-IIS-1'
        $null = New-Item -ItemType Directory -Path (Split-Path $dest) -Force
        $r = Save-IISConfigEvidence -Destination $dest -SourceFolder $script:IisSource
        ($r.Files -join ',') | Should -Be 'administration.config,applicationHost.config,redirection.config'
        $r.Location | Should -Be ($dest + '.zip')
        Test-Path -LiteralPath $r.Location | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $dest 'notes.txt') | Should -BeFalse
        $r.ApplicationHostSha256 | Should -Be (Get-FileHash -LiteralPath (Join-Path $script:IisSource 'applicationHost.config') -Algorithm SHA256).Hash
        $r.SharedConfigPath | Should -Be ''
    }
    It 'does not change the source folder' {
        @(Get-ChildItem -LiteralPath $script:IisSource | ForEach-Object { $_.Name + '|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks }) -join ';' | Should -Be ($script:IisBefore -join ';')
    }
    It 'reports shared configuration from redirection.config' {
        $src = Join-Path $TestDrive 'shared-config'
        New-Item -ItemType Directory -Path $src | Out-Null
        [IO.File]::WriteAllText((Join-Path $src 'redirection.config'), '<configuration><configurationRedirection enabled="true" path="\\files.example.test\iisconfig" /></configuration>')
        $r = Save-IISConfigEvidence -Destination (Join-Path $TestDrive 'shared-copy') -SourceFolder $src -Zip $false
        $r.SharedConfigPath | Should -Be '\\files.example.test\iisconfig'
        $r.Location | Should -Be (Join-Path $TestDrive 'shared-copy')
    }
    It 'throws when there is nothing to copy' {
        $empty = Join-Path $TestDrive 'empty-config'
        New-Item -ItemType Directory -Path $empty | Out-Null
        { Save-IISConfigEvidence -Destination (Join-Path $TestDrive 'never') -SourceFolder $empty } | Should -Throw '*No .config files*'
    }
}

Describe 'Group Policy system helpers on a real Windows host (#80)' -Tag 'Integration' {
    It 'Get-GpResultXml returns RSoP XML that the parser reads, or a clear error' -Skip:($env:OS -ne 'Windows_NT') {
        $xml = $null; $err = $null
        try { $xml = Get-GpResultXml } catch { $err = $_.Exception.Message }
        if ($xml) {
            { ConvertFrom-GpResultXml $xml } | Should -Not -Throw
            @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'IPU-gpresult-*.xml' -ErrorAction SilentlyContinue).Count | Should -Be 0
        } else {
            $err | Should -Not -BeNullOrEmpty
        }
    }
    It 'Get-GroupPolicyLastApplied returns a date or nothing, never throws' -Skip:($env:OS -ne 'Windows_NT') {
        { $script:gpLast = Get-GroupPolicyLastApplied } | Should -Not -Throw
        if ($null -ne $script:gpLast) { $script:gpLast | Should -BeOfType ([datetime]) }
    }
    It 'Get-AdComputerGroup and Get-WmiFilterQuery fail clearly when the host is not in a domain' -Skip:($env:OS -ne 'Windows_NT' -or $env:USERDNSDOMAIN) {
        { Get-AdComputerGroup } | Should -Throw
        { Get-WmiFilterQuery @('{11111111-1111-1111-1111-111111111111}') } | Should -Throw
    }
}

Describe 'LGPO edge cases (#150)' {
    It 'points to the LGPO backup only when this run makes one' {
        Get-LocalPolicyAdvice $true $true | Should -Match 'local policy backup \(LGPO\)'
        Get-LocalPolicyAdvice $false $true | Should -Not -Match 'LGPO'
        Get-LocalPolicyAdvice $true $false | Should -Not -Match 'LGPO'
        Get-LocalPolicyAdvice $false $false | Should -Match 'gpresult /scope computer'
    }
    It 'an empty -LgpoExe means LGPO is not available, without testing an empty path' {
        $LgpoExe = ''
        Test-LgpoAvailable | Should -BeFalse
    }
}

Describe 'Save-NetworkEvidence (#149)' {
    BeforeAll {
        Mock Test-CommandAvailable { $false }
    }
    It 'saves each command output into the folder and zips it' {
        Mock Invoke-NativeCapture { [pscustomobject]@{ ExitCode = 0; Output = ('output of ' + ($ArgumentList -join ' ')); Lines = @('x'); TimedOut = $false; Error = '' } }
        $dest = Join-Path $TestDrive 'evidence\SRV-IPU-Network-1'
        $r = Save-NetworkEvidence -Destination $dest
        ($r.Files -join ',') | Should -Be 'ipconfig-all.txt,route-print.txt,netsh-ipv4-show-config.txt,netsh-interface-dump.txt'
        @($r.Failed).Count | Should -Be 0
        $r.Location | Should -Be ($dest + '.zip')
        Test-Path -LiteralPath $r.Location | Should -BeTrue
        [IO.File]::ReadAllText((Join-Path $dest 'netsh-interface-dump.txt')) | Should -Match 'output of -c interface dump'
        Should -Invoke Invoke-NativeCapture -Times 4 -Exactly
    }
    It 'runs only read-only commands, each with a timeout' {
        Mock Invoke-NativeCapture { [pscustomobject]@{ ExitCode = 0; Output = 'x'; Lines = @('x'); TimedOut = $false; Error = '' } }
        $null = Save-NetworkEvidence -Destination (Join-Path $TestDrive 'ro') -Zip $false -TimeoutSeconds 30
        Should -Invoke Invoke-NativeCapture -Times 4 -Exactly -ParameterFilter {
            $TimeoutSeconds -eq 30 -and (($ArgumentList -join ' ') -in @('/all', 'print', 'interface ipv4 show config', '-c interface dump'))
        }
    }
    It 'a command that times out is listed in Failed; the rest is saved' {
        Mock Invoke-NativeCapture { [pscustomobject]@{ ExitCode = $null; Output = ''; Lines = @(); TimedOut = $true; Error = '' } } -ParameterFilter { $FilePath -like '*route.exe' }
        Mock Invoke-NativeCapture { [pscustomobject]@{ ExitCode = 0; Output = 'x'; Lines = @('x'); TimedOut = $false; Error = '' } } -ParameterFilter { $FilePath -notlike '*route.exe' }
        $r = Save-NetworkEvidence -Destination (Join-Path $TestDrive 'partial') -Zip $false
        @($r.Files).Count | Should -Be 3
        ($r.Failed -join ' ') | Should -Match 'route print: no answer within 60 seconds'
    }
    It 'throws when nothing could be saved' {
        Mock Invoke-NativeCapture { [pscustomobject]@{ ExitCode = 1; Output = ''; Lines = @(); TimedOut = $false; Error = '' } }
        { Save-NetworkEvidence -Destination (Join-Path $TestDrive 'none') -Zip $false } | Should -Throw '*No network command output*'
    }
    It '-RedactExisting leaves the evidence alone: it is not a report' {
        $dir = Join-Path $TestDrive 'share'
        New-Item -ItemType Directory -Path $dir | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'SRV01-IPU-Network-20261013-100000.txt'), 'IPv4 Address. . . : 10.20.30.40')
        Invoke-RedactExisting $dir | Should -Be 1
        @(Get-ChildItem -LiteralPath $dir -Filter 'REDACTED-*').Count | Should -Be 0
    }
}

Describe 'Read-only system helpers (#127: every function runs in a test)' {
    It 'Get-PrerequisiteState never throws and reads this host' {
        $s = Get-PrerequisiteState
        $s.PowerShellVersion | Should -Be $PSVersionTable.PSVersion
        $s.DotNetRelease | Should -BeOfType [int]
        $s.IsElevated | Should -BeOfType [bool]
        , @($s.MissingModules) | Should -BeOfType [object[]]
    }
    It 'Get-AdComputerDn returns a DN or throws with a message (never an empty name)' {
        $r = try { Get-AdComputerDn } catch { 'threw: ' + $_.Exception.Message }
        $r | Should -Match '^(CN=.+|threw: .+)'
    }
    It 'Get-GpoListRegistryEntry reads hexadecimal subkeys (a, b, 10) in order, even with errors terminating (#223)' {
        Mock Get-ChildItem { @('0', '1', '9', 'a', 'b', '10', 'odd') | ForEach-Object { [pscustomobject]@{ PSChildName = $_; PSPath = ('k' + $_) } } }
        Mock Get-ItemProperty { [pscustomobject]@{ DisplayName = ('GPO ' + $LiteralPath.Substring(1)); GPOName = ''; Link = 'Local' } }
        $ErrorActionPreference = 'Stop'
        $list = Get-GpoListRegistryEntry
        ($list | ForEach-Object { $_.DisplayName }) -join ',' | Should -Be 'GPO 0,GPO 1,GPO 9,GPO a,GPO b,GPO 10,GPO odd'
        ConvertFrom-GpoListKeyName 'b' | Should -Be 11
        ConvertFrom-GpoListKeyName '10' | Should -Be 16
        ConvertFrom-GpoListKeyName 'odd' | Should -Be ([int]::MaxValue)
    }
    It 'Get-GpoListRegistryEntry reads the GPO-List keys in numeric order' {
        Mock Get-ChildItem { @([pscustomobject]@{ PSChildName = '10'; PSPath = 'k10' }, [pscustomobject]@{ PSChildName = '2'; PSPath = 'k2' }) }
        Mock Get-ItemProperty { if ($LiteralPath -eq 'k2') { [pscustomobject]@{ DisplayName = 'Second'; GPOName = '{2}'; Link = 'Local' } } else { [pscustomobject]@{ DisplayName = 'Tenth'; GPOName = '{10}'; Link = 'Local' } } }
        $list = Get-GpoListRegistryEntry
        ($list | ForEach-Object { $_.DisplayName }) -join ',' | Should -Be 'Second,Tenth'
    }
    It 'Get-FileCompanyName: empty for a missing file, the company for a real one' {
        Get-FileCompanyName '' | Should -Be ''
        Get-FileCompanyName (Join-Path $TestDrive 'missing.dll') | Should -Be ''
        $exe = (Get-Process -Id $PID).Path
        Get-FileCompanyName $exe | Should -BeOfType [string]
    }
    It 'Get-PrintDriverStoreSize adds up every file under spool\drivers' {
        Mock Get-ChildItem { @([pscustomobject]@{ Length = 1000 }, [pscustomobject]@{ Length = 2500 }) }
        Get-PrintDriverStoreSize | Should -Be 3500
    }
    It 'Get-PrintMonitorInventory lists port monitors and print processors with their company' {
        Mock Get-ChildItem { @([pscustomobject]@{ PSChildName = 'Local Port'; PSPath = 'mon1' }) } -ParameterFilter { $LiteralPath -like '*\Monitors' }
        Mock Get-ChildItem { @([pscustomobject]@{ PSChildName = 'winprint'; PSPath = 'pp1' }) } -ParameterFilter { $LiteralPath -like '*Print Processors' }
        Mock Get-ItemProperty { if ($LiteralPath -eq 'mon1') { [pscustomobject]@{ Driver = 'localspl.dll' } } else { [pscustomobject]@{ Driver = 'winprint.dll' } } }
        Mock Get-FileCompanyName { 'Microsoft Corporation' }
        $items = Get-PrintMonitorInventory
        ($items | ForEach-Object { $_.Type + ':' + $_.Name + ':' + $_.Driver + ':' + $_.Company }) -join ';' | Should -Be 'PortMonitor:Local Port:localspl.dll:Microsoft Corporation;PrintProcessor:winprint:winprint.dll:Microsoft Corporation'
    }
}

Describe 'Evidence folders named after their contents (#198)' {
    It 'each topic has its own folder under EvidenceRoot' -TestCases @(
        @{ Topic = 'Policy' }, @{ Topic = 'IIS' }, @{ Topic = 'Network' }, @{ Topic = 'Printers' }
    ) {
        Get-EvidenceFolderPath 'C:\Temp\IPU-Evidence' $Topic '' | Should -Be (Join-Path 'C:\Temp\IPU-Evidence' $Topic)
    }
    It 'PolicyEvidenceRoot, when set, keeps only the policy evidence where it was' {
        Get-EvidenceFolderPath 'C:\Temp\IPU-Evidence' 'Policy' 'C:\Temp\Tools\PolBackup' | Should -Be 'C:\Temp\Tools\PolBackup'
        Get-EvidenceFolderPath 'C:\Temp\IPU-Evidence' 'Network' 'C:\Temp\Tools\PolBackup' | Should -Be (Join-Path 'C:\Temp\IPU-Evidence' 'Network')
    }
    It 'the README says what is there, that it is unredacted and to copy it off' {
        $t = Get-EvidenceReadmeText
        foreach ($w in 'Policy\', 'IIS\', 'Network\', 'Printers\', 'NOT redacted', 'Copy them off the server') { $t | Should -Match ([regex]::Escape($w)) }
        $t | Should -Match "`r`n$"
        @([char[]]$t | Where-Object { [int]$_ -gt 127 }).Count | Should -Be 0
    }
    It 'creates the root with its README and the topic folder (Windows)' -Skip:($env:OS -ne 'Windows_NT') {
        $EvidenceRoot = Join-Path $TestDrive 'ipu-evidence'
        $PolicyEvidenceRoot = ''
        $f = Initialize-EvidenceFolder 'Network'
        $f | Should -Be (Join-Path $EvidenceRoot 'Network')
        Test-Path -LiteralPath $f -PathType Container | Should -BeTrue
        [IO.File]::ReadAllText((Join-Path $EvidenceRoot 'README.txt')) | Should -Be (Get-EvidenceReadmeText)
        @(Get-BroadFolderReader $EvidenceRoot).Count | Should -Be 0
    }
    It 'with PolicyEvidenceRoot set, the policy folder is created there and no README is written (Windows)' -Skip:($env:OS -ne 'Windows_NT') {
        $EvidenceRoot = Join-Path $TestDrive 'unused-root'
        $PolicyEvidenceRoot = Join-Path $TestDrive 'old-polbackup'
        Initialize-EvidenceFolder 'Policy' | Should -Be $PolicyEvidenceRoot
        Test-Path -LiteralPath $PolicyEvidenceRoot | Should -BeTrue
        Test-Path -LiteralPath $EvidenceRoot | Should -BeFalse
    }
}
