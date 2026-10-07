# Run with: ruby tests/libguestfs_environment_test.rb
require 'logger'
require 'minitest/autorun'
require 'minitest/mock'
require 'ostruct'
require 'rbconfig'
require 'stringio'
require 'timeout'

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
            h.send(:guest_run_cmd, '/tmp/disk', 'sync')
            h.send(:windows_control_sets_for_disk, '/tmp/disk')
            h.send(:disable_vmtools_via_virt_win_reg, '/tmp/disk')
            h.send(:disable_vmtools_via_guestfish, '/tmp/disk')
        end
    end

    def test_guest_root_free_space_receives_environment
        capture = lambda do |env, cmd|
            assert_equal({ 'LIBGUESTFS_PATH' => APPLIANCE }, env)
            assert_includes cmd, 'statvfs /'
            ["bsize: 4096\nfrsize: 4096\nbavail: 512\n", '', status]
        end
        Open3.stub(:capture3, capture) do
            assert_equal 2, helper.send(:guest_root_free_mb, '/tmp/disk',
                                      { 'mounts' => { '/' => '/dev/sda1' } })
        end
    end

    def test_spinner_joins_thread_when_block_raises
        h = helper
        h.singleton_class.send(:remove_method, :show_wait_spinner)
        spinner = nil
        threads_before = Thread.list
        capture_io do
            error = assert_raises(RuntimeError) do
                h.send(:show_wait_spinner, 1000) do
                    spinner = (Thread.list - threads_before).first
                    assert spinner.alive?
                    raise 'inspection failed'
                end
            end
            assert_equal 'inspection failed', error.message
        end
        refute spinner.alive?
        assert_equal false, spinner.status
        capture_io { assert_equal :result, h.send(:show_wait_spinner, 1000) { :result } }
    ensure
        spinner.kill.join if spinner && spinner.alive?
    end

    def test_successful_block_and_spinner_preserve_return_value
        assert_spinner_outcome(nil, nil)
    end

    def test_failing_block_and_successful_spinner_preserve_block_exception
        assert_spinner_outcome(ArgumentError.new('operation failed'), nil)
    end

    def test_successful_block_and_failing_spinner_propagate_spinner_exception
        assert_spinner_outcome(nil, IOError.new('spinner output failed'))
    end

    def test_failing_block_and_spinner_preserve_original_block_exception
        assert_spinner_outcome(ArgumentError.new('operation failed'), IOError.new('spinner output failed'))
    end

    def test_interrupted_join_after_success_stops_spinner_before_raising
        assert_interrupted_spinner_cleanup(nil)
    end

    def test_interrupted_join_preserves_operation_error_after_stopping_spinner
        assert_interrupted_spinner_cleanup(ArgumentError.new('operation failed'))
    end

    def test_repeated_interruptions_do_not_escape_before_spinner_stops
        assert_interrupted_spinner_cleanup(nil, true)
    end

    def test_repeated_interruptions_preserve_original_operation_error
        assert_interrupted_spinner_cleanup(ArgumentError.new('operation failed'), true)
    end

    def assert_interrupted_spinner_cleanup(operation_error, interrupt_again = false)
        h = helper
        h.singleton_class.send(:remove_method, :show_wait_spinner)
        started = Queue.new
        joining = Queue.new
        stopping = Queue.new
        finish_stopping = Queue.new
        blocked_output = Queue.new
        result = Queue.new
        spinner = nil
        h.define_singleton_method(:print) do |_text|
            started << Thread.current
            begin
                blocked_output.pop
            ensure
                stopping << true
                finish_stopping.pop
            end
        end
        caller = Thread.new do
            begin
                h.send(:show_wait_spinner) do
                    spinner = started.pop
                    spinner.define_singleton_method(:join) do |*args|
                        joining << true
                        super(*args)
                    end
                    raise operation_error if operation_error

                    :result
                end
                result << [:returned, spinner.alive?]
            rescue Exception => error
                result << [error, spinner.alive?]
            end
        end
        interruption = Interrupt.new('interrupted join')
        Timeout.timeout(5) do
            joining.pop
            Thread.pass until caller.status == 'sleep'
            caller.raise(interruption)
            stopping.pop
            caller.raise(Interrupt.new('interrupted again')) if interrupt_again
            finish_stopping << true
            error, alive_at_exit = result.pop
            assert_same operation_error || interruption, error
            refute alive_at_exit
            caller.join
            refute spinner.alive?
        end
    ensure
        # Unblock test-owned waits even when an assertion or timeout fails.
        finish_stopping << true if finish_stopping
        blocked_output << true if blocked_output
        caller.kill.join if caller && caller.alive?
        spinner.kill.join if spinner && spinner.alive?
    end

    def assert_spinner_outcome(operation_error, spinner_error)
        h = helper
        h.singleton_class.send(:remove_method, :show_wait_spinner)
        started = Queue.new
        output = []
        spinner = nil
        h.define_singleton_method(:print) do |text|
            # The test observes worker failures through join, not stderr.
            Thread.current.report_on_exception = false
            output << text
            started << Thread.current if output.length == 1
            raise spinner_error if spinner_error
        end
        operation = lambda do
            h.send(:show_wait_spinner, 1000) do
                spinner = started.pop
                raise operation_error if operation_error

                :result
            end
        end

        expected_error = operation_error || spinner_error
        if expected_error
            actual_error = assert_raises(expected_error.class, &operation)
            assert_same expected_error, actual_error
        else
            assert_equal :result, operation.call
        end
        refute spinner.alive?
        if spinner_error
            assert_nil spinner.status
        else
            assert_equal false, spinner.status
        end
        assert_equal '/', output.first
        assert_equal "\b", output.last unless spinner_error
    ensure
        spinner.kill.join if spinner && spinner.alive?
    end

    def test_successful_inspection_logs_stderr
        h = helper
        messages = []
        h.instance_variable_get(:@logger).stub(:debug, ->(message) { messages << message }) do
            Open3.stub(:capture3, ['<operatingsystems/>', 'inspection warning', status]) do
                assert_nil h.send(:detect_distro, '/tmp/disk')
            end
        end
        assert_equal ['inspection warning'], messages
    end

    def test_prechecks_use_effective_environment
        [[{}, { :libguestfs_path => APPLIANCE }],
         [{ 'LIBGUESTFS_PATH' => '/exported' }, {}],
         [{ 'LIBGUESTFS_PATH' => '/exported' }, { :libguestfs_path => APPLIANCE }]].each do |exported, options|
            h = helper(options)
            ENV.stub(:to_h, exported) do
                Process.stub(:uid, 1000) do
                    File.stub(:readable?, false) do
                        out, err = capture_io do
                            refute h.send(:warn_if_wof_support_missing, :overlay_globs => [])
                            h.send(:warn_unreadable_kernel_for_libguestfs, h.send(:v2v_env))
                        end
                        assert_empty out
                        assert_empty err
                    end
                end
            end
        end
        # An empty exported value must not override a configured appliance.
        h = helper
        refute h.send(:warn_if_wof_support_missing, :env => { 'LIBGUESTFS_PATH' => '' },
                      :overlay_globs => [])
    end

    def test_prechecks_prefer_yaml_path_over_exported_path
        h = helper
        used = []
        configured_path = Object.new
        configured_path.define_singleton_method(:to_s) { used << :yaml; APPLIANCE }
        h.stub(:v2v_env, { 'LIBGUESTFS_PATH' => configured_path }) do
            ENV.stub(:to_h, { 'LIBGUESTFS_PATH' => '/exported' }) do
                Process.stub(:uid, 1000) do
                    refute h.send(:warn_if_wof_support_missing, :overlay_globs => [])
                    h.send(:warn_unreadable_kernel_for_libguestfs, h.send(:v2v_env))
                end
            end
        end
        assert_equal [:yaml, :yaml], used
    end

    def test_inspection_failure_retains_fallback_and_hybrid_behavior
        [:fallback, :hybrid, :disabled, :fatal].each do |mode|
            h = helper(:name => 'vm', :work_dir => '/unused')
            h.instance_variable_set(:@props, { 'config' => { :guestFullName => 'Linux' } })
            # Enable hybrid after command construction to exercise its rescue branch
            # without involving the downloader or filesystem.
            h.define_singleton_method(:build_v2v_vc_cmd) do
                @options[mode] = true if [:fallback, :hybrid].include?(mode)
                @options[:fallback] = true if mode == :fatal
                'virt-v2v'
            end
            h.define_singleton_method(:warn_unreadable_kernel_for_libguestfs) { |_env| }
            h.define_singleton_method(:create_one_images) do |_disks|
                raise ConversionError, 'fatal' if mode == :fatal
                detect_distro('/tmp/disk')
            end
            cleaned = false
            h.define_singleton_method(:cleanup_disks) { cleaned = true }
            h.define_singleton_method(:run_custom_conversion) { :custom }
            streams = [StringIO.new, StringIO.new, StringIO.new, OpenStruct.new(:value => 0)]
            Open3.stub(:popen3, streams) do
                Dir.stub(:glob, ['/tmp/disk']) do
                    Open3.stub(:capture3, ['', 'supermin failed', status(false)]) do
                        if [:fallback, :hybrid].include?(mode)
                            assert_equal :custom, h.send(:run_v2v_conversion)
                            assert_equal mode == :fallback, cleaned
                        else
                            error = assert_raises(ConversionError) { h.send(:run_v2v_conversion) }
                            assert_includes error.message, mode == :fatal ? 'fatal' : 'supermin failed'
                        end
                    end
                end
            end
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
