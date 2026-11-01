# =============================================================================
# 5. CHECKS
# =============================================================================
function Register-AssessmentCheck {
    Register-Check -Id 'baseline' -Name 'Baseline inventory' -Script { Invoke-BaselineCheck }
    Register-Check -Id 'upgradepath' -Name 'Upgrade path, edition and media' -Script { Invoke-UpgradePathCheck }
    Register-Check -Id 'licensing' -Name 'Windows activation' -Script { Invoke-LicensingCheck }
    Register-Check -Id 'pendingreboot' -Name 'Pending reboot and uptime' -Script { Invoke-PendingRebootCheck }
    Register-Check -Id 'patchlevel' -Name 'Patch level' -Script { Invoke-PatchLevelCheck }
    Register-Check -Id 'history' -Name 'Previous upgrade history' -Script { Invoke-HistoryCheck }
    Register-Check -Id 'domain' -Name 'Domain role and access' -Script { Invoke-DomainCheck }
    Register-Check -Id 'grouppolicy' -Name 'Group Policy and AD groups' -Script { Invoke-GroupPolicyCheck }
    Register-Check -Id 'rdp' -Name 'RDP access, policy and evidence' -Script { Invoke-RdpPolicyAssessment }
    Register-Check -Id 'platform' -Name 'Platform and hardware' -Script { Invoke-PlatformCheck }
    Register-Check -Id 'performance' -Name 'CPU and memory' -Script { Invoke-PerformanceCheck }
    Register-Check -Id 'cluster' -Name 'Failover clustering' -Script { Invoke-ClusterCheck }
    Register-Check -Id 'special' -Name 'SPECIAL server (cluster node, domain controller)' -Script { Invoke-SpecialCheck }
    Register-Check -Id 'storage' -Name 'Storage' -Script { Invoke-StorageCheck }
    Register-Check -Id 'network' -Name 'Network, teaming, hosts and routes' -Script { Invoke-NetworkCheck }
    Register-Check -Id 'exchange' -Name 'Exchange Server' -Script { Invoke-ExchangeCheck }
    Register-Check -Id 'sql' -Name 'SQL Server' -Script { Invoke-SqlCheck }
    Register-Check -Id 'workloads' -Name 'Roles and workloads' -Script { Invoke-WorkloadsCheck }
    Register-Check -Id 'fileshares' -Name 'File shares' -Script { Invoke-FileSharesCheck }
    Register-Check -Id 'printers' -Name 'Print server: printers, ports and drivers' -Script { Invoke-PrintersCheck }
    Register-Check -Id 'iis' -Name 'IIS' -Script { Invoke-IisCheck }
    Register-Check -Id 'rds' -Name 'Remote Desktop Services roles' -Script { Invoke-RdsCheck }
    Register-Check -Id 'pki' -Name 'PKI, certificates and TLS bindings' -Script { Invoke-PkiCheck }
    Register-Check -Id 'agents' -Name 'Management agents (OpenText)' -Script { Invoke-AgentsCheck }
    Register-Check -Id 'antivirus' -Name 'Antivirus, EDR and security tools' -Script { Invoke-AntivirusCheck }
    Register-Check -Id 'backup' -Name 'Backup and VSS' -Script { Invoke-BackupCheck }
    Register-Check -Id 'services' -Name 'Services' -Script { Invoke-ServicesCheck }
    Register-Check -Id 'vmware' -Name 'VMware guest readiness' -Script { Invoke-VmwareCheck }
    Register-Check -Id 'drivers' -Name 'Non-Microsoft drivers' -Script { Invoke-DriversCheck }
    Register-Check -Id 'ports' -Name 'Listening ports' -Script { Invoke-PortsCheck }
    Register-Check -Id 'tasks' -Name 'Scheduled tasks' -Script { Invoke-TasksCheck }
    Register-Check -Id 'eolcandidates' -Name 'Products for end-of-life checks' -Script { Invoke-EolCandidatesCheck }
    Register-Check -Id 'eolsnapshot' -Name 'End-of-life snapshot' -Script { Invoke-EolSnapshotCheck }
    Register-Check -Id 'checklist' -Name 'Standard change checklist' -Script { Invoke-ChecklistCheck }
    # SLOW CHECKS (time-boxed, run after the checkpoint report is written)
    Register-Check -Id 'printbackup' -Name 'Print server backup (PrintBrm)' -Phase 'Slow' -Script { Invoke-PrintBackupCheck }
    Register-Check -Id 'dism' -Name 'DISM component store scan' -Phase 'Slow' -Script { Invoke-DismCheck }
    Register-Check -Id 'sfc' -Name 'SFC protected file verification' -Phase 'Slow' -Script { Invoke-SfcCheck }
    Register-Check -Id 'compatscan' -Name 'Setup compatibility scan' -Phase 'Slow' -Script { Invoke-CompatScanCheck }
}
