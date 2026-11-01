# Chapter: Hardware and virtualization (docs/checks.md).
# Each check is one function; Register-AssessmentCheck (50-checks.ps1) lists them in run order.

function Invoke-PlatformCheck {
    $cs = $script:Data.CS; $bios = $script:Data.BIOS
    $platform = $script:Data.Platform
    if ($platform.Type -eq 'Virtual') {
        Add-Result 'PLATFORM' 'PhysicalOrVirtual' 'OK' ('Virtual (' + $platform.Hypervisor + ')') @(('Manufacturer=' + $cs.Manufacturer),('Model=' + $cs.Model)) -Source 'Win32_ComputerSystem'
        if ($platform.Hypervisor -match 'AWS|Google|Azure') {
            Add-Result 'PLATFORM' 'CloudProvider' 'MANUAL' $platform.Hypervisor -Recommendation 'Microsoft defers cloud IPU support to the provider. Follow the provider''s documented in-place upgrade procedure and licensing rules.' -Source 'Platform classification'
        }
        return
    }
    if ($platform.Type -eq 'Unknown') {
        Add-Result 'PLATFORM' 'PhysicalOrVirtual' 'MANUAL' 'Could not be determined' -Recommendation 'Confirm the platform manually.' -Source 'Win32_ComputerSystem'
        return
    }
    Add-Result 'PLATFORM' 'PhysicalOrVirtual' 'MANUAL' 'Physical' @(('Manufacturer=' + $cs.Manufacturer),('Model=' + $cs.Model)) -Recommendation ('Validate model, firmware, storage controller and NIC driver support for ' + (Get-ReleaseDisplayName $TargetServerVersion) + ' with the OEM, and confirm a bare-metal recovery path.') -Source 'Local inventory cannot prove OEM certification'

    $product = @(Get-CimSafe 'Win32_ComputerSystemProduct') | Select-Object -First 1
    $board = @(Get-CimSafe 'Win32_BaseBoard') | Select-Object -First 1
    Add-Result 'HARDWARE' 'SystemIdentification' 'INFO' ('Model=' + $cs.Model) @(('SerialOrServiceTag=' + $bios.SerialNumber),('SKU=' + $cs.SystemSKUNumber),('Product=' + $product.Name + ' ' + $product.Version)) -Source 'Win32_ComputerSystem, Win32_BIOS'
    if ($board) { Add-Result 'HARDWARE' 'BaseBoard' 'INFO' ('Manufacturer=' + $board.Manufacturer) @(('Product=' + $board.Product),('Version=' + $board.Version)) -Source 'Win32_BaseBoard' }
    if ($bios) {
        $biosDate = [string]$bios.ReleaseDate
        $releaseDate = ConvertTo-DateTimeValue $bios.ReleaseDate
        if ($releaseDate) { $biosDate = $releaseDate.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
        Add-Result 'HARDWARE' 'BIOS' 'INFO' ('Version=' + $bios.SMBIOSBIOSVersion) @(('Manufacturer=' + $bios.Manufacturer),('ReleaseDate=' + $biosDate)) -Source 'Win32_BIOS'
    }
    $firmware = 'Legacy BIOS or undetermined'
    if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State') { $firmware = 'UEFI' }
    Add-Result 'HARDWARE' 'FirmwareMode' 'INFO' $firmware -Source 'SecureBoot registry presence'
    $i = 0
    foreach ($cpu in $script:Data.CPU) { $i++; Add-Result 'HARDWARE' ('CPU-' + $i) 'INFO' $cpu.Name @(('Cores=' + $cpu.NumberOfCores),('Logical=' + $cpu.NumberOfLogicalProcessors)) -Source 'Win32_Processor' }

    $netDrivers = @(Get-CimSafe 'Win32_PnPSignedDriver' "DeviceClass='NET'")
    foreach ($nic in @(Get-CimSafe 'Win32_NetworkAdapter' | Where-Object { $_.PhysicalAdapter -eq $true })) {
        $drv = @($netDrivers | Where-Object { $_.DeviceID -eq $nic.PNPDeviceID }) | Select-Object -First 1
        $drvText = 'Driver not correlated'
        if ($drv) { $drvText = 'Provider=' + $drv.DriverProviderName + ', Version=' + $drv.DriverVersion + ', Date=' + $drv.DriverDate }
        Add-Result 'HARDWARE' ('NIC: ' + $nic.Name) 'INFO' ('MAC=' + $nic.MACAddress) $drvText -Source 'Win32_NetworkAdapter, Win32_PnPSignedDriver'
    }
    $storageDrivers = @(Get-CimSafe 'Win32_PnPSignedDriver' "DeviceClass='SCSIAdapter'") + @(Get-CimSafe 'Win32_PnPSignedDriver' "DeviceClass='HDC'")
    foreach ($drv in @($storageDrivers | Sort-Object DeviceName,DriverVersion -Unique)) {
        Add-Result 'HARDWARE' ('Storage controller: ' + $drv.DeviceName) 'INFO' ('Provider=' + $drv.DriverProviderName) @(('Version=' + $drv.DriverVersion),('Date=' + $drv.DriverDate)) -Source 'Win32_PnPSignedDriver'
    }
}

function Invoke-PerformanceCheck {
    $cs = $script:Data.CS
    $logical = [int]$cs.NumberOfLogicalProcessors
    if ($logical -le 1) { Add-Result 'PERFORMANCE' 'LogicalProcessors' 'ACTION' $logical -Recommendation 'Add CPU before IPU; setup on a single logical CPU is very slow.' -Source 'Win32_ComputerSystem' }
    elseif ($logical -eq 2) { Add-Result 'PERFORMANCE' 'LogicalProcessors' 'WARNING' $logical -Recommendation 'Setup will be noticeably slower on 2 logical CPUs; consider adding CPU temporarily for the change window.' -Source 'Win32_ComputerSystem' }
    else { Add-Result 'PERFORMANCE' 'LogicalProcessors' 'OK' $logical -Source 'Win32_ComputerSystem' }
    $ramGB = [math]::Round(([double]$cs.TotalPhysicalMemory / 1GB),2)
    if ($ramGB -lt $MinimumMemoryGB) { Add-Result 'PERFORMANCE' 'MemoryGB' 'WARNING' (Format-Number $ramGB) -Recommendation ('Below the project threshold of ' + $MinimumMemoryGB + ' GB; consider adding memory before IPU.') -Source 'Win32_ComputerSystem' }
    else { Add-Result 'PERFORMANCE' 'MemoryGB' 'OK' (Format-Number $ramGB) -Source 'Win32_ComputerSystem' }
}

function Invoke-VmwareCheck {
    if ($script:Data.Platform.Hypervisor -ne 'VMware') {
        Add-Result 'VMWARE' 'Applicability' 'INFO' ('Not a VMware VM (' + $script:Data.Platform.Type + ')') -Source 'Platform classification'
        return
    }
    $tools = @($script:Data.Apps | Where-Object { $_.Name -eq 'VMware Tools' }) | Select-Object -First 1
    $version = ''
    if ($tools) { $version = [string]$tools.Version }
    else {
        $exe = Join-Path $env:ProgramFiles 'VMware\VMware Tools\vmtoolsd.exe'
        if (Test-Path -LiteralPath $exe) { $version = [string](Get-Item -LiteralPath $exe).VersionInfo.ProductVersion }
    }
    $decision = Get-VMwareToolsDecision $version $TargetServerVersion
    $toolsSvc = @($script:Data.Services | Where-Object { $_.Name -eq 'VMTools' }) | Select-Object -First 1
    $svcText = 'VMTools service not found'
    if ($toolsSvc) { $svcText = 'VMTools service ' + $toolsSvc.State + ', ' + $toolsSvc.StartMode }
    Add-Result 'VMWARE' 'VMwareTools' $decision.Status ('Version=' + $version) $svcText -Recommendation $decision.Text -Source 'Uninstall registry / vmtoolsd.exe'

    $firmware = 'BIOS'
    if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State') { $firmware = 'EFI' }
    Add-Result 'VMWARE' 'VMFirmware' 'INFO' $firmware ('BIOS version=' + $script:Data.BIOS.SMBIOSBIOSVersion) -Recommendation 'BIOS-firmware VMs upgrade in place; Secure Boot and vTPM need EFI firmware.' -Source 'SecureBoot registry, Win32_BIOS'

    foreach ($drv in @($script:Data.KernelDrivers | Where-Object { $_.Name -match '^(pvscsi|vmxnet3|vmxnet3ndis6|vsepflt|vnetflt|vnetWFP|vmci|vsock|vm3dmp|vmmemctl|vmhgfs|vmrawdsk|vmusbmouse|vmmouse|glxgi)' } | Sort-Object Name)) {
        $fileVersion = ''
        $path = ([string]$drv.PathName -replace '^\\\?\?\\','' -replace '^\\SystemRoot', $env:windir -replace '^(?i)system32', (Join-Path $env:windir 'System32'))
        try { if ($path -and (Test-Path -LiteralPath $path)) { $fileVersion = (Get-Item -LiteralPath $path).VersionInfo.FileVersion } } catch { Write-Swallowed $_ }
        Add-Result 'VMWARE' ('Driver: ' + $drv.Name) 'INFO' $drv.DisplayName ('FileVersion=' + $fileVersion) -Source 'Win32_SystemDriver'
    }

    $hostText = 'Confirm the ESXi host version supports ' + (Get-ReleaseDisplayName $TargetServerVersion) + ' guests (VMware Compatibility Guide).'
    if ($TargetServerVersion -eq '2025') { $hostText = 'Windows Server 2025 is certified on vSphere 7.0 U3 and 8.0.x. Confirm the host (and any vMotion/DRS target) runs one of these.' }
    Add-Result 'CHECKLIST' 'VMware host version' 'MANUAL' 'Not visible from inside the guest' '' -Recommendation $hostText -Kind 'Checklist'
    Add-Result 'CHECKLIST' 'VMware guest OS setting' 'MANUAL' 'After the upgrade' '' -Recommendation ('After IPU, power off the VM and change its Guest OS version to Microsoft Windows Server ' + $TargetServerVersion + ' (64-bit), as Broadcom''s IPU KB 374927 instructs.') -Kind 'Checklist'
    Add-Result 'VMWARE' 'BroadcomGuidance' 'INFO' 'Broadcom KB 374927' 'Broadcom recommends a new VM with a clean install over an in-place upgrade of the guest OS.' -Recommendation 'Company decision; listed so the choice to do an IPU is made knowingly.' -Kind 'Observation' -Source 'knowledge.broadcom.com/external/article/374927'
}

function Invoke-DriversCheck {
    $unsigned = @()
    $pnp = @(); $pnpError = ''
    try { $pnp = @(Get-CimRequired 'Win32_PnPSignedDriver' | Where-Object { $_.DeviceName -and $_.DriverProviderName -and $_.DriverProviderName -notmatch '^Microsoft' }) }
    catch {
        $pnpError = $_.Exception.Message; Write-Swallowed $_
        Add-Result 'DRIVERS' 'DeviceDrivers' 'MANUAL' 'The device driver list could not be read' $pnpError -Recommendation 'List the third-party drivers by hand (driverquery /v, or Device Manager) before the change; old drivers are the most common cause of IPU rollback.' -Kind 'Finding' -Source 'Win32_PnPSignedDriver'
    }
    foreach ($d in @($pnp | Sort-Object DeviceName,DriverVersion -Unique)) {
        $date = [string]$d.DriverDate
        $driverDate = ConvertTo-DateTimeValue $d.DriverDate
        if ($driverDate) { $date = $driverDate.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
        Add-Result 'DRIVERS' ('Device: ' + $d.DeviceName) 'INFO' ('Provider=' + $d.DriverProviderName) @(('Version=' + $d.DriverVersion),('Date=' + $date),('Class=' + $d.DeviceClass),('Signed=' + $d.IsSigned)) -Source 'Win32_PnPSignedDriver'
        if ($d.IsSigned -eq $false) { $unsigned += $d.DeviceName }
    }
    $kernelCount = 0
    foreach ($drv in @($script:Data.KernelDrivers | Sort-Object Name)) {
        $path = ([string]$drv.PathName -replace '^\\\?\?\\','' -replace '^\\SystemRoot', $env:windir -replace '^(?i)system32', (Join-Path $env:windir 'System32'))
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }
        $info = $null
        try { $info = (Get-Item -LiteralPath $path).VersionInfo } catch { Write-Swallowed $_; continue }
        if ($info.CompanyName -and $info.CompanyName -notmatch 'Microsoft') {
            $kernelCount++
            Add-Result 'DRIVERS' ('Kernel driver: ' + $drv.Name) 'INFO' ('Company=' + $info.CompanyName) @(('FileVersion=' + $info.FileVersion),('Path=' + $path)) -Source 'Win32_SystemDriver'
        }
    }
    $devicesText = 'NonMicrosoftDevices=' + @($pnp | Sort-Object DeviceName -Unique).Count
    if ($pnpError) { $devicesText = 'NonMicrosoftDevices=unknown' }
    Add-Result 'DRIVERS' 'Summary' 'INFO' ($devicesText + ', NonMicrosoftKernelDrivers=' + $kernelCount) -Recommendation 'Old third-party drivers are the most common cause of IPU rollback (0xC1900101). Update them, especially storage, network and security drivers, before IPU.' -Source 'Win32_PnPSignedDriver, Win32_SystemDriver'
    if ($unsigned.Count -gt 0) {
        Add-Result 'DRIVERS' 'UnsignedDrivers' 'WARNING' ('Count=' + $unsigned.Count) ($unsigned -join ', ') -Recommendation 'Unsigned drivers may not load after the upgrade. Replace them with signed versions before IPU.' -Source 'Win32_PnPSignedDriver'
    }
}
