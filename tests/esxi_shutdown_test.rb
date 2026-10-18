require 'minitest/autorun'
require 'minitest/mock'
require 'stringio'
require 'tmpdir'
require_relative '../esxi_vm'

class EsxiShutdownTest < Minitest::Test
    def build_vm(tools: true, states: ['Powered on', 'Powered off'], command_ok: true, summary: nil)
        commands = []
        unexpected_command = ->(command) { flunk "Unexpected command: #{command}" }
        summary ||= tools ? 'toolsStatus = "toolsOk", toolsRunningStatus = "guestToolsRunning"' :
                            'toolsStatus = "toolsNotInstalled", toolsRunningStatus = "guestToolsNotRunning"'
        client = ESXi::Client.allocate
        client.instance_variable_set(:@logger, Logger.new(StringIO.new))
        client.define_singleton_method(:vm_cmd) do |command|
            commands << command
            case command
            when 'get.summary 42'
                summary == :unreadable ? ['', 'connection lost', false] : [summary, '', true]
            when 'power.getstate 42'
                current = states.length > 1 ? states.shift : states.first
                [current, '', true]
            when 'power.shutdown 42', 'power.off 42'
                ['', '', command_ok]
            else
                unexpected_command.call(command)
            end
        end
        vm = ESXi::VirtualMachine.allocate
        vm.instance_variable_set(:@client, client)
        vm.instance_variable_set(:@logger, client.logger)
        vm.instance_variable_set(:@id, 42)
        vm.instance_variable_set(:@name, 'shutdown-test')
        [vm, client, commands]
    end

    def test_tools_available_selects_graceful_shutdown
        vm, _, commands = build_vm
        assert vm.shutdown
        assert_equal ['power.getstate 42', 'get.summary 42', 'power.shutdown 42', 'power.getstate 42'], commands
    end

    def test_tools_unavailable_preserves_hard_poweroff
        vm, _, commands = build_vm(:tools => false)
        assert vm.shutdown
        assert_equal ['power.getstate 42', 'get.summary 42', 'power.off 42', 'power.getstate 42'], commands
    end

    def test_running_tools_that_are_out_of_date_still_shut_the_guest_down
        vm, _, commands = build_vm(:summary => 'toolsStatus = "toolsOld", toolsRunningStatus = "guestToolsRunning"')
        assert vm.shutdown
        assert_equal ['power.getstate 42', 'get.summary 42', 'power.shutdown 42', 'power.getstate 42'], commands
    end

    def test_stopped_tools_do_not_lead_to_a_hard_poweroff
        # The guest may already be shutting down, e.g. from an earlier commit.
        vm, _, commands = build_vm(:summary => 'toolsStatus = "toolsNotRunning", ' \
                                               'toolsRunningStatus = "guestToolsNotRunning"')
        output, = capture_io { refute vm.shutdown }
        assert_equal ['power.getstate 42', 'get.summary 42'], commands
        assert_includes output, 'VMware Tools'
    end

    def test_unreadable_summary_powers_nothing_off
        vm, _, commands = build_vm(:summary => :unreadable)
        refute vm.shutdown
        assert_equal ['power.getstate 42', 'get.summary 42'], commands
    end

    def test_powered_off_vm_needs_no_shutdown
        vm, _, commands = build_vm(:states => ['Powered off'])
        assert vm.shutdown
        assert_equal ['power.getstate 42'], commands
    end

    def test_both_shutdown_modes_wait_for_confirmed_poweroff
        [true, false].each do |tools|
            vm, = build_vm(:tools => tools, :states => ['Powered on', 'Powered on', 'Powered on', 'Powered off'])
            sleeps = []
            vm.stub(:sleep, ->(seconds) { sleeps << seconds }) do
                assert vm.shutdown
            end
            assert_equal [5, 5], sleeps
        end
    end

    def test_timeout_aborts_delta_commit_without_hard_fallback
        vm, client, commands = build_vm(:states => ['Powered on'])
        now = 0.0
        Process.stub(:clock_gettime, ->(_clock) { now }) do
            vm.stub(:sleep, ->(seconds) { now += seconds }) do
                assert_commit_aborts(vm, client)
            end
        end
        assert_equal ESXi::VirtualMachine::SHUTDOWN_TIMEOUT, now
        assert_equal 1, commands.count('power.shutdown 42')
        refute_includes commands, 'power.off 42'
    end

    def test_command_failure_aborts_delta_commit
        vm, client, commands = build_vm(:command_ok => false)
        assert_commit_aborts(vm, client)
        assert_equal ['power.getstate 42', 'get.summary 42', 'power.shutdown 42'], commands
    end

    def test_unexpected_state_aborts_delta_commit
        vm, client, = build_vm(:states => ['Suspended'])
        assert_commit_aborts(vm, client)
    end

    def assert_commit_aborts(vm, client)
        Dir.mktmpdir('oneswap-shutdown-test-') do |convert_dir|
            # Pass the delta prechecks so these tests reach the real shutdown path.
            base = File.join(convert_dir, 'disk.raw')
            File.write(base, 'raw')
            prepared = {
                'transfer_dir' => '/unused/transfers',
                'convert_dir' => convert_dir,
                'results_dir' => '/unused/results',
                'disks' => [{ 'active_snapshot_descriptor' => 'disk.vmdk',
                              'active_snapshot_extent' => 'disk-delta.vmdk',
                              'converted_raw_base_path' => base }]
            }
            cleaned = []
            transfers = []
            vm.define_singleton_method(:storage_path) {|file| file }
            vm.define_singleton_method(:prepared_disks_changed) {|_state| nil }
            vm.define_singleton_method(:missing_commands) {|_commands| [] }
            client.define_singleton_method(:pull_files) {|*args| transfers << args }
            output = nil
            vm.stub(:read_live2kvm_state, prepared) do
                vm.stub(:live_storage_transfer_cleanup, ->(*args) { cleaned << args }) do
                    output, = capture_io { assert_equal false, vm.live2kvm_commit('/unused') }
                end
            end
            assert_empty transfers, 'Delta processing must not start'
            # The VM may still be running: the prepared base copies are kept.
            assert_empty cleaned
            assert_path_exists base
            assert_includes output, 'Delta commit failed: failed to shut down VM shutdown-test.'
            assert_includes output, 'still running'
        end
    end
end
