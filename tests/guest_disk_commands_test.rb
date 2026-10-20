# Unit checks for the commands run on converted disks: paths are quoted
# (VM names may hold spaces or quotes) and the disk format is named
# (probing guest-controlled data could make the tools read host files).
# Run with: ruby tests/guest_disk_commands_test.rb

require 'logger'
require 'minitest/autorun'
require 'minitest/mock'
require 'ostruct'
require 'rexml/document'
require 'shellwords'
require 'stringio'
require 'tmpdir'

module OpenNebulaHelper
    class OneHelper; end
end

# Just enough of the OpenNebula API for the image creation.
module OpenNebula

    def self.is_error?(value)
        value.is_a?(Error)
    end

    class Error

        attr_reader :message

        def initialize(message)
            @message = message
        end

    end

    # An image whose datastore copy follows a script of states.
    class Image

        class << self

            attr_accessor :allocated, :deleted, :failing_name, :states, :names, :paths

            def reset(failing_name = nil)
                @allocated = []
                @deleted = []
                @paths = []
                @failing_name = failing_name
                @states = Hash.new {|hash, name| hash[name] = [] }
                @names = {}
            end

            def build_xml(_id = nil)
                nil
            end

            def new_with_id(id, _client)
                new(nil, nil).tap do |image|
                    image.instance_variable_set(:@id, id)
                    image.instance_variable_set(:@name, names[id])
                end
            end

        end

        attr_reader :id

        def initialize(_xml, _client)
            @id = nil
        end

        def add_element(_path, attributes)
            @attributes = attributes
            @name = attributes['NAME']
            Image.paths << attributes['PATH']
        end

        def to_xml
            @attributes
        end

        def allocate(_xml, _datastore)
            return Error.new('datastore full') if @name == Image.failing_name

            Image.allocated << @name
            @id = 100 + Image.allocated.length
            Image.names[@id] = @name
            nil
        end

        # The next state of the scripted copy, READY once the script ends;
        # :error fails the call, as while oned restarts.
        def info
            state = Image.states[@name].shift || 'READY'
            return Error.new('oned is not responding') if state == :error

            @state = state
            nil
        end

        def state_str
            @state
        end

        def short_state_str
            @state.to_s.downcase
        end

        def [](key)
            key == 'TEMPLATE/ERROR' && @state == 'ERROR' ? 'Error copying the image' : nil
        end

        # OpenNebula would leave the copy of a LOCKED image in the datastore.
        def delete
            return Error.new('the copy is still running') unless Image.states[@name].empty?

            Image.deleted << @id
            nil
        end

    end

end

module Kernel
    alias oneswap_guest_disk_original_require require

    def require(path)
        return true if ['one_helper', 'opennebula'].include?(path)

        oneswap_guest_disk_original_require(path)
    end
end

require_relative '../oneswap_helper'

class GuestDiskCommandsTest < Minitest::Test

    VM = "Bob's VM"
    WORK = "/var/tmp/work dir/#{VM}"
    DISK = "#{WORK}/esxi2kvm-#{VM}/disk0.raw"

    def ok
        OpenStruct.new(:success? => true, :exitstatus => 0)
    end

    def helper(options = {})
        OneSwapHelper.allocate.tap do |h|
            h.instance_variable_set(:@options, {
                :name => VM, :work_dir => WORK, :format => 'qcow2', :datastore => '1'
            }.merge(options))
            h.instance_variable_set(:@logger, Logger.new(File::NULL))
        end
    end

    # A disk the image import registered as raw.
    def raw_disk_helper(options = {})
        helper(options).tap {|h| h.send(:register_disk_format, [DISK], 'raw') }
    end

    def assert_adds_raw_disk(args, message = nil)
        assert_includes args.each_cons(3).to_a, ['--format=raw', '-a', DISK], message
    end

    # --- libguestfs tools ----------------------------------------------------

    def test_inspection_names_the_format_and_quotes_the_path
        h = raw_disk_helper
        cmd = nil
        Open3.stub(:capture3, ->(_env, command) { cmd = command; ['<operatingsystems/>', '', ok] }) do
            capture_io { assert_nil h.send(:detect_distro, DISK) }
        end

        assert_equal ['virt-inspector', '--format=raw', '-a', DISK, '--no-applications', '--no-icon'],
                     Shellwords.split(cmd)
    end

    def test_disks_of_unknown_format_keep_the_previous_arguments
        assert_equal '-a /tmp/disk', helper.send(:guestfs_disk, '/tmp/disk')
    end

    def test_customization_commands_name_the_format_and_quote_paths
        Dir.mktmpdir('oneswap guest ') do |dir|
            msi = File.join(dir, 'qemu ga.msi')
            script = File.join(dir, "removal's script.ps1")
            [msi, script].each {|path| File.write(path, '') }
            h = raw_disk_helper(:virtio_path => '/srv/virtio win.iso', :qemu_ga_win => msi)
            commands = {
                :virtio => h.send(:win_virtio_command, DISK),
                :qemu_ga => h.send(:qemu_ga_command, DISK),
                :package => h.send(:pkg_install_command, DISK, 'qemu-guest-agent'),
                :tools_linux => h.send(:remove_vmtools_command, DISK, { 'name' => 'linux' }, script),
                :tools_windows => h.send(:remove_vmtools_command, DISK, { 'name' => 'windows' }, script)
            }

            commands.each do |name, cmd|
                args = Shellwords.split(cmd)
                assert_equal 'virt-customize', args.first, name
                assert_adds_raw_disk(args, name)
            end
            assert_includes Shellwords.split(commands[:virtio]), '/srv/virtio win.iso'
            assert_includes Shellwords.split(commands[:qemu_ga]), "#{msi}:/Temp"
            assert_includes Shellwords.split(commands[:tools_linux]), script
            assert_includes Shellwords.split(commands[:tools_windows]), "#{File.realpath(script)}:/Temp"
        end
    end

    def test_context_injection_quotes_the_disk_and_the_package
        h = raw_disk_helper
        package = '/srv/one context/one-context.pkg'
        h.define_singleton_method(:detect_context_package) {|_family| package }

        ['rhel9', 'win10', 'alt10', 'freebsd13', 'opensuse15.5'].each do |os|
            osinfo = { 'name' => os.start_with?('win') ? 'windows' : 'linux', 'os' => os }
            cmd, = h.send(:context_command, DISK, osinfo)
            args = Shellwords.split(cmd)

            assert_adds_raw_disk(args, os)
            assert args.any? {|arg| arg.start_with?("#{package}:/") }, os
        end
    end

    def test_guestfish_and_registry_commands_name_the_format_and_quote_the_path
        h = raw_disk_helper
        commands = []
        Open3.stub(:capture3, ->(_env, cmd) { commands << cmd; ["\"Current\"=dword:00000001\n", '', ok] }) do
            h.send(:guest_root_free_mb, DISK, { 'mounts' => { '/' => '/dev/sda1' } })
            h.send(:guest_run_cmd, DISK, 'sync')
            h.send(:windows_control_sets_for_disk, DISK)
            h.send(:disable_vmtools_via_virt_win_reg, DISK)
        end

        assert_equal ['guestfish', '--ro', '--format=raw', '-a', DISK], Shellwords.split(commands[0]).first(5)
        assert_equal ['guestfish', '--format=raw', '-a', DISK, '-i', 'sync'], Shellwords.split(commands[1])
        assert_equal ['virt-win-reg', '--format=raw', DISK, 'HKLM\\SYSTEM\\Select'], Shellwords.split(commands[2])
        merge = commands.find {|cmd| cmd.include?('--merge') }
        assert_equal ['virt-win-reg', '--merge', '--format=raw', DISK], Shellwords.split(merge).first(4)
    end

    def test_windows_control_set_lookup_names_the_format_and_quotes_the_path
        h = raw_disk_helper
        cmd = nil
        status = ok
        h.define_singleton_method(:run_cmd_report) {|command, *| cmd = command; ["\"Current\"=dword:00000001\n", status] }
        capture_io { assert_equal 1, h.send(:get_win_controlset, DISK) }

        assert_equal ['virt-win-reg', '--format=raw', DISK, 'HKLM\\SYSTEM\\Select'], Shellwords.split(cmd)
    end

    def test_guestfish_scripts_quote_the_disk_and_name_its_format
        h = raw_disk_helper
        script = nil
        reader = lambda do |_env, cmd|
            script = File.read(Shellwords.split(cmd).last) if cmd.start_with?('guestfish -f')
            ["\"Current\"=dword:00000001\n", '', ok]
        end
        Open3.stub(:capture3, reader) { h.send(:disable_vmtools_via_guestfish, DISK) }

        assert_equal %(add "#{DISK}" format:raw), script.lines.first.chomp
        assert_equal '"a \\"b\\" \\\\c"', h.send(:guestfish_quote, 'a "b" \\c')
    end

    def test_windows_context_upload_does_not_let_the_shell_expand_paths
        Dir.mktmpdir('oneswap $HOME `id` ') do |work|
            disk = File.join(work, 'disk0.raw')
            h = helper(:work_dir => work, :virt_tools => '/srv/virt tools')
            h.send(:register_disk_format, [disk], 'raw')
            h.define_singleton_method(:detect_context_package) {|_family| '/srv/one context.msi' }
            h.define_singleton_method(:get_win_controlset) {|_disk| 1 }
            commands = []
            status = ok
            h.define_singleton_method(:run_cmd_report) {|cmd, *| commands << cmd; ['', status] }
            capture_io { h.send(:win_context_inject, disk, { 'mounts' => { '/' => '/dev/sda2' } }) }

            # The shell passes the script to guestfish unchanged.
            script = `#{commands.first.sub(/\Aguestfish/, 'cat')}`
            assert_includes script.lines.map(&:chomp), %(add #{h.send(:guestfish_quote, disk)} format:raw)
            assert_includes script, %(upload "/srv/virt tools/rhsrvany.exe" /rhsrvany.exe)
            assert_includes script, %(upload "/srv/one context.msi" /one-context.msi)
            assert_equal ['virt-win-reg', '--merge', '--format=raw', disk, File.join(work, 'service.reg')],
                         Shellwords.split(commands.last)
        end
    end

    # --- virt-v2v and qemu-img -------------------------------------------------

    def vcenter_helper
        h = helper(:v2v_path => '/usr/bin/virt-v2v', :ova => '/srv/ova files/web.ova', :root => 'first',
                   :vddk_path => '/opt/vddk lib', :vddk_thumb => 'AA:BB', :esxi_user => 'root',
                   :esxi_ip => '10.0.0.1')
        h.instance_variable_set(:@props, {
            'name' => VM,
            'config' => { :files => { :vmPathName => "[ds 1] #{VM}/#{VM}.vmx" },
                          :datastoreUrl => [{ :name => 'ds 1', :url => '/vmfs/volumes/uuid-1' }] }
        })
        h.define_singleton_method(:vcenter_vpx_url) { 'vpx://administrator%40vsphere.local@vc/DC/host?no_verify=1' }
        h
    end

    def test_virt_v2v_commands_quote_paths_and_the_vm_name
        h = vcenter_helper
        output = ['-os', "#{WORK}/conversions/"]
        {
            :build_v2v_vc_cmd => [output, ['-ip', "#{WORK}/vpassfile"], [VM]],
            :build_v2v_vddk_cmd => [output, ['-ip', "#{WORK}/vpassfile"], ['-io', 'vddk-libdir=/opt/vddk lib'], [VM]],
            :build_v2v_esx_cmd => [output, ['-ip', "#{WORK}/esxpassfile"]],
            :build_v2v_ova => [output, ['-i', 'ova', '/srv/ova files/web.ova']]
        }.each do |builder, parts|
            args = Shellwords.split(h.send(builder))
            parts.each {|part| assert_includes args.each_cons(part.length).to_a, part, builder }
        end
        assert_includes Shellwords.split(h.send(:build_v2v_hybrid_cmd, "#{WORK}/local.xml")), "#{WORK}/local.xml"
    end

    def test_esxi_transfer_url_encodes_the_vmx_path
        args = Shellwords.split(vcenter_helper.send(:build_v2v_esx_cmd))

        assert_includes args, 'ssh://root@10.0.0.1//vmfs/volumes/uuid-1/Bob%27s%20VM/Bob%27s%20VM.vmx'
    end

    def test_hybrid_domain_xml_escapes_values_and_names_the_raw_format
        disk = "#{WORK}/transfers/#{VM}-disk0.vmdk"
        doc = REXML::Document.new(helper.send(:build_hybrid_xml, [disk]))

        assert_equal VM, doc.elements['domain/name'].text
        assert_equal disk, doc.elements['domain/devices/disk/source'].attributes['file']
        # The downloads hold the raw data of the VMware disks.
        assert_equal 'raw', doc.elements['domain/devices/disk/driver'].attributes['type']
    end

    def test_custom_conversion_converts_raw_downloads_without_probing
        Dir.mktmpdir('oneswap [custom] ') do |work|
            FileUtils.mkdir_p(File.join(work, 'transfers'))
            vmdk = File.join(work, 'transfers', "#{VM}-disk0.vmdk")
            File.write(vmdk, 'raw data')
            h = helper(:work_dir => work, :hybrid => true)
            commands = []
            h.define_singleton_method(:system) {|cmd| commands << cmd; true }
            imported = nil
            h.define_singleton_method(:create_one_images) {|disks, format| imported = [disks, format]; [] }
            capture_io { h.send(:run_custom_conversion) }

            base = vmdk.delete_suffix('.vmdk')
            assert_equal [['qemu-img', 'convert', '-f', 'raw', '-O', 'qcow2', '-p', '-S', '4k', '-W', vmdk,
                           "#{base}.qcow2"]], commands.map {|cmd| Shellwords.split(cmd) }
            refute_path_exists vmdk
            assert_equal [["#{base}.qcow2"], 'qcow2'], imported
        end
    end

    def test_vmdk_import_quotes_paths_and_imports_qcow2
        Dir.mktmpdir('oneswap import ') do |work|
            vmdk = File.join(work, "#{VM}.vmdk")
            File.write(vmdk, '')
            h = helper(:work_dir => work, :vmdk => vmdk)
            cmd = nil
            h.define_singleton_method(:system) {|command| cmd = command; true }
            imported = nil
            h.define_singleton_method(:create_one_images) {|disks, format| imported = [disks, format]; [{ :id => 1 }] }
            capture_io { h.send(:import_image) }

            output = File.join(work, 'conversions', "#{VM}.qcow2")
            assert_equal ['qemu-img', 'convert', '-O', 'qcow2', '-p', '-S', '4k', '-W', vmdk, output],
                         Shellwords.split(cmd)
            assert_equal [[output], 'qcow2'], imported
        end
    end

    def test_virt_v2v_outputs_of_names_with_glob_characters_are_imported
        Dir.mktmpdir('oneswap ') do |root|
            name = 'web[1]'
            work = File.join(root, name)
            FileUtils.mkdir_p(File.join(work, 'conversions'))
            output = File.join(work, 'conversions', "#{name}-sda")
            File.write(output, '')
            File.write(File.join(work, 'conversions', "#{name}.xml"), '')
            h = helper(:name => name, :work_dir => work, :format => 'raw')
            h.instance_variable_set(:@props, { 'config' => { :guestFullName => 'Linux' } })
            h.define_singleton_method(:build_v2v_vc_cmd) { 'virt-v2v' }
            h.define_singleton_method(:warn_unreadable_kernel_for_libguestfs) {|_env| }
            imported = nil
            h.define_singleton_method(:create_one_images) {|disks, format| imported = [disks, format]; [] }
            streams = [StringIO.new, StringIO.new, StringIO.new, OpenStruct.new(:value => 0)]
            Open3.stub(:popen3, streams) { capture_io { h.send(:run_v2v_conversion) } }

            assert_equal [[output], 'raw'], imported
        end
    end

    # --- image creation --------------------------------------------------------

    def import_helper(dir)
        helper(:work_dir => dir).tap do |h|
            h.define_singleton_method(:chown_one_object) {|*| }
            h.define_singleton_method(:resolve_one_ownership) { [-1, -1] }
            h.define_singleton_method(:persist_opennebula_import_metrics) {|_metrics| }
            h.define_singleton_method(:opennebula_import_mode) { 'local-path' }
        end
    end

    def test_ova_import_finds_the_domain_xml_below_a_name_with_glob_characters
        Dir.mktmpdir('oneswap ') do |dir|
            conversions = File.join(dir, 'web[1] {a,b}', 'conversions')
            FileUtils.mkdir_p(conversions)
            xml = File.join(conversions, 'web[1] {a,b}.xml')
            File.write(xml, '<domain/>')
            File.write(File.join(conversions, 'web[1] {a,b}-sda'), '')

            assert_equal xml, helper(:work_dir => File.dirname(conversions)).send(:conversion_domain_xml)
        end
    end

    def test_image_creation_names_the_disk_format_for_the_guest_tools
        Dir.mktmpdir('oneswap import ') do |dir|
            disks = ['disk0.raw', 'disk 1.raw'].map {|name| File.join(dir, name) }
            disks.each {|disk| File.write(disk, '') }
            OpenNebula::Image.reset
            h = import_helper(dir)
            seen = []
            h.define_singleton_method(:detect_distro) {|disk| seen << guestfs_disk(disk); nil }
            capture_io { h.send(:create_one_images, disks, 'raw') }

            assert_equal disks.map {|disk| "--format=raw -a #{Shellwords.escape(disk)}" }, seen
        end
    end

    def import_disks(dir, count)
        Array.new(count) {|index| File.join(dir, "disk#{index}.raw") }.each {|disk| File.write(disk, '') }
    end

    def test_import_waits_until_opennebula_has_copied_each_disk
        Dir.mktmpdir('oneswap import ') do |dir|
            OpenNebula::Image.reset
            OpenNebula::Image.states["#{VM}_0"] = ['LOCKED', 'LOCKED', 'READY']
            h = import_helper(dir)
            h.define_singleton_method(:detect_distro) {|_disk| nil }
            polls = []
            h.define_singleton_method(:sleep) {|seconds| polls << seconds }
            ids = nil
            capture_io { ids = h.send(:create_one_images, import_disks(dir, 1), 'raw') }

            assert_equal [101], ids.map {|image| image[:id] }
            assert_empty OpenNebula::Image.states["#{VM}_0"]
            assert_equal 2, polls.length
        end
    end

    def test_import_fails_when_opennebula_cannot_copy_a_disk
        Dir.mktmpdir('oneswap import ') do |dir|
            OpenNebula::Image.reset
            OpenNebula::Image.states["#{VM}_1"] = ['LOCKED', 'ERROR']
            h = import_helper(dir)
            h.define_singleton_method(:detect_distro) {|_disk| nil }
            h.define_singleton_method(:sleep) {|_seconds| }
            error = nil
            capture_io { error = assert_raises(ImageImportError) { h.send(:create_one_images, import_disks(dir, 2), 'raw') } }

            assert_includes error.message, 'Error copying the image'
            assert_equal [101, 102], OpenNebula::Image.deleted
        end
    end

    def test_an_image_still_copied_is_deleted_once_its_copy_ends
        Dir.mktmpdir('oneswap import ') do |dir|
            OpenNebula::Image.reset
            OpenNebula::Image.states["#{VM}_0"] = ['LOCKED', 'LOCKED']
            h = import_helper(dir)
            h.define_singleton_method(:detect_distro) {|_disk| nil }
            h.define_singleton_method(:sleep) {|_seconds| }
            # The import stops right after the allocation, during the copy.
            h.define_singleton_method(:chown_one_object) {|*| raise 'quota exceeded' }
            capture_io { assert_raises(RuntimeError) { h.send(:create_one_images, import_disks(dir, 1), 'raw') } }

            assert_equal [101], OpenNebula::Image.deleted
        end
    end

    def test_an_image_still_copied_after_img_wait_is_kept
        Dir.mktmpdir('oneswap import ') do |dir|
            OpenNebula::Image.reset
            OpenNebula::Image.states["#{VM}_0"] = ['LOCKED'] * 100_000
            h = import_helper(dir).tap {|helper| helper.instance_variable_get(:@options)[:img_wait] = 0.2 }
            h.define_singleton_method(:detect_distro) {|_disk| nil }
            ids = nil
            capture_io { ids = h.send(:create_one_images, import_disks(dir, 1), 'raw') }

            assert_equal [101], ids.map {|image| image[:id] }
            assert_empty OpenNebula::Image.deleted
        end
    end

    # As OCA wait_state did with ZMQ, the default waits for the whole copy.
    def test_imports_wait_for_the_whole_copy_unless_img_wait_limits_it
        assert_nil helper.send(:image_wait_timeout)
        assert_nil helper(:delta => true).send(:image_wait_timeout)
        assert_equal 30, helper(:delta => true, :img_wait => 30).send(:image_wait_timeout)
    end

    def test_import_survives_a_few_failed_image_reads
        Dir.mktmpdir('oneswap import ') do |dir|
            OpenNebula::Image.reset
            OpenNebula::Image.states["#{VM}_0"] = ['LOCKED', :error, :error, 'LOCKED', 'READY']
            h = import_helper(dir)
            h.define_singleton_method(:detect_distro) {|_disk| nil }
            h.define_singleton_method(:sleep) {|_seconds| }
            ids = nil
            capture_io { ids = h.send(:create_one_images, import_disks(dir, 1), 'raw') }

            assert_equal [101], ids.map {|image| image[:id] }
            assert_empty OpenNebula::Image.deleted
        end
    end

    def test_import_stops_when_the_image_cannot_be_read
        Dir.mktmpdir('oneswap import ') do |dir|
            OpenNebula::Image.reset
            OpenNebula::Image.states["#{VM}_0"] = [:error] * 1000
            h = import_helper(dir)
            h.define_singleton_method(:detect_distro) {|_disk| nil }
            h.define_singleton_method(:sleep) {|_seconds| }
            error = nil
            capture_io { error = assert_raises(ImageImportError) { h.send(:create_one_images, import_disks(dir, 1), 'raw') } }

            assert_includes error.message, 'oned is not responding'
        end
    end

    # The conversion is fine: a fallback conversion would fail the same way.
    def test_import_failures_are_not_conversion_failures
        Dir.mktmpdir('oneswap import ') do |dir|
            OpenNebula::Image.reset
            OpenNebula::Image.states["#{VM}_0"] = ['ERROR']
            h = import_helper(dir)
            h.define_singleton_method(:detect_distro) {|_disk| nil }
            capture_io { assert_raises(ImageImportError) { h.send(:create_one_images, import_disks(dir, 1), 'raw') } }

            OpenNebula::Image.reset("#{VM}_0")
            capture_io { assert_raises(ImageImportError) { h.send(:create_one_images, import_disks(dir, 1), 'raw') } }
        end
    end

    def test_an_interrupted_import_leaves_the_images_still_copied
        Dir.mktmpdir('oneswap import ') do |dir|
            OpenNebula::Image.reset
            OpenNebula::Image.states["#{VM}_0"] = ['LOCKED'] * 1000
            h = import_helper(dir)
            h.define_singleton_method(:detect_distro) {|_disk| nil }
            h.define_singleton_method(:sleep) {|_seconds| raise Interrupt }
            output, = capture_io { assert_raises(Interrupt) { h.send(:create_one_images, import_disks(dir, 1), 'raw') } }

            # No wait for the copy: the image is named for a later deletion.
            assert_empty OpenNebula::Image.deleted
            assert_includes output, 'oneimage delete 101'
        end
    end

    def test_a_failure_after_the_import_keeps_the_images
        Dir.mktmpdir('oneswap import ') do |dir|
            OpenNebula::Image.reset
            h = import_helper(dir)
            h.define_singleton_method(:detect_distro) {|_disk| nil }
            h.define_singleton_method(:persist_opennebula_import_metrics) {|_metrics| raise 'metrics file is not a Hash' }
            capture_io { assert_raises(RuntimeError) { h.send(:create_one_images, import_disks(dir, 2), 'raw') } }

            assert_empty OpenNebula::Image.deleted
        end
    end

    def test_import_metrics_skip_the_images_still_copied
        Dir.mktmpdir('oneswap import ') do |dir|
            OpenNebula::Image.reset
            OpenNebula::Image.states["#{VM}_0"] = ['LOCKED'] * 1000
            h = import_helper(dir).tap {|helper| helper.instance_variable_get(:@options)[:img_wait] = 0 }
            h.define_singleton_method(:detect_distro) {|_disk| nil }
            metrics = nil
            h.define_singleton_method(:persist_opennebula_import_metrics) {|import_metrics| metrics = import_metrics }
            capture_io { h.send(:create_one_images, import_disks(dir, 1), 'raw') }

            refute metrics.first.key?('opennebula_import_mib_s')
        end
    end

    def test_a_failed_http_import_stops_its_server
        Dir.mktmpdir('oneswap import ') do |dir|
            OpenNebula::Image.reset
            OpenNebula::Image.states["#{VM}_0"] = ['ERROR']
            h = import_helper(dir).tap do |helper|
                helper.instance_variable_get(:@options).merge!(:http_transfer => true, :http_host => 'one.example',
                                                               :http_port => 8080)
            end
            h.define_singleton_method(:detect_distro) {|_disk| nil }
            server = Thread.new { sleep }
            h.define_singleton_method(:start_http_transfer_server) {|_root| server }
            capture_io { assert_raises(ImageImportError) { h.send(:create_one_images, import_disks(dir, 1), 'raw') } }

            # A batch reuses the port for the next VM.
            refute server.alive?
        end
    end

    def test_vcenter_lookup_encodes_the_vm_name
        client = VSphereClient.allocate
        client.instance_variable_set(:@vcenter, 'vc.example')
        client.instance_variable_set(:@logger, Logger.new(File::NULL))
        uris = []
        response = OpenStruct.new(:body => '{"value":[{"vm":"vm-42"}]}')
        client.define_singleton_method(:https_request) {|uri| uris << uri; response }

        assert_equal({ 'vm' => 'vm-42' }, client.get_vm("Bob's VM #1 & a+b 100%"))
        assert_equal 'filter.names=Bob%27s%20VM%20%231%20%26%20a%2Bb%20100%25', uris.first.query
    end

    def test_a_vm_the_vcenter_api_does_not_find_gets_no_tags
        h = helper
        vsphere = Object.new
        vsphere.define_singleton_method(:get_vm) {|_name| nil }
        h.define_singleton_method(:new_vsphere_client) { @vsphere_client = vsphere }
        tags = nil
        output, = capture_io { tags = h.send(:vcenter_vm_tags) }

        assert_equal [], tags
        assert_includes output, 'tags'
    end

    # --- names OpenNebula or the guest tools cannot take ---------------------

    def test_local_path_import_refuses_an_apostrophe_up_front
        # OpenNebula's datastore driver single-quotes the source path.
        error = assert_raises(RuntimeError) { helper.send(:ensure_importable_local_path!) }
        assert_includes error.message, 'http_transfer'

        assert_nil helper(:http_transfer => true).send(:ensure_importable_local_path!)
        assert_nil helper(:work_dir => '/var/tmp/work dir/Web $erver [1]').send(:ensure_importable_local_path!)
    end

    def test_shift_imports_are_checked_on_the_mount
        error = assert_raises(RuntimeError) do
            helper(:shift => true, :shift_mount => '/mnt/shift', :work_dir => '/var/tmp/w/web').send(
                :ensure_importable_local_path!, "web's"
            )
        end
        assert_includes error.message, "/mnt/shift/web's"

        assert_nil helper(:shift => true, :shift_mount => '/mnt/shift', :work_dir => "/var/tmp/bob's/web")
            .send(:ensure_importable_local_path!, 'web')
    end

    def test_shift_vms_are_checked_before_the_blueprint_runs
        options = { :shift => true, :shift_mount => '/mnt/shift', :work_dir => '/var/tmp/w' }
        error = assert_raises(RuntimeError) { helper.ensure_importable_shift_vms!(['web', "Bob's VM"], options) }
        assert_includes error.message, "/mnt/shift/Bob's VM"

        assert_nil helper.ensure_importable_shift_vms!(["Bob's VM"], options.merge(:http_transfer => true))
    end

    def test_disk_import_refuses_an_apostrophe_before_converting
        Dir.mktmpdir('oneswap ') do |dir|
            h = helper
            h.define_singleton_method(:apply_verbosity) {|_options| }
            h.define_singleton_method(:check_one_connectivity) { true }
            converted = false
            h.define_singleton_method(:import_image) { converted = true }
            error = nil
            capture_io do
                error = assert_raises(RuntimeError) { h.import({ :vmdk => "/srv/#{VM}.vmdk", :work_dir => dir.dup }) }
            end

            refute converted
            assert_includes error.message, 'apostrophe'
            # import has no HTTP transfer.
            assert_includes error.message, 'Rename the file'
            refute_includes error.message, 'http_transfer'
            refute_path_exists File.join(dir, VM)
        end
    end

    def test_http_transfer_urls_are_percent_encoded
        h = helper(:http_transfer => true, :http_host => 'one.example', :http_port => 8080)

        {
            "#{WORK}/conversions/#{VM}-sda" => 'http://one.example:8080/Bob%27s%20VM-sda',
            '/w/web[1]-sda' => 'http://one.example:8080/web%5B1%5D-sda',
            '/w/web#1-sda' => 'http://one.example:8080/web%231-sda',
            '/w/web01-sda' => 'http://one.example:8080/web01-sda'
        }.each {|disk, url| assert_equal url, h.send(:http_image_url, disk) }
    end

    def test_import_benchmark_encodes_its_url_and_stops_when_the_copy_fails
        Dir.mktmpdir('oneswap ') do |dir|
            OpenNebula::Image.reset
            OpenNebula::Image.states = Hash.new {|states, name| states[name] = ['LOCKED', 'ERROR'] }
            h = helper(:work_dir => dir, :http_transfer => true, :http_host => 'one.example', :http_port => 8080,
                       :dry_run_import_benchmark_size_mib => 1)
            h.define_singleton_method(:start_http_transfer_server) {|_root| nil }
            h.define_singleton_method(:write_benchmark_file) {|path, _bytes| File.write(path, '') }
            h.define_singleton_method(:sleep) {|_seconds| }
            output, = capture_io { h.send(:run_opennebula_import_benchmark) }

            assert_equal ['http://one.example:8080/Bob%27s%20VM-import-benchmark.raw'], OpenNebula::Image.paths
            assert_includes output, 'Error copying the image'
            assert_equal [101], OpenNebula::Image.deleted
        end
    end

    def test_import_benchmark_does_not_delete_an_image_still_copied
        Dir.mktmpdir('oneswap ') do |dir|
            OpenNebula::Image.reset
            OpenNebula::Image.states = Hash.new {|states, name| states[name] = ['LOCKED'] * 1000 }
            h = helper(:work_dir => dir, :http_transfer => true, :http_host => 'one.example', :http_port => 8080,
                       :dry_run_import_benchmark_size_mib => 1, :img_wait => 0)
            h.define_singleton_method(:start_http_transfer_server) {|_root| nil }
            h.define_singleton_method(:write_benchmark_file) {|path, _bytes| File.write(path, '') }
            output, = capture_io { h.send(:run_opennebula_import_benchmark) }

            assert_empty OpenNebula::Image.deleted
            assert_includes output, 'oneimage delete 101'
        end
    end

    # virt-customize --copy-in splits its argument at the first colon, and
    # the work dir holds the VM name.
    def test_dns_injection_writes_resolv_conf_outside_the_vm_named_work_dir
        Dir.mktmpdir('oneswap ') do |root|
            h = helper(:work_dir => File.join(root, 'db:01'), :inject_dns => '10.0.0.53')
            resolv = nil
            capture_io { resolv = h.send(:inject_dns_resolv_conf) }

            refute_includes resolv, ':'
            assert_equal "nameserver 10.0.0.53\n", File.read(resolv)
            capture_io { h.send(:cleanup_all) }
            refute_path_exists resolv
        end
    end

    def test_qemu_ga_msi_from_the_iso_is_copied_outside_the_vm_named_work_dir
        Dir.mktmpdir('oneswap ') do |root|
            iso = File.join(root, 'virtio-win.iso')
            File.write(iso, '')
            h = helper(:work_dir => File.join(root, 'db:01'), :qemu_ga_win => iso)
            h.define_singleton_method(:system) {|_command| true }
            mounts = []
            mount = lambda do |command|
                mounts << Shellwords.split(command).last
                FileUtils.mkdir_p(File.join(mounts.last, 'guest-agent'))
                File.write(File.join(mounts.last, 'guest-agent', 'qemu-ga-x86_64.msi'), 'msi')
                ['', '', ok]
            end
            args = Open3.stub(:capture3, mount) { Shellwords.split(h.send(:qemu_ga_command, DISK)) }
            mounts.each {|mount_dir| FileUtils.rm_rf(mount_dir) }
            staged = args[args.index('--copy-in') + 1].delete_suffix(':/Temp')

            refute_includes staged, ':'
            assert_equal 'msi', File.read(staged)
            capture_io { h.send(:cleanup_all) }
            refute_path_exists staged
        end
    end

    def test_windows_context_first_boot_command_quotes_the_package
        h = raw_disk_helper
        h.define_singleton_method(:detect_context_package) {|_family| '/srv/one context/one context.msi' }
        cmd, = h.send(:context_command, DISK, { 'name' => 'windows', 'os' => 'win10' })
        args = Shellwords.split(cmd)

        assert_equal 'msiexec -i "c:\\Temp\\one context.msi" /quiet && del "c:\\Temp\\one context.msi"',
                     args[args.index('--firstboot-command') + 1]
    end

    def test_failed_import_deletes_the_images_it_created
        Dir.mktmpdir('oneswap import ') do |dir|
            disks = ['disk0.raw', 'disk1.raw'].map {|name| File.join(dir, name) }
            disks.each {|disk| File.write(disk, '') }
            OpenNebula::Image.reset("#{VM}_1")
            h = import_helper(dir)
            h.define_singleton_method(:detect_distro) {|_disk| nil }
            error = nil
            capture_io { error = assert_raises(ImageImportError) { h.send(:create_one_images, disks, 'raw') } }

            # A retry finds no image of this VM in the way.
            assert_includes error.message, 'datastore full'
            assert_equal ["#{VM}_0"], OpenNebula::Image.allocated
            assert_equal [101], OpenNebula::Image.deleted
        end
    end

end
