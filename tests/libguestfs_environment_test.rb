# Run with: ruby tests/libguestfs_environment_test.rb
require 'logger'
require 'minitest/autorun'
require 'minitest/mock'
require 'ostruct'
require 'rbconfig'

module OpenNebulaHelper
    class OneHelper; end
end

module Kernel
    alias oneswap_libguestfs_original_require require

    def require(path)
        return true if ['one_helper', 'opennebula'].include?(path)

        oneswap_libguestfs_original_require(path)
    end
end

require_relative '../oneswap_helper'

class LibguestfsEnvironmentTest < Minitest::Test
    APPLIANCE = '/var/lib/one/fixed appliance'.freeze

    def helper(options = { :libguestfs_path => " #{APPLIANCE} " })
        OneSwapHelper.allocate.tap do |h|
            h.instance_variable_set(:@options, options)
            h.instance_variable_set(:@logger, Logger.new(File::NULL))
            h.define_singleton_method(:show_wait_spinner) {|&block| block.call }
        end
    end

    def status(ok = true)
        OpenStruct.new(:success? => ok, :signaled? => false, :exitstatus => ok ? 0 : 1)
    end

    def inspect_output(stdout, stderr = '', process_status = status)
        Open3.stub(:capture3, [stdout, stderr, process_status]) do
            helper.send(:detect_distro, '/tmp/disk')
        end
    end

    def test_inspector_receives_environment_and_preserves_no_os_result
        capture = lambda do |env, cmd|
            assert_equal({ 'LIBGUESTFS_PATH' => APPLIANCE }, env)
            assert_includes cmd, 'virt-inspector -a /tmp/disk'
            ['<operatingsystems/>', '', status]
        end
        original_env = ENV.to_h
        Open3.stub(:capture3, capture) do
            assert_nil helper.send(:detect_distro, '/tmp/disk')
        end
        assert_equal original_env, ENV.to_h
    end

    def test_inspector_nonzero_exit_preserves_stderr
        error = assert_raises(ConversionError) { inspect_output('', 'supermin failed', status(false)) }
        assert_includes error.message, '/tmp/disk'
        assert_includes error.message, 'exit status 1'
        assert_includes error.message, 'supermin failed'
    end

    def test_inspector_signal_failure
        st = OpenStruct.new(:success? => false, :signaled? => true, :termsig => 9)
        error = assert_raises(ConversionError) { inspect_output('', 'killed', st) }
        assert_includes error.message, 'signal 9'
    end

    def test_inspector_empty_output
        ['', " \n"].each do |output|
            error = assert_raises(ConversionError) { inspect_output(output) }
            assert_includes error.message, 'empty output'
        end
    end

    def test_inspector_malformed_xml
        error = assert_raises(ConversionError) { inspect_output('<operatingsystems><broken></operatingsystems>') }
        assert_includes error.message, 'invalid XML'
    end

    def test_inspector_missing_root
        error = assert_raises(ConversionError) { inspect_output('<?xml version="1.0"?><!-- no root -->') }
        assert_includes error.message, 'without a root'
    end

    def test_inspector_unexpected_root
        error = assert_raises(ConversionError) { inspect_output('<error/>') }
        assert_includes error.message, 'unexpected XML root'
    end

    def test_shared_runner_passes_environment_to_customize_and_guestfish
        ['virt-customize -a /tmp/disk --install pkg', 'guestfish -a /tmp/disk -i sync'].each do |command|
            capture = lambda do |env, cmd|
                assert_equal({ 'LIBGUESTFS_PATH' => APPLIANCE }, env)
                assert_equal command, cmd
                ['ok', '', status]
            end
            Open3.stub(:capture3, capture) do
                assert_equal 'ok', helper.send(:run_cmd_report, command, true).first
            end
        end
    end

    def test_timeout_runner_passes_environment_to_actual_child
        command = Shellwords.join([RbConfig.ruby, '-e', 'print ENV.fetch("LIBGUESTFS_PATH", "")'])
        output, st = helper.send(:run_cmd_report, command, true, :timeout => 5)
        assert st.success?
        assert_equal APPLIANCE, output
    end

    def test_blank_and_unset_options_preserve_inherited_environment
        [{}, { :libguestfs_path => nil }, { :libguestfs_path => " \n" }].each do |options|
            h = helper(options)
            assert_equal({}, h.send(:v2v_env))
            command = Shellwords.join([RbConfig.ruby, '-e', 'print ENV.fetch("LIBGUESTFS_PATH", "")'])
            [nil, 5].each do |timeout|
                output, st = h.send(:run_cmd_report, command, true, :timeout => timeout)
                assert st.success?
                assert_equal ENV.fetch('LIBGUESTFS_PATH', ''), output
            end
        end
    end

    def test_direct_guestfish_and_registry_calls_receive_environment
        h = helper
        capture = lambda do |env, cmd|
            assert_equal({ 'LIBGUESTFS_PATH' => APPLIANCE }, env)
            assert_match(/\A(?:guestfish|virt-win-reg)\b/, cmd)
            ['', '', status]
        end
        Open3.stub(:capture3, capture) do
            h.send(:guest_root_free_mb, '/tmp/disk', { 'mounts' => { '/' => '/dev/sda1' } })
            h.send(:guest_run_cmd, '/tmp/disk', 'sync')
            h.send(:windows_control_sets_for_disk, '/tmp/disk')
            h.send(:disable_vmtools_via_virt_win_reg, '/tmp/disk')
            h.send(:disable_vmtools_via_guestfish, '/tmp/disk')
        end
    end

    def test_delta_morph_receives_environment_without_changing_ssh_environment
        [{ :libguestfs_path => APPLIANCE }, {}].each do |options|
            h = helper(options)
            client_class = Class.new(ESXi::Client) do
                def authenticate!; end
                def dependency_precheck; end
            end
            client = client_class.new('host', Logger.new(File::NULL), h.send(:esxi_client_options))
            execution = lambda do |cmd, _message, env|
                assert_includes cmd, 'virt-v2v-in-place -i disk /tmp/disk'
                assert_equal h.send(:v2v_env), env
                true
            end
            client.stub(:live_execution, execution) do
                assert client.os_morph('/tmp/disk')
            end
            assert_equal({}, client.instance_variable_get(:@ssh_env))
        end
    end
end
