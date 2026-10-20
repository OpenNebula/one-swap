# Unit checks for ESXi::Client parsing and command construction.
# Run with: ruby tests/esxi_client_test.rb

require 'logger'
require 'minitest/autorun'
require 'shellwords'
require 'tmpdir'
require_relative '../esxi_vm'

class ESXiClientTest < Minitest::Test

    # Real `vim-cmd vmsvc/snapshot.get` layout from ESXi 8.0.3: the name is
    # printed before the id, and child snapshots are indented further.
    SNAPSHOT_TREE = <<~OUT
        Get Snapshot:
        |-ROOT
        --Snapshot Name        : before-patching
        --Snapshot Id        : 1
        --Snapshot Desciption  : customer restore point
        --Snapshot Created On  : 10/1/2026 9:00:00
        --Snapshot State       : powered on
        --|-CHILD
        ----Snapshot Name        : VM Snapshot 10/17/2026, 6:19:10 PM
        ----Snapshot Id        : 2
        ----Snapshot Desciption  : OneSwap ESXi client snapshot
        ----Snapshot Created On  : 10/17/2026 16:27:43
        ----Snapshot State       : powered off
    OUT

    def client(vm_cmd_output = nil, vm_cmd_status = true)
        ESXi::Client.allocate.tap do |c|
            c.instance_variable_set(:@host, 'esxi.invalid')
            c.instance_variable_set(:@user, 'root')
            c.instance_variable_set(:@logger, Logger.new(File::NULL))
            c.instance_variable_set(:@ssh_options, '-o BatchMode=yes')
            c.instance_variable_set(:@ssh_env, {})
            c.instance_variable_set(:@vm_list, [])
            unless vm_cmd_output.nil?
                c.define_singleton_method(:vm_cmd) {|_actions| [vm_cmd_output, '', vm_cmd_status] }
            end
        end
    end

    def test_snapshot_id_by_name_reads_name_before_id
        c = client(SNAPSHOT_TREE)

        assert_equal '2', c.snapshot_id_by_name(42, 'VM Snapshot 10/17/2026, 6:19:10 PM')
        assert_equal '1', c.snapshot_id_by_name(42, 'before-patching')
        assert_nil c.snapshot_id_by_name(42, 'missing')
    end

    def test_snapshots_pairs_each_id_with_its_own_name_and_description
        assert_equal [
            { :id => '1', :name => 'before-patching', :description => 'customer restore point' },
            { :id => '2', :name => 'VM Snapshot 10/17/2026, 6:19:10 PM',
              :description => 'OneSwap ESXi client snapshot' }
        ], client(SNAPSHOT_TREE).snapshots(42)
    end

    def test_snapshot_fields_inside_a_description_are_not_parsed_as_fields
        tree = SNAPSHOT_TREE.sub('customer restore point', 'restore point (Snapshot Id: 1, Snapshot Name : x)')
        c = client(tree)

        assert_equal '2', c.snapshot_id_by_name(42, 'VM Snapshot 10/17/2026, 6:19:10 PM')
        assert_equal ['before-patching', 'VM Snapshot 10/17/2026, 6:19:10 PM'], c.snapshots(42).map {|s| s[:name] }
    end

    def test_snapshot_names_outside_ascii_are_parsed_in_any_locale
        # Under LANG=C the command output is tagged US-ASCII but holds UTF-8.
        tree = SNAPSHOT_TREE.sub('before-patching', 'Înainte de actualizare').b.force_encoding(Encoding::US_ASCII)
        c = client(tree)

        assert_equal '1', c.snapshot_id_by_name(42, 'Înainte de actualizare')
        assert_equal '2', c.snapshot_id_by_name(42, 'VM Snapshot 10/17/2026, 6:19:10 PM')
    end

    def test_snapshot_listing_failure_is_an_error_not_an_empty_result
        c = client('', false)

        assert_raises(ESXi::Client::Error) { c.snapshot_id_by_name(42, 'VM Snapshot') }
        assert_raises(ESXi::Client::Error) { c.snapshots(42) }
    end

    def test_get_vm_by_name_returns_nil_when_missing
        c = client
        c.instance_variable_set(:@vm_list, [{ :vmid => 1, :name => 'other', :file => '[ds] other/other.vmx',
                                              :guest_os => 'x', :version => 'vmx-21', :annotation => nil }])

        assert_nil c.get_vm_by_name('missing')
    end

    def test_same_named_vms_are_told_apart_by_their_vmx
        c = client
        c.instance_variable_set(:@vm_list, [
            { :vmid => 1, :name => 'web', :file => '[ds] test/web.vmx', :guest_os => 'x', :version => 'vmx-21',
              :annotation => nil },
            { :vmid => 2, :name => 'web', :file => '[ds] prod/web.vmx', :guest_os => 'x', :version => 'vmx-21',
              :annotation => nil }
        ])

        assert_equal 2, c.get_vm_by_name('web', '[ds] prod/web.vmx').instance_variable_get(:@id)
        assert_nil c.get_vm_by_name('web', '[ds] other/web.vmx')
    end

    def test_file_signature_reads_the_size_and_modification_time
        c = client
        remote = []
        c.define_singleton_method(:ssh) {|cmd| remote << cmd; ["140959 1792278256\n", '', true] }

        assert_equal '140959 1792278256', c.file_signature('/vmfs/volumes/ds/web vm/vmware.log')
        assert_equal ['stat', '-c', '%s %Y', '/vmfs/volumes/ds/web vm/vmware.log'], Shellwords.split(remote[0])

        c.define_singleton_method(:ssh) {|_cmd| ['', 'No such file or directory', false] }
        assert_nil c.file_signature('/vmfs/volumes/ds/web vm/vmware.log')
    end

    def test_removing_files_that_are_already_gone_succeeds
        c = client
        remote = []
        c.define_singleton_method(:ssh) {|cmd| remote << cmd; ['', '', true] }

        assert c.remove_files('/vmfs/volumes/ds/web/vmkfstools_output')
        assert_equal ['rm', '-rf', '/vmfs/volumes/ds/web/vmkfstools_output'], Shellwords.split(remote[0])
    end

    def test_ssh_passes_the_remote_command_as_one_argument
        c = client
        c.instance_variable_set(:@user, 'esx admin')
        commands = []
        c.define_singleton_method(:execute) {|cmd, _env = {}| commands << cmd; ['', '', true] }
        remote = %q{vim-cmd hostsvc/autostartmanager/update_autostartentry 42 'none' '0'}

        c.send(:ssh, remote)

        args = Shellwords.split(commands.fetch(0))
        assert_equal ['ssh', '-o', 'BatchMode=yes', 'esx admin@esxi.invalid', remote], args
    end

    def test_quoted_datastore_paths_are_accepted
        c = client
        remote = []
        c.define_singleton_method(:ssh) {|cmd| remote << cmd; ["-rw------- 1 0 0 42 Oct 17 file\n", '', true] }

        assert_equal 42, c.file_size_bytes("/vmfs/volumes/ds/Bob's DB/Bob's DB-000001-sesparse.vmdk")
        assert c.create_zero_file("/vmfs/volumes/ds/Bob's DB/oneswap-benchmark", 1)
        assert_equal ['ls', '-ln', "/vmfs/volumes/ds/Bob's DB/Bob's DB-000001-sesparse.vmdk"], Shellwords.split(remote[0])
    end

    def test_pull_files_escapes_remote_and_local_paths_but_keeps_globs
        c = client
        commands = []
        c.define_singleton_method(:live_execution) {|cmd, *_| commands << cmd; true }

        c.pull_files('/vmfs/volumes/Data Store/My VM/My VM-000001.vmdk', '/var/tmp/work dir/esxi_client-My VM')
        c.pull_files('/vmfs/volumes/Data Store/My VM/vmkfstools_output/*', '/var/tmp/work dir')

        first = Shellwords.split(commands.fetch(0))
        assert_equal ['scp', '-o', 'BatchMode=yes', '-r'], first[0, 4]
        # One local-shell layer is removed here; the remaining escaping is for
        # the remote side (remote shell or the SFTP glob of modern scp).
        assert_equal 'root@esxi.invalid:/vmfs/volumes/Data\\ Store/My\\ VM/My\\ VM-000001.vmdk', first[4]
        assert_equal '/var/tmp/work dir/esxi_client-My VM', first[5]
        assert_equal ['/vmfs/volumes/Data Store/My VM/My VM-000001.vmdk'],
                     Shellwords.split(first[4].delete_prefix('root@esxi.invalid:'))

        second = Shellwords.split(commands.fetch(1))
        assert_equal 'root@esxi.invalid:/vmfs/volumes/Data\\ Store/My\\ VM/vmkfstools_output/*', second[4]
    end

    def test_remote_disk_commands_escape_paths
        c = client
        remote = []
        c.define_singleton_method(:ssh) {|cmd| remote << cmd; ['', '', true] }
        source = '/vmfs/volumes/Data Store/My VM/My VM.vmdk'
        target = '/vmfs/volumes/Data Store/My VM/vmkfstools_output/disk0.vmdk'

        c.clone_virtual_disk(source, target)
        c.create_dir('/vmfs/volumes/Data Store/My VM/vmkfstools_output')
        c.file_size_bytes('/vmfs/volumes/Data Store/My VM/My VM-000001-sesparse.vmdk')

        assert_equal ['vmkfstools', '--clonevirtualdisk', source, target, '-d', 'thin'], Shellwords.split(remote[0])
        assert_equal ['mkdir', '-p', '/vmfs/volumes/Data Store/My VM/vmkfstools_output'], Shellwords.split(remote[1])
        assert_equal ['ls', '-ln', '/vmfs/volumes/Data Store/My VM/My VM-000001-sesparse.vmdk'],
                     Shellwords.split(remote[2])
    end

    def test_local_disk_commands_escape_paths
        c = client
        commands = []
        c.define_singleton_method(:live_execution) {|cmd, *_| commands << cmd; true }
        c.instance_variable_set(:@v2v_env, {})

        c.convert_vmdk('/var/tmp/work dir/My VM.vmdk', '/var/tmp/work dir/convert/disk0.raw', 'raw')
        c.apply_vmdk_snapshot_to_raw('/var/tmp/work dir/My VM-000001-sesparse.vmdk', '/var/tmp/work dir/convert/disk0.raw')
        c.os_morph('/var/tmp/work dir/convert/disk0.raw', '-v --machine-readable')

        assert_equal ['qemu-img', 'convert', '-p', '-f', 'vmdk', '/var/tmp/work dir/My VM.vmdk',
                      '-O', 'raw', '/var/tmp/work dir/convert/disk0.raw'], Shellwords.split(commands[0])
        assert_equal ['sesparse', '/var/tmp/work dir/My VM-000001-sesparse.vmdk',
                      '/var/tmp/work dir/convert/disk0.raw'], Shellwords.split(commands[1])
        # The copies are raw: the format of guest-controlled data is never probed.
        assert_equal ['virt-v2v-in-place', '-i', 'disk', '-if', 'raw', '/var/tmp/work dir/convert/disk0.raw',
                      '-v', '--machine-readable'], Shellwords.split(commands[2])
    end

    def test_guest_conversion_probe_runs_on_an_overlay_without_probing_formats
        c = client
        commands = []
        c.define_singleton_method(:live_execution) {|cmd, *_| commands << cmd; true }
        c.instance_variable_set(:@v2v_env, {})

        c.create_overlay('convert dir/disk0.raw', '/var/tmp/work dir/probe/disk0.qcow2')
        c.os_morph('/var/tmp/work dir/probe/disk0.qcow2', '', 'qcow2')

        # The backing file is absolute: qemu-img resolves a relative one
        # against the overlay folder.
        assert_equal ['qemu-img', 'create', '-q', '-f', 'qcow2', '-F', 'raw', '-b',
                      File.expand_path('convert dir/disk0.raw'), '/var/tmp/work dir/probe/disk0.qcow2'],
                     Shellwords.split(commands[0])
        assert_equal ['virt-v2v-in-place', '-i', 'disk', '-if', 'qcow2', '/var/tmp/work dir/probe/disk0.qcow2'],
                     Shellwords.split(commands[1])
    end

    def test_guest_conversion_keeps_what_virt_v2v_reports
        c = client
        c.define_singleton_method(:live_execution) {|_cmd, _message, _env, output| output << "error: read-only\n"; false }
        output = []

        refute c.os_morph('/var/tmp/work dir/probe/disk0.qcow2', '', 'qcow2', output)
        assert_equal ["error: read-only\n"], output
    end

    def test_live_execution_streams_and_can_keep_the_output
        output = []
        status = nil
        streamed, = capture_subprocess_io do
            status = client.send(:live_execution, "printf 'converting\\n'; printf 'error: read-only\\n' >&2; exit 1",
                                 nil, {}, output)
        end

        refute status
        assert_includes streamed, 'converting'
        assert_equal ["converting\n", "error: read-only\n"], output.sort
    end

    def test_failed_vmdk_conversion_removes_partial_output
        Dir.mktmpdir do |dir|
            target = File.join(dir, 'disk0.raw')
            File.write(target, 'partial')
            c = client
            c.define_singleton_method(:live_execution) {|*_| false }

            assert_equal false, c.convert_vmdk(File.join(dir, 'disk0.vmdk'), target, 'raw')
            refute_path_exists target
        end
    end

end
