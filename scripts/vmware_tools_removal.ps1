
# Script to remove VMware Tools from Windows machines (Windows 2008–2019)

function Get-VMwareToolsInstallerID {
    foreach ($item in $(Get-ChildItem Registry::HKEY_CLASSES_ROOT\Installer\Products)) {
        if ($item.GetValue('ProductName') -eq 'VMware Tools') {
            return @{
                reg_id = $item.PSChildName
                msi_id = [Regex]::Match($item.GetValue('ProductIcon'), '(?<={)(.*?)(?=})') | Select-Object -ExpandProperty Value
            }
        }
    }
}

function Mark-For-DeletionOnReboot($path) {
    $sig = '[DllImport("kernel32.dll", SetLastError=true)] public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);'
    $type = Add-Type -MemberDefinition $sig -Name 'Win32MoveFileEx' -Namespace Win32Functions -PassThru
    $type::MoveFileEx($path, $null, 4) | Out-Null
    Write-Host "[VMWare Tools removal] Marked $path for deletion on reboot."
}

$vmware_tools_ids = Get-VMwareToolsInstallerID

$reg_targets = @(
    "Registry::HKEY_CLASSES_ROOT\Installer\Features\",
    "Registry::HKEY_CLASSES_ROOT\Installer\Products\",
    "HKLM:\SOFTWARE\Classes\Installer\Features\",
    "HKLM:\SOFTWARE\Classes\Installer\Products\",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\"
)

$VMware_Tools_Directory = "C:\Program Files\VMware"
$VMware_Common_Directory = "C:\Program Files\Common Files\VMware"

$targets = @()

if ($vmware_tools_ids) {
    foreach ($item in $reg_targets) {
        $targets += $item + $vmware_tools_ids.reg_id
    }
    $targets += "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{$($vmware_tools_ids.msi_id)}"
}

if ([Environment]::OSVersion.Version.Major -lt 10) {
    $targets += "HKCR:\CLSID\{D86ADE52-C4D9-4B98-AA0D-9B0C7F1EBBC8}"
    $targets += "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{9709436B-5A41-4946-8BE7-2AA433CAF108}"
    $targets += "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{FE2F6A2C-196E-4210-9C04-2B1BC21F07EF}"
}

if (Test-Path "HKLM:\SOFTWARE\VMware, Inc.") {
    $targets += "HKLM:\SOFTWARE\VMware, Inc."
}
if (Test-Path $VMware_Tools_Directory) {
    $targets += $VMware_Tools_Directory
}
if (Test-Path $VMware_Common_Directory) {
    $targets += $VMware_Common_Directory
}

$services = @()
$vmware_services = Get-Service -DisplayName "VMware*" -ErrorAction SilentlyContinue
if ($vmware_services) { $services += $vmware_services }
$gisvc = Get-Service -DisplayName "GISvc" -ErrorAction SilentlyContinue
if ($gisvc) { $services += $gisvc }
Write-Host "[VMWare Tools removal] Attempting to remove VMware Tools..."
if (!$targets -and !$services) {
    Write-Host "[VMWare Tools removal] Nothing to do!"
} else {
    Write-Host "[VMWare Tools removal] The following registry keys, filesystem folders, and services will be deleted:"
    $targets | ForEach-Object { Write-Host " - $_" }
    $services | ForEach-Object { Write-Host " - Service: $($_.Name)" }

    if ($services.Count -gt 0) {
        try {
            $services | Stop-Service -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "[VMWare Tools removal] Services stopped."
        } catch {
            Write-Host "[VMWare Tools removal] Warning: Failed to stop services: $_"
        }

        if (Get-Command Remove-Service -ErrorAction SilentlyContinue) {
            $services | Remove-Service -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "[VMWare Tools removal] Services removed using Remove-Service."
        } else {
            foreach ($s in $services) {
                sc.exe DELETE $($s.Name) | Out-Null
                Write-Host "[VMWare Tools removal] Service $($s.Name) deleted with sc.exe."
            }
        }
    }

    foreach ($item in $targets) {
        if (Test-Path $item) {
            try {
                Remove-Item -Path $item -Recurse -Force -ErrorAction Stop
                Write-Host "[VMWare Tools removal] Deleted: $item"
            } catch {
                Write-Host "[VMWare Tools removal] Could not delete $item — marking for deletion on reboot."
                if (Test-Path $item -PathType Leaf) {
                    Mark-For-DeletionOnReboot $item
                }
            }
        }
    }

    Write-Host "[VMWare Tools removal] Done. Reboot to complete removal."
}
