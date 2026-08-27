# Unit-style checks for the NetApp Shift conversion mode in oneswap_helper.rb.
# Run with: ruby tests/netapp_shift_mode_test.rb

require 'fileutils'
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

# Minimal stand-in for Process::Status
FakeStatus = Struct.new(:ok) do
    def success?
        ok
    end
end

class NetAppShiftModeTest < Minitest::Test

    def helper(options = {})
        OneSwapHelper.allocate.tap do |h|
            h.instance_variable_set(:@options, options)
            h.instance_variable_set(:@logger, Logger.new(File::NULL))
        end
    end

    # Helper wired for run_shift_conversion: n vCenter disks, quiet preflight,
    # captured commands and imports. Returns [helper, commands, imported].
    def conversion_helper(mount, work_dir, disk_count, options = {})
        h = helper({ :name        => 'web01',
                     :shift       => 'https://shift.local',
                     :shift_mount => mount,
                     :work_dir    => work_dir }.merge(options))

        commands = []
        imported = nil

        h.define_singleton_method(:local_path_image_allocation_preflight!) { nil }
        h.define_singleton_method(:warn_unreadable_kernel_for_libguestfs) {|_env| nil }
        h.define_singleton_method(:vc_virtual_disks) { Array.new(disk_count, :disk) }
        h.define_singleton_method(:new_netapp_shift) {|_opts| NetAppShift::Helper.allocate }
        h.define_singleton_method(:run_cmd_report) do |cmd, _out = false, **_kw|
            commands << cmd
            ['', FakeStatus.new(true)]
        end
        h.define_singleton_method(:create_one_images) do |disks|
            imported = disks
            [{ :id => 1, :os => false }]
        end
        h.instance_variable_set(:@props,
                                'config' => { :hardware => { :memoryMB => 2048, :numCPU => 4 } })

        [h, commands, proc { imported }]
    end

    def test_missing_disk_raises_before_any_command
        Dir.mktmpdir do |mount|
            Dir.mktmpdir do |work_dir|
                h, commands, = conversion_helper(mount, work_dir, 1)

                err = assert_raises(NetAppShift::Error) { h.send(:run_shift_conversion) }

                assert_includes err.message, 'web01.qcow2'
                assert_empty commands
            end
        end
    end

    def test_single_disk_uses_i_disk_in_place
        Dir.mktmpdir do |mount|
            Dir.mktmpdir do |work_dir|
                disk = File.join(mount, 'web01.qcow2')
                File.write(disk, 'x')

                h, commands, imported = conversion_helper(mount, work_dir, 1)
                h.send(:run_shift_conversion)

                assert_equal 1, commands.size
                assert_includes commands.first, 'virt-v2v-in-place'
                assert_includes commands.first, "-i disk #{disk}"
                assert_includes commands.first, '--machine-readable'

                # imported straight from the mount, no copy anywhere
                assert_equal [disk], imported.call
                assert File.exist?(disk)
                assert_empty Dir.children(work_dir)
            end
        end
    end

    def test_multi_disk_uses_libvirtxml_with_ordered_disks
        Dir.mktmpdir do |mount|
            Dir.mktmpdir do |work_dir|
                disks = ['web01.qcow2', 'web01_1.qcow2', 'web01_2.qcow2']
                        .map {|f| File.join(mount, f) }
                disks.each {|d| File.write(d, 'x') }

                h, commands, imported = conversion_helper(mount, work_dir, 3)
                h.send(:run_shift_conversion)

                assert_includes commands.first, '-i libvirtxml'

                xml_path = File.join(work_dir, 'web01-shift-domain.xml')
                assert File.exist?(xml_path)

                xml = File.read(xml_path)
                # all three disks referenced, in device order
                positions = disks.map {|d| xml.index("file='#{d}'") }
                assert positions.all?, "missing disk in domain XML: #{xml}"
                assert_equal positions.sort, positions

                assert_equal disks, imported.call
            end
        end
    end

    # virt-v2v reads /domain/memory/text() as an integer, so a pretty-printed
    # document ("\n    4096\n  ") makes it bail before it looks at the disks.
    def test_domain_xml_text_nodes_carry_no_whitespace
        Dir.mktmpdir do |mount|
            Dir.mktmpdir do |work_dir|
                ['web01.qcow2', 'web01_1.qcow2'].each {|f| File.write(File.join(mount, f), 'x') }

                h, = conversion_helper(mount, work_dir, 2)
                h.send(:run_shift_conversion)

                doc = REXML::Document.new(
                    File.read(File.join(work_dir, 'web01-shift-domain.xml'))
                )

                ['/domain/name', '/domain/memory', '/domain/vcpu', '/domain/os/type'].each do |xpath|
                    text = doc.elements[xpath].text
                    refute_nil text, "#{xpath} has no text"
                    assert_equal text.strip, text, "#{xpath} text is padded: #{text.inspect}"
                end

                assert_equal '2048', doc.elements['/domain/memory'].text
                assert_match(/\A\d+\z/, doc.elements['/domain/vcpu'].text)
            end
        end
    end

    def test_failed_morph_raises_and_skips_import
        Dir.mktmpdir do |mount|
            Dir.mktmpdir do |work_dir|
                File.write(File.join(mount, 'web01.qcow2'), 'x')

                h, _commands, imported = conversion_helper(mount, work_dir, 1)
                h.define_singleton_method(:run_cmd_report) do |_cmd, _out = false, **_kw|
                    ['', FakeStatus.new(false)]
                end

                err = assert_raises(RuntimeError) { h.send(:run_shift_conversion) }

                assert_includes err.message, 'virt-v2v-in-place failed'
                assert_nil imported.call
            end
        end
    end

    # virt-v2v's real error arrives as --machine-readable JSON on stdout. The
    # terminal usually shows only teardown noise, so the JSON has to be the
    # thing that reaches the operator.
    def test_failure_surfaces_the_machine_readable_error
        Dir.mktmpdir do |mount|
            Dir.mktmpdir do |work_dir|
                File.write(File.join(mount, 'web01.qcow2'), 'x')

                h, = conversion_helper(mount, work_dir, 1)
                h.define_singleton_method(:run_cmd_report) do |_cmd, _out = false, **_kw|
                    out = [
                        '{"type":"message","message":"Opening the source"}',
                        '{"type":"error","message":"inspection could not detect the source guest"}',
                        'fsync: Input/output error'
                    ].join("\n")
                    [out, FakeStatus.new(false)]
                end

                err = assert_raises(RuntimeError) { h.send(:run_shift_conversion) }

                assert_includes err.message, 'inspection could not detect the source guest'
            end
        end
    end

    # virt-v2v refuses guests it does not recognise (Alpine, other minimal
    # distributions). Many of those boot on KVM unmodified, so the error has
    # to point at the flag rather than just failing.
    def test_unsupported_guest_error_names_the_flag
        Dir.mktmpdir do |mount|
            Dir.mktmpdir do |work_dir|
                File.write(File.join(mount, 'web01.qcow2'), 'x')

                h, = conversion_helper(mount, work_dir, 1)
                h.define_singleton_method(:run_cmd_report) do |_cmd, _out = false, **_kw|
                    ['{"type":"error","message":"virt-v2v is unable to convert this ' \
                     'guest type (linux/alpinelinux)"}', FakeStatus.new(false)]
                end

                err = assert_raises(RuntimeError) { h.send(:run_shift_conversion) }

                assert_includes err.message, 'linux/alpinelinux'
                assert_includes err.message, '--shift-skip-morph'
            end
        end
    end

    def test_skip_morph_imports_without_running_virt_v2v
        Dir.mktmpdir do |mount|
            Dir.mktmpdir do |work_dir|
                disks = ['web01.qcow2', 'web01_1.qcow2'].map {|f| File.join(mount, f) }
                disks.each {|d| File.write(d, 'x') }

                h, commands, imported = conversion_helper(mount, work_dir, 2,
                                                          :shift_skip_morph => true)
                capture_io { h.send(:run_shift_conversion) }

                assert_empty commands
                assert_equal disks, imported.call
                # no domain XML needed when the morph is skipped
                assert_empty Dir.children(work_dir)
            end
        end
    end

    def test_failure_without_json_falls_back_to_the_tail
        Dir.mktmpdir do |mount|
            Dir.mktmpdir do |work_dir|
                File.write(File.join(mount, 'web01.qcow2'), 'x')

                h, = conversion_helper(mount, work_dir, 1)
                h.define_singleton_method(:run_cmd_report) do |_cmd, _out = false, **_kw|
                    ['something broke', FakeStatus.new(false)]
                end

                err = assert_raises(RuntimeError) { h.send(:run_shift_conversion) }

                assert_includes err.message, 'something broke'
            end
        end
    end

    def test_libguestfs_path_exported_to_command
        Dir.mktmpdir do |mount|
            Dir.mktmpdir do |work_dir|
                File.write(File.join(mount, 'web01.qcow2'), 'x')

                h, commands, = conversion_helper(mount, work_dir, 1,
                                                 :libguestfs_path => '/var/lib/one/appliance')
                h.send(:run_shift_conversion)

                assert_match(%r{^LIBGUESTFS_PATH=/var/lib/one/appliance virt-v2v-in-place},
                             commands.first)
            end
        end
    end

    def test_zero_disks_raises
        Dir.mktmpdir do |mount|
            Dir.mktmpdir do |work_dir|
                h, = conversion_helper(mount, work_dir, 0)

                err = assert_raises(RuntimeError) { h.send(:run_shift_conversion) }

                assert_includes err.message, 'no virtual disks'
            end
        end
    end

end

# Fake NetAppShift::Helper for the orchestration tests. Mirrors the real
# client's contract: reads return data, actions raise on failure.
class FakeShift

    attr_reader :calls

    def initialize(responses = {})
        @responses = responses
        @calls     = []
    end

    def verbs
        @calls.map(&:first)
    end

    def blueprint_execution_state(blueprint)
        @calls << [:state, blueprint]
        replay(:state, nil)
    end

    def blueprint_vm_names(blueprint)
        @calls << [:vm_names, blueprint]
        replay(:vm_names)
    end

    def run_compliance_check(blueprint)
        @calls << [:compliance, blueprint]
        replay(:compliance, {})
    end

    def trigger_conversion(blueprint, ignore_powered_on: false)
        @calls << [:trigger, blueprint, ignore_powered_on]
        replay(:trigger)
    end

    def wait_for_completion(blueprint, execution_id, timeout: nil)
        @calls << [:wait, blueprint, execution_id, timeout]
        replay(:wait, { :status => 'complete' })
    end

    private

    # A stored exception is raised; anything else is returned.
    def replay(key, default = :__required__)
        value = @responses.fetch(key) do
            raise "test: FakeShift has no :#{key} response" if default == :__required__

            default
        end

        raise value if value.is_a?(Class) && value <= StandardError
        raise value if value.is_a?(StandardError)

        value
    end

end

class ShiftExecuteBlueprintTest < Minitest::Test

    OPTIONS = {
        :shift               => 'https://shift.local',
        :shift_user          => 'admin',
        :shift_pass          => 'p',
        :shift_blueprint     => 'bp1',
        :shift_mount         => '/mnt/shift',
        :shift_wait_timeout  => 3600
    }.freeze

    def orchestration_helper(fake)
        h = OneSwapHelper.allocate
        h.instance_variable_set(:@logger, Logger.new(File::NULL))
        h.instance_variable_set(:@verbose, true) # short-circuits apply_verbosity
        h.define_singleton_method(:check_one_connectivity) { nil }
        h.define_singleton_method(:local_path_image_allocation_preflight!) { nil }
        h.define_singleton_method(:new_netapp_shift) {|_opts| fake }
        h
    end

    def run_it(fake)
        capture_io { orchestration_helper(fake).shift_execute_blueprint(OPTIONS.dup) }
    end

    def test_happy_path_passes_blueprint_execution_id_and_timeout
        fake = FakeShift.new(:state => nil, :trigger => 'ex-9')

        run_it(fake)

        assert_includes fake.calls, [:compliance, 'bp1']
        assert_includes fake.calls, [:trigger, 'bp1', false]
        assert_includes fake.calls, [:wait, 'bp1', 'ex-9', 3600]
    end

    # The reported bug: a blueprint that already converted must not be
    # triggered again, it must fall through to import.
    def test_already_converted_state_skips_compliance_and_trigger
        fake = FakeShift.new(:state => { :status => 'convert_complete', :complete => true,
                                         :running => false, :failed => false,
                                         :execution_id => 'ex-1' })

        out, = run_it(fake)

        assert_equal [[:state, 'bp1']], fake.calls
        assert_includes out, 'already been converted'
    end

    # And when the status endpoint does not report it, Shift's own rejection
    # of the second execution must be treated the same way.
    def test_already_executed_on_trigger_is_not_an_error
        fake = FakeShift.new(:state => nil, :trigger => NetAppShift::AlreadyExecuted)

        out, = run_it(fake)

        assert_includes out, 'already been converted'
        refute_includes fake.verbs, :wait
    end

    def test_running_blueprint_attaches_to_existing_execution
        fake = FakeShift.new(:state => { :status => 'convert_inprogress', :complete => false,
                                         :running => true, :failed => false,
                                         :execution_id => 'ex-7' })

        run_it(fake)

        assert_includes fake.calls, [:wait, 'bp1', 'ex-7', 3600]
        refute_includes fake.verbs, :trigger
        refute_includes fake.verbs, :compliance
    end

    def test_failed_blueprint_raises_without_triggering
        fake = FakeShift.new(:state => { :status => 'convert_error', :complete => false,
                                         :running => false, :failed => true,
                                         :execution_id => 'ex-3' })

        err = assert_raises(RuntimeError) { run_it(fake) }

        assert_includes err.message, 'last execution failed'
        refute_includes fake.verbs, :trigger
    end

    def test_compliance_failure_becomes_a_plain_error
        fake = FakeShift.new(
            :state      => nil,
            :compliance => NetAppShift::OperationError.new('compliance check failed: nope')
        )

        err = assert_raises(RuntimeError) { run_it(fake) }

        refute_kind_of NetAppShift::Error, err
        assert_includes err.message, 'compliance check failed'
        refute_includes fake.verbs, :trigger
    end

    def test_trigger_failure_propagates
        fake = FakeShift.new(
            :state   => nil,
            :trigger => NetAppShift::OperationError.new('returned no execution id')
        )

        err = assert_raises(RuntimeError) { run_it(fake) }

        assert_includes err.message, 'no execution id'
        refute_includes fake.verbs, :wait
    end

    def test_blueprint_vm_names_delegates
        fake = FakeShift.new(:vm_names => %w[web01 db01])
        h = orchestration_helper(fake)

        assert_equal %w[web01 db01], h.shift_blueprint_vm_names(OPTIONS.dup)
    end

    def test_powered_on_vms_error_names_the_flag
        fake = FakeShift.new(
            :state   => nil,
            :trigger => NetAppShift::PoweredOnVms.new(
                "ERSCSTEX022: Cannot execute the 'convert' action - as some VMs are " \
                'still powered on.',
                :vm_names => %w[web01 db01]
            )
        )

        err = assert_raises(RuntimeError) { run_it(fake) }

        assert_includes err.message, 'still powered on'
        assert_includes err.message, 'web01, db01'
        assert_includes err.message, '--shift-ignore-running-vms'
        refute_includes fake.verbs, :wait
    end

    def test_ignore_running_vms_is_passed_through
        fake = FakeShift.new(:state => nil, :trigger => 'ex-9')

        capture_io do
            orchestration_helper(fake)
                .shift_execute_blueprint(OPTIONS.merge(:shift_ignore_running_vms => true))
        end

        assert_includes fake.calls, [:trigger, 'bp1', true]
    end

    def test_skip_compliance_still_triggers
        fake = FakeShift.new(:state => nil, :trigger => 'ex-9')

        out, = capture_io do
            orchestration_helper(fake)
                .shift_execute_blueprint(OPTIONS.merge(:shift_skip_compliance => true))
        end

        refute_includes fake.verbs, :compliance
        assert_includes fake.verbs, :trigger
        assert_includes fake.calls, [:wait, 'bp1', 'ex-9', 3600]
        assert_includes out, 'Skipping Shift compliance check'
    end

end

# Captures whatever rows a lister hands to the table renderer, standing in for
# CLIHelper::ShowTable (which needs OpenNebula's CLI libs).
class FakeTable

    attr_reader :rows, :options

    def show(rows, options)
        @rows    = rows
        @options = options
    end

end

class ShiftListingTest < Minitest::Test

    VMS = [
        { :name => 'web01', :id => 'vm-1', :resource_group => 'group1' },
        { :name => 'db01',  :id => 'vm-2', :resource_group => 'group2' }
    ].freeze

    SUMMARIES = [
        { :name => 'multidisk', :id => 'bp-1',
          :resource_groups => ['group1'], :vms => %w[web01 web02] },
        { :name => 'waves', :id => 'bp-2',
          :resource_groups => %w[group1 group2], :vms => %w[web01 web02 db01] }
    ].freeze

    OPTIONS = {
        :shift           => 'https://shift.local',
        :shift_user      => 'admin',
        :shift_pass      => 'p',
        :shift_blueprint => 'waves'
    }.freeze

    # Fake client exposing only the two read methods the listers use
    class ListShift

        def initialize(vms: VMS, summaries: SUMMARIES)
            @vms = vms
            @summaries = summaries
        end

        def blueprint_vms(_bp)
            raise @vms if @vms.is_a?(StandardError)

            @vms
        end

        def blueprint_summaries
            @summaries
        end

    end

    def lister(shift = ListShift.new)
        table = FakeTable.new
        h = OneSwapHelper.allocate
        h.instance_variable_set(:@logger, Logger.new(File::NULL))
        h.instance_variable_set(:@verbose, true)
        h.define_singleton_method(:format_list) { table }
        h.define_singleton_method(:new_netapp_shift) {|_opts| shift }
        h.define_singleton_method(:list_vms) {|_opts| :went_to_vcenter }
        [h, table]
    end

    def test_list_vms_with_shift_lists_blueprint_vms
        h, table = lister
        h.list(OPTIONS.merge(:object => 'vms'))

        assert_equal %w[web01 db01], table.rows.map {|r| r[:name] }
        assert_equal %w[group1 group2], table.rows.map {|r| r[:resource_group] }
    end

    def test_list_vms_without_shift_still_uses_vcenter
        h, table = lister
        assert_equal :went_to_vcenter, h.list(:object => 'vms')
        assert_nil table.rows
    end

    def test_datacenters_are_never_diverted_to_shift
        h, = lister
        h.define_singleton_method(:list_datacenters) {|_opts| :went_to_vcenter }

        assert_equal :went_to_vcenter, h.list(OPTIONS.merge(:object => 'datacenters'))
    end

    def test_list_vms_sets_the_shift_column_set
        h, = lister
        h.list(OPTIONS.merge(:object => 'vms'))

        assert_equal OneSwapHelper::VOBJECT::SHIFT_VM, h.instance_variable_get(:@vobject)
    end

    def test_name_filter_applies_to_blueprint_vms
        h, table = lister
        h.list(OPTIONS.merge(:object => 'vms', :name => 'web'))

        assert_equal %w[web01], table.rows.map {|r| r[:name] }
    end

    def test_list_blueprints_summarises_each
        h, table = lister
        h.list(OPTIONS.merge(:object => 'blueprints'))

        assert_equal %w[multidisk waves], table.rows.map {|r| r[:name] }
        assert_equal [2, 3], table.rows.map {|r| r[:vm_count] }
        assert_equal ['group1', 'group1, group2'], table.rows.map {|r| r[:resource_group] }
        assert_equal OneSwapHelper::VOBJECT::BLUEPRINT, h.instance_variable_get(:@vobject)
    end

    def test_list_blueprints_needs_no_blueprint_name
        h, table = lister
        h.list(:object => 'blueprints', :shift => 'https://s',
               :shift_user => 'u', :shift_pass => 'p')

        assert_equal 2, table.rows.length
    end

    def test_missing_credentials_name_the_flags
        h, = lister

        err = assert_raises(RuntimeError) { h.list(:object => 'blueprints', :shift => 'https://s') }

        assert_includes err.message, '--shift-user'
        assert_includes err.message, '--shift-pass'
    end

    def test_listing_vms_requires_a_blueprint
        h, = lister

        err = assert_raises(RuntimeError) do
            h.list(:object => 'vms', :shift => 'https://s', :shift_user => 'u', :shift_pass => 'p')
        end

        assert_includes err.message, '--shift-blueprint'
    end

    def test_client_errors_become_plain_errors
        h, = lister(ListShift.new(:vms => NetAppShift::OperationError.new("Blueprint 'x' not found")))

        err = assert_raises(RuntimeError) { h.list(OPTIONS.merge(:object => 'vms')) }

        refute_kind_of NetAppShift::Error, err
        assert_includes err.message, 'not found'
    end

end
