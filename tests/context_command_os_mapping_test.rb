# Unit-style checks for context package family selection.
# Run with: ruby tests/context_command_os_mapping_test.rb

require 'logger'
require 'minitest/autorun'
require 'ostruct'
require 'rexml/document'
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
            'redhat-based100'
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
