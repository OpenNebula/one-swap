# Unit-style checks for dry-run estimator and safety helpers.
# Run with: ruby tests/dry_run_safety_test.rb

require 'logger'
require 'minitest/autorun'

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
end
