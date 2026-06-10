Build libguestfs
========================

Download sources from http://download.libguestfs.org/1.40-stable/libguestfs-1.40.2.tar.gz

Download virtio-win ISO from https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/

sudo yum install yum-utils

sudo yum-builddep libguestfs

sudo ln -s supermin5 /usr/bin/supermin
patch -p 1 -i ../v2v-patch
./configure
make

sudo yum install libguestfs-winsupport virt-v2v
cp /usr/lib64/guestfs/supermin.d/zz-winsupport.tar.gz builddir/appliance/supermin.d/
sudo mkdir -p /opt/windows-convert/files/
sudo cp cert1.cer /opt/windows-convert/files/cert1.cer

sudo mkdir -p /usr/local/share/virtio-win
sudo mount -o loop,ro virtio-win-0.1.171.iso /usr/local/share/virtio-win
sudo cp /usr/local/share/virtio-win/guest-agent/qemu-ga-x86_64.msi /opt/windows-convert/files/qemu-ga-x64.msi
sudo ln -s /usr/share/virt-tools /usr/local/share/virt-tools


virt-v2v -v -x -i libvirtxml domain.xml --in-place


