![OneSwap Logo Color](https://github.com/OpenNebula/one-swap/assets/92747003/a770a3e2-2774-4682-ab36-c18d6e75f442)

# OneSwap

OneSwap is a command-line tool designed to simplify converting Virtual Machines from vCenter to OpenNebula. It supports `virt-v2v` and `qemu-img` conversion and is able to import Open Virtual Appliances (OVAs) previously exported from vCenter/ESXi environments.

OneSwap has been used in the field with a 96% success rate in converting VMs automatically, greatly simplifying and speeding up the migration process.

When OpenNebula Image or VM Template allocation fails, OneSwap reports the
OpenNebula API error directly and stops the current conversion.

The full documentation is available in the in the [OpenNebula documentation](https://docs.opennebula.io/stable/):

  - For guide on converting Virtual Machines from vCenter to OpenNebula, see [Migrating VMs with OneSwap](https://docs.opennebula.io/stable/software/migration_from_vmware/oneswap/)
  - For guides on importing OVAs and VMDKs, see [Managing OVAs and VMDKs](https://docs.opennebula.io/stable/software/migration_from_vmware/import_ova/)

## System Requirements

The following packages must be installed on the conversion host:

| Package | Required for |
|---------|-------------|
| `virt-v2v` | All standard conversion modes |
| `guestfs-tools` | Context injection, `--virtio`, `--win-qemu-ga` (requires ≥ 1.49.9 for those options) |
| `qemu-img` | All conversion modes |
| `ovmf` | Migrating UEFI guests (provides OVMF firmware for x86-64); without it `virt-v2v` will fail with *"cannot find firmware for UEFI guests"* |
| `guestfish` / `virt-inspector` | Windows context injection and disk inspection |
| `nbdkit` (with VDDK plugin) | `--vddk` transfers; Debian/Ubuntu packages do not ship the VDDK plugin — see [VDDK Transfer Support](#vddk-transfer-support) |

When installing OneSwap via the provided packages all dependencies are installed automatically. If deploying from source, the dependencies listed in the table above must be installed manually using the system package manager.

### Non-root libguestfs

When OneSwap is executed as a non-root user, libguestfs/supermin may fail if
the user cannot read the host kernel image under `/boot/vmlinuz-*`. In that
case, configure a prebuilt libguestfs appliance with `:libguestfs_path:` or
pass `--libguestfs-path`.

Detailed setup steps are documented in the OpenNebula documentation.

## Windows CompactOS Support

Windows guests that use NTFS system compression (CompactOS / WOF) fail
conversion with `inspection could not detect the source guest` /
`No root device found`, because the ntfs-3g inside the libguestfs appliance
cannot read WOF-compressed system files. You can check a guest from an
elevated prompt with:

```
compact /compactos:query
```

To enable CompactOS support, run once on each migration host (as root):

```
/usr/lib/one/oneswap/scripts/setup_ntfs_wof.sh
```

The script builds the
[ntfs-3g-system-compression](https://github.com/ebiggers/ntfs-3g-system-compression)
plugin, installs it, and packs it as a supermin.d overlay so every libguestfs
appliance rebuild includes it automatically (no fixed appliance or
`LIBGUESTFS_PATH` needed). It requires internet access, or an internal mirror
via the `NTFS_WOF_REPO_URL` environment variable.

Windows guests using the `vd` device prefix require VirtIO block drivers to
boot. OneSwap warns before conversion when no `virtio_path` is configured for
that case; configure it in `oneswap.yaml` or pass the existing VirtIO CLI option.

## VDDK Transfer Support

`--vddk` transfers require the nbdkit VDDK plugin, which Debian/Ubuntu
packages do not ship (on RHEL install the `nbdkit-vddk-plugin` package). To
build and install it, run once on each migration host (as root):

```
/usr/lib/one/oneswap/scripts/setup_nbdkit_vddk.sh
```

The script builds the nbdkit version matching the installed distro package
and copies only the VDDK plugin into nbdkit's plugin directory. It requires
internet access, or an internal mirror via the `NBDKIT_REPO_URL` environment
variable.

VDDK mode is also required for VMware vSAN-backed VMDKs. vSAN disks are
object-backed and are not available through the classic vCenter datastore
`*-flat.vmdk` download path used by the non-VDDK and hybrid transfer modes.

To convert VMs stored on a vSAN datastore, configure VDDK:

```yaml
:vddk_path: '/opt/vmware-vix-disklib-distrib/'
```

## Dry-run Estimates

OneSwap can estimate migration time without running the full conversion. Dry-run
reports estimate basis, rates, phase durations, and confidence.

Regular dry-run:

```
oneswap convert <vm> --dry-run
```

Optional OpenNebula import benchmark:

```
oneswap convert <vm> --dry-run --benchmark-import
```

Optional source export benchmark:

```
oneswap convert <vm> --dry-run --benchmark-export
```

`--benchmark-import` measures the OpenNebula image import path using a
temporary image. `--benchmark-export` creates a temporary file on the VM's
source datastore and measures the VMware datastore download path. Both store
mode-specific metrics for future estimates.

### Delta Dry-run Workflow

Staged delta migration can prepare the base disks while the source VM keeps
running, estimate the final phase, and then commit during the downtime window.

```
oneswap convert <vm> --delta --delta-prepare
oneswap convert <vm> --dry-run --delta
oneswap convert <vm> --dry-run --delta --benchmark-import
oneswap convert <vm> --delta --delta-commit
oneswap convert <vm> --delta --delta-cleanup
```

When OneSwap runs on a worker host, enable `http_transfer` so the OpenNebula
frontend can fetch images over HTTP. Local-path mode requires OneSwap to run on
the OpenNebula frontend, or `work_dir` to be shared at the same absolute path
on the frontend.

Do not leave the VMware snapshot created by `--delta --delta-prepare` active
indefinitely. Either finish with `--delta --delta-commit` or run
`--delta-cleanup` if aborting or postponing the migration.

For detailed behavior, metric selection, confidence levels, and examples, see
the official OpenNebula documentation.

## NetApp Shift Conversion

With `--shift`, the VMDK-to-qcow2 disk conversion is delegated to a
[NetApp Shift Toolkit](https://docs.netapp.com/us-en/netapp-solutions/shift-toolkit/shift-overview.html)
appliance instead of virt-v2v. Shift converts on the ONTAP storage side
(FlexClone based), so the disks never travel through the OneSwap worker.
OneSwap still gathers VM properties from vCenter, runs the guest
customization (context, VirtIO, QEMU Guest Agent) and creates the OpenNebula
images and template.

Prerequisites, all created in the Shift UI beforehand:

- A source site (vCenter + ONTAP) and a destination site.
- One or more resource groups containing the VMs to convert.
- A blueprint (DR plan) referencing those resource groups.
- The source NFS datastore mounted locally on the OneSwap host
  (`--shift-mount`); Shift writes `<vm-name>.qcow2` (plus
  `<vm-name>_1.qcow2`, ... for additional disks) next to each VM folder.
- `virt-v2v-in-place` installed on the conversion host.
- vCenter credentials, same as any other conversion mode: the VM properties,
  NICs and tags the OpenNebula template is built from still come from vCenter,
  even though the disks do not.

Power state is awkward, and the two Shift operations disagree about it:

- The **compliance check** wants the VMs powered **on**. With them off it
  reports them as failed resources (`{"powerState":"POWERED_OFF"}`), even
  though the conversion then runs perfectly well.
- The **convert** execution wants them powered **off**, and rejects the
  trigger otherwise (`ERSCSTEX022`, naming the offenders, and checking every
  VM in the blueprint rather than just the one being imported). This is the
  dismissable warning the Shift UI shows with a "Continue" button;
  `--shift-ignore-running-vms` is the same override, and OneSwap names the
  flag in the error so a failed run tells you how to retry.

Converting a running VM uses a point-in-time snapshot, so the resulting disks
are crash-consistent rather than quiesced — fine for most guests, but not for
a database you care about. Powering the VM down first is still the safer path.

Two workable combinations:

```
# VMs powered off; the compliance check objects to that, so skip it
oneswap convert $VOPTS $SOPTS --shift-skip-compliance

# VMs left running; compliance passes, convert needs the override
oneswap convert $VOPTS $SOPTS --shift-ignore-running-vms
```

Importing is unaffected by either: once the disks exist, OneSwap only reads
qcow2 files from the mount, so power state and snapshots are irrelevant. That
is why the powered-off/no-snapshot preconditions the other modes enforce are
skipped in Shift mode — and Shift's own clone leaves a snapshot behind anyway.

```
SOPTS='--shift https://<shift-ip> --shift-user admin --shift-pass ...'

# Which blueprints exist, and how many VMs each covers
oneswap list blueprints $SOPTS

# Which VMs a blueprint would convert
oneswap list vms $SOPTS --shift-blueprint bp1

SOPTS="$SOPTS --shift-blueprint bp1 --shift-mount /mnt/shift"

# Convert and import every VM in the blueprint
oneswap convert $VOPTS $SOPTS

# Convert the blueprint once, but only import selected VMs (in this order)
oneswap convert $VOPTS $SOPTS --vms vm-web-01,vm-db-01

# Import more VMs later; the blueprint is not executed again
oneswap convert vm-app-01 $VOPTS $SOPTS

# Import without contacting Shift at all (disks known to be on the mount)
oneswap convert vm-web-01 $VOPTS $SOPTS --shift-skip-conversion

# Trigger the blueprint but skip the compliance check (already checked, or resuming)
oneswap convert $VOPTS $SOPTS --shift-skip-compliance

# Import without the OS morph, for guests virt-v2v refuses to convert
oneswap convert alpine-vm $VOPTS $SOPTS --shift-skip-morph
```

After the disks are converted, OneSwap runs `virt-v2v-in-place` on them to
install virtio drivers and fix the initramfs and bootloader for KVM. virt-v2v
only recognises guests it has support for, and rejects the rest with
`virt-v2v is unable to convert this guest type` — Alpine among them. Guests
like that usually boot on KVM unmodified because virtio is already built in,
so `--shift-skip-morph` imports the converted disks as they are. OneSwap names
the flag in the error when it hits that case.

Notes:

- A blueprint execution converts **every** VM in its resource group(s), in
  parallel, regardless of which VMs are then imported. Keep blueprints
  aligned with what you intend to import — `oneswap list blueprints` and
  `oneswap list vms --shift-blueprint <name>` show what you are committing to
  before you run anything.
- `oneswap list vms` reads from Shift whenever `--shift` (or `:shift:` in the
  config file) is set, and from vCenter otherwise. `list datacenters` and
  `list clusters` are vCenter concepts and always use vCenter.
- One execution serves every later `oneswap convert` against that blueprint.
  OneSwap checks the blueprint state first and, if it has already converted,
  reuses the disks on the mount instead of executing again -- Shift rejects a
  second execution until the previous one is cleared. If an execution is
  still running, OneSwap attaches to it and waits instead of starting another.
  To genuinely convert again, clear the blueprint execution in the Shift UI
  (or with the `removeBpJobs.ps1` script NetApp ships) and re-run.
  `--shift-skip-conversion` is only needed to skip talking to Shift entirely.
- The OS morph (`virt-v2v-in-place`) and context injection modify the qcow2
  files on the datastore in place -- there is no local copy, so terabyte
  disks work on workers with small local storage. To regenerate a disk,
  re-run the blueprint in the Shift UI; re-importing an already imported VM
  without regenerating it is unsupported (the guest would be morphed twice).
- The wait for the blueprint execution runs until it finishes; interrupt
  with Ctrl+C or bound it with `:shift_wait_timeout:` in `oneswap.yaml`.
- `--shift` cannot be combined with `--delta`, `--hybrid`, `--custom`,
  `--fallback`, `--vddk`, `--esxi`, `--clone` or `--dry-run`.

## vCenter Permissions Requirements

OneSwap requires specific vCenter permissions depending on the conversion mode used. Below are the required privileges for vCenter 8.

### Minimum Permissions (All Conversion Modes)

**Datastore**:
- **Browse datastore** - Required to discover VMDK files and VM storage configuration
- Used by: All conversion modes (standard virt-v2v, custom, hybrid, clone)

**Network**:
- **Assign network** - Required to read VM NIC configuration and network mappings
- Used by: All conversion modes

**Resource**:
- **Assign virtual machine to resource pool** - Required to read VM placement and resource allocation
- Used by: All conversion modes

**Virtual machine > Change Configuration**:
- **Change Settings** - Required to read VM hardware configuration (CPU, RAM, disks)
- **Query unowned files** - Required to access VM configuration files
- Used by: All conversion modes

**Virtual machine > Edit Inventory**:
- **Create from existing** - Required to read VM metadata and state
- Used by: All conversion modes

**Virtual machine > Guest operations**:
- **Guest operation queries** - Required to read guest OS information, IP addresses, and installed tools
- Used by: All conversion modes

### Additional Permissions for Clone Mode (`--clone`)

**Datastore**:
- **Allocate space** - Required to provision storage for the cloned VM (thin provisioning)
- Used by: `--clone` mode only

**Folder**:
- **Create folder** - **CRITICAL** - Required to create the cloned VM in the same folder as the original
  - Without this permission, clone operations will fail with `FileLocked: Unable to access file since it is locked`
- Used by: `--clone` mode only

**Virtual machine > Edit Inventory**:
- **Create new** - Required to create the cloned VM
- **Remove** - Required to delete the clone after successful conversion
- Used by: `--clone` mode only

**Virtual machine > Provisioning**:
- **Clone virtual machine** - Required to execute the CloneVM_Task operation
- **Customize guest** - Required for VM customization during cloning
- Used by: `--clone` mode only

### Additional Permissions for Custom/Fallback/Hybrid Modes

**Datastore**:
- **Low level file operations** - Required to download VMDK files directly from datastores
- Used by: `--custom`, `--fallback`, `--hybrid` modes

### Permission Setup Example

Create a custom role in vCenter 8:

```
Role Name: OneSwap-Standard
Description: Minimum permissions for standard virt-v2v conversions

Permissions:
  - Datastore > Browse datastore
  - Network > Assign network
  - Resource > Assign virtual machine to resource pool
  - Virtual machine > Change Configuration > Change Settings
  - Virtual machine > Change Configuration > Query unowned files
  - Virtual machine > Edit Inventory > Create from existing
  - Virtual machine > Guest operations > Guest operation queries
```

For clone mode support, create an extended role:

```
Role Name: OneSwap-Clone
Description: Permissions for clone-based conversions (zero production impact)

Includes all permissions from OneSwap-Standard, plus:
  - Datastore > Allocate space
  - Folder > Create folder
  - Virtual machine > Edit Inventory > Create new
  - Virtual machine > Edit Inventory > Remove
  - Virtual machine > Provisioning > Clone virtual machine
  - Virtual machine > Provisioning > Customize guest
```

For download-based conversions (custom/fallback/hybrid):

```
Role Name: OneSwap-Download
Description: Permissions for custom conversion modes

Includes all permissions from OneSwap-Standard, plus:
  - Datastore > Low level file operations
```

**Important Notes**:
- Assign roles at vCenter root level with **"Propagate to children"** enabled
- For `--clone` mode, the VM **must NOT have any snapshots** (remove all snapshots before cloning)
- For `--delta` and `--esxi` modes, vCenter permissions are minimal as operations run via direct ESXi SSH

## Contributing

* [Development and issue tracking](https://github.com/OpenNebula/one/issues?q=sort%3Aupdated-desc%20is%3Aissue%20is%3Aopen%20label%3A%22Category%3A%20OneSwap%22).

## Contact Information

* [OpenNebula web site](https://opennebula.io)
* [Enterprise Services](https://opennebula.io/enterprise)

## License

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.

## Author Information

Copyright 2002-2025, OpenNebula Project, OpenNebula Systems

## Acknowledgements

Some of the software features included in this repository have been made possible through the funding of the following innovation project: [ONEnextgen](http://onenextgen.eu/).

### Storpool sesparse tool

This tool allows to apply vmdk snapshots to vmdk disks converted to raw format. This tool is used in the delta transfer feature.


Copyright (c) 2019  StorPool.
 All rights reserved.

  Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that the following conditions
  are met:
  1. Redistributions of source code must retain the above copyright
     notice, this list of conditions and the following disclaimer.
  2. Redistributions in binary form must reproduce the above copyright
     notice, this list of conditions and the following disclaimer in the
     documentation and/or other materials provided with the distribution.

  THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
  ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
  ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
  FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
  DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
  OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
  HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
  LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
  OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
  SUCH DAMAGE.
