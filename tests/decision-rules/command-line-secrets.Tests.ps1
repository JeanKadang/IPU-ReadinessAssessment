# Pester 5 tests. Passwords and tokens in scheduled-task command lines are masked (GHSA-3xmq-62gm-6hxj).
# The script is loaded in library mode by ..\TestSetup.ps1: functions only, nothing is collected.

BeforeAll { . (Join-Path $PSScriptRoot '..\TestSetup.ps1') }

AfterAll { Remove-Item Env:\IPU_ASSESSMENT_LIBRARY_ONLY -ErrorAction SilentlyContinue }

Describe 'Hide-CommandLineSecret' {
    It 'masks <Secret> in: <Line>' -ForEach @(
        @{ Line = 'sqlcmd -S SQLPROD01 -U sa -P "Pa55word"'; Secret = 'Pa55word' }
        @{ Line = 'sqlcmd -S SQLPROD01 -U sa -P "Pa55 word"'; Secret = 'Pa55 word' }
        @{ Line = 'tool.exe -Password Winter2026!'; Secret = 'Winter2026!' }
        @{ Line = 'tool.exe -password:Winter2026!'; Secret = 'Winter2026!' }
        @{ Line = 'tool.exe /password:Winter2026!'; Secret = 'Winter2026!' }
        @{ Line = 'tool.exe /p:Winter2026!'; Secret = 'Winter2026!' }
        @{ Line = 'schtasks /create /ru CONTOSO\svc /rp Secr3t! /tn x'; Secret = 'Secr3t!' }
        @{ Line = 'net use \\SRV02\backup /user:CONTOSO\svc_bak Secr3t!'; Secret = 'Secr3t!' }
        @{ Line = 'net use \\SRV02\backup Secr3t! /user:CONTOSO\svc_bak'; Secret = 'Secr3t!' }
        @{ Line = 'app.exe "Server=db01;User Id=app;Password=Xyz123"'; Secret = 'Xyz123' }
        @{ Line = 'app.exe "server=db01;PWD=Xyz123;Database=x"'; Secret = 'Xyz123' }
        @{ Line = 'powershell -Command "ConvertTo-SecureString ''Pa55word'' -AsPlainText -Force"'; Secret = 'Pa55word' }
        @{ Line = 'curl https://svc_bak:Secr3t!@files.example.test/x'; Secret = 'Secr3t!' }
    ) {
        $r = Hide-CommandLineSecret $Line
        $r.Text | Should -Not -Match ([regex]::Escape($Secret))
        $r.Masked | Should -BeTrue
    }

    It 'keeps the rest of the command line' {
        (Hide-CommandLineSecret 'sqlcmd -S SQLPROD01 -U sa -P "Pa55word" -Q "select 1"').Text | Should -Be 'sqlcmd -S SQLPROD01 -U sa -P ******** -Q "select 1"'
    }

    It 'leaves a command line without a secret as it was' -ForEach @(
        @{ Line = 'C:\Windows\System32\cmd.exe /c C:\Scripts\backup.cmd' }
        @{ Line = 'powershell.exe -NoProfile -File C:\Scripts\Path-Check.ps1' }
        @{ Line = 'net use \\SRV02\backup /user:CONTOSO\svc_bak *' }
        @{ Line = '' }
    ) {
        $r = Hide-CommandLineSecret $Line
        $r.Text | Should -Be $Line
        $r.Masked | Should -BeFalse
    }

    It 'handles a null command line' {
        (Hide-CommandLineSecret $null).Masked | Should -BeFalse
    }
}
