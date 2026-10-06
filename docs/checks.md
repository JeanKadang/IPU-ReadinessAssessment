# Checks reference

The assessment runs 31 checks, in the order below. Each check writes rows to the report under one or more
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
| `upgradepath` Upgrade path, edition and media | Release (from the build number), edition, Server Core or Desktop Experience, install language (`Nls\Language\InstallLanguage`, not the system locale), cluster membership, boot from VHD | `OK` supported path; `BLOCKER` unsupported path, clustered node, evaluation or Storage Server edition, boot from VHD, media language different from *TargetMediaLanguage*; `MANUAL` unknown release or language. Names the exact installation image to select |
| `licensing` Windows activation | `SoftwareLicensingProduct` (only the last five key characters), KMS host from the registry | `OK` licensed; `ACTION` not licensed or no key; `WARNING` OEM licence; `MANUAL` when the query fails (never reported as "unlicensed") |
| `pendingreboot` Pending reboot and uptime | CBS, Windows Update, `UpdateExeVolatile`, pending computer rename or domain join, ConfigMgr client, `PendingFileRenameOperations` (the first file paths are shown), last boot | `ACTION` reboot required; `WARNING` only pending file renames, or uptime above *UptimeWarningDays*; `OK` |
| `patchlevel` Patch level | Newest dated update (`Get-HotFix`) | `OK`; `WARNING` older than *MaxPatchAgeDays*; `MANUAL` no dated history |
| `history` Previous upgrade history | `HKLM\SYSTEM\Setup\Source OS*` keys, `C:\Windows.old`, OS install date, leftover `C:\$WINDOWS.~BT` | `WARNING` observation when the server was upgraded in place before; INFO otherwise. `C:\Windows\Panther\setupact.log` is **not** treated as upgrade evidence (every installation writes it) |
| `dism` DISM component store scan (slow) | `DISM /English /Online /Cleanup-Image /ScanHealth` (read-only) | `OK` no corruption; `ACTION` repairable or non-zero exit; `MANUAL` unclear or truncated output, timeout (*DISMTimeoutMinutes*) or skipped (*RunDISMScanHealth*) |
| `sfc` SFC protected file verification (slow) | `sfc /verifyonly` (read-only); for non-English output, the `CBS.log` lines written during the run | `OK`; `ACTION` integrity violations; `MANUAL` unclassifiable output, timeout or skipped |
| `compatscan` Setup compatibility scan (slow, optional) | With *TargetMediaPath*: picks the image matching edition and installation type, checks the media language, runs `setup.exe /auto upgrade /quiet /compat scanonly`, keeps Setup's `CompatData*.xml` | `OK` no issues; `ACTION` compatibility issues (hard blocks named), no matching image, low disk; `BLOCKER` upgrade not available with this media, media in another language; `INFO` not run without media |

## Workloads and applications

| Check | Looks at | Possible results |
|---|---|---|
| `domain` Domain role and access | Domain role, secure channel, built-in Administrator (RID 500), local Administrators members | `BLOCKER` domain controller (company policy, *BlockDomainControllerIPU*); `ACTION` broken secure channel; `MANUAL` secure channel not testable; `WARNING` workgroup server |
| `exchange` Exchange Server | Exchange services and setup registration | `BLOCKER` Exchange server role (in-place OS upgrade is not supported by Microsoft); `ACTION` only setup registration found (probably management tools) |
| `sql` SQL Server | Database Engine, Reporting Services and Analysis Services instances and versions | `BLOCKER` SQL version not supported on the target (for example SQL Server 2017 on 2025; the text names a target that supports it); `OK`; `MANUAL` version not found |
| `workloads` Roles and workloads | Installed roles, application workloads from the detection patterns (SharePoint, Oracle, SAP, Citrix, Java, Tomcat, ...), features removed or deprecated in the target | `WARNING` per workload or role that needs its owner; `ACTION` a feature removed in the target (for example SMTP Server, PowerShell 2.0 on 2025); `WARNING` observation for deprecated features; `MANUAL` when roles cannot be listed |
| `iis` IIS | Web Server role, sites and bindings | `WARNING` IIS installed (back up the configuration); `OK` not installed |
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
| `storage` Storage | Free space on C:, partition after C:, system and recovery partition free space, all disks with mount points, labels and file systems | `ACTION` C: below *MinimumCFreeGB* (with the size to add, in steps of *ExtendBlockGB*); `WARNING` partition after C:, system partition below *SystemPartitionMinFreeMB*; `WARNING` observation recovery partition below *RecoveryPartitionMinFreeMB* |
| `cluster` Failover clustering | Feature, membership, nodes, groups, quorum, CSVs, disks | `BLOCKER` clustered node (use Cluster OS Rolling Upgrade); `ACTION` feature present but cmdlets missing; `WARNING` feature without membership; `OK` |
| `network` Network, teaming, hosts and routes | IP configuration, LBFO and SET teams, hosts file, persistent and manual routes | `ACTION` LBFO team (disable before IPU; under a Hyper-V switch convert to SET); `MANUAL` active hosts entries or static routes to confirm; `OK` |
| `ports` Listening ports | TCP and UDP listeners below 49152 with the owning service or process | INFO; used for the post-upgrade test plan and comparison |

## Access, certificates and security

| Check | Looks at | Possible results |
|---|---|---|
| `rdp` RDP access, policy and evidence | RDP enabled (policy and effective), listener and port, NLA, firewall rules, logon rights, Remote Desktop Users, drive redirection; optional evidence (gpresult, user rights, LGPO backup) zipped | `ACTION` NO-GO (RDP disabled, nothing listening, no one may log on); `MANUAL` REVIEW; `OK` GO; `WARNING` drive redirection blocked; `WARNING` observation NLA off |
| `pki` PKI, certificates and TLS bindings | AD CS roles and CA configuration, certificates in My, Remote Desktop and WebHosting, IIS HTTPS bindings, RDP and WinRM certificates, HTTP.sys bindings | `ACTION` certification authority, IIS binding to a missing or expired certificate; `WARNING` binding certificate expiring within *CertificateWarningDays*; `WARNING` observation expired or expiring certificates |
| `antivirus` Antivirus, EDR and security tools | Microsoft Defender status, third-party AV/EDR by product, service and driver name, Nessus/NXLog/Sysmon, AppLocker, BitLocker, Secure Boot, TPM, filter drivers | `WARNING` per AV/EDR product (vendor IPU procedure) and security tool; `MANUAL` no protection recognised; `OK` Defender current; `WARNING` BitLocker on C: (recovery key) |
| `agents` Management agents (OpenText) | Server Automation, Universal Discovery and Operations agents (application and service) | INFO when found; `WARNING` observation stopped service; `MANUAL` observation not identified |

## Backup, services and checklist

| Check | Looks at | Possible results |
|---|---|---|
| `backup` Backup and VSS | In-guest backup agents (Commvault, Spectrum Protect, Veeam), VSS writers and providers | `ACTION` failed VSS writers; `MANUAL` observation writer state unreadable; `WARNING` observation third-party VSS provider |
| `services` Services | Automatic and manual services with state and logon account | INFO; the list to compare after the upgrade |
| `tasks` Scheduled tasks | Non-Microsoft scheduled tasks, run-as account and action | `WARNING` observation for tasks that run as named accounts (stored credentials) |
| `checklist` Standard change checklist | Steps that a script cannot prove: backup and fallback, credentials and console access, target licensing, installation media, application owner sign-off, monitoring agents | `MANUAL` checklist items (do not affect the overall status) |

## After the upgrade (`-AssessmentMode Post`)

The same checks run, except `checklist` and `compatscan`. The **post-upgrade comparison** then reads the
pre-upgrade JSON from the same folder and reports:

| Result | Status |
|---|---|
| Target release not reached (upgrade failed or rolled back) | `ACTION` |
| Automatic services that ran before and no longer run | `ACTION` |
| Lost static routes or IPv4 addresses | `ACTION` |
| Lost listening ports, DNS servers, hosts entries, applications, Windows features, scheduled tasks; services that no longer exist | `WARNING` |
| No pre-upgrade JSON found | `MANUAL` |
| Pre-upgrade result was a partial checkpoint | `WARNING` observation |
