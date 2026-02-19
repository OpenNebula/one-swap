![OneSwap Logo Color](https://github.com/OpenNebula/one-swap/assets/92747003/a770a3e2-2774-4682-ab36-c18d6e75f442)

# OneSwap

OneSwap is a command-line tool designed to simplify converting Virtual Machines from vCenter to OpenNebula. It supports `virt-v2v` and `qemu-img` conversion and is able to import Open Virtual Appliances (OVAs) previously exported from vCenter/ESXi environments.

OneSwap has been used in the field with a 96% success rate in converting VMs automatically, greatly simplifying and speeding up the migration process.

The full documentation is available in the in the [OpenNebula documentation](https://docs.opennebula.io/stable/):

  - For guide on converting Virtual Machines from vCenter to OpenNebula, see [Migrating VMs with OneSwap](https://docs.opennebula.io/stable/software/migration_from_vmware/oneswap/)
  - For guides on importing OVAs and VMDKs, see [Managing OVAs and VMDKs](https://docs.opennebula.io/stable/software/migration_from_vmware/import_ova/)

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
