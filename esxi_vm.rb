require 'tempfile'
require 'time'
require 'yaml'
require_relative 'esxi_client'

module ESXi; end

#
# Virtual Machine entity controlled by an ESXi SSH client
#
class ESXi::VirtualMachine

    attr_reader :live2kvm_snapshot_name

    # output from vim-cmd vmsvc/getallvms
    VM_INFO_KEYS = [:vmid, :name, :file, :guest_os, :version, :annotation]

    STATES ={
        :RUNNING  => 'Powered on',
        :POWEROFF => 'Powered off'
    }
    VIRT_V2V_OPTIONS_EXTRA = '-v --machine-readable'
    SHUTDOWN_TIMEOUT = 300
    # Disk controllers of a VMX, in the order of their vCenter device keys.
    CONTROLLERS = ['scsi', 'ide', 'sata', 'nvme']
    STATE_FILE = 'oneswap-delta-state.yaml'
    # virt-v2v cannot write to a filesystem that the running guest keeps in
    # use, such as the dirty NTFS of a running Windows guest.
    RUNNING_GUEST_FILESYSTEM = /mounted read-only|not cleanly unmounted|Hibernation or Fast Restart/

    def initialize(esxi_client, getallvms_info)
        self.class.validate_vm_info(getallvms_info)
        @client = esxi_client
        @logger = esxi_client.logger

        @name = getallvms_info[:name]
        @id = getallvms_info[:vmid]
        @os = getallvms_info[:guest_os]
        @version = getallvms_info[:version]
        @annotation = getallvms_info[:annotation]

        file = getallvms_info[:file]
        @datastore = file.split('] ', 2).first.delete_prefix('[')
        vm_folder = File.dirname(file.split('] ', 2)[1])
        @vm_storage = remote_expand_path(vm_folder, "#{ESXi::Client::DATASTORES_PATH}/#{@datastore}")
        @clone_dir = "#{@vm_storage}/vmkfstools_output"
        @vmx_file = storage_path(File.basename(file.split('] ', 2)[1]))
        @vmx = {}
    end

    def shutdown
        # Already off, e.g. when retrying a commit that failed after shutdown.
        return true if state == STATES[:POWEROFF]

        # Only a guest without VMware Tools is powered off hard: stopped Tools
        # may mean the guest is already shutting down.
        tools = tools_state
        return false if tools.nil?

        if tools == :stopped
            puts "VMware Tools are installed but not running in VM #{@name}: shut the guest down " \
                 '(or start VMware Tools), then retry.'
            return false
        end
        return false unless @client.shutdown_vm(@id, tools == :running)

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SHUTDOWN_TIMEOUT

        loop do
            current_state = state
            return true if current_state == STATES[:POWEROFF]

            unless current_state == STATES[:RUNNING]
                @logger.error "Unable to determine power state while shutting down VM #{@name}: #{current_state.inspect}"
                return false
            end

            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if remaining <= 0
                @logger.error "Timed out after #{SHUTDOWN_TIMEOUT}s waiting for VM #{@name} to power off"
                return false
            end

            sleep [5, remaining].min
        end
    end

    def start
        @client.start_vm(@id)
    end

    def create_snapshot(name = ESXi::Client.default_snapshot_name,
                        options = ESXi::Client.default_snapshot_options)
        @client.snapshot_vm(@id, name, options)
    end

    # TODO: Report document output with timers
    def live2kvm(target_dir)
        return false unless live2kvm_prepare(target_dir)

        live2kvm_commit(target_dir)
    end

    def live2kvm_prepare(target_dir, &copy_base)
        puts "Starting delta prepare for VM #{@name}."
        puts 'Running delta prepare prechecks...'
        return false unless live_storage_transfer_precheck
        puts 'Delta prepare prechecks completed.'

        @delta_transport = copy_base ? 'vddk' : 'ssh'
        transfer_dir = live2kvm_transfer_dir(target_dir)
        puts "Cleaning previous delta work directories at #{transfer_dir}..."
        previous_state = read_live2kvm_state(target_dir, :quiet => true)
        if previous_state.is_a?(Hash)
            # Its state is the only record of the clones of a previous SSH
            # prepare, which a VDDK prepare does not clone over.
            unless release_clone_dir(target_dir, previous_state)
                puts 'Delta prepare aborted: the clones of the previous prepare could not be removed. ' \
                     'Retry, or run --delta-cleanup first.'
                return false
            end
            return false unless remove_previous_snapshot(previous_state)
        end
        live_storage_transfer_cleanup(transfer_dir)

        results_dir = live2kvm_results_dir(target_dir)
        convert_dir = "#{transfer_dir}/convert"
        FileUtils.rm_r(results_dir) if Dir.exist?(results_dir)
        # Before the snapshot, so that nothing fails between the snapshot and
        # the state that records it.
        FileUtils.mkdir_p(convert_dir)
        puts 'Previous delta work directories cleaned.'

        puts "Creating premigrate snapshot for VM #{@name}..."
        @logger.info "Creating premigrate snapshot for VM #{@name}"
        t0 = Time.now
        snapshot_name = ESXi::Client.default_snapshot_name
        @live2kvm_snapshot_name = snapshot_name
        # Not quiesced: the migrated disks are the base plus every write until
        # the clean shutdown of the commit, whatever state the base froze in.
        unless create_snapshot(snapshot_name)
            puts "Delta prepare aborted: failed to create a snapshot of VM #{@name}."
            @logger.error 'Aborting live storage transfer due to failed snapshot creation'
            return false
        end

        puts "Snapshot created in #{format_elapsed(Time.now - t0)}."

        state = {
            'vm_name' => @name,
            'vm_storage_path' => @vm_storage,
            'datastore_path' => "#{ESXi::Client::DATASTORES_PATH}/#{@datastore}",
            'snapshot_name' => snapshot_name,
            'transfer_dir' => transfer_dir,
            'convert_dir' => convert_dir,
            'results_dir' => results_dir,
            'transport' => @delta_transport,
            'clone_dir' => copy_base ? nil : @clone_dir,
            'disks' => []
        }
        # Written before the long copies: a prepare that is killed meanwhile
        # can still be cleaned up, or replaced by the next prepare.
        unless write_live2kvm_state(target_dir, state)
            return abort_prepare(target_dir, state, 'failed to persist delta migration state')
        end

        if !copy_base && !@client.create_dir(@clone_dir)
            return abort_prepare(target_dir, state, "cannot create remote clone directory #{@clone_dir}")
        end

        puts 'Reading VMX and detecting active disks...'
        t0 = Time.now
        begin
            refresh_vmx # snapshots created new active disks
            descriptors = active_disks
            # Recorded first: the cleanup of an interrupted prepare checks them.
            state['disks'] = descriptors.map {|disk| { 'active_snapshot_descriptor' => disk } }
            write_live2kvm_state(target_dir, state)
            disks = descriptors.map {|disk| delta_disk(disk) }
        rescue StandardError => e
            @logger.debug e.backtrace.join("\n") if e.backtrace
            return abort_prepare(target_dir, state, e.message)
        end
        puts "Detected #{disks.length} active disk(s) in #{format_elapsed(Time.now - t0)}."
        if disks.empty?
            return abort_prepare(target_dir, state, 'no active disks detected for delta migration')
        end

        # Base copies are named after their position in the VMX, so that the
        # imported images keep the VM's disk order.
        disks.each_with_index do |disk, index|
            disk['converted_raw_base_path'] = "#{convert_dir}/#{self.class.disk_file_name(index)}"
        end

        base_convert_seconds = 0.0
        base_convert_bytes = 0
        if copy_base
            disks.each do |disk|
                parent = disk['parent_base_path']
                output_path = disk['converted_raw_base_path']
                begin
                    puts "Copying base disk via VDDK: #{parent}..."
                    t0 = Time.now
                    copy_base.call(parent, output_path)
                    raise "VDDK conversion output is missing: #{output_path}" unless File.exist?(output_path)

                    elapsed = Time.now - t0
                    puts "Copied base disk #{parent} via VDDK in #{format_elapsed(elapsed)}."
                    base_convert_seconds += elapsed
                    base_convert_bytes += File.size(output_path)
                rescue StandardError => e
                    @logger.debug e.backtrace.join("\n") if e.backtrace
                    return abort_prepare(target_dir, state,
                                         "failed disk #{parent} VDDK conversion: #{e.class}: #{e.message}")
                end
            end

            # VDDK copies and converts in one operation; it does not measure
            # the SCP transfer used for the remaining delta during commit.
            base_transfer_seconds = nil
            base_transfer_bytes = nil
            base_transfer_mib_s = nil
        else
            disks.each_with_index do |disk, index|
                parent = disk['parent_base_path']
                # Disks on different datastores can share a file name.
                clone_target = "#{@clone_dir}/disk#{index}.vmdk"

                puts "Cloning base disk on ESXi: #{parent}..."
                t0 = Time.now
                unless @client.clone_virtual_disk(parent, clone_target)
                    return abort_prepare(target_dir, state, "failed disk #{parent} clone")
                end

                puts "Cloned base disk #{parent} in #{format_elapsed(Time.now - t0)}."
            end

            @logger.info "Transferring VM #{@name} storage to #{transfer_dir}"
            puts "Transferring base disk files to local work dir #{transfer_dir}..."
            t0 = Time.now
            local_bytes = local_tree_size(transfer_dir)
            if !@client.pull_files("#{@clone_dir}/*", transfer_dir)
                return abort_prepare(target_dir, state, 'failed disk transfer')
            end
            base_transfer_seconds = Time.now - t0
            base_transfer_bytes = local_tree_size(transfer_dir) - local_bytes
            base_transfer_mib_s = mib_per_second(base_transfer_bytes, base_transfer_seconds)
            puts "Transferred base disk files in #{format_elapsed(base_transfer_seconds)}."

            disks.each_with_index do |disk, index|
                source = "#{transfer_dir}/disk#{index}.vmdk"
                target = disk['converted_raw_base_path']

                puts "Converting base disk to raw: #{disk['parent_base_path']}..."
                t0 = Time.now
                unless @client.convert_vmdk(source, target, 'raw')
                    return abort_prepare(target_dir, state, "failed disk #{source} conversion")
                end

                elapsed = Time.now - t0
                base_convert_seconds += elapsed
                base_convert_bytes += File.size(target) if File.exist?(target)
                puts "Converted #{File.basename(source)} to raw in #{format_elapsed(elapsed)}."
            end

            # The commit only needs the raw copies: the clones would take space
            # next to the growing snapshot until then.
            Dir.children(transfer_dir).each do |file|
                path = File.join(transfer_dir, file)
                FileUtils.rm_f(path) if file.end_with?('.vmdk') && File.file?(path)
            end
            release_clone_dir(target_dir, state)
        end
        base_convert_mib_s = mib_per_second(base_convert_bytes, base_convert_seconds)

        unless guest_conversion_possible?(disks, transfer_dir)
            return abort_prepare(target_dir, state,
                                 "virt-v2v-in-place cannot convert the guest of VM #{@name} (see its error above), " \
                                 'so the commit would fail after the VM shutdown')
        end

        puts 'Writing prepared delta state...'
        state.merge!(
            # Delta size is only a point-in-time value while the VM keeps running;
            # it can continue growing until the final commit phase shuts it down.
            'delta_size_bytes' => nil,
            'base_transfer_bytes' => base_transfer_bytes,
            'base_transfer_seconds' => base_transfer_seconds,
            'base_transfer_mib_s' => base_transfer_mib_s,
            'base_convert_bytes' => base_convert_bytes,
            'base_convert_seconds' => base_convert_seconds,
            'base_convert_mib_s' => base_convert_mib_s,
            'disks' => disks
        )
        unless write_live2kvm_state(target_dir, state)
            return abort_prepare(target_dir, state, 'failed to persist delta migration state')
        end
        puts "Prepared delta state written to #{live2kvm_state_file(target_dir)}."

        state
    end

    def live2kvm_commit(target_dir)
        state = read_live2kvm_state(target_dir)
        return false unless state

        transfer_dir = state['transfer_dir']
        convert_dir = state['convert_dir']
        results_dir = state['results_dir']
        disks = state['disks']
        prepare_again = 'Run --delta-prepare again, or --delta-cleanup to roll back.'
        if !disks.is_a?(Array) || disks.empty?
            return abort_commit('the prepared delta state contains no disks', prepare_again)
        end

        case state['commit_stage']
        when 'migrated', 'cleaned'
            return resume_migrated_commit(target_dir, state)
        when 'morphing'
            # The disks reach the results directory only after the guest conversion.
            return resume_migrated_commit(target_dir, state) if Dir.exist?(results_dir.to_s)

            return discard_base_copies_after_failed_morph(target_dir, state,
                                                          'a previous commit stopped during the guest conversion')
        end
        converted_disks = disks.map {|disk| File.basename(disk['converted_raw_base_path'].to_s) }
        missing = converted_disks.map {|disk| "#{convert_dir}/#{disk}" }.reject {|path| File.file?(path) }
        unless missing.empty?
            return abort_commit("prepared base disk copies are missing: #{missing.join(', ')}", prepare_again)
        end

        missing = missing_commands(['sesparse', 'virt-v2v-in-place'])
        return abort_commit("command(s) #{missing.join(', ')} not found") unless missing.empty?

        begin
            changed = prepared_disks_changed(state)
        rescue StandardError => e
            return abort_commit("unable to check the disks of VM #{@name}: #{e.message}", 'Retry --delta-commit.')
        end
        return abort_commit(changed, prepare_again) if changed

        t0 = Time.now
        @logger.warn "Shutting down VM #{@name}. Downtime begins"
        if !shutdown
            return keep_state_after_failed_commit(target_dir, state, "failed to shut down VM #{@name}", false)
        end

        # A snapshot taken while the guest was shutting down.
        begin
            changed = prepared_disks_changed(state)
        rescue StandardError => e
            changed = "unable to check the disks of VM #{@name}: #{e.message}"
        end
        return keep_state_after_failed_commit(target_dir, state, changed, true) if changed

        # transfer and apply active snapshot vmdk
        disks.each do |disk_data|
            # alma9-clone_17-000022.vmdk
            # alma9-clone --> vm name
            # _17 --> disk identifier
            # --> 000022 snapshots
            disk = disk_data['active_snapshot_descriptor']
            snapshot_extent = disk_data['active_snapshot_extent']

            # copy vmdk metadata + bits
            [disk, snapshot_extent].each do |file|
                source = storage_path(file)

                next if @client.pull_files(source, transfer_dir)

                return keep_state_after_failed_commit(target_dir, state, "failed vmdk file #{disk} transfer", true)
            end

            # apply active snapshot to flat converted disk; scp stores the
            # extent under its file name even when the VMX uses a full path
            snapshot = "#{transfer_dir}/#{File.basename(snapshot_extent)}"
            parent = disk_data['converted_raw_base_path']

            next if @client.apply_vmdk_snapshot_to_raw(snapshot, parent)

            message = "failed applying snapshot #{snapshot} to raw parent disk #{parent}"
            return keep_state_after_failed_commit(target_dir, state, message, true)
        end

        # From here on the copies change: a retry must not apply the deltas again.
        state['commit_stage'] = 'morphing'
        unless write_live2kvm_state(target_dir, state)
            state.delete('commit_stage')
            return keep_state_after_failed_commit(target_dir, state, 'failed to persist delta migration state', true)
        end

        os_morph_seconds = 0.0
        os_morph_disks_tried = 0
        converted_disks.each do |disk|
            root_disk_path = "#{convert_dir}/#{disk}"

            t_os_morph = Time.now
            os_morph_disks_tried += 1
            if @client.os_morph(root_disk_path, VIRT_V2V_OPTIONS_EXTRA)
                os_morph_seconds += Time.now - t_os_morph
                break
            end
            os_morph_seconds += Time.now - t_os_morph

            if converted_disks.last != disk
                @logger.warn "Failed to morph OS on disk #{disk}"
                @logger.info 'Trying next disk as root device conversion target'
                next
            end

            return discard_base_copies_after_failed_morph(target_dir, state, "failed to morph OS for VM #{@name}")
        end

        # The disks are migrated: a retry only finishes the cleanup and the import.
        state['commit_stage'] = 'migrated'
        state['vm_log'] = vm_log_signature
        write_live2kvm_state(target_dir, state)
        move_migrated_disks(state)
        write_live2kvm_metrics(target_dir, {
                                   'delta_os_morph_seconds' => os_morph_seconds,
                                   'delta_os_morph_disks_tried' => os_morph_disks_tried
                               })

        t_downtime = Time.now - t0
        t_downtime_formatted = Time.at(t_downtime).utc.strftime("%M:%S")

        @logger.info "Migrated VM #{@name} to KVM with downtime #{t_downtime_formatted}. VM disks at #{results_dir}"
        @logger.info "VM disks at #{results_dir}"

        finish_migrated_commit(target_dir, state)
    end

    #
    # Once the disks are imported, the prepared state of a commit is only kept
    # while its snapshot cleanup is incomplete.
    #
    def live2kvm_finish(target_dir)
        state = read_live2kvm_state(target_dir, :quiet => true)
        return unless state.is_a?(Hash)

        if state['commit_stage'] == 'cleaned'
            cleanup_local_state(target_dir, state)
        else
            puts "Prepared delta state kept at #{live2kvm_state_file(target_dir)}: run --delta-cleanup " \
                 'to finish removing the VMware snapshot.'
        end
    end

    def live2kvm_current_delta_size_bytes(target_dir)
        info = live2kvm_current_delta_size(target_dir)
        info && info[:bytes]
    end

    def live2kvm_current_delta_size(target_dir)
        state = read_live2kvm_state(target_dir)
        return nil unless state

        disks = state['disks']
        return nil unless disks.is_a?(Array) && !disks.empty?

        total = 0
        paths = []
        disks.each do |disk_data|
            extent = disk_data['active_snapshot_extent']
            raise 'prepared state is missing active snapshot extent' if extent.to_s.empty?

            # This is a point-in-time value. While the VM keeps running after
            # prepare, snapshot delta extents can continue to grow.
            path = storage_path(extent)
            @logger.debug "Reading live snapshot delta size from #{path}"
            size = @client.file_size_bytes(path)
            raise "unable to read live snapshot extent size for #{path}" if size.nil?

            paths << path
            total += size
        end

        {
            :bytes => total,
            :source => 'refreshed from ESXi snapshot extent',
            :paths => paths,
            :refreshed => true
        }
    rescue StandardError => e
        @logger.warn "Unable to refresh live snapshot delta size: #{e.message}"
        stored = state && state['delta_size_bytes'].to_i
        return nil unless stored && stored > 0

        {
            :bytes => stored,
            :source => 'stored prepare-time delta size',
            :paths => [],
            :refreshed => false,
            :warning => 'Warning: unable to refresh live snapshot delta size from ESXi; using stored prepare-time value.'
        }
    end

    def live2kvm_state(target_dir)
        read_live2kvm_state(target_dir)
    end

    def live2kvm_cleanup(target_dir)
        puts "Cleaning prepared delta migration for VM #{@name}"
        state = read_live2kvm_state(target_dir)
        if state.nil?
            puts "No prepared delta state found at #{live2kvm_state_file(target_dir)}."
            return cleanup_leftover_oneswap_snapshots(live2kvm_state_file(target_dir))
        end

        state_file = live2kvm_state_file(target_dir)
        snapshot_removed = cleanup_snapshot(state)
        # Also when the snapshot was not found: its disks may still be in use.
        vmx_verified = snapshot_removed && verify_vmx_base_disks(state, state_file)
        # Free the datastore even when the snapshot has to stay for a retry.
        clones_removed = release_clone_dir(target_dir, state)
        unless vmx_verified && clones_removed
            puts "Delta prepare cleanup failed; prepared state retained at #{state_file}. Retry with --delta-cleanup."
            return false
        end

        cleanup_local_state(target_dir, state)

        puts 'Delta prepare cleanup completed.'
        true
    end

    def disable_autostart
        @client.disable_vm_autostart(@id)
    end

    def refresh_vmx
        @logger.info "Reading vmx file #{@vmx_file}"

        vmx = read_remote_descriptor(@vmx_file)

        @logger.debug vmx.to_yaml
        @vmx = vmx
        vmx
    end

    def vmdk_info(fileName)
        read_remote_descriptor(storage_path(fileName))
    end

    # Output based on vim-cmd vmsvc/power.getstate $vmid
    def state
        @client.vm_state(@id)
    end

    def running?
        state == STATES[:RUNNING]
    end

    #
    # VDDK through vCenter only opens "[datastore] path" names, so the ESXi
    # path of a disk is mapped back to the name of its datastore.
    #
    # @param [String] path disk path under /vmfs/volumes/<datastore name or UUID>/
    # @param [Hash] datastore_names datastore name or UUID => datastore name
    #
    # @return [String] "[datastore] folder/disk.vmdk"
    #
    def vddk_path(path, datastore_names)
        prefix = "#{ESXi::Client::DATASTORES_PATH}/"
        volume, relative_path = path.delete_prefix(prefix).split('/', 2) if path.start_with?(prefix)
        datastore = datastore_names[volume]
        if datastore.nil? || relative_path.to_s.empty?
            raise "Unable to map disk #{path} to a vCenter datastore name for VDDK"
        end

        "[#{datastore}] #{relative_path}"
    end

    def poweroff?
        state == STATES[:POWEROFF]
    end

    #
    # @return [Symbol, nil] VMware Tools in the guest: :running (also out of
    #   date ones), :stopped or :missing; nil when unknown
    #
    def tools_state
        return unless load_summary

        # @summary string output is tricky to convert into a Hash
        return :running if @summary.include?('toolsRunningStatus = "guestToolsRunning"')

        @summary.include?('toolsStatus = "toolsNotInstalled"') ? :missing : :stopped
    end

    def load_summary
        @summary = @client.vm_summary(@id).to_s

        if @summary.empty?
            message = "Failed to read VM #{@name} summary"
            @logger.error message
            return
        end

        @summary
    end

    def active_disks
        refresh_vmx if @vmx.empty?

        disks = self.class.active_vmdks(@vmx)
        @logger.info("VM #{@name} has the following active disks: #{disks}")
        @disks = disks

        disks
    end

    private

    def live2kvm_transfer_dir(target_dir)
        "#{target_dir}/esxi_client-#{@name}"
    end

    def live2kvm_results_dir(target_dir)
        "#{target_dir}/esxi2kvm-#{@name}"
    end

    def live2kvm_state_file(target_dir)
        "#{live2kvm_transfer_dir(target_dir)}/#{STATE_FILE}"
    end

    def live2kvm_metrics_file(target_dir)
        "#{target_dir}/oneswap-metrics.yaml"
    end

    # Replaces the state in one step: it is the only record of the snapshot.
    def write_live2kvm_state(target_dir, state)
        state_file = live2kvm_state_file(target_dir)
        File.write("#{state_file}.tmp", state.to_yaml)
        File.rename("#{state_file}.tmp", state_file)
        true
    rescue StandardError => e
        FileUtils.rm_f("#{state_file}.tmp") if state_file
        @logger.error "Failed to write delta migration state: #{e.message}"
        false
    end

    def read_live2kvm_state(target_dir, quiet: false)
        state_file = live2kvm_state_file(target_dir)
        if !File.exist?(state_file)
            @logger.error "Delta migration state file not found at #{state_file}" unless quiet
            return nil
        end

        YAML.load_file(state_file)
    rescue StandardError => e
        @logger.error "Failed to read delta migration state: #{e.message}"
        nil
    end

    #
    # A new prepare replaces the previous one, whose snapshot would otherwise
    # stay on the VM under the new one.
    #
    def remove_previous_snapshot(state)
        return true if state['snapshot_name'].to_s.empty? || cleanup_snapshot(state)

        puts 'Delta prepare aborted: the snapshot of the previous prepare could not be removed. ' \
             'Retry, or run --delta-cleanup first.'
        false
    end

    #
    # Describe an active snapshot disk of the VMX and its base disk.
    #
    # @param [String] disk VMX file name of the active snapshot descriptor
    #
    # @return [Hash] prepared state entry for the disk
    #
    def delta_disk(disk)
        vmdk_data = vmdk_info(disk)

        # Independent disks are left out of snapshots, so the VMX still
        # points to the disk itself.
        parent = vmdk_data['parentFileNameHint'].to_s
        if parent.empty?
            raise "disk #{disk} has no snapshot delta; independent disks are not supported by delta migration"
        end

        create_type = vmdk_data['createType'].to_s
        unless create_type.casecmp?('seSparse')
            create_type = 'an unknown format' if create_type.empty?
            raise "snapshot disk #{disk} uses #{create_type}; delta migration needs SEsparse " \
                  'snapshots (VMFS6 datastores, or VMFS5 disks of 2 TB and larger)'
        end

        {
            'active_snapshot_descriptor' => disk,
            'active_snapshot_extent' => "#{disk.chomp('.vmdk')}-sesparse.vmdk",
            # A relative hint is relative to the snapshot descriptor, which may
            # be on another datastore than the VMX.
            'parent_base_path' => remote_expand_path(parent, File.dirname(storage_path(disk)))
        }
    end

    def abort_prepare(target_dir, state, reason)
        puts "Delta prepare aborted: #{reason}"
        @logger.error "Aborting live storage transfer due to #{reason}"
        release_clone_dir(target_dir, state)
        if cleanup_snapshot(state)
            FileUtils.remove_dir(state['transfer_dir']) if Dir.exist?(state['transfer_dir'])
        else
            puts "Warning: VM snapshot #{state['snapshot_name']} remains active. Run --delta-cleanup before retrying."
            # The prepared state names the snapshot for that cleanup.
            remove_local_copies(state['transfer_dir'])
        end
        false
    end

    def abort_commit(reason, advice = nil)
        @logger.error "Aborting delta commit before VM shutdown: #{reason}"
        puts "Delta commit aborted before shutdown: #{reason}."
        puts advice if advice
        false
    end

    #
    # virt-v2v-in-place has no dry run, so it converts throwaway overlays of
    # the base copies while the VM still runs: a guest it cannot convert would
    # otherwise only fail after the shutdown of the commit. Like the commit,
    # it tries the disks in order until one holds the guest.
    #
    def guest_conversion_possible?(disks, transfer_dir)
        puts 'Checking that virt-v2v-in-place can convert the guest...'
        probe_dir = "#{transfer_dir}/probe"
        FileUtils.mkdir_p(probe_dir)
        in_use = false
        converted = disks.each_with_index.any? do |disk, index|
            overlay = "#{probe_dir}/disk#{index}.qcow2"
            next false unless @client.create_overlay(disk['converted_raw_base_path'], overlay)

            output = []
            morphed = @client.os_morph(overlay, '', 'qcow2', output)
            FileUtils.rm_f(overlay)
            in_use ||= output.join.match?(RUNNING_GUEST_FILESYSTEM)
            morphed
        end
        return converted unless !converted && in_use

        puts 'Warning: the running guest keeps its filesystem in use, so virt-v2v-in-place cannot check its ' \
             'conversion now; the commit converts it after the shutdown.'
        true
    ensure
        FileUtils.rm_rf(probe_dir) if probe_dir
    end

    #
    # Commit applies the deltas recorded at prepare: a snapshot taken or
    # removed since then, or a disk added or removed, would migrate the wrong
    # data.
    #
    # @return [String, nil] how the disks changed, nil when they did not
    # @raise [StandardError] when the snapshots or the disks cannot be read
    #
    def prepared_disks_changed(state)
        snapshot_name = state['snapshot_name']
        if @client.snapshot_id_by_name(@id, snapshot_name).nil?
            return "VMware snapshot #{snapshot_name} of the prepare was not found"
        end

        refresh_vmx
        prepared = state['disks'].map {|disk| storage_path(disk['active_snapshot_descriptor'].to_s) }
        current = active_disks.map {|disk| storage_path(disk) }
        if prepared.sort != current.sort
            return "the disks of VM #{@name} changed after prepare (prepared: #{prepared.join(', ')}; " \
                   "current: #{current.join(', ')})"
        end

        # A revert to an older snapshot can give a new delta the same name.
        state['disks'].each do |disk|
            next unless disk['parent_base_path']

            parent = delta_disk(disk['active_snapshot_descriptor'])['parent_base_path']
            next if parent == disk['parent_base_path']

            return "snapshot disk #{disk['active_snapshot_descriptor']} continues from #{parent}, " \
                   "not from the prepared base #{disk['parent_base_path']}"
        end
        nil
    end

    #
    # A failed commit keeps the prepared base copies, so it can be retried
    # once the cause is fixed, or rolled back with --delta-cleanup.
    #
    def keep_state_after_failed_commit(target_dir, state, reason, powered_off)
        @logger.error "Aborting delta commit due to #{reason}"
        # Only the local copies are needed to retry, not the datastore clones.
        release_clone_dir(target_dir, state)

        snapshot_name = state['snapshot_name']
        puts "Delta commit failed: #{reason}."
        puts "Prepared delta state and base disk copies are kept at #{state['transfer_dir']}."
        if powered_off
            puts "VM #{@name} is powered off and VMware snapshot #{snapshot_name} is still active."
        else
            puts "VM #{@name} is still running (or did not finish shutting down) and VMware " \
                 "snapshot #{snapshot_name} is still active."
        end
        puts 'Fix the cause and retry with --delta-commit, or power the VM on and run ' \
             '--delta-cleanup to roll back.'
        false
    end

    #
    # virt-v2v-in-place may already have changed the base copies, and the
    # deltas cannot be applied to them again: only the state is kept, so that
    # the snapshot can still be removed.
    #
    def discard_base_copies_after_failed_morph(target_dir, state, reason)
        @logger.error "Aborting delta commit due to #{reason}"
        release_clone_dir(target_dir, state)
        remove_local_copies(state['transfer_dir'])

        puts "Delta commit failed: #{reason}."
        puts 'The base disk copies were removed, as virt-v2v-in-place may have changed them; ' \
             'the migration has to be started again.'
        if poweroff?
            puts "VM #{@name} is powered off and VMware snapshot #{state['snapshot_name']} is still active."
            puts 'Power the VM on and run --delta-cleanup to roll back, then --delta-prepare to start again.'
        else
            puts "Run --delta-cleanup to remove VMware snapshot #{state['snapshot_name']}, " \
                 'then --delta-prepare to start again.'
        end
        false
    end

    #
    # A retried commit of migrated disks only finishes the cleanup and returns
    # them for the import, unless the VM ran again since: then they are stale.
    #
    def resume_migrated_commit(target_dir, state)
        power_state = @client.vm_state(@id)
        if power_state.nil?
            puts "Delta commit failed: unable to read the power state of VM #{@name}; retry --delta-commit."
            return false
        end

        # ESXi starts a new vmware.log at every power-on.
        if power_state != STATES[:POWEROFF] || (state['vm_log'] && vm_log_signature != state['vm_log'])
            puts "Delta commit failed: VM #{@name} ran after its migration, so the migrated disks are outdated."
            puts 'Run --delta-cleanup, then power the VM on and run --delta-prepare again.'
            return false
        end
        unless state['vm_log']
            puts "Warning: unable to tell whether VM #{@name} ran after its migration; importing the disks " \
                 'migrated then.'
        end

        move_migrated_disks(state)
        finish_migrated_commit(target_dir, state)
    end

    # Size and modification time of vmware.log, which every power-on replaces.
    def vm_log_signature
        @client.file_signature(storage_path('vmware.log'))
    end

    #
    # Removes the snapshot and the clones of a migrated VM, and returns its
    # disks for the import. The state stays until the import is done.
    #
    def finish_migrated_commit(target_dir, state)
        results_dir = state['results_dir']
        missing = state['disks'].each_index.map {|index| "#{results_dir}/#{self.class.disk_file_name(index)}" }
        missing.reject! {|path| File.file?(path) }
        unless missing.empty?
            puts "Delta commit failed: the migrated disks are missing: #{missing.join(', ')}."
            puts 'Run --delta-cleanup, then power the VM on and run --delta-prepare again.'
            return false
        end
        return results_dir if state['commit_stage'] == 'cleaned'

        state_file = live2kvm_state_file(target_dir)
        snapshot_removed = cleanup_snapshot(state)
        vmx_verified = snapshot_removed && verify_vmx_base_disks(state, state_file)
        clones_removed = release_clone_dir(target_dir, state)
        if vmx_verified && clones_removed
            state['commit_stage'] = 'cleaned'
            remove_local_copies(state['transfer_dir'])
        else
            state['commit_stage'] = 'migrated'
            puts "Warning: the cleanup after the migration did not complete; prepared state retained at #{state_file}. " \
                 'Retry with --delta-cleanup.'
        end
        # The cleanup does not touch vmware.log, but a retry compares with the latest.
        state['vm_log'] = vm_log_signature || state['vm_log']
        write_live2kvm_state(target_dir, state)

        results_dir
    end

    #
    # Moves the migrated disks to the results directory, named after their
    # position in the VMX, also when an older release named the base copies
    # after their parent disk. Disks already moved stay.
    #
    def move_migrated_disks(state)
        FileUtils.mkdir_p(state['results_dir'])
        state['disks'].each_with_index do |disk, index|
            source = "#{state['convert_dir']}/#{File.basename(disk['converted_raw_base_path'].to_s)}"
            target = "#{state['results_dir']}/#{self.class.disk_file_name(index)}"
            File.rename(source, target) if File.file?(source)
        end
    end

    # Everything a delta migration keeps locally, except its state.
    def remove_local_copies(transfer_dir)
        return unless Dir.exist?(transfer_dir.to_s)

        Dir.children(transfer_dir).each do |file|
            FileUtils.rm_rf(File.join(transfer_dir, file)) unless file == STATE_FILE
        end
    end

    def read_remote_descriptor(path)
        Tempfile.create('oneswap-descriptor') do |file|
            file.close
            unless @client.pull_files(path, file.path)
                raise ESXi::Client::Error, "Failed to read #{path} from the ESXi host"
            end

            ESXi::Client.parse_vmware_file(file.path)
        end
    end

    def write_live2kvm_metrics(target_dir, metrics)
        current = if File.exist?(live2kvm_metrics_file(target_dir))
                      YAML.load_file(live2kvm_metrics_file(target_dir)) || {}
                  else
                      {}
                  end
        File.write(live2kvm_metrics_file(target_dir), current.merge(metrics).to_yaml)
    rescue StandardError => e
        @logger.warn "Failed to write delta migration metrics: #{e.message}"
    end

    def format_elapsed(seconds)
        "#{seconds.round(2)}s"
    end

    def local_tree_size(path)
        # The path has the VM name: it must not be read as a pattern.
        Dir.glob('**/*', File::FNM_DOTMATCH, :base => path).sum do |file|
            file = File.join(path, file)
            File.file?(file) ? File.size(file) : 0
        end
    end

    def mib_per_second(bytes, seconds)
        return nil if bytes.to_i <= 0 || seconds.to_f <= 0

        (bytes.to_f / (1024 * 1024)) / seconds.to_f
    end

    def cleanup_snapshot(state)
        snapshot_name = state['snapshot_name']
        if snapshot_name.to_s.empty?
            puts 'Snapshot name is missing from prepared state; automatic snapshot cleanup is unavailable.'
            return false
        end

        puts "Removing VMware snapshot #{snapshot_name}..."
        snapshot_id = @client.snapshot_id_by_name(@id, snapshot_name)
        if snapshot_id.nil?
            puts "Warning: VMware snapshot #{snapshot_name} was not found; continuing cleanup."
            return true
        end

        if @client.remove_snapshot_vm(@id, snapshot_id)
            puts "Removed VMware snapshot #{snapshot_name}."
            return true
        else
            puts "Warning: failed to remove VMware snapshot #{snapshot_name}; continuing cleanup."
            return false
        end
    rescue ESXi::Client::Error => e
        puts "Warning: unable to check VMware snapshot #{snapshot_name}: #{e.message}"
        false
    end

    def cleanup_leftover_oneswap_snapshots(state_file)
        begin
            snapshots = @client.snapshots(@id).select {|snapshot| oneswap_snapshot?(snapshot) }
        rescue ESXi::Client::Error => e
            puts "Warning: unable to list the snapshots of VM #{@name}: #{e.message}"
            return false
        end
        if snapshots.empty?
            puts "Warning: no snapshots with a OneSwap marker were found for VM #{@name}; not removing any snapshots without prepared state."
            return true
        end

        all_removed = true
        snapshots.each do |snapshot|
            snapshot_info = "#{snapshot[:name]} (id #{snapshot[:id]}, description: #{snapshot[:description]})"
            puts "Removing leftover OneSwap snapshot #{snapshot_info}..."
            if @client.remove_snapshot_vm(@id, snapshot[:id])
                puts "Removed leftover OneSwap snapshot #{snapshot_info}."
            else
                all_removed = false
                puts "Warning: failed to remove leftover OneSwap snapshot for VM #{@name}: #{snapshot_info}."
            end
        end

        vmx_verified = verify_vmx_base_disks({}, state_file)
        if all_removed && vmx_verified
            puts 'Leftover OneSwap snapshot cleanup completed.'
            return true
        end

        puts "Warning: leftover OneSwap snapshot cleanup for VM #{@name} did not fully complete."
        false
    end

    def oneswap_snapshot?(snapshot)
        snapshot[:description].to_s == ESXi::Client.default_snapshot_options[:description] ||
            snapshot[:name].to_s.start_with?('OneSwap ')
    end

    #
    # Once the OneSwap snapshot is removed, the VMX must point to the disks
    # it was taken from. Without them (cleanup without state), any snapshot
    # descriptor is suspect, unless the VM has snapshots of its own.
    #
    def verify_vmx_base_disks(state, state_file)
        oneswap_disks = state['disks'].to_a.map {|disk| disk['active_snapshot_descriptor'] }.compact
        oneswap_disks.map! {|disk| storage_path(disk) }
        # Without them (cleanup without a complete state), any delta disk is
        # suspect, unless the VM has snapshots of its own.
        any_delta = oneswap_disks.empty? && @client.snapshots(@id).all? {|snapshot| oneswap_snapshot?(snapshot) }
        if oneswap_disks.empty? && !any_delta
            puts "Note: VM #{@name} has other snapshots, so its VMX disk backing cannot be verified without prepared state."
            return true
        end
        still_active = []

        12.times do |attempt|
            refresh_vmx
            still_active = self.class.active_vmdks(@vmx).map {|disk| storage_path(disk) }.select do |disk|
                chain = disk_chain(disk)
                # A disk that still continues from the OneSwap delta was not
                # consolidated; later snapshots of the user continue past it.
                any_delta ? chain.length > 1 : !(chain & oneswap_disks).empty?
            end
            if still_active.empty?
                puts 'Verified VMX disk backing no longer points to the OneSwap snapshot descriptor.'
                return true
            end

            sleep 5 if attempt < 11
        end

        puts "Warning: VMX still points to snapshot descriptor(s): #{still_active.join(', ')}."
        puts 'Warning: the VM disks may need a consolidation in vCenter.'
        puts "Warning: prepared state was #{state_file}."
        false
    rescue StandardError => e
        puts "Warning: unable to verify VMX disk backing after snapshot cleanup: #{e.message}."
        puts "Warning: prepared state was #{state_file}."
        false
    end

    def snapshot_descriptor?(disk)
        disk.to_s =~ /-\d{6}\.vmdk$/
    end

    #
    # A disk and the parents its descriptors name. VMware names snapshot
    # disks <disk>-NNNNNN.vmdk, so other disks are not read.
    #
    def disk_chain(disk)
        chain = [disk]
        while snapshot_descriptor?(chain.last) && chain.length < 64
            parent = vmdk_info(chain.last)['parentFileNameHint'].to_s
            break if parent.empty?

            chain << remote_expand_path(parent, File.dirname(chain.last))
        end
        chain
    end

    # @return [String, nil] remote clone directory of a prepared state
    def state_clone_dir(state)
        return nil if state['transport'] == 'vddk'

        # Older states without the key use the VM's default clone directory.
        # An explicit nil means the clones were already removed.
        state.fetch('clone_dir', @clone_dir)
    end

    #
    # The datastore clones are only needed until the base copies are local;
    # remove them and record it in the prepared state.
    #
    # @return [Boolean] false when the clones are still on the datastore
    #
    def release_clone_dir(target_dir, state)
        clone_dir = state_clone_dir(state)
        return true if clone_dir.nil?

        if !clone_dir.start_with?("#{ESXi::Client::DATASTORES_PATH}/")
            puts 'Warning: ESXi clone directory is missing or unsafe; skipping remote clone cleanup.'
            return true
        end

        puts "Removing ESXi clone directory #{clone_dir}..."
        unless @client.remove_files(clone_dir)
            puts "Warning: failed to remove ESXi clone directory #{clone_dir}."
            return false
        end

        puts "Removed ESXi clone directory #{clone_dir}."
        state['clone_dir'] = nil
        write_live2kvm_state(target_dir, state)
        true
    end

    def cleanup_local_state(target_dir, state)
        transfer_dir = state['transfer_dir']
        expected_dir = live2kvm_transfer_dir(target_dir)
        if File.expand_path(transfer_dir.to_s) != File.expand_path(expected_dir)
            puts "Warning: prepared state path #{transfer_dir} does not match expected #{expected_dir}; skipping local cleanup."
            return
        end

        puts "Removing local prepared state #{transfer_dir}..."
        if Dir.exist?(transfer_dir)
            FileUtils.remove_dir(transfer_dir)
            puts "Removed local prepared state #{transfer_dir}."
        else
            puts "Warning: local prepared state #{transfer_dir} is already gone."
        end
    end

    def live_storage_transfer_precheck
        if !running?
            message = "Cannot perform live storage transfer on a non #{STATES[:RUNNING]} VM"
            puts "Delta prepare aborted: VM #{@name} is not powered on."
            @logger.error message

            return false
        end

        # The commit needs sesparse and virt-v2v-in-place too: check them now.
        missing = missing_commands(['sesparse', 'qemu-img', 'virt-v2v-in-place'])
        unless missing.empty?
            message = "command(s) #{missing.join(', ')} needed for live storage transfer"
            puts "Delta prepare aborted: #{message}."
            @logger.error message
            return false
        end

        true
    end

    # Local commands of a delta migration that are not in PATH.
    def missing_commands(commands)
        commands.reject {|cmd| ESXi::Client.command_exists?(cmd) }
    end

    def live_storage_transfer_cleanup(transfer_dir)
        if @delta_transport != 'vddk' && !@clone_dir.to_s.empty?
            @logger.info "Cleaning disk clone directory on ESXi host at #{@clone_dir}"
            @client.remove_files(@clone_dir)
        end

        @logger.info "Cleaning local transfer directory at #{transfer_dir}"
        FileUtils.remove_dir(transfer_dir) if Dir.exist?(transfer_dir)
    end

    #
    # FileSystem path of a disk name
    #
    # @param [String] fileName disk name, relative to the VMX folder or absolute
    #
    # @return [String] Path prefixed with datastore path
    #
    def storage_path(fileName)
        remote_expand_path(fileName, @vm_storage)
    end

    # File.expand_path for ESXi paths, where "~" is not a home directory.
    def remote_expand_path(path, dir)
        File.expand_path(path.start_with?('/') ? path : "./#{path}", dir)
    end

    # Base copies and migrated disks are named after their position in the VMX.
    def self.disk_file_name(index)
        "disk#{index}.raw"
    end

    #
    # Migrated disks in their VMX order (disk10 after disk2), whatever the
    # directory order; any other file follows by name.
    #
    def self.disk_files(dir)
        Dir.children(dir).sort_by do |file|
            index = file[/\Adisk(\d+)\.raw\z/, 1]
            index ? [0, index.to_i, file] : [1, 0, file]
        end
    end

    def self.active_vmdks(vmx_data)
        vmdks = []

        # Match example
        # scsi0:0.fileName = "alma9-clone_17-000003.vmdk"
        # scsi0:1.fileName = "alma9-clone-000003.vmdk"
        slots = vmx_data.keys.filter_map do |key|
            slot = key.to_s.match(/\A(scsi|ide|sata|nvme)(\d+):(\d+)\.fileName\z/)
            [key, slot] if slot
        end
        # In controller and unit order, as vCenter lists the disks: hostd
        # appends a re-attached disk at the end of the VMX.
        slots.sort_by! {|_key, slot| [CONTROLLERS.index(slot[1]), slot[2].to_i, slot[3].to_i] }
        slots.each do |key, _slot|
            device_type_key = key.sub(/\.fileName$/, '.deviceType')
            next if Array(vmx_data[device_type_key]).any? do |type|
                type.is_a?(String) && /\A(?:atapi-cdrom|cdrom-image|cdrom-raw)\z/i.match?(type)
            end

            Array(vmx_data[key]).each do |filename|
                vmdks << filename if filename.is_a?(String) && filename.end_with?('.vmdk')
            end
        end

        vmdks.uniq
    end

    def self.validate_vm_info(vm_info)
        raise ArgumentError, "#{vm_info.class} is not a #{Hash}" unless vm_info.is_a?(Hash)

        VM_INFO_KEYS.each do |k|
            raise ArgumentError, "Missing VM information #{k} on #{vm_info}" unless vm_info.key?(k)
        end

        true
    end

end
