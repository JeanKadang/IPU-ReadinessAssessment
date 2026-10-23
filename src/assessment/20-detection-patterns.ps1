# =============================================================================
# 2. DETECTION PATTERNS
# =============================================================================
# Regular expressions, matched case-insensitively:
#   App     - installed application DisplayName (uninstall registry)
#   Service - service short Name
#   Display - service DisplayName
#   Driver  - file-system filter driver or kernel driver name
# Keep them specific: a broad word matches unrelated software.
$script:DetectionPatterns = @{
    Agents = @(
        @{ Label='OpenText Server Automation Agent';  App='^SA Agent$|Server Automation|Opsware';           Service='^OpswareAgent$';        Display='Opsware Agent|Server Automation' }
        @{ Label='OpenText Universal Discovery Agent'; App='Universal Discovery|^UD Agent';                  Service='^UDAgent$|^DDMA';        Display='Universal Discovery' }
        @{ Label='OpenText Operations Agent';          App='^Operations-agent$|Operations Agent|OMi Agent|HP Operations'; Service='^OvCtrl$|^ovcd$|^opcagt'; Display='OpenView Ctrl|Operations Agent' }
    )
    EndpointProtection = @(
        # Trend Micro / TrendAI: one row per product, so the report names
        # what is installed. Kernel drivers are listed under the Deep
        # Security Agent, which installs them.
        @{ Label='Trend Micro Deep Security Agent (Server & Workload Protection)'; App='Deep Security Agent'; Service='^(ds_agent|ds_monitor|ds_notifier|Amsp)$'; Display='Deep Security'; Driver='^(tmeyes|TmKmSnsr|tmumh)$'; Link='https://docs.trendmicro.com/en-us/documentation/article/trend-vision-one-agent-platform-compatibility'; LinkTitle='Trend Micro: agent platform compatibility' }
        @{ Label='Trend Micro Apex One'; App='Apex One|OfficeScan'; Service='^(ntrtscan|tmlisten|TmCCSF|TMBMServer|TmPfw)$'; Display='Apex One|OfficeScan' }
        @{ Label='Trend Vision One Endpoint Security agent (Endpoint Basecamp)'; App='Endpoint Basecamp|Vision One'; Service='^(Trend Micro Endpoint Basecamp|tm_netsrv)$'; Display='Endpoint Basecamp|Vision One'; Link='https://docs.trendmicro.com/en-us/documentation/article/trend-vision-one-agent-platform-compatibility'; LinkTitle='Trend Micro: agent platform compatibility' }
        @{ Label='Microsoft Defender for Endpoint (EDR sensor)'; Service='^Sense$' }
        @{ Label='CrowdStrike Falcon';       App='CrowdStrike';                       Service='^(CSAgent|CSFalconService)$';  Driver='^CSAgent$' }
        @{ Label='SentinelOne';              App='SentinelOne|Sentinel Agent';         Service='^(SentinelAgent|SentinelStaticEngine)$'; Driver='^SentinelMonitor$' }
        @{ Label='Cisco Secure Endpoint (AMP)'; App='Cisco Secure Endpoint|Cisco AMP|AMP for Endpoints|Immunet'; Service='^(CiscoAMP|immunetprotect)'; Display='Cisco Secure Endpoint|Cisco AMP' }
        @{ Label='Trellix / McAfee';         App='Trellix|McAfee';                     Service='^(mfefire|mfemms|masvc|macmnsvc|xagt)$'; Driver='^(mfehidk|mfencbdc)$' }
        @{ Label='Sophos';                   App='^Sophos';                            Service='^Sophos';                       Driver='^Sophos' }
        @{ Label='Symantec / Broadcom Endpoint Protection'; App='Symantec Endpoint|Broadcom Endpoint'; Service='^SepMasterService$'; Driver='^(SymEFASI|SRTSP)' }
        @{ Label='ESET';                     App='^ESET';                              Service='^ekrn$';                        Driver='^eamonm$' }
        @{ Label='Kaspersky';                App='Kaspersky';                          Service='^AVP' }
        @{ Label='VMware Carbon Black';      App='Carbon Black|Cb Defense|Cb Protection'; Service='^(CbDefense|Parity|CarbonBlack)'; Driver='^(carbonblackk|ctifile|parity)$' }
    )
    SecurityTools = @(
        @{ Label='Tenable Nessus agent'; App='Nessus|Tenable';  Service='^Tenable Nessus Agent$|^NessusAgent'; Display='Nessus' }
        @{ Label='NXLog';                App='^NXLog';          Service='^nxlog$' }
        @{ Label='Sysmon';               Service='^Sysmon(64)?$'; Driver='^SysmonDrv$' }
        @{ Label='Secure Root';          App='Secure Root';     Display='Secure Root' }
    )
    Backup = @(
        @{ Label='Commvault';                  App='Commvault|ContentStore|Hitachi Data Protection'; Service='^GxCVD|^GxClMgrS|^GXCVD' }
        @{ Label='IBM Spectrum Protect (TSM)'; App='Tivoli Storage Manager|Spectrum Protect|IBM Storage Protect'; Service='^(dsmcad|TSM)' }
        @{ Label='Veeam';                      App='Veeam';                             Service='^Veeam' }
    )
    Workloads = @(
        @{ Label='SharePoint';      App='^Microsoft SharePoint (Server|Foundation)'; Service='^(SPTimerV4|SPAdminV4)$' }
        @{ Label='Oracle Database'; App='^Oracle (Database|Client)|^Oracle .*Home';  Service='^(OracleService|OracleOraDB)|TNSListener' }
        @{ Label='SAP';             App='(^|[\s_\-])SAP([\s_\-]|$)|SAP HANA|SAP NetWeaver|SAP Host Agent'; Service='^(SAP\w+_\d\d|SAPHostExec|SAPHostControl|sapstartsrv)' }
        @{ Label='Citrix';          App='^Citrix';                                   Service='^(Citrix|Ctx)' }
        @{ Label='Boomi';           App='Boomi';                                     Service='Boomi' }
        @{ Label='Java runtime';    App='^(Java( \d+)?( Update \d+)?|Java\(TM\)|Java SE|Eclipse Temurin|Adoptium|Amazon Corretto|Microsoft Build of OpenJDK|Azul Zulu|OpenJDK|IBM Semeru)' }
        @{ Label='Apache Tomcat';   App='Apache Tomcat';                             Service='^Tomcat\d*$' }
        @{ Label='MySQL';           App='^MySQL Server';                             Service='^MySQL\d*$' }
        @{ Label='PostgreSQL';      App='^PostgreSQL';                               Service='^postgresql' }
        @{ Label='IBM Db2';         App='^IBM Db2|^DB2 ';                            Service='^DB2' }
    )
}

# Windows features removed or no longer developed, per Microsoft's
# "Features removed or no longer developed" pages for the target release.
# Removed  -> ACTION (Setup drops the feature; the dependent workload breaks).
# Deprecated -> Observation (still works, plan a replacement).
# Verified: see $script:FactSources.FeatureLifecycle (section 4).
$script:FeatureLifecycle = @(
    @{ Feature='SMTP-Server';              Name='SMTP Server';                     State='Removed';    Targets=@('2025') }
    @{ Feature='Web-Lgcy-Mgmt-Console';    Name='IIS 6 Management Console';        State='Removed';    Targets=@('2025') }
    @{ Feature='PowerShell-V2';            Name='Windows PowerShell 2.0 engine';   State='Removed';    Targets=@('2025') }
    @{ Feature='WebDAV-Redirector';        Name='WebDAV Redirector';               State='Deprecated'; Targets=@('2025') }
    @{ Feature='NLB';                      Name='Network Load Balancing';          State='Deprecated'; Targets=@('2025') }
    @{ Feature='Windows-Internal-Database';Name='Windows Internal Database (WID)'; State='Deprecated'; Targets=@('2025') }
    @{ Feature='UpdateServices';           Name='WSUS';                            State='Deprecated'; Targets=@('2025') }
    @{ Feature='ISNS';                     Name='iSNS Server service';             State='Removed';    Targets=@('2022','2025') }
    @{ Feature='WINS';                     Name='Windows Internet Name Service (WINS)'; State='Deprecated'; Targets=@('2022') }
)


