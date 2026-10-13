<#
    Joins the source parts of a script into the single file that OpenText
    SA runs (ADR 0002, #151).

        pwsh ./build/Build-Script.ps1           # write the built file
        pwsh ./build/Build-Script.ps1 -Check    # fail when it is out of date

    The parts and their order come from a manifest (one file name per line,
    '#' starts a comment). The output is the plain concatenation of the
    parts: CRLF line endings, ASCII, no byte-order mark, so the same parts
    always give the same bytes. The built file is committed, so SA users,
    the tests and the release keep using one path; CI runs -Check so it can
    never be edited by hand or fall behind the parts.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Build output for the console and GitHub annotations.')]
[CmdletBinding()]
param(
    [string]$Manifest = (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/assessment/manifest.txt'),
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Windows-IPU-Readiness-Assessment.ps1'),
    [switch]$Check
)
$ErrorActionPreference = 'Stop'

function Get-BuiltContent {
    param([Parameter(Mandatory = $true)][string]$ManifestPath)
    $folder = Split-Path -Parent $ManifestPath
    $names = @([IO.File]::ReadAllLines($ManifestPath) | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    if ($names.Count -eq 0) { throw ('No parts listed in ' + $ManifestPath) }
    $listed = @{}
    $out = New-Object System.IO.MemoryStream
    foreach ($n in $names) {
        if ($listed.ContainsKey($n)) { throw ('Part listed twice: ' + $n) }
        $listed[$n] = $true
        $path = Join-Path $folder $n
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('Part not found: ' + $path) }
        $bytes = [IO.File]::ReadAllBytes($path)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { throw ('Part has a byte-order mark: ' + $n) }
        foreach ($b in $bytes) { if ($b -gt 127) { throw ('Part is not ASCII: ' + $n) } }
        $text = [Text.Encoding]::ASCII.GetString($bytes)
        if ($text -match '(?<!\r)\n') { throw ('Part has LF line endings (CRLF required): ' + $n) }
        if (-not $text.EndsWith("`r`n")) { throw ('Part must end with a line break: ' + $n) }
        $out.Write($bytes, 0, $bytes.Length)
    }
    # Every .ps1 in the folder must be listed, so no part is forgotten.
    foreach ($f in @(Get-ChildItem -LiteralPath $folder -Filter '*.ps1' -File)) {
        if (-not $listed.ContainsKey($f.Name)) { throw ('Part not in the manifest: ' + $f.Name) }
    }
    return ,($out.ToArray())
}

$built = Get-BuiltContent $Manifest
if ($Check) {
    $current = @()
    if (Test-Path -LiteralPath $OutputPath) { $current = [IO.File]::ReadAllBytes($OutputPath) }
    $same = ($current.Length -eq $built.Length)
    if ($same) { for ($i = 0; $i -lt $built.Length; $i++) { if ($current[$i] -ne $built[$i]) { $same = $false; break } } }
    if (-not $same) {
        Write-Host ('::error title=Built file out of date::' + (Split-Path -Leaf $OutputPath) + ' does not match its parts. Edit the parts in src/assessment/ and run build/Build-Script.ps1; never edit the built file by hand.')
        exit 1
    }
    Write-Host ('Built file is up to date: ' + (Split-Path -Leaf $OutputPath) + ' (' + $built.Length + ' bytes)')
    exit 0
}
[IO.File]::WriteAllBytes($OutputPath, $built)
Write-Host ('Built ' + $OutputPath + ' (' + $built.Length + ' bytes)')
