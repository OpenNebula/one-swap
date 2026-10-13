# Unit-style checks for dry-run estimator and safety helpers.
# Run with: ruby tests/dry_run_safety_test.rb

require 'logger'
require 'minitest/autorun'
require 'stringio'
require 'tmpdir'

module OpenNebulaHelper
    class OneHelper; end
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
    def helper(options = {})
        OneSwapHelper.allocate.tap do |h|
            h.instance_variable_set(:@options, {
                :dry_run_target_import_mib_s => 80
            }.merge(options))
            h.instance_variable_set(:@logger, Logger.new(File::NULL))
        end
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
        vm.define_singleton_method(:vddk_path) {|disk| calls << [:vddk_path, disk]; "[datastore] test-vm/#{disk}" }
        h = helper(:work_dir => '/tmp/work', :vddk_path => '/opt/vddk', :skip_prechecks => true)
        h.define_singleton_method(:validate_delta_vddk_prerequisites!) do
            calls << [:vddk_prerequisites]
        end
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
            [:vddk_path, 'base.vmdk'],
            [:convert_vddk, '[datastore] test-vm/base.vmdk', '/tmp/work/convert/disk0.raw', 'snapshot-42'],
            [:vddk_path, 'data.vmdk'],
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

    def test_vcenter_snapshot_moref_retries_and_finds_nested_snapshot
        ref = Struct.new(:_ref)
        node = Struct.new(:name, :snapshot, :childSnapshotList)
        expected = node.new('VM Snapshot test', ref.new('snapshot-42'), [])
        root = node.new('older snapshot', ref.new('snapshot-1'), [expected])
        snapshot_info = Struct.new(:rootSnapshotList).new([root])
        calls = 0
        vc_vm = Object.new
        vc_vm.define_singleton_method(:collect!) do |_property|
            calls += 1
            { 'snapshot' => calls == 1 ? nil : snapshot_info }
        end
        h = helper
        h.instance_variable_set(:@vi_client, Object.new)
        h.instance_variable_set(:@vm_moref, 'vm-42')

        RbVmomi::VIM::VirtualMachine.stub(:new, vc_vm) do
            h.stub(:sleep, nil) do
                assert_equal 'snapshot-42', h.send(:vcenter_snapshot_moref, 'VM Snapshot test')
            end
        end
        assert_equal 2, calls
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

    def test_delta_prepare_with_zero_disks_cleans_snapshot_and_does_not_write_state
        calls = []
        vm = delta_vm
        [:live_storage_transfer_precheck, :vmwaretools?].each {|m| vm.define_singleton_method(m) { true } }
        vm.define_singleton_method(:create_snapshot) do |name, *|
            @created_snapshot_name = name
            true
        end
        vm.define_singleton_method(:refresh_vmx) { true }
        vm.define_singleton_method(:active_disks) { [] }
        vm.define_singleton_method(:cleanup_snapshot) {|state| calls << [:snapshot, state['snapshot_name']] }
        vm.define_singleton_method(:live_storage_transfer_cleanup) {|dir, reason = nil| calls << [:cleanup, dir, reason] }
        vm.define_singleton_method(:write_live2kvm_state) { raise 'state should not be written' }

        result = vm.live2kvm_prepare('/tmp/work') { raise 'no disks should be converted' }

        assert_equal false, result
        assert_equal vm.instance_variable_get(:@created_snapshot_name), vm.live2kvm_snapshot_name
        assert_equal :snapshot, calls[-2][0]
        assert_equal [:cleanup, '/tmp/work/esxi_client-test-vm', 'no active disks detected for delta migration'], calls[-1]
    end

    def test_delta_prepare_logs_vddk_exception_details
        Dir.mktmpdir do |dir|
            log = StringIO.new
            vm = delta_vm
            vm.instance_variable_set(:@logger, Logger.new(log, :level => Logger::DEBUG))
            [:live_storage_transfer_precheck, :vmwaretools?].each {|m| vm.define_singleton_method(m) { true } }
            vm.define_singleton_method(:create_snapshot) do |name, *|
                @created_snapshot_name = name
                true
            end
            vm.define_singleton_method(:refresh_vmx) { true }
            vm.define_singleton_method(:active_disks) { ['disk-000001.vmdk'] }
            vm.define_singleton_method(:vmdk_info) {|_| { 'parentFileNameHint' => 'base.vmdk' } }
            vm.define_singleton_method(:live_storage_transfer_cleanup) do |_, reason = nil|
                @cleanup_reason = reason if reason
            end
            vm.define_singleton_method(:write_live2kvm_state) { raise 'state should not be written' }
            error = ArgumentError.new('bad vddk')
            error.set_backtrace(['controlled-vddk-backtrace:1'])

            result = nil
            stdout, = capture_io do
                result = vm.live2kvm_prepare(dir) { raise error }
            end

            assert_equal false, result
            assert_includes vm.instance_variable_get(:@cleanup_reason), 'ArgumentError: bad vddk'
            assert_includes log.string, 'controlled-vddk-backtrace:1'
            warning = "Warning: VM snapshot #{vm.instance_variable_get(:@created_snapshot_name)} " \
                      'remains active. Run --delta-cleanup before retrying.'
            assert_includes stdout, warning
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

    # Construct the real VM metadata without constructing an SSH client.
    def vddk_vm(client, vmx = '[datastore] actual-folder/guest.vmx')
        info = ESXi::VirtualMachine::VM_INFO_KEYS.to_h {|key| [key, ''] }
        info.merge!(:name => 'display-name', :vmid => 42, :file => vmx)
        ESXi::VirtualMachine.new(client, info)
    end

    def test_vddk_paths_use_vmx_folder_and_normalize_parent_hints
        client = Struct.new(:logger).new(Logger.new(File::NULL))
        vm = vddk_vm(client)
        assert_equal '[datastore] actual-folder/base.vmdk', vm.vddk_path('base.vmdk')
        assert_equal '[datastore] shared/base.vmdk', vm.vddk_path('../shared/base.vmdk')
        assert_equal '[datastore] shared/base.vmdk', vm.vddk_path('/shared/base.vmdk')

        root_vm = vddk_vm(client, '[datastore] guest.vmx')
        assert_equal '[datastore] base.vmdk', root_vm.vddk_path('base.vmdk')
        assert_equal '[datastore] shared/base.vmdk', root_vm.vddk_path('../shared/base.vmdk')
    end

    def with_vddk_prepare(disks)
        Dir.mktmpdir('oneswap-vddk-test-') do |dir|
            client = Minitest::Mock.new
            client.expect(:logger, Logger.new(File::NULL))
            vm = vddk_vm(client)
            clone_dir = '/vmfs/volumes/datastore/display-name/vmkfstools_output'
            vm.define_singleton_method(:live_storage_transfer_precheck) { true }
            vm.define_singleton_method(:vmwaretools?) { true }
            vm.define_singleton_method(:refresh_vmx) { true }
            vm.define_singleton_method(:active_disks) { disks.keys }
            vm.define_singleton_method(:vmdk_info) do |disk|
                { 'parentFileNameHint' => disks.fetch(disk) }
            end
            client.expect(:snapshot_vm, true, [42, String, Hash])
            yield vm, client, dir, clone_dir
            client.verify
        end
    end

    def test_vddk_prepare_persists_multiple_disks_without_legacy_clone_or_transfer
        disks = {
            'os-000001.vmdk' => '../os/base.vmdk',
            'data-000001.vmdk' => '/shared/base.vmdk'
        }
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
            assert_equal disks.values.zip(outputs), calls
            assert_equal state, YAML.load_file(File.join(transfer, 'oneswap-delta-state.yaml'))
            assert_equal 'display-name', state['vm_name']
            assert_equal vm.live2kvm_snapshot_name, state['snapshot_name']
            assert_equal transfer, state['transfer_dir']
            assert_equal convert, state['convert_dir']
            assert_equal File.join(dir, 'esxi2kvm-display-name'), state['results_dir']
            assert_equal 'vddk', state['transport']
            assert_nil state['clone_dir']
            assert_equal '/vmfs/volumes/datastore', state['datastore_path']
            assert_equal '/vmfs/volumes/datastore/display-name', state['vm_storage_path']
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
                    'parent_base_descriptor' => parent,
                    'converted_raw_base_path' => outputs[index]
                }
            }, state['disks']
            # The strict client mock rejects remove_files, create_dir,
            # clone_virtual_disk, pull_files and convert_vmdk: none may run for this transport.
        end
    end

    def test_vddk_prepare_exception_removes_partial_files_and_keeps_snapshot_for_cleanup
        with_vddk_prepare('disk-000001.vmdk' => 'base.vmdk') do |vm, _client, dir, _clone_dir|
            result = nil
            output, = capture_io do
                result = vm.live2kvm_prepare(dir) do |_parent, target|
                    File.write(target, 'partial conversion')
                    raise IOError, 'controlled conversion failure'
                end
            end
            assert_equal false, result
            refute_path_exists File.join(dir, 'esxi_client-display-name')
            assert_empty Dir.children(dir)
            assert_includes output, "Warning: VM snapshot #{vm.live2kvm_snapshot_name} remains active."
            assert_includes output, 'Run --delta-cleanup before retrying.'
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
            assert_equal [{ 'snapshot_name' => vm.live2kvm_snapshot_name }], snapshots
            refute_path_exists transfer
            assert_empty Dir.children(dir)
        end
    end

    def assert_delta_workflow(workflow, vddk, prepared = true)
        Dir.mktmpdir('oneswap-dispatch-test-') do |dir|
            disk = File.join(dir, 'disk0.raw')
            File.write(disk, 'raw')
            h = helper(:name => 'test-vm', :work_dir => dir,
                       :vddk_path => vddk ? '/mock/vddk' : nil)
            h.define_singleton_method(:get_esxi_host) { 'esxi.invalid' }
            h.define_singleton_method(:esxi_client_options) { {} }
            calls = []
            h.define_singleton_method(:local_path_image_allocation_preflight!) { calls << :preflight }
            h.define_singleton_method(:validate_delta_vddk_prerequisites!) { calls << :prerequisites }
            h.define_singleton_method(:vcenter_snapshot_moref) do |name|
                calls << [:snapshot, name]
                'snapshot-42'
            end
            h.define_singleton_method(:convert_vddk_disk) do |*args|
                calls << [:convert, *args]
                disk
            end
            h.define_singleton_method(:create_one_images) {|paths| calls << [:images, paths] }
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
                    vm.expect(:vddk_path, '[ds] actual-folder/base.vmdk', ['base.vmdk'])
                    vm.expect(:live2kvm_commit, dir, [dir]) if workflow == :run_delta_conversion && prepared
                end
            else
                vm.expect(:live2kvm, dir, [dir])
            end
            client = Minitest::Mock.new
            client.expect(:get_vm_by_name, vm, ['test-vm'])
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
            expected = workflow == :run_delta_conversion ? [:preflight] : []
            if vddk
                expected.concat([:prerequisites, [:snapshot, 'prepare snapshot'],
                                 [:convert, '[ds] actual-folder/base.vmdk', disk, 'snapshot-42']])
            end
            expected << [:images, [disk]] if workflow == :run_delta_conversion && prepared
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

    def assert_delta_cleanup(workflow, state_fields, remote_dir)
        with_prepared_delta(state_fields) do |vm, client, dir, state|
            # Snapshot cleanup must still run even when remote clone cleanup is skipped.
            client.expect(:snapshot_id_by_name, 7, [42, 'OneSwap prepare'])
            client.expect(:remove_snapshot_vm, true, [42, 7])
            client.expect(:remove_files, true, [remote_dir]) if remote_dir
            if workflow == :live2kvm_commit
                client.expect(:shutdown_vm, true, [42])
                state['disks'].each do |disk|
                    ['active_snapshot_descriptor', 'active_snapshot_extent'].each do |key|
                        source = "/vmfs/volumes/datastore/display-name/#{disk[key]}"
                        client.expect(:pull_files, true, [source, state['transfer_dir']])
                    end
                    client.expect(:apply_vmdk_snapshot_to_raw, true, [
                        File.join(state['transfer_dir'], disk['active_snapshot_extent']),
                        disk['converted_raw_base_path']
                    ])
                    client.expect(:os_morph, true, [disk['converted_raw_base_path'],
                                                  ESXi::VirtualMachine::VIRT_V2V_OPTIONS_EXTRA])
                end
                vm.define_singleton_method(:refresh_vmx) do
                    @vmx = { 'scsi0:0.fileName' => 'base.vmdk' }
                end
            end
            capture_io do
                result = vm.public_send(workflow, dir)
                assert_equal workflow == :live2kvm_commit ? state['results_dir'] : true, result
            end
            refute_path_exists state['transfer_dir']
            if workflow == :live2kvm_commit
                assert_equal 'raw', File.read(File.join(state['results_dir'], 'disk0.raw'))
            end
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
            assert_delta_cleanup(workflow, {}, '/vmfs/volumes/datastore/display-name/vmkfstools_output')
        end
    end

    def test_commit_and_cleanup_safely_skip_nil_or_empty_clone_directory
        [:live2kvm_commit, :live2kvm_cleanup].each do |workflow|
            [nil, ''].each do |clone_dir|
                assert_delta_cleanup(workflow, { 'clone_dir' => clone_dir }, nil)
            end
        end
    end

    def test_vddk_commit_failure_cleans_local_files_without_remote_clone_removal
        with_prepared_delta('transport' => 'vddk') do |vm, client, dir, state|
            client.expect(:shutdown_vm, false, [42])
            assert_equal false, vm.live2kvm_commit(dir)
            refute_path_exists state['transfer_dir']
        end
    end

    def test_legacy_prepare_retains_separate_transfer_and_conversion_metrics
        with_vddk_prepare('disk-000001.vmdk' => 'base.vmdk') do |vm, client, dir, clone_dir|
            transfer = File.join(dir, 'esxi_client-display-name')
            client.expect(:remove_files, true, [clone_dir])
            client.expect(:create_dir, true, [clone_dir])
            client.expect(:clone_virtual_disk, true, [
                '/vmfs/volumes/datastore/display-name/base.vmdk', "#{clone_dir}/base.vmdk"
            ])
            client.expect(:pull_files, true) do |source, destination|
                assert_equal "#{clone_dir}/*", source
                assert_equal transfer, destination
                File.write(File.join(destination, 'base.vmdk'), 'vmdk')
                true
            end
            client.expect(:convert_vmdk, true) do |source, destination, format|
                assert_equal File.join(transfer, 'base.vmdk'), source
                assert_equal File.join(transfer, 'convert/base.raw'), destination
                assert_equal 'raw', format
                File.write(destination, 'raw')
                true
            end
            state = nil
            capture_io { state = vm.live2kvm_prepare(dir) }
            assert_equal 'ssh', state['transport']
            assert_equal clone_dir, state['clone_dir']
            assert_equal 4, state['base_transfer_bytes']
            assert_equal 3, state['base_convert_bytes']
            ['base_transfer_seconds', 'base_convert_seconds',
             'base_transfer_mib_s', 'base_convert_mib_s'].each do |key|
                assert_operator state[key], :>, 0, key
            end
            assert_equal state, vm.live2kvm_state(dir)
        end
    end

    def assert_delta_dry_run_metrics(state, expected_rate, expected_source)
        Dir.mktmpdir('oneswap-estimate-test-') do |dir|
            h = helper(:work_dir => dir, :name => 'test-vm',
                       :dry_run_source_export_mib_s => 40,
                       :dry_run_qcow2_conversion_mib_s => 50,
                       :dry_run_delta_os_morph_seconds => 30,
                       :dry_run_guest_customization_seconds => 10)
            h.define_singleton_method(:get_esxi_host) { 'esxi.invalid' }
            h.define_singleton_method(:read_metrics) { {} }
            client = Minitest::Mock.new
            vm = Minitest::Mock.new
            # Run both the calculation and the full reporting entry point.
            2.times do
                client.expect(:get_vm_by_name, vm, ['test-vm'])
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
                assert_equal 80, info[:apply_rate]
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
        assert_delta_dry_run_metrics({
            'transport' => 'vddk', 'base_transfer_bytes' => nil,
            'base_transfer_seconds' => nil, 'base_transfer_mib_s' => nil,
            'base_convert_bytes' => 1024 * 1024, 'base_convert_seconds' => 0.0125,
            'base_convert_mib_s' => 80
        }, 40, :configured_fallback)
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

end
