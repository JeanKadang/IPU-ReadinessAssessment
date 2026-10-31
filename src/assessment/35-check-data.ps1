# ==============================================================================
# Check data (#360). The checks share $script:Data, and its Snapshot, as one
# bus: baseline fills the inventory, later checks read it, and the Post run
# compares the Snapshot lists. Which check writes which key used to exist only
# in the check text. This part says it once: the OWNER of a key is the one check
# (or, outside the checks, main / report / rules) that may write it. A test
# reads the check bodies and fails when a check writes a key it does not own,
# or when an owner no longer writes its key (tests/core/check-data.Tests.ps1).
# Readers are not listed: about 25 checks read baseline's keys.
# ==============================================================================

# Owners of $script:Data keys. Several owners: comma separated.
$script:CheckDataOwners = [ordered]@{
    # baseline: the inventory every other check reads
    OS = 'baseline'; CS = 'baseline'; BIOS = 'baseline'; CPU = 'baseline'; CV = 'baseline'
    Services = 'baseline'; Apps = 'baseline'; Features = 'baseline'
    FilterDrivers = 'baseline'; KernelDrivers = 'baseline'; DriverNames = 'baseline'
    Platform = 'baseline'; Snapshot = 'baseline'
    # upgradepath
    SourceRelease = 'upgradepath'; SourceSupport = 'upgradepath'; InstallLanguage = 'upgradepath'; RecommendedMedia = 'upgradepath'
    # the facts the report summary shows
    KmsEndpoint = 'licensing'; ActivationKind = 'licensing'; ActivationSummary = 'licensing'
    DomainRoleText = 'domain'; UacSummary = 'domain'
    AdLocation = 'grouppolicy'
    CSummary = 'storage'; NetworkEvidence = 'network'; SqlSummary = 'sql'
    EndpointProducts = 'antivirus'
    # other checks
    PrintServer = 'printers'; Special = 'special'; EolCandidates = 'eolcandidates'
    RdpSummary = 'rdp'; DriveRedirection = 'rdp'; PolicyEvidence = 'rdp'; NlaState = 'rdp'
    # written outside the checks
    SpecialKind = 'main'; NlaBefore = 'report'; RedactLiterals = 'rules'
}

# Keys of $script:CheckDataOwners that nothing reads. A test checks that this
# stays true: the first read of one of them must update this list. Step 2 of
# #360 removed the six that were written and never read (IsClustered, Edition,
# ClusterName, IISConfigEvidence, PrintBackup, RedactionKey), so it is empty now.
$script:CheckDataUnused = @()

# Owners that are not checks.
$script:CheckDataNonCheckOwners = @('main', 'report', 'rules')

# The lists of $script:Data.Snapshot (#239, #306). Owner: the check that fills
# the list (baseline creates every list empty, then the owner fills it; Features
# is created only when the feature inventory was read, #361).
# Compare: 'Both' = the Post run compares the list and needs it from both runs;
# 'Current' = checked on the current side only; '' = stored, not compared as a
# list. A list whose check did not complete cannot be compared, and an empty
# list must not read as "nothing lost".
$script:SnapshotListOwners = [ordered]@{
    Services = @{ Owner = 'baseline'; Compare = 'Both' }
    Apps = @{ Owner = 'baseline'; Compare = 'Both' }
    Features = @{ Owner = 'baseline'; Compare = 'Both' }
    Ports = @{ Owner = 'ports'; Compare = 'Both' }
    IPv4 = @{ Owner = 'network'; Compare = 'Both' }
    Dns = @{ Owner = 'network'; Compare = 'Both' }
    Adapters = @{ Owner = 'network'; Compare = 'Both' }
    Hosts = @{ Owner = 'network'; Compare = 'Both' }
    Routes = @{ Owner = 'network'; Compare = 'Both' }
    Tasks = @{ Owner = 'tasks'; Compare = 'Both' }
    Shares = @{ Owner = 'fileshares'; Compare = 'Both' }
    Printers = @{ Owner = 'printers'; Compare = 'Both' }
    PrinterPorts = @{ Owner = 'printers'; Compare = 'Both' }
    PrinterDrivers = @{ Owner = 'printers'; Compare = 'Both' }
    Gpos = @{ Owner = 'grouppolicy'; Compare = 'Current' }
    Groups = @{ Owner = 'grouppolicy'; Compare = 'Current' }
    Uac = @{ Owner = 'domain'; Compare = '' }
    Ou = @{ Owner = 'grouppolicy'; Compare = '' }
    Nla = @{ Owner = 'rdp'; Compare = '' }
    PortOwners = @{ Owner = 'ports'; Compare = '' }
}

function Get-CheckDataOwner {
    # Pure: the owners (check ids, or main / report / rules) of a $script:Data
    # key, or nothing when the key is not declared.
    param([string]$Key)
    if (-not $script:CheckDataOwners.Contains($Key)) { return @() }
    return @(([string]$script:CheckDataOwners[$Key]) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-SnapshotListSourceMap {
    # Pure: list name -> id of the check that collects it, in declaration order,
    # for the lists with the given Compare value. 'Both' is what the Post run
    # compares (was $script:SnapshotListSources), 'Current' what it checks on
    # the current side only (was $script:SnapshotCurrentListSources).
    param([ValidateSet('Both', 'Current')][string]$Compare)
    $map = [ordered]@{}
    foreach ($name in $script:SnapshotListOwners.Keys) {
        $entry = $script:SnapshotListOwners[$name]
        if ($entry.Compare -eq $Compare) { $map[$name] = [string]$entry.Owner }
    }
    return $map
}

# What a check cannot give a trustworthy result without (#360, step 3). When
# one of the checks listed for a check stopped with an error or ran out of time,
# the check is not run: it would read empty data and report "not installed" or
# "OK" for things it never saw. It is recorded as skipped, with a MANUAL result
# that names the check it needs. baseline is the source for every check that
# reads its inventory (the 29 below); a test derives that list from the check
# bodies, so a new check that reads the inventory must be added here. The two
# others are named by hand: printbackup reads what printers found, eolsnapshot
# reads what eolcandidates found. A check that runs its own queries
# (licensing, patchlevel, storage, sql, dism, sfc) needs nothing.
$script:CheckNeeds = [ordered]@{
    upgradepath = 'baseline'; pendingreboot = 'baseline'; history = 'baseline'
    domain = 'baseline'; grouppolicy = 'baseline'; rdp = 'baseline'
    platform = 'baseline'; performance = 'baseline'; cluster = 'baseline'; special = 'baseline'
    network = 'baseline'; exchange = 'baseline'; workloads = 'baseline'; fileshares = 'baseline'
    printers = 'baseline'; iis = 'baseline'; rds = 'baseline'; pki = 'baseline'
    agents = 'baseline'; antivirus = 'baseline'; backup = 'baseline'; services = 'baseline'
    vmware = 'baseline'; drivers = 'baseline'; ports = 'baseline'; tasks = 'baseline'
    eolcandidates = 'baseline'; checklist = 'baseline'; compatscan = 'baseline'
    printbackup = 'printers'; eolsnapshot = 'eolcandidates'
}

function Get-CheckNeed {
    # Pure: the ids of the checks that a check needs; none for a check that
    # runs its own queries.
    param([string]$CheckId)
    if (-not $script:CheckNeeds.Contains($CheckId)) { return @() }
    return @(([string]$script:CheckNeeds[$CheckId]) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-BlockingCheckRun {
    # Pure: the runs of the checks that $CheckId needs which stopped with an
    # error, ran out of time, or were themselves not run for that reason (their
    # message starts with "Needs"), so the block follows the chain. A needed
    # check that was skipped by design (a SPECIAL short report, a switch) or
    # has not run yet does not block.
    param([string]$CheckId, [object[]]$CheckRuns)
    $blocking = @()
    foreach ($source in @(Get-CheckNeed $CheckId)) {
        $run = @($CheckRuns | Where-Object { $_.Id -eq $source }) | Select-Object -Last 1
        if (-not $run) { continue }
        if ($run.Outcome -eq 'Failed' -or $run.Outcome -eq 'TimedOut' -or ($run.Outcome -eq 'Skipped' -and [string]$run.Message -like 'Needs *')) { $blocking += $run }
    }
    return @($blocking)
}

function Get-BlockedCheckMessage {
    # Pure: why a check was not run, in a sentence the coverage notice can
    # put after "was skipped (...)".
    param([object[]]$BlockingRuns)
    $parts = @()
    foreach ($run in @($BlockingRuns)) {
        $how = 'stopped with an error'
        if ($run.Outcome -eq 'TimedOut') { $how = 'ran out of time' }
        elseif ($run.Outcome -eq 'Skipped') { $how = 'was not run' }
        $parts += ('Needs ' + $run.Id + ', which ' + $how)
    }
    return ($parts -join '; ')
}
