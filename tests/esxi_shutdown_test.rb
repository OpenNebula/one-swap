require 'minitest/autorun'
require 'minitest/mock'
require 'stringio'
require_relative '../esxi_vm'

class EsxiShutdownTest < Minitest::Test
    def build_vm(tools: true, states: ['Powered off'], command_ok: true)
        commands = []
        unexpected_command = ->(command) { flunk "Unexpected command: #{command}" }
        summary = tools ? 'toolsStatus = "toolsOk", toolsRunningStatus = "guestToolsRunning"' :
                          'toolsStatus = "toolsNotInstalled", toolsRunningStatus = "guestToolsNotRunning"'
        client = ESXi::Client.allocate
        client.instance_variable_set(:@logger, Logger.new(StringIO.new))
        client.define_singleton_method(:vm_cmd) do |command|
            commands << command
            case command
            when 'get.summary 42'
                [summary, '', true]
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
        assert_equal ['get.summary 42', 'power.shutdown 42', 'power.getstate 42'], commands
    end

    def test_tools_unavailable_preserves_hard_poweroff
        vm, _, commands = build_vm(:tools => false)
        assert vm.shutdown
        assert_equal ['get.summary 42', 'power.off 42', 'power.getstate 42'], commands
    end

    def test_both_shutdown_modes_wait_for_confirmed_poweroff
        [true, false].each do |tools|
            vm, = build_vm(:tools => tools, :states => ['Powered on', 'Powered on', 'Powered off'])
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
        assert_equal ['get.summary 42', 'power.shutdown 42'], commands
    end

    def test_unexpected_state_aborts_delta_commit
        vm, client, = build_vm(:states => ['Suspended'])
        assert_commit_aborts(vm, client)
    end

    def assert_commit_aborts(vm, client)
        prepared = {
            'transfer_dir' => '/unused/transfers',
            'convert_dir' => '/unused/conversions',
            'results_dir' => '/unused/results',
            'disks' => [{ 'active_snapshot_descriptor' => 'disk.vmdk',
                          'active_snapshot_extent' => 'disk-delta.vmdk' }]
        }
        cleaned = []
        vm.define_singleton_method(:storage_path) {|file| file }
        unexpected_transfer = ->(*) { flunk 'Delta processing must not start' }
        client.define_singleton_method(:pull_files, unexpected_transfer)
        vm.stub(:read_live2kvm_state, prepared) do
            vm.stub(:live_storage_transfer_cleanup, ->(*args) { cleaned << args }) do
                assert_equal false, vm.live2kvm_commit('/unused')
            end
        end
        assert_equal [['/unused/transfers', 'failed to shut down VM shutdown-test']], cleaned
    end
end
