<#
    Keeps the two vendored copies of the GitHub workflow skills identical
    (#129). Claude Code reads .claude/skills, OpenAI Codex reads
    .agents/skills; both must hold the same files. The source of truth is
    https://github.com/JeanKadang/DOC-GitHub-Practice-Skills.

        pwsh ./build/Sync-Skills.ps1 -Check
            Fails when the two copies differ (CI runs this).
        pwsh ./build/Sync-Skills.ps1 -Source <folder>
            Replaces both copies with the skill folders in <folder> (each
            holds a SKILL.md), for example the skills folder of a clone of
            the source repository. Review the diff, then commit through a PR.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Build output for the console and GitHub annotations.')]
[CmdletBinding()]
param(
    [string]$Source = '',
    [switch]$Check,
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'
$trees = @('.claude/skills', '.agents/skills')

function Get-TreeHash {
    # Relative path (forward slashes) -> SHA-256 of every file in a folder.
    param([Parameter(Mandatory = $true)][string]$Folder)
    $map = @{}
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { return $map }
    $base = (Resolve-Path -LiteralPath $Folder).ProviderPath.TrimEnd('\', '/')
    foreach ($f in @(Get-ChildItem -LiteralPath $base -Recurse -File -Force)) {
        $rel = $f.FullName.Substring($base.Length + 1).Replace('\', '/')
        $map[$rel] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
    }
    return $map
}

if ($Check) {
    $a = Get-TreeHash (Join-Path $Root $trees[0])
    $b = Get-TreeHash (Join-Path $Root $trees[1])
    $diff = @()
    foreach ($k in @($a.Keys + $b.Keys | Sort-Object -Unique)) {
        if (-not $a.ContainsKey($k)) { $diff += ('only in ' + $trees[1] + ': ' + $k) }
        elseif (-not $b.ContainsKey($k)) { $diff += ('only in ' + $trees[0] + ': ' + $k) }
        elseif ($a[$k] -ne $b[$k]) { $diff += ('different: ' + $k) }
    }
    if ($a.Count -eq 0) { $diff += ($trees[0] + ' is missing or empty') }
    if ($diff.Count -gt 0) {
        Write-Host ('::error title=Skill copies differ::' + ($diff -join '; ') + '. Run build/Sync-Skills.ps1 -Source <skills folder> and commit both copies.')
        exit 1
    }
    Write-Host ('Skill copies are identical: ' + $a.Count + ' files in ' + ($trees -join ' and '))
    exit 0
}

if (-not $Source) { throw 'Give -Source <folder with the skill folders>, or -Check.' }
if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw ('Source folder not found: ' + $Source) }
$skills = @(Get-ChildItem -LiteralPath $Source -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') -PathType Leaf })
if ($skills.Count -eq 0) { throw ('No skill folders (with a SKILL.md) in ' + $Source) }
foreach ($t in $trees) {
    $dest = Join-Path $Root $t
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $dest -Force
    foreach ($s in $skills) { Copy-Item -LiteralPath $s.FullName -Destination $dest -Recurse -Force }
    Write-Host ('Copied ' + $skills.Count + ' skills into ' + $t)
}
