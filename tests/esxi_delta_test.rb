# Unit checks for the ESXi delta migration flow (prepare, commit, cleanup).
# Run with: ruby tests/esxi_delta_test.rb

require 'logger'
require 'minitest/autorun'
require 'stringio'
require 'tmpdir'
require 'yaml'
require_relative '../esxi_vm'

class EsxiDeltaTest < Minitest::Test

    DS2_UUID = '650c2b3a-12345678-abcd-001122334455'
    DATASTORE_NAMES = { DS2_UUID => 'ds2', 'ds2' => 'ds2', 'datastore' => 'datastore' }.freeze
    TOOLS_RUNNING = 'toolsStatus = "toolsOk", toolsRunningStatus = "guestToolsRunning"'
    NO_TOOLS = 'toolsStatus = "toolsNotInstalled", toolsRunningStatus = "guestToolsNotRunning"'

    # The process is killed (Ctrl-C, SIGHUP, SIGTERM), which no rescue handles.
    class Killed < Exception; end # rubocop:disable Lint/InheritException

    # In-memory ESXi host: remote files, snapshots and power state.
    class FakeClient

        attr_reader :logger, :calls
        attr_accessor :remote_files, :snapshot_list, :results, :states, :summary, :signatures, :morph_output

        def initialize
            @logger = Logger.new(File::NULL)
            @calls = []
            @remote_files = {}
            @snapshot_list = []
            @results = Hash.new(true)
            @states = ['Powered on']
            @summary = TOOLS_RUNNING
            @signatures = {}
        end

        def result(name)
            value = @results[name]
            value.is_a?(Array) ? value.shift : value
        end

        def snapshot_vm(_id, name, options)
            @calls << [:snapshot_vm, options[:quiesce]]
            return false unless result(:snapshot_vm)

            @snapshot_list << { :id => (@snapshot_list.length + 100).to_s, :name => name,
                                :description => options[:description] }
            # The VMX moves from the base disks to the new deltas.
            @remote_files.each_key do |path|
                next unless path.end_with?('.vmx')

                @remote_files[path] = @remote_files[path].gsub(/(?<!-\d{6})\.vmdk"/, '-000001.vmdk"')
            end
            true
        end

        def snapshots(_id)
            raise ESXi::Client::Error, 'snapshot listing failed' unless result(:snapshots)

            @snapshot_list.map(&:dup)
        end

        def snapshot_id_by_name(id, name)
            snapshot = snapshots(id).find {|s| s[:name] == name }
            snapshot && snapshot[:id]
        end

        def remove_snapshot_vm(_id, snapshot_id)
            @calls << [:remove_snapshot_vm, snapshot_id]
            return false unless result(:remove_snapshot_vm)

            @snapshot_list.reject! {|s| s[:id] == snapshot_id }
            # Consolidation points the VMX back to the base disks.
            @remote_files.each_key do |path|
                next unless path.end_with?('.vmx')

                @remote_files[path] = @remote_files[path].gsub('-000001.vmdk', '.vmdk')
            end
            true
        end

        def vm_summary(_id)
            @summary
        end

        def vm_state(_id)
            @states.length > 1 ? @states.shift : @states.first
        end

        def shutdown_vm(_id, tools)
            @calls << [:shutdown_vm, tools]
            ok = result(:shutdown_vm)
            @states = ['Powered off'] if ok
            ok
        end

        def pull_files(source, target)
            @calls << [:pull_files, source, target]
            return false unless result(:pull_files)

            if source.end_with?('/*')
                dir = source.delete_suffix('/*')
                @remote_files.each do |path, content|
                    File.write(File.join(target, File.basename(path)), content) if File.dirname(path) == dir
                end
                return true
            end
            return false unless @remote_files.key?(source)

            destination = File.directory?(target) ? File.join(target, File.basename(source)) : target
            File.write(destination, @remote_files[source])
            true
        end

        def create_dir(dir)
            @calls << [:create_dir, dir]
            result(:create_dir)
        end

        def remove_files(path)
            @calls << [:remove_files, path]
            result(:remove_files)
        end

        def clone_virtual_disk(source, target)
            @calls << [:clone_virtual_disk, source, target]
            return false unless result(:clone_virtual_disk)

            @remote_files[target] = "descriptor of #{source}"
            @remote_files[target.sub(/\.vmdk\z/, '-flat.vmdk')] = "data of #{source}"
            true
        end

        def convert_vmdk(source, target, format)
            @calls << [:convert_vmdk, source, target, format]
            File.write(target, "raw of #{File.read(source)}")
            true
        end

        def apply_vmdk_snapshot_to_raw(snapshot, raw)
            @calls << [:apply, snapshot, raw]
            result(:apply)
        end

        def os_morph(path, _options, format = 'raw', output = nil)
            @calls << [:os_morph, path, format]
            output << @morph_output if output && @morph_output
            result(:os_morph)
        end

        def create_overlay(base, overlay)
            @calls << [:create_overlay, base, overlay]
            return false unless result(:create_overlay)

            File.write(overlay, "overlay of #{base}")
            true
        end

        def file_size_bytes(path)
            @calls << [:file_size_bytes, path]
            @remote_files.fetch(path, '').bytesize
        end

        def file_signature(path)
            @calls << [:file_signature, path]
            @signatures.fetch(path, '100 1792278256')
        end

    end

    def build_vm(client, vmx = '[datastore] web/web.vmx')
        info = ESXi::VirtualMachine::VM_INFO_KEYS.to_h {|key| [key, ''] }
        info.merge!(:vmid => 42, :name => 'web vm', :file => vmx)
        vm = ESXi::VirtualMachine.new(client, info)
        vm.define_singleton_method(:live_storage_transfer_precheck) { true }
        vm.define_singleton_method(:missing_commands) {|_commands| [] }
        vm.define_singleton_method(:sleep) {|*| }
        vm
    end

    def descriptor(parent, create_type = 'seSparse')
        lines = []
        lines << %(createType="#{create_type}") if create_type
        lines << %(parentFileNameHint="#{parent}") if parent
        lines.join("\n") + "\n"
    end

    # A VM with one disk next to its VMX on "datastore" and one on "ds2",
    # both named after the VM as vSphere does by default.
    def two_datastore_client(ds2_parent = 'web.vmdk', create_type = 'seSparse')
        FakeClient.new.tap do |c|
            c.remote_files['/vmfs/volumes/datastore/web/web.vmx'] = <<~VMX
                scsi0:0.fileName = "web-000001.vmdk"
                scsi0:1.fileName = "/vmfs/volumes/#{DS2_UUID}/web/web-000001.vmdk"
            VMX
            c.remote_files['/vmfs/volumes/datastore/web/web-000001.vmdk'] = descriptor('web.vmdk')
            c.remote_files["/vmfs/volumes/#{DS2_UUID}/web/web-000001.vmdk"] = descriptor(ds2_parent, create_type)
            c.remote_files['/vmfs/volumes/datastore/web/web.vmdk'] = descriptor(nil, 'vmfs')
            c.remote_files["/vmfs/volumes/#{DS2_UUID}/web/web.vmdk"] = descriptor(nil, 'vmfs')
        end
    end

    def prepare_vddk(vm, dir)
        copies = []
        state = nil
        output, = capture_io do
            state = vm.live2kvm_prepare(dir) do |parent, target|
                copies << [parent, target]
                File.write(target, "raw of #{parent}")
            end
        end
        [state, copies, output]
    end

    # --- VDDK file names -------------------------------------------------

    def test_vddk_path_uses_datastore_names_for_every_absolute_form
        vm = build_vm(FakeClient.new)

        assert_equal '[datastore] web/web.vmdk', vm.vddk_path('/vmfs/volumes/datastore/web/web.vmdk', DATASTORE_NAMES)
        assert_equal '[ds2] web/web.vmdk', vm.vddk_path("/vmfs/volumes/#{DS2_UUID}/web/web.vmdk", DATASTORE_NAMES)
        assert_equal '[ds2] web/web.vmdk', vm.vddk_path('/vmfs/volumes/ds2/web/web.vmdk', DATASTORE_NAMES)
    end

    def test_vddk_path_rejects_paths_it_cannot_map
        vm = build_vm(FakeClient.new)

        assert_raises(RuntimeError) { vm.vddk_path("/vmfs/volumes/#{DS2_UUID}/web/web.vmdk", {}) }
        assert_raises(RuntimeError) { vm.vddk_path('/shared/base.vmdk', DATASTORE_NAMES) }
    end

    def test_vddk_path_only_maps_resolved_datastore_paths
        # Relative names depend on the folder of the snapshot descriptor, which
        # only prepare knows (parent_base_path).
        vm = build_vm(FakeClient.new)

        assert_raises(RuntimeError) { vm.vddk_path('web.vmdk', DATASTORE_NAMES) }
        assert_raises(RuntimeError) { vm.vddk_path('../datastore/web/web.vmdk', DATASTORE_NAMES) }
    end

    # --- prepare -------------------------------------------------------------

    def test_prepare_resolves_parent_hints_next_to_each_delta_descriptor
        Dir.mktmpdir do |dir|
            vm = build_vm(two_datastore_client)
            state, copies, = prepare_vddk(vm, dir)

            convert = File.join(dir, 'esxi_client-web vm', 'convert')
            assert_equal [
                ['/vmfs/volumes/datastore/web/web.vmdk', File.join(convert, 'disk0.raw')],
                ["/vmfs/volumes/#{DS2_UUID}/web/web.vmdk", File.join(convert, 'disk1.raw')]
            ], copies
            assert_equal ['web-000001-sesparse.vmdk', "/vmfs/volumes/#{DS2_UUID}/web/web-000001-sesparse.vmdk"],
                         state['disks'].map {|disk| disk['active_snapshot_extent'] }
            assert_equal ['/vmfs/volumes/datastore/web/web.vmdk', "/vmfs/volumes/#{DS2_UUID}/web/web.vmdk"],
                         state['disks'].map {|disk| disk['parent_base_path'] }
        end
    end

    def test_prepare_rejects_snapshots_that_are_not_sesparse_before_copying
        Dir.mktmpdir do |dir|
            client = two_datastore_client('web.vmdk', 'vmfsSparse')
            vm = build_vm(client)
            state, copies, output = prepare_vddk(vm, dir)

            assert_equal false, state
            assert_empty copies
            assert_includes output, 'vmfsSparse'
            assert_empty client.snapshot_list
            assert_empty Dir.children(dir)
        end
    end

    def test_prepare_rejects_a_disk_without_snapshot_delta_and_removes_the_snapshot
        Dir.mktmpdir do |dir|
            # An independent disk is not part of the snapshot: the VMX keeps
            # pointing to the base disk, which has no parent.
            client = two_datastore_client(nil, 'vmfs')
            state, copies, output = prepare_vddk(build_vm(client), dir)

            assert_equal false, state
            assert_empty copies
            assert_empty client.snapshot_list
            assert_includes output, 'independent'
        end
    end

    def test_prepare_resolves_a_parent_name_starting_with_a_tilde
        Dir.mktmpdir do |dir|
            client = two_datastore_client('~web.vmdk')
            state, = prepare_vddk(build_vm(client), dir)

            assert_equal "/vmfs/volumes/#{DS2_UUID}/web/~web.vmdk", state['disks'][1]['parent_base_path']
        end
    end

    def test_prepare_again_removes_the_snapshot_of_the_previous_prepare
        Dir.mktmpdir do |dir|
            client = two_datastore_client
            first, = prepare_vddk(build_vm(client), dir)
            first_id = client.snapshot_id_by_name(42, first['snapshot_name'])
            client.snapshot_list.each {|s| s[:name] = 'older OneSwap snapshot' if s[:id] == first_id }
            File.write(File.join(first['transfer_dir'], 'oneswap-delta-state.yaml'),
                       first.merge('snapshot_name' => 'older OneSwap snapshot').to_yaml)

            second, = prepare_vddk(build_vm(client), dir)

            assert_includes client.calls, [:remove_snapshot_vm, first_id]
            assert_equal [second['snapshot_name']], client.snapshot_list.map {|s| s[:name] }
        end
    end

    def test_prepare_stops_when_the_previous_snapshot_cannot_be_removed
        Dir.mktmpdir do |dir|
            client = two_datastore_client
            first, = prepare_vddk(build_vm(client), dir)
            File.write(File.join(first['transfer_dir'], 'oneswap-delta-state.yaml'),
                       first.merge('snapshot_name' => 'older OneSwap snapshot').to_yaml)
            client.snapshot_list.first[:name] = 'older OneSwap snapshot'
            client.results[:remove_snapshot_vm] = false

            second, copies, output = prepare_vddk(build_vm(client), dir)

            assert_equal false, second
            assert_empty copies
            assert_equal 1, client.snapshot_list.length
            assert_includes output, '--delta-cleanup'
        end
    end

    def test_prepare_removes_the_snapshot_when_the_state_cannot_be_written
        Dir.mktmpdir do |dir|
            client = two_datastore_client
            vm = build_vm(client)
            vm.define_singleton_method(:write_live2kvm_state) {|*| false }
            state, = prepare_vddk(vm, dir)

            assert_equal false, state
            assert_empty client.snapshot_list
        end
    end

    def test_an_interrupted_prepare_is_replaced_by_the_next_one
        Dir.mktmpdir do |dir|
            client = two_datastore_client
            assert_raises(Killed) { capture_io { build_vm(client).live2kvm_prepare(dir) {|*| raise Killed } } }
            assert_equal 1, client.snapshot_list.length

            second, = prepare_vddk(build_vm(client), dir)

            assert_equal [second['snapshot_name']], client.snapshot_list.map {|s| s[:name] }
        end
    end

    def test_cleanup_removes_the_snapshot_of_an_interrupted_prepare
        Dir.mktmpdir do |dir|
            client = two_datastore_client
            assert_raises(Killed) { capture_io { build_vm(client).live2kvm_prepare(dir) {|*| raise Killed } } }

            capture_io { assert_equal true, build_vm(client).live2kvm_cleanup(dir) }

            assert_empty client.snapshot_list
            refute_path_exists File.join(dir, 'esxi_client-web vm')
        end
    end

    def test_prepare_removes_the_snapshot_when_the_vmx_cannot_be_read
        Dir.mktmpdir do |dir|
            client = two_datastore_client
            client.results[:pull_files] = false
            state, copies, = prepare_vddk(build_vm(client), dir)

            assert_equal false, state
            assert_empty copies
            assert_empty client.snapshot_list
        end
    end

    def test_failed_vddk_copy_removes_the_snapshot_and_partial_files
        Dir.mktmpdir do |dir|
            client = two_datastore_client
            vm = build_vm(client)
            result = nil
            capture_io do
                result = vm.live2kvm_prepare(dir) {|_parent, target| File.write(target, 'partial'); raise IOError, 'boom' }
            end

            assert_equal false, result
            assert_empty client.snapshot_list
            assert_empty Dir.children(dir)
        end
    end

    def test_ssh_prepare_clones_each_disk_to_its_own_positional_name
        Dir.mktmpdir do |dir|
            client = two_datastore_client
            vm = build_vm(client)
            state = nil
            capture_io { state = vm.live2kvm_prepare(dir) }

            clone_dir = '/vmfs/volumes/datastore/web/vmkfstools_output'
            clones = client.calls.select {|call| call[0] == :clone_virtual_disk }
            assert_equal [
                [:clone_virtual_disk, '/vmfs/volumes/datastore/web/web.vmdk', "#{clone_dir}/disk0.vmdk"],
                [:clone_virtual_disk, "/vmfs/volumes/#{DS2_UUID}/web/web.vmdk", "#{clone_dir}/disk1.vmdk"]
            ], clones
            convert = File.join(dir, 'esxi_client-web vm', 'convert')
            assert_equal [File.join(convert, 'disk0.raw'), File.join(convert, 'disk1.raw')],
                         state['disks'].map {|disk| disk['converted_raw_base_path'] }
            assert_equal 'raw of descriptor of /vmfs/volumes/datastore/web/web.vmdk',
                         File.read(File.join(convert, 'disk0.raw'))
        end
    end

    def test_ssh_prepare_removes_the_clones_once_the_base_copies_are_local
        Dir.mktmpdir do |dir|
            client = two_datastore_client
            state = nil
            capture_io { state = build_vm(client).live2kvm_prepare(dir) }

            calls = client.calls.map(&:first)
            assert_operator calls.rindex(:remove_files), :>, calls.rindex(:convert_vmdk)
            assert_nil state['clone_dir']
            # Only the raw base copies stay until the commit.
            assert_equal ['convert', 'oneswap-delta-state.yaml'], Dir.children(state['transfer_dir']).sort
        end
    end

    def test_ssh_prepare_abort_removes_the_clones_also_when_the_snapshot_stays
        Dir.mktmpdir do |dir|
            client = two_datastore_client
            client.results[:clone_virtual_disk] = [true, false]
            client.results[:remove_snapshot_vm] = false
            state = nil
            output, = capture_io { state = build_vm(client).live2kvm_prepare(dir) }

            assert_equal false, state
            calls = client.calls.map(&:first)
            assert_operator calls.rindex(:remove_files), :>, calls.rindex(:clone_virtual_disk)
            assert_nil build_vm(client).live2kvm_state(dir)['clone_dir']
            assert_includes output, 'remains active'
        end
    end

    def test_prepare_checks_the_guest_conversion_on_throwaway_overlays
        Dir.mktmpdir do |dir|
            client = two_datastore_client
            state, = prepare_vddk(build_vm(client), dir)

            convert = state['convert_dir']
            probe = File.join(state['transfer_dir'], 'probe', 'disk0.qcow2')
            assert_equal [[:create_overlay, File.join(convert, 'disk0.raw'), probe]],
                         client.calls.select {|call| call[0] == :create_overlay }
            assert_includes client.calls, [:os_morph, probe, 'qcow2']
            # The base copies stay as they were copied; the overlays are gone.
            assert_equal 'raw of /vmfs/volumes/datastore/web/web.vmdk', File.read(File.join(convert, 'disk0.raw'))
            refute_path_exists File.dirname(probe)
        end
    end

    def test_prepare_stops_before_any_downtime_when_the_guest_cannot_be_converted
        Dir.mktmpdir do |dir|
            client = two_datastore_client
            client.results[:os_morph] = false
            client.morph_output = "virt-v2v-in-place: error: virt-v2v is unable to convert this guest type (linux/alpinelinux)\n"
            state, copies, output = prepare_vddk(build_vm(client), dir)

            assert_equal false, state
            assert_equal 2, copies.length
            # Each disk was tried as the root disk, as the commit would.
            assert_equal 2, client.calls.count {|call| call[0] == :os_morph }
            assert_empty client.snapshot_list
            assert_empty Dir.children(dir)
            assert_includes output, 'virt-v2v-in-place cannot convert'
        end
    end

    def test_prepare_goes_on_when_the_running_guest_keeps_its_filesystem_in_use
        # The NTFS of a running Windows guest is dirty, so virt-v2v mounts it
        # read-only; after the clean shutdown of the commit, it can write to it.
        Dir.mktmpdir do |dir|
            client = two_datastore_client
            client.results[:os_morph] = false
            client.morph_output = 'virt-v2v-in-place: error: filesystem was mounted read-only, even though we ' \
                                  'asked for it to be mounted read-write.  This usually means that the filesystem ' \
                                  "was not cleanly unmounted.\n"
            state, _copies, output = prepare_vddk(build_vm(client), dir)

            assert_kind_of Hash, state
            assert_includes output, 'after the shutdown'
        end
    end

    def test_prepare_conversion_check_tries_the_next_disk_as_the_commit_does
        Dir.mktmpdir do |dir|
            client = two_datastore_client
            client.results[:os_morph] = [false, true]
            state, = prepare_vddk(build_vm(client), dir)

            assert_kind_of Hash, state
            assert_equal ['disk0.qcow2', 'disk1.qcow2'],
                         client.calls.select {|call| call[0] == :os_morph }.map {|call| File.basename(call[1]) }
        end
    end

    def test_prepare_never_quiesces_the_snapshot
        # The migrated disk is the base plus every write until the clean
        # shutdown of commit, so quiescing the split point adds nothing.
        [TOOLS_RUNNING, NO_TOOLS].each do |summary|
            Dir.mktmpdir do |dir|
                client = two_datastore_client
                client.summary = summary
                prepare_vddk(build_vm(client), dir)
                assert_equal [[:snapshot_vm, false]], client.calls.select {|call| call[0] == :snapshot_vm }
            end
        end
    end

    def test_ssh_prepare_after_a_vddk_prepare_still_clears_the_clone_directory
        Dir.mktmpdir do |dir|
            client = two_datastore_client
            transfer = File.join(dir, 'esxi_client-web vm')
            FileUtils.mkdir_p(transfer)
            File.write(File.join(transfer, 'oneswap-delta-state.yaml'),
                       { 'transport' => 'vddk', 'clone_dir' => nil, 'transfer_dir' => transfer }.to_yaml)

            capture_io { build_vm(client).live2kvm_prepare(dir) }

            assert_includes client.calls, [:remove_files, '/vmfs/volumes/datastore/web/vmkfstools_output']
        end
    end

    def test_vddk_prepare_removes_clones_left_by_a_previous_ssh_prepare
        Dir.mktmpdir do |dir|
            client = two_datastore_client
            stale = '/vmfs/volumes/datastore/web/vmkfstools_output'
            transfer = File.join(dir, 'esxi_client-web vm')
            FileUtils.mkdir_p(transfer)
            File.write(File.join(transfer, 'oneswap-delta-state.yaml'),
                       { 'transport' => 'ssh', 'clone_dir' => stale, 'transfer_dir' => transfer }.to_yaml)

            state, = prepare_vddk(build_vm(client), dir)

            assert_equal 'vddk', state['transport']
            assert_includes client.calls, [:remove_files, stale]
        end
    end

    def test_reading_descriptors_leaves_no_temporary_files
        client = two_datastore_client
        vm = build_vm(client)
        vm.refresh_vmx
        vm.vmdk_info('web-000001.vmdk')

        targets = client.calls.select {|call| call[0] == :pull_files }.map(&:last)
        assert_equal 2, targets.length
        targets.each {|path| refute_path_exists path }
    end

    # --- commit --------------------------------------------------------------

    def prepared_state(dir, transport = 'vddk')
        client = two_datastore_client
        vm = build_vm(client)
        state = nil
        capture_io do
            state = transport == 'vddk' ? vm.live2kvm_prepare(dir) {|_p, t| File.write(t, 'raw') } : vm.live2kvm_prepare(dir)
        end
        client.calls.clear
        [client, state]
    end

    def test_commit_applies_absolute_extents_from_their_local_copy_in_disk_order
        Dir.mktmpdir do |dir|
            client, state = prepared_state(dir)
            client.remote_files["/vmfs/volumes/#{DS2_UUID}/web/web-000001-sesparse.vmdk"] = 'delta 2'
            client.remote_files['/vmfs/volumes/datastore/web/web-000001-sesparse.vmdk'] = 'delta 1'
            client.results[:os_morph] = [false, true]
            vm = build_vm(client)
            result = nil
            capture_io { result = vm.live2kvm_commit(dir) }

            assert_equal state['results_dir'], result
            transfer = state['transfer_dir']
            applies = client.calls.select {|call| call[0] == :apply }
            assert_equal [
                [:apply, File.join(transfer, 'web-000001-sesparse.vmdk'), File.join(state['convert_dir'], 'disk0.raw')],
                [:apply, File.join(transfer, 'web-000001-sesparse.vmdk'), File.join(state['convert_dir'], 'disk1.raw')]
            ], applies
            morphs = client.calls.select {|call| call[0] == :os_morph }.map {|call| File.basename(call[1]) }
            assert_equal ['disk0.raw', 'disk1.raw'], morphs
        end
    end

    def test_commit_failure_after_shutdown_keeps_state_for_retry
        Dir.mktmpdir do |dir|
            client, state = prepared_state(dir, 'ssh')
            client.remote_files["/vmfs/volumes/#{DS2_UUID}/web/web-000001-sesparse.vmdk"] = 'delta'
            client.remote_files['/vmfs/volumes/datastore/web/web-000001-sesparse.vmdk'] = 'delta'
            client.results[:apply] = false
            vm = build_vm(client)
            result = nil
            output, = capture_io { result = vm.live2kvm_commit(dir) }

            assert_equal false, result
            assert_path_exists state['convert_dir']
            retained = vm.live2kvm_state(dir)
            assert_equal state['disks'], retained['disks']
            # The clones were released at prepare, once the base copies were local.
            assert_nil retained['clone_dir']
            refute client.calls.any? {|call| call[0] == :remove_snapshot_vm }
            assert_includes output, 'powered off'
            assert_includes output, '--delta-commit'
            assert_includes output, '--delta-cleanup'

            # The VM is already off: a retry must not need a second shutdown.
            client.results[:apply] = true
            client.calls.clear
            capture_io { result = build_vm(client).live2kvm_commit(dir) }
            assert_equal state['results_dir'], result
            refute client.calls.any? {|call| call[0] == :shutdown_vm }
        end
    end

    def test_commit_morph_failure_discards_the_modified_base_copies
        Dir.mktmpdir do |dir|
            client, state = prepared_state(dir)
            client.remote_files['/vmfs/volumes/datastore/web/web-000001-sesparse.vmdk'] = 'delta'
            client.remote_files["/vmfs/volumes/#{DS2_UUID}/web/web-000001-sesparse.vmdk"] = 'delta'
            client.results[:os_morph] = false
            result = nil
            output, = capture_io { result = build_vm(client).live2kvm_commit(dir) }

            # virt-v2v-in-place already changed the copies: they cannot be reused.
            assert_equal false, result
            assert_equal ['oneswap-delta-state.yaml'], Dir.children(state['transfer_dir'])
            assert_includes output, '--delta-cleanup'
            refute_includes output, '--delta-commit'

            # The kept state still names the snapshot for the rollback.
            capture_io { assert_equal true, build_vm(client).live2kvm_cleanup(dir) }
            assert_empty client.snapshot_list
            refute_path_exists state['transfer_dir']
        end
    end

    def test_commit_refuses_disks_that_changed_after_prepare
        Dir.mktmpdir do |dir|
            client, state = prepared_state(dir)
            # A backup snapshot taken after prepare moved the VMX to new deltas.
            client.remote_files['/vmfs/volumes/datastore/web/web.vmx'] =
                client.remote_files['/vmfs/volumes/datastore/web/web.vmx'].gsub('-000001.vmdk', '-000002.vmdk')
            result = nil
            output, = capture_io { result = build_vm(client).live2kvm_commit(dir) }

            assert_equal false, result
            refute client.calls.any? {|call| call[0] == :shutdown_vm }
            assert_path_exists state['convert_dir']
            assert_includes output, 'web-000002.vmdk'
        end
    end

    def test_commit_renames_legacy_base_copies_to_their_disk_position
        Dir.mktmpdir do |dir|
            client, state = prepared_state(dir)
            convert = state['convert_dir']
            # A state prepared by an older release names the copies after the
            # parent disks, which sort differently than the VMX order.
            legacy = ['web.raw', 'data.raw'].map {|name| File.join(convert, name) }
            state['disks'].zip(legacy).each do |disk, path|
                File.delete(disk['converted_raw_base_path'])
                File.write(path, "base of #{File.basename(path)}")
                disk['converted_raw_base_path'] = path
            end
            File.write(File.join(state['transfer_dir'], 'oneswap-delta-state.yaml'), state.to_yaml)
            client.remote_files['/vmfs/volumes/datastore/web/web-000001-sesparse.vmdk'] = 'delta'
            client.remote_files["/vmfs/volumes/#{DS2_UUID}/web/web-000001-sesparse.vmdk"] = 'delta'
            results = nil
            capture_io { results = build_vm(client).live2kvm_commit(dir) }

            assert_equal ['disk0.raw', 'disk1.raw'], ESXi::VirtualMachine.disk_files(results)
            assert_equal 'base of web.raw', File.read(File.join(results, 'disk0.raw'))
            assert_equal 'base of data.raw', File.read(File.join(results, 'disk1.raw'))
        end
    end

    def with_deltas(client)
        client.remote_files['/vmfs/volumes/datastore/web/web-000001-sesparse.vmdk'] = 'delta'
        client.remote_files["/vmfs/volumes/#{DS2_UUID}/web/web-000001-sesparse.vmdk"] = 'delta'
        client
    end

    def test_commit_retry_after_an_interrupted_guest_conversion_does_not_apply_the_deltas_again
        Dir.mktmpdir do |dir|
            client, state = prepared_state(dir)
            with_deltas(client)
            client.define_singleton_method(:os_morph) {|*| raise Killed }
            assert_raises(Killed) { capture_io { build_vm(client).live2kvm_commit(dir) } }

            client.singleton_class.send(:remove_method, :os_morph)
            client.calls.clear
            result = nil
            output, = capture_io { result = build_vm(client).live2kvm_commit(dir) }

            assert_equal false, result
            assert_empty client.calls.select {|call| [:apply, :os_morph].include?(call[0]) }
            assert_equal ['oneswap-delta-state.yaml'], Dir.children(state['transfer_dir'])
            assert_includes output, 'stopped during the guest conversion'
        end
    end

    def test_commit_stops_when_a_snapshot_is_taken_during_the_shutdown
        Dir.mktmpdir do |dir|
            client, state = prepared_state(dir)
            with_deltas(client)
            client.define_singleton_method(:shutdown_vm) do |_id, tools|
                @calls << [:shutdown_vm, tools]
                @states = ['Powered off']
                # A backup job snapshots the VM while the guest shuts down.
                @snapshot_list << { :id => '7', :name => 'backup', :description => 'backup job' }
                path = '/vmfs/volumes/datastore/web/web.vmx'
                @remote_files[path] = @remote_files[path].gsub('-000001.vmdk', '-000002.vmdk')
                true
            end
            result = nil
            output, = capture_io { result = build_vm(client).live2kvm_commit(dir) }

            assert_equal false, result
            assert_empty client.calls.select {|call| call[0] == :apply }
            assert_path_exists state['convert_dir']
            assert_includes output, 'web-000002.vmdk'
        end
    end

    def test_commit_needs_its_local_tools_before_the_shutdown
        Dir.mktmpdir do |dir|
            client, state = prepared_state(dir)
            vm = build_vm(client)
            vm.define_singleton_method(:missing_commands) {|_commands| ['virt-v2v-in-place'] }
            result = nil
            output, = capture_io { result = vm.live2kvm_commit(dir) }

            assert_equal false, result
            assert_empty client.calls.select {|call| call[0] == :shutdown_vm }
            assert_includes output, 'virt-v2v-in-place'
            assert_path_exists state['convert_dir']
        end
    end

    def test_commit_needs_every_base_copy_before_the_shutdown
        Dir.mktmpdir do |dir|
            client, state = prepared_state(dir)
            File.delete(state['disks'][1]['converted_raw_base_path'])
            result = nil
            output, = capture_io { result = build_vm(client).live2kvm_commit(dir) }

            assert_equal false, result
            assert_empty client.calls.select {|call| call[0] == :shutdown_vm }
            assert_includes output, 'disk1.raw'
        end
    end

    def test_commit_keeps_state_when_the_clones_cannot_be_removed
        Dir.mktmpdir do |dir|
            client = with_deltas(two_datastore_client)
            # The datastore refuses to remove the clones, at prepare and at commit.
            client.results[:remove_files] = false
            capture_io { build_vm(client).live2kvm_prepare(dir) }
            state = build_vm(client).live2kvm_state(dir)
            result = nil
            output, = capture_io { result = build_vm(client).live2kvm_commit(dir) }

            # The disks are ready to import; only the clones still need a cleanup.
            assert_equal state['results_dir'], result
            assert_equal '/vmfs/volumes/datastore/web/vmkfstools_output', build_vm(client).live2kvm_state(dir)['clone_dir']
            assert_includes output, '--delta-cleanup'
        end
    end

    def test_commit_keeps_state_when_shutdown_fails
        Dir.mktmpdir do |dir|
            client, state = prepared_state(dir)
            client.results[:shutdown_vm] = false
            result = nil
            output, = capture_io { result = build_vm(client).live2kvm_commit(dir) }

            assert_equal false, result
            assert_path_exists state['convert_dir']
            assert_includes output, 'still running'
        end
    end

    # The VM already had a user snapshot before prepare: the OneSwap deltas
    # (-000002) sit on top of the user's ones (-000001).
    def user_snapshot_client
        FakeClient.new.tap do |c|
            c.snapshot_list << { :id => '1', :name => 'before-patching', :description => 'customer' }
            c.remote_files['/vmfs/volumes/datastore/web/web.vmx'] = <<~VMX
                scsi0:0.fileName = "web-000002.vmdk"
                scsi0:1.fileName = "/vmfs/volumes/#{DS2_UUID}/web/web-000002.vmdk"
            VMX
            ['/vmfs/volumes/datastore/web', "/vmfs/volumes/#{DS2_UUID}/web"].each do |folder|
                c.remote_files["#{folder}/web-000002.vmdk"] = descriptor('web-000001.vmdk')
                c.remote_files["#{folder}/web-000001.vmdk"] = descriptor('web.vmdk')
                c.remote_files["#{folder}/web.vmdk"] = descriptor(nil, 'vmfs')
                c.remote_files["#{folder}/web-000002-sesparse.vmdk"] = 'delta'
            end
            # Removing the OneSwap snapshot points the VMX back to its parents.
            c.define_singleton_method(:remove_snapshot_vm) do |_id, snapshot_id|
                @calls << [:remove_snapshot_vm, snapshot_id]
                @snapshot_list.reject! {|s| s[:id] == snapshot_id }
                path = '/vmfs/volumes/datastore/web/web.vmx'
                @remote_files[path] = @remote_files[path].gsub('-000002.vmdk', '-000001.vmdk')
                true
            end
        end
    end

    def test_commit_with_a_user_snapshot_removes_only_the_oneswap_one
        Dir.mktmpdir do |dir|
            client = user_snapshot_client
            capture_io { build_vm(client).live2kvm_prepare(dir) {|_p, t| File.write(t, 'raw') } }
            output, = capture_io { build_vm(client).live2kvm_commit(dir) }

            assert_equal ['before-patching'], client.snapshot_list.map {|s| s[:name] }
            refute_includes client.calls, [:remove_snapshot_vm, '1']
            assert_includes output, 'Verified VMX disk backing'
            assert_equal 'cleaned', build_vm(client).live2kvm_state(dir)['commit_stage']
        end
    end

    def test_commit_accepts_the_base_disks_when_the_parent_snapshot_was_deleted_meanwhile
        Dir.mktmpdir do |dir|
            client = user_snapshot_client
            capture_io { build_vm(client).live2kvm_prepare(dir) {|_p, t| File.write(t, 'raw') } }
            # The user deletes the older snapshot: its delta merges into the base disk.
            client.snapshot_list.reject! {|s| s[:id] == '1' }
            client.define_singleton_method(:remove_snapshot_vm) do |_id, snapshot_id|
                @snapshot_list.reject! {|s| s[:id] == snapshot_id }
                path = '/vmfs/volumes/datastore/web/web.vmx'
                @remote_files[path] = @remote_files[path].gsub('-000002.vmdk', '.vmdk')
                true
            end
            output, = capture_io { build_vm(client).live2kvm_commit(dir) }

            assert_includes output, 'Verified VMX disk backing'
            assert_equal 'cleaned', build_vm(client).live2kvm_state(dir)['commit_stage']
        end
    end

    def test_commit_verification_flags_disks_that_still_continue_from_the_oneswap_delta
        Dir.mktmpdir do |dir|
            client, = prepared_state(dir)
            with_deltas(client)
            client.snapshot_list.unshift({ :id => '1', :name => 'other', :description => 'customer' })
            # The snapshot is gone from the list, but its delta was never merged.
            unmerged = descriptor('web-000001.vmdk')
            client.define_singleton_method(:remove_snapshot_vm) do |_id, snapshot_id|
                @snapshot_list.reject! {|s| s[:id] == snapshot_id }
                path = '/vmfs/volumes/datastore/web/web.vmx'
                @remote_files[path] = @remote_files[path].gsub('-000001.vmdk', '-000003.vmdk')
                @remote_files['/vmfs/volumes/datastore/web/web-000003.vmdk'] = unmerged
                @remote_files["/vmfs/volumes/#{DS2_UUID}/web/web-000003.vmdk"] = unmerged
                true
            end
            output, = capture_io { build_vm(client).live2kvm_commit(dir) }

            assert_includes output, 'VMX still points to snapshot descriptor(s)'
            assert_equal 'migrated', build_vm(client).live2kvm_state(dir)['commit_stage']
        end
    end

    def test_cleanup_completes_while_a_later_snapshot_of_the_user_remains
        Dir.mktmpdir do |dir|
            client, state = prepared_state(dir)
            # A snapshot taken after prepare: its delta continues from the OneSwap one.
            client.snapshot_list << { :id => '7', :name => 'backup', :description => 'backup job' }
            vmx = '/vmfs/volumes/datastore/web/web.vmx'
            client.remote_files[vmx] = client.remote_files[vmx].gsub('-000001.vmdk', '-000002.vmdk')
            folders = ['/vmfs/volumes/datastore/web', "/vmfs/volumes/#{DS2_UUID}/web"]
            folders.each {|folder| client.remote_files["#{folder}/web-000002.vmdk"] = descriptor('web-000001.vmdk') }
            # Removing the OneSwap snapshot merges its delta into the base disks.
            merged = descriptor('web.vmdk')
            client.define_singleton_method(:remove_snapshot_vm) do |_id, snapshot_id|
                @snapshot_list.reject! {|s| s[:id] == snapshot_id }
                folders.each {|folder| @remote_files["#{folder}/web-000002.vmdk"] = merged }
                true
            end
            result = nil
            capture_io { result = build_vm(client).live2kvm_cleanup(dir) }

            assert_equal true, result
            refute_path_exists state['transfer_dir']
            assert_equal ['backup'], client.snapshot_list.map {|s| s[:name] }
        end
    end

    def test_cleanup_of_an_interrupted_prepare_accepts_base_disks_named_like_deltas
        Dir.mktmpdir do |dir|
            client = FakeClient.new
            client.remote_files['/vmfs/volumes/datastore/web/web.vmx'] = %(scsi0:0.fileName = "app-202401.vmdk"\n)
            client.remote_files['/vmfs/volumes/datastore/web/app-202401.vmdk'] = descriptor(nil, 'vmfs')
            client.remote_files['/vmfs/volumes/datastore/web/app-202401-000001.vmdk'] = descriptor('app-202401.vmdk')
            # The snapshot moved the VMX to app-202401-000001.vmdk.
            client.define_singleton_method(:snapshot_vm) do |_id, name, options|
                @snapshot_list << { :id => '100', :name => name, :description => options[:description] }
                path = '/vmfs/volumes/datastore/web/web.vmx'
                @remote_files[path] = %(scsi0:0.fileName = "app-202401-000001.vmdk"\n)
                true
            end
            assert_raises(Killed) { capture_io { build_vm(client).live2kvm_prepare(dir) {|*| raise Killed } } }

            result = nil
            capture_io { result = build_vm(client).live2kvm_cleanup(dir) }

            assert_equal true, result
            assert_empty client.snapshot_list
        end
    end

    def test_state_is_replaced_atomically
        Dir.mktmpdir do |dir|
            client, state = prepared_state(dir)
            state_file = File.join(state['transfer_dir'], 'oneswap-delta-state.yaml')
            before = File.read(state_file)
            # The disk fills up while the new state is written.
            full = ->(path, *) { File.open(path, 'w') {}; raise Errno::ENOSPC, path }
            File.stub(:write, full) do
                refute build_vm(client).send(:write_live2kvm_state, dir, state.merge('clone_dir' => nil))
            end

            assert_equal before, File.read(state_file)
            assert_equal ['convert', 'oneswap-delta-state.yaml'], Dir.children(state['transfer_dir']).sort
        end
    end

    def test_commit_refuses_a_delta_that_no_longer_continues_from_the_prepared_base
        Dir.mktmpdir do |dir|
            client, = prepared_state(dir)
            # A revert to an older snapshot made a new delta under the same file name.
            client.remote_files['/vmfs/volumes/datastore/web/web-000001.vmdk'] = descriptor('older.vmdk')
            result = nil
            output, = capture_io { result = build_vm(client).live2kvm_commit(dir) }

            assert_equal false, result
            assert_empty client.calls.select {|call| call[0] == :shutdown_vm }
            assert_includes output, 'older.vmdk'
        end
    end

    def test_commit_keeps_the_state_until_the_disks_are_imported
        Dir.mktmpdir do |dir|
            client, state = prepared_state(dir)
            with_deltas(client)
            vm = build_vm(client)
            results = nil
            capture_io { results = vm.live2kvm_commit(dir) }

            assert_equal state['results_dir'], results
            # An import that fails can still be retried with --delta-commit.
            assert_equal ['oneswap-delta-state.yaml'], Dir.children(state['transfer_dir'])

            capture_io { vm.live2kvm_finish(dir) }
            refute_path_exists state['transfer_dir']
        end
    end

    def test_commit_retry_after_the_guest_conversion_returns_the_migrated_disks
        Dir.mktmpdir do |dir|
            client, state = prepared_state(dir)
            with_deltas(client)
            # Killed while the snapshot was removed, after the guest conversion.
            client.define_singleton_method(:remove_snapshot_vm) {|*| raise Killed }
            assert_raises(Killed) { capture_io { build_vm(client).live2kvm_commit(dir) } }
            client.singleton_class.send(:remove_method, :remove_snapshot_vm)
            client.calls.clear

            results = nil
            capture_io { results = build_vm(client).live2kvm_commit(dir) }

            assert_equal state['results_dir'], results
            assert_equal ['disk0.raw', 'disk1.raw'], ESXi::VirtualMachine.disk_files(results)
            assert_empty client.calls.select {|call| [:apply, :os_morph, :shutdown_vm].include?(call[0]) }
            assert_empty client.snapshot_list
        end
    end

    def test_commit_retry_refuses_the_disks_of_a_vm_that_ran_since_its_migration
        Dir.mktmpdir do |dir|
            client, state = prepared_state(dir)
            with_deltas(client)
            log = '/vmfs/volumes/datastore/web/vmware.log'
            client.signatures[log] = '1000 1792278256'
            # The import fails afterwards, so the state is kept for a retry.
            capture_io { build_vm(client).live2kvm_commit(dir) }
            # The VM was powered on and off again: ESXi started a new log.
            client.signatures[log] = '2000 1792279999'

            result = nil
            output, = capture_io { result = build_vm(client).live2kvm_commit(dir) }

            assert_equal false, result
            assert_includes output, 'ran'
            assert_path_exists state['results_dir']
        end
    end

    def test_commit_retry_with_an_unreadable_power_state_asks_for_a_retry
        Dir.mktmpdir do |dir|
            client, = prepared_state(dir)
            with_deltas(client)
            capture_io { build_vm(client).live2kvm_commit(dir) }
            client.states = [nil]

            result = nil
            output, = capture_io { result = build_vm(client).live2kvm_commit(dir) }

            assert_equal false, result
            assert_includes output, 'retry'
            refute_includes output, '--delta-prepare'
        end
    end

    def test_commit_retry_resumes_when_the_migrated_stage_was_not_written
        Dir.mktmpdir do |dir|
            client, state = prepared_state(dir)
            with_deltas(client)
            vm = build_vm(client)
            # The disk is full once the guest conversion is done.
            write = vm.method(:write_live2kvm_state)
            vm.define_singleton_method(:write_live2kvm_state) do |target, current|
                ['migrated', 'cleaned'].include?(current['commit_stage']) ? false : write.call(target, current)
            end
            capture_io { vm.live2kvm_commit(dir) }
            assert_equal 'morphing', build_vm(client).live2kvm_state(dir)['commit_stage']
            client.calls.clear

            results = nil
            capture_io { results = build_vm(client).live2kvm_commit(dir) }

            assert_equal state['results_dir'], results
            assert_empty client.calls.select {|call| [:apply, :os_morph].include?(call[0]) }
        end
    end

    def test_commit_check_errors_ask_for_a_retry_not_a_new_prepare
        Dir.mktmpdir do |dir|
            client, = prepared_state(dir)
            client.results[:snapshots] = false
            result = nil
            output, = capture_io { result = build_vm(client).live2kvm_commit(dir) }

            assert_equal false, result
            assert_includes output, 'Retry --delta-commit'
            refute_includes output, '--delta-prepare'
        end
    end

    def test_prepare_keeps_the_previous_state_when_its_clones_cannot_be_removed
        Dir.mktmpdir do |dir|
            client = two_datastore_client
            # The clones of an SSH prepare stay on the datastore.
            client.results[:remove_files] = false
            capture_io { build_vm(client).live2kvm_prepare(dir) }
            clone_dir = build_vm(client).live2kvm_state(dir)['clone_dir']

            state, copies, output = prepare_vddk(build_vm(client), dir)

            assert_equal false, state
            assert_empty copies
            assert_equal clone_dir, build_vm(client).live2kvm_state(dir)['clone_dir']
            assert_includes output, '--delta-cleanup'
        end
    end

    def test_cleanup_of_an_interrupted_prepare_of_a_linked_clone_completes
        Dir.mktmpdir do |dir|
            # A linked clone: its own disk continues from the disk of its parent VM.
            client = FakeClient.new
            vmx = '/vmfs/volumes/datastore/web/web.vmx'
            client.remote_files[vmx] = %(scsi0:0.fileName = "web-000001.vmdk"\n)
            client.remote_files['/vmfs/volumes/datastore/web/web-000001.vmdk'] =
                descriptor('/vmfs/volumes/datastore/parent/parent.vmdk')
            client.remote_files['/vmfs/volumes/datastore/web/web-000002.vmdk'] = descriptor('web-000001.vmdk')
            client.define_singleton_method(:snapshot_vm) do |_id, name, options|
                @snapshot_list << { :id => '100', :name => name, :description => options[:description] }
                @remote_files[vmx] = %(scsi0:0.fileName = "web-000002.vmdk"\n)
                true
            end
            client.define_singleton_method(:remove_snapshot_vm) do |_id, snapshot_id|
                @snapshot_list.reject! {|s| s[:id] == snapshot_id }
                @remote_files[vmx] = %(scsi0:0.fileName = "web-000001.vmdk"\n)
                true
            end
            assert_raises(Killed) { capture_io { build_vm(client).live2kvm_prepare(dir) {|*| raise Killed } } }

            result = nil
            capture_io { result = build_vm(client).live2kvm_cleanup(dir) }

            assert_equal true, result
            assert_empty client.snapshot_list
        end
    end

    def test_commit_retry_does_not_import_disks_of_a_vm_powered_on_again
        Dir.mktmpdir do |dir|
            client, state = prepared_state(dir)
            with_deltas(client)
            capture_io { build_vm(client).live2kvm_commit(dir) }
            # The VM was powered on again after the migration, e.g. to roll back.
            client.states = ['Powered on']

            result = nil
            output, = capture_io { result = build_vm(client).live2kvm_commit(dir) }

            assert_equal false, result
            assert_includes output, '--delta-prepare'
            assert_path_exists state['results_dir']
        end
    end

    # --- cleanup -------------------------------------------------------------

    def test_cleanup_fails_when_the_snapshot_list_cannot_be_read
        Dir.mktmpdir do |dir|
            client, state = prepared_state(dir)
            client.results[:snapshots] = false
            result = nil
            capture_io { result = build_vm(client).live2kvm_cleanup(dir) }

            assert_equal false, result
            assert_equal state, build_vm(client).live2kvm_state(dir)
        end
    end

    def test_cleanup_removes_remote_clones_even_when_the_snapshot_stays
        Dir.mktmpdir do |dir|
            client = two_datastore_client
            # The clones of the prepare could not be removed back then.
            client.results[:remove_files] = false
            capture_io { build_vm(client).live2kvm_prepare(dir) }
            clone_dir = build_vm(client).live2kvm_state(dir)['clone_dir']
            client.results[:remove_files] = true
            client.results[:remove_snapshot_vm] = false
            result = nil
            capture_io { result = build_vm(client).live2kvm_cleanup(dir) }

            assert_equal false, result
            assert_includes client.calls, [:remove_files, clone_dir]
            assert_nil build_vm(client).live2kvm_state(dir)['clone_dir']
        end
    end

    def test_cleanup_keeps_state_while_the_vmx_still_uses_the_snapshot_disks
        Dir.mktmpdir do |dir|
            client, state = prepared_state(dir)
            # The snapshot entry is gone, but its disks were never consolidated.
            client.snapshot_list.clear
            result = nil
            output, = capture_io { result = build_vm(client).live2kvm_cleanup(dir) }

            assert_equal false, result
            assert_path_exists state['transfer_dir']
            assert_includes output, 'consolidat'
        end
    end

    def test_cleanup_does_not_warn_about_a_clone_directory_already_removed
        Dir.mktmpdir do |dir|
            client, state = prepared_state(dir, 'ssh')
            File.write(File.join(state['transfer_dir'], 'oneswap-delta-state.yaml'),
                       state.merge('clone_dir' => nil).to_yaml)
            output, = capture_io { assert_equal true, build_vm(client).live2kvm_cleanup(dir) }

            refute_includes output, 'missing or unsafe'
        end
    end

    def test_cleanup_accepts_an_equivalent_work_dir_spelling
        Dir.mktmpdir do |dir|
            client, state = prepared_state(dir)
            result = nil
            capture_io { result = build_vm(client).live2kvm_cleanup("#{dir}/") }

            assert_equal true, result
            refute_path_exists state['transfer_dir']
        end
    end

    def test_current_delta_size_reads_absolute_extents_without_writing_state
        Dir.mktmpdir do |dir|
            client, state = prepared_state(dir)
            client.remote_files['/vmfs/volumes/datastore/web/web-000001-sesparse.vmdk'] = 'a' * 3
            client.remote_files["/vmfs/volumes/#{DS2_UUID}/web/web-000001-sesparse.vmdk"] = 'b' * 4
            before = File.read(File.join(state['transfer_dir'], 'oneswap-delta-state.yaml'))

            info = build_vm(client).live2kvm_current_delta_size(dir)

            assert_equal 7, info[:bytes]
            assert_equal before, File.read(File.join(state['transfer_dir'], 'oneswap-delta-state.yaml'))
        end
    end

    def test_transfer_size_counts_the_files_below_a_vm_named_directory
        Dir.mktmpdir do |dir|
            # The transfer dir has the VM name, which may hold glob characters.
            tree = File.join(dir, 'web[1] {a,b}*')
            FileUtils.mkdir_p(File.join(tree, 'sub'))
            File.write(File.join(tree, 'disk0.vmdk'), 'x' * 10)
            File.write(File.join(tree, 'sub', '.state'), 'y' * 5)

            assert_equal 15, build_vm(FakeClient.new).send(:local_tree_size, tree)
        end
    end

end
