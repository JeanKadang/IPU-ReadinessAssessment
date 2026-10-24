# =============================================================================
# 3. CORE
# =============================================================================
$ProgressPreference = 'SilentlyContinue'
$script:CollectorVersion  = '4.5.4'
# Settings a profile file (-ProfileFile) may set. Mode, target, media path,
# report folder and redaction describe one run, so they stay arguments only.
$script:ProfileSettingNames = @(
    'TargetMediaLanguage','BlockDomainControllerIPU',
    'MinimumCFreeGB','ExtendBlockGB','MinimumMemoryGB','MaxPatchAgeDays','UptimeWarningDays','GroupPolicyMaxAgeDays','AVMaxAgeDays',
    'CertificateWarningDays','SystemPartitionMinFreeMB','RecoveryPartitionMinFreeMB',
    'RunDISMScanHealth','RunSFCVerifyOnly','DISMTimeoutMinutes','SFCTimeoutMinutes','SlowCheckBudgetMinutes','CompatScanTimeoutMinutes',
    'EvidenceRoot','EnableRDPPolicyEvidence','LgpoExe','PolicyEvidenceRoot','CreatePolicyEvidenceZip','EnableIISConfigEvidence','EnableNetworkEvidence','EnablePrintBackup','PrintBackupTimeoutMinutes',
    'WriteJson','RestrictOutputAcl','NumberCultureName','WriteRedactionKey'
)
$script:PatternFields = @('Label','App','Service','Display','Driver','Disabled','Link','LinkTitle')
$script:Results           = New-Object System.Collections.Generic.List[object]
$script:CheckRuns         = New-Object System.Collections.Generic.List[object]
$script:Checks            = New-Object System.Collections.Generic.List[object]
$script:Data              = @{}
$script:CurrentCheckId    = 'core'
$script:CurrentCheckOutcome = $null
$script:CurrentCheckMessage = $null
$script:LogWriteFailures  = 0
$script:SlowSecondsLeft   = 0
$script:CollectionStarted = Get-Date
$script:ComputerName      = $env:COMPUTERNAME
if (-not $script:ComputerName) { $script:ComputerName = [Environment]::MachineName }
$script:SafeComputerName  = ($script:ComputerName -replace '[^A-Za-z0-9_.-]','_')
$script:ReportSuffix      = $(if ($AssessmentMode -eq 'Post') { '-IPU-PostUpgrade' } else { '-IPU-Assessment' })
$script:ReportBaseName    = $script:SafeComputerName + $script:ReportSuffix
# A redacted report must not carry the computer name in its file name.
if ($RedactReport) { $script:ReportBaseName = 'REDACTED-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + $script:ReportSuffix }
$script:ReportPath        = [IO.Path]::Combine($ReportDirectory, $script:ReportBaseName + '.html')
$script:LogPath           = [IO.Path]::Combine($ReportDirectory, $script:SafeComputerName + $script:ReportSuffix + '.log')
$script:JsonPath          = [IO.Path]::Combine($ReportDirectory, $script:ReportBaseName + '.json')
$script:BaselinePath      = [IO.Path]::Combine($ReportDirectory, $script:SafeComputerName + '-IPU-Assessment.json')

function Resolve-NumberCulture {
    # An unknown name must not pass silently: .NET Framework builds a culture
    # for any well-formed name, so the exception is not a reliable test. The
    # name has to be one of the cultures this server knows (#139). Not known:
    # the invariant culture, and Known = $false so the report can say so.
    param([string]$Name)
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    if (-not $Name) { return [pscustomobject]@{ Culture = $invariant; Known = $false } }
    $known = @([System.Globalization.CultureInfo]::GetCultures([System.Globalization.CultureTypes]::AllCultures) | Where-Object { $_.Name -ieq $Name })
    if ($known.Count -eq 0) { return [pscustomobject]@{ Culture = $invariant; Known = $false } }
    try { return [pscustomobject]@{ Culture = (New-Object System.Globalization.CultureInfo($known[0].Name)); Known = $true } }
    catch { return [pscustomobject]@{ Culture = $invariant; Known = $false } }
}

$script:NumberCultureResolved = Resolve-NumberCulture $NumberCultureName
$script:NumberCulture = $script:NumberCultureResolved.Culture

# SPECIAL (#152): not a standard IPU (cluster node, domain controller) - a
# separate plan, extra time and coordination, more risk. Ranks above BLOCKER.
$script:StatusOrder  = @('SPECIAL','BLOCKER','ACTION','WARNING','MANUAL','OK','INFO')
$script:FindingStatuses = @('SPECIAL','BLOCKER','ACTION','WARNING','MANUAL')
$script:ValidKinds   = @('Finding','Observation','Evidence','Checklist')
# Get-OverallStatus counts Findings only. A MANUAL row that is an Observation or Evidence would be left out of the overall status, so a failed read could still end in OK (#240). Add-Result refuses that combination unless the area is listed here with the reason.
$script:ManualNotCounted = @{
    AGENTS = 'A management agent that is not found may simply not be expected on this server; the row asks the operator to confirm in the backend and must not turn every such server MANUAL.'
}

# The single definition of report areas. Name = what readers see, Chapter =
# which collapsible chapter the area belongs to.
$script:ChapterOrder = @(
    'Post-Upgrade Comparison',
    'Upgrade Path, Licensing and Windows Health',
    'Workloads and Applications',
    'Hardware and Virtualization',
    'Storage',
    'Clustering',
    'Network',
    'Access and Remote Desktop',
    'IIS and Remote Desktop Services',
    'PKI and Certificates',
    'Security and Antivirus',
    'Management Agents',
    'Backup and Recovery',
    'Services and Scheduled Tasks',
    'Assessment and Collector'
)
$script:AreaMap = @{
    'POST_UPGRADE'       = @{ Name='Before/after comparison';     Chapter='Post-Upgrade Comparison' }
    'COMPAT_SCAN'        = @{ Name='Setup compatibility scan';    Chapter='Upgrade Path, Licensing and Windows Health' }
    'FEATURE_LIFECYCLE'  = @{ Name='Removed/deprecated features'; Chapter='Workloads and Applications' }
    'VMWARE'             = @{ Name='VMware guest readiness';      Chapter='Hardware and Virtualization' }
    'DRIVERS'            = @{ Name='Non-Microsoft drivers';       Chapter='Hardware and Virtualization' }
    'PORTS'              = @{ Name='Listening ports';             Chapter='Network' }
    'TASKS'              = @{ Name='Scheduled tasks';             Chapter='Services and Scheduled Tasks' }
    'UPGRADE_PATH'       = @{ Name='Upgrade path and media';      Chapter='Upgrade Path, Licensing and Windows Health' }
    'LICENSING'          = @{ Name='Windows activation';          Chapter='Upgrade Path, Licensing and Windows Health' }
    'WINDOWS_HEALTH'     = @{ Name='Windows health';              Chapter='Upgrade Path, Licensing and Windows Health' }
    'UPGRADE_HISTORY'    = @{ Name='Upgrade history';             Chapter='Upgrade Path, Licensing and Windows Health' }
    'EXCHANGE'           = @{ Name='Exchange Server';             Chapter='Workloads and Applications' }
    'SQL'                = @{ Name='SQL Server';                  Chapter='Workloads and Applications' }
    'SPECIAL'            = @{ Name='Special server';              Chapter='Upgrade Path, Licensing and Windows Health' }
    'DOMAIN_CONTROLLER'  = @{ Name='Domain controller';           Chapter='Workloads and Applications' }
    'WORKLOAD'           = @{ Name='Roles and workloads';         Chapter='Workloads and Applications' }
    'FILE_SHARES'        = @{ Name='File shares';                 Chapter='Workloads and Applications' }
    'PRINTING'           = @{ Name='Print server';                Chapter='Workloads and Applications' }
    'ROLES'              = @{ Name='Installed roles/features';    Chapter='Workloads and Applications' }
    'APPLICATIONS'       = @{ Name='Installed applications';      Chapter='Workloads and Applications' }
    'PLATFORM'           = @{ Name='Platform';                    Chapter='Hardware and Virtualization' }
    'HARDWARE'           = @{ Name='Physical hardware';           Chapter='Hardware and Virtualization' }
    'PERFORMANCE'        = @{ Name='CPU and memory';              Chapter='Hardware and Virtualization' }
    'STORAGE'            = @{ Name='Storage';                     Chapter='Storage' }
    'CLUSTER'            = @{ Name='Failover clustering';         Chapter='Clustering' }
    'NETWORK'            = @{ Name='Network adapters and teaming';Chapter='Network' }
    'NETWORK_DEPENDENCY' = @{ Name='Hosts file and static routes';Chapter='Network' }
    'ACCESS'             = @{ Name='Access and credentials';      Chapter='Access and Remote Desktop' }
    'RDP'                = @{ Name='RDP access and policy';       Chapter='Access and Remote Desktop' }
    'GROUP_POLICY'       = @{ Name='Group Policy and AD groups';  Chapter='Access and Remote Desktop' }
    'POLICY_EVIDENCE'    = @{ Name='Policy evidence files';       Chapter='Access and Remote Desktop' }
    'IIS'                = @{ Name='IIS';                         Chapter='IIS and Remote Desktop Services' }
    'RDS'                = @{ Name='Remote Desktop Services';     Chapter='IIS and Remote Desktop Services' }
    'PKI'                = @{ Name='Certification Authority';     Chapter='PKI and Certificates' }
    'CERTIFICATES'       = @{ Name='Certificates and bindings';   Chapter='PKI and Certificates' }
    'ANTIVIRUS'          = @{ Name='Antivirus';                   Chapter='Security and Antivirus' }
    'SECURITY'           = @{ Name='Security configuration';      Chapter='Security and Antivirus' }
    'AGENTS'             = @{ Name='Management agents';           Chapter='Management Agents' }
    'BACKUP'             = @{ Name='Backup and VSS';              Chapter='Backup and Recovery' }
    'SERVICES'           = @{ Name='Services';                    Chapter='Services and Scheduled Tasks' }
    'CHECKLIST'          = @{ Name='Change checklist';            Chapter='Assessment and Collector' }
    'COLLECTOR'          = @{ Name='Collector coverage';          Chapter='Assessment and Collector' }
    'ASSESSMENT'         = @{ Name='Assessment metadata';         Chapter='Assessment and Collector' }
}

function Write-AssessmentLog {
    param([string]$Level = 'INFO', [string]$Phase = '', [string]$Message = '')
    try {
        $line = '{0};{1};{2};{3}{4}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Phase,(($Message -replace '[\r\n;]+',' | ')),[Environment]::NewLine
        [IO.File]::AppendAllText($script:LogPath,$line,(New-Object System.Text.UTF8Encoding($false)))
    } catch {
        # The log itself cannot record this; count it so the report can say
        # the log is incomplete. Logging must never stop the assessment.
        $script:LogWriteFailures++
    }
}

function ConvertTo-CleanText {
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    $s = [string]$Value
    $s = $s -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]',''
    $s = $s -replace '[\r\n]+',' | '
    return $s.Trim()
}

function ConvertTo-SAField {
    param([object]$Value)
    return ((ConvertTo-CleanText $Value) -replace ';',',')
}

function Write-Swallowed {
    # Records an intentionally ignored failure of an optional query in the log,
    # so "not found" and "could not look" can be told apart afterwards.
    param($ErrorRecord)
    try {
        $where = ''
        if ($ErrorRecord -and $ErrorRecord.InvocationInfo) { $where = ' (line ' + $ErrorRecord.InvocationInfo.ScriptLineNumber + ')' }
        Write-AssessmentLog 'DEBUG' $script:CurrentCheckId ('Optional query failed' + $where + ': ' + $ErrorRecord.Exception.Message)
    } catch {
        $script:LogWriteFailures++
    }
}

function Test-NotFoundError {
    # The storage, network and CIM-based cmdlets raise an ObjectNotFound error
    # when a filter matches nothing (no listener on a port, no persistent
    # route). That is an empty answer, not a failed query (#242). The error
    # category is used, never the message text, which is localised.
    param($ErrorRecord)
    return ($null -ne $ErrorRecord -and $null -ne $ErrorRecord.CategoryInfo -and [string]$ErrorRecord.CategoryInfo.Category -eq 'ObjectNotFound')
}

function Find-DetectionMatch {
    # Pure: matches one pattern table (section 2) against the inventories and
    # returns one object per detected product with the evidence that matched.
    param([object[]]$Patterns, [object[]]$Apps = @(), [object[]]$Services = @(), [string[]]$Drivers = @())
    $found = @()
    foreach ($pattern in $Patterns) {
        $mApps = @(); $mSvcs = @(); $mDrv = @()
        if ($pattern.App) { $mApps = @($Apps | Where-Object { $_.Name -match $pattern.App -and $_.Name -notmatch 'VirtualBox' }) }
        if ($pattern.Service -or $pattern.Display) {
            $mSvcs = @($Services | Where-Object { ($pattern.Service -and $_.Name -match $pattern.Service) -or ($pattern.Display -and $_.DisplayName -match $pattern.Display) })
        }
        if ($pattern.Driver) { $mDrv = @($Drivers | Where-Object { $_ -match $pattern.Driver }) }
        if (($mApps.Count + $mSvcs.Count + $mDrv.Count) -gt 0) {
            $found += [pscustomobject]@{ Label=$pattern.Label; Apps=$mApps; Services=$mSvcs; Drivers=$mDrv; Link=[string]$pattern.Link; LinkTitle=[string]$pattern.LinkTitle }
        }
    }
    return ,$found
}

function Get-DetectionEvidence {
    param($Match)
    $parts = @()
    # "version" before the number, so redaction does not take it for an
    # IPv4 address (#194).
    foreach ($a in $Match.Apps) { $parts += $(if ($a.Version) { $a.Name + ' version ' + $a.Version } else { [string]$a.Name }) }
    foreach ($s in $Match.Services) { $parts += ('Service ' + $s.Name + ' (' + $s.State + ')') }
    if (@($Match.Drivers).Count -gt 0) { $parts += ('Drivers ' + (@($Match.Drivers) -join ',')) }
    return ,$parts
}

function Format-Duration {
    param([TimeSpan]$Duration)
    if ($Duration.Days -gt 0) {
        return ('{0}.{1:00}:{2:00}:{3:00}' -f $Duration.Days,$Duration.Hours,$Duration.Minutes,$Duration.Seconds)
    }
    return ('{0:00}:{1:00}:{2:00}' -f [math]::Floor($Duration.TotalHours),$Duration.Minutes,$Duration.Seconds)
}

function Format-Number {
    param([double]$Value, [int]$Decimals = 2)
    return $Value.ToString(('N' + $Decimals), $script:NumberCulture)
}

function Add-Result {
    param(
        [Parameter(Mandatory=$true,Position=0)][string]$Area,
        [Parameter(Mandatory=$true,Position=1)][string]$Item,
        [Parameter(Position=2)][ValidateSet('SPECIAL','BLOCKER','ACTION','WARNING','MANUAL','OK','INFO')][string]$Status = 'INFO',
        [Parameter(Position=3)][object]$Value = '',
        [Parameter(Position=4)][object]$Details = '',
        [string]$Recommendation = '',
        [string]$Kind = '',
        [string]$Source = '',
        # Optional "how" and "read more" (#79). The script only shows the
        # command; it never runs it. Check = read-only, Change = run in the
        # change window.
        [string]$Command = '',
        [ValidateSet('','Check','Change')][string]$CommandKind = '',
        [string]$Link = '',
        [string]$LinkTitle = ''
    )
    if ($Command -and -not $CommandKind) { throw 'Add-Result: -Command needs -CommandKind Check or Change.' }
    if ($Link -and $Link -notmatch '^https://[^\s"<>]+$') { throw ('Add-Result: -Link must be an https URL: ' + $Link) }
    if (-not $script:AreaMap.ContainsKey($Area)) { throw ("Unknown report area '{0}'. Add it to `$script:AreaMap." -f $Area) }
    if (-not $Kind) {
        if ($script:FindingStatuses -contains $Status) { $Kind = 'Finding' } else { $Kind = 'Evidence' }
    }
    if ($script:ValidKinds -notcontains $Kind) { throw ("Unknown result kind '{0}'." -f $Kind) }
    if ($Status -eq 'MANUAL' -and (@('Observation','Evidence') -contains $Kind) -and -not $script:ManualNotCounted.ContainsKey($Area)) {
        throw ("Add-Result: a MANUAL row in {0} ('{1}') must be a Finding so it counts towards the overall status. Use -Kind Finding, or add the area to $script:ManualNotCounted with the reason." -f $Area, $Item)
    }
    $detailParts = @()
    foreach ($part in @($Details)) {
        $clean = ConvertTo-CleanText $part
        if ($clean) { $detailParts += $clean }
    }
    $script:Results.Add([pscustomobject]@{
        CheckId        = $script:CurrentCheckId
        Area           = $Area
        Item           = (ConvertTo-CleanText $Item)
        Status         = $Status
        Kind           = $Kind
        Value          = (ConvertTo-CleanText $Value)
        Details        = ($detailParts -join ' | ')
        Recommendation = (ConvertTo-CleanText $Recommendation)
        Source         = (ConvertTo-CleanText $Source)
        Command        = (ConvertTo-CleanText $Command)
        CommandKind    = $(if ($Command) { $CommandKind } else { '' })
        Link           = $Link
        LinkTitle      = $(if ($Link) { $(if ($LinkTitle) { ConvertTo-CleanText $LinkTitle } else { $Link }) } else { '' })
    })
}

function Register-Check {
    param(
        [Parameter(Mandatory=$true)][string]$Id,
        [Parameter(Mandatory=$true)][string]$Name,
        [ValidateSet('Fast','Slow')][string]$Phase = 'Fast',
        [Parameter(Mandatory=$true)][scriptblock]$Script
    )
    $script:Checks.Add([pscustomobject]@{ Id=$Id; Name=$Name; Phase=$Phase; Script=$Script })
}

function Invoke-Check {
    param([Parameter(Mandatory=$true)]$Check)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $script:CurrentCheckId = $Check.Id
    $script:CurrentCheckOutcome = $null
    $script:CurrentCheckMessage = $null
    $outcome = 'Completed'
    $message = ''
    Write-AssessmentLog 'INFO' $Check.Id 'Started.'
    try {
        # Inside a check every error is terminating. Optional queries must use
        # -ErrorAction SilentlyContinue or try/catch explicitly, so an
        # unexpected failure is visible instead of looking like a clean result.
        $ErrorActionPreference = 'Stop'
        # try/catch does not catch break or continue: left alone, one inside a
        # check would end the caller's loop and drop the rest of the phase.
        # The do/while is the loop they end instead (#251).
        $ranToEnd = $false
        do {
            $null = & $Check.Script
            $ranToEnd = $true
        } while ($false)
        if (-not $ranToEnd) { throw 'The check left the runner with break or continue before it finished; its remaining rows are missing' }
        if ($script:CurrentCheckOutcome) { $outcome = $script:CurrentCheckOutcome }
        if ($script:CurrentCheckMessage) { $message = $script:CurrentCheckMessage }
    } catch {
        $outcome = 'Failed'
        $message = $_.Exception.GetType().Name + ': ' + $_.Exception.Message
        $position = ''
        if ($_.InvocationInfo) { $position = 'Line ' + $_.InvocationInfo.ScriptLineNumber }
        Write-AssessmentLog 'ERROR' $Check.Id ($message + ' | ' + $position)
        try {
            Add-Result 'COLLECTOR' $Check.Name 'MANUAL' 'Check did not complete' @($message,$position) -Recommendation 'This area was only partially assessed. Absence of findings here is NOT evidence of readiness. Review it manually, or fix the cause and re-run.' -Kind 'Finding' -Source ('Check ' + $Check.Id)
        } catch { Write-Swallowed $_ }
    }
    $sw.Stop()
    $script:CheckRuns.Add([pscustomobject]@{
        Id=$Check.Id; Name=$Check.Name; Phase=$Check.Phase; Outcome=$outcome
        Duration=(Format-Duration $sw.Elapsed); Seconds=[math]::Round($sw.Elapsed.TotalSeconds,1); Message=$message
    })
    Write-AssessmentLog 'INFO' $Check.Id ('Finished. Outcome={0} | Duration={1}' -f $outcome,(Format-Duration $sw.Elapsed))
    $script:CurrentCheckId = 'core'
}

# Extra SIDs for restricted folders. Always empty in a real run; the test
# suite adds the current user when it runs unelevated, so it can still use
# and clean up the folders it creates (#126).
$script:ExtraRestrictedSids = @()

function New-RestrictedDirectorySecurity {
    # SYSTEM and Administrators full control, inheritance from the parent
    # removed. Built from SIDs so it works on every OS language.
    param([string[]]$ExtraSids = $script:ExtraRestrictedSids)
    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($sid in (@('S-1-5-18', 'S-1-5-32-544') + @($ExtraSids | Where-Object { $_ }) | Select-Object -Unique)) {
        $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, [System.Security.AccessControl.FileSystemRights]::FullControl, $inherit, [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)
    }
    return $security
}

function Set-RestrictedFolderAcl {
    param([string]$Path)
    Set-Acl -LiteralPath $Path -AclObject (New-RestrictedDirectorySecurity) -ErrorAction Stop
}

function New-RestrictedFolder {
    # Creates the folder together with its restricted access list. Windows
    # PowerShell (.NET Framework) has Directory.CreateDirectory(path, security);
    # PowerShell 7 (.NET) has it as an extension method. Throws when neither
    # works, and Initialize-OutputFolder then falls back to create + Set-Acl.
    param([string]$Path)
    $security = New-RestrictedDirectorySecurity
    try { [void][System.IO.Directory]::CreateDirectory($Path, $security) }
    catch {
        $ext = 'System.IO.FileSystemAclExtensions' -as [type]
        if (-not $ext) { throw }
        [void]$ext::CreateDirectory($security, $Path)
    }
}

function Initialize-OutputFolder {
    # Creates a folder for the script's own output. Only a folder created by
    # this run is restricted; an existing folder keeps its permissions (it may
    # be shared, e.g. C:\Temp) and the report says whether it is too open.
    param([string]$Path, [bool]$Restrict = $RestrictOutputAcl)
    if (Test-Path -LiteralPath $Path -PathType Container) { return 'Existing' }
    if ($Restrict) {
        # Created with its access list in one call, so there is no moment
        # when the folder exists with inherited permissions (#139).
        try { New-RestrictedFolder $Path; return 'CreatedRestricted' }
        catch { Write-Swallowed $_ }
    }
    New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
    if (-not $Restrict) { return 'Created' }
    try {
        Set-RestrictedFolderAcl $Path
        return 'CreatedRestricted'
    } catch {
        Write-AssessmentLog 'WARNING' 'ACL' ('Could not restrict ' + $Path + ': ' + $_.Exception.Message)
        return 'CreatedUnrestricted'
    }
}

function Initialize-EvidenceFolder {
    # The topic folder for an evidence copy (#198), created with the same
    # restricted access as the report folder. The evidence root gets a
    # README that says what is there and that it is unredacted (best effort).
    param([Parameter(Mandatory=$true)][ValidateSet('Policy','IIS','Network','Printers')][string]$Topic)
    $folder = Get-EvidenceFolderPath $EvidenceRoot $Topic $PolicyEvidenceRoot
    if ($Topic -ne 'Policy' -or -not $PolicyEvidenceRoot) {
        $null = Initialize-OutputFolder $EvidenceRoot
        $readme = Join-Path $EvidenceRoot 'README.txt'
        if (-not (Test-Path -LiteralPath $readme)) {
            try { [IO.File]::WriteAllText($readme, (Get-EvidenceReadmeText)) } catch { Write-Swallowed $_ }
        }
    }
    $null = Initialize-OutputFolder $folder
    return $folder
}

function Get-GpResultXml {
    # Runs "gpresult /scope computer /x" into a temp file and returns the
    # XML text. Throws with gpresult's own message when it fails.
    $file = Join-Path ([IO.Path]::GetTempPath()) ('IPU-gpresult-' + [guid]::NewGuid().ToString('N') + '.xml')
    try {
        $r = Invoke-NativeCapture (Join-Path $env:windir 'System32\gpresult.exe') @('/scope','computer','/x',$file,'/f') 180
        if ($r.TimedOut) { throw 'gpresult did not finish within 3 minutes' }
        if (-not (Test-Path -LiteralPath $file)) { throw ('gpresult wrote no result (exit ' + $r.ExitCode + '): ' + (@($r.Lines) -join ' ')) }
        return [IO.File]::ReadAllText($file)
    } finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

function Get-GpoListRegistryEntry {
    # The GPOs that applied at the last machine policy refresh, as recorded
    # by the Group Policy service (#160). Readable as SYSTEM when gpresult
    # says the computer "does not have RSoP data". Read-only.
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\GPO-List'
    $list = @()
    # The subkeys are numbered in hexadecimal (0..9, a, b, ...); [int]'a'
    # failed and, inside a check, stopped the whole read (#223).
    foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction Stop | Sort-Object { ConvertFrom-GpoListKeyName ([string]$_.PSChildName) })) {
        $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if ($p) { $list += [pscustomobject]@{ DisplayName = [string]$p.DisplayName; GPOName = [string]$p.GPOName; Link = [string]$p.Link } }
    }
    return ,$list
}

function ConvertFrom-GpoListEntry {
    # Pure (#160): registry GPO-List entries -> the same shape as
    # ConvertFrom-GpResultXml. Only applied GPOs are recorded there, without
    # filter names; WMI filters are still looked up in AD by GUID.
    param([object[]]$Entries)
    $gpos = @()
    foreach ($e in @($Entries)) {
        if (-not $e.DisplayName) { continue }
        $link = [string]$e.Link
        if ($link -match '^LDAP://(.+)$') { $link = ConvertTo-AdLocation ('CN=x,' + $Matches[1]) }
        $guid = [string]$e.GPOName
        if ($guid -and $guid -notmatch '^\{') { $guid = '' }
        $gpos += [pscustomobject]@{ Name = [string]$e.DisplayName; Guid = $guid; Applied = $true; Reason = ''; Links = @($link | Where-Object { $_ }); FilterName = '' }
    }
    return [pscustomobject]@{ Domain = ''; Site = ''; Gpos = $gpos; Groups = @() }
}

function Get-AdComputerGroup {
    # The computer object's security groups from AD, nested groups included
    # (tokenGroups), read as the computer account itself - no RSAT needed.
    $searcher = New-Object System.DirectoryServices.DirectorySearcher
    $searcher.Filter = '(&(objectCategory=computer)(sAMAccountName=' + $env:COMPUTERNAME + '$))'
    $searcher.ClientTimeout = [TimeSpan]::FromSeconds(30)
    $hit = $searcher.FindOne()
    if (-not $hit) { throw ('Computer object ' + $env:COMPUTERNAME + '$ not found in AD') }
    $entry = $hit.GetDirectoryEntry()
    $entry.RefreshCache([string[]]@('tokenGroups'))
    $names = @()
    foreach ($bytes in @($entry.Properties['tokenGroups'])) {
        $sid = New-Object System.Security.Principal.SecurityIdentifier ([byte[]]$bytes), 0
        try { $names += $sid.Translate([System.Security.Principal.NTAccount]).Value } catch { $names += $sid.Value }
    }
    return ,@($names | Sort-Object -Unique)
}

function Get-AdComputerDn {
    # The computer object's distinguished name, read as the computer account.
    $searcher = New-Object System.DirectoryServices.DirectorySearcher
    $searcher.Filter = '(&(objectCategory=computer)(sAMAccountName=' + $env:COMPUTERNAME + '$))'
    $searcher.ClientTimeout = [TimeSpan]::FromSeconds(30)
    $null = $searcher.PropertiesToLoad.Add('distinguishedName')
    $hit = $searcher.FindOne()
    if (-not $hit) { throw ('Computer object ' + $env:COMPUTERNAME + '$ not found in AD') }
    return [string]$hit.Properties['distinguishedname'][0]
}

function ConvertTo-AdLocation {
    # Pure (#99): "CN=SRV01,OU=Web,OU=Servers,DC=corp,DC=example,DC=test" ->
    # "corp.example.test/Servers/Web" (the way AD tools show the OU path).
    # Commas escaped with a backslash inside a name are kept.
    param([string]$DistinguishedName)
    if (-not $DistinguishedName) { return '' }
    $parts = [regex]::Split($DistinguishedName, '(?<!\\),')
    $dc = @(); $ou = @()
    foreach ($p in $parts) {
        if ($p -match '^\s*DC=(.+)$') { $dc += $Matches[1] }
        elseif ($p -match '^\s*(OU|CN)=(.+)$') { $ou += ($Matches[2] -replace '\\,', ',') }
    }
    if ($ou.Count -gt 0) { $ou = $ou[1..($ou.Count - 1)] }   # drop the computer's own CN
    [array]::Reverse($ou)
    return ((@(($dc -join '.')) + @($ou)) -join '/')
}

function Get-WmiFilterQuery {
    # WMI filter name and queries for the given GPO GUIDs, from AD.
    # Returns GUID -> @{ Name; Queries }; GPOs without a filter are absent.
    param([string[]]$GpoGuids)
    $result = @{}
    $root = New-Object System.DirectoryServices.DirectoryEntry('LDAP://RootDSE')
    $nc = [string]$root.Properties['defaultNamingContext'][0]
    foreach ($guid in @($GpoGuids | Where-Object { $_ } | Sort-Object -Unique)) {
        $s = New-Object System.DirectoryServices.DirectorySearcher([ADSI]('LDAP://CN=Policies,CN=System,' + $nc))
        $s.ClientTimeout = [TimeSpan]::FromSeconds(30); $s.ServerTimeLimit = [TimeSpan]::FromSeconds(30)
        $s.Filter = '(&(objectClass=groupPolicyContainer)(cn=' + $guid + '))'
        $null = $s.PropertiesToLoad.Add('gPCWQLFilter')
        $gpo = $s.FindOne()
        if (-not $gpo -or $gpo.Properties['gpcwqlfilter'].Count -eq 0) { continue }
        $link = [string]$gpo.Properties['gpcwqlfilter'][0]
        $m = [regex]::Match($link, '\{[0-9A-Fa-f-]{36}\}')
        if (-not $m.Success) { continue }
        $f = New-Object System.DirectoryServices.DirectorySearcher([ADSI]('LDAP://CN=SOM,CN=WMIPolicy,CN=System,' + $nc))
        $f.ClientTimeout = [TimeSpan]::FromSeconds(30); $f.ServerTimeLimit = [TimeSpan]::FromSeconds(30)
        $f.Filter = '(&(objectClass=msWMI-Som)(msWMI-ID=' + $m.Value + '))'
        foreach ($p in 'msWMI-Name','msWMI-Parm2') { $null = $f.PropertiesToLoad.Add($p) }
        $hit = $f.FindOne()
        if (-not $hit) { continue }
        $result[$guid] = @{ Name = [string]$hit.Properties['mswmi-name'][0]; Queries = (ConvertFrom-WmiFilterParm ([string]$hit.Properties['mswmi-parm2'][0])) }
    }
    return $result
}

function Get-GroupPolicyLastApplied {
    # Last time the computer's Group Policy core processing ran, from the
    # registry (FILETIME as two DWORDs). $null when not recorded.
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\Extension-List\{00000000-0000-0000-0000-000000000000}'
    $hi = Get-RegistryValueSafe $key 'EndTimeHi'
    $lo = Get-RegistryValueSafe $key 'EndTimeLo'
    if (-not $hi.Exists -or -not $lo.Exists) { return $null }
    return (ConvertFrom-FileTimeValue $hi.Value $lo.Value)
}

function New-ZipFromFolder {
    # Zips a folder with .NET 4.5 (System.IO.Compression.FileSystem), which
    # Windows PowerShell 4.0 does not load by default. The type is resolved
    # after Add-Type, so a missing assembly is a clear error (#94).
    param([Parameter(Mandatory=$true)][string]$Folder, [Parameter(Mandatory=$true)][string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipType = 'System.IO.Compression.ZipFile' -as [type]
    $level = 'System.IO.Compression.CompressionLevel' -as [type]
    if (-not $zipType -or -not $level) { throw '.NET Framework 4.5 or later is needed to create ZIP files.' }
    $zipType::CreateFromDirectory($Folder, $ZipPath, $level::Optimal, $false)
}

function Save-IISConfigEvidence {
    # Copies the IIS configuration files into a new, restricted evidence
    # folder and zips it (#76). Read-only for IIS: nothing under inetsrv is
    # written. applicationHost.config can hold encrypted secrets, so the
    # folder gets the same SYSTEM/Administrators-only access as the other
    # evidence. Throws when nothing could be copied.
    param(
        [Parameter(Mandatory=$true)][string]$Destination,
        [string]$SourceFolder = (Join-Path $env:windir 'System32\inetsrv\config'),
        [bool]$Zip = $true
    )
    $files = @(Get-ChildItem -LiteralPath $SourceFolder -Filter '*.config' -File -ErrorAction Stop)
    if ($files.Count -eq 0) { throw ('No .config files found in ' + $SourceFolder) }
    $null = Initialize-OutputFolder $Destination
    foreach ($f in $files) { Copy-Item -LiteralPath $f.FullName -Destination $Destination -Force -ErrorAction Stop }
    $hash = ''
    $appHost = Join-Path $Destination 'applicationHost.config'
    if (Test-Path -LiteralPath $appHost) {
        try { $hash = (Get-FileHash -LiteralPath $appHost -Algorithm SHA256 -ErrorAction Stop).Hash } catch { Write-Swallowed $_ }
    }
    # Shared configuration: redirection.config points to the real files.
    $shared = ''
    $redirection = Join-Path $Destination 'redirection.config'
    if (Test-Path -LiteralPath $redirection) {
        try {
            [xml]$doc = [IO.File]::ReadAllText($redirection)
            $node = $doc.SelectSingleNode('//configurationRedirection')
            if ($node -and [string]$node.GetAttribute('enabled') -eq 'true') { $shared = [string]$node.GetAttribute('path') }
        } catch { Write-Swallowed $_ }
    }
    $location = $Destination
    if ($Zip) {
        $zipPath = $Destination + '.zip'
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
        New-ZipFromFolder $Destination $zipPath
        $location = $zipPath
    }
    return [pscustomobject]@{ Location = $location; Folder = $Destination; Files = @($files | ForEach-Object { $_.Name } | Sort-Object); ApplicationHostSha256 = $hash; SharedConfigPath = $shared }
}

function Save-NetworkEvidence {
    # Saves the output of read-only network commands into a new, restricted
    # evidence folder (#149): what the network team needs to put the IP
    # configuration back by hand if the upgrade resets an adapter. Never
    # redacted and never part of the report, so it gets the same
    # SYSTEM/Administrators-only access as the other evidence. Every command
    # has a timeout; one that fails is listed in Failed. Throws when nothing
    # could be saved.
    param(
        [Parameter(Mandatory=$true)][string]$Destination,
        [bool]$Zip = $true,
        [int]$TimeoutSeconds = 60
    )
    $sys = Join-Path $env:windir 'System32'
    $commands = @(
        @{ File = 'ipconfig-all.txt';           Exe = (Join-Path $sys 'ipconfig.exe'); Args = @('/all') },
        @{ File = 'route-print.txt';            Exe = (Join-Path $sys 'route.exe');    Args = @('print') },
        @{ File = 'netsh-ipv4-show-config.txt'; Exe = (Join-Path $sys 'netsh.exe');    Args = @('interface', 'ipv4', 'show', 'config') },
        @{ File = 'netsh-interface-dump.txt';   Exe = (Join-Path $sys 'netsh.exe');    Args = @('-c', 'interface', 'dump') }
    )
    # The evidence root first, so a root created by this run is restricted too.
    $null = Initialize-OutputFolder (Split-Path -Parent $Destination)
    $null = Initialize-OutputFolder $Destination
    $utf8 = New-Object System.Text.UTF8Encoding($true)
    $saved = @(); $failed = @()
    foreach ($c in $commands) {
        $label = [IO.Path]::GetFileNameWithoutExtension($c.Exe) + ' ' + ($c.Args -join ' ')
        $r = Invoke-NativeCapture $c.Exe $c.Args $TimeoutSeconds
        if ($r.Error) { $failed += ($label + ': ' + $r.Error); continue }
        if ($r.TimedOut) { $failed += ($label + ': no answer within ' + $TimeoutSeconds + ' seconds'); continue }
        if ($r.ExitCode -ne 0 -or -not [string]$r.Output) { $failed += ($label + ': exit code ' + $r.ExitCode + ', no output'); continue }
        $text = '# ' + $label + "`r`n# " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "`r`n`r`n" + ([string]$r.Output -replace '\r?\n', "`r`n") + "`r`n"
        [IO.File]::WriteAllText((Join-Path $Destination $c.File), $text, $utf8)
        $saved += $c.File
    }
    # Advanced adapter properties (offloads, jumbo frames, VLAN) are not in
    # the netsh dump; the NetAdapter module is optional (#94).
    if (Test-CommandAvailable 'Get-NetAdapterAdvancedProperty') {
        try {
            $props = @(Get-NetAdapterAdvancedProperty -ErrorAction Stop | Sort-Object Name, DisplayName)
            $text = ($props | Format-Table Name, DisplayName, DisplayValue, RegistryKeyword -AutoSize | Out-String -Width 300)
            [IO.File]::WriteAllText((Join-Path $Destination 'adapter-advanced-properties.txt'), $text, $utf8)
            $saved += 'adapter-advanced-properties.txt'
        } catch { $failed += ('Get-NetAdapterAdvancedProperty: ' + $_.Exception.Message) }
    }
    if ($saved.Count -eq 0) { throw ('No network command output could be saved: ' + ($failed -join '; ')) }
    $location = $Destination
    if ($Zip) {
        $zipPath = $Destination + '.zip'
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
        New-ZipFromFolder $Destination $zipPath
        $location = $zipPath
    }
    return [pscustomobject]@{ Location = $location; Folder = $Destination; Files = $saved; Failed = $failed }
}

# Print servers (#148): read-only helpers for the printers and printbackup
# checks. Defined here (script scope), not inside Register-AssessmentCheck.
function Get-FileCompanyName {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    try { return [string]([Diagnostics.FileVersionInfo]::GetVersionInfo($Path).CompanyName) } catch { return '' }
}

function Get-PrintMonitorInventory {
    # Port monitors and print processors registered with the spooler, with
    # the company name of their DLL (registry and file version reads only).
    $sys = Join-Path $env:windir 'System32'
    $items = @()
    $monitors = 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors'
    foreach ($k in @(Get-ChildItem -LiteralPath $monitors -ErrorAction Stop)) {
        $drv = [string](Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).Driver
        $path = $(if ($drv -and [IO.Path]::IsPathRooted($drv)) { $drv } elseif ($drv) { Join-Path $sys $drv } else { '' })
        $items += [pscustomobject]@{ Type = 'PortMonitor'; Name = [string]$k.PSChildName; Driver = $drv; Company = (Get-FileCompanyName $path) }
    }
    $processors = 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Environments\Windows x64\Print Processors'
    foreach ($k in @(Get-ChildItem -LiteralPath $processors -ErrorAction SilentlyContinue)) {
        $drv = [string](Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).Driver
        $path = $(if ($drv -and [IO.Path]::IsPathRooted($drv)) { $drv } elseif ($drv) { Join-Path $sys ('spool\prtprocs\x64\' + $drv) } else { '' })
        $items += [pscustomobject]@{ Type = 'PrintProcessor'; Name = [string]$k.PSChildName; Driver = $drv; Company = (Get-FileCompanyName $path) }
    }
    return ,$items
}

function Get-PrintDriverStoreSize {
    # Size of spool\drivers, every architecture: the PrintBrm export holds
    # every driver package, so this is the estimate for the backup.
    $root = Join-Path $env:windir 'System32\spool\drivers'
    $sum = [long]0
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue)) { $sum += [long]$f.Length }
    return $sum
}

function Get-PrinterInventory {
    # Printers, ports and drivers from the PrintManagement module, or from
    # CIM where the module is missing (#94). Returns plain records.
    $out = [pscustomobject]@{ Printers = @(); Ports = @(); Drivers = @(); Source = '' }
    if (Test-CommandAvailable 'Get-Printer') {
        $out.Source = 'Get-Printer, Get-PrinterPort, Get-PrinterDriver'
        $out.Printers = @(Get-Printer -ErrorAction Stop | Where-Object { [string]$_.Type -ne 'Connection' } | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_.Name; ShareName = [string]$_.ShareName; Shared = [bool]$_.Shared; Published = [bool]$_.Published; DriverName = [string]$_.DriverName; PortName = [string]$_.PortName }
        })
        $out.Ports = @(Get-PrinterPort -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_.Name; Description = [string]$_.Description; Monitor = [string]$_.PortMonitor; Address = [string]$_.PrinterHostAddress; PortNumber = [string]$_.PortNumber; Protocol = [string]$_.Protocol; Queue = [string]$_.LprQueueName }
        })
        $out.Drivers = @(Get-PrinterDriver -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_.Name; Environment = [string]$_.PrinterEnvironment; Major = [string]$_.MajorVersion; Manufacturer = [string]$_.Manufacturer }
        })
        return $out
    }
    $out.Source = 'Win32_Printer, Win32_TCPIPPrinterPort, Win32_PrinterDriver'
    $out.Printers = @(Get-CimRequired 'Win32_Printer' 'Local=True' | ForEach-Object {
        [pscustomobject]@{ Name = [string]$_.Name; ShareName = [string]$_.ShareName; Shared = [bool]$_.Shared; Published = [bool]$_.Published; DriverName = [string]$_.DriverName; PortName = [string]$_.PortName }
    })
    $out.Ports = @(Get-CimSafe 'Win32_TCPIPPrinterPort' | ForEach-Object {
        [pscustomobject]@{ Name = [string]$_.Name; Description = 'Standard TCP/IP Port'; Monitor = 'TCPMON.DLL'; Address = [string]$_.HostAddress; PortNumber = [string]$_.PortNumber; Protocol = [string]$_.Protocol; Queue = [string]$_.Queue }
    })
    # Win32_PrinterDriver.Name is "<driver>,<version>,<environment>".
    $out.Drivers = @(Get-CimSafe 'Win32_PrinterDriver' | ForEach-Object {
        $p = @(([string]$_.Name) -split ',')
        [pscustomobject]@{ Name = $p[0]; Environment = $(if ($p.Count -gt 2) { $p[2] } else { [string]$_.SupportedPlatform }); Major = $(if ($p.Count -gt 1) { $p[1] } else { [string]$_.Version }); Manufacturer = '' }
    })
    return $out
}

# Optional PowerShell modules and the checks that need them (#94). A missing
# module does not stop the run; the affected checks report it.
$script:OptionalModules = [ordered]@{
    ServerManager  = 'roles and features (baseline, workloads, IIS, RDS, clustering)'
    Storage        = 'storage (disks, partitions, volumes)'
    NetAdapter     = 'network adapters and teaming'
    NetTCPIP       = 'listening ports, routes and IP configuration'
    ScheduledTasks = 'scheduled tasks'
    Dism           = 'Setup compatibility scan (image selection)'
    SmbShare       = 'file shares'
}

function Get-PrerequisiteDecision {
    # Pure (#94): what is missing for a reliable run, in words an operator can
    # act on. Required items stop the run before anything is collected;
    # optional items only reduce what some checks can see.
    param(
        [Version]$PowerShellVersion,
        [int]$DotNetRelease,
        [bool]$IsElevated,
        [string[]]$MissingModules = @(),
        [hashtable]$ModuleUse = $script:OptionalModules
    )
    $required = @()
    if ($null -eq $PowerShellVersion -or $PowerShellVersion.Major -lt 4) {
        $required += ('Windows PowerShell 4.0 or later (found ' + $(if ($PowerShellVersion) { $PowerShellVersion.ToString() } else { 'unknown' }) + '). Install Windows Management Framework 4.0 or later (5.1 recommended) and run again.')
    }
    if ($DotNetRelease -lt 378389) {
        $found = 'not found'; if ($DotNetRelease -gt 0) { $found = 'release ' + $DotNetRelease }
        $required += ('.NET Framework 4.5 or later (' + $found + '). Install .NET Framework 4.8 and run again.')
    }
    if (-not $IsElevated) {
        $required += 'Administrator rights. Run the script elevated (Run as administrator), or as SYSTEM through OpenText SA.'
    }
    $optional = @()
    foreach ($m in @($MissingModules | Where-Object { $_ })) {
        $use = $ModuleUse[$m]; if (-not $use) { $use = 'some checks' }
        $optional += ('PowerShell module ' + $m + ' is not available: ' + $use + ' cannot be fully assessed.')
    }
    return [pscustomobject]@{ CanRun = ($required.Count -eq 0); Required = $required; Optional = $optional }
}

function Get-PrerequisiteState {
    # Reads what Get-PrerequisiteDecision needs. Never throws.
    $release = 0
    try {
        $v = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction Stop
        $release = [int]$v.Release
    } catch { Write-Swallowed $_ }
    $elevated = $false
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or $identity.IsSystem
    } catch { Write-Swallowed $_ }
    $missing = @()
    foreach ($m in @($script:OptionalModules.Keys)) {
        if (-not (Get-Module -ListAvailable -Name $m -ErrorAction SilentlyContinue)) { $missing += $m }
    }
    return [pscustomobject]@{ PowerShellVersion = $PSVersionTable.PSVersion; DotNetRelease = $release; IsElevated = $elevated; MissingModules = $missing }
}

function Get-BroadFolderReader {
    # Returns the broad groups (Everyone, Authenticated Users, Users) that are
    # allowed to read the folder. Empty when the ACL cannot be read.
    param([string]$Path)
    $broad = @{ 'S-1-1-0' = 'Everyone'; 'S-1-5-11' = 'Authenticated Users'; 'S-1-5-32-545' = 'Users' }
    $found = @()
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        foreach ($rule in @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
            $sid = [string]$rule.IdentityReference
            if ($broad.ContainsKey($sid) -and [string]$rule.AccessControlType -eq 'Allow' -and ([int]$rule.FileSystemRights -band [int][System.Security.AccessControl.FileSystemRights]::ReadData)) {
                if ($found -notcontains $broad[$sid]) { $found += $broad[$sid] }
            }
        }
    } catch { Write-Swallowed $_ }
    return $found
}

function Test-CommandAvailable {
    # True when a cmdlet or function exists on this server. One place, so
    # tests can simulate servers with and without optional modules.
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-RegistryValueSafe {
    param([string]$Path, [string]$Name)
    $result = New-Object PSObject -Property @{ Exists=$false; Value=$null }
    try {
        if (Test-Path -LiteralPath $Path) {
            $item = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
            if ($item.PSObject.Properties[$Name]) {
                $result.Exists = $true
                $result.Value = $item.$Name
            }
        }
    } catch { Write-Swallowed $_ }
    return $result
}

$script:CimOperationTimeoutSec = 120

function Invoke-WithTimeout {
    # Runs a self-contained script block in its own runspace and gives up
    # after TimeoutSec: for .NET calls that have no timeout of their own
    # (for example Domain.GetComputerDomain on an unreachable DC, #241). The
    # block cannot see the script's variables or functions; it returns data,
    # not live objects. A timeout or an error inside is thrown.
    param([scriptblock]$ScriptBlock, [int]$TimeoutSec = 30)
    $ps = [powershell]::Create()
    [void]$ps.AddScript($ScriptBlock.ToString())
    $handle = $ps.BeginInvoke()
    if (-not $handle.AsyncWaitHandle.WaitOne($TimeoutSec * 1000)) {
        [void]$ps.BeginStop($null, $null)
        throw ('Timed out after ' + $TimeoutSec + ' seconds')
    }
    try {
        $out = $ps.EndInvoke($handle)
        if ($ps.Streams.Error.Count -gt 0) { throw $ps.Streams.Error[0].Exception }
        return $out
    } finally { $ps.Dispose() }
}

function Get-CimRequired {
    # Essential CIM query: a failure throws, so the calling check is reported
    # as "did not complete" instead of looking clean. CIM cmdlets exist from
    # PowerShell 3.0; a local query needs no WinRM.
    param([string]$Class, [string]$Filter = '', [string]$Namespace = 'root\cimv2')
    # A hung provider must not stall the run until SA's job timeout (#241).
    $p = @{ ClassName=$Class; Namespace=$Namespace; ErrorAction='Stop'; OperationTimeoutSec=$script:CimOperationTimeoutSec }
    if ($Filter) { $p.Filter = $Filter }
    return @(Get-CimInstance @p)
}

function Get-CimSafe {
    # Optional CIM query: a failure returns nothing and is logged.
    param([string]$Class, [string]$Filter = '', [string]$Namespace = 'root\cimv2')
    try { return @(Get-CimRequired $Class $Filter $Namespace) } catch { Write-Swallowed $_; return @() }
}

function ConvertTo-DateTimeValue {
    # Pure: CIM returns [datetime]; WMI-era data and some providers return
    # DMTF strings (20260929011022.500000+120) or plain date text. Returns
    # $null when the value cannot be read as a date.
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value }
    $text = [string]$Value
    if (-not $text) { return $null }
    if ($text -match '^\d{14}\.\d{6}[+-]\d{3}$') {
        try { return [Management.ManagementDateTimeConverter]::ToDateTime($text) } catch { Write-Swallowed $_ }
    }
    if ($text -match '^\d{8}$') {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($text, 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) { return $parsed }
    }
    $any = [datetime]::MinValue
    if ([datetime]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$any)) { return $any }
    return $null
}

function ConvertFrom-NativeByteArray {
    # Native tools write either UTF-16LE (sfc.exe, secedit) or the OEM code
    # page (dism.exe, netsh, vssadmin). Detect which and strip control chars.
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
    $text = ''
    $isUnicode = $false
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) { $isUnicode = $true }
    else {
        $sample = [Math]::Min($Bytes.Length, 512)
        $oddPositions = 0; $oddZeros = 0
        for ($i = 1; $i -lt $sample; $i += 2) { $oddPositions++; if ($Bytes[$i] -eq 0) { $oddZeros++ } }
        if ($oddPositions -gt 0 -and ($oddZeros / $oddPositions) -gt 0.3) { $isUnicode = $true }
    }
    if ($isUnicode) { $text = [Text.Encoding]::Unicode.GetString($Bytes) }
    else {
        $encoding = $null
        try { $encoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch { Write-Swallowed $_ }
        if ($null -eq $encoding) { $encoding = New-Object System.Text.UTF8Encoding($false) }
        $text = $encoding.GetString($Bytes)
    }
    $text = $text.TrimStart([char]0xFEFF)
    return ($text -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]','')
}

function ConvertTo-NativeArgument {
    # Pure: one argument -> its text on a Windows command line, following the
    # rules CommandLineToArgvW reads back (#136). A plain argument is left
    # alone; one with white space or a quote is wrapped in quotes, with each
    # embedded quote escaped and the backslashes in front of a quote (or of
    # the closing quote) doubled, so C:\Install Media\ does not swallow the
    # closing quote. An argument the caller already wrapped in quotes, with
    # none inside, is kept as it is.
    param([AllowEmptyString()][string]$Argument)
    if ($Argument.Length -eq 0) { return '""' }
    if ($Argument -match '^"[^"]*"$') { return $Argument }
    if ($Argument -notmatch '[\s"]') { return $Argument }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $Argument.ToCharArray()) {
        if ($ch -eq [char]'\') { $backslashes++; continue }
        if ($ch -eq [char]'"') {
            [void]$sb.Append('\', ($backslashes * 2 + 1)).Append('"')
        } else {
            [void]$sb.Append('\', $backslashes).Append($ch)
        }
        $backslashes = 0
    }
    [void]$sb.Append('\', ($backslashes * 2)).Append('"')
    return $sb.ToString()
}

function Invoke-NativeCapture {
    # Runs a native command with a timeout and captured output. Used for every
    # external tool so that stderr output never becomes a terminating
    # PowerShell error and a hung tool cannot stall the whole assessment.
    # The process is started through System.Diagnostics.Process (not
    # Start-Process -PassThru), so the exit code is available even when the
    # tool exits at once (#66). Output is read as raw bytes in the background
    # and decoded by ConvertFrom-NativeByteArray (sfc.exe writes UTF-16).
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 120
    )
    $result = [pscustomobject]@{ ExitCode=$null; Output=''; Lines=@(); TimedOut=$false; Error='' }
    $process = $null
    try {
        $quoted = @($ArgumentList | ForEach-Object { ConvertTo-NativeArgument $_ })
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        $psi.Arguments = ($quoted -join ' ')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        $null = $process.Start()
        $outBuffer = New-Object System.IO.MemoryStream
        $errBuffer = New-Object System.IO.MemoryStream
        $readers = [System.Threading.Tasks.Task[]]@(
            $process.StandardOutput.BaseStream.CopyToAsync($outBuffer),
            $process.StandardError.BaseStream.CopyToAsync($errBuffer)
        )
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $result.TimedOut = $true
            try { $null = Invoke-NativeTreeKill $process.Id } catch { Write-Swallowed $_ }
            try { $null = $process.WaitForExit(15000) } catch { Write-Swallowed $_ }
        } else {
            $process.WaitForExit()
            $result.ExitCode = $process.ExitCode
        }
        # A child process that outlives the tool can keep the pipes open;
        # never wait for it longer than 15 seconds.
        try { $null = [System.Threading.Tasks.Task]::WaitAll($readers, 15000) } catch { Write-Swallowed $_ }
        $chunks = @()
        foreach ($buffer in @($outBuffer,$errBuffer)) { $chunks += (ConvertFrom-NativeByteArray $buffer.ToArray()) }
        $result.Output = (($chunks | Where-Object { $_ }) -join "`n")
        $result.Lines = @($result.Output -split '\r?\n' | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -ne '' })
    } catch {
        $result.Error = $_.Exception.Message
    } finally {
        if ($process) { try { $process.Dispose() } catch { Write-Swallowed $_ } }
    }
    return $result
}

function Invoke-NativeTreeKill {
    param([int]$ProcessId)
    $taskkill = Join-Path $env:windir 'System32\taskkill.exe'
    if (Test-Path -LiteralPath $taskkill) {
        $p = Start-Process -FilePath $taskkill -ArgumentList @('/PID',[string]$ProcessId,'/T','/F') -PassThru -NoNewWindow -Wait -ErrorAction SilentlyContinue
        return $p
    }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Get-InstalledApplication {
    $items = @()
    foreach ($path in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        foreach ($entry in @(Get-ItemProperty $path -ErrorAction SilentlyContinue)) {
            if ($entry.DisplayName -and -not $entry.SystemComponent) {
                $items += [pscustomobject]@{
                    Name=[string]$entry.DisplayName; Version=[string]$entry.DisplayVersion
                    Publisher=[string]$entry.Publisher; InstallDate=[string]$entry.InstallDate
                }
            }
        }
    }
    return @($items | Sort-Object Name,Version -Unique)
}

function Get-FeatureState {
    param([string]$Name)
    if ($null -eq $script:Data.Features) { return $null }
    if ($script:Data.Features.ContainsKey($Name)) { return [bool]$script:Data.Features[$Name] }
    return $false
}

function ConvertTo-NormalizedThumbprint {
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [byte[]]) { return (($Value | ForEach-Object { $_.ToString('X2') }) -join '') }
    return (([string]$Value) -replace '[^0-9A-Fa-f]','').ToUpperInvariant()
}

function Resolve-PolicyAccountName {
    param([string]$Account)
    if (-not $Account) { return '' }
    $clean = ($Account.Trim() -replace '^\*','')
    if ($clean -match '^S-\d-') {
        try {
            $sid = New-Object Security.Principal.SecurityIdentifier($clean)
            return $sid.Translate([Security.Principal.NTAccount]).Value + ' [' + $clean + ']'
        } catch { return $clean }
    }
    return $clean
}

function Get-LocalGroupMembersBySid {
    param([string]$Sid)
    $members = @()
    $group = @(Get-CimSafe 'Win32_Group' ("LocalAccount=True AND SID='" + $Sid + "'")) | Select-Object -First 1
    if ($group) {
        try {
            $adsi = [ADSI]('WinNT://' + $script:ComputerName + '/' + $group.Name + ',group')
            foreach ($member in @($adsi.psbase.Invoke('Members'))) {
                $name = $member.GetType().InvokeMember('Name','GetProperty',$null,$member,$null)
                $path = $member.GetType().InvokeMember('ADsPath','GetProperty',$null,$member,$null)
                $members += ($name + ' [' + $path + ']')
            }
        } catch { Write-Swallowed $_ }
    }
    return ,$members
}

function Read-FileTail {
    # Reads the last part of a log that another process may hold open.
    param([string]$Path, [int]$MaxBytes = 20MB)
    $lines = @()
    if (-not (Test-Path -LiteralPath $Path)) { return ,$lines }
    $stream = $null; $reader = $null
    try {
        $stream = New-Object IO.FileStream($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        if ($stream.Length -gt $MaxBytes) { $null = $stream.Seek(-1 * $MaxBytes, [IO.SeekOrigin]::End) }
        $reader = New-Object IO.StreamReader($stream)
        $lines = @($reader.ReadToEnd() -split '\r?\n')
    } catch { Write-Swallowed $_ } finally {
        if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() }
    }
    return ,$lines
}

# SPECIAL servers (#152): read-only helpers used by the main flow and the
# special check. Defined here (script scope), not inside Register-AssessmentCheck.
function Get-SpecialServerState {
    # What decides SPECIAL (#152), read once after the baseline. Read-only.
    $clusSvc = @($script:Data.Services | Where-Object { $_.Name -eq 'ClusSvc' -and $_.StartMode -ne 'Disabled' }).Count -gt 0
    $clusterKey = [bool](Test-Path 'HKLM:\Cluster')
    $clusterFeature = (Resolve-ClusterFeatureState (Get-FeatureState 'Failover-Clustering') $clusSvc $clusterKey) -eq $true
    $role = 0; if ($script:Data.CS) { $role = [int]$script:Data.CS.DomainRole }
    return (Get-SpecialServerDecision $role $clusterFeature $clusSvc $clusterKey $BlockDomainControllerIPU)
}

function Get-SpecialServerFact {
    # The facts needed to choose a plan for a SPECIAL server (#152). Every
    # source is optional: a fact that cannot be read says so.
    param([string]$Kind)
    $facts = @()
    if ($Kind -eq 'Cluster') {
        if (-not (Test-CommandAvailable 'Get-Cluster')) { return ,@('Cluster cmdlets not available: read the cluster with Failover Cluster Manager.') }
        try {
            $c = Get-Cluster -ErrorAction Stop
            $facts += ('Cluster: ' + $c.Name)
            $nodes = @(Get-ClusterNode -ErrorAction SilentlyContinue)
            $facts += ('Nodes (' + $nodes.Count + '): ' + (@($nodes | ForEach-Object { [string]$_.Name + ' (' + $_.State + ')' }) -join ', '))
            $groups = @(Get-ClusterGroup -ErrorAction SilentlyContinue | Where-Object { [string]$_.GroupType -notmatch '^(Cluster|AvailableStorage)$' })
            $types = @($groups | Group-Object { [string]$_.GroupType } | ForEach-Object { $_.Name + ' x' + $_.Count })
            $facts += ('Roles: ' + $(if ($types.Count) { $types -join ', ' } else { 'none' }))
            $sql = @(Get-ClusterResource -ErrorAction SilentlyContinue | Where-Object { [string]$_.ResourceType -eq 'SQL Server' })
            if ($sql.Count -gt 0) { $facts += ('SQL Server failover cluster instances: ' + $sql.Count) }
            $q = Get-ClusterQuorum -ErrorAction SilentlyContinue
            if ($q) { $facts += ('Quorum: ' + $q.QuorumType + $(if ($q.QuorumResource) { ' (witness ' + $q.QuorumResource + ')' } else { '' })) }
            $csv = @(Get-ClusterSharedVolume -ErrorAction SilentlyContinue)
            $facts += ('Cluster Shared Volumes: ' + $csv.Count)
            if (Test-CommandAvailable 'Get-ClusterStorageSpacesDirect') {
                try { $s2d = Get-ClusterStorageSpacesDirect -ErrorAction Stop; if ($s2d) { $facts += ('Storage Spaces Direct: ' + $s2d.State) } } catch { Write-Swallowed $_ }
            }
        } catch { $facts += ('Cluster details not readable: ' + $_.Exception.Message) }
    }
    if ($Kind -eq 'DomainController') {
        try {
            # No timeout of its own: run it bounded, as strings only (#241).
            $dcFacts = Invoke-WithTimeout -TimeoutSec 60 -ScriptBlock {
                $facts = @()
                $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()
                $me = $env:COMPUTERNAME
                $mine = @()
                foreach ($r in @(@('PDC emulator', $domain.PdcRoleOwner), @('RID master', $domain.RidRoleOwner), @('Infrastructure master', $domain.InfrastructureRoleOwner), @('Schema master', $domain.Forest.SchemaRoleOwner), @('Domain naming master', $domain.Forest.NamingRoleOwner))) {
                    if ($r[1] -and ([string]$r[1].Name -split '\.')[0] -ieq $me) { $mine += $r[0] }
                }
                $facts += ('FSMO roles on this server: ' + $(if ($mine.Count) { $mine -join ', ' } else { 'none' }))
                $dc = @($domain.DomainControllers | Where-Object { ([string]$_.Name -split '\.')[0] -ieq $me }) | Select-Object -First 1
                if ($dc) { $facts += ('Global catalog: ' + $(if ($dc.IsGlobalCatalog()) { 'yes' } else { 'no' })) }
                $facts += ('Domain controllers in the domain: ' + @($domain.DomainControllers).Count)
                $facts
            }
            $facts += @($dcFacts | ForEach-Object { [string]$_ })
        } catch { $facts += ('FSMO roles and global catalog not readable: ' + $_.Exception.Message) }
        $same = @(@(@('DNS','DNS Server'), @('DHCP','DHCP Server'), @('ADCS-Cert-Authority','Certification Authority')) | Where-Object { (Get-FeatureState $_[0]) -eq $true } | ForEach-Object { $_[1] })
        $facts += ('Other roles on this server: ' + $(if ($same.Count) { $same -join ', ' } else { 'none of DNS, DHCP, certificate services' }))
        $repadmin = Join-Path $env:windir 'System32\repadmin.exe'
        if (Test-Path -LiteralPath $repadmin) {
            $r = Invoke-NativeCapture $repadmin @('/replsummary') 120
            $errLines = @($r.Lines | Where-Object { $_ -match 'error|fail' -and $_ -notmatch '^\s*Source DSA|^\s*Destination DSA' })
            $facts += ('Replication summary (repadmin /replsummary): exit ' + $r.ExitCode + $(if ($errLines.Count) { ', lines with errors: ' + $errLines.Count } else { ', no error lines' }))
        } else { $facts += 'Replication summary: repadmin not found' }
    }
    return ,$facts
}
