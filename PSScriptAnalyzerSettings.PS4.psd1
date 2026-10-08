# PowerShell 4.0 / Windows Server 2012 R2 compatibility check for src/ (#94).
# The script runs on servers as old as Windows Server 2012 R2 with the
# Windows PowerShell 4.0 it ships with; CI only has 5.1 and 7. These rules
# compare every command, type and syntax element with the 2012 R2 profile
# that ships with PSScriptAnalyzer. Deliberate exceptions (commands used only
# after Test-CommandAvailable, assemblies loaded with Add-Type) are
# suppressed in the script with the reason.
@{
    IncludeRules = @('PSUseCompatibleSyntax', 'PSUseCompatibleCommands', 'PSUseCompatibleTypes')
    Rules = @{
        PSUseCompatibleSyntax   = @{ Enable = $true; TargetVersions = @('4.0') }
        PSUseCompatibleCommands = @{ Enable = $true; TargetProfiles = @('win-8_x64_6.3.9600.0_4.0_x64_4.0.30319.42000_framework') }
        PSUseCompatibleTypes    = @{ Enable = $true; TargetProfiles = @('win-8_x64_6.3.9600.0_4.0_x64_4.0.30319.42000_framework') }
    }
}
