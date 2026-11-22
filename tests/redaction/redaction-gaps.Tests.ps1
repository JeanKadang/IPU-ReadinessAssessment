# Pester 5 tests. Names, hosts and addresses that redaction missed (GHSA-232q-x6hc-mm39).
# The script is loaded in library mode by ..\TestSetup.ps1: functions only, nothing is collected.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Tests set script settings as local variables, which shadow them for the code under test.')]
param()

BeforeAll { . (Join-Path $PSScriptRoot '..\TestSetup.ps1') }

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'Redaction of text that passed through unchanged (GHSA-232q)' {
    BeforeEach { $script:Ctx = New-RedactionContext 'SRV01' 'contoso.local' }

    It 'redacts <What>: <In>' -TestCases @(
        @{ What = 'an address at the end of a sentence'; In = 'Connected to 10.1.2.3.'; Gone = '10.1.2.3' }
        @{ What = 'a UNC host'; In = 'Share \\SRV02\data'; Gone = 'SRV02' }
        @{ What = 'a UNC host in a media path'; In = 'TargetMediaPath=\\deploy01\iso\win.iso'; Gone = 'deploy01' }
        @{ What = 'a host name outside the old domain list'; In = 'Server=web01.fabrikam.io'; Gone = 'fabrikam' }
        @{ What = 'a host name under .app'; In = 'api.fabrikam.app'; Gone = 'fabrikam' }
        @{ What = 'a host name under .dev'; In = 'git.fabrikam.dev'; Gone = 'fabrikam' }
        @{ What = 'a link to a host with no domain'; In = 'http://portal:8080/'; Gone = 'portal' }
        @{ What = 'a user profile path'; In = 'C:\Users\jdoe\AppData\Local'; Gone = 'jdoe' }
        @{ What = 'a user profile name with a space'; In = 'C:\Users\Jane Doe\Desktop'; Gone = 'Jane Doe' }
        @{ What = 'an Azure AD SID'; In = 'Owner S-1-12-1-1111111111-2222222222-3333333333-4444444444'; Gone = '1111111111' }
        @{ What = 'a dotted MAC address'; In = 'MAC 0050.56ab.cdef'; Gone = '0050.56ab' }
        @{ What = 'a plain MAC address'; In = 'MAC 005056ABCDEF'; Gone = '005056ABCDEF' }
    ) {
        $out = Protect-ReportText $In $script:Ctx
        $out | Should -Not -Match ([regex]::Escape($Gone))
    }

    It 'gives the short name of a host the placeholder of its full name' {
        $out = Protect-ReportText '10.1.2.3 sqlprod01 sqlprod01.contoso.local' $script:Ctx
        $out | Should -Not -Match 'sqlprod01'
        ($out -split ' ')[1] | Should -Be ($out -split ' ')[2]
    }

    It 'lists the computer name itself in the key when its full name is seen first' {
        $ctx = New-RedactionContext 'fv-az1234-567' ''
        $null = Protect-ReportText 'Host fv-az1234-567.internal.cloudapp.net and fv-az1234-567' $ctx
        @($ctx.Originals.Values | Where-Object { $_.Kind -eq 'HOST' -and $_.Original -ieq 'fv-az1234-567' }).Count | Should -Be 1
    }

    It 'keeps <What>' -TestCases @(
        @{ What = 'the shared profiles'; In = 'C:\Users\Public\Documents and C:\Users\Default\NTUSER.DAT' }
        @{ What = 'a device path'; In = '\\?\C:\Windows and \\.\pipe\x' }
        @{ What = 'loopback in a link'; In = 'http://localhost:8080/ and https://127.0.0.1/' }
        @{ What = 'a vendor link'; In = 'https://learn.microsoft.com/en-us/windows-server/' }
        @{ What = 'a file name'; In = 'Setup.exe, report.html and Windows-IPU-Readiness-Assessment.ps1' }
        @{ What = 'a .NET name'; In = 'Microsoft.PowerShell.Management and System.Net.Http' }
        @{ What = 'a 12-digit number'; In = 'Order 202611221430 done' }
        @{ What = 'a GUID'; In = '{1a2b3c4d-1a2b-3c4d-5e6f-0050569abcde}' }
    ) {
        Protect-ReportText $In $script:Ctx | Should -BeExactly $In
    }
}

Describe 'Redaction of an account with several words (GHSA-232q)' {
    It 'redacts a known domain with a name that has a space' {
        $ctx = New-RedactionContext 'SRV01' 'fabrikam.local'
        $out = Protect-ReportText 'RunAs=Fabrikam\Jane Doe | State=Ready' $ctx
        $out | Should -Not -Match 'Jane'
        $out | Should -Match 'State=Ready'
    }
}

Describe 'Redaction of the HTML page (GHSA-232q)' {
    BeforeEach {
        $script:Ctx = New-RedactionContext 'SRV01' 'contoso.local'
        $script:Ctx.Literals['Fabrikam Servers & Baseline'] = 'GPO'
        $script:Ctx.Literals["O'Brien Printers"] = 'NAME'
        $script:Ctx.Literals[([string][char]0xC6 + 'ble Share')] = 'NAME'
    }

    It 'finds a name that is HTML encoded in the page' {
        $html = '<p>GPO: Fabrikam Servers &amp; Baseline</p><p>' + [Net.WebUtility]::HtmlEncode("O'Brien Printers") + '</p>'
        $out = Protect-ReportHtml $html $script:Ctx
        $out | Should -Not -Match 'Fabrikam'
        $out | Should -Not -Match 'Brien'
        $out | Should -Match '^<p>GPO: GPO-1</p><p>NAME-\d</p>$'
    }

    It 'finds a name with a non-ASCII letter' {
        $name = [string][char]0xC6 + 'ble Share'
        $out = Protect-ReportHtml ('<td>' + [Net.WebUtility]::HtmlEncode($name) + '</td>') $script:Ctx
        $out | Should -Match '^<td>NAME-\d</td>$'
    }

    It 'gives the same value one placeholder in the page and in the JSON text' {
        $html = Protect-ReportHtml '<td>Fabrikam Servers &amp; Baseline</td>' $script:Ctx
        $json = Protect-ReportText 'Fabrikam Servers & Baseline' $script:Ctx
        $html | Should -Be ('<td>' + $json + '</td>')
    }

    It 'writes the decoded original to the redaction key' {
        $null = Protect-ReportHtml '<td>Fabrikam Servers &amp; Baseline</td>' $script:Ctx
        @($script:Ctx.Originals.Values | Where-Object { $_.Original -eq 'Fabrikam Servers & Baseline' }).Count | Should -Be 1
        @($script:Ctx.Originals.Values | Where-Object { $_.Original -match '&amp;' }).Count | Should -Be 0
    }

    It 'redacts attribute values and leaves the markup alone' {
        $out = Protect-ReportHtml '<a href="https://web01.fabrikam.io" class="badge s-ok">link</a>' $script:Ctx
        $out | Should -Not -Match 'fabrikam'
        $out | Should -Match '^<a href="https://HOST-\d" class="badge s-ok">link</a>$'
    }

    It 'keeps a page without names byte for byte' {
        $html = '<!doctype html><html><head><style>p{color:#333}</style></head><body><p>Total &lt; 5 &amp; done</p><!-- note --></body></html>'
        Protect-ReportHtml $html $script:Ctx | Should -BeExactly $html
    }

    It 'redacts script text as it is' {
        $out = Protect-ReportHtml '<script>var h = "web01.fabrikam.io";</script>' $script:Ctx
        $out | Should -Not -Match 'fabrikam'
    }
}
