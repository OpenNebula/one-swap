1. Convert VM metadata and define a new VM at the target hypervisor
2. Take a snapshot of the VM disks on the source hypervisor
3. Copy the snapshot to the target hypervisor
4. Convert the VM disk image format
5. Take a second snapshot, if needed, and copy the latest changes to the target hypervisor
6. Apply the changes to the target image.
7. Stop the VM at the source hypervisor
8. Copy the data changed since the last snapshot to the target hypervisor
9. Apply the changes to the target image.
10. OS morphing
11. Start the VM at the target hypervisor


Questions
- what about block device based datastores. For example ceph.
- OneSwap converts VMs in vCenter to VM Templates
  - we could convert directly to a VM instead of the VM Template.
    - Reduces VM deployment downtime
  - Do we deploy the VM Template with this delta migration ?
- Maybe a 3rd snapshot can reduce DOWNTIME even more
- We could apply virt-v2v directly to the image already existing in the image DS in other oneswap conversion, to avoid multiple disk copies
  - Currently
    - ova/vcenter vmdk gets tranferred to work_dir
    - virt-v2v does OS changes to work_dir
    - work_dir gets copied to image_ds
  - Proposal (only makes sense for raw images)
    - Create empty image
    - ova/vcenter vmdk gets tranferred to work_dir
    - virt-v2v does OS changes to image SOURCE
    -
- virt-v2v-in-place
  - What if the VM has multiple disks

Optimization for Persistent Images. Maybe ?
- Instantiate the VM Template with the dummy images
- Poweroff --hard the VM
- perform the syncing of the images on the system DS

Procedure
- Get vCenter VM metadata
  - For each disk.
    - Create empty OS/DATABLOCK image
    - Link disk to VM TEMPLATE
  - Create VM Template
- Snapshot (1st) the vCenter VM
- copy all vmdk files to target datastore
  - current write vmdk file will fail
- convert copied vmdk files to raw
- Snapshot (2nd) the vCenter VM
- copy all vmdk files to target datastore
  - current write vmdk file will fail
- Apply newly copied snapshot to the existing raw image
- Stop vCenter VM ### DOWNTIME BEGINS
- copy failed vmdk files to target datastore
- Apply newly copied snapshot to the existing raw image
- virt-v2v
  - Create a simple temporary libvirt xml
  -
- deploy VM Template ?
