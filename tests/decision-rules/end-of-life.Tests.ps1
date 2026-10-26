# Pester 5 tests. End-of-life products, verdicts and the snapshot (ADR 0003).
# The script is loaded in library mode by ..\TestSetup.ps1: functions only, nothing is collected.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
param()

BeforeAll { . (Join-Path $PSScriptRoot '..\TestSetup.ps1') }

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'Products for end-of-life checks (#286)' {
    Context 'version and command line parsing' {
        It 'takes the first dotted number' {
            ConvertTo-EolVersionText '16.2-1' | Should -Be '16.2'
            ConvertTo-EolVersionText '3.12.1150.0' | Should -Be '3.12.1150.0'
            ConvertTo-EolVersionText 'Version 8.2.12 (x64)' | Should -Be '8.2.12'
            ConvertTo-EolVersionText 'none' | Should -Be ''
            ConvertTo-EolVersionText '' | Should -Be ''
        }
        It 'reads the executable from a service command line' {
            Get-ExecutablePathFromCommand '"C:\Program Files\Apache Tomcat\bin\tomcat9.exe" //RS//Tomcat9' | Should -Be 'C:\Program Files\Apache Tomcat\bin\tomcat9.exe'
            Get-ExecutablePathFromCommand 'D:\app\ORACLE.EXE ORCL' | Should -Be 'D:\app\ORACLE.EXE'
            Get-ExecutablePathFromCommand 'C:\Program Files\X\x.exe -k run' | Should -Be 'C:\Program Files\X\x.exe'
            Get-ExecutablePathFromCommand '"unterminated' | Should -Be ''
            Get-ExecutablePathFromCommand '' | Should -Be ''
        }
        It '.NET Framework Release values map to the version' {
            ConvertFrom-DotNetFrameworkRelease 533320 | Should -Be '4.8.1'
            ConvertFrom-DotNetFrameworkRelease 528040 | Should -Be '4.8'
            ConvertFrom-DotNetFrameworkRelease 528372 | Should -Be '4.8'
            ConvertFrom-DotNetFrameworkRelease 461814 | Should -Be '4.7.2'
            ConvertFrom-DotNetFrameworkRelease 378389 | Should -Be '4.5'
            ConvertFrom-DotNetFrameworkRelease 378388 | Should -Be ''
            ConvertFrom-DotNetFrameworkRelease 'x' | Should -Be ''
            ConvertFrom-DotNetFrameworkRelease $null | Should -Be ''
        }
    }
    Context 'the detection table' {
        It 'every product in the snapshot except windows-server has a route, .NET Framework by the registry' {
            $snap = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\src\eol-snapshot.json') -Raw | ConvertFrom-Json
            $wanted = @($snap.products.PSObject.Properties.Name | Where-Object { $_ -ne 'windows-server' -and $_ -ne 'dotnetfx' })
            $have = @($script:EolDetection | ForEach-Object { $_.Product })
            foreach ($slug in $wanted) { $have | Should -Contain $slug -Because ($slug + ' needs a detection route (#286)') }
            foreach ($d in $script:EolDetection) {
                ($d.App -or ($d.Service -and $d.Exe) -or $d.Probe) | Should -BeTrue -Because ($d.Product + ' has no route')
                if ($d.Service) { $d.Exe | Should -Not -BeNullOrEmpty -Because ($d.Product + ': a service route needs the executable name') }
            }
        }
        It 'the products that leave no uninstall entry are found by file probe' {
            foreach ($slug in 'php', 'apache-http-server', 'nginx') {
                @($script:EolDetection | Where-Object { $_.Product -eq $slug })[0].Probe | Should -Not -BeNullOrEmpty
            }
        }
        It 'the check never starts a product' {
            $src = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\..\src\assessment\50-checks.ps1'))
            $i = $src.IndexOf("Register-Check -Id 'eolcandidates'"); $j = $src.IndexOf("Register-Check -Id 'checklist'")
            $i | Should -BeGreaterThan 0; $j | Should -BeGreaterThan $i
            $body = $src.Substring($i, $j - $i)
            $body | Should -Not -Match 'Invoke-NativeCapture|Start-Process|Invoke-Expression|Invoke-Command|\bInvoke-Item\b'
        }
    }
    Context 'Find-EolAppCandidate' {
        BeforeAll {
            function New-AppEntry([string]$Name, [string]$Version) { [pscustomobject]@{ Name = $Name; Version = $Version } }
        }
        It 'finds products by their uninstall entry and takes the DisplayVersion' {
            $apps = @((New-AppEntry 'PostgreSQL 16' '16.2-1'), (New-AppEntry 'Node.js' '20.11.0'), (New-AppEntry 'Microsoft SQL Server 2019 (64-bit)' '15.0.2000.5'), (New-AppEntry 'Eclipse Temurin JDK with Hotspot 17.0.9+9 (x64)' '17.0.9.9'))
            $r = @(Find-EolAppCandidate $script:EolDetection $apps)
            ($r | Where-Object Product -eq 'postgresql').Version | Should -Be '16.2'
            ($r | Where-Object Product -eq 'nodejs').Version | Should -Be '20.11.0'
            ($r | Where-Object Product -eq 'mssqlserver').Version | Should -Be '15.0.2000.5'
            ($r | Where-Object Product -eq 'eclipse-temurin').Version | Should -Be '17.0.9.9'
            ($r | Where-Object Product -eq 'nodejs').Source | Should -Be 'Uninstall entry'
        }
        It 'the parts of one Python installation and the SQL Server setup entry are not products of their own' {
            $apps = @((New-AppEntry 'Python 3.12.1 (64-bit)' '3.12.1150.0'), (New-AppEntry 'Python 3.12.1 Core Interpreter (64-bit)' '3.12.1150.0'), (New-AppEntry 'Python 3.12.1 Standard Library (64-bit)' '3.12.1150.0'), (New-AppEntry 'Python Launcher' '3.12.1150.0'), (New-AppEntry 'Microsoft SQL Server 2019 Setup (English)' '15.0.2000.5'))
            $r = @(Find-EolAppCandidate $script:EolDetection $apps)
            @($r | Where-Object Product -eq 'python').Count | Should -Be 1
            @($r | Where-Object Product -eq 'mssqlserver').Count | Should -Be 0
        }
        It 'an entry without a readable version comes back with an empty version' {
            (@(Find-EolAppCandidate $script:EolDetection @((New-AppEntry 'Redis on Windows' ''))))[0].Version | Should -Be ''
        }
        It 'the .NET runtimes, desktop runtime and SDK count; the host does not' {
            $apps = @((New-AppEntry 'Microsoft .NET Runtime - 8.0.4 (x64)' '8.0.4.33311'), (New-AppEntry 'Microsoft Windows Desktop Runtime - 8.0.4 (x64)' '8.0.4.33311'), (New-AppEntry 'Microsoft .NET SDK 8.0.100 (x64)' '8.0.100.0'), (New-AppEntry 'Microsoft ASP.NET Core 8.0.4 - Shared Framework (x64)' '8.0.4.24161'), (New-AppEntry 'Microsoft .NET Host - 8.0.4 (x64)' '8.0.4.33311'))
            @(Find-EolAppCandidate $script:EolDetection $apps | Where-Object Product -eq 'dotnet').Count | Should -Be 3
        }
        It 'no apps, no candidates' { @(Find-EolAppCandidate $script:EolDetection @()).Count | Should -Be 0 }
    }
    Context 'Get-EolServiceTarget' {
        It 'a service of the product gives the executable to read the version from' {
            $svc = @([pscustomobject]@{ Name = 'Tomcat9'; PathName = '"C:\Program Files\Apache Software Foundation\Tomcat 9.0\bin\tomcat9.exe" //RS//Tomcat9' }, [pscustomobject]@{ Name = 'OracleServiceORCL'; PathName = 'D:\app\product\19\bin\ORACLE.EXE ORCL' })
            $r = @(Get-EolServiceTarget $script:EolDetection $svc)
            ($r | Where-Object Product -eq 'tomcat').Path | Should -Match 'tomcat9\.exe$'
            ($r | Where-Object Product -eq 'oracle-database').Path | Should -Be 'D:\app\product\19\bin\ORACLE.EXE'
            ($r | Where-Object Product -eq 'tomcat').Source | Should -Be 'Service file'
            ($r | Where-Object Product -eq 'tomcat').Evidence | Should -Be 'Tomcat9'
        }
        It 'a service run by a wrapper (nssm) is not read as the product' {
            @(Get-EolServiceTarget $script:EolDetection @([pscustomobject]@{ Name = 'nginx'; PathName = 'C:\tools\nssm.exe' })).Count | Should -Be 0
        }
        It 'a service without a command line is left out' {
            @(Get-EolServiceTarget $script:EolDetection @([pscustomobject]@{ Name = 'Redis'; PathName = '' })).Count | Should -Be 0
        }
    }
    Context 'Merge-EolCandidate' {
        It 'one entry per product and version, the first source wins; unknown versions are dropped; sorted' {
            $in = @(
                [pscustomobject]@{ Product = 'php'; Version = '8.2.12'; Source = 'File probe'; Evidence = 'php.exe' },
                [pscustomobject]@{ Product = 'php'; Version = '8.2.12'; Source = 'Uninstall entry'; Evidence = 'PHP 8.2' },
                [pscustomobject]@{ Product = 'nginx'; Version = ''; Source = 'File probe'; Evidence = 'nginx.exe' },
                [pscustomobject]@{ Product = 'dotnet'; Version = '8.0.4'; Source = 'Uninstall entry'; Evidence = 'x' })
            $r = @(Merge-EolCandidate $in)
            $r.Count | Should -Be 2
            $r[0].Product | Should -Be 'dotnet'; $r[1].Product | Should -Be 'php'; $r[1].Source | Should -Be 'File probe'
        }
        It 'nothing in, nothing out' { @(Merge-EolCandidate @()).Count | Should -Be 0 }
    }
    Context 'reading files' {
        It 'Get-FileVersionText reads the version resource of a real executable without running it' {
            $exe = (Get-Process -Id $PID).Path
            $r = Get-FileVersionText $exe
            $r.Version | Should -Match '^\d+\.\d+'; $r.Error | Should -Be ''
        }
        It 'a file with no version resource and a missing file say why' {
            $txt = Join-Path $TestDrive 'plain.exe'; Set-Content -LiteralPath $txt -Value 'not an executable'
            (Get-FileVersionText $txt).Error | Should -Match 'no version resource'
            (Get-FileVersionText (Join-Path $TestDrive 'missing.exe')).Error | Should -Match 'does not exist'
        }
        It 'Resolve-EolProbePath expands variables and a star in a folder name' {
            $root = Join-Path $TestDrive 'probe'
            foreach ($d in 'php7', 'php8', 'other') { $null = New-Item -ItemType Directory -Path (Join-Path $root $d) -Force }
            foreach ($d in 'php7', 'php8') { Set-Content -LiteralPath (Join-Path $root "$d\php.exe") -Value 'x' }
            $env:IPU_TEST_PROBE_ROOT = $root
            try {
                $r = Resolve-EolProbePath '%IPU_TEST_PROBE_ROOT%\php*\php.exe'
                @($r.Paths).Count | Should -Be 2; $r.Error | Should -Be ''
                @((Resolve-EolProbePath '%IPU_TEST_PROBE_ROOT%\php8\php.exe').Paths).Count | Should -Be 1
                @((Resolve-EolProbePath '%IPU_TEST_PROBE_ROOT%\nginx*\nginx.exe').Paths).Count | Should -Be 0
                @((Resolve-EolProbePath '%IPU_TEST_PROBE_ROOT%\missing\sub*\x.exe').Paths).Count | Should -Be 0
            } finally { Remove-Item Env:\IPU_TEST_PROBE_ROOT -ErrorAction SilentlyContinue }
            (Resolve-EolProbePath 'nonsense').Error | Should -Be ''
        }
    }
    It 'the result JSON carries EolCandidates' {
        $script:Data.EolCandidates = @([pscustomobject]@{ Product = 'php'; Version = '8.2.12'; Source = 'File probe'; Evidence = 'php.exe' })
        try {
            $obj = New-AssessmentJsonObject -Results @() -Overall 'OK' -Completed (Get-Date)
            @($obj.EolCandidates).Count | Should -Be 1
            $obj.EolCandidates[0].Product | Should -Be 'php'
            ($obj | ConvertTo-Json -Depth 6) | Should -Match '"EolCandidates"'
        } finally { $script:Data.EolCandidates = @() }
    }
}

Describe 'End-of-life verdicts in the assessment (#275)' {
    BeforeAll {
        $script:Today = [datetime]'2026-10-24'
        $script:Snap = ('{"asOf":"2026-10-01","products":{' +
            '"php":[{"cycle":"8.9","eol":"2099-01-01","support":"2098-01-01"},{"cycle":"7.4","eol":"2022-11-28","support":"2021-11-28"},{"cycle":"8.1","eol":"2026-12-01","support":"2025-11-25"},{"cycle":"8.2","eol":"2028-12-31","support":"2025-12-31"}],' +
            '"nginx":[]}}') | ConvertFrom-Json
        function New-EolCandidate([string]$Product, [string]$Version) { [pscustomobject]@{ Product = $Product; Version = $Version; Source = 'Uninstall entry'; Evidence = 'x' } }
    }
    It 'past end of life is WARNING' {
        $v = Get-EolCandidateVerdict (New-EolCandidate 'php' '7.4.33') $script:Snap $script:Today
        $v.Status | Should -Be 'WARNING'; $v.State | Should -Be 'EndOfLife'; $v.Name | Should -Be 'PHP'
    }
    It 'ending within 180 days is INFO' {
        $v = Get-EolCandidateVerdict (New-EolCandidate 'php' '8.1.2') $script:Snap $script:Today
        $v.Status | Should -Be 'INFO'; $v.State | Should -Be 'EndingSoon'
    }
    It 'security fixes only is INFO, supported is OK' {
        (Get-EolCandidateVerdict (New-EolCandidate 'php' '8.2.12') $script:Snap $script:Today).State | Should -Be 'SecurityOnly'
        $v = Get-EolCandidateVerdict (New-EolCandidate 'php' '8.9.0') $script:Snap $script:Today
        $v.Status | Should -Be 'OK'; $v.State | Should -Be 'Supported'
    }
    It 'a version that matches no release is MANUAL, not supported' {
        $v = Get-EolCandidateVerdict (New-EolCandidate 'php' '5.6.40') $script:Snap $script:Today
        $v.Status | Should -Be 'MANUAL'; $v.Text | Should -Match 'matches no known release'
    }
    It 'a product the snapshot has no releases for is MANUAL' {
        (Get-EolCandidateVerdict (New-EolCandidate 'nginx' '1.25.3') $script:Snap $script:Today).Status | Should -Be 'MANUAL'
        (Get-EolCandidateVerdict (New-EolCandidate 'redis' '7.0.1') $script:Snap $script:Today).Text | Should -Match 'No lifecycle data for Redis'
        (Get-EolCandidateVerdict (New-EolCandidate 'php' '8.2.1') ([pscustomobject]@{ asOf = '2026-10-01' }) $script:Today).Status | Should -Be 'MANUAL'
    }
    It 'a snapshot older than six months cannot confirm support; end of life still shows' {
        $old = ($script:Snap | ConvertTo-Json -Depth 6 | ConvertFrom-Json); $old.asOf = '2025-12-01'
        $v = Get-EolCandidateVerdict (New-EolCandidate 'php' '8.9.0') $old $script:Today
        $v.Status | Should -Be 'MANUAL'; $v.State | Should -Be 'Unconfirmed'; $v.Text | Should -Match 'months old'
        (Get-EolCandidateVerdict (New-EolCandidate 'php' '7.4.33') $old $script:Today).Status | Should -Be 'WARNING'
    }
    It 'the date of a snapshot parsed by PowerShell 7 (a DateTime) is read too' {
        $s = [pscustomobject]@{ asOf = [datetime]'2026-10-01'; products = $script:Snap.products }
        (Get-EolCandidateVerdict (New-EolCandidate 'php' '8.9.0') $s $script:Today).Status | Should -Be 'OK'
    }
    It 'Windows Server is matched by release name (the shared core in the assessment)' {
        ConvertTo-EolWindowsRelease '10.0.20348' | Should -Be '2022'
        ConvertTo-EolWindowsRelease '2012R2' | Should -Be '2012-r2'
        $snap = '{"asOf":"2026-10-01","products":{"windows-server":[{"cycle":"2012-r2","eol":"2023-10-10"}]}}' | ConvertFrom-Json
        (Get-EolCandidateVerdict ([pscustomobject]@{ Product = 'windows-server'; Version = '6.3.9600' }) $snap $script:Today).State | Should -Be 'EndOfLife'
    }
    It 'the EOL core is one source part, built into both scripts' {
        $core = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\..\src\assessment\25-eol-core.ps1'))
        [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\..\src\Windows-IPU-Readiness-Assessment.ps1')).Contains($core) | Should -BeTrue
        [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\..\src\Get-IPUEolStatus.ps1')).Contains($core) | Should -BeTrue
        $core | Should -Match 'function Get-EolDecision'
    }
}

Describe 'EOL snapshot beside the script (#285)' {
    Context 'Get-EolSnapshotSearchPath' {
        It 'looks at the named path, then the script folder, then the report folder' {
            $p = Get-EolSnapshotSearchPath 'D:\Tools\snap.json' 'C:\IPU' 'C:\Temp\Reports'
            $p | Should -Be @('D:\Tools\snap.json', 'C:\IPU\eol-snapshot.json', 'C:\Temp\Reports\eol-snapshot.json')
        }
        It 'a folder as the named path gets the file name added' {
            (Get-EolSnapshotSearchPath 'D:\Tools' 'C:\IPU' '')[0] | Should -Be 'D:\Tools\eol-snapshot.json'
        }
        It 'without a named path the script folder comes first; empty folders are left out; duplicates once' {
            @(Get-EolSnapshotSearchPath '' 'C:\IPU' 'C:\IPU').Count | Should -Be 1
            @(Get-EolSnapshotSearchPath '' '' '').Count | Should -Be 0
        }
    }
    Context 'Get-EolSnapshotDecision' {
        BeforeAll { $script:Today = [datetime]'2026-10-24' }
        It 'a fresh snapshot is an INFO observation with its date' {
            $d = Get-EolSnapshotDecision @('C:\IPU\eol-snapshot.json') 'C:\IPU\eol-snapshot.json' '2026-10-01' '' $false $script:Today
            $d.Status | Should -Be 'INFO'; $d.Kind | Should -Be 'Observation'; $d.Value | Should -Be 'EOL snapshot from 2026-10-01'
        }
        It 'no snapshot is one INFO row that says where it looked, never a clean result' {
            $d = Get-EolSnapshotDecision @('C:\IPU\eol-snapshot.json', 'C:\R\eol-snapshot.json') '' '' '' $false $script:Today
            $d.Status | Should -Be 'INFO'; $d.Value | Should -Match 'No EOL snapshot found'
            $d.Details[0] | Should -Match 'C:\\IPU\\eol-snapshot.json; C:\\R\\eol-snapshot.json'
        }
        It 'a named path that is missing is MANUAL: the operator asked for it' {
            $d = Get-EolSnapshotDecision @('D:\x.json') '' '' '' $true $script:Today
            $d.Status | Should -Be 'MANUAL'; $d.Kind | Should -Be 'Finding'
        }
        It 'a snapshot older than six months is MANUAL; exactly six months is still fresh' {
            (Get-EolSnapshotDecision @('p') 'p' '2026-04-24' '' $false $script:Today).Status | Should -Be 'INFO'
            $d = Get-EolSnapshotDecision @('p') 'p' '2026-04-23' '' $false $script:Today
            $d.Status | Should -Be 'MANUAL'; $d.Value | Should -Match 'older than 6 months'
        }
        It 'the age limit can be changed' {
            (Get-EolSnapshotDecision @('p') 'p' '2026-08-01' '' $false $script:Today 2).Status | Should -Be 'MANUAL'
        }
        It 'a read error and a missing date are MANUAL' {
            (Get-EolSnapshotDecision @('p') 'p' '' 'Unexpected character' $false $script:Today).Value | Should -Match 'could not be read'
            (Get-EolSnapshotDecision @('p') 'p' '' '' $false $script:Today).Value | Should -Match 'no usable date'
            (Get-EolSnapshotDecision @('p') 'p' 'yesterday' '' $false $script:Today).Status | Should -Be 'MANUAL'
        }
    }
    It 'the snapshot that ships sits next to the script and is read by the assessment' {
        $dir = Join-Path $PSScriptRoot '..\..\src'
        Test-Path -LiteralPath (Join-Path $dir 'eol-snapshot.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\data\eol-snapshot.json') | Should -BeFalse
        $script:ScriptFolder | Should -Not -BeNullOrEmpty
        # The file the release ships is one the check reads: it has a date the decision accepts.
        $asOf = [string]((Get-Content -LiteralPath (Join-Path $dir 'eol-snapshot.json') -Raw | ConvertFrom-Json).asOf)
        $asOf | Should -Match '^\d{4}-\d{2}-\d{2}$'
        (Get-EolSnapshotDecision @('p') 'p' $asOf '' $false ([datetime]$asOf)).Value | Should -Be ('EOL snapshot from ' + $asOf)
    }
}
