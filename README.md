# Description

oneswap aims to provide a smooth VM migration path from vCenter to OpenNebula KVM

# Installation

Prerequisites:
- virt-v2v
- libguestfs-tools
- nbdkit 
- nbdkit-plugin-dev 
- nbdkit-plugin-libvirt
- libguestfs-xfs ( for XFS guests )
- libguestfs-zfs ( for ZFS guests )

Optional requirements:
- vddk library
  * VDDK library is not freely distributable and you can download it from VMWare's Developers Portal
- RHSrvAny.exe - for Windows Context Injection
  * https://github.com/rwmjones/rhsrvany 

OneSwap Installation
- Execute `install.sh` in your OpenNebula Front-End to install oneswap and helper library
- Use `install.sh -l` or `install.sh -c` options for a symbolic link or copy based installation of oneswap

Required Tools for converting Windows Guests:
- Download and install rhsrvany tools from GitHub:
  * https://github.com/rwmjones/rhsrvany
  - Download latest version of the RPM found at https://rpmfind.net/linux/rpm2html/search.php?query=mingw32-srvany
  - Extract EXE's from rpm package by executing:
    * `rpm2cpio srvany.rpm | cpio -idmv \
      && mkdir /usr/share/virt-tools \
      && mv ./usr/i686-w64-mingw32/sys-root/mingw/bin/*exe /usr/share/virt-tools/`
- Download VirtIO ISO drivers for Windows to the /usr/share/virtio-win/ directory:
  * https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso
- Maybe the QEMU guest agent as well, since virt-v2v 

If you are going to install context on the guest with this utility:
- Download necessary context packages from the github
- Place them all in a specific directory, default at /var/lib/one/context/  ( --context argument )

# Workload Preparation

Linux Guests should have the following installed:
- Kernel Headers (kernel-devel)
- VM must be shut down cleanly from inside the guest (hibernation or suspend mode are not supported)
- Verify BIOS/UEFI firmware usage on guest
  * If UEFI boot is enabled, OpenNebula template->OS&CPU->Boot section should be configured as follows:
    * CPU architecture: x86_64
    * Machine type: q35
    * UEFI firmware: UEFI: `/usr/share/OVMF/OVMF_CODE.secboot.fd`
- Virtio drivers should be supported by the running Linux kernel (minimum kernel version v2.6.30)

Windows Guests:
- Disable fast startup
- Must be shut down cleanly from inside the guest (hibernation or suspend modes are not supported)
- Verify BIOS/UEFI firmware usage on guest
  * If UEFI boot is enabled, OpenNebula template->OS&CPU->Boot section should be configured as follows:
    * CPU architecture: x86_64
    * Machine type: q35
    * UEFI firmware: UEFI: `/usr/share/OVMF/OVMF_CODE.secboot.fd`
- Virtio Storage/Network drivers will be injected automatically
- Windows Server 2016 onwards will requiere UEFI firmware to boot up correctly.

# Limitations

- Ubuntu/Debian based distributions

virt-v2v tool does not support Grub2 update. The following message will be shown during conversion process:

`WARNING: could not determine a way to update the configuration of Grub2`

Depending on GRUB2 boot up complexity and configuration, boot process would require to be fixed by OS recovery tools (SystemRescueCD or Ubuntu Live Recovery)

- Windows

Windows is only compatible with virt-v2v style conversion, will refuse to use `--custom` or `--fallback`.

# Usage

* Define your vCenter Options:

	`VOPTS='--vcenter 10.10.10.120 --vuser Administrator@VSPHERE.LOCAL --vpass password'`

	Optionally define ESXi Options, only required for direct ESXi transfer. Both options are required for this because the metadata of the virtual machine is still gathered through vCenter.

	`EOPTS='--esxi 10.10.10.121 --esxi_user root --esxi_pass password'`

* Listing Virtual Machines in vCenter:

	`oneswap list vms $VOPTS \[--datacenter DCName \[--cluster Cluster1\]\]`

* Converting VM's from vCenter to OpenNebula: 

	`oneswap convert 'Virtual Machine Name' $VOPTS \[\($EOPTS | --vddk /path/to/vddk-lib\)\]`

	Options (optional):

	`--vddk [path to vddk lib]`

	For faster conversion speeds, you can use VDDK VMware library by using `--vddk` option. You can use either the ESXi options `EOPTS` or the VDDK option, but not both. This also does not work with the custom conversion method.

	***Converting Network Interfaces***

	In each OpenNebula Virtual Network used for migration targets, create an attribute `VCENTER_NETWORK_MATCH` with the name of the Network in vCenter, This will automatically assign each NIC of the migrated VM to the proper network.

	`VCENTER_NETWORK_MATCH=VMware Network`

	oneswap requires a default network to be defined for the network interfaces that do not have a valid match by using `--network [network_ID]` option. Omitting the network argument will not generate any networks for the virtual machine and you will need to create them manually. For example:

	`oneswap convert 'Virtual Machine Name' $VOPTS --network 1`

# Troubleshooting
