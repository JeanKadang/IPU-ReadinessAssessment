# Pester 5 tests. Redaction of existing reports (-RedactExisting).
# The script is loaded in library mode by ..\TestSetup.ps1: functions only, nothing is collected.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
param()

BeforeAll { . (Join-Path $PSScriptRoot '..\TestSetup.ps1') }

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'Redact existing reports: the run log (#329)' {
    BeforeAll {
        $script:LogDir = Join-Path $TestDrive 'withlog'
        New-Item -ItemType Directory -Path $script:LogDir | Out-Null
        $sample = Join-Path $PSScriptRoot '..\..\docs\samples'
        Copy-Item -LiteralPath (Join-Path $sample 'sample-result.json') -Destination (Join-Path $script:LogDir 'SRV-APP01-IPU-Assessment.json')
        Copy-Item -LiteralPath (Join-Path $sample 'sample-report.html') -Destination (Join-Path $script:LogDir 'SRV-APP01-IPU-Assessment.html')
        $log = @(
            'Timestamp;Level;Phase;Message',
            '2026-10-29 14:01:26;INFO;START;Collector=4.6.0 | Mode=Pre | Target=2025',
            '2026-10-29 14:01:27;INFO;CHECK;gpresult for SRV-APP01 | Domain=corp.example.test | 10.20.30.40',
            '2026-10-29 14:01:28;INFO;REPORT;Written C:\temp\IPU-Assessment\SRV-APP01-IPU-Assessment.html'
        ) -join [Environment]::NewLine
        $script:LogOriginal = Join-Path $script:LogDir 'SRV-APP01-IPU-Assessment.log'
        [IO.File]::WriteAllText($script:LogOriginal, $log)
        $script:LogHash = (Get-FileHash -LiteralPath $script:LogOriginal).Hash
        $script:LogCode = Invoke-RedactExisting $script:LogDir
        $script:LogCopy = @(Get-ChildItem -LiteralPath $script:LogDir -Filter 'REDACTED-*-IPU-Assessment.log')
        $script:LogJson = @(Get-ChildItem -LiteralPath $script:LogDir -Filter 'REDACTED-*-IPU-Assessment.json')
    }
    It 'writes one redacted log beside the redacted pair, named like it' {
        $script:LogCode | Should -Be 0
        $script:LogCopy.Count | Should -Be 1
        [IO.Path]::GetFileNameWithoutExtension($script:LogCopy[0].Name) | Should -Be ([IO.Path]::GetFileNameWithoutExtension($script:LogJson[0].Name))
    }
    It 'no collected name survives, and the computer has the report''s placeholder' {
        $text = [IO.File]::ReadAllText($script:LogCopy[0].FullName)
        foreach ($secret in 'SRV-APP01', 'corp.example.test', '10.20.30.40') { $text | Should -Not -Match ([regex]::Escape($secret)) }
        $json = [IO.File]::ReadAllText($script:LogJson[0].FullName) | ConvertFrom-Json
        $text | Should -Match ('gpresult for ' + [regex]::Escape($json.ComputerName) + ' ')
        $text | Should -Match 'Collector=4\.6\.0'
    }
    It 'leaves the original log unchanged' {
        (Get-FileHash -LiteralPath $script:LogOriginal).Hash | Should -Be $script:LogHash
    }
    It 'a report without a log still gets its pair, and no log' {
        $dir = Join-Path $TestDrive 'nolog'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Copy-Item -LiteralPath (Join-Path (Join-Path $PSScriptRoot '..\..\docs\samples') 'sample-result.json') -Destination (Join-Path $dir 'SRV-APP01-IPU-Assessment.json')
        Invoke-RedactExisting $dir | Should -Be 0
        @(Get-ChildItem -LiteralPath $dir -Filter 'REDACTED-*.log').Count | Should -Be 0
    }
}

Describe 'Redact existing reports (#101)' {
    BeforeAll {
        $script:RexDir = Join-Path $TestDrive 'existing'
        New-Item -ItemType Directory -Path $script:RexDir | Out-Null
        $sample = Join-Path $PSScriptRoot '..\..\docs\samples'
        Copy-Item -LiteralPath (Join-Path $sample 'sample-result.json') -Destination (Join-Path $script:RexDir 'SRV-APP01-IPU-Assessment.json')
        Copy-Item -LiteralPath (Join-Path $sample 'sample-report.html') -Destination (Join-Path $script:RexDir 'SRV-APP01-IPU-Assessment.html')
        $script:RexBefore = @(Get-ChildItem -LiteralPath $script:RexDir | ForEach-Object { $_.Name + '|' + (Get-FileHash -LiteralPath $_.FullName).Hash })
        $script:RexCode = Invoke-RedactExisting $script:RexDir
        $script:RexJson = @(Get-ChildItem -LiteralPath $script:RexDir -Filter 'REDACTED-*-IPU-Assessment.json')
        $script:RexHtml = @(Get-ChildItem -LiteralPath $script:RexDir -Filter 'REDACTED-*-IPU-Assessment.html')
    }
    It 'writes one redacted JSON and HTML pair and returns 0' {
        $script:RexCode | Should -Be 0
        $script:RexJson.Count | Should -Be 1
        $script:RexHtml.Count | Should -Be 1
    }
    It 'the copies contain neither the computer name nor the domain, and the JSON is marked Redacted' {
        foreach ($f in @($script:RexJson[0], $script:RexHtml[0])) {
            $text = [IO.File]::ReadAllText($f.FullName)
            $text | Should -Not -Match 'SRV-APP01'
            $text | Should -Not -Match 'corp\.example\.test'
        }
        ([IO.File]::ReadAllText($script:RexJson[0].FullName) | ConvertFrom-Json).Redacted | Should -BeTrue
    }
    It 'HTML and JSON use the same placeholder for the computer' {
        $json = [IO.File]::ReadAllText($script:RexJson[0].FullName) | ConvertFrom-Json
        $json.ComputerName | Should -Match '^HOST-\d+$'
        [IO.File]::ReadAllText($script:RexHtml[0].FullName) | Should -Match ([regex]::Escape('<strong>' + $json.ComputerName + '</strong>'))
    }
    It 'leaves the originals unchanged' {
        $after = @(Get-ChildItem -LiteralPath $script:RexDir | Where-Object { $_.Name -notlike 'REDACTED-*' -and $_.Name -notlike 'DO-NOT-SHARE-*' } | ForEach-Object { $_.Name + '|' + (Get-FileHash -LiteralPath $_.FullName).Hash })
        ($after -join ';') | Should -Be ($script:RexBefore -join ';')
    }
    It 'skips a report that is already redacted' {
        $out = Join-Path $TestDrive 'skip'
        New-Item -ItemType Directory -Path $out | Out-Null
        Copy-Item -LiteralPath $script:RexJson[0].FullName -Destination (Join-Path $out 'X-IPU-Assessment.json')
        Invoke-RedactExisting $out | Should -Be 1
        @(Get-ChildItem -LiteralPath $out -Filter 'REDACTED-*').Count | Should -Be 0
    }
    It 'says clearly when nothing is there' {
        Invoke-RedactExisting (Join-Path $TestDrive 'nowhere') | Should -Be 1
        $empty = Join-Path $TestDrive 'empty'
        New-Item -ItemType Directory -Path $empty | Out-Null
        Invoke-RedactExisting $empty | Should -Be 1
    }
    It 'recovers the names to redact from the result rows' {
        $rows = @(
            [pscustomobject]@{ Area = 'TASKS'; Item = '\Nightly'; Value = 'RunAs=CORP\adm-jdoe'; Details = '' }
            [pscustomobject]@{ Area = 'SERVICES'; Item = 'App'; Value = 'App'; Details = 'State=Running | StartMode=Auto | LogOnAs=svc_app@corp.example.test' }
            [pscustomobject]@{ Area = 'GROUP_POLICY'; Item = 'GPO: Web Lockdown'; Value = 'Applied'; Details = 'Linked at x | WMI filter: VM only | Query: SELECT 1' }
        )
        $l = Get-RedactionLiteralFromResult $rows
        (@($l | ForEach-Object { $_.Kind + '=' + $_.Value }) -join '; ') | Should -Be 'ACCOUNT=CORP\adm-jdoe; ACCOUNT=svc_app@corp.example.test; GPO=Web Lockdown; NAME=VM only'
    }
}

Describe 'Redact existing reports: one placeholder per server across files (#157)' {
    BeforeAll {
        $dir = Join-Path $TestDrive 'fleet'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $sample = Join-Path $PSScriptRoot '..\..\docs\samples'
        $json = [IO.File]::ReadAllText((Join-Path $sample 'sample-result.json'))
        $html = [IO.File]::ReadAllText((Join-Path $sample 'sample-report.html'))
        foreach ($f in @(@{ Name = 'SRV-APP01-IPU-Assessment'; Host = 'SRV-APP01' }, @{ Name = 'SRV-APP01-IPU-PostUpgrade'; Host = 'SRV-APP01' }, @{ Name = 'SRV-DB02-IPU-Assessment'; Host = 'SRV-DB02' })) {
            $obj = $json.Replace('SRV-APP01', $f.Host) | ConvertFrom-Json
            if ($f.Name -like '*PostUpgrade') { $obj.Mode = 'Post' }
            [IO.File]::WriteAllText((Join-Path $dir ($f.Name + '.json')), ($obj | ConvertTo-Json -Depth 8))
            [IO.File]::WriteAllText((Join-Path $dir ($f.Name + '.html')), $html.Replace('SRV-APP01', $f.Host))
        }
        $script:FleetCode = Invoke-RedactExisting $dir
        $script:FleetJson = @(Get-ChildItem -LiteralPath $dir -Filter 'REDACTED-*.json' | Sort-Object Name)
    }
    It 'redacts all three reports' {
        $script:FleetCode | Should -Be 0
        $script:FleetJson.Count | Should -Be 3
    }
    It 'names each copy after the server placeholder, and the JSON agrees' {
        foreach ($f in $script:FleetJson) {
            $f.Name | Should -Match '^REDACTED-\d{8}-\d{6}-(HOST-\d+)-IPU-(Assessment|PostUpgrade)\.json$'
            $tag = [regex]::Match($f.Name, 'HOST-\d+').Value
            ([IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json).ComputerName | Should -Be $tag
        }
    }
    It 'a fleet overview of the redacted copies shows one row per server and mode' {
        $only = Join-Path $TestDrive 'fleet-redacted'
        $mergeOut = Join-Path $TestDrive 'fleet-overview'
        New-Item -ItemType Directory -Path $only, $mergeOut | Out-Null
        foreach ($f in $script:FleetJson) { Copy-Item -LiteralPath $f.FullName -Destination $only }
        $null = & (Join-Path $PSScriptRoot '..\..\src\Merge-IPUAssessments.ps1') -InputFolder $only -OutputFolder $mergeOut
        $rows = @(Import-Csv -LiteralPath (Join-Path $mergeOut 'IPU-Fleet-Servers.csv') -Delimiter ';')
        $rows.Count | Should -Be 3
        @($rows | ForEach-Object { $_.ComputerName + '|' + $_.Mode } | Sort-Object -Unique).Count | Should -Be 3
        @($rows | ForEach-Object { $_.ComputerName } | Sort-Object -Unique).Count | Should -Be 2
    }
    It 'gives one server the same placeholder in pre and post, and different servers different ones' {
        $tags = @($script:FleetJson | ForEach-Object { [regex]::Match($_.Name, 'HOST-\d+').Value + '|' + [regex]::Match($_.Name, 'Assessment|PostUpgrade').Value })
        @($tags | ForEach-Object { ($_ -split '\|')[0] } | Sort-Object -Unique) -join ',' | Should -Be 'HOST-1,HOST-2'   # numbered first (#172)
        $post = @($tags | Where-Object { $_ -like '*|PostUpgrade' })[0].Split('|')[0]
        @($tags | Where-Object { $_ -eq ($post + '|Assessment') }).Count | Should -Be 1
    }
}

Describe 'RedactExisting recovers every name the collector registers (#172)' {
    It 'recovers share names and descriptions from the share rows' {
        $rows = @(
            [pscustomobject]@{ Area = 'FILE_SHARES'; Item = 'FileShares'; Value = 'Count=2'; Details = 'Finance, Scans$' }
            [pscustomobject]@{ Area = 'FILE_SHARES'; Item = 'Share: Finance'; Value = 'D:\Finance'; Details = @('Path=D:\Finance', 'Description=Contoso finance team', 'Share permissions: Everyone: Read') }
            [pscustomobject]@{ Area = 'FILE_SHARES'; Item = 'Share: Scans$'; Value = 'D:\Scans'; Details = @('Path=D:\Scans', 'Share permissions: not readable') }
        )
        $l = Get-RedactionLiteralFromResult $rows
        (@($l | ForEach-Object { $_.Kind + '=' + $_.Value }) -join '; ') | Should -Be 'NAME=Finance; NAME=Contoso finance team; NAME=Scans$'
    }
    It 'has a recovery rule for every Add-RedactionLiteral call site in the collector' {
        # When this fails, a new call site was added: add a rule to
        # Get-RedactionLiteralFromResult and its pattern here.
        $src = [IO.File]::ReadAllLines((Join-Path $PSScriptRoot '..\..\src\Windows-IPU-Readiness-Assessment.ps1'))
        $sites = @($src | Where-Object { $_ -match 'Add-RedactionLiteral ' -and $_ -notmatch '^\s*function ' -and $_ -notmatch 'Get-RedactionLiteralFromResult' } | ForEach-Object { $_.Trim() })
        $known = @(
            'Add-RedactionLiteral $g.Name ''GPO''',
            'if ($g.FilterName) { Add-RedactionLiteral $g.FilterName ''NAME'' }',
            'Add-RedactionLiteral $filter.Name ''NAME''',
            'Add-RedactionLiteral ([string]$sh.Name) ''NAME''',
            'if ($sh.Description) { Add-RedactionLiteral ([string]$sh.Description) ''NAME'' }',
            'foreach ($s in @($script:Data.Services | Where-Object { $_.StartName })) { Add-RedactionLiteral ([string]$s.StartName) ''ACCOUNT'' }',
            'if ($user -and -not $isBuiltIn) { Add-RedactionLiteral $user ''ACCOUNT'' }',
            'Add-RedactionLiteral ([string]$cluster.Name) ''HOST''',
            'try { foreach ($n in @(Get-ClusterNode -ErrorAction Stop)) { Add-RedactionLiteral ([string]$n.Name) ''HOST''; Add-Result ''CLUSTER'' (''Node: '' + $n.Name) ''INFO'' (''State='' + $n.State) -Source ''Get-ClusterNode'' } } catch { $unread += (''nodes: '' + $_.Exception.Message) }',
            'if ($act.KmsHost) { foreach ($h in @($act.KmsHost, ($act.KmsHost -split ''\.'')[0]) | Select-Object -Unique) { Add-RedactionLiteral $h ''HOST'' }; $script:Data.KmsEndpoint = $act.KmsEndpoint } elseif ($script:Data.ActivationKind -eq ''KMS'') { $script:Data.KmsEndpoint = ''found via DNS'' }',
            'foreach ($p in $printers) { Add-RedactionLiteral $p.Name ''NAME''; if ($p.ShareName) { Add-RedactionLiteral $p.ShareName ''NAME'' } }',
            'foreach ($pt in $ports) { Add-RedactionLiteral $pt.Name ''NAME''; if ($pt.Address -and $pt.Address -notmatch ''^[0-9.:]+$'') { Add-RedactionLiteral $pt.Address ''HOST'' } }',
            'foreach ($i in $instances) { if ($script:SqlDefaultInstanceNames -notcontains $i.Instance) { Add-RedactionLiteral $i.Instance ''NAME''; Add-RedactionLiteral $i.Id ''NAME'' } }'
        )
        @($sites | Where-Object { $known -notcontains $_ }) | Should -BeNullOrEmpty
    }
}
