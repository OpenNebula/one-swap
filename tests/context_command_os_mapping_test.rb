# Unit-style checks for context package family selection.
# Run with: ruby tests/context_command_os_mapping_test.rb

require 'logger'
require 'minitest/autorun'
require 'ostruct'
require 'rexml/document'
require 'shellwords'
require 'tmpdir'

module OpenNebulaHelper
    class OneHelper; end
end

module Kernel
    alias oneswap_context_mapping_original_require require

    def require(path)
        return true if ['one_helper', 'opennebula'].include?(path)

        oneswap_context_mapping_original_require(path)
    end
end

require_relative '../oneswap_helper'

class ContextCommandOsMappingTest < Minitest::Test
    def helper
        OneSwapHelper.allocate.tap do |h|
            h.instance_variable_set(:@options, {
                :inject_dns => false
            })
            h.instance_variable_set(:@logger, Logger.new(File::NULL))
        end
    end

    def assert_context_family(osinfo_id, expected_family, message = nil)
        assert_context_family_for({
            'name' => 'linux',
            'os' => osinfo_id
        }, expected_family, message)
    end

    def assert_context_family_for(osinfo, expected_family, message = nil)
        h = helper
        detected = []
        h.define_singleton_method(:detect_context_package) do |family|
            detected << family
            "/tmp/one-context-#{family}.pkg"
        end

        cmd, fallback_cmd = h.send(:context_command, '/tmp/disk.qcow2', osinfo)

        assert_equal [expected_family], detected, message
        assert_includes cmd, "/tmp/one-context-#{expected_family}.pkg", message
        assert_includes fallback_cmd, "/tmp/one-context-#{expected_family}.pkg", message

        [cmd, fallback_cmd]
    end

    def test_direct_mappings
        cases = [
            ['almalinux8', 'rhel8'],
            ['rocky8', 'rhel8'],
            ['ol8.8', 'rhel8'],
            ['centos-stream8', 'rhel8'],
            ['almalinux9', 'rhel9'],
            ['rocky9', 'rhel9'],
            ['ol9.4', 'rhel9'],
            ['centos-stream9', 'rhel9'],
            ['rhel10', 'rhel10'],
            ['almalinux10', 'rhel10'],
            ['rocky10', 'rhel10'],
            ['ol10', 'rhel10'],
            ['redhat-based10', 'rhel10'],
            ['redhat-based10.2', 'rhel10'],
            ['debian12', 'debian'],
            ['ubuntu24.04', 'debian'],
            ['ubuntu26.04', 'debian'],
            ['rhel8.10', 'rhel8'],
            ['rhel9.4', 'rhel9'],
            ['opensuse15.6', 'opensuse'],
            ['sles15.6', 'opensuse'],
            ['sled12', 'opensuse']
        ]

        cases.each do |osinfo_id, expected_family|
            msg = "#{osinfo_id.inspect} should map to #{expected_family.inspect}"
            assert_context_family(osinfo_id, expected_family, msg)
        end
    end

    def test_el8_el9_and_el10_install_local_context_without_epel
        {
            'rhel8' => %w[rhel8.10 rocky8 almalinux8 ol8.8 centos-stream8 redhat-based8],
            'rhel9' => %w[rhel9.4 rocky9 almalinux9 ol9.4 centos-stream9 redhat-based9],
            'rhel10' => %w[rhel10 rocky10 almalinux10 ol10 redhat-based10]
        }.each do |family, osinfo_ids|
            osinfo_ids.each do |osinfo_id|
                cmd, fallback_cmd = assert_context_family(osinfo_id, family)
                package = "/tmp/one-context-#{family}.pkg"

                refute_includes cmd, 'https://dl.fedoraproject.org/pub/epel/', osinfo_id
                refute_includes cmd, 'epel-release', osinfo_id
                refute_includes fallback_cmd, 'epel-release', osinfo_id
                assert_includes cmd, " --copy-in #{package}:/tmp", osinfo_id
                args = dnf_install_args(cmd)
                assert_equal ['dnf', '-y'], args.first(2), osinfo_id
                refute_includes cmd, '--disablerepo', osinfo_id
                dnf_options.each {|option| assert_includes args, option, osinfo_id }
                assert_includes args, '--setopt=strict=True', osinfo_id
                assert_equal ['install', package], args.last(2), osinfo_id
                refute_includes cmd, 'subscription-manager', osinfo_id
                refute_includes Shellwords.split(cmd), '--install', osinfo_id
                refute_includes cmd, 'codeready-builder', osinfo_id
                refute_includes cmd, 'subscription-manager repos', osinfo_id
                assert_includes fallback_cmd, " --copy-in #{package}:/tmp", osinfo_id
                assert_equal args, dnf_install_args(fallback_cmd, '--firstboot-command'), osinfo_id
                refute_includes fallback_cmd, '--disablerepo', osinfo_id
                refute_includes fallback_cmd, 'subscription-manager', osinfo_id
            end
        end
    end

    def test_custom_context_directory_for_el8_el9_and_el10
        Dir.mktmpdir do |dir|
            [8, 9, 10].each do |version|
                File.write(File.join(dir, "one-context-7.4.0-0.el#{version}.noarch.rpm"), '')
            end

            h = helper
            h.instance_variable_get(:@options)[:context] = dir

            [8, 9, 10].each do |version|
                basename = "one-context-7.4.0-0.el#{version}.noarch.rpm"
                cmd, fallback_cmd = h.send(:context_command, '/tmp/disk.qcow2', {
                    'name' => 'linux', 'os' => "rhel#{version}"
                })

                [cmd, fallback_cmd].each do |command|
                    assert_includes command, " --copy-in #{File.join(dir, basename)}:/tmp"
                    refute_includes command, 'epel-release'
                    refute_includes command, 'https://dl.fedoraproject.org/pub/epel/'
                end
                assert_equal ['install', "/tmp/#{basename}"], dnf_install_args(cmd).last(2)
                assert_equal dnf_install_args(cmd), dnf_install_args(fallback_cmd, '--firstboot-command')
            end
        end
    end

    def dnf_options
        %w[--setopt=strict=True --setopt=timeout=3 --setopt=*.timeout=3
           --setopt=retries=1 --setopt=skip_if_unavailable=True
           --setopt=*.skip_if_unavailable=True --setopt=install_weak_deps=False]
    end

    def guest_install_command(command, flag = '--run-command')
        args = Shellwords.split(command)
        args.fetch(args.index(flag) + 1)
    end

    def dnf_install_args(command, flag = '--run-command')
        Shellwords.split(guest_install_command(command, flag))
    end

    def test_non_el_recommendation_suppression
        # Alias selection is covered by test_direct_mappings; exercise each builder once.
        { 'fedora42' => ['fedora', 'dnf', '--setopt=install_weak_deps=False'],
          'debian12' => ['debian', 'apt-get', '--no-install-recommends'],
          'opensuse15.6' => ['opensuse', 'zypper', '--no-recommends'] }.each do |os, (family, manager, option)|
            primary, fallback = assert_context_family(os, family)
            guest = guest_install_command(primary)
            assert_equal guest, guest_install_command(fallback, '--firstboot-command')
            assert_includes guest, manager
            assert_includes Shellwords.split(guest), option
            refute_includes Shellwords.split(primary), '--install'
            refute_includes Shellwords.split(fallback), '--firstboot-install'
            assert_includes Shellwords.split(primary), '--delete'
            refute_includes Shellwords.split(fallback), '--delete'
            if family == 'debian'
                assert_includes guest, 'export DEBIAN_FRONTEND=noninteractive'
                assert_includes guest, 'update; apt-get'
                assert_includes Shellwords.split(guest), 'Dpkg::Options::=--force-confnew'
                assert_includes primary, '--uninstall cloud-init'
            elsif family == 'fedora'
                assert_includes Shellwords.split(guest), '--setopt=skip_if_unavailable=True'
            else
                assert_equal ['zypper', '-n', 'in', '-l', '--no-recommends',
                              '/tmp/one-context-opensuse.pkg'], Shellwords.split(guest)
            end
        end
    end

    def test_alt_commands_remain_unchanged
        primary, fallback = assert_context_family('alt10', 'alt')
        assert_includes primary, ' --install /tmp/one-context-alt.pkg'
        assert_includes fallback, ' --firstboot-install /tmp/one-context-alt.pkg'
        refute_includes primary, '--no-install-recommends'
        refute_includes fallback, '--no-install-recommends'
    end

    def test_apt_invocations_and_final_install_status
        Dir.mktmpdir('apt harness ') do |dir|
            # An executable on PATH works with /bin/sh without nonportable
            # hyphenated shell function names. NULs preserve argument boundaries.
            executable = File.join(dir, 'apt-get')
            File.write(executable, <<~'SH')
                #!/bin/sh
                printf '%s\0' "$DEBIAN_FRONTEND" "$@"
                printf '\0'
                case " $* " in
                    *" update "*) exit "$REFRESH_STATUS" ;;
                    *) exit "$INSTALL_STATUS" ;;
                esac
            SH
            File.chmod(0755, executable)

            h = helper
            package = %q(/custom context/one-context '";$(printf INJECTED)*%.deb)
            h.define_singleton_method(:detect_context_package) {|_| package }
            primary, fallback = h.context_command('/disk', { 'name' => 'linux', 'os' => 'debian12' })
            apt_options = ['-q', '-y', '-o', 'Dpkg::Options::=--force-confnew']
            expected = [
                ['noninteractive'] + apt_options + ['update'],
                ['noninteractive'] + apt_options +
                    ['--no-install-recommends', 'install', "/tmp/#{File.basename(package)}"]
            ]

            [[primary, '--run-command'], [fallback, '--firstboot-command']].each do |cmd, flag|
                [0, 100].product([0, 42]).each do |refresh_status, install_status|
                    env = {
                        'PATH' => dir,
                        'DEBIAN_FRONTEND' => 'interactive',
                        'REFRESH_STATUS' => refresh_status.to_s,
                        'INSTALL_STATUS' => install_status.to_s
                    }
                    output, error, status = Open3.capture3(
                        env, '/bin/sh', '-c', guest_install_command(cmd, flag))
                    label = "#{flag}: refresh=#{refresh_status}, install=#{install_status}"
                    assert_equal expected, output.split("\0\0").map {|call| call.split("\0") }, label
                    assert_equal install_status, status.exitstatus, "#{label}: #{error}"
                end
            end
        end
    end

    def test_context_install_command_rejects_unsupported_family
        error = assert_raises(ArgumentError) do
            helper.context_install_command('unknown', '/tmp/context.rpm')
        end
        assert_includes error.message, 'unknown'
    end

    def test_explicit_qemu_ga_is_independent_of_context_recommendations
        # package_injection is distro-independent; command families are tested separately.
        [false, true].each do |enabled|
            [false, true].each do |offline_failure|
                h = helper
                h.instance_variable_get(:@options).merge!(
                    :qemu_ga_linux => enabled, :context_timeout => 123)
                h.define_singleton_method(:detect_context_package) {|_| '/tmp/context.pkg' }
                h.define_singleton_method(:ensure_guest_free_space) {|*_| true }
                calls = []
                h.define_singleton_method(:run_cmd_report) do |cmd, out = false, timeout: nil|
                    calls << [cmd, out, timeout]
                    ['', OpenStruct.new(:success? => !(offline_failure && calls.length == 1))]
                end
                capture_io { h.package_injection('/disk', { 'name' => 'linux', 'os' => 'rocky9' }) }
                context_calls = calls.reject {|cmd, _, _| cmd.include?('--install qemu-guest-agent') }
                assert_equal offline_failure ? 2 : 1, context_calls.length
                context_calls.each do |cmd, _, timeout|
                    assert_match(/install_weak_deps|no-install-recommends|no-recommends/, cmd)
                    assert_equal 123, timeout
                end
                agent_calls = calls - context_calls
                assert_equal enabled ? 1 : 0, agent_calls.length
                if enabled
                    assert_equal ['virt-customize -a /disk --install qemu-guest-agent', false, 123],
                                 agent_calls.first
                end
            end
        end
    end

    def test_non_el_paths_are_quoted_for_both_shells
        { 'fedora42' => 'dnf', 'debian12' => 'apt-get',
          'opensuse15.6' => 'zypper' }.each do |os, manager|
            h = helper
            package = %q(/custom context/one-context '";$(printf INJECTED)*%.pkg)
            h.define_singleton_method(:detect_context_package) {|_| package }
            primary, fallback = h.context_command('/disk', { 'name' => 'linux', 'os' => os })
            [[primary, '--run-command'], [fallback, '--firstboot-command']].each do |cmd, flag|
                output, error, status = Open3.capture3('sh', '-c', "set -- #{cmd}; printf '%s\\n' \"$@\"")
                assert status.success?, error
                args = output.lines.map(&:chomp)
                assert_equal "#{package}:/tmp", args[args.index('--copy-in') + 1]
                guest = args[args.index(flag) + 1]
                # Stub the guest manager, including apt's metadata refresh.
                script = "#{manager}() { printf '%s\\n' \"$DEBIAN_FRONTEND\" \"$@\"; }; #{guest}"
                output, error, status = Open3.capture3('bash', '-c', script)
                assert status.success?, error
                assert_equal "/tmp/#{File.basename(package)}", output.lines.last.chomp
                assert_includes output.lines.map(&:chomp), 'noninteractive' if manager == 'apt-get'
            end
        end
    end

    def test_el_context_package_path_is_quoted_for_host_and_guest_shells
        Dir.mktmpdir('custom context ') do |dir|
            basename = %q(one-context-7.4.0-0.el9 '";$(printf INJECTED)*%.rpm)
            package = File.join(dir, basename)
            File.write(package, '')
            h = helper
            h.instance_variable_get(:@options)[:context] = dir
            cmd, fallback_cmd = h.send(:context_command, '/tmp/disk.qcow2', {
                'name' => 'linux', 'os' => 'rocky9'
            })

            # Parse through a real host shell without running virt-customize.
            stdout, stderr, status = Open3.capture3('sh', '-c', "set -- #{cmd}; printf '%s\\n' \"$@\"")
            assert status.success?, stderr
            args = stdout.lines.map(&:chomp)
            assert_equal "#{package}:/tmp", args[args.index('--copy-in') + 1]
            assert_equal "/tmp/#{basename}", args[args.index('--delete') + 1]
            guest_cmd = args[args.index('--run-command') + 1]
            # Replace DNF with an argument printer; no installation is performed.
            stdout, stderr, status = Open3.capture3('sh', '-c', "dnf() { printf '%s\\n' \"$@\"; }; #{guest_cmd}")
            assert status.success?, stderr
            assert_equal ['-y'] + dnf_options + ['install', "/tmp/#{basename}"],
                         stdout.lines.map(&:chomp)
            fallback_args = Shellwords.split(fallback_cmd)
            assert_equal "#{package}:/tmp", fallback_args[fallback_args.index('--copy-in') + 1]
            assert_equal guest_cmd, fallback_args[fallback_args.index('--firstboot-command') + 1]
        end
    end

    def test_dnf_network_options_and_shell_quoting
        %w[rocky8 rocky9 rocky10 rhel8.10 rhel9.4 rhel10].each do |os|
            h = helper
            package = %q(/custom context/one-context '"*$(echo bad).rpm)
            h.define_singleton_method(:detect_context_package) {|_| package }
            primary, fallback = h.context_command('/disk', { 'name' => 'linux', 'os' => os })
            args = dnf_install_args(primary)
            %w[--setopt=strict=True --setopt=timeout=3 --setopt=*.timeout=3 --setopt=retries=1
               --setopt=skip_if_unavailable=True --setopt=*.skip_if_unavailable=True].each do |arg|
                assert_includes args, arg
            end
            refute_includes primary, '--disablerepo'
            refute_includes primary, '--disableplugin'
            [primary, fallback].each do |command|
                refute_match(/epel-release|codeready-builder|subscription-manager repos/, command)
            end
            guest = Shellwords.split(primary)[Shellwords.split(primary).index('--run-command') + 1]
            output, error, status = Open3.capture3('sh', '-c', "dnf() { printf '%s\\n' \"$@\"; }; #{guest}")
            assert status.success?, error
            assert_equal args.drop(1), output.lines.map(&:chomp)
            assert_equal "/tmp/#{File.basename(package)}", args.last
        end
    end

    def test_el10_fallback_mappings
        [nil, '', 'unknown', 'redhat-based'].each do |osinfo_id|
            osinfo = {
                'name' => 'linux', 'os' => osinfo_id, 'distro' => 'redhat-based',
                'major_version' => '10'
            }

            assert_context_family_for(osinfo, 'rhel10', "#{osinfo.inspect} should map to \"rhel10\"")
        end
    end

    def test_unknown_os_returns_false_without_package_lookup
        h = helper
        h.define_singleton_method(:detect_context_package) do |family|
            raise "unexpected package lookup for #{family}"
        end

        assert_equal false, h.send(:context_command, '/tmp/disk.qcow2', {
            'name' => 'linux',
            'os' => 'unknownos1'
        })
    end

    def test_unsupported_cases_return_false_without_package_lookup
        string_cases = [
            'centos-stream10',
            'redhat-based100', 'amazon2', 'amazon2023', 'amzn2', 'amzn2023', 'alpine3.22'
        ]
        osinfo_cases = [
            {
                'name' => 'linux', 'os' => nil, 'distro' => 'redhat-based',
                'major_version' => '9'
            },
            {
                'name' => 'linux', 'os' => nil, 'distro' => 'redhat-based',
                'major_version' => '11'
            },
            {
                'name' => 'linux', 'os' => nil, 'distro' => 'unknown',
                'major_version' => '10'
            }
        ]

        string_cases.each do |osinfo_id|
            msg = "#{osinfo_id.inspect} should return false without package lookup"
            assert_unknown_os_without_package_lookup(osinfo_id, msg)
        end
        osinfo_cases.each do |osinfo|
            msg = "#{osinfo.inspect} should return false without package lookup"
            assert_unsupported_osinfo_without_package_lookup(osinfo, msg)
        end
    end

    def test_detect_distro_stores_major_version
        h = helper
        h.define_singleton_method(:show_wait_spinner) {|&block| block.call }
        xml = <<~XML
            <operatingsystems>
              <operatingsystem>
                <name>linux</name>
                <distro>redhat-based</distro>
                <major_version>10</major_version>
                <package_format>rpm</package_format>
                <osinfo/>
                <mountpoints>
                  <mountpoint dev="/dev/sda1">/</mountpoint>
                </mountpoints>
                <product_name>AlmaLinux release 10.2</product_name>
              </operatingsystem>
            </operatingsystems>
        XML

        original_capture2 = Open3.method(:capture2)
        Open3.define_singleton_method(:capture2) do |_cmd|
            [xml, OpenStruct.new(:success? => true)]
        end

        osinfo = h.send(:detect_distro, '/tmp/disk.qcow2')

        assert_equal '10', osinfo['major_version']
    ensure
        Open3.define_singleton_method(:capture2, original_capture2)
    end

    def test_rhel10_package_selection_uses_el10_rpm_pattern
        Dir.mktmpdir do |dir|
            package = File.join(dir, 'one-context-7.2.1-0.el10.noarch.rpm')
            File.write(package, '')

            h = helper
            h.instance_variable_set(:@options, {
                :context => dir,
                :inject_dns => false
            })

            assert_equal package, h.send(:detect_context_package, 'rhel10')
        end
    end

    def assert_unknown_os_without_package_lookup(osinfo_id, message = nil)
        assert_unsupported_osinfo_without_package_lookup({
            'name' => 'linux',
            'os' => osinfo_id
        }, message)
    end

    def assert_unsupported_osinfo_without_package_lookup(osinfo, message = nil)
        h = helper
        h.define_singleton_method(:detect_context_package) do |family|
            raise "unexpected package lookup for #{family}"
        end

        assert_equal false, h.send(:context_command, '/tmp/disk.qcow2', osinfo), message
    end

end
