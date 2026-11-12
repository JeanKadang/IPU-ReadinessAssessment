<#
    Finds relative links in the Markdown files that do not resolve (#265):
    a file that is not there, or a #anchor that is not a heading of the
    target file. The user guide is split into several files (#265), so a
    link that points into the wrong one must not go unnoticed. Links to
    other sites (http:, https:, mailto:) are not followed.

        pwsh ./build/Find-BrokenDocLink.ps1

    Exit code 1 when a link is broken. The Pester test runs the same check
    on the documents that ship with the scripts.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

function Get-MarkdownSlug {
    # Pure: the anchor GitHub makes from the text of a heading: lower case,
    # everything but letters, digits, blanks, hyphens and underscores
    # removed, blanks turned into hyphens.
    param([AllowNull()][string]$Heading)
    $t = [string]$Heading
    $t = [regex]::Replace($t, '\[([^\]]*)\]\([^)]*\)', '$1')
    $t = $t -replace '[`*]', ''
    $t = $t.Trim().ToLowerInvariant()
    $t = [regex]::Replace($t, '[^\p{L}\p{N}_ -]', '')
    return ($t -replace ' ', '-')
}

function Get-MarkdownAnchor {
    # Pure: the anchors a text offers. A heading that repeats gets -1, -2.
    # Lines inside a code fence are not headings.
    param([AllowNull()][string]$Text)
    $seen = @{}
    $anchors = New-Object Collections.Generic.List[string]
    $fence = $false
    foreach ($line in ([string]$Text -split '\r?\n')) {
        if ($line -match '^\s*(```|~~~)') { $fence = -not $fence; continue }
        if ($fence) { continue }
        $m = [regex]::Match($line, '^ {0,3}#{1,6}[ \t]+(.+?)(?:[ \t]+#+)?[ \t]*$')
        if (-not $m.Success) { continue }
        $slug = Get-MarkdownSlug $m.Groups[1].Value
        if ($seen.ContainsKey($slug)) { $seen[$slug] = $seen[$slug] + 1; $anchors.Add($slug + '-' + $seen[$slug]) }
        else { $seen[$slug] = 0; $anchors.Add($slug) }
    }
    return $anchors.ToArray()
}

function Get-MarkdownLink {
    # Pure: the targets of [text](target) and ![alt](target) with their line
    # number. Code fences and inline code are skipped.
    param([AllowNull()][string]$Text)
    $found = New-Object Collections.Generic.List[object]
    $fence = $false
    $n = 0
    foreach ($line in ([string]$Text -split '\r?\n')) {
        $n++
        if ($line -match '^\s*(```|~~~)') { $fence = -not $fence; continue }
        if ($fence) { continue }
        $plain = [regex]::Replace($line, '`[^`]*`', '')
        foreach ($m in [regex]::Matches($plain, '\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)')) {
            $found.Add([pscustomobject]@{ Line = $n; Target = $m.Groups[1].Value })
        }
    }
    return $found.ToArray()
}

function Find-BrokenDocLink {
    # Reads the files (paths relative to RepoRoot) and returns one object per
    # relative link that does not resolve: File, Line, Target, Reason.
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string[]]$File
    )
    $anchorCache = @{}
    $broken = New-Object Collections.Generic.List[object]
    foreach ($f in $File) {
        $full = [IO.Path]::GetFullPath((Join-Path $RepoRoot $f))
        $text = [IO.File]::ReadAllText($full)
        foreach ($l in @(Get-MarkdownLink $text)) {
            $t = [string]$l.Target
            if ($t -match '^[A-Za-z][A-Za-z0-9+.-]*:') { continue }
            $path = $t
            $anchor = ''
            $hash = $t.IndexOf('#')
            if ($hash -ge 0) { $path = $t.Substring(0, $hash); $anchor = $t.Substring($hash + 1) }
            $path = [Uri]::UnescapeDataString($path)
            if ($path -eq '') { $target = $full }
            elseif ($path.StartsWith('/')) { $target = [IO.Path]::GetFullPath((Join-Path $RepoRoot $path.TrimStart('/'))) }
            else { $target = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $full) $path)) }
            $reason = ''
            if (-not (Test-Path -LiteralPath $target)) { $reason = 'file not found' }
            elseif ($anchor -and $target.EndsWith('.md') -and (Test-Path -LiteralPath $target -PathType Leaf)) {
                if (-not $anchorCache.ContainsKey($target)) { $anchorCache[$target] = @(Get-MarkdownAnchor ([IO.File]::ReadAllText($target))) }
                if ($anchorCache[$target] -notcontains $anchor.ToLowerInvariant()) { $reason = 'no such heading in ' + (Split-Path -Leaf $target) }
            }
            if ($reason) { $broken.Add([pscustomobject]@{ File = $f; Line = $l.Line; Target = $t; Reason = $reason }) }
        }
    }
    return $broken.ToArray()
}

function Get-DocLinkFile {
    # The documents that ship with the scripts or guide the contributors.
    # The review notes under docs/review are a record of the time they were
    # written and are not checked.
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    $names = New-Object Collections.Generic.List[string]
    foreach ($n in 'README.md', 'CONTRIBUTING.md', 'SECURITY.md', 'AGENTS.md', 'GLOSSARY.md') {
        if (Test-Path -LiteralPath (Join-Path $RepoRoot $n)) { $names.Add($n) }
    }
    foreach ($d in 'docs', 'docs/adr', 'docs/agents') {
        $dir = Join-Path $RepoRoot $d
        if (Test-Path -LiteralPath $dir) {
            foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.md' -File | Sort-Object Name)) { $names.Add($d + '/' + $f.Name) }
        }
    }
    return $names.ToArray()
}

if ($MyInvocation.InvocationName -eq '.') { return }

$ErrorActionPreference = 'Stop'
$files = @(Get-DocLinkFile $RepoRoot)
$broken = @(Find-BrokenDocLink $RepoRoot $files)
Write-Output ('{0} file(s) checked, {1} broken link(s).' -f $files.Count, $broken.Count)
foreach ($b in $broken) { Write-Output ('{0}:{1}: {2} ({3})' -f $b.File, $b.Line, $b.Target, $b.Reason) }
if ($broken.Count -gt 0) { exit 1 }
