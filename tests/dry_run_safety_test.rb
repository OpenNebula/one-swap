# Unit-style checks for dry-run estimator and safety helpers.
# Run with: ruby tests/dry_run_safety_test.rb

require 'logger'
require 'minitest/autorun'
require 'tmpdir'

module OpenNebulaHelper
    class OneHelper; end
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
        end
        vm.define_singleton_method(:vddk_path) {|disk| calls << [:vddk_path, disk]; "[datastore] test-vm/#{disk}" }
        h = helper(:work_dir => '/tmp/work', :vddk_path => '/opt/vddk')
        h.define_singleton_method(:convert_vddk_disk) do |vddk_file, output_path|
            calls << [:convert_vddk, vddk_file, output_path]
            output_path
        end
        h.send(:prepare_delta_conversion, vm)
        assert_equal [
            [:prepare, '/tmp/work', true],
            [:vddk_path, 'base.vmdk'],
            [:convert_vddk, '[datastore] test-vm/base.vmdk', '/tmp/work/convert/disk0.raw']
        ], calls
        calls.clear
        helper(:work_dir => '/tmp/work').send(:prepare_delta_conversion, vm)
        assert_equal [[:prepare, '/tmp/work', false]], calls
    end

    def test_delta_prepare_with_zero_disks_cleans_snapshot_and_does_not_write_state
        calls = []
        vm = delta_vm
        [:live_storage_transfer_precheck, :vmwaretools?].each {|m| vm.define_singleton_method(m) { true } }
        vm.define_singleton_method(:create_snapshot) {|*| true }
        vm.define_singleton_method(:refresh_vmx) { true }
        vm.define_singleton_method(:active_disks) { [] }
        vm.define_singleton_method(:cleanup_snapshot) {|state| calls << [:snapshot, state['snapshot_name']] }
        vm.define_singleton_method(:live_storage_transfer_cleanup) {|dir, reason = nil| calls << [:cleanup, dir, reason] }
        vm.define_singleton_method(:write_live2kvm_state) { raise 'state should not be written' }

        result = vm.live2kvm_prepare('/tmp/work') { raise 'no disks should be converted' }

        assert_equal false, result
        assert_equal :snapshot, calls[-2][0]
        assert_equal [:cleanup, '/tmp/work/esxi_client-test-vm', 'no active disks detected for delta migration'], calls[-1]
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
end
