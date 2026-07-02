![OneSwap Logo Color](https://github.com/OpenNebula/one-swap/assets/92747003/a770a3e2-2774-4682-ab36-c18d6e75f442)

# OneSwap

OneSwap is a command-line tool designed to simplify converting Virtual Machines from vCenter to OpenNebula. It supports `virt-v2v` and `qemu-img` conversion and is able to import Open Virtual Appliances (OVAs) previously exported from vCenter/ESXi environments.

OneSwap has been used in the field with a 96% success rate in converting VMs automatically, greatly simplifying and speeding up the migration process.

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

## Dry-run Estimates

To estimate a regular conversion without running the migration:

```
oneswap convert <vm> --dry-run
```

This reads VM and disk metadata, estimates export, qcow2 conversion, and
OpenNebula import time, and uses the configured fallback throughput values from
`oneswap.yaml`. It does not create VMware snapshots, OpenNebula images, or
OpenNebula templates, and it does not modify the source VM.

### Delta Dry-run Workflow

For delta migrations, you can stage the online base phase first:

```
oneswap convert <vm> --delta --delta-prepare
```

This creates a VMware snapshot while the source VM keeps running, then
clones, transfers, and converts the base disks. It writes prepared state under
the VM work directory and does not shut down the VM, apply the final delta, or
create OpenNebula images/templates. The VMware snapshot remains active after
prepare, so the delta can continue growing.

Then estimate downtime from the prepared state:

```
oneswap convert <vm> --dry-run --delta
```

This reads the prepared state, checks the current snapshot delta extent size
on ESXi, and estimates the final downtime/import-ready phase. It reports the
current delta copy estimate, delta apply estimate, OpenNebula image import/copy
estimate, virt-v2v-in-place / OS morph estimate, guest customization estimate,
and template creation as negligible. When available, it prefers measured base
transfer/conversion throughput stored during prepare and measured OpenNebula
import/customization metrics from previous runs. If that data is missing, it
falls back to configured values such as `dry_run_target_import_mib_s`,
`dry_run_delta_os_morph_seconds`, and
`dry_run_guest_customization_seconds`. Set `dry_run_target_import_mib_s` to
match the full OpenNebula frontend/datastore import path, not only network
bandwidth.

The delta dry-run report includes an estimate basis section showing whether
each phase comes from prepare measurements, an import benchmark, previous full
import metrics, or configured fallbacks. Confidence is `high` when prepare
transfer/conversion are measured and target import comes from a previous full
import or a benchmark of at least 4 GiB, and OS morph/customization timings
come from a previous successful run. It is `medium` when prepare metrics are
available but target import uses configured fallback or a small benchmark, or
when OS morph/customization still use configured fallback values. It is `low`
when prepare metrics are missing or an important phase cannot be accounted for.

To measure the OpenNebula frontend/datastore import path before commit, run:

```
oneswap convert <vm> --dry-run --delta --benchmark-import
```

This requires prepared delta state from `--delta --delta-prepare`. When
`http_transfer` is enabled, OneSwap creates a temporary non-sparse raw test
file under the VM work directory, serves it through the configured
`http_host`/`http_port`, allocates a temporary OpenNebula image, waits for it
to become `READY`, records the measured import rate in the VM metrics file,
deletes the temporary image, and then runs the normal delta dry-run estimate.
The test file size defaults to `dry_run_import_benchmark_size_mib: 4096` and
is configurable. Small benchmark files can be dominated by fixed OpenNebula
allocation, datastore, and polling overhead, so files below 1024 MiB are
reported with a warning and can produce pessimistic linear estimates. If a
previous full import metric is available, it is preferred over a small
benchmark because it is more representative. If the benchmark cannot run or
fails, the estimate falls back to previous import metrics or
`dry_run_target_import_mib_s`.

If you want to continue immediately, run the downtime phase:

```
oneswap convert <vm> --delta --delta-commit
```

This shuts down the source VM, copies and applies the remaining delta, and
then creates OpenNebula images/templates through the existing migration flow.
This is the real migration completion step, not a dry-run. If OneSwap runs on
a worker host that is not the OpenNebula frontend, enable `http_transfer` and
set `http_host`/`http_port` so the frontend can fetch the committed disk files
over HTTP instead of trying to read worker-local paths.

If you only wanted timing data and will migrate later, clean up the prepared
snapshot and state:

```
oneswap convert <vm> --delta --delta-cleanup
```

This removes the VMware snapshot created by prepare, the temporary ESXi clone
directory, and the local prepared transfer/conversion/state directory. Later,
during the chosen maintenance window, run a normal full delta migration with
the same backward-compatible command:

```
oneswap convert <vm> --delta
```

Delta migration discovers the ESXi host from vCenter `runtime.host`. ESXi SSH
authentication tries passwordless SSH first, then uses `esxi_user`/`esxi_pass`
from CLI options or `oneswap.yaml`, and finally falls back to a limited
interactive prompt. A single `esxi_user`/`esxi_pass` pair applies to the
discovered ESXi host; per-host credential mapping is not implemented.

Do not leave the VMware snapshot created by `--delta --delta-prepare` active
indefinitely. Either finish with `--delta --delta-commit` or run
`--delta-cleanup` if aborting or postponing the migration.

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
