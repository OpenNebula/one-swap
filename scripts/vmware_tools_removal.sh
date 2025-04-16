#!/bin/bash

# Script to remove VMware Tools from Linux machines (Ubuntu/Debian/CentOS/RHEL)

# Check if the user is root
if [[ "$EUID" -ne 0 ]]; then
  echo "[VMWare Tools removal] This script must be run as root."
  exit 1
fi

is_package_installed() {
  local package="$1"
  command -v "$package" >/dev/null 2>&1
}

remove_vmware_tools() {
  echo "[VMWare Tools removal] Attempting to remove VMware Tools..."

  # Check for and remove open-vm-tools
  if is_package_installed "apt-get"; then
    echo "[VMWare Tools removal] [VMWare Tools removal]  Using apt-get to remove open-vm-tools..."
    apt-get remove --purge -y open-vm-tools open-vm-tools-desktop
    apt-get autoremove -y
  elif is_package_installed "yum"; then
    echo "[VMWare Tools removal] Using yum to remove open-vm-tools..."
    yum remove -y open-vm-tools open-vm-tools-desktop
  elif is_package_installed "dnf"; then
    echo "[VMWare Tools removal] Using dnf to remove open-vm-tools..."
    dnf remove -y open-vm-tools open-vm-tools-desktop
  fi

  # Check for and remove VMware Tools
  if [ -d "/usr/lib/vmware-tool/usr/lib/vmware-toolss" ]; then
    echo "[VMWare Tools removal] Found potential VMware Tools installation in /usr/lib/vmware-tools..."
    echo "[VMWare Tools removal] Attempting to run the uninstall script (if it exists)."
    if [ -x "/usr/lib/vmware-tools/uninstall/vmware-uninstall-tools.pl" ]; then
      echo "[VMWare Tools removal] Executing /usr/lib/vmware-tools/uninstall/vmware-uninstall-tools.pl"
      /usr/lib/vmware-tools/uninstall/vmware-uninstall-tools.pl --clobber-config --unattended
    elif [ -x "/usr/lib/vmware-tools/uninstall.sh" ]; then
      echo "[VMWare Tools removal] Executing /usr/lib/vmware-tools/uninstall.sh"
      /usr/lib/vmware-tools/uninstall.sh --unattended
    else
      echo "[VMWare Tools removal] No uninstall script found. Manually removing VMware Tools files."
      rm -rf /usr/lib/vmware-tools /etc/vmware-tools
    fi
  fi
  echo "[VMWare Tools removal] Done. Reboot to complete removal."
}

remove_vmware_tools

exit 0
