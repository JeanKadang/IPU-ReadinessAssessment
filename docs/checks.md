# Checks reference

The assessment runs 38 checks. The tables group them by report chapter; slow checks run last. Each check writes rows to the report under one or more
**areas**. A check that throws is reported as `MANUAL` in *Collector coverage* ("Check did not complete");
the absence of findings in that area is then **not** evidence of readiness.

How to read the tables:

- **Fast** checks run first; the report is then written once as a checkpoint. **Slow** checks (DISM, SFC,
  Setup compatibility scan) run last, inside a time budget.
- **Possible results** lists the statuses a check can produce and when. Only rows of kind *Finding* count
  towards the overall status; *Observation*, *Checklist* and *Evidence* rows do not
  (see [result kinds](user-guide.md#result-kinds)).
- Thresholds in italics are parameters (see the [user guide](user-guide.md#4-parameters)).

Every check has tests in `tests/Checks.Tests.ps1` that run it against a fake server; a test fails if a
check is added without one.

## Upgrade path, licensing and Windows health

| Check | Looks at | Possible results |
|---|---|---|
| `baseline` Baseline inventory | OS, computer system, BIOS, CPU, services, installed applications (uninstall registry, never `Win32_Product`), Windows features, file-system filter and kernel drivers, output folder permissions. Feeds every other check and the post-upgrade snapshot | INFO; `ACTION` when running in 32-bit PowerShell that could not relaunch as 64-bit; `WARNING` observation when the existing report folder is readable by ordinary users |
| `upgradepath` Upgrade path, edition and media | Release (from the build number), edition, Server Core or Desktop Experience, install language (`Nls\Language\InstallLanguage`, not the system locale), cluster membership, boot from VHD | `OK` supported path; `BLOCKER` unsupported path, clustered node, evaluation or Storage Server edition, boot from VHD, media language different from *TargetMediaLanguage*; `MANUAL` unknown release or language. Names the exact installation image to select. End of extended support for the source release (fixed Microsoft Lifecycle dates): `INFO` while supported, a `WARNING` observation once support has ended (mentions ESU) |
| `licensing` Windows activation | `SoftwareLicensingProduct` (only the last five key characters), KMS host from the registry | `OK` licensed; `ACTION` not licensed or no key; `WARNING` OEM licence; `MANUAL` when the query fails (never reported as "unlicensed"). Records the activation channel (KMS client, MAK, AVMA, OEM, retail) for the target-licensing checklist item. A KMS client shows the KMS host that activated it (found via DNS or set on the server) and the days until renewal; `WARNING` under *KmsRenewWarnDays* (165: two missed renewal windows). An add-on licence such as ESU is never the Windows licence; it gets its own `INFO` row. MAK, AVMA, OEM and retail get their own plain text |
| `pendingreboot` Pending reboot and uptime | CBS, Windows Update, `UpdateExeVolatile`, pending computer rename or domain join, ConfigMgr client, `PendingFileRenameOperations` (the first file paths are shown), last boot | `ACTION` reboot required; `WARNING` only pending file renames, or uptime above *UptimeWarningDays*; `OK` |
| `patchlevel` Patch level | Newest dated update (`Get-HotFix`) | `OK`; `WARNING` older than *MaxPatchAgeDays* (says when the source OS is out of support, so no newer updates exist without ESU); `MANUAL` no dated history |
| `history` Previous upgrade history | `HKLM\SYSTEM\Setup\Source OS*` keys, `C:\Windows.old`, OS install date, leftover `C:\$WINDOWS.~BT` | `WARNING` observation when the server was upgraded in place before; INFO otherwise. `C:\Windows\Panther\setupact.log` is **not** treated as upgrade evidence (every installation writes it) |
| `dism` DISM component store scan (slow) | `DISM /English /Online /Cleanup-Image /ScanHealth` (read-only) | `OK` no corruption; `ACTION` DISM reports the store repairable or not repairable; `WARNING` a servicing operation waits for a reboot (0x800f082f, DISM scanned nothing: restart and re-run); `MANUAL` a plain error code such as 87 (DISM did not look), unclear or truncated output, timeout (*DISMTimeoutMinutes*) or skipped (*RunDISMScanHealth*) |
| `sfc` SFC protected file verification (slow) | `sfc /verifyonly` (read-only); for non-English output, the `CBS.log` lines written during the run | `OK`; `ACTION` integrity violations; `WARNING` a repair waits for a reboot (SFC checked nothing: reboot and re-run); `MANUAL` unclassifiable output, timeout or skipped |
| `compatscan` Setup compatibility scan (slow, optional) | With *TargetMediaPath*: picks the image matching edition and installation type, checks the media language, runs `setup.exe /auto upgrade /quiet /compat scanonly`, keeps Setup's `CompatData*.xml` | `OK` no issues; `ACTION` compatibility issues (hard blocks named), no matching image, low disk; `BLOCKER` upgrade not available with this media, media in another language; `INFO` not run without media |

## Workloads and applications

| Check | Looks at | Possible results |
|---|---|---|
| `domain` Domain role and access | Domain role, secure channel, built-in Administrator (RID 500), local Administrators members, User Account Control (shown in the summary; INFO, UAC does not block an upgrade) | `INFO` domain controller (the `special` check reports it as SPECIAL; site policy, *BlockDomainControllerIPU*, on by default; with it off a `WARNING`); `ACTION` broken secure channel; `MANUAL` secure channel not testable; `WARNING` workgroup server |
| `exchange` Exchange Server | Exchange services and setup registration | `BLOCKER` Exchange server role (in-place OS upgrade is not supported by Microsoft); `ACTION` only setup registration found (probably management tools) |
| `sql` SQL Server | Database Engine, Reporting Services and Analysis Services instances and versions | `BLOCKER` SQL version not supported on the target (for example SQL Server 2017 on 2025; the text names a target that supports it); `OK`; `MANUAL` version not found |
| `workloads` Roles and workloads | Installed roles, application workloads from the detection patterns (SharePoint, Oracle, SAP, Citrix, Java, Tomcat, ...), features removed or deprecated in the target | `WARNING` per workload or role that needs its owner; `ACTION` a feature removed in the target (for example SMTP Server, PowerShell 2.0 on 2025); `WARNING` observation for deprecated features; `MANUAL` when roles cannot be listed |
| `fileshares` File shares | SMB shares (`Get-SmbShare`) with path, description and share permissions (`Get-SmbShareAccess`); default administrative shares are left out, `print$` only with the Print Server role | `WARNING` when folders are shared (test access after the upgrade, keep the list); `INFO` no shares; `MANUAL` observation when the role is installed but the SmbShare cmdlets are missing |
| `printers` Print server: printers, ports and drivers (#148) | Print Server role or shared printers; printers (share, driver, port, published), the ports they use and every LPR port (address, protocol, queue), drivers (v3/v4, x64/x86, manufacturer), port monitors and print processors with the company of their DLL; `Get-Printer` and friends, CIM as fallback. Inbox virtual printers (Print to PDF, XPS, fax, OneNote) are left out | `WARNING` print server (keep the backup, test each shared printer after the upgrade); `WARNING` third-party drivers (vendor support for the target; for Windows Server 2025 the Windows Update note); `WARNING` per third-party port monitor or print processor; `WARNING` observation LPR port monitor port or LPD Service (deprecated); `INFO` drivers for 32-bit clients only; `MANUAL` printers not readable; `OK` not a print server |
| `printbackup` Print server backup (slow, #148) | `PrintBrm.exe -B -F <EvidenceRoot>\Printers\<Computer>-IPU-Print-<time>\<Computer>-printers.printerExport` (reads the spooler configuration only); space estimate from `spool\drivers`; timeout *PrintBackupTimeoutMinutes*, counted against the slow-check budget | `OK` export saved (copy it off the server); `MANUAL` skipped for lack of space (needs 1.5 x `spool\drivers` + 1 GB free), switched off (*EnablePrintBackup*), PrintBrm missing or failed, or timed out; skipped when not a print server and after the upgrade |
| `iis` IIS | Web Server role, sites and bindings; copies the IIS configuration files into `<EvidenceRoot>\IIS` (*EnableIISConfigEvidence*) | `WARNING` IIS installed (run `appcmd add backup` right before the change); `OK` configuration copied (path and SHA-256); `MANUAL` copy failed; `WARNING` observation shared configuration; `OK` not installed |
| `eolsnapshot` End-of-life snapshot (#285) | `eol-snapshot.json` (ADR 0003): the file given with *EolSnapshotPath*, else next to the script, else in *ReportDirectory*. Reading a file makes no network call. Runs after `eolcandidates` and compares what that check found with the snapshot | `INFO` observation with the snapshot date; `INFO` observation when none is found (names the places it looked); `MANUAL` when the file is older than six months, cannot be read, has no date, or the file named with *EolSnapshotPath* is missing. With a readable snapshot, one row per product the `eolcandidates` check found (#275): `WARNING` past end of life (with advice), `INFO` observation when it ends within 180 days or only gets security fixes, `OK` supported, `MANUAL` when the snapshot has no releases for the product, the version matches no release, or the snapshot is too old to confirm support |
| `eolcandidates` Products for end-of-life checks (#286) | Which products with an end-of-life date are on the server (ADR 0003): uninstall entries (DisplayVersion), service command lines (the version resource of the product's own executable), file probes for products that leave no uninstall entry (PHP, Apache HTTP Server, nginx, OpenSSL in the usual folders) and the .NET Framework `Release` registry value. Covers SQL Server, MySQL, MariaDB, PostgreSQL, MongoDB, Oracle Database, Db2, Redis, Apache HTTP Server, Tomcat, nginx, PHP, .NET, .NET Framework, PowerShell, Python, Node.js, OpenSSL and the Java builds endoflife.date tracks. A product is never run to read its version. The list goes into the result JSON as `EolCandidates` | `INFO` observation per product and version found; `MANUAL` when a product is seen but its version cannot be read (file without a version resource, access denied). A product that is not found does not appear: the report cannot say that none exists, only that none was found where the check looks |
| `rds` Remote Desktop Services roles | Session Host and Licensing roles, licensing mode and servers | `ACTION` session host or licensing server; `OK` |

## Hardware and virtualization

| Check | Looks at | Possible results |
|---|---|---|
| `platform` Platform and hardware | Physical or virtual and the hypervisor (VMware, Hyper-V/Azure, AWS, Google, Nutanix, KVM, Xen, ...); on physical servers model, BIOS, firmware, NIC and storage drivers | `OK` virtual; `MANUAL` physical (OEM support must be confirmed), cloud VM (provider procedure), unknown platform |
| `performance` CPU and memory | Logical processors and memory | `ACTION` one logical CPU; `WARNING` two CPUs or memory below *MinimumMemoryGB*; `OK` |
| `vmware` VMware guest readiness | VMware Tools version and service, VMware driver versions, firmware | `ACTION` VMware Tools missing, or older than 12.5.0 for a 2025 target; `OK`; adds checklist items for the ESXi host version and the guest OS setting after the upgrade |
| `drivers` Non-Microsoft drivers | Non-Microsoft PnP drivers and running kernel drivers (provider, version, date, signature) | `WARNING` unsigned drivers; INFO list for the driver review |

## Storage, clustering and network

| Check | Looks at | Possible results |
|---|---|---|
| `storage` Storage | Free space on C:, partition after C:, system and recovery partition free space, all disks with mount points, labels and file systems | `ACTION` C: below *MinimumCFreeGB* (with the size to add, in steps of *ExtendBlockGB*); `WARNING` partition after C:, system partition below *SystemPartitionMinFreeMB*; `WARNING` observation recovery partition below *RecoveryPartitionMinFreeMB* Recovery partition after C: (`reagentc /info`, read-only): before the upgrade a `WARNING` when Setup will likely add one (shows `setup.exe /ResizeRecoveryPartition Disable`); a recovery partition after C: is a `WARNING` with its number and the removal steps; `MANUAL` when `reagentc /info` fails |
| `cluster` Failover clustering | Feature, membership, nodes, groups, quorum, CSVs, disks | `INFO` clustered node (the `special` check reports it as SPECIAL); `ACTION` feature present but cmdlets missing; `WARNING` feature without membership; `MANUAL` a node, role, quorum, shared volume or disk list that cannot be read (named in `ClusterDetails`); `OK` |
| `special` SPECIAL server (#152) | Domain role, Failover Clustering feature, cluster service, `HKLM:\Cluster`; for the facts: cluster nodes, roles, SQL FCIs, quorum, CSVs, S2D, or FSMO roles, global catalog, roles on the same server and `repadmin /replsummary` (read-only) | `SPECIAL` cluster node or (with `-BlockDomainControllerIPU`) domain controller: short report, risks and options with links; `MANUAL` when the cluster signals disagree |
| `network` Network, teaming, hosts and routes | IP configuration per adapter (IPv4, IPv6, gateway, DNS servers, suffix and registration, WINS, NetBIOS, metric, VLAN), LBFO and SET teams, hosts file, persistent and manual routes; saves a network configuration copy into the evidence folder (*EnableNetworkEvidence*) | `ACTION` LBFO team (disable before IPU; under a Hyper-V switch convert to SET); `MANUAL` active hosts entries or static routes to confirm; `OK` configuration copy saved (copy it off the server); `MANUAL` copy failed or incomplete; `OK` |
| `ports` Listening ports | TCP and UDP listeners below 49152 with the owning service or process | INFO; used for the post-upgrade test plan and comparison |

## Access, certificates and security

| Check | Looks at | Possible results |
|---|---|---|
| `grouppolicy` Group Policy and AD groups | The computer object's OU path in AD (also in the summary); `gpresult /scope computer /x`: GPOs that apply and GPOs filtered out with the reason (WMI filter, security filtering, disabled); the WMI filter queries of those GPOs and the computer's AD groups including nested groups, read from AD as the computer account; when Group Policy last applied | Workgroup server: `INFO` "only local policy applies" (never MANUAL). Domain member: `WARNING` per GPO whose WMI filter selects on the Windows version, build or caption (it can stop or start matching after the upgrade); `WARNING` Group Policy not applied for more than *GroupPolicyMaxAgeDays*; `MANUAL` when gpresult or AD could not be read (the lists are then incomplete, not empty); INFO lists When gpresult has no RSoP data (seen as SYSTEM on 2016), the applied GPOs come from `HKLM\...\Group Policy\State\Machine\GPO-List` (applied only; WMI filters still read from AD) with an INFO row naming the source |
| `rdp` RDP access, policy and evidence | RDP enabled (policy and effective), listener and port, NLA, firewall rules, logon rights, Remote Desktop Users, drive redirection; optional evidence (gpresult, user rights, LGPO backup) zipped | `ACTION` NO-GO (RDP disabled, nothing listening, no one may log on); `MANUAL` REVIEW; `OK` GO; `WARNING` drive redirection blocked; `WARNING` observation NLA off |
| `pki` PKI, certificates and TLS bindings | AD CS roles and CA configuration, certificates in My, Remote Desktop and WebHosting, IIS HTTPS bindings, RDP and WinRM certificates, HTTP.sys bindings | `ACTION` certification authority, IIS binding to a missing or expired certificate; `WARNING` binding certificate expiring within *CertificateWarningDays*; `WARNING` observation expired or expiring certificates |
| `antivirus` Antivirus, EDR and security tools | Microsoft Defender status, third-party AV/EDR by product, service and driver name (one row per product, for example Trend Micro Deep Security Agent, Apex One and Vision One Endpoint Basecamp separately), Defender for Endpoint onboarding state, Nessus/NXLog/Sysmon, AppLocker, BitLocker, Secure Boot, TPM, filter drivers | `WARNING` per AV/EDR product (vendor IPU procedure; the summary names product and version); `WARNING` per security or monitoring tool with a driver (for example Sysmon), `WARNING` observation for a tool without drivers (for example Nessus, NXLog: check it runs after the upgrade); `INFO` for the built-in Defender for Endpoint sensor when it is not onboarded and not running; `MANUAL` no protection recognised; `OK` Defender current; `WARNING` BitLocker on C: (recovery key) |
| `agents` Management agents (OpenText) | Server Automation, Universal Discovery and Operations agents (application and service) | INFO when found; `WARNING` observation stopped service; `MANUAL` observation not identified |

## Backup, services and checklist

| Check | Looks at | Possible results |
|---|---|---|
| `backup` Backup and VSS | In-guest backup agents (Commvault, Spectrum Protect, Veeam), VSS writers and providers | `ACTION` failed VSS writers; `MANUAL` observation writer state unreadable; `WARNING` observation third-party VSS provider |
| `services` Services | Automatic and manual services with state and logon account | INFO; the list to compare after the upgrade |
| `tasks` Scheduled tasks | Non-Microsoft scheduled tasks, run-as account and action; Windows' per-user `User_Feed_Synchronization-{GUID}` tasks are counted in one line | `WARNING` observation for tasks that run as named accounts (stored credentials); `INFO` count of Windows per-user feed tasks |
| `checklist` Standard change checklist | Steps that a script cannot prove: backup and fallback, credentials and console access, target licensing (what the target needs for the current activation channel: KMS host key, MAK, AVMA host, OEM or retail licence), installation media, application owner sign-off, monitoring agents | `MANUAL` checklist items (do not affect the overall status) |

## After the upgrade (`-AssessmentMode Post`)

The same checks run, except `checklist` and `compatscan`. The **post-upgrade comparison** then reads the
pre-upgrade JSON from the same folder and reports:

| Result | Status |
|---|---|
| Target release not reached (upgrade failed or rolled back) | `ACTION` |
| Automatic services that ran before and no longer run | `ACTION` |
| Automatic services that ran before and are now disabled (often hardening after the upgrade) | `WARNING` |
| RDP Network Level Authentication on before, off now | `ACTION` |
| .NET Framework 3.5 removed by the upgrade (with the reinstall command) | `WARNING` |
| Changes that come with the new release: services Microsoft now starts on demand or removed, ports that closed with such a service, features removed or renamed (PowerShell 2.0, PowerShell ISE, Defender); per-user services are compared without their random suffix | `INFO` |
| Lost static routes or IPv4 addresses (baselines before 4.5.0) | `ACTION` |
| Network adapter, matched by MAC (#149): gone, switched to DHCP, static addresses or gateway lost, VLAN changed | `ACTION` |
| Network adapter: new DHCP address, DNS servers (order counts), DNS suffix or registration, WINS, NetBIOS or global IPv6 changed | `WARNING` |
| Network adapter renamed or metric changed only; new adapters | `INFO` |
| Printers or printer ports that existed before and no longer do (#148) | `ACTION` |
| Printers that now use another driver (#148) | `WARNING` |
| Lost listening ports, DNS servers, hosts entries, applications, Windows features, scheduled tasks; services that no longer exist | `WARNING` |
| No pre-upgrade JSON found | `MANUAL` |
| File shares that existed before and no longer do | `ACTION` |
| Computer object moved to another OU | `WARNING` |
| GPOs that applied before and no longer do, GPOs that newly apply, AD groups the computer is no longer in | `WARNING` |
| User Account Control set differently than before | `WARNING` |
| Pre-upgrade result was a partial checkpoint | `WARNING` observation |
