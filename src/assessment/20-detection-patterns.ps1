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

# Products for the end-of-life check (#286, ADR 0003). One entry per endoflife.date
# identifier in the snapshot, except windows-server (the operating system has its
# own check). Routes, in order:
#   App     - uninstall entry DisplayName; its DisplayVersion is the version
#   Service - service short name; the service's executable must match Exe, and
#             its version resource is the version
#   Probe   - file locations for products that leave no uninstall entry (PHP,
#             Apache HTTP Server and nginx are often just an unpacked folder).
#             %Variables% are expanded, '*' stands for part of one folder name
# The version comes from the uninstall entry or from a file's version resource.
# A product is NEVER run to ask for its version (php.exe -v would execute it).
# Not detected, by design: a product in an unusual folder with no service and no
# uninstall entry; MySQL by service (mysqld.exe is also the old MariaDB service,
# so only its uninstall entry counts); SQL Server by file (its file version is
# 2019.150..., not the 15.0 the release table uses); other Java builds (Azul
# Zulu, IBM Semeru) that endoflife.date does not track here. .NET Framework is
# read from the registry (Release value), not from a file.
$script:EolDetection = @(
    @{ Product='mssqlserver';      Name='Microsoft SQL Server'; App='^Microsoft SQL Server \d{4}( \(\d+-bit\))?$' }
    @{ Product='mysql';            Name='MySQL';                App='^MySQL Server \d' }
    @{ Product='mariadb';          Name='MariaDB';              App='^MariaDB';        Service='^MariaDB';           Exe='^(mariadbd|mysqld)\.exe$' }
    @{ Product='postgresql';       Name='PostgreSQL';           App='^PostgreSQL \d';  Service='^postgresql';        Exe='^(pg_ctl|postgres)\.exe$' }
    @{ Product='mongodb';          Name='MongoDB';              App='^MongoDB';        Service='^MongoDB$';          Exe='^mongod\.exe$' }
    @{ Product='oracle-database';  Name='Oracle Database';      App='^Oracle Database \d'; Service='^OracleService';  Exe='^oracle\.exe$' }
    @{ Product='ibm-db2';          Name='IBM Db2';              App='^IBM Db2|^DB2 \d'; Service='^DB2';              Exe='^db2syscs\.exe$' }
    @{ Product='redis';            Name='Redis';                App='^Redis';          Service='^Redis';             Exe='^redis-server\.exe$' }
    @{ Product='apache-http-server'; Name='Apache HTTP Server'; App='^Apache HTTP Server|^Apache Lounge'; Service='^(Apache|httpd)'; Exe='^httpd\.exe$'
       Probe=@('%SystemDrive%\Apache*\bin\httpd.exe', '%ProgramFiles%\Apache*\bin\httpd.exe', '%SystemDrive%\xampp\apache\bin\httpd.exe') }
    @{ Product='tomcat';           Name='Apache Tomcat';        App='^Apache Tomcat';  Service='^Tomcat\d*$';        Exe='^tomcat\d*w?\.exe$' }
    @{ Product='nginx';            Name='nginx';                Service='^nginx';      Exe='^nginx\.exe$'
       Probe=@('%SystemDrive%\nginx*\nginx.exe', '%ProgramFiles%\nginx*\nginx.exe') }
    @{ Product='php';              Name='PHP';                  App='^PHP \d'
       Probe=@('%SystemDrive%\php*\php.exe', '%ProgramFiles%\PHP*\php.exe', '%ProgramFiles(x86)%\PHP*\php.exe', '%SystemDrive%\xampp\php\php.exe') }
    @{ Product='dotnet';           Name='.NET';                 App='^Microsoft (\.NET (Runtime|Windows Desktop Runtime|SDK)|ASP\.NET Core \d)' }
    @{ Product='powershell';       Name='PowerShell';           App='^PowerShell \d' }
    @{ Product='python';           Name='Python';               App='^Python \d+\.\d+\.\d+'; AppExclude='^Python \d+\.\d+\.\d+ (Core|Standard|Documentation|Development|Executables|pip|Tcl|Test|Add)|Launcher' }
    @{ Product='nodejs';           Name='Node.js';              App='^Node\.js' }
    @{ Product='eclipse-temurin';  Name='Eclipse Temurin (Java)'; App='^(Eclipse Temurin|Adoptium)' }
    @{ Product='oracle-jdk';       Name='Oracle JDK (Java)';    App='^(Java( \d+)? Update|Java\(TM\) SE|Java SE Development)' }
    @{ Product='amazon-corretto';  Name='Amazon Corretto (Java)'; App='^Amazon Corretto' }
    @{ Product='microsoft-build-of-openjdk'; Name='Microsoft Build of OpenJDK (Java)'; App='^Microsoft Build of OpenJDK' }
    @{ Product='openssl';          Name='OpenSSL';              App='^OpenSSL'
       Probe=@('%ProgramFiles%\OpenSSL*\bin\openssl.exe', '%SystemDrive%\OpenSSL*\bin\openssl.exe') }
)

# .NET Framework 4.x: the Release value under NDP\v4\Full -> the version it
# means (Microsoft's "How to determine which versions are installed" table;
# the smallest Release value of each version).
$script:DotNetFrameworkReleases = @(
    @{ Min=533320; Version='4.8.1' }, @{ Min=528040; Version='4.8' }, @{ Min=461808; Version='4.7.2' }, @{ Min=461308; Version='4.7.1' }
    @{ Min=460798; Version='4.7' }, @{ Min=394802; Version='4.6.2' }, @{ Min=394254; Version='4.6.1' }, @{ Min=393295; Version='4.6' }
    @{ Min=379893; Version='4.5.2' }, @{ Min=378675; Version='4.5.1' }, @{ Min=378389; Version='4.5' }
)

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


