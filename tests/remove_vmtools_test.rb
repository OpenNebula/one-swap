# Unit tests for the VMware Tools removal flow
# Run with: ruby tests/remove_vmtools_test.rb

require 'minitest/autorun'

class RemoveVmtoolsTest < Minitest::Test
    def test_windows_removal_uses_explicit_powershell_command
        source = File.read(File.expand_path('../oneswap_helper.rb', __dir__))

        assert_includes source, 'def remove_vmtools_command(disk, osinfo, script_path)'
        assert_includes source, '--copy-in'
    end

    def test_offline_service_disable_uses_virt_win_reg
        source = File.read(File.expand_path('../oneswap_helper.rb', __dir__))

        assert_includes source, 'def disable_vmtools_services_offline(disk)'
        assert_includes source, 'virt-win-reg --merge'
        assert_includes source, 'VMTOOLS_SERVICES_TO_DISABLE'
        assert_includes source, 'VMTOOLS_CONTROL_SETS'
        assert_includes source, 'VMTools'
        assert_includes source, 'VGAuthService'
        assert_includes source, 'ControlSet001'
        assert_includes source, 'ControlSet002'
        assert_includes source, 'dword:00000004'
        assert_includes source, 'disable_vmtools_services_offline(disk) if osinfo'
    end

    def test_windows_script_tries_msi_uninstall_and_logs
        source = File.read(File.expand_path('../scripts/vmware_tools_removal.ps1', __dir__))

        assert_includes source, 'vmware_tools_removal.log'
        assert_includes source, 'Get-VMwareToolsInstallerEntry'
        assert_includes source, 'msiexec.exe'
        assert_includes source, 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*'
        assert_includes source, 'Stop-VMwareToolsProcesses'
    end
end
