
# Script to remove VMware Tools from Windows machines (Windows 2008-2019)

$script:LogFile = 'C:\Program Files\Guestfs\Firstboot\vmware_tools_removal.log'

function Write-RemovalLog {
    param(
        [string]$Message
    )

    $line = "[VMWare Tools removal] $Message"
    Write-Host $line
    try {
        $log_dir = Split-Path -Parent $script:LogFile
        New-Item -ItemType Directory -Path $log_dir -Force | Out-Null
        Add-Content -Path $script:LogFile -Value "$(Get-Date -Format o) $line"
    } catch {
        Write-Host "[VMWare Tools removal] Warning: could not write log file: $_"
    }
}

function Get-VMwareToolsInstallerEntry {
    $uninstall_roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($root in $uninstall_roots) {
        $entry = Get-ItemProperty $root -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -eq 'VMware Tools' -or $_.ProductName -eq 'VMware Tools' } |
            Select-Object -First 1

        if ($entry) {
            Write-RemovalLog "Found VMware Tools installer entry at $root (ProductCode=$($entry.PSChildName))."
            return $entry
        }
    }

    Write-RemovalLog 'No VMware Tools installer entry was found in either uninstall hive.'
    return $null
}

function Stop-VMwareToolsProcesses {
    $process_names = @(
        'vmtoolsd',
        'vmwaretray',
        'vmacthlp',
        'vmwareuser',
        'VGAuthService'
    )

    Get-Process -Name $process_names -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

function Write-ServiceInventory {
    param(
        [array]$Services,
        [string]$Title
    )

    Write-RemovalLog $Title
    if (-not $Services -or $Services.Count -eq 0) {
        Write-RemovalLog ' - none'
        return
    }

    foreach ($service in $Services) {
        $cim_service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($service.Name)'" -ErrorAction SilentlyContinue
        if ($cim_service) {
            Write-RemovalLog " - Service: $($service.Name) DisplayName=$($service.DisplayName) State=$($cim_service.State) StartMode=$($cim_service.StartMode) StartName=$($cim_service.StartName)"
        } else {
            Write-RemovalLog " - Service: $($service.Name) DisplayName=$($service.DisplayName) State=$($service.Status)"
        }
    }
}

function Mark-For-DeletionOnReboot {
    param(
        [string]$Path
    )

    $sig = '[DllImport("kernel32.dll", SetLastError=true)] public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);'
    $type_name = 'Win32Functions.Win32MoveFileEx'
    if (-not ([System.Management.Automation.PSTypeName]$type_name).Type) {
        Add-Type -MemberDefinition $sig -Name 'Win32MoveFileEx' -Namespace Win32Functions | Out-Null
    }
    $type = [Win32Functions.Win32MoveFileEx]
    $type::MoveFileEx($Path, $null, 4) | Out-Null
    Write-RemovalLog "Marked $Path for deletion on reboot."
}

function Invoke-VMwareToolsUninstall {
    param(
        $InstallerEntry
    )

    if (-not $InstallerEntry) {
        Write-RemovalLog 'No VMware Tools MSI entry found; skipping msiexec uninstall.'
        return $false
    }

    $product_code = $InstallerEntry.PSChildName
    if ($product_code -notmatch '^\{[0-9A-Fa-f-]+\}$') {
        Write-RemovalLog "Found VMware Tools entry '$product_code' but it does not look like a MSI product code."
        return $false
    }

    Write-RemovalLog "Running msiexec /x $product_code /qn /norestart."
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/x', $product_code, '/qn', '/norestart') -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 1641 -or $process.ExitCode -eq 3010) {
        Write-RemovalLog "msiexec completed with exit code $($process.ExitCode)."
        return $true
    }

    Write-RemovalLog "msiexec failed with exit code $($process.ExitCode)."
    return $false
}

$vmware_tools_entry = Get-VMwareToolsInstallerEntry
$services = @()
$reg_targets = @(
    'Registry::HKEY_CLASSES_ROOT\Installer\Features\',
    'Registry::HKEY_CLASSES_ROOT\Installer\Products\',
    'HKLM:\SOFTWARE\Classes\Installer\Features\',
    'HKLM:\SOFTWARE\Classes\Installer\Products\',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\'
)

$vmware_tools_directory = 'C:\Program Files\VMware'
$vmware_common_directory = 'C:\Program Files\Common Files\VMware'

$targets = @()

if ($vmware_tools_entry) {
    $installer_key = $vmware_tools_entry.PSChildName
    foreach ($item in $reg_targets) {
        $targets += $item + $installer_key
    }

    $targets += "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$installer_key"
}

if ([Environment]::OSVersion.Version.Major -lt 10) {
    $targets += 'HKCR:\CLSID\{D86ADE52-C4D9-4B98-AA0D-9B0C7F1EBBC8}'
    $targets += 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{9709436B-5A41-4946-8BE7-2AA433CAF108}'
    $targets += 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{FE2F6A2C-196E-4210-9C04-2B1BC21F07EF}'
}

if (Test-Path 'HKLM:\SOFTWARE\VMware, Inc.') {
    $targets += 'HKLM:\SOFTWARE\VMware, Inc.'
}
if (Test-Path $vmware_tools_directory) {
    $targets += $vmware_tools_directory
}
if (Test-Path $vmware_common_directory) {
    $targets += $vmware_common_directory
}

$vmware_services = @(Get-Service -Name 'VMware*' -ErrorAction SilentlyContinue)
if (-not $vmware_services) {
    $vmware_services = @(Get-Service -DisplayName 'VMware*' -ErrorAction SilentlyContinue)
}
if ($vmware_services) { $services += $vmware_services }

$gisvc = @(Get-Service -Name 'GISvc' -ErrorAction SilentlyContinue)
if (-not $gisvc) {
    $gisvc = @(Get-Service -DisplayName 'GISvc' -ErrorAction SilentlyContinue)
}
if ($gisvc) { $services += $gisvc }

$vgauthsvc = @(Get-Service -Name 'VGAuthService' -ErrorAction SilentlyContinue)
if ($vgauthsvc) { $services += $vgauthsvc }

Write-RemovalLog "Detected $($services.Count) service(s) matching VMware/GISvc/VGAuthService filters."
Write-ServiceInventory -Services $services -Title 'Service inventory before uninstall:'

Write-RemovalLog 'Attempting to remove VMware Tools...'
if (-not $vmware_tools_entry -and -not $targets -and -not $services) {
    Write-RemovalLog 'Nothing to do!'
    exit 0
}

Write-RemovalLog 'The following registry keys, filesystem folders, and services will be deleted:'
$targets | ForEach-Object { Write-RemovalLog " - $_" }
$services | ForEach-Object { Write-RemovalLog " - Service: $($_.Name)" }

Stop-VMwareToolsProcesses
Write-RemovalLog 'Stopped VMware Tools-related processes if any were running.'
Write-ServiceInventory -Services $services -Title 'Service inventory after process stop:'

if ($services.Count -gt 0) {
    try {
        $services | Stop-Service -Confirm:$false -ErrorAction SilentlyContinue
        Write-RemovalLog 'Services stopped.'
    } catch {
        Write-RemovalLog "Warning: failed to stop services: $_"
    }

    if (Get-Command Remove-Service -ErrorAction SilentlyContinue) {
        $services | Remove-Service -Confirm:$false -ErrorAction SilentlyContinue
        Write-RemovalLog 'Services removed using Remove-Service.'
    } else {
        foreach ($service in $services) {
            sc.exe DELETE $service.Name | Out-Null
            Write-RemovalLog "Service $($service.Name) deleted with sc.exe."
        }
    }
} else {
    Write-RemovalLog 'No VMware-related services were detected for removal.'
}

Invoke-VMwareToolsUninstall $vmware_tools_entry | Out-Null
Write-RemovalLog 'Uninstall step finished.'

foreach ($item in $targets) {
    if (Test-Path $item) {
        try {
            Remove-Item -Path $item -Recurse -Force -ErrorAction Stop
            Write-RemovalLog "Deleted: $item"
        } catch {
            Write-RemovalLog "Could not delete $item; marking for deletion on reboot."
            if (Test-Path $item -PathType Leaf) {
                Mark-For-DeletionOnReboot $item
            }
        }
    }
}

Write-RemovalLog "Removal sweep completed. Remaining registry/file targets may be deleted on reboot if any were marked for deletion."
Write-RemovalLog 'Done. Reboot to complete removal.'
