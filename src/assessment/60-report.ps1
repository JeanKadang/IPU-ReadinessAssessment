# =============================================================================
# 6. HTML/JSON REPORT
# =============================================================================
function ConvertTo-HtmlText {
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function New-StatusBadge {
    param([string]$Status)
    return '<span class="badge s-' + (ConvertTo-HtmlText $Status.ToLowerInvariant()) + '">' + (ConvertTo-HtmlText $Status) + '</span>'
}

function Get-AreaName {
    param([string]$Area)
    if ($script:AreaMap.ContainsKey($Area)) { return $script:AreaMap[$Area].Name }
    return $Area
}

function Get-ResultText {
    param($Results, [string]$Area, [string]$Item)
    $r = @($Results | Where-Object { $_.Area -eq $Area -and $_.Item -eq $Item }) | Select-Object -First 1
    if (-not $r) { return '' }
    return (@($r.Value,$r.Details) | Where-Object { $_ }) -join ' | '
}

function Get-CoverageNotice {
    # Pure: splits the checks that did not complete into problems (failed,
    # timed out, or skipped because the time budget ran out - their areas are
    # incomplete) and checks not run by choice (switched off, no media,
    # not applicable), each with a plain-language sentence.
    param([object[]]$CheckRuns, [string]$Target = 'the target release')
    $problems = @(); $byChoice = @()
    foreach ($run in @($CheckRuns)) {
        if ($run.Outcome -eq 'Completed') { continue }
        $msg = [string]$run.Message
        if ($run.Outcome -eq 'Skipped' -and $msg -like 'Not applicable*') { continue }
        if ($run.Outcome -eq 'Skipped' -and $msg -like 'Not configured*') {
            if ($run.Id -eq 'compatscan') {
                $byChoice += ('Microsoft''s own upgrade check (Setup compatibility scan) was not run, because no ' + $Target + ' installation media was given. This is optional: to include it, run the assessment again with -TargetMediaPath set to the ISO, or a folder or share with the installation files.')
            } else {
                $byChoice += ($run.Name + ' was switched off for this run (' + ($msg -replace '^Not configured:\s*','') + '). Run it before the final go/no-go.')
            }
            continue
        }
        $why = 'did not finish'
        if ($run.Outcome -eq 'Failed') { $why = 'stopped with an error' }
        elseif ($run.Outcome -eq 'TimedOut') { $why = 'ran out of time' }
        # Only the budget skip blames the budget (#206); any other skip says why.
        elseif ($run.Outcome -eq 'Skipped' -and $msg -eq 'Time budget used up') { $why = 'was not started, the time budget was used up' }
        elseif ($run.Outcome -eq 'Skipped') { $why = $(if ($msg) { 'was skipped (' + $msg + ')' } else { 'was skipped' }) }
        $problems += ($run.Name + ' ' + $why)
    }
    return [pscustomobject]@{ Problems = $problems; ByChoice = $byChoice }
}

function Get-ProfileAclNote {
    # Pure (#261): RestrictOutputAcl from a profile file reaches the evidence
    # folders, but the report folder was created (or found) before the file
    # was read. '' when the profile does not set it.
    param([bool]$ProfileSetsIt, [string]$FolderState)
    if (-not $ProfileSetsIt) { return '' }
    $state = $FolderState; if (-not $state) { $state = 'unknown' }
    return ('RestrictOutputAcl: applies to the evidence folders only. The report folder was set up before the profile was read (' + $state + '); to change it, pass -RestrictOutputAcl as an argument.')
}

function Get-SaLogPathField {
    # Pure (#261): the LogPath field of the SA line names the log only when it
    # was written, so a FAILED line never points to a file that is not there.
    param([string]$LogPath, [bool]$Exists)
    if ($LogPath -and $Exists) { return $LogPath }
    return ''
}

function Get-CheckRunCount {
    # Pure (#261): the counts for the SA line. NotCompleted is what left a gap
    # (failed, timed out, or not started because the time budget ran out), the
    # same split as the coverage notice. Skipped is what was not run by choice
    # or does not apply (switched off, no media, not a print server, a SPECIAL
    # short report): it is not a gap.
    param([object[]]$CheckRuns)
    $notCompleted = @((Get-CoverageNotice $CheckRuns).Problems).Count
    $other = @(@($CheckRuns) | Where-Object { $_ -and $_.Outcome -ne 'Completed' }).Count
    return [pscustomobject]@{ Total = @(@($CheckRuns) | Where-Object { $_ }).Count; NotCompleted = $notCompleted; Skipped = ($other - $notCompleted) }
}

function New-RecommendationHtml {
    # The "What to do" cell: recommendation text, then the command (labelled
    # Check or Change, with a copy button) and the documentation link (#79).
    param($Row)
    $html = ConvertTo-HtmlText $Row.Recommendation
    if ($Row.PSObject.Properties['Command'] -and $Row.Command) {
        $label = 'Check'; $hint = 'read-only'
        if ($Row.CommandKind -eq 'Change') { $label = 'Change'; $hint = 'run in the change window' }
        $cmd = ConvertTo-HtmlText $Row.Command
        $html += '<div class="cmd"><span class="ck ck-' + $label.ToLowerInvariant() + '" title="' + $hint + '">' + $label + '</span><code>' + $cmd + '</code><button type="button" class="copy" data-cmd="' + $cmd + '" aria-label="Copy the ' + $label.ToLowerInvariant() + ' command">Copy</button></div>'
    }
    if ($Row.PSObject.Properties['Link'] -and $Row.Link) {
        $title = $Row.LinkTitle; if (-not $title) { $title = $Row.Link }
        $html += '<div class="more">Read more: <a class="ext" href="' + (ConvertTo-HtmlText $Row.Link) + '" target="_blank" rel="noopener noreferrer">' + (ConvertTo-HtmlText $title) + '</a></div>'
    }
    return $html
}

function New-FindingTable {
    param($Rows, [switch]$WithCheckbox, [string]$Caption = 'Findings')
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="scroll"><table><caption class="sr">' + (ConvertTo-HtmlText $Caption) + '</caption><thead><tr>')
    if ($WithCheckbox) { [void]$sb.Append('<th scope="col" class="cb">Done</th>') }
    [void]$sb.Append('<th scope="col">Status</th><th scope="col">Area</th><th scope="col">Item</th><th scope="col">Finding</th><th scope="col">What to do</th></tr></thead><tbody>')
    foreach ($r in $Rows) {
        [void]$sb.Append('<tr>')
        # A printable tick box: the glyph is hidden from screen readers, which
        # read the visible word "open" instead.
        if ($WithCheckbox) { [void]$sb.Append('<td class="cb"><span aria-hidden="true">&#x2610;</span> <span class="cbt">open</span></td>') }
        $finding = (@($r.Value,$r.Details) | Where-Object { $_ }) -join ' | '
        [void]$sb.Append('<td class="nw">' + (New-StatusBadge $r.Status) + '</td><td class="nw">' + (ConvertTo-HtmlText (Get-AreaName $r.Area)) + '</td><td class="item">' + (ConvertTo-HtmlText $r.Item) + '</td><td class="txt">' + (ConvertTo-HtmlText $finding) + '</td><td class="txt">' + (New-RecommendationHtml $r) + '</td></tr>')
    }
    [void]$sb.Append('</tbody></table></div>')
    return $sb.ToString()
}

function New-IPUReportHtml {
    param(
        [object[]]$Results,
        [object[]]$CheckRuns,
        [string]$OverallStatus,
        [datetime]$CompletedTime,
        [switch]$Partial
    )
    $ErrorActionPreference = 'Stop'
    $e = ${function:ConvertTo-HtmlText}
    $findings = @($Results | Where-Object { $_.Kind -eq 'Finding' })
    $counts = @{}
    foreach ($s in $script:FindingStatuses) { $counts[$s] = @($findings | Where-Object { $_.Status -eq $s }).Count }
    $decision = @($findings | Where-Object { $_.Status -in @('SPECIAL','BLOCKER','ACTION') } | Sort-Object @{Expression={Get-StatusRank $_.Status}},Area,Item)
    $planning = @($findings | Where-Object { $_.Status -in @('WARNING','MANUAL') } | Sort-Object @{Expression={Get-StatusRank $_.Status}},Area,Item)
    $checklist = @($Results | Where-Object { $_.Kind -eq 'Checklist' })
    $coverage = Get-CoverageNotice $CheckRuns (Get-ReleaseDisplayName $TargetServerVersion)
    $duration = Format-Duration ($CompletedTime - $script:CollectionStarted)
    $target = Get-ReleaseDisplayName $TargetServerVersion
    $isPost = ($AssessmentMode -eq 'Post')
    $title = 'Windows Server IPU Readiness Assessment'
    if ($isPost) { $title = 'Windows Server Post-Upgrade Verification' }
    # A fact a check sets: 'None detected' when the check completed without
    # finding anything, 'Not assessed' when the check did not complete.
    $factValue = {
        param($Value, [string]$CheckId)
        if ($Value) { return [string]$Value }
        $run = @($CheckRuns | Where-Object { $_.Id -eq $CheckId }) | Select-Object -First 1
        if ($run -and $run.Outcome -eq 'Completed') { return 'None detected' }
        return 'Not assessed'
    }
    $eppNames = @($Results | Where-Object { $_.Area -eq 'ANTIVIRUS' -and $_.Item -eq 'Microsoft Defender Antivirus' -and ($_.Status -eq 'OK' -or $_.Status -eq 'WARNING') } | ForEach-Object { $_.Item })
    if ($script:Data.EndpointProducts) { $eppNames += @($script:Data.EndpointProducts) }
    else { $eppNames += @($Results | Where-Object { $_.Area -eq 'ANTIVIRUS' -and $_.Status -eq 'WARNING' -and $_.Item -ne 'Microsoft Defender Antivirus' } | ForEach-Object { $_.Item }) }
    $epp = $eppNames -join ', '

    $facts = @(
        @('Current OS', (Get-ResultText $Results 'UPGRADE_PATH' 'CurrentOS')),
        @('Target', $target),
        @('Upgrade path', (Get-ResultText $Results 'UPGRADE_PATH' 'TargetUpgradePath')),
        @('Installation image to use', $script:Data.RecommendedMedia),
        @('Windows activation', (Get-ResultText $Results 'LICENSING' 'CurrentActivation')),
        @('Platform', (Get-ResultText $Results 'PLATFORM' 'PhysicalOrVirtual')),
        @('Domain role', $script:Data.DomainRoleText),
        @('AD location (OU)', $script:Data.AdLocation),
        @('UAC', $script:Data.UacSummary),
        @('SQL Server', (& $factValue $script:Data.SqlSummary 'sql')),
        @('Endpoint protection', (& $factValue $epp 'antivirus')),
        @('VMware Tools', (Get-ResultText $Results 'VMWARE' 'VMwareTools')),
        @('Setup compatibility scan', (Get-ResultText $Results 'COMPAT_SCAN' 'SetupCompatibilityScan')),
        @('RDP access', (Get-RdpAccessFact)),
        @('RDP drive redirection', $script:Data.DriveRedirection),
        @('C: drive', $script:Data.CSummary),
        @('Memory GB / logical CPUs', ((Get-ResultText $Results 'PERFORMANCE' 'MemoryGB') + ' / ' + (Get-ResultText $Results 'PERFORMANCE' 'LogicalProcessors'))),
        @('Evidence copies (unredacted)', $EvidenceRoot),
        @('Policy evidence', $script:Data.PolicyEvidence),
        @('Network evidence', $script:Data.NetworkEvidence),
        @('Machine-readable result', $(if ($WriteJson) { $script:JsonPath } else { 'Disabled' }))
    )
    if ($isPost) {
        $facts = @(
            @('Current OS', (Get-ResultText $Results 'UPGRADE_PATH' 'CurrentOS')),
            @('Target', $target),
            @('Upgrade result', (Get-ResultText $Results 'POST_UPGRADE' 'UpgradeReachedTarget')),
            @('Baseline', (Get-ResultText $Results 'POST_UPGRADE' 'Baseline')),
            @('Windows activation', (Get-ResultText $Results 'LICENSING' 'CurrentActivation')),
            @('RDP access', (Get-RdpAccessFact)),
            @('UAC', $script:Data.UacSummary),
            @('C: drive', $script:Data.CSummary),
            @('Endpoint protection', (& $factValue $epp 'antivirus'))
        )
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">')
    [void]$sb.AppendLine('<title>' + (& $e $(if ($isPost) { 'IPU Post-Upgrade' } else { 'IPU Assessment' })) + ' - ' + (& $e $script:ComputerName) + '</title>')
    [void]$sb.AppendLine(@'
<style>
/* Colour tokens. Contrast (WCAG 2.1) is checked by the tests: text >= 4.5:1, focus outline >= 3:1, in both themes. */
:root{--ink:#16202e;--muted:#5d6a79;--line:#dde3ea;--bg:#f3f5f8;--panel:#ffffff;--navy:#16365f;--heading:#16365f;--th-bg:#eef2f7;--th-ink:#30475f;--focus:#16365f;--partial-bg:#fff4d6;--partial-ink:#5c4400;--partial-line:#e6c46a;--special:#0f4c5c;--blocker:#7a1717;--action:#b42318;--warning:#9a5800;--manual:#5b47a0;--ok:#17703a;--info:#4a6578}
@media (prefers-color-scheme: dark){:root{--ink:#e6edf5;--muted:#a9b6c4;--line:#2c3947;--bg:#0e141b;--panel:#16202b;--heading:#a9c8f0;--th-bg:#1e2a37;--th-ink:#c5d3e0;--focus:#8fb8ff;--partial-bg:#3a2e0b;--partial-ink:#ffe08a;--partial-line:#7a6220}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.5 "Segoe UI",Arial,sans-serif}
.wrap{max-width:1440px;margin:auto;padding:24px 16px}
.hero{background:var(--navy);color:#fff;padding:24px 28px;border-radius:12px}
.hero h1{margin:0 0 6px;font-size:24px;font-weight:600}.hero p{margin:3px 0;color:#d5e1ee}
.verdict{margin-top:12px;font-size:16px}.verdict .badge{font-size:14px;padding:5px 12px}
.partial{background:var(--partial-bg);border:1px solid var(--partial-line);color:var(--partial-ink);border-radius:10px;padding:12px 16px;margin:14px 0;font-weight:600}
.cards{display:grid;grid-template-columns:repeat(6,minmax(0,1fr));gap:10px;margin:16px 0}
.card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:12px 14px;color:inherit;text-decoration:none;display:block}a.card:hover{border-color:var(--heading)}a.card:focus-visible{outline:3px solid var(--focus);outline-offset:2px}a.card b::after{content:" \2192";font-size:14px;color:var(--muted)}
.cmd{margin-top:6px;display:flex;flex-wrap:wrap;gap:6px;align-items:flex-start}.cmd code{flex:1 1 260px;font:12px/1.45 Consolas,'Cascadia Mono',monospace;background:var(--th-bg);color:var(--ink);border:1px solid var(--line);border-radius:6px;padding:4px 6px;overflow-wrap:anywhere;white-space:pre-wrap}
.ck{font-size:11px;font-weight:700;border-radius:4px;padding:2px 6px;border:1px solid var(--line);color:var(--ink)}.ck-change{border-color:var(--action);color:var(--action)}
.copy{display:none;font:inherit;font-size:12px;border:1px solid var(--line);background:var(--panel);color:var(--ink);border-radius:6px;padding:2px 8px;cursor:pointer}.js .copy{display:inline-block}.copy:focus-visible{outline:3px solid var(--focus);outline-offset:2px}
.more{margin-top:4px;font-size:12px}.more a{color:var(--heading)}
.chapters-note{color:var(--muted);margin:18px 2px 6px}.js-only{display:none}.js .js-only{display:inline}.tgl{font:inherit;font-size:12px;border:1px solid var(--line);background:var(--panel);color:var(--ink);border-radius:6px;padding:2px 8px;cursor:pointer}.tgl:focus-visible{outline:3px solid var(--focus);outline-offset:2px}
.note{background:var(--panel);border:1px solid var(--line);border-left:4px solid var(--info);border-radius:10px;padding:12px 16px;margin:14px 0}.card b{display:block;font-size:24px;font-weight:650}.card small{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.04em}
section,details{background:var(--panel);border:1px solid var(--line);border-radius:10px;margin:14px 0}
section{padding:18px 20px}h2{font-size:18px;margin:0 0 6px;color:var(--heading)}.lead{color:var(--muted);margin:0 0 12px}
summary{cursor:pointer;font-size:16px;font-weight:600;color:var(--heading);padding:14px 20px}summary:focus-visible{outline:3px solid var(--focus);outline-offset:2px;border-radius:8px}details>div{padding:0 20px 18px}
.badge{display:inline-block;color:#fff;font-weight:700;font-size:11px;letter-spacing:.03em;padding:3px 8px;border-radius:999px;white-space:nowrap}
.s-special{background:var(--special)}.s-blocker{background:var(--blocker)}.s-action{background:var(--action)}.s-warning{background:var(--warning)}.s-manual{background:var(--manual)}.s-ok{background:var(--ok)}.s-info{background:var(--info)}
.scroll{width:100%;overflow-x:auto}table{width:100%;border-collapse:collapse;min-width:860px}
th,td{text-align:left;vertical-align:top;border-bottom:1px solid var(--line);padding:8px}
th{background:var(--th-bg);color:var(--th-ink);font-size:11px;text-transform:uppercase;letter-spacing:.04em}
.nw{white-space:nowrap}.txt{overflow-wrap:anywhere}.item{min-width:150px;overflow-wrap:break-word}.cb{width:64px;white-space:nowrap;color:var(--muted)}.cb span[aria-hidden]{font-size:18px}.cbt{font-size:11px}
.sr{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}
.facts{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:0 24px}.fact{border-bottom:1px solid var(--line);padding:8px 0}.fact b{display:block;color:var(--muted);font-size:12px;font-weight:600}
.special{border-left:6px solid var(--special)}.special h3{font-size:15px;margin:14px 0 4px;color:var(--heading)}.special-banner{font-size:15px}.legend p{margin:6px 0}.muted{color:var(--muted)}footer{padding:16px 2px;color:var(--muted);font-size:12px}
@media(max-width:900px){.cards{grid-template-columns:repeat(2,1fr)}.facts{grid-template-columns:1fr}}
@media print{.copy{display:none!important}a.ext::after{content:" (" attr(href) ")";font-size:9px;overflow-wrap:anywhere}:root{--ink:#16202e;--muted:#5d6a79;--line:#dde3ea;--bg:#ffffff;--panel:#ffffff;--heading:#16365f;--th-bg:#eef2f7;--th-ink:#30475f;--partial-bg:#fff4d6;--partial-ink:#5c4400;--partial-line:#e6c46a}body{background:#fff;color:#16202e}.wrap{max-width:none;padding:0}details{break-inside:avoid}.scroll{overflow:visible}table{min-width:0;font-size:10px}}
</style></head><body><div class="wrap">
'@)
    [void]$sb.AppendLine('<div class="hero"><h1>' + (& $e $title) + '</h1>')
    [void]$sb.AppendLine('<p><strong>' + (& $e $script:ComputerName) + '</strong> &nbsp;&rarr;&nbsp; ' + (& $e $target) + '</p>')
    [void]$sb.AppendLine('<p>Started ' + (& $e $script:CollectionStarted.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)) + ' &nbsp;|&nbsp; Completed ' + (& $e $CompletedTime.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)) + ' &nbsp;|&nbsp; Runtime ' + (& $e $duration) + ' &nbsp;|&nbsp; Collector ' + (& $e $script:CollectorVersion) + '</p>')
    [void]$sb.AppendLine('<p class="verdict">' + $(if ($isPost) { 'Overall post-upgrade result: ' } else { 'Overall IPU assessment: ' }) + (New-StatusBadge $OverallStatus) + '</p></div>')
    if ($Partial) {
        [void]$sb.AppendLine('<div class="partial">PARTIAL REPORT - the slow checks (DISM, SFC, Setup compatibility scan) had not finished when this was written. If this is the newest report, the SA job was stopped before they completed.</div>')
    }
    if ($script:LogWriteFailures -gt 0) {
        [void]$sb.AppendLine('<div class="partial">The collector log is incomplete: ' + $script:LogWriteFailures + ' line(s) could not be written to ' + (& $e $script:LogPath) + '.</div>')
    }
    if (@($coverage.Problems).Count -gt 0) {
        [void]$sb.AppendLine('<div class="partial">Not fully assessed: ' + (& $e (@($coverage.Problems) -join '; ')) + '. The results for these areas may be incomplete - absence of findings there is not evidence of readiness. Details: <a href="#coverage">Collector coverage</a>.</div>')
    }
    foreach ($note in @($coverage.ByChoice)) { [void]$sb.AppendLine('<div class="note"><strong>Not run by choice:</strong> ' + (& $e $note) + '</div>') }

    # Counter cards link to the rows behind them (#77); a zero is not a link.
    $cardTarget = @{ SPECIAL = 'special'; BLOCKER = 'decision'; ACTION = 'decision'; WARNING = 'planning'; MANUAL = 'planning' }
    $card = {
        param([string]$Label, $Count, [string]$Anchor, [string]$What)
        if ($Anchor -and [int]("0" + ([string]$Count -replace '\s.*$','')) -gt 0) {
            return ('<a class="card" href="#' + $Anchor + '" aria-label="' + (& $e ([string]$Count + ' ' + $What + ' - go to the list')) + '"><small>' + (& $e $Label) + '</small><b>' + (& $e ([string]$Count)) + '</b></a>')
        }
        return ('<div class="card"><small>' + (& $e $Label) + '</small><b>' + (& $e ([string]$Count)) + '</b></div>')
    }
    [void]$sb.AppendLine('<div class="cards">')
    # The SPECIAL card only when there is one (#152), so the usual six cards
    # keep their layout.
    foreach ($s in $script:FindingStatuses) { if ($s -eq 'SPECIAL' -and $counts[$s] -eq 0) { continue }; [void]$sb.AppendLine((& $card $s $counts[$s] $cardTarget[$s] ($s + ' findings'))) }
    [void]$sb.AppendLine((& $card 'Checklist items' $checklist.Count 'checklist' 'checklist items'))
    [void]$sb.AppendLine((& $card 'Checks run' (([string]@($CheckRuns | Where-Object { $_.Outcome -eq 'Completed' }).Count) + ' / ' + @($CheckRuns).Count) 'coverage' 'checks completed') + '</div>')

    [void]$sb.AppendLine('<section><h2>Summary</h2><div class="facts">')
    foreach ($f in $facts) {
        $v = [string]$f[1]; if (-not $v) { $v = 'Not reported' }
        [void]$sb.AppendLine('<div class="fact"><b>' + (& $e $f[0]) + '</b>' + (& $e $v) + '</div>')
    }
    [void]$sb.AppendLine('</div></section>')

    # Status meaning right after the Summary, before the tables that use it (#96).
    [void]$sb.AppendLine('<section class="legend"><h2>Status meaning</h2>')
    [void]$sb.AppendLine('<p>' + (New-StatusBadge 'SPECIAL') + ' Not a standard in-place upgrade (cluster node, domain controller): a separate plan, extra time and coordination, more risk. Tell the project and the customer.</p>')
    [void]$sb.AppendLine('<p>' + (New-StatusBadge 'BLOCKER') + ' The selected IPU path or standard procedure does not apply.</p>')
    [void]$sb.AppendLine('<p>' + (New-StatusBadge 'ACTION') + ' Must be fixed or investigated before IPU.</p>')
    [void]$sb.AppendLine('<p>' + (New-StatusBadge 'WARNING') + ' Planning risk.</p>')
    [void]$sb.AppendLine('<p>' + (New-StatusBadge 'MANUAL') + ' Needs human or external verification, or the check could not complete.</p>')
    [void]$sb.AppendLine('<p>' + (New-StatusBadge 'OK') + ' Check passed. ' + (New-StatusBadge 'INFO') + ' Documentation only. Rows marked <em>Observation</em> in the sections below have a status for visibility but do not affect the overall result.</p></section>')

    # SPECIAL server (#152): plain words for the project and the customer,
    # the facts to choose a plan, the risks, then the options to evaluate.
    $special = $script:Data.Special
    if ($special) {
        [void]$sb.AppendLine('<section id="special" class="special"><h2>' + (New-StatusBadge 'SPECIAL') + ' ' + (& $e $special.Title) + ' - not a standard in-place upgrade</h2>')
        [void]$sb.AppendLine('<p class="special-banner"><strong>' + (& $e $special.Banner) + '</strong></p>')
        [void]$sb.AppendLine('<h3>What this server is</h3><ul>')
        foreach ($f in @($special.Facts)) { [void]$sb.AppendLine('<li>' + (& $e $f) + '</li>') }
        [void]$sb.AppendLine('</ul><h3>Risks</h3><ul>')
        foreach ($r in @($special.Risks)) { [void]$sb.AppendLine('<li>' + (& $e $r) + '</li>') }
        [void]$sb.AppendLine('</ul><h3>Options to evaluate</h3><ul>')
        foreach ($o in @($special.Options)) {
            $link = ''; if ($o.Url) { $link = ' <a class="ext" href="' + (& $e $o.Url) + '" rel="noopener">' + (& $e $o.Title) + '</a>' }
            [void]$sb.AppendLine('<li>' + (& $e $o.Text) + $link + '</li>')
        }
        [void]$sb.AppendLine('</ul><p class="lead">This report is short on purpose: the standard checks were not run, because the standard procedure does not apply. Plan this server separately.</p></section>')
    }

    if ($isPost) { [void]$sb.AppendLine('<section id="decision"><h2>Must be resolved</h2><p class="lead">Problems found after the upgrade, including what changed compared with the pre-upgrade snapshot.</p>') }
    else { [void]$sb.AppendLine('<section id="decision"><h2>IPU decision - must be resolved</h2><p class="lead">BLOCKER: this server cannot follow the standard IPU path as configured. ACTION: must be fixed or investigated before the change.</p>') }
    if ($decision.Count -eq 0) { [void]$sb.AppendLine('<p>No BLOCKER or ACTION findings.</p>') } else { [void]$sb.AppendLine((New-FindingTable $decision -WithCheckbox -Caption 'Findings that must be resolved')) }
    [void]$sb.AppendLine('</section>')

    if ($isPost) { [void]$sb.AppendLine('<section id="planning"><h2>Verify</h2><p class="lead">WARNING: check that this is expected. MANUAL: needs a human or external check.</p>') }
    else { [void]$sb.AppendLine('<section id="planning"><h2>IPU planning - validate before the change</h2><p class="lead">WARNING: risk to plan for. MANUAL: needs a human or external check.</p>') }
    if ($planning.Count -eq 0) { [void]$sb.AppendLine('<p>No planning findings.</p>') } else { [void]$sb.AppendLine((New-FindingTable $planning -WithCheckbox -Caption 'Findings to validate before the change')) }
    [void]$sb.AppendLine('</section>')

    if ($checklist.Count -gt 0) {
        [void]$sb.AppendLine('<section id="checklist"><h2>Standard change checklist</h2><p class="lead">Required for every IPU. These do not affect the overall status.</p>')
        [void]$sb.AppendLine((New-FindingTable $checklist -WithCheckbox -Caption 'Standard change checklist'))
        [void]$sb.AppendLine('</section>')
    }


    [void]$sb.AppendLine('<p class="chapters-note">Chapters with findings to act on are open; the others hold inventory and evidence - open them as needed. Printing includes every chapter.<span class="js-only"> <button type="button" class="tgl" data-open="1">Expand all</button> <button type="button" class="tgl" data-open="0">Collapse all</button></span></p>')
    foreach ($chapter in $script:ChapterOrder) {
        $areas = @($script:AreaMap.Keys | Where-Object { $script:AreaMap[$_].Chapter -eq $chapter })
        $rows = @($Results | Where-Object { $areas -contains $_.Area -and $_.Kind -ne 'Checklist' } | Sort-Object @{Expression={Get-AreaName $_.Area}},@{Expression={Get-StatusRank $_.Status}},Item)
        if ($rows.Count -eq 0 -and $chapter -ne 'Assessment and Collector') { continue }
        $open = ''
        # Open when the chapter holds a finding to act on (#97); inventory and
        # evidence chapters start closed.
        if (@($rows | Where-Object { $_.Kind -eq 'Finding' -and $_.Status -in $script:FindingStatuses }).Count -gt 0) { $open = ' open' }
        $chapterId = ''
        if ($chapter -eq 'Assessment and Collector') {
            $chapterId = ' id="coverage"'
            if (@($coverage.Problems).Count -gt 0) { $open = ' open' }
        }
        [void]$sb.AppendLine('<details' + $chapterId + $open + '><summary>' + (& $e $chapter) + ' (' + $rows.Count + ')</summary><div>')
        if ($chapter -eq 'Assessment and Collector') {
            [void]$sb.AppendLine('<h2>Collector coverage</h2><div class="scroll"><table><caption class="sr">Collector coverage: outcome of every check</caption><thead><tr><th scope="col">Check</th><th scope="col">Phase</th><th scope="col">Outcome</th><th scope="col">Duration</th><th scope="col">Message</th></tr></thead><tbody>')
            foreach ($run in $CheckRuns) {
                $st = 'OK'; if ($run.Outcome -eq 'Failed') { $st = 'MANUAL' } elseif ($run.Outcome -ne 'Completed') { $st = 'WARNING' }
                [void]$sb.AppendLine('<tr><td>' + (& $e $run.Name) + '</td><td>' + (& $e $run.Phase) + '</td><td class="nw">' + (New-StatusBadge $st) + ' ' + (& $e $run.Outcome) + '</td><td class="nw">' + (& $e $run.Duration) + '</td><td class="txt">' + (& $e $run.Message) + '</td></tr>')
            }
            [void]$sb.AppendLine('</tbody></table></div><h2 style="margin-top:16px">Records</h2>')
        }
        if ($rows.Count -gt 0) {
            [void]$sb.AppendLine('<div class="scroll"><table><caption class="sr">' + (& $e ($chapter + ': all records')) + '</caption><thead><tr><th scope="col">Status</th><th scope="col">Area</th><th scope="col">Item</th><th scope="col">Value</th><th scope="col">Details</th><th scope="col">Recommendation</th><th scope="col">Source</th></tr></thead><tbody>')
            foreach ($r in $rows) {
                $kindNote = ''; if ($r.Kind -eq 'Observation') { $kindNote = '<br><em class="muted">Observation</em>' }
                [void]$sb.AppendLine('<tr><td class="nw">' + (New-StatusBadge $r.Status) + $kindNote + '</td><td class="nw">' + (& $e (Get-AreaName $r.Area)) + '</td><td class="item">' + (& $e $r.Item) + '</td><td class="txt">' + (& $e $r.Value) + '</td><td class="txt">' + (& $e $r.Details) + '</td><td class="txt">' + (New-RecommendationHtml $r) + '</td><td class="txt muted">' + (& $e $r.Source) + '</td></tr>')
            }
            [void]$sb.AppendLine('</tbody></table></div>')
        }
        [void]$sb.AppendLine('</div></details>')
    }
    [void]$sb.AppendLine('<footer>Collector ' + (& $e $script:CollectorVersion) + ' | ' + @($Results).Count + ' records | Read-only local assessment. It does not prove backups, credentials, licensing or application/vendor support. Commands are shown, never run, by this script.</footer></div>')
    # Copy buttons (#79). Without JavaScript the buttons stay hidden and the
    # command text can be selected as usual.
    [void]$sb.AppendLine('<script type="text/javascript">document.documentElement.className+=" js";document.addEventListener("click",function(e){var b=e.target;if(!b||!b.classList||!b.classList.contains("copy"))return;var t=b.getAttribute("data-cmd");var done=function(){b.textContent="Copied";setTimeout(function(){b.textContent="Copy"},1500)};if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(t).then(done,function(){})}else{var a=document.createElement("textarea");a.value=t;document.body.appendChild(a);a.select();try{document.execCommand("copy");done()}catch(x){}document.body.removeChild(a)}});document.addEventListener("click",function(e){var b=e.target;if(!b||!b.classList||!b.classList.contains("tgl"))return;var o=b.getAttribute("data-open")==="1";var d=document.querySelectorAll("details");for(var i=0;i<d.length;i++){d[i].open=o}});var closedForPrint=[];window.addEventListener("beforeprint",function(){closedForPrint=[];var d=document.querySelectorAll("details:not([open])");for(var i=0;i<d.length;i++){d[i].open=true;closedForPrint.push(d[i])}});window.addEventListener("afterprint",function(){for(var i=0;i<closedForPrint.length;i++){closedForPrint[i].open=false}closedForPrint=[]});</script>')
    [void]$sb.AppendLine('</body></html>')
    return $sb.ToString()
}

function Protect-LogText {
    # Pure apart from the placeholder map (#329): the run log, redacted line by
    # line with the same rules and map as the report, so HOST-2 in the log is
    # HOST-2 in the report. The header line has nothing to redact.
    param([string]$Text, [hashtable]$Context)
    if (-not $Text) { return $Text }
    $lines = @($Text -split '\r?\n')
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($l in $lines) { $out.Add((Protect-ReportText $l $Context)) }
    return ($out.ToArray() -join [Environment]::NewLine)
}

function Write-RedactedLogCopy {
    # A redacted copy of a run log (#329). The original is never changed; the
    # copy's name comes from the redacted report, never from the computer name.
    # Throws when the log cannot be read or the copy cannot be written.
    param([Parameter(Mandatory=$true)][string]$LogPath, [Parameter(Mandatory=$true)][string]$Destination, [Parameter(Mandatory=$true)][hashtable]$Context)
    $text = [IO.File]::ReadAllText($LogPath)
    [IO.File]::WriteAllText($Destination, (Protect-LogText $text $Context), (New-Object System.Text.UTF8Encoding($false)))
}

function Write-AssessmentReport {
    param([switch]$Partial)
    $completed = Get-Date
    $results = $script:Results.ToArray()
    $overall = Get-OverallStatus $results
    $html = New-IPUReportHtml -Results $results -CheckRuns $script:CheckRuns.ToArray() -OverallStatus $overall -CompletedTime $completed -Partial:$Partial
    if ($RedactReport) { $html = Protect-ReportText $html (Get-RedactionContext) }
    if ($html.Length -lt 2048 -or $html -notmatch '(?is)^\s*<!doctype html' -or $html -notmatch '(?is)</html>\s*$') {
        throw ('HTML validation failed (length {0}).' -f $html.Length)
    }
    $temp = $script:ReportPath + '.writing'
    [IO.File]::WriteAllText($temp,$html,(New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $script:ReportPath -Force -ErrorAction Stop
    $info = Get-Item -LiteralPath $script:ReportPath -ErrorAction Stop
    Write-AssessmentLog 'INFO' 'REPORT' ('Written. Partial={0} | Overall={1} | Bytes={2}' -f [bool]$Partial,$overall,$info.Length)
    $jsonOutcome = 'Disabled'
    if ($WriteJson) {
        try {
            Write-AssessmentJson -Results $results -Overall $overall -Completed $completed -Partial:$Partial
            $jsonOutcome = 'Written'; if ($Partial) { $jsonOutcome = 'Partial' }
        } catch {
            $jsonOutcome = 'Failed'
            Write-AssessmentLog 'WARNING' 'JSON' ('JSON result could not be written: ' + $_.Exception.Message)
        }
    }
    # A redacted copy of the log beside the redacted reports (#329), at the
    # end of the run only. The log itself stays unredacted for troubleshooting;
    # lines written after this point are not in the copy.
    if ($RedactReport -and -not $Partial) {
        $logCopy = [IO.Path]::ChangeExtension($script:ReportPath, '.log')
        try {
            Write-AssessmentLog 'INFO' 'REDACTION' ('Redacted copy of this log: ' + (Split-Path -Leaf $logCopy))
            Write-RedactedLogCopy $script:LogPath $logCopy (Get-RedactionContext)
        } catch { Write-AssessmentLog 'WARNING' 'REDACTION' ('Redacted log copy could not be written: ' + $_.Exception.Message) }
    }
    # The key to the placeholders (#211), after the HTML, the JSON and the log
    # copy so it holds every placeholder they use.
    if ($RedactReport -and $WriteRedactionKey) {
        $keyPath = Join-Path (Split-Path -Parent $script:ReportPath) ('DO-NOT-SHARE-' + $script:SafeComputerName + $script:ReportSuffix + '-REDACTION-KEY.csv')
        try { $script:Data.RedactionKey = Write-RedactionKey (Get-RedactionContext) $keyPath }
        catch { Write-AssessmentLog 'WARNING' 'REDACTION' ('Redaction key could not be written: ' + $_.Exception.Message) }
    }
    return [pscustomobject]@{ Overall=$overall; Completed=$completed; Bytes=$info.Length; JsonOutcome=$jsonOutcome }
}

function New-AssessmentJsonObject {
    # The machine-readable result: used by Merge-IPUAssessments.ps1 for the
    # fleet overview, and as the baseline for the post-upgrade comparison.
    param([object[]]$Results, [string]$Overall, [datetime]$Completed, [switch]$Partial)
    $counts = [ordered]@{}
    foreach ($s in $script:FindingStatuses) { $counts[$s] = @($Results | Where-Object { $_.Kind -eq 'Finding' -and $_.Status -eq $s }).Count }
    $snapshot = $script:Data.Snapshot
    if (-not $snapshot) { $snapshot = @{} }
    return [pscustomobject][ordered]@{
        Schema              = 'IPU-Assessment/1'
        CollectorVersion    = $script:CollectorVersion
        ComputerName        = $script:ComputerName
        Mode                = $AssessmentMode
        TargetServerVersion = $TargetServerVersion
        Started             = $script:CollectionStarted.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
        Completed           = $Completed.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
        UtcOffset           = (Format-UtcOffset ([TimeZoneInfo]::Local.GetUtcOffset($Completed)))
        Partial             = [bool]$Partial
        Redacted            = $false
        Overall             = $Overall
        Counts              = [pscustomobject]$counts
        Facts               = [pscustomobject][ordered]@{
            CurrentOS        = (Get-ResultText $Results 'UPGRADE_PATH' 'CurrentOS')
            SourceRelease    = $script:Data.SourceRelease
            UpgradePath      = (Get-ResultText $Results 'UPGRADE_PATH' 'TargetUpgradePath')
            RecommendedMedia = $script:Data.RecommendedMedia
            Platform         = (Get-ResultText $Results 'PLATFORM' 'PhysicalOrVirtual')
            DomainRole       = $script:Data.DomainRoleText
            Uac              = $script:Data.UacSummary
            Nla              = $(if ($script:Data.NlaState) { [string]$script:Data.NlaState } else { 'Unknown' })
            AdLocation       = $script:Data.AdLocation
            SqlServer        = $script:Data.SqlSummary
            Activation       = $script:Data.ActivationSummary
            CDrive           = $script:Data.CSummary
            CompatScan       = (Get-ResultText $Results 'COMPAT_SCAN' 'SetupCompatibilityScan')
        }
        Results             = @($Results | Select-Object CheckId,Area,Item,Status,Kind,Value,Details,Recommendation,Source,Command,CommandKind,Link,LinkTitle)
        CheckRuns           = @($script:CheckRuns.ToArray() | Select-Object Id,Name,Phase,Outcome,Duration,Message)
        EolCandidates       = @($script:Data.EolCandidates | Where-Object { $_ } | Select-Object Product,Version,Source,Evidence)
        Snapshot            = [pscustomobject]$snapshot
        Special             = $(if ($script:Data.Special) { [pscustomobject][ordered]@{ Kind = $script:Data.Special.Kind; Title = $script:Data.Special.Title; Banner = $script:Data.Special.Banner; Facts = @($script:Data.Special.Facts); Risks = @($script:Data.Special.Risks); Options = @($script:Data.Special.Options | ForEach-Object { [pscustomobject][ordered]@{ Text = $_.Text; Url = $_.Url; Title = $_.Title } }) } } else { $null })
    }
}

function Get-RedactionLiteralFromResult {
    # Pure (#101): the names a run collected for redaction, recovered from
    # the rows of an existing result - task run-as accounts, service logon
    # accounts, GPO names and WMI filter names. Returns value/kind pairs.
    param([object[]]$Results)
    $found = @()
    foreach ($r in @($Results)) {
        if ($r.Area -eq 'TASKS' -and [string]$r.Value -match '^RunAs=(.+)$') { $found += [pscustomobject]@{ Value = $Matches[1]; Kind = 'ACCOUNT' } }
        if ($r.Area -eq 'SERVICES' -and [string]$r.Details -match '(?:^|\|\s*)LogOnAs=([^|]+)') { $found += [pscustomobject]@{ Value = $Matches[1].Trim(); Kind = 'ACCOUNT' } }
        if ($r.Area -eq 'GROUP_POLICY' -and [string]$r.Item -match '^GPO: (.+)$') { $found += [pscustomobject]@{ Value = $Matches[1]; Kind = 'GPO' } }
        if ($r.Area -eq 'GROUP_POLICY' -and [string]$r.Details -match '(?:^|\|\s*)WMI filter: ([^|]+)') { $found += [pscustomobject]@{ Value = $Matches[1].Trim(); Kind = 'NAME' } }
        # Cluster and node names (#152).
        if ($r.Area -eq 'CLUSTER' -and [string]$r.Item -match '^Node: (.+)$') { $found += [pscustomobject]@{ Value = $Matches[1]; Kind = 'HOST' } }
        if ($r.Area -eq 'CLUSTER' -and $r.Item -eq 'ClusterMembership' -and [string]$r.Value -match '^Cluster=(.+)$') { $found += [pscustomobject]@{ Value = $Matches[1]; Kind = 'HOST' } }
        # The KMS host that activated the server (#171).
        # Like the live run, the host name and its first label (#124).
        if ($r.Area -eq 'LICENSING' -and (@($r.Details) -join ' | ') -match 'KMS host: ([^\s:|(]+)') { foreach ($h in @($Matches[1], ($Matches[1] -split '\.')[0]) | Select-Object -Unique) { $found += [pscustomobject]@{ Value = $h; Kind = 'HOST' } } }
        # File shares (#172): the share name from the per-share row, and its
        # description.
        if ($r.Area -eq 'FILE_SHARES' -and [string]$r.Item -match '^Share: (.+)$') { $found += [pscustomobject]@{ Value = $Matches[1]; Kind = 'NAME' } }
        if ($r.Area -eq 'FILE_SHARES' -and (@($r.Details) -join ' | ') -match '(?:^|\|\s*)Description=([^|]+)') { $found += [pscustomobject]@{ Value = $Matches[1].Trim(); Kind = 'NAME' } }
        # Named SQL Server instances and their instance ids (#195).
        if ($r.Area -eq 'SQL' -and [string]$r.Item -match '^(?:Database Engine|Reporting Services|Analysis Services): (.+)$' -and $script:SqlDefaultInstanceNames -notcontains $Matches[1]) {
            $found += [pscustomobject]@{ Value = $Matches[1]; Kind = 'NAME' }
            if ((@($r.Details) -join ' | ') -match '(?:^|\|\s*)InstanceId=([^|\s]+)') { $found += [pscustomobject]@{ Value = $Matches[1]; Kind = 'NAME' } }
        }
        # Print servers (#148): printer, share and port names, port host names.
        if ($r.Area -eq 'PRINTING' -and [string]$r.Item -match '^(?:Printer|Port): (.+)$') { $found += [pscustomobject]@{ Value = $Matches[1]; Kind = 'NAME' } }
        if ($r.Area -eq 'PRINTING' -and (@($r.Details) -join ' | ') -match '(?:^|\|\s*)Share=([^|]+)' -and $Matches[1].Trim() -ne '(not shared)') { $found += [pscustomobject]@{ Value = $Matches[1].Trim(); Kind = 'NAME' } }
        if ($r.Area -eq 'PRINTING' -and (@($r.Details) -join ' | ') -match '(?:^|\|\s*)Address=([^|:\s]+)' -and $Matches[1] -notmatch '^[0-9.]+$') { $found += [pscustomobject]@{ Value = $Matches[1]; Kind = 'HOST' } }
    }
    return ,$found
}

function Invoke-RedactExisting {
    # -RedactExisting (#101): writes REDACTED- copies of existing reports
    # without collecting anything. The originals are not changed. Returns the
    # exit code: 0 when at least one report was redacted.
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { [Console]::Out.WriteLine('RedactExisting: not found: ' + $Path); return 1 }
    $item = Get-Item -LiteralPath $Path
    if ($item.PSIsContainer) {
        $jsonFiles = @(Get-ChildItem -LiteralPath $Path -File | Where-Object { $_.Name -match '-IPU-(Assessment|PostUpgrade)\.json$' -and $_.Name -notlike 'REDACTED-*' })
    } elseif ($item.Name -match '-IPU-(Assessment|PostUpgrade)\.(json|html)$') {
        # SilentlyContinue: No JSON beside the HTML is reported just below (no report found).
        $jsonFiles = @(Get-Item -LiteralPath ([IO.Path]::ChangeExtension($item.FullName, '.json')) -ErrorAction SilentlyContinue)
    } else { $jsonFiles = @() }
    if ($jsonFiles.Count -eq 0) { [Console]::Out.WriteLine('RedactExisting: no *-IPU-Assessment.json or *-IPU-PostUpgrade.json report found in ' + $Path); return 1 }
    # One placeholder map for the whole folder (#157): a server keeps the
    # same placeholder in its pre- and post-upgrade report, and different
    # servers get different ones. The key file (#211) is the only place the
    # map is written to disk.
    $shared = @{ Map = @{}; Counters = @{}; Originals = @{} }
    $jsonFiles = @($jsonFiles | Sort-Object Name)
    # Number the servers first, in name order (#172): HOST-1..HOST-n in the
    # file names, before other host names in the reports take numbers.
    $names = @()
    foreach ($jf in $jsonFiles) { try { $names += [string]([IO.File]::ReadAllText($jf.FullName) | ConvertFrom-Json).ComputerName } catch { Write-Swallowed $_ } }
    foreach ($n in @($names | Where-Object { $_ } | Sort-Object -Unique)) { $null = Get-RedactionPlaceholder $shared 'HOST' $n }
    $stampAll = (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
    $done = 0
    foreach ($jf in $jsonFiles) {
        try {
            $obj = [IO.File]::ReadAllText($jf.FullName) | ConvertFrom-Json
            if ($obj.Schema -ne 'IPU-Assessment/1') { throw 'not an IPU-Assessment/1 result' }
            if ($obj.PSObject.Properties['Redacted'] -and $obj.Redacted) { [Console]::Out.WriteLine('RedactExisting: already redacted, skipped: ' + $jf.Name); continue }
            $domain = ''
            $member = @($obj.Results | Where-Object { $_.Area -eq 'ACCESS' -and $_.Item -eq 'DomainMembership' -and [string]$_.Value -match '^Domain=' }) | Select-Object -First 1
            if ($member) { $domain = ([string]$member.Value).Substring(7) }
            $script:Data = @{}
            foreach ($l in (Get-RedactionLiteralFromResult @($obj.Results))) { Add-RedactionLiteral $l.Value $l.Kind }
            $ctx = New-RedactionContext ([string]$obj.ComputerName) $domain
            $ctx.Map = $shared.Map; $ctx.Counters = $shared.Counters; $ctx.Originals = $shared.Originals
            if ($script:Data.RedactLiterals) { foreach ($k in @($script:Data.RedactLiterals.Keys)) { $ctx.Literals[$k] = $script:Data.RedactLiterals[$k] } }
            $suffix = '-IPU-Assessment'; if ($jf.Name -match '-IPU-PostUpgrade\.json$') { $suffix = '-IPU-PostUpgrade' }
            # The placeholder in the file name pairs a server's pre and post
            # copies (#157), e.g. REDACTED-<time>-HOST-2-IPU-PostUpgrade.json.
            $hostTag = 'HOST-0'; if ($obj.ComputerName) { $hostTag = Get-RedactionPlaceholder $ctx 'HOST' ([string]$obj.ComputerName) }
            $base = Join-Path $jf.DirectoryName ('REDACTED-' + $stampAll + '-' + $hostTag + $suffix)
            $n = 2; $first = $base
            while (Test-Path -LiteralPath ($base + '.json')) { $base = $first + '-' + $n; $n++ }
            $red = Protect-ReportObject $obj $ctx
            $red | Add-Member -NotePropertyName Redacted -NotePropertyValue $true -Force
            [IO.File]::WriteAllText($base + '.json', ($red | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
            $html = [IO.Path]::ChangeExtension($jf.FullName, '.html')
            $note = ''; $written = '.json'
            if (Test-Path -LiteralPath $html) {
                [IO.File]::WriteAllText($base + '.html', (Protect-ReportText ([IO.File]::ReadAllText($html)) $ctx), (New-Object System.Text.UTF8Encoding($false)))
                $written += '/.html'
            } else { $note += ' (no HTML report next to it)' }
            # The run log beside the report (#329), with the same placeholders.
            $log = [IO.Path]::ChangeExtension($jf.FullName, '.log')
            if (Test-Path -LiteralPath $log) {
                try { Write-RedactedLogCopy $log ($base + '.log') $ctx; $written += '/.log' }
                catch { $note += ' (the log could not be redacted: ' + $_.Exception.Message + ')' }
            }
            [Console]::Out.WriteLine('RedactExisting: ' + $jf.Name + ' -> ' + (Split-Path -Leaf $base) + $written + $note)
            $done++
        } catch {
            [Console]::Out.WriteLine('RedactExisting: could not redact ' + $jf.Name + ': ' + $_.Exception.Message)
        }
    }
    if ($done -gt 0) {
        [Console]::Out.WriteLine('RedactExisting: ' + $done + ' report(s) redacted. Redaction is best effort - read the copies before sharing them.')
        if ($WriteRedactionKey) {
            $folder = $(if ($item.PSIsContainer) { $item.FullName } else { $item.DirectoryName })
            $keyPath = Join-Path $folder ('DO-NOT-SHARE-REDACTION-KEY-' + $stampAll + '.csv')
            try {
                $null = Write-RedactionKey $shared $keyPath
                [Console]::Out.WriteLine('RedactExisting: redaction key written: ' + (Split-Path -Leaf $keyPath) + ' - it holds the real names. Keep it in the team; share only the REDACTED-* files.')
            } catch { [Console]::Out.WriteLine('RedactExisting: the redaction key could not be written: ' + $_.Exception.Message) }
        }
        return 0
    }
    return 1
}

function Write-RedactionKey {
    # Writes the redaction key (#211): which placeholder stands for which
    # original. UTF-8 with BOM so Excel shows non-ASCII names. Access is
    # limited to SYSTEM, Administrators and the current user (best effort).
    param([Parameter(Mandatory=$true)][hashtable]$Context, [Parameter(Mandatory=$true)][string]$Path)
    $originals = @{}
    if ($Context.ContainsKey('Originals') -and $Context.Originals) { $originals = $Context.Originals }
    $lines = ConvertTo-RedactionKeyLine $originals
    [IO.File]::WriteAllText($Path, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    try {
        $security = New-Object System.Security.AccessControl.FileSecurity
        $security.SetAccessRuleProtection($true, $false)
        $sids = @('S-1-5-18', 'S-1-5-32-544', [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value) | Select-Object -Unique
        foreach ($sid in $sids) {
            $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
            $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($identity, [System.Security.AccessControl.FileSystemRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow)))
        }
        Set-Acl -LiteralPath $Path -AclObject $security -ErrorAction Stop
    } catch { Write-Swallowed $_ }
    return $Path
}

function Get-RedactionContext {
    # One context per run, so placeholders match between the checkpoint and
    # the final report, and between the HTML and the JSON.
    if (-not $script:RedactionContext) {
        $domain = ''
        if ($script:Data.CS -and $script:Data.CS.PartOfDomain) { $domain = [string]$script:Data.CS.Domain }
        $script:RedactionContext = New-RedactionContext $script:ComputerName $domain
    }
    # Names collected so far (the checkpoint and the final report share them).
    if ($script:Data.RedactLiterals) {
        foreach ($k in @($script:Data.RedactLiterals.Keys)) { $script:RedactionContext.Literals[$k] = $script:Data.RedactLiterals[$k] }
    }
    return $script:RedactionContext
}

function Write-AssessmentJson {
    param([object[]]$Results, [string]$Overall, [datetime]$Completed, [switch]$Partial)
    $obj = New-AssessmentJsonObject -Results $Results -Overall $Overall -Completed $Completed -Partial:$Partial
    if ($RedactReport) {
        $obj = Protect-ReportObject $obj (Get-RedactionContext)
        $obj.Redacted = $true
    }
    $json = $obj | ConvertTo-Json -Depth 6
    # A Pre run writes the file the Post run compares against. Re-running Pre
    # (after the upgrade, or stopped after a checkpoint) must not silently
    # replace a complete baseline: keep it as a dated copy first (#239).
    if ($AssessmentMode -eq 'Pre' -and $script:JsonPath -eq $script:BaselinePath -and $null -eq $script:BaselineKept -and (Test-Path -LiteralPath $script:JsonPath)) {
        try {
            $existing = Get-Content -LiteralPath $script:JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (Test-BaselineKeepCopy $existing ([bool]$Partial) (Get-ReleaseDisplayName $script:Data.SourceRelease)) {
                $kept = $script:JsonPath -replace '\.json$', ('-' + (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture) + '.json')
                Copy-Item -LiteralPath $script:JsonPath -Destination $kept -ErrorAction Stop
                $script:BaselineKept = $kept
                Write-AssessmentLog 'INFO' 'BASELINE' ('Kept the earlier pre-upgrade result as ' + $kept)
            }
        } catch { Write-AssessmentLog 'WARNING' 'BASELINE' ('Could not keep the earlier pre-upgrade result: ' + $_.Exception.Message) }
    }
    $temp = $script:JsonPath + '.writing'
    [IO.File]::WriteAllText($temp,$json,(New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $script:JsonPath -Force -ErrorAction Stop
}

function Import-SiteDataFile {
    # Reads -PatternFile and -ProfileFile (both optional) and applies them,
    # all or nothing. Without either file, nothing changes and no row is
    # written. A file that cannot be used gives a MANUAL finding.
    if ($PatternFile) {
        $hash = ''
        try {
            $text = [IO.File]::ReadAllText($PatternFile)
            try { $hash = (Get-FileHash -LiteralPath $PatternFile -Algorithm SHA256 -ErrorAction Stop).Hash } catch { Write-Swallowed $_ }
            $obj = ConvertFrom-SiteDataJson $text 'IPU-Patterns/1'
            $merge = Merge-DetectionPatternSet $script:DetectionPatterns $obj
            if (@($merge.Errors).Count -gt 0) { throw (@($merge.Errors) -join ' | ') }
            $script:DetectionPatterns = $merge.Patterns
            Add-Result 'COLLECTOR' 'Pattern file' 'INFO' ('Applied, ' + @($merge.Changes).Count + ' change(s)') (@($merge.Changes) + @('SHA256=' + $hash)) -Source $PatternFile
            Write-AssessmentLog 'INFO' 'SITEDATA' ('Pattern file applied: ' + $PatternFile + ' | ' + (@($merge.Changes) -join '; '))
        } catch {
            Add-Result 'COLLECTOR' 'Pattern file' 'MANUAL' 'Not applied; the built-in detection patterns were used' @($_.Exception.Message, $(if ($hash) { 'SHA256=' + $hash })) -Recommendation 'Fix the file (user guide, "Site data files") and re-run. Until then, products your site added to the file are not detected.' -Kind 'Finding' -Source $PatternFile
            Write-AssessmentLog 'WARNING' 'SITEDATA' ('Pattern file not applied: ' + $_.Exception.Message)
        }
    }
    if ($ProfileFile) {
        $hash = ''
        try {
            $text = [IO.File]::ReadAllText($ProfileFile)
            try { $hash = (Get-FileHash -LiteralPath $ProfileFile -Algorithm SHA256 -ErrorAction Stop).Hash } catch { Write-Swallowed $_ }
            $obj = ConvertFrom-SiteDataJson $text 'IPU-Profile/1'
            $attributes = @{}
            foreach ($n in $script:ProfileSettingNames) {
                # SilentlyContinue: A setting name without a variable has no attributes to check.
                $v = Get-Variable -Name $n -ErrorAction SilentlyContinue
                if ($v) { $attributes[$n] = @($v.Attributes) }
            }
            $decision = Get-ProfileSettingDecision $obj $attributes $script:ProfileSettingNames $script:BoundParameterNames
            if (@($decision.Errors).Count -gt 0) { throw (@($decision.Errors) -join ' | ') }
            $details = @()
            foreach ($k in @($decision.Settings.Keys)) {
                Set-Variable -Name $k -Value $decision.Settings[$k] -Scope Script
                $details += ($k + '=' + (@($decision.Settings[$k]) -join ','))
            }
            foreach ($k in @($decision.Ignored)) { $details += ($k + ': the argument given to the script was used') }
            # The report folder exists before the profile is read (#261): say so
            # instead of applying the setting silently to the evidence folders only.
            $aclNote = Get-ProfileAclNote $decision.Settings.Contains('RestrictOutputAcl') ([string]$script:OutputFolderState)
            if ($aclNote) { $details += $aclNote }
            if ($decision.Settings.Contains('NumberCultureName')) {
                $script:NumberCultureResolved = Resolve-NumberCulture ([string]$decision.Settings['NumberCultureName'])
                $script:NumberCulture = $script:NumberCultureResolved.Culture
            }
            Add-Result 'COLLECTOR' 'Profile file' 'INFO' ('Applied, ' + $decision.Settings.Count + ' setting(s)') ($details + @('SHA256=' + $hash)) -Source $ProfileFile
            Write-AssessmentLog 'INFO' 'SITEDATA' ('Profile file applied: ' + $ProfileFile + ' | ' + ($details -join '; '))
        } catch {
            Add-Result 'COLLECTOR' 'Profile file' 'MANUAL' 'Not applied; the built-in defaults and the arguments were used' @($_.Exception.Message, $(if ($hash) { 'SHA256=' + $hash })) -Recommendation 'Fix the file (user guide, "Site data files") and re-run. Until then, thresholds and policy are the built-in defaults, not your site''s.' -Kind 'Finding' -Source $ProfileFile
            Write-AssessmentLog 'WARNING' 'SITEDATA' ('Profile file not applied: ' + $_.Exception.Message)
        }
    }
}

function Invoke-PostUpgradeComparison {
    $script:CurrentCheckId = 'postcompare'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $outcome = 'Completed'; $message = ''
    try {
        $reached = ($script:Data.SourceRelease -eq $TargetServerVersion)
        if ($reached) { Add-Result 'POST_UPGRADE' 'UpgradeReachedTarget' 'OK' ('Now ' + (Get-ReleaseDisplayName $script:Data.SourceRelease)) -Source 'Win32_OperatingSystem build' }
        else { Add-Result 'POST_UPGRADE' 'UpgradeReachedTarget' 'ACTION' ('Now ' + (Get-ReleaseDisplayName $script:Data.SourceRelease) + ', expected ' + (Get-ReleaseDisplayName $TargetServerVersion)) '' -Recommendation 'The upgrade did not complete or was rolled back. Read C:\$WINDOWS.~BT\Sources\Panther\setuperr.log and C:\Windows\Panther\setuperr.log.' -Source 'Win32_OperatingSystem build' }

        if (-not (Test-Path -LiteralPath $script:BaselinePath)) {
            Add-Result 'POST_UPGRADE' 'Baseline' 'MANUAL' 'No pre-upgrade result found' $script:BaselinePath -Recommendation 'Without the pre-upgrade JSON the before/after comparison cannot run. Compare services, ports and routes manually with the pre-upgrade HTML report.' -Source 'File check'
            return
        }
        $baseline = Get-Content -LiteralPath $script:BaselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($baseline.Redacted) {
            Add-Result 'POST_UPGRADE' 'Baseline' 'MANUAL' 'The pre-upgrade result is redacted' $script:BaselinePath -Recommendation 'A redacted result has its names and addresses replaced, so it cannot be compared with this server. Keep an unredacted pre-upgrade run (without -RedactReport) as the baseline and redact only copies you share.' -Source 'File check'
            return
        }
        Add-Result 'POST_UPGRADE' 'Baseline' 'INFO' ('Pre-upgrade run ' + $baseline.Completed + ' (collector ' + $baseline.CollectorVersion + ')') @(('Overall then=' + $baseline.Overall),('OS then=' + $baseline.Facts.CurrentOS)) -Source $script:BaselinePath
        if ($baseline.Partial) {
            Add-Result 'POST_UPGRADE' 'BaselineComplete' 'WARNING' 'The pre-upgrade result was a partial (checkpoint) report' '' -Recommendation 'The snapshot data is still complete (it is collected by the fast checks); only the slow checks were missing.' -Kind 'Observation' -Source $script:BaselinePath
        }
        $before = $baseline.Snapshot
        # Baselines from 4.3.0 and older have no NLA in the snapshot: read it
        # from the pre-upgrade RDP listener row (#158).
        if ($before -and -not $before.PSObject.Properties['Nla']) {
            $listener = @($baseline.Results | Where-Object { $_.Area -eq 'RDP' -and $_.Item -eq 'Listener' }) | Select-Object -First 1
            if ($listener -and (@($listener.Details) -join ' ') -match 'NLA=(\d)') { $before | Add-Member -NotePropertyName Nla -NotePropertyValue $(if ($Matches[1] -eq '0') { 'Off' } else { 'On' }) -Force }
        }
        if ($before -and $before.PSObject.Properties['Nla']) { $script:Data.NlaBefore = [string]$before.Nla }
        # What the comparison cannot cover (#239): an empty or partial baseline,
        # a SPECIAL short report, a check that did not complete, a baseline
        # taken after the upgrade. "Comparison OK" only when nothing is left out.
        $coverage = @(Get-BaselineCoverageRow $baseline $script:ComputerName (Get-ReleaseDisplayName $TargetServerVersion))
        foreach ($c in $coverage) { Add-Result 'POST_UPGRADE' $c.Item $c.Status $c.Value $c.Details -Recommendation $c.Recommendation -Kind 'Finding' -Source 'Pre-upgrade result' }
        # And what THIS run could not read (#306): such a list is left out of
        # the comparison, not read as empty, which would call every entry lost.
        $after = [pscustomobject]$script:Data.Snapshot
        $gaps = @(Get-CurrentListGap $before $after $script:CheckRuns.ToArray())
        if ($gaps.Count -gt 0) {
            Add-Result 'POST_UPGRADE' 'CurrentCoverage' 'MANUAL' ($gaps.Count.ToString() + ' list(s) could not be read in this run') @($gaps | ForEach-Object { $_.List + ' (' + $_.Reason + ')' }) -Recommendation 'These lists were read before the upgrade but not now, so they are left out of the comparison instead of showing every entry as lost. See the COLLECTOR rows for the check that failed, fix the cause and run Post again, or compare these lists by hand with the pre-upgrade report.' -Kind 'Finding' -Source 'This run'
            $before = Get-SnapshotWithoutList $before @($gaps | ForEach-Object { $_.List })
        }
        $diffs = Compare-IPUSnapshot $before $after
        foreach ($d in $diffs) { Add-Result 'POST_UPGRADE' $d.Item $d.Status $d.Value $d.Details -Recommendation $d.Recommendation -Source 'Pre-upgrade snapshot vs now' }
        if ($diffs.Count -eq 0 -and $coverage.Count -eq 0 -and $gaps.Count -eq 0) { Add-Result 'POST_UPGRADE' 'Comparison' 'OK' 'No lost services, ports, routes, IP/DNS settings, hosts entries, applications, features or tasks' -Source 'Pre-upgrade snapshot vs now' }
    } catch {
        $outcome = 'Failed'; $message = $_.Exception.Message
        Add-Result 'COLLECTOR' 'Post-upgrade comparison' 'MANUAL' 'Check did not complete' $message -Recommendation 'Compare manually with the pre-upgrade report.' -Kind 'Finding'
    } finally {
        $sw.Stop()
        $script:CheckRuns.Add([pscustomobject]@{ Id='postcompare'; Name='Post-upgrade comparison'; Phase='Fast'; Outcome=$outcome; Duration=(Format-Duration $sw.Elapsed); Seconds=[math]::Round($sw.Elapsed.TotalSeconds,1); Message=$message })
        $script:CurrentCheckId = 'core'
    }
}


