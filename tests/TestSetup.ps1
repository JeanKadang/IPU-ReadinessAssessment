# Shared setup for the Pester tests in the folders under tests/, dot-sourced in
# each file's BeforeAll. Not a test file itself. Loads the assessment in library
# mode (functions only, nothing is collected).
# The strict-mode finder (#256, build/Invoke-CiTests.ps1 -StrictModeFinder)
# loads the code under Set-StrictMode. Normal runs and production never do.
if ($env:IPU_TEST_STRICT_MODE) { Set-StrictMode -Version $env:IPU_TEST_STRICT_MODE }
$env:IPU_ASSESSMENT_LIBRARY_ONLY = '1'
. (Join-Path $PSScriptRoot '..\src\Windows-IPU-Readiness-Assessment.ps1')
# Unelevated runs (#126): keep the current user on the folders the tests
# restrict, so they can be used and cleaned up. Elevated runs are as before.
if ($env:OS -eq 'Windows_NT') {
    $me = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($me)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { $script:ExtraRestrictedSids = @($me.User.Value) }
}
