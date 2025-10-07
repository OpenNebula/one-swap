![OneSwap Logo Color](https://github.com/OpenNebula/one-swap/assets/92747003/a770a3e2-2774-4682-ab36-c18d6e75f442)

# OneSwap

OneSwap is a command-line tool designed to simplify migrating Virtual Machines from vCenter to OpenNebula. It supports `virt-v2v` and `qemu-img` conversion and is able to import Open Virtual Appliances (OVAs) previously exported from vCenter/ESXi environments.

OneSwap has been used in the field with a 96% success rate in converting VMs automatically, greatly simplifying and speeding up the migration process.

The full documentation is available in the [OneSwap Wiki](https://github.com/OpenNebula/one-swap/wiki). For guides on importing OVAs and VMDKs, see [Managing OVAs and VMDKs](https://docs.opennebula.io/7.0/software/migration_from_vmware/import_ova/) in the [OpenNebula documentation](https://docs.opennebula.io/7.0/).

## Contributing

* [Development and issue tracking](https://github.com/OpenNebula/one-swap/issues).

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

/*-
 * Copyright (c) 2019  StorPool.
 * All rights reserved.
 */

/*
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

*/

/*
