# Unit-style checks for dry-run estimator and safety helpers.
# Run with: ruby tests/dry_run_safety_test.rb

require 'logger'
require 'openssl'
require 'minitest/autorun'
require 'stringio'
require 'tmpdir'

module OpenNebulaHelper
    class OneHelper
        def self.get_password
            raise 'Unexpected password prompt'
        end
    end
end

module RbVmomi
    module VIM
        class VirtualMachine; end
    end
end

module Kernel
    alias oneswap_test_original_require require

    def require(path)
        return true if ['one_helper', 'opennebula'].include?(path)

        oneswap_test_original_require(path)
    end
end

require_relative '../oneswap_helper'

class DryRunSafetyTest < Minitest::Test
    # vCenter path of the test VM, which also names it on the ESXi host.
    VMX_PATH = '[ds] test-vm/test-vm.vmx'

    def with_vmx_path(h)
        h.instance_variable_set(:@props, { 'config' => { :files => { :vmPathName => VMX_PATH } } })
        h
    end

    def helper(options = {})
        OneSwapHelper.allocate.tap do |h|
            h.instance_variable_set(:@options, {
                :dry_run_target_import_mib_s => 80
            }.merge(options))
            h.instance_variable_set(:@logger, Logger.new(File::NULL))
        end
    end

    def firmware_template(options = {}, firmware = 'bios')
        h = helper({ :uefi_path => '/tmp/OVMF_CODE.fd' }.merge(options))
        h.instance_variable_set(:@props, {
            'config' => {
                :firmware => firmware,
                :bootOptions => {}
            }
        })

        h.send(:template_firmware)['OS']
     end

def delta_vm
        ESXi::VirtualMachine.allocate.tap do |vm|
            vm.instance_variable_set(:@name, 'test-vm')
            vm.instance_variable_set(:@id, 42)
            vm.instance_variable_set(:@clone_dir, '/vmfs/volumes/ds/test-vm/vmkfstools_output')
            vm.instance_variable_set(:@logger, Logger.new(File::NULL))
        end
    end

    def test_http_real_import_metrics_are_ignored_when_benchmark_exists
        h = helper(:http_transfer => true)
        result = h.send(:target_import_estimate, :metrics => {
            'opennebula_import_mode' => 'http',
            'opennebula_import_seconds' => 1200,
            'opennebula_import_mib_s' => 17,
            'opennebula_import_benchmark_mode' => 'http',
            'opennebula_import_benchmark_mib_s' => 15,
            'opennebula_import_benchmark_bytes' => 4 * 1024 * 1024 * 1024,
            'opennebula_import_benchmark_seconds' => 273
        })

        assert_equal 15, result[:rate]
        assert_equal :large_benchmark, result[:source]
    end

    def test_http_real_import_metrics_fall_back_without_benchmark
        h = helper(:http_transfer => true, :dry_run_target_import_mib_s => 80)
        result = h.send(:target_import_estimate, :metrics => {
            'opennebula_import_mode' => 'http',
            'opennebula_import_seconds' => 1200,
            'opennebula_import_mib_s' => 17
        })

        assert_equal 80, result[:rate]
        assert_equal :configured_fallback, result[:source]
    end

    def test_snapshot_marker_matches_only_oneswap_snapshots
        vm = ESXi::VirtualMachine.allocate

        assert vm.send(:oneswap_snapshot?, {
            :name => 'VM Snapshot 7/1/2026, 1:23:45 PM',
            :description => 'OneSwap ESXi client snapshot'
        })
        assert vm.send(:oneswap_snapshot?, {
            :name => 'OneSwap delta prepare',
            :description => ''
        })
        refute vm.send(:oneswap_snapshot?, {
            :name => 'VM Snapshot 7/1/2026, 1:23:45 PM',
            :description => ''
        })
    end

    def test_delta_prepare_uses_vddk_block_only_when_configured
        calls = []
        vm = Object.new
        vm.define_singleton_method(:live2kvm_prepare) do |work_dir, &block|
            calls << [:prepare, work_dir, !block.nil?]
            block&.call('base.vmdk', '/tmp/work/convert/disk0.raw')
            block&.call('data.vmdk', '/tmp/work/convert/disk1.raw')
        end
        vm.define_singleton_method(:live2kvm_snapshot_name) { 'VM Snapshot test' }
        vm.define_singleton_method(:vddk_path) do |disk, names|
            calls << [:vddk_path, disk, names]
            "[datastore] test-vm/#{disk}"
        end
        h = helper(:work_dir => '/tmp/work', :vddk_path => '/opt/vddk', :skip_prechecks => true)
        h.define_singleton_method(:validate_delta_vddk_prerequisites!) do
            calls << [:vddk_prerequisites]
        end
        names = { 'uuid-1' => 'datastore', 'datastore' => 'datastore' }
        h.define_singleton_method(:vcenter_datastore_names) { names }
        h.define_singleton_method(:vcenter_snapshot_moref) do |snapshot_name|
            calls << [:snapshot_moref, snapshot_name]
            'snapshot-42'
        end
        h.define_singleton_method(:convert_vddk_disk) do |vddk_file, output_path, snapshot_moref|
            calls << [:convert_vddk, vddk_file, output_path, snapshot_moref]
            output_path
        end
        stdout, = capture_io { h.send(:prepare_delta_conversion, vm) }
        assert_includes stdout, 'Using VDDK transport for delta prepare.'
        assert_equal [
            [:vddk_prerequisites],
            [:prepare, '/tmp/work', true],
            [:snapshot_moref, 'VM Snapshot test'],
            [:vddk_path, 'base.vmdk', names],
            [:convert_vddk, '[datastore] test-vm/base.vmdk', '/tmp/work/convert/disk0.raw', 'snapshot-42'],
            [:vddk_path, 'data.vmdk', names],
            [:convert_vddk, '[datastore] test-vm/data.vmdk', '/tmp/work/convert/disk1.raw', 'snapshot-42']
        ], calls
        calls.clear
        helper(:work_dir => '/tmp/work').send(:prepare_delta_conversion, vm)
        assert_equal [[:prepare, '/tmp/work', false]], calls
    end

    def test_delta_vddk_prerequisite_validation
        status_class = Struct.new(:ok) do
            def success?
                ok
            end
        end
        cases = [
            ['missing nbdkit', false, true, '', '', true, /nbdkit is required/],
            ['invalid VDDK path', true, false, '', '', true, /not a directory/],
            ['failed dump-plugin', true, true, '', 'plugin failed', false, /plugin failed/],
            ['marker-less dump-plugin', true, true, "name=vddk\n", '', true, /could not load VDDK/],
            ['library version marker', true, true, "vddk_library_version=8\n", '', true, nil]
        ]

        cases.each do |name, nbdkit, directory, stdout, stderr, command_ok, error|
            h = helper(:vddk_path => '/opt/vddk')
            argv = nil
            capture = lambda do |*args|
                argv = args
                [stdout, stderr, status_class.new(command_ok)]
            end

            ESXi::Client.stub(:command_exists?, nbdkit) do
                File.stub(:directory?, directory) do
                    Open3.stub(:capture3, capture) do
                        if error
                            exception = assert_raises(RuntimeError, name) do
                                h.send(:validate_delta_vddk_prerequisites!)
                            end
                            assert_match error, exception.message, name
                        else
                            assert_nil h.send(:validate_delta_vddk_prerequisites!), name
                        end
                    end
                end
            end

            next unless nbdkit && directory

            assert_equal [
                'nbdkit', 'vddk', '--dump-plugin', 'libdir=/opt/vddk'
            ], argv, name
        end
    end

    # vCenter learns about a snapshot taken on the ESXi host only after its
    # next sync with the host, which took 5-10 s in the lab.
    def snapshot_lookup(polls_before_visible)
        ref = Struct.new(:_ref)
        node = Struct.new(:name, :snapshot, :childSnapshotList)
        expected = node.new('VM Snapshot test', ref.new('snapshot-42'), [])
        root = node.new('older snapshot', ref.new('snapshot-1'), [expected])
        snapshot_info = Struct.new(:rootSnapshotList).new([root])
        calls = 0
        vc_vm = Object.new
        vc_vm.define_singleton_method(:collect!) do |_property|
            calls += 1
            { 'snapshot' => calls > polls_before_visible ? snapshot_info : nil }
        end
        h = helper
        h.instance_variable_set(:@vm_obj, vc_vm)
        h.instance_variable_set(:@vm_moref, 'vm-42')
        now = 0.0
        result = nil
        Process.stub(:clock_gettime, ->(_clock) { now }) do
            h.stub(:sleep, ->(seconds) { now += seconds }) do
                result = begin
                    h.send(:vcenter_snapshot_moref, 'VM Snapshot test')
                rescue RuntimeError => e
                    e
                end
            end
        end
        [result, calls, now]
    end

    def test_vcenter_snapshot_moref_retries_and_finds_nested_snapshot
        result, calls, = snapshot_lookup(1)
        assert_equal 'snapshot-42', result
        assert_equal 2, calls
    end

    def test_vcenter_snapshot_moref_waits_long_enough_for_vcenter_sync
        result, calls, waited = snapshot_lookup(8)
        assert_equal 'snapshot-42', result
        assert_equal 9, calls
        assert_operator waited, :>, 10
    end

    def test_vcenter_snapshot_moref_gives_up_after_the_timeout
        result, _calls, waited = snapshot_lookup(Float::INFINITY)
        assert_kind_of RuntimeError, result
        assert_includes result.message, "Unable to find snapshot 'VM Snapshot test' for VM vm-42 in vCenter"
        assert_operator waited, :>=, OneSwapHelper::VCENTER_SNAPSHOT_LOOKUP_TIMEOUT
    end

    def test_convert_vddk_disk_adds_snapshot_only_when_provided
        commands = []
        h = helper(
            :vddk_path => '/opt/vddk',
            :vcenter => 'vcenter.example',
            :vuser => 'user',
            :vpass => 'plaintext-password',
            :work_dir => '/tmp/work'
        )
        h.instance_variable_set(:@vm_moref, 'vm-42')
        h.define_singleton_method(:vddk_thumbprint) { 'AA:BB' }
        h.define_singleton_method(:system) {|cmd| commands << cmd; true }

        stdout, = capture_io do
            h.send(:convert_vddk_disk, '[ds] base.vmdk', '/tmp/base.raw')
            h.send(:convert_vddk_disk, '[ds] base.vmdk', '/tmp/base.raw', 'snapshot-42')
        end

        refute_includes commands[0], ' snapshot='
        assert_includes commands[1], ' snapshot=snapshot-42'
        assert_includes stdout, 'Running: nbdkit'
        assert_includes stdout, 'password=+/tmp/work/vpassfile'
        refute_includes stdout, 'plaintext-password'
    end

    def test_convert_vddk_disk_quotes_output_path_for_both_shells
        output_path = %q{/tmp/work dir/owner's "disk"; $HOME $(false).raw}
        h = helper(:vddk_path => '/opt/vddk', :vcenter => 'vcenter.invalid',
                   :vuser => 'user', :work_dir => '/tmp/work dir')
        h.instance_variable_set(:@vm_moref, 'vm-42')
        h.define_singleton_method(:vddk_thumbprint) { 'AA:BB' }
        command = nil
        h.define_singleton_method(:system) {|cmd| command = cmd; true }

        capture_io do
            assert_equal output_path, h.send(:convert_vddk_disk, '[ds] base.vmdk', output_path, 'snapshot-42')
        end

        # Decode the outer shell argument, then the command nbdkit runs.
        # No shell, nbdkit or qemu-img process is started.
        args = Shellwords.split(command)
        assert_equal ['nbdkit', '-r', '-U'], args[0, 3]
        assert_match %r{\A#{Regexp.escape(Dir.tmpdir)}/nbd[^/]+/s\z}, args[3]
        refute_path_exists File.dirname(args[3])
        assert_equal ['vddk', 'libdir=/opt/vddk',
                      'server=vcenter.invalid', 'port=443', 'user=user', 'password=+/tmp/work dir/vpassfile',
                      'thumbprint=AA:BB', 'vm=moref=vm-42', 'snapshot=snapshot-42',
                      'file=[ds] base.vmdk', '--run'], args[4...-1]
        assert_includes args.last, '"$uri"'
        assert_equal ['qemu-img', 'convert', '-f', 'raw', '-O', 'raw', '-p', '-S', '4k', '-W',
                      '$uri', output_path], Shellwords.split(args.last)
    end

    def test_nbdkit_socket_fits_a_unix_socket_path_with_a_long_tmpdir
        h = helper(:vddk_path => '/opt/vddk', :vcenter => 'vcenter.invalid', :vuser => 'user', :work_dir => '/tmp/w')
        h.instance_variable_set(:@vm_moref, 'vm-42')
        h.define_singleton_method(:vddk_thumbprint) { 'AA:BB' }
        command = nil
        h.define_singleton_method(:system) {|cmd| command = cmd; true }
        Dir.mktmpdir('oneswap-a-rather-long-temporary-directory-name-for-the-vddk-base-copies-') do |tmpdir|
            Dir.stub(:tmpdir, tmpdir) do
                capture_io { h.send(:convert_vddk_disk, '[ds] base.vmdk', '/tmp/base.raw') }
            end
        end

        socket = Shellwords.split(command)[3]
        # sun_path holds 107 bytes.
        assert_operator socket.bytesize, :<=, 107
        assert_match %r{\A/tmp/nbd[^/]+/s\z}, socket
    end

    def test_vddk_uses_configured_or_default_port_for_thumbprint_and_nbdkit
        [nil, '8443'].each do |port|
            h = helper(:vcenter => 'vcenter.invalid', :port => port,
                       :vddk_path => '/opt/vddk', :vuser => 'user', :work_dir => '/tmp/work')
            h.instance_variable_set(:@vm_moref, 'vm-42')
            tcp = Minitest::Mock.new
            tcp.expect(:close, nil)
            ssl = Minitest::Mock.new
            ssl.expect(:connect, nil)
            ssl.expect(:puts, nil, ["GET / HTTP/1.0\r\n\r\n"])
            ssl.expect(:read, '')
            ssl.expect(:sysclose, nil)
            ssl.expect(:peer_cert, Struct.new(:to_der).new('test certificate'))
            commands = []
            h.define_singleton_method(:system) {|cmd| commands << cmd; true }
            socket_factory = lambda do |host, actual_port|
                assert_equal 'vcenter.invalid', host
                assert_equal port || 443, actual_port
                tcp
            end
            TCPSocket.stub(:new, socket_factory) do
                OpenSSL::SSL::SSLSocket.stub(:new, ssl) do
                    capture_io do
                        h.send(:convert_vddk_disk, '[ds] base.vmdk', '/tmp/disk.raw', 'snapshot-42')
                    end
                end
            end
            args = Shellwords.split(commands.fetch(0))
            assert_includes args, "port=#{port || 443}"
            assert_includes args, 'snapshot=snapshot-42'
            assert_includes args, 'password=+/tmp/work/vpassfile'
            tcp.verify
            ssl.verify
        end
    end

    def test_convert_writes_prompted_or_supplied_password_before_vddk_conversion
        [nil, 'supplied password'].each do |supplied|
            Dir.mktmpdir('oneswap-password-test-') do |dir|
                options = { :work_dir => dir.dup, :vcenter => 'vcenter.invalid',
                            :vuser => 'user', :vpass => supplied, :vddk_path => '/opt/vddk' }
                h = helper
                h.define_singleton_method(:apply_verbosity) {|_| }
                h.define_singleton_method(:check_one_connectivity) { true }
                h.define_singleton_method(:cleanup_all) { cleanup_passwords }
                h.define_singleton_method(:vddk_thumbprint) { 'AA:BB' }
                h.instance_variable_set(:@vm_moref, 'vm-42')
                observations = []
                h.define_singleton_method(:convert_vm) do
                    # This connection normally occurs after the password file is written.
                    observations << connection_options('vm', @options)[:password]
                    convert_vddk_disk('[ds] base.vmdk', File.join(@options[:work_dir], 'disk.raw'))
                end
                h.define_singleton_method(:system) do |cmd|
                    password_arg = Shellwords.split(cmd).find {|arg| arg.start_with?('password=+') }
                    path = password_arg.delete_prefix('password=+')
                    observations << File.read(path)
                    observations << (File.stat(path).mode & 0o777)
                    true
                end
                prompts = 0
                prompt = lambda { prompts += 1; "prompted 'password'" }
                output = nil
                OpenNebulaHelper::OneHelper.stub(:get_password, prompt) do
                    output, = capture_io { h.convert('test-vm', options) }
                end
                expected = supplied || "prompted 'password'"
                assert_equal [expected, expected, 0o600], observations
                assert_equal expected, options[:vpass]
                assert_equal supplied ? 0 : 1, prompts
                refute_includes output, expected
                refute_path_exists File.join(dir, 'test-vm/vpassfile')
            end
        end
    end

    def test_delta_prepare_with_zero_disks_cleans_snapshot_and_leaves_no_state
        Dir.mktmpdir do |dir|
            calls = []
            vm = delta_vm
            vm.define_singleton_method(:live_storage_transfer_precheck) { true }
            vm.define_singleton_method(:create_snapshot) do |name, *|
                @created_snapshot_name = name
                true
            end
            vm.define_singleton_method(:refresh_vmx) { true }
            vm.define_singleton_method(:active_disks) { [] }
            vm.define_singleton_method(:cleanup_snapshot) {|state| calls << [:snapshot, state['snapshot_name']] }

            result = nil
            output, = capture_io { result = vm.live2kvm_prepare(dir) { raise 'no disks should be converted' } }

            assert_equal false, result
            assert_equal vm.instance_variable_get(:@created_snapshot_name), vm.live2kvm_snapshot_name
            assert_equal [[:snapshot, vm.live2kvm_snapshot_name]], calls
            assert_includes output, 'no active disks detected for delta migration'
            assert_empty Dir.children(dir)
        end
    end

    def test_delta_prepare_logs_vddk_exception_details
        Dir.mktmpdir do |dir|
            log = StringIO.new
            vm = delta_vm
            vm.instance_variable_set(:@logger, Logger.new(log, :level => Logger::DEBUG))
            vm.define_singleton_method(:live_storage_transfer_precheck) { true }
            vm.define_singleton_method(:create_snapshot) do |name, *|
                @created_snapshot_name = name
                true
            end
            vm.define_singleton_method(:refresh_vmx) { true }
            vm.define_singleton_method(:active_disks) { ['disk-000001.vmdk'] }
            vm.define_singleton_method(:vmdk_info) do |_|
                { 'createType' => 'seSparse', 'parentFileNameHint' => 'base.vmdk' }
            end
            vm.define_singleton_method(:cleanup_snapshot) {|state| @removed_snapshot = state['snapshot_name'] }
            vm.define_singleton_method(:live_storage_transfer_cleanup) do |_, reason = nil|
                @cleanup_reason = reason if reason
            end
            error = ArgumentError.new('bad vddk')
            error.set_backtrace(['controlled-vddk-backtrace:1'])

            result = nil
            stdout, = capture_io do
                result = vm.live2kvm_prepare(dir) { raise error }
            end

            assert_equal false, result
            assert_includes stdout, 'ArgumentError: bad vddk'
            assert_includes log.string, 'controlled-vddk-backtrace:1'
            assert_includes stdout, 'Delta prepare aborted: failed disk'
            assert_equal vm.instance_variable_get(:@created_snapshot_name),
                         vm.instance_variable_get(:@removed_snapshot)
        end
    end

    def test_delta_commit_rejects_invalid_state_before_shutdown
        Dir.mktmpdir do |dir|
            full = File.join(dir, 'full')
            empty = File.join(dir, 'empty')
            missing = File.join(dir, 'missing')
            [full, empty].each {|path| Dir.mkdir(path) }
            File.write(File.join(full, 'disk0.raw'), '')
            states = [
                { 'transfer_dir' => dir, 'convert_dir' => full, 'results_dir' => "#{dir}/out", 'disks' => [] },
                { 'transfer_dir' => dir, 'convert_dir' => missing, 'results_dir' => "#{dir}/out", 'disks' => [{}] },
                { 'transfer_dir' => dir, 'convert_dir' => empty, 'results_dir' => "#{dir}/out", 'disks' => [{}] }
            ]
            states.each do |state|
                vm = delta_vm
                shutdown_called = false
                vm.define_singleton_method(:read_live2kvm_state) {|_| state }
                vm.define_singleton_method(:shutdown) { shutdown_called = true }
                assert_equal false, vm.live2kvm_commit('/tmp/work')
                refute shutdown_called
            end
        end
    end

    def test_http_transfer_bypasses_local_path_guard
        h = helper(:http_transfer => true, :endpoint => 'http://remote.example/RPC2')

        assert_nil h.send(:local_path_image_allocation_preflight!)
    end

    def test_non_http_real_import_metrics_are_reused
        h = helper(:http_transfer => false)
        result = h.send(:target_import_estimate,
            :prefer_previous_full => true,
            :metrics => {
                'opennebula_import_mode' => 'local-path',
                'opennebula_import_seconds' => 600,
                'opennebula_import_mib_s' => 42
            })

        assert_equal 42, result[:rate]
        assert_equal :previous_full_import, result[:source]
    end

    def test_remote_local_path_endpoint_is_rejected
        h = helper(:http_transfer => false, :endpoint => 'http://remote.example/RPC2')

        error = assert_raises(RuntimeError) do
            h.send(:local_path_image_allocation_preflight!)
        end
        assert_includes error.message, "OpenNebula endpoint host 'remote.example'"
    end

    def test_allow_local_path_remote_overrides_guard
        h = helper(
            :http_transfer => false,
            :allow_local_path_remote => true,
            :endpoint => 'http://remote.example/RPC2'
        )

        assert_nil h.send(:local_path_image_allocation_preflight!)
    end

    def test_windows_vd_without_virtio_path_warns_and_continues
        h = helper

        out, = capture_io do
            assert h.send(:warn_if_windows_virtio_iso_missing, 'windows')
        end

        assert_includes out, 'Windows guest will use VirtIO block devices'
        assert_includes out, 'no VirtIO driver ISO is configured'
        assert_includes out, 'may fail to boot'
        assert_includes out, 'virtio_path in oneswap.yaml'
    end

    def test_windows_vd_with_valid_virtio_path_does_not_warn
        h = helper(:virtio_path => __FILE__)

        out, = capture_io do
            refute h.send(:warn_if_windows_virtio_iso_missing, 'windows')
        end

        refute_includes out, 'no VirtIO driver ISO is configured'
    end

    def test_windows_non_vd_device_prefix_does_not_warn
        h = helper(:dev_prefix => 'sd')

        out, = capture_io do
            refute h.send(:warn_if_windows_virtio_iso_missing, 'windows')
        end

        refute_includes out, 'no VirtIO driver ISO is configured'
    end

    def test_non_windows_vd_does_not_warn
        h = helper(:dev_prefix => 'vd')

        out, = capture_io do
            refute h.send(:warn_if_windows_virtio_iso_missing, 'linux')
        end

        refute_includes out, 'no VirtIO driver ISO is configured'
    end

    def test_nonempty_virtio_path_suppresses_missing_configuration_warning
        h = helper(:virtio_path => '/nonexistent/virtio-win.iso')

        out, = capture_io do
            refute h.send(:warn_if_windows_virtio_iso_missing, 'windows')
        end

        assert h.send(:virtio_path_configured?)
        refute_includes out, 'no VirtIO driver ISO is configured'
    end

    def test_configured_machine_is_used_for_bios_and_efi
        {
            'bios' => 'BIOS',
            'efi' => '/tmp/OVMF_CODE.fd'
        }.each do |firmware, expected_path|
            os = firmware_template({ :machine => 'pc-q35-rhel9.4.0' }, firmware)

            assert_equal expected_path, os['FIRMWARE']
            assert_equal 'pc-q35-rhel9.4.0', os['MACHINE']
        end
    end

    def test_machine_defaults_remain_unchanged
        refute firmware_template.key?('MACHINE')
        assert_equal 'q35', firmware_template({}, 'efi')['MACHINE']
    end

    def test_cpu_model_without_features_remains_supported
        assert_nil helper.send(:template_cpu_model)
        assert_equal({ 'MODEL' => 'host-passthrough' },
                     helper.send(:template_cpu_model, { :cpu_model => 'host-passthrough' }))
    end

    def test_cpu_features_accept_yaml_array
        cpu = helper.send(:template_cpu_model, {
            :cpu_model => 'Skylake-Server-noTSX-IBRS',
            :cpu_features => ['arch-capabilities', 'ssbd', 'stibp', 'md-clear']
        })

        assert_equal 'Skylake-Server-noTSX-IBRS', cpu['MODEL']
        assert_equal 'arch-capabilities,ssbd,stibp,md-clear', cpu['FEATURES']
    end

    def test_cpu_features_accept_comma_separated_input
        cpu = helper.send(:template_cpu_model, {
            :cpu_model => 'Skylake-Server-noTSX-IBRS',
            :cpu_features => 'arch-capabilities, ssbd,stibp, md-clear'
        })

        assert_equal 'arch-capabilities,ssbd,stibp,md-clear', cpu['FEATURES']
    end

    def test_cpu_features_require_cpu_model
        error = assert_raises(RuntimeError) do
            helper.send(:template_cpu_model, { :cpu_features => ['ssbd'] })
        end

        assert_equal 'cpu_features requires a non-empty cpu_model', error.message
    end

# Construct the real VM metadata without constructing an SSH client.
    def vddk_vm(client, vmx = '[datastore] actual-folder/guest.vmx')
        info = ESXi::VirtualMachine::VM_INFO_KEYS.to_h {|key| [key, ''] }
        info.merge!(:name => 'display-name', :vmid => 42, :file => vmx)
        ESXi::VirtualMachine.new(client, info).tap do |vm|
            vm.define_singleton_method(:missing_commands) {|_commands| [] }
            # tests/esxi_delta_test.rb covers the conversion check of prepare.
            vm.define_singleton_method(:guest_conversion_possible?) {|_disks, _transfer_dir| true }
        end
    end

    def test_vddk_paths_map_only_resolved_datastore_paths
        client = Struct.new(:logger).new(Logger.new(File::NULL))
        vm = vddk_vm(client)
        names = { 'datastore' => 'datastore', 'shared' => 'shared' }

        assert_equal '[datastore] actual-folder/base.vmdk',
                     vm.vddk_path('/vmfs/volumes/datastore/actual-folder/base.vmdk', names)
        assert_equal '[shared] base.vmdk', vm.vddk_path('/vmfs/volumes/shared/base.vmdk', names)
        # Prepare resolves parent hints against the snapshot descriptor folder.
        assert_raises(RuntimeError) { vm.vddk_path('base.vmdk', names) }
        # ESXi absolute paths always start with /vmfs/volumes.
        assert_raises(RuntimeError) { vm.vddk_path('/shared/base.vmdk', names) }

        root_vm = vddk_vm(client, '[datastore] guest.vmx')
        assert_equal '/vmfs/volumes/datastore/base.vmdk', root_vm.send(:storage_path, 'base.vmdk')
        # Above a datastore root ESXi reaches the next volume, here "shared".
        assert_equal '/vmfs/volumes/shared/base.vmdk', root_vm.send(:storage_path, '../shared/base.vmdk')
    end

    def test_absolute_esxi_disk_paths_keep_ssh_paths_and_map_vddk_names
        client = Struct.new(:logger).new(Logger.new(File::NULL))
        vm = vddk_vm(client)
        names = { 'datastore' => 'datastore', 'Data Store' => 'Data Store',
                  '650c2b3a-12345678-abcd-001122334455' => 'ds2' }

        {
            '/vmfs/volumes/datastore/shared/base.vmdk' => '[datastore] shared/base.vmdk',
            '/vmfs/volumes/Data Store/shared disks/base.vmdk' => '[Data Store] shared disks/base.vmdk',
            '/vmfs/volumes/650c2b3a-12345678-abcd-001122334455/shared/base.vmdk' => '[ds2] shared/base.vmdk'
        }.each do |path, vddk|
            assert_equal path, vm.send(:storage_path, path)
            assert_equal vddk, vm.vddk_path(path, names)
        end
        # VDDK cannot open /vmfs/volumes paths, so an unknown volume is an error.
        assert_raises(RuntimeError) do
            vm.vddk_path('/vmfs/volumes/650c2b3a-12345678-abcd-001122334455/shared/base.vmdk', {})
        end
    end

    def test_datastore_names_with_spaces_preserve_vmx_and_disk_paths
        client = Struct.new(:logger).new(Logger.new(File::NULL))
        names = { 'Data Store' => 'Data Store', 'shared' => 'shared' }

        ['folder', 'VM Folder', '.'].each do |folder|
            vmx = folder == '.' ? 'guest.vmx' : "#{folder}/guest.vmx"
            vm = vddk_vm(client, "[Data Store] #{vmx}")
            storage = File.dirname("/vmfs/volumes/Data Store/#{vmx}")

            assert_equal "/vmfs/volumes/Data Store/#{vmx}", vm.instance_variable_get(:@vmx_file)
            assert_equal "#{storage}/base.vmdk", vm.send(:storage_path, 'base.vmdk')
            relative = folder == '.' ? 'base.vmdk' : "#{folder}/base.vmdk"
            assert_equal "[Data Store] #{relative}", vm.vddk_path(vm.send(:storage_path, 'base.vmdk'), names)
            # Above a datastore root ESXi reaches the next volume.
            shared = folder == '.' ? '/vmfs/volumes/shared/base.vmdk' : '/vmfs/volumes/Data Store/shared/base.vmdk'
            assert_equal shared, vm.send(:storage_path, '../shared/base.vmdk')
            absolute = '/vmfs/volumes/Data Store/shared/base.vmdk'
            assert_equal absolute, vm.send(:storage_path, absolute)
            assert_equal '[Data Store] shared/base.vmdk', vm.vddk_path(absolute, names)
        end
    end

    def test_storage_paths_use_actual_vmx_location
        client = Struct.new(:logger).new(Logger.new(File::NULL))
        [
            ['actual-folder/guest.vmx', '/vmfs/volumes/datastore/actual-folder'],
            ['guest.vmx', '/vmfs/volumes/datastore'],
            ['display-name/display-name.vmx', '/vmfs/volumes/datastore/display-name']
        ].each do |vmx, storage|
            vm = vddk_vm(client, "[datastore] #{vmx}")
            assert_equal "#{storage}/base.vmdk", vm.send(:storage_path, 'base.vmdk')
            assert_equal "#{storage}/vmkfstools_output", vm.instance_variable_get(:@clone_dir)
            assert_equal "/vmfs/volumes/datastore/#{vmx}", vm.instance_variable_get(:@vmx_file)
            assert_equal vm.send(:storage_path, 'base.vmdk'),
                         vm.vddk_path(vm.send(:storage_path, 'base.vmdk'), 'datastore' => 'datastore')
                           .sub('[datastore] ', '/vmfs/volumes/datastore/')
        end
    end

    def with_vddk_prepare(disks)
        Dir.mktmpdir('oneswap-vddk-test-') do |dir|
            client = Minitest::Mock.new
            client.expect(:logger, Logger.new(File::NULL))
            vm = vddk_vm(client)
            clone_dir = '/vmfs/volumes/datastore/actual-folder/vmkfstools_output'
            vm.define_singleton_method(:live_storage_transfer_precheck) { true }
            vm.define_singleton_method(:refresh_vmx) { true }
            vm.define_singleton_method(:active_disks) { disks.keys }
            vm.define_singleton_method(:vmdk_info) do |disk|
                { 'createType' => 'seSparse', 'parentFileNameHint' => disks.fetch(disk) }
            end
            client.expect(:snapshot_vm, true, [42, String, Hash])
            yield vm, client, dir, clone_dir
            client.verify
        end
    end

    # A failed prepare removes the snapshot it created.
    def expect_snapshot_removal(client, removed = true)
        client.expect(:snapshot_id_by_name, '7', [42, String])
        client.expect(:remove_snapshot_vm, removed, [42, '7'])
    end

    def test_vddk_prepare_persists_multiple_disks_without_legacy_clone_or_transfer
        disks = {
            'os-000001.vmdk' => '../os/base.vmdk',
            'data-000001.vmdk' => '/vmfs/volumes/shared-ds/shared/base.vmdk'
        }
        parents = ['/vmfs/volumes/datastore/os/base.vmdk', '/vmfs/volumes/shared-ds/shared/base.vmdk']
        with_vddk_prepare(disks) do |vm, _client, dir, _clone_dir|
            calls = []
            state = nil
            now = Time.at(1000)
            capture_io do
                Time.stub(:now, lambda { now += 1 }) do
                    state = vm.live2kvm_prepare(dir) do |parent, output|
                        calls << [parent, output]
                        File.write(output, 'raw')
                        output
                    end
                end
            end
            transfer = File.join(dir, 'esxi_client-display-name')
            convert = File.join(transfer, 'convert')
            outputs = ["#{convert}/disk0.raw", "#{convert}/disk1.raw"]
            assert_equal parents.zip(outputs), calls
            assert_equal state, YAML.load_file(File.join(transfer, 'oneswap-delta-state.yaml'))
            assert_equal 'display-name', state['vm_name']
            assert_equal vm.live2kvm_snapshot_name, state['snapshot_name']
            assert_equal transfer, state['transfer_dir']
            assert_equal convert, state['convert_dir']
            assert_equal File.join(dir, 'esxi2kvm-display-name'), state['results_dir']
            assert_equal 'vddk', state['transport']
            assert_nil state['clone_dir']
            assert_equal '/vmfs/volumes/datastore', state['datastore_path']
            assert_equal '/vmfs/volumes/datastore/actual-folder', state['vm_storage_path']
            assert_nil state['base_transfer_bytes']
            assert_nil state['base_transfer_seconds']
            assert_nil state['base_transfer_mib_s']
            assert_equal 6, state['base_convert_bytes']
            assert_equal 2.0, state['base_convert_seconds']
            assert_in_delta 6.0 / (1024 * 1024) / state['base_convert_seconds'],
                            state['base_convert_mib_s'], 1e-12
            assert_equal disks.each_with_index.map {|(active, parent), index|
                {
                    'active_snapshot_descriptor' => active,
                    'active_snapshot_extent' => active.sub('.vmdk', '-sesparse.vmdk'),
                    'parent_base_path' => parents[index],
                    'converted_raw_base_path' => outputs[index]
                }
            }, state['disks']
            # The strict client mock rejects remove_files, create_dir,
            # clone_virtual_disk, pull_files and convert_vmdk: none may run for this transport.
        end
    end

    def test_vddk_prepare_ignores_conversion_block_return_value
        [nil, true, '/unexpected/disk.raw'].each do |block_result|
            with_vddk_prepare('disk-000001.vmdk' => 'base.vmdk') do |vm, _client, dir, _clone_dir|
                state = nil
                capture_io do
                    state = vm.live2kvm_prepare(dir) do |parent, output|
                        assert_equal '/vmfs/volumes/datastore/actual-folder/base.vmdk', parent
                        File.write(output, 'raw')
                        block_result
                    end
                end
                expected = File.join(dir, 'esxi_client-display-name/convert/disk0.raw')
                assert_equal expected, state['disks'].first['converted_raw_base_path']
                assert_equal state, vm.live2kvm_state(dir)
                assert_equal 'raw', File.read(expected)
            end
        end
    end

    def test_vddk_prepare_missing_expected_output_fails_and_cleans_up
        with_vddk_prepare('disk-000001.vmdk' => 'base.vmdk') do |vm, client, dir, _clone_dir|
            expect_snapshot_removal(client)
            log = StringIO.new
            vm.instance_variable_set(:@logger, Logger.new(log))
            result = nil
            output, = capture_io do
                result = vm.live2kvm_prepare(dir) do |_parent, target|
                    # Even an existing file returned by the block is not the expected output.
                    other = File.join(File.dirname(target), 'wrong.raw')
                    File.write(other, 'raw')
                    other
                end
            end
            assert_equal false, result
            assert_empty Dir.children(dir)
            assert_includes log.string, 'VDDK conversion output is missing:'
            assert_includes output, "Removed VMware snapshot #{vm.live2kvm_snapshot_name}."
            refute_includes output, 'remains active'
        end
    end

    def test_run_cmd_report_preserves_keyword_environment_with_and_without_timeout
        [{}, { 'ONESWAP_TEST' => 'value with spaces' },
         { 'LIBGUESTFS_PATH' => '/explicit/appliance' }].each do |env|
            [nil, 1].each do |timeout|
                h = helper(:libguestfs_path => '/configured/appliance')
                h.define_singleton_method(:show_wait_spinner) {|&block| block.call }
                status = Struct.new(:success?).new(true)
                wait = Minitest::Mock.new
                wait.expect(:join, true, [1]) if timeout
                wait.expect(:value, status) if timeout
                popen = lambda do |actual_env, cmd, **options, &block|
                    assert_equal env, actual_env
                    assert_equal 'mock-command', cmd
                    assert_equal({ :pgroup => true }, options)
                    block.call(StringIO.new, StringIO.new('stdout'), StringIO.new('stderr'), wait)
                end
                capture = lambda do |actual_env, cmd|
                    assert_equal env, actual_env
                    assert_equal 'mock-command', cmd
                    ['stdout', 'stderr', status]
                end
                Open3.stub(:popen3, popen) do
                    Open3.stub(:capture3, capture) do
                        capture_io do
                            assert_equal ['stdout', status], h.send(:run_cmd_report, 'mock-command', true,
                                                                   timeout: timeout, env: env)
                        end
                    end
                end
                wait.verify
            end
        end
    end

    def test_vddk_prepare_exception_removes_partial_files_and_the_snapshot
        # When the snapshot cannot be removed either, the user is told to clean up.
        [true, false].each do |removed|
            with_vddk_prepare('disk-000001.vmdk' => 'base.vmdk') do |vm, client, dir, _clone_dir|
                expect_snapshot_removal(client, removed)
                result = nil
                output, = capture_io do
                    result = vm.live2kvm_prepare(dir) do |_parent, target|
                        File.write(target, 'partial conversion')
                        raise IOError, 'controlled conversion failure'
                    end
                end
                assert_equal false, result
                warning = "Warning: VM snapshot #{vm.live2kvm_snapshot_name} remains active. " \
                          'Run --delta-cleanup before retrying.'
                transfer = File.join(dir, 'esxi_client-display-name')
                if removed
                    refute_includes output, warning
                    assert_empty Dir.children(dir)
                else
                    assert_includes output, warning
                    # Only the state stays, naming the snapshot for that cleanup.
                    assert_equal ['oneswap-delta-state.yaml'], Dir.children(transfer)
                    assert_equal vm.live2kvm_snapshot_name, vm.live2kvm_state(dir)['snapshot_name']
                end
            end
        end
    end

    def test_vddk_prepare_zero_disks_removes_snapshot_and_stale_state
        with_vddk_prepare({}) do |vm, _client, dir, _clone_dir|
            transfer = File.join(dir, 'esxi_client-display-name')
            FileUtils.mkdir_p(transfer)
            File.write(File.join(transfer, 'oneswap-delta-state.yaml'), 'stale state')
            snapshots = []
            vm.define_singleton_method(:cleanup_snapshot) {|state| snapshots << state }
            capture_io do
                assert_equal false, vm.live2kvm_prepare(dir) { flunk 'No disks should be converted' }
            end
            assert_equal [vm.live2kvm_snapshot_name], snapshots.map {|state| state['snapshot_name'] }
            refute_path_exists transfer
            assert_empty Dir.children(dir)
        end
    end

    def assert_delta_workflow(workflow, vddk, prepared = true)
        Dir.mktmpdir('oneswap-dispatch-test-') do |dir|
            disk = File.join(dir, 'disk0.raw')
            File.write(disk, 'raw')
            h = with_vmx_path(helper(:name => 'test-vm', :work_dir => dir,
                                     :vddk_path => vddk ? '/mock/vddk' : nil))
            h.define_singleton_method(:get_esxi_host) { 'esxi.invalid' }
            h.define_singleton_method(:esxi_client_options) { {} }
            calls = []
            h.define_singleton_method(:delta_preflight!) { calls << :preflight }
            h.define_singleton_method(:validate_delta_vddk_prerequisites!) { calls << :prerequisites }
            h.define_singleton_method(:vcenter_datastore_names) { { 'ds' => 'ds' } }
            h.define_singleton_method(:vcenter_snapshot_moref) do |name|
                calls << [:snapshot, name]
                'snapshot-42'
            end
            h.define_singleton_method(:convert_vddk_disk) do |*args|
                calls << [:convert, *args]
                disk
            end
            h.define_singleton_method(:create_one_images) {|paths, format| calls << [:images, paths, format]; [{ :id => 1 }] }
            h.define_singleton_method(:image_state) {|_id| 'READY' }
            vm = Minitest::Mock.new
            if vddk || workflow == :run_delta_prepare
                vm.expect(:live2kvm_prepare, prepared ? { 'transfer_dir' => dir } : false) do |work, &block|
                    assert_equal dir, work
                    assert_equal vddk, !block.nil?
                    assert_equal disk, block.call('base.vmdk', disk) if block
                    true
                end
                if vddk
                    vm.expect(:live2kvm_snapshot_name, 'prepare snapshot')
                    vm.expect(:vddk_path, '[ds] actual-folder/base.vmdk', ['base.vmdk', { 'ds' => 'ds' }])
                    vm.expect(:live2kvm_commit, dir, [dir]) if workflow == :run_delta_conversion && prepared
                end
            else
                vm.expect(:live2kvm, dir, [dir])
            end
            # The prepared state goes only once the disks are imported.
            vm.expect(:live2kvm_finish, nil, [dir]) if workflow == :run_delta_conversion && prepared
            client = Minitest::Mock.new
            client.expect(:get_vm_by_name, vm, ['test-vm', VMX_PATH])
            factory = lambda do |host, logger, options|
                assert_equal 'esxi.invalid', host
                assert_same h.instance_variable_get(:@logger), logger
                assert_equal({}, options)
                client
            end
            ESXi::Client.stub(:new, factory) do
                capture_io do
                    if prepared
                        h.send(workflow)
                    else
                        error = assert_raises(RuntimeError) { h.send(workflow) }
                        assert_match(/Failed to (perform|prepare) delta migration/, error.message)
                    end
                end
            end
            # Prepare checks the import too: it fails only after the VM is down.
            expected = [:preflight]
            if vddk
                expected.concat([:prerequisites, [:snapshot, 'prepare snapshot'],
                                 [:convert, '[ds] actual-folder/base.vmdk', disk, 'snapshot-42']])
            end
            # The commit leaves raw disks.
            expected << [:images, [disk], 'raw'] if workflow == :run_delta_conversion && prepared
            assert_equal expected, calls
            vm.verify
            client.verify
        end
    end

    def test_run_delta_conversion_dispatches_vddk_prepare_then_commit
        assert_delta_workflow(:run_delta_conversion, true)
    end

    def test_run_delta_prepare_dispatches_vddk_block
        assert_delta_workflow(:run_delta_prepare, true)
    end

    def test_run_delta_conversion_preserves_legacy_live2kvm
        assert_delta_workflow(:run_delta_conversion, false)
    end

    def test_run_delta_prepare_preserves_legacy_prepare_without_block
        assert_delta_workflow(:run_delta_prepare, false)
    end

    def test_failed_vddk_prepare_prevents_commit_and_image_creation
        assert_delta_workflow(:run_delta_conversion, true, false)
        assert_delta_workflow(:run_delta_prepare, true, false)
    end

    def with_prepared_delta(overrides = {})
        Dir.mktmpdir('oneswap-cleanup-test-') do |dir|
            client = Minitest::Mock.new
            client.expect(:logger, Logger.new(File::NULL))
            vm = vddk_vm(client)
            transfer = File.join(dir, 'esxi_client-display-name')
            convert = File.join(transfer, 'convert')
            FileUtils.mkdir_p(convert)
            base = File.join(convert, 'disk0.raw')
            File.write(base, 'raw')
            state = {
                'snapshot_name' => 'OneSwap prepare',
                'transfer_dir' => transfer,
                'convert_dir' => convert,
                'results_dir' => File.join(dir, 'esxi2kvm-display-name'),
                'disks' => [{
                    'active_snapshot_descriptor' => 'disk-000001.vmdk',
                    'active_snapshot_extent' => 'disk-000001-sesparse.vmdk',
                    'converted_raw_base_path' => base
                }]
            }.merge(overrides)
            File.write(File.join(transfer, 'oneswap-delta-state.yaml'), state.to_yaml)
            yield vm, client, dir, state
            client.verify
        end
    end

    def assert_delta_cleanup(workflow, state_fields, remote_dir, snapshot_removed = true)
        with_prepared_delta(state_fields) do |vm, client, dir, state|
            commit = workflow == :live2kvm_commit
            # Snapshot cleanup must still run even when remote clone cleanup is
            # skipped; commit also checks the snapshot before and after the shutdown.
            (commit ? 3 : 1).times { client.expect(:snapshot_id_by_name, 7, [42, 'OneSwap prepare']) }
            client.expect(:remove_snapshot_vm, snapshot_removed, [42, 7])
            # Datastore clones are removed even when the snapshot has to stay.
            client.expect(:remove_files, true, [remote_dir]) if remote_dir
            # The VMX points to the snapshot descriptors until the snapshot is removed.
            vmx_disks = commit ? state['disks'].map {|disk| disk['active_snapshot_descriptor'] } * 2 : []
            # A retried commit compares vmware.log, which every power-on replaces.
            vm_log = '/vmfs/volumes/datastore/actual-folder/vmware.log'
            2.times { client.expect(:file_signature, '1 2', [vm_log]) } if commit
            vm.define_singleton_method(:refresh_vmx) do
                @vmx = { 'scsi0:0.fileName' => vmx_disks.shift || 'base.vmdk' }
            end
            if commit
                vm.define_singleton_method(:tools_state) { :missing }
                states = [ESXi::VirtualMachine::STATES[:RUNNING], ESXi::VirtualMachine::STATES[:POWEROFF]]
                vm.define_singleton_method(:state) { states.length > 1 ? states.shift : states.first }
                client.expect(:shutdown_vm, true, [42, false])
                state['disks'].each do |disk|
                    ['active_snapshot_descriptor', 'active_snapshot_extent'].each do |key|
                        source = "/vmfs/volumes/datastore/actual-folder/#{disk[key]}"
                        client.expect(:pull_files, true, [source, state['transfer_dir']])
                    end
                    client.expect(:apply_vmdk_snapshot_to_raw, true, [
                        File.join(state['transfer_dir'], disk['active_snapshot_extent']),
                        disk['converted_raw_base_path']
                    ])
                    client.expect(:os_morph, true, [disk['converted_raw_base_path'],
                                                  ESXi::VirtualMachine::VIRT_V2V_OPTIONS_EXTRA])
                end
            end
            output, = capture_io do
                result = vm.public_send(workflow, dir)
                assert_equal commit ? state['results_dir'] : snapshot_removed, result
            end
            unless snapshot_removed
                refute_includes output, 'Delta prepare cleanup completed.'
                assert_includes output, 'retained'
                expected_state = remote_dir ? state.merge('clone_dir' => nil) : state
                # A migrated VM only needs the cleanup, never a second commit.
                expected_state = expected_state.merge('commit_stage' => 'migrated', 'vm_log' => '1 2') if commit
                assert_equal expected_state, vm.live2kvm_state(dir)
                if workflow == :live2kvm_cleanup
                    assert_equal 'raw', File.read(state['disks'].first['converted_raw_base_path'])
                end

                # A fresh VM instance can retry cleanup using the retained state;
                # the clones are already gone, only the snapshot is left.
                client.expect(:logger, Logger.new(File::NULL))
                retry_vm = vddk_vm(client)
                retry_vm.define_singleton_method(:refresh_vmx) { @vmx = { 'scsi0:0.fileName' => 'base.vmdk' } }
                client.expect(:snapshot_id_by_name, 7, [42, 'OneSwap prepare'])
                client.expect(:remove_snapshot_vm, true, [42, 7])
                retry_output, = capture_io { assert_equal true, retry_vm.live2kvm_cleanup(dir) }
                assert_includes retry_output, 'Delta prepare cleanup completed.'
            end
            if commit && snapshot_removed
                # The state stays until the disks are imported.
                assert_equal 'cleaned', vm.live2kvm_state(dir)['commit_stage']
                capture_io { vm.live2kvm_finish(dir) }
            end
            refute_path_exists state['transfer_dir']
            if commit
                assert_equal 'raw', File.read(File.join(state['results_dir'], 'disk0.raw'))
            end
        end
    end

    def test_failed_snapshot_removal_retains_state_for_cleanup_retry
        clone_dir = '/vmfs/volumes/datastore/legacy/vmkfstools_output'
        [:live2kvm_commit, :live2kvm_cleanup].each do |workflow|
            assert_delta_cleanup(workflow, { 'transport' => 'vddk', 'clone_dir' => nil }, nil, false)
            assert_delta_cleanup(workflow, { 'transport' => 'ssh', 'clone_dir' => clone_dir }, clone_dir, false)
            assert_delta_cleanup(workflow, { 'clone_dir' => clone_dir }, clone_dir, false)
        end
    end

    def test_delta_cleanup_dispatch_reports_failure
        [true, false].each do |removed|
            h = with_vmx_path(helper(:name => 'test-vm', :work_dir => '/tmp/work'))
            h.define_singleton_method(:get_esxi_host) { 'esxi.invalid' }
            h.define_singleton_method(:esxi_client_options) { {} }
            vm = Minitest::Mock.new
            vm.expect(:live2kvm_cleanup, removed, ['/tmp/work'])
            client = Minitest::Mock.new
            client.expect(:get_vm_by_name, vm, ['test-vm', VMX_PATH])
            ESXi::Client.stub(:new, client) do
                if removed
                    assert_equal true, h.send(:run_delta_cleanup)
                else
                    error = assert_raises(RuntimeError) { h.send(:run_delta_cleanup) }
                    assert_includes error.message, 'Failed to clean up delta migration'
                end
            end
            vm.verify
            client.verify
        end
    end

    def test_delete_preserves_delta_recovery_state_until_cleanup_succeeds
        with_prepared_delta('transport' => 'vddk') do |vm, client, dir, state|
            h = helper(:name => 'display-name', :work_dir => dir, :delta => true, :delete => true)
            ['vpassfile', 'esxpassfile'].each { |name| File.write(File.join(dir, name), 'password') }
            capture_io { h.send(:cleanup_all) }
            assert_equal state, vm.live2kvm_state(dir)
            assert_equal 'raw', File.read(state['disks'].first['converted_raw_base_path'])
            refute_path_exists File.join(dir, 'vpassfile')
            refute_path_exists File.join(dir, 'esxpassfile')

            client.expect(:snapshot_id_by_name, 7, [42, 'OneSwap prepare'])
            client.expect(:remove_snapshot_vm, true, [42, 7])
            vm.define_singleton_method(:refresh_vmx) { @vmx = { 'scsi0:0.fileName' => 'base.vmdk' } }
            capture_io do
                assert_equal true, vm.live2kvm_cleanup(dir)
                h.send(:cleanup_dirs)
            end
            refute_path_exists dir
            Dir.mkdir(dir) # Let the temporary-directory fixture remove its root.
        end
    end

    def test_vddk_commit_and_cleanup_skip_remote_clone_removal
        [:live2kvm_commit, :live2kvm_cleanup].each do |workflow|
            [nil, '/vmfs/volumes/datastore/unused/vmkfstools_output'].each do |clone_dir|
                assert_delta_cleanup(workflow, { 'transport' => 'vddk', 'clone_dir' => clone_dir }, nil)
            end
            assert_delta_cleanup(workflow, { 'transport' => 'vddk' }, nil)
        end
    end

    def test_legacy_commit_and_cleanup_remove_remote_clone_directory
        clone_dir = '/vmfs/volumes/datastore/legacy/vmkfstools_output'
        [:live2kvm_commit, :live2kvm_cleanup].each do |workflow|
            assert_delta_cleanup(workflow, { 'transport' => 'ssh', 'clone_dir' => clone_dir }, clone_dir)
            # Pre-transport-marker states retain their original cleanup behavior.
            assert_delta_cleanup(workflow, { 'clone_dir' => clone_dir }, clone_dir)
            assert_delta_cleanup(workflow, {}, '/vmfs/volumes/datastore/actual-folder/vmkfstools_output')
        end
    end

    def test_commit_and_cleanup_safely_skip_nil_or_empty_clone_directory
        [:live2kvm_commit, :live2kvm_cleanup].each do |workflow|
            [nil, ''].each do |clone_dir|
                assert_delta_cleanup(workflow, { 'clone_dir' => clone_dir }, nil)
            end
        end
    end

    def test_vddk_commit_failure_keeps_local_state_without_remote_clone_removal
        with_prepared_delta('transport' => 'vddk') do |vm, client, dir, state|
            vm.define_singleton_method(:tools_state) { :missing }
            vm.define_singleton_method(:state) { ESXi::VirtualMachine::STATES[:RUNNING] }
            vm.define_singleton_method(:refresh_vmx) { @vmx = { 'scsi0:0.fileName' => 'disk-000001.vmdk' } }
            client.expect(:snapshot_id_by_name, 7, [42, 'OneSwap prepare'])
            client.expect(:shutdown_vm, false, [42, false])
            capture_io { assert_equal false, vm.live2kvm_commit(dir) }
            assert_equal state, vm.live2kvm_state(dir)
            assert_equal 'raw', File.read(state['disks'].first['converted_raw_base_path'])
        end
    end

    def test_legacy_prepare_retains_separate_transfer_and_conversion_metrics
        with_vddk_prepare('disk-000001.vmdk' => 'base.vmdk') do |vm, client, dir, clone_dir|
            transfer = File.join(dir, 'esxi_client-display-name')
            client.expect(:remove_files, true, [clone_dir])
            client.expect(:create_dir, true, [clone_dir])
            client.expect(:clone_virtual_disk, true, [
                '/vmfs/volumes/datastore/actual-folder/base.vmdk', "#{clone_dir}/disk0.vmdk"
            ])
            client.expect(:pull_files, true) do |source, destination|
                assert_equal "#{clone_dir}/*", source
                assert_equal transfer, destination
                File.write(File.join(destination, 'disk0.vmdk'), 'vmdk')
                true
            end
            client.expect(:convert_vmdk, true) do |source, destination, format|
                assert_equal File.join(transfer, 'disk0.vmdk'), source
                assert_equal File.join(transfer, 'convert/disk0.raw'), destination
                assert_equal 'raw', format
                File.write(destination, 'raw')
                true
            end
            # The clones go once the base copies are local.
            client.expect(:remove_files, true, [clone_dir])
            state = nil
            capture_io { state = vm.live2kvm_prepare(dir) }
            assert_equal 'ssh', state['transport']
            assert_nil state['clone_dir']
            assert_equal 4, state['base_transfer_bytes']
            assert_equal 3, state['base_convert_bytes']
            ['base_transfer_seconds', 'base_convert_seconds',
             'base_transfer_mib_s', 'base_convert_mib_s'].each do |key|
                assert_operator state[key], :>, 0, key
            end
            assert_equal state, vm.live2kvm_state(dir)
        end
    end

    def assert_delta_dry_run_metrics(state, expected_rate, expected_source, expected_apply_rate = 80)
        Dir.mktmpdir('oneswap-estimate-test-') do |dir|
            h = helper(:work_dir => dir, :name => 'test-vm',
                       :dry_run_source_export_mib_s => 40,
                       :dry_run_qcow2_conversion_mib_s => 50,
                       :dry_run_delta_os_morph_seconds => 30,
                       :dry_run_guest_customization_seconds => 10)
            with_vmx_path(h)
            h.define_singleton_method(:get_esxi_host) { 'esxi.invalid' }
            h.define_singleton_method(:read_metrics) { {} }
            client = Minitest::Mock.new
            vm = Minitest::Mock.new
            # Run both the calculation and the full reporting entry point.
            2.times do
                client.expect(:get_vm_by_name, vm, ['test-vm', VMX_PATH])
                vm.expect(:live2kvm_state, state, [dir])
                vm.expect(:live2kvm_current_delta_size, {
                    :bytes => 1024 * 1024, :source => 'test delta', :paths => [], :refreshed => true
                }, [dir])
            end
            ESXi::Client.stub(:new, client) do
                info = h.send(:dry_run_delta_info)
                refute_nil info
                assert_equal expected_rate, info[:source_rate]
                assert_equal expected_source, info[:source_rate_source]
                assert_equal expected_apply_rate, info[:apply_rate]
                output, = capture_io { h.send(:run_delta_dry_run_estimate) }
                label = expected_source == :prepare_measured ? 'measured during prepare' : 'configured fallback, not measured'
                assert_includes output, "source/delta transfer: #{expected_rate.to_f} MiB/s (#{label})"
                assert_includes output, 'total estimated downtime/import-ready time:'
                refute_match(/NaN|Infinity/, output)
            end
            client.verify
            vm.verify
        end
    end

    def test_delta_dry_run_uses_fallback_for_nil_vddk_transfer_metrics
        # The VDDK copy speed is a network rate, not the local delta apply rate.
        assert_delta_dry_run_metrics({
            'transport' => 'vddk', 'base_transfer_bytes' => nil,
            'base_transfer_seconds' => nil, 'base_transfer_mib_s' => nil,
            'base_convert_bytes' => 1024 * 1024, 'base_convert_seconds' => 0.0125,
            'base_convert_mib_s' => 80
        }, 40, :configured_fallback, 50)
    end

    def test_delta_dry_run_preserves_old_state_transfer_metrics
        assert_delta_dry_run_metrics({
            'base_transfer_bytes' => 1024 * 1024, 'base_transfer_seconds' => 0.01,
            'base_transfer_mib_s' => 100, 'base_convert_bytes' => 1024 * 1024,
            'base_convert_mib_s' => 80
        }, 100, :prepare_measured)
    end

    def test_delta_dry_run_uses_fallback_when_old_state_has_no_transfer_metrics
        assert_delta_dry_run_metrics({ 'base_convert_mib_s' => 80 }, 40, :configured_fallback)
    end

    def test_delta_dry_run_explains_why_no_estimate_is_available
        h = helper(:work_dir => '/tmp/work', :name => 'test-vm')
        h.define_singleton_method(:get_esxi_host) { 'esxi.invalid' }
        failing = ->(*) { raise 'Unable to authenticate to ESXi host root@esxi.invalid' }
        output = nil
        ESXi::Client.stub(:new, failing) do
            output, = capture_io { h.send(:run_delta_dry_run_estimate) }
        end
        assert_includes output, 'Downtime estimate is not available: Unable to authenticate to ESXi host'
    end

    def test_vcenter_datastore_names_map_uuids_and_names
        h = helper
        # The VM config already lists its datastores; no extra vCenter call is needed.
        h.instance_variable_set(:@props, { 'config' => { :datastoreUrl => [
            { :name => 'ssd-datastore', :url => '/vmfs/volumes/67da89c9-a0d67b30-f01d-ac1f6be6c5d4' },
            { :name => 'nfs ds', :url => '/vmfs/volumes/d3366807-fa4825ad/' }
        ] } })

        assert_equal({
            'ssd-datastore' => 'ssd-datastore', '67da89c9-a0d67b30-f01d-ac1f6be6c5d4' => 'ssd-datastore',
            'nfs ds' => 'nfs ds', 'd3366807-fa4825ad' => 'nfs ds'
        }, h.send(:vcenter_datastore_names))
    end

    def delta_conversion_helper(dir, vm)
        h = with_vmx_path(helper(:name => 'test-vm', :work_dir => dir))
        h.define_singleton_method(:get_esxi_host) { 'esxi.invalid' }
        h.define_singleton_method(:esxi_client_options) { {} }
        h.define_singleton_method(:delta_preflight!) { true }
        h.define_singleton_method(:image_state) {|_id| 'READY' }
        h.define_singleton_method(:vm_images) { [] }
        client = Object.new
        client.define_singleton_method(:get_vm_by_name) {|_name, _vmx| vm }
        [h, client]
    end

    def test_run_delta_conversion_imports_disks_in_vmx_order
        Dir.mktmpdir do |dir|
            results = File.join(dir, 'results')
            Dir.mkdir(results)
            %w[disk10.raw disk2.raw disk0.raw disk1.raw].each {|name| File.write(File.join(results, name), '') }
            vm = Object.new
            vm.define_singleton_method(:live2kvm) {|_dir| results }
            vm.define_singleton_method(:live2kvm_finish) {|_dir| }
            h, client = delta_conversion_helper(dir, vm)
            imported = nil
            h.define_singleton_method(:create_one_images) {|paths, _format| imported = paths; [{ :id => 1 }] }

            ESXi::Client.stub(:new, client) { h.send(:run_delta_conversion) }

            assert_equal %w[disk0.raw disk1.raw disk2.raw disk10.raw].map {|name| File.join(results, name) },
                         imported
        end
    end

    def test_run_delta_conversion_keeps_the_state_until_the_import_succeeds
        Dir.mktmpdir do |dir|
            results = File.join(dir, 'results')
            Dir.mkdir(results)
            File.write(File.join(results, 'disk0.raw'), '')
            calls = []
            vm = Object.new
            vm.define_singleton_method(:live2kvm) {|_dir| results }
            vm.define_singleton_method(:live2kvm_finish) {|_dir| calls << :finish }
            h, client = delta_conversion_helper(dir, vm)
            h.define_singleton_method(:create_one_images) {|_paths, _format| raise 'datastore full' }
            output = nil
            ESXi::Client.stub(:new, client) do
                output, = capture_io { assert_raises(RuntimeError) { h.send(:run_delta_conversion) } }
            end
            assert_empty calls
            assert_includes output, '--delta-commit'

            h.define_singleton_method(:create_one_images) {|_paths, _format| calls << :import; [{ :id => 7 }] }
            h.define_singleton_method(:image_state) {|_id| 'READY' }
            ESXi::Client.stub(:new, client) { assert_equal [{ :id => 7 }], h.send(:run_delta_conversion) }
            assert_equal [:import, :finish], calls
        end
    end

    def test_run_delta_conversion_lists_the_images_to_delete_before_a_retry
        Dir.mktmpdir do |dir|
            results = File.join(dir, 'results')
            Dir.mkdir(results)
            File.write(File.join(results, 'disk0.raw'), '')
            vm = Object.new
            vm.define_singleton_method(:live2kvm) {|_dir| results }
            h, client = delta_conversion_helper(dir, vm)
            h.define_singleton_method(:create_one_images) {|_paths, _format| raise 'datastore full' }
            # Images it could not delete would block the retry.
            h.define_singleton_method(:vm_images) { ['test-vm_0 (ID 27)'] }
            output = nil
            ESXi::Client.stub(:new, client) do
                output, = capture_io { assert_raises(RuntimeError) { h.send(:run_delta_conversion) } }
            end

            assert_includes output, 'test-vm_0 (ID 27)'
            assert_includes output, '--delta-commit'
        end
    end

    def test_run_delta_conversion_keeps_the_state_while_opennebula_still_copies
        Dir.mktmpdir do |dir|
            results = File.join(dir, 'results')
            Dir.mkdir(results)
            File.write(File.join(results, 'disk0.raw'), '')
            finished = false
            vm = Object.new
            vm.define_singleton_method(:live2kvm) {|_dir| results }
            vm.define_singleton_method(:live2kvm_finish) {|_dir| finished = true }
            h, client = delta_conversion_helper(dir, vm)
            h.define_singleton_method(:create_one_images) {|_paths, _format| [{ :id => 7, :os => 'linux' }] }
            # --img-wait ended before the datastore copy.
            h.define_singleton_method(:image_state) {|_id| 'LOCKED' }
            h.define_singleton_method(:delete_one_images) {|_ids| flunk 'an image still copied must stay' }
            ids = nil
            output = nil
            ESXi::Client.stub(:new, client) do
                output, = capture_io { ids = h.send(:run_delta_conversion) }
            end

            # The copy reads the migrated disks, so the work dir stays.
            assert_equal [{ :id => 7, :os => 'linux' }], ids
            refute finished
            assert_includes output, '--delta-cleanup --delete-after'
        end
    end

    def test_an_interrupted_delta_import_tells_how_to_retry
        Dir.mktmpdir do |dir|
            results = File.join(dir, 'results')
            Dir.mkdir(results)
            File.write(File.join(results, 'disk0.raw'), '')
            finished = false
            vm = Object.new
            vm.define_singleton_method(:live2kvm) {|_dir| results }
            vm.define_singleton_method(:live2kvm_finish) {|_dir| finished = true }
            h, client = delta_conversion_helper(dir, vm)
            h.define_singleton_method(:create_one_images) {|_paths, _format| raise Interrupt }
            h.define_singleton_method(:vm_images) { [] }
            output = nil
            ESXi::Client.stub(:new, client) do
                output, = capture_io { assert_raises(Interrupt) { h.send(:run_delta_conversion) } }
            end

            # The VM stays off: its migrated disks are kept for the retry.
            refute finished
            assert_includes output, 'retry the import with --delta-commit'
        end
    end

    def apostrophe_convert_helper
        helper.tap do |h|
            h.define_singleton_method(:apply_verbosity) {|_options| }
            h.define_singleton_method(:check_one_connectivity) { true }
        end
    end

    def apostrophe_convert_options(dir, extra = {})
        { :work_dir => dir.dup, :vcenter => 'vcenter.invalid', :vuser => 'user', :vpass => 'secret' }.merge(extra)
    end

    # OpenNebula's datastore drivers single-quote the path of a local image.
    def test_convert_refuses_an_apostrophe_before_any_change
        Dir.mktmpdir do |dir|
            h = apostrophe_convert_helper
            started = false
            h.define_singleton_method(:convert_vm) { started = true }
            error = nil
            capture_io do
                error = assert_raises(ConversionError) { h.convert("Bob's VM", apostrophe_convert_options(dir, :delta => true)) }
            end

            # No snapshot, clone or conversion started.
            refute started
            assert_includes error.message, 'apostrophe'
            refute_path_exists File.join(dir, "Bob's VM")
        end
    end

    def test_convert_takes_an_apostrophe_over_http_or_to_clean_up
        [{ :http_transfer => true }, { :delta => true, :delta_cleanup => true }].each do |extra|
            Dir.mktmpdir do |dir|
                h = apostrophe_convert_helper
                converted = false
                h.define_singleton_method(:convert_vm) { converted = true }
                capture_io { h.convert("Bob's VM", apostrophe_convert_options(dir, extra)) }

                assert converted, extra.inspect
            end
        end
    end

    def test_delta_preflight_accepts_vm_names_with_spaces_and_quotes
        # Every command of the migration quotes its paths; with http_transfer
        # OpenNebula gets a percent-encoded URL.
        h = helper(:work_dir => "/var/tmp/work/Bob's Web Server", :http_transfer => true)
        h.define_singleton_method(:warn_unreadable_kernel_for_libguestfs) {|_env| }

        assert_nil h.send(:delta_preflight!)
    end

    def test_delta_finds_the_esxi_vm_by_its_vmx_path
        h = with_vmx_path(helper(:name => 'test-vm'))
        h.define_singleton_method(:get_esxi_host) { 'esxi.invalid' }
        args = nil
        client = Object.new
        client.define_singleton_method(:get_vm_by_name) {|*given| args = given; :vm }
        ESXi::Client.stub(:new, client) { assert_equal :vm, h.send(:delta_esxi_vm, {}) }

        # Another VM of the same name on the host must never be shut down.
        assert_equal ['test-vm', VMX_PATH], args
    end

    def test_delta_preflight_warns_when_libguestfs_cannot_start
        h = helper(:work_dir => '/tmp/work', :http_transfer => true)
        warned = []
        h.define_singleton_method(:warn_unreadable_kernel_for_libguestfs) {|env| warned << env }
        h.send(:delta_preflight!)

        assert_equal [{}], warned
    end

    def test_delta_commands_report_a_vm_missing_on_the_esxi_host
        [:run_delta_conversion, :run_delta_prepare, :run_delta_cleanup].each do |workflow|
            h, client = delta_conversion_helper('/tmp/work', nil)
            error = nil
            ESXi::Client.stub(:new, client) do
                capture_io { error = assert_raises(RuntimeError) { h.send(workflow) } }
            end
            assert_includes error.message, "Unable to find VM test-vm (#{VMX_PATH}) on ESXi host esxi.invalid", workflow
        end
    end

    def test_delta_cleanup_skips_opennebula_name_prechecks
        assert helper.send(:one_prechecks_required?)
        refute helper(:skip_prechecks => true).send(:one_prechecks_required?)
        # Cleanup creates no image or template, and its images may already exist.
        refute helper(:delta => true, :delta_cleanup => true).send(:one_prechecks_required?)
    end

    def test_convert_reports_the_connection_error_and_cleans_up
        Dir.mktmpdir('oneswap-convert-error-') do |dir|
            h = helper
            h.define_singleton_method(:apply_verbosity) {|_| }
            h.define_singleton_method(:check_one_connectivity) { true }
            options = { :work_dir => dir.dup, :delete => true }
            error = nil
            capture_io do
                error = assert_raises(ConversionError) { h.convert('test-vm', options) }
            end
            assert_includes error.message, 'vCenter connection parameters are mandatory'
            refute_path_exists File.join(dir, 'test-vm')
        end
    end

    def test_fallback_conversion_only_removes_the_failed_outputs
        [true, false].each do |delete|
            Dir.mktmpdir('oneswap-fallback-') do |dir|
                conversions = File.join(dir, 'conversions')
                transfers = File.join(dir, 'transfers')
                [conversions, transfers].each {|path| Dir.mkdir(path) }
                File.write(File.join(conversions, 'test-vm-sda'), 'partial virt-v2v output')
                # A hybrid custom conversion converts these downloads.
                File.write(File.join(transfers, 'test-vm.vmdk'), 'download')
                h = helper(:work_dir => dir, :name => 'test-vm', :fallback => true, :delete => delete)
                h.instance_variable_set(:@props, { 'config' => { :guestFullName => 'Alpine Linux' } })
                h.define_singleton_method(:build_v2v_vc_cmd) { 'virt-v2v' }
                h.define_singleton_method(:warn_unreadable_kernel_for_libguestfs) {|_env| }
                seen = nil
                h.define_singleton_method(:run_custom_conversion) do
                    seen = [Dir.children(conversions), Dir.children(transfers)]
                end
                Open3.stub(:popen3, ->(*) { raise 'virt-v2v is unable to convert this guest type' }) do
                    capture_io { h.send(:run_v2v_conversion) }
                end
                assert_equal [delete ? [] : ['test-vm-sda'], ['test-vm.vmdk']], seen
            end
        end
    end

    def test_log_file_falls_back_to_home_when_the_system_log_is_not_writable
        Dir.mktmpdir('oneswap-home-') do |home|
            original = File.method(:open)
            denied = lambda do |path, *args, **kwargs, &block|
                raise Errno::EACCES, path if path == OneSwapHelper::LOG

                original.call(path, *args, **kwargs, &block)
            end
            stderr = nil
            ENV.stub(:[], ->(key) { key == 'HOME' ? home : ENV.fetch(key, nil) }) do
                Dir.stub(:home, home) do
                    Dir.stub(:exist?, true) do
                        File.stub(:open, denied) do
                            _, stderr = capture_io { OneSwapHelper.new }
                        end
                    end
                end
            end
            assert_path_exists File.join(home, 'oneswap.log')
            assert_includes stderr, OneSwapHelper::LOG
        end
    end

    def test_delta_preflight_rejects_a_work_dir_oneadmin_cannot_read
        user = Struct.new(:name, :uid, :gid).new('oneadmin', 9869, 9869)
        [true, false].each do |readable|
            Dir.mktmpdir('oneswap-preflight-') do |work_dir|
                h = helper(:work_dir => work_dir, :endpoint => 'http://localhost:2633/RPC2')
                h.define_singleton_method(:path_accessible_as?) {|_user, _path| readable }
                Process.stub(:uid, 0) do
                    Etc.stub(:getpwnam, user) do
                        # Shift imports from its own mount, not from work_dir.
                        assert_nil h.send(:local_path_image_allocation_preflight!)
                        if readable
                            assert_nil h.send(:delta_preflight!)
                        else
                            error = assert_raises(RuntimeError) { h.send(:delta_preflight!) }
                            assert_includes error.message, work_dir
                        end
                    end
                end
                assert_empty Dir.children(work_dir)
            end
        end
        # Served over HTTP, the disks are not read by oneadmin.
        h = helper(:work_dir => '/var/tmp/private/test-vm', :http_transfer => true)
        h.define_singleton_method(:path_accessible_as?) {|_user, _path| flunk 'not needed with http_transfer' }
        Process.stub(:uid, 0) { assert_nil h.send(:delta_preflight!) }
    end

    def test_delta_preflight_checks_a_file_created_like_the_disks
        user = Struct.new(:name, :uid, :gid).new('oneadmin', 9869, 9869)
        Dir.mktmpdir('oneswap-preflight-') do |work_dir|
            h = helper(:work_dir => work_dir, :endpoint => 'http://localhost:2633/RPC2')
            probes = []
            h.define_singleton_method(:path_accessible_as?) do |_user, path|
                probes << [File.file?(path), File.dirname(path, 2), format('%o', File.stat(path).mode & 0o777)]
                false
            end
            umask = File.umask(0o027)
            begin
                Process.stub(:uid, 0) do
                    Etc.stub(:getpwnam, user) do
                        error = assert_raises(RuntimeError) { h.send(:delta_preflight!) }
                        assert_includes error.message, 'umask'
                    end
                end
            ensure
                File.umask(umask)
            end

            # The disks are files in new directories below work_dir, created
            # with the umask of this process.
            assert_equal [[true, work_dir, '640']], probes
            assert_empty Dir.children(work_dir)
        end
    end

    def test_fallback_cleanup_does_not_glob_the_vm_name
        Dir.mktmpdir('oneswap-fallback-') do |root|
            dir = File.join(root, 'web[1]')
            other = File.join(root, 'web1', 'conversions')
            FileUtils.mkdir_p([File.join(dir, 'conversions'), File.join(dir, 'transfers'), other])
            File.write(File.join(dir, 'conversions', 'web[1]-sda'), 'partial virt-v2v output')
            File.write(File.join(other, 'web1-sda'), 'output of another VM')
            h = helper(:work_dir => dir, :name => 'web[1]', :fallback => true, :delete => true)
            h.instance_variable_set(:@props, { 'config' => { :guestFullName => 'Alpine Linux' } })
            h.define_singleton_method(:build_v2v_vc_cmd) { 'virt-v2v' }
            h.define_singleton_method(:warn_unreadable_kernel_for_libguestfs) {|_env| }
            h.define_singleton_method(:run_custom_conversion) { true }
            Open3.stub(:popen3, ->(*) { raise 'virt-v2v is unable to convert this guest type' }) do
                capture_io { h.send(:run_v2v_conversion) }
            end

            assert_empty Dir.children(File.join(dir, 'conversions'))
            assert_equal ['web1-sda'], Dir.children(other)
        end
    end

    def test_log_file_is_disabled_when_no_home_directory_is_known
        denied = ->(path, *) { raise Errno::EACCES, path }
        stderr = nil
        Dir.stub(:exist?, true) do
            Dir.stub(:home, -> { raise ArgumentError, "couldn't find login name" }) do
                File.stub(:open, ->(path, *args) { path == File::NULL ? StringIO.new : denied.call(path, *args) }) do
                    _, stderr = capture_io { OneSwapHelper.new }
                end
            end
        end
        assert_includes stderr, 'logging is disabled'
    end

    def test_config_file_conversion_modes_do_not_apply_to_delta
        config = { :esxi_ip => '10.0.1.6', :esxi_user => 'root', :custom_convert => true, :hybrid => true,
                   :download_stripes => 4, :fallback => true, :clone => false, :shift => true,
                   :shift_skip_conversion => true, :vddk_path => '/opt/vddk' }

        assert_equal [:esxi_ip, :custom_convert, :hybrid, :download_stripes, :fallback, :shift,
                      :shift_skip_conversion],
                     OneSwapHelper.drop_config_modes_for_delta!(config)
        # Delta still uses the ESXi credentials and VDDK.
        assert_equal({ :esxi_user => 'root', :vddk_path => '/opt/vddk' }, config)
    end

end
