require 'minitest/autorun'
require_relative '../esxi_vm'

class EsxiActiveVmdksTest < Minitest::Test
    def detect(filename, type = nil, slot = 'scsi0:0')
        vmx = { "#{slot}.fileName" => filename }
        vmx["#{slot}.deviceType"] = type unless type.nil?
        ESXi::VirtualMachine.active_vmdks(vmx)
    end

    def test_normal_hard_disk
        assert_equal ['vm-1-000003.vmdk'], detect('vm-1-000003.vmdk', 'scsi-hardDisk')
    end

    def test_empty_cdrom
        assert_empty detect('emptyBackingString', 'atapi-cdrom', 'sata0:0')
    end

    def test_mixed_parsed_vmx
        Tempfile.create(['oneswap-disks', '.vmx']) do |file|
            file.write(<<~VMX)
                sata0:0.deviceType = "atapi-cdrom"
                sata0:0.fileName = "emptyBackingString"
                sata0:0.present = "TRUE"
                scsi0:0.deviceType = "scsi-hardDisk"
                scsi0:0.fileName = "vm-1-000003.vmdk"
                scsi0:0.present = "TRUE"
            VMX
            file.flush
            vmx = ESXi::Client.parse_vmware_file(file.path)
            assert_equal ['vm-1-000003.vmdk'], ESXi::VirtualMachine.active_vmdks(vmx)
        end
    end

    def test_explicit_non_disk_type_wins_over_filename
        %w[scsi ide sata].each do |bus|
            %w[atapi-cdrom cdrom-image cdrom-raw].each do |type|
                %w[installer.iso /dev/cdrom misleading.vmdk].each do |filename|
                    assert_empty detect(filename, type, "#{bus}0:0")
                end
            end
        end
    end

    def test_missing_device_type_accepts_vmdk_on_supported_slots
        %w[scsi ide sata].each do |bus|
            assert_equal ['disk.vmdk'], detect('disk.vmdk', nil, "#{bus}0:0")
        end
    end

    def test_only_vmdk_string_candidates_are_accepted
        [nil, 'scsi-hardDisk', 'unknown-device'].each do |type|
            assert_equal ['disk.vmdk'], detect(['emptyBackingString', 'disk.iso', nil, 42,
                                              'disk.vmdk.bak', 'disk.vmdk'], type)
        end
    end

    def test_arrays_order_and_duplicates
        vmx = {
            'scsi0:0.deviceType' => ['scsi-hardDisk', 'scsi-hardDisk'],
            'scsi0:0.fileName' => ['second.vmdk', 'first.vmdk', 'second.vmdk'],
            'sata0:1.fileName' => ['first.vmdk', 'third.vmdk']
        }
        assert_equal ['second.vmdk', 'first.vmdk', 'third.vmdk'],
                     ESXi::VirtualMachine.active_vmdks(vmx)
    end

    def test_nvme_disks_are_active_disks
        assert_equal ['data.vmdk'], detect('data.vmdk', nil, 'nvme0:0')
    end

    def test_disks_follow_controller_and_unit_order_not_vmx_line_order
        # hostd appends a re-attached disk at the end of the VMX.
        vmx = {
            'scsi0:1.fileName' => 'data.vmdk',
            'nvme0:0.fileName' => 'fast.vmdk',
            'sata0:0.fileName' => 'sata.vmdk',
            'ide0:1.fileName' => 'ide.vmdk',
            'scsi1:0.fileName' => 'other.vmdk',
            'scsi0:10.fileName' => 'ten.vmdk',
            'scsi0:0.fileName' => 'os.vmdk'
        }
        # The order of the vCenter device keys: SCSI, IDE, SATA, then NVMe.
        assert_equal ['os.vmdk', 'data.vmdk', 'ten.vmdk', 'other.vmdk', 'ide.vmdk', 'sata.vmdk', 'fast.vmdk'],
                     ESXi::VirtualMachine.active_vmdks(vmx)
    end

    def test_conflicting_device_types_exclude_device
        assert_empty detect('disk.vmdk', ['scsi-hardDisk', 'cdrom-image'])
        assert_empty detect('disk.vmdk', ['cdrom-image', 'scsi-hardDisk'])
        assert_empty detect('disk.vmdk', ['unknown-device', 'atapi-cdrom'])
        assert_empty detect('disk.vmdk', ['atapi-cdrom', 'unknown-device'])
    end

    def test_unknown_device_types_preserve_filename_fallback
        ['unknown-device', ['unknown-device', 'another-type']].each do |type|
            assert_equal ['disk.vmdk'], detect('disk.vmdk', type)
        end
    end

    def test_supported_hard_disk_types
        %w[hardDisk scsi-hardDisk ide-hardDisk sata-hardDisk].each do |type|
            assert_equal ['disk.vmdk'], detect('disk.vmdk', type)
        end
    end

    def test_other_filename_keys_remain_excluded
        %w[floppy0 serial0 scsi0 scsi0:0.extra nvme0].each do |slot|
            assert_empty detect('disk.vmdk', nil, slot)
        end
    end

    def test_present_handling_is_unchanged
        vmx = { 'scsi0:0.fileName' => 'disk.vmdk', 'scsi0:0.present' => 'FALSE' }
        assert_equal ['disk.vmdk'], ESXi::VirtualMachine.active_vmdks(vmx)
    end
end
