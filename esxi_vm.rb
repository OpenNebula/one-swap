require 'tempfile'
require 'time'
require 'yaml'
require_relative 'esxi_client'

module ESXi; end

#
# Virtual Machine entity controlled by an ESXi SSH client
#
class ESXi::VirtualMachine

    # output from vim-cmd vmsvc/getallvms
    VM_INFO_KEYS = [:vmid, :name, :file, :guest_os, :version, :annotation]

    STATES ={
        :RUNNING  => 'Powered on',
        :POWEROFF => 'Powered off'
    }
    VIRT_V2V_OPTIONS_EXTRA = '-v --machine-readable'

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
        @datastore = file.split(' ').first.slice(1..-2)
        @vm_storage = "#{ESXi::Client::DATASTORES_PATH}/#{@datastore}/#{@name}"
        @clone_dir = "#{@vm_storage}/vmkfstools_output"
        @vmx_file = "#{@vm_storage}/#{@name}.vmx"
        @vmx = {}
    end

    def shutdown
        @client.shutdown_vm(@id)
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

    def live2kvm_prepare(target_dir)
        puts "Starting delta prepare for VM #{@name}."
        puts 'Running delta prepare prechecks...'
        return false unless live_storage_transfer_precheck
        puts 'Delta prepare prechecks completed.'

        transfer_dir = live2kvm_transfer_dir(target_dir)
        puts "Cleaning previous delta work directories at #{transfer_dir}..."
        live_storage_transfer_cleanup(transfer_dir)

        results_dir = live2kvm_results_dir(target_dir)
        FileUtils.rm_r(results_dir) if Dir.exist?(results_dir)
        puts 'Previous delta work directories cleaned.'

        puts "Creating premigrate snapshot for VM #{@name}..."
        @logger.info "Creating premigrate snapshot for VM #{@name}"
        t0 = Time.now
        snapshot_name = ESXi::Client.default_snapshot_name
        snapshot_options = ESXi::Client.default_snapshot_options
        if !vmwaretools?
            snapshot_options = snapshot_options.merge({ :quiesce => true })
        end

        if !create_snapshot(snapshot_name, snapshot_options)

            @logger.error 'Aborting live storage transfer due to failed snapshot creation'
            return false
        end
        puts "Snapshot created in #{format_elapsed(Time.now - t0)}."

        FileUtils.mkdir_p(transfer_dir) unless Dir.exist?(transfer_dir)
        if !@client.create_dir(@clone_dir)
            message = "Aborting live storage transfer. Cannot create remote clone directory #{@clone_dir}"
            @logger.error message
            return false
        end

        puts 'Reading VMX and detecting active disks...'
        t0 = Time.now
        refresh_vmx # snapshots created new active disks
        detected_disks = active_disks
        puts "Detected #{detected_disks.length} active disk(s) in #{format_elapsed(Time.now - t0)}."
        disks = []
        detected_disks.each do |disk|
            vmdk_data = vmdk_info(disk)
            parent_disk = vmdk_data['parentFileNameHint']
            disk_name = disk.chomp('.vmdk')
            parent_disk_name = parent_disk.chomp('.vmdk')

            clone_source = storage_path(parent_disk)
            clone_target = "#{@clone_dir}/#{parent_disk}"

            puts "Cloning base disk on ESXi: #{parent_disk}..."
            t0 = Time.now
            if @client.clone_virtual_disk(clone_source, clone_target)
                puts "Cloned base disk #{parent_disk} in #{format_elapsed(Time.now - t0)}."
                disks << {
                    'active_snapshot_descriptor' => disk,
                    'active_snapshot_extent' => "#{disk_name}-sesparse.vmdk",
                    'parent_base_descriptor' => parent_disk,
                    'converted_raw_base_path' => "#{transfer_dir}/convert/#{parent_disk_name}.raw"
                }
                next
            end

            message = "failed disk #{parent_disk} clone"

            live_storage_transfer_cleanup(transfer_dir, message)
            return false
        end

        @logger.info "Transferring VM #{@name} storage to #{transfer_dir}"
        puts "Transferring base disk files to local work dir #{transfer_dir}..."
        t0 = Time.now
        if !@client.pull_files("#{@clone_dir}/*", transfer_dir)
            message = 'failed disk transfer'
            live_storage_transfer_cleanup(transfer_dir, message)
            return false
        end
        base_transfer_seconds = Time.now - t0
        base_transfer_bytes = local_tree_size(transfer_dir)
        base_transfer_mib_s = mib_per_second(base_transfer_bytes, base_transfer_seconds)
        puts "Transferred base disk files in #{format_elapsed(base_transfer_seconds)}."

        cloned_vmdk_list = Dir.children(transfer_dir)

        convert_dir = "#{transfer_dir}/convert"
        Dir.mkdir(convert_dir) unless Dir.exist?(convert_dir)

        base_convert_seconds = 0.0
        base_convert_bytes = 0
        cloned_vmdk_list.each do |file|
            next if file.end_with?('-flat.vmdk')

            source = "#{transfer_dir}/#{file}"
            target = "#{convert_dir}/#{file.chomp('.vmdk')}.raw"
            format = 'raw'

            puts "Converting base disk to raw: #{file}..."
            t0 = Time.now
            if @client.convert_vmdk(source, target, format)
                elapsed = Time.now - t0
                base_convert_seconds += elapsed
                base_convert_bytes += File.size(target) if File.exist?(target)
                puts "Converted #{file} to raw in #{format_elapsed(elapsed)}."
                next
            end

            message = "failed disk #{source} conversion"
            live_storage_transfer_cleanup(transfer_dir, message)
            return false
        end
        base_convert_mib_s = mib_per_second(base_convert_bytes, base_convert_seconds)

        puts 'Writing prepared delta state...'
        state = {
            'vm_name' => @name,
            'vm_storage_path' => @vm_storage,
            'datastore_path' => "#{ESXi::Client::DATASTORES_PATH}/#{@datastore}",
            'snapshot_name' => snapshot_name,
            'transfer_dir' => transfer_dir,
            'convert_dir' => convert_dir,
            'results_dir' => results_dir,
            'clone_dir' => @clone_dir,
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
        }
        if !write_live2kvm_state(target_dir, state)
            message = 'failed to persist delta migration state'
            live_storage_transfer_cleanup(transfer_dir, message)
            return false
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
        @clone_dir = state['clone_dir'] || @clone_dir

        t0 = Time.now
        @logger.warn "Shutting down VM #{@name}. Downtime begins"
        if !shutdown
            message = "failed to shut down VM #{@name}"
            live_storage_transfer_cleanup(transfer_dir, message)
            return false
        end

        # transfer and apply active snapshot vmdk
        state['disks'].each do |disk_data|
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

                message = "failed vmdk file #{disk} transfer"
                live_storage_transfer_cleanup(transfer_dir, message)
                return false
            end

            # apply active snapshot to flat converted disk
            snapshot = "#{transfer_dir}/#{snapshot_extent}"
            parent = disk_data['converted_raw_base_path']

            next if @client.apply_vmdk_snapshot_to_raw(snapshot, parent)

            message = "failed applying snapshot #{snapshot} to raw parent disk #{parent}"
            live_storage_transfer_cleanup(transfer_dir, message)
            return false
        end

        converted_disks = Dir.children(convert_dir)
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

            message = "Failed to morph OS for VM #{@name}"
            live_storage_transfer_cleanup(transfer_dir, message)
            return false
        end

        FileUtils.mv(convert_dir, results_dir)
        write_live2kvm_metrics(target_dir, {
                                   'delta_os_morph_seconds' => os_morph_seconds,
                                   'delta_os_morph_disks_tried' => os_morph_disks_tried
                               })

        t_downtime = Time.now - t0
        t_downtime_formatted = Time.at(t_downtime).utc.strftime("%M:%S")

        @logger.info "Migrated VM #{@name} to KVM with downtime #{t_downtime_formatted}. VM disks at #{results_dir}"
        @logger.info "VM disks at #{results_dir}"

        state_file = live2kvm_state_file(target_dir)
        snapshot_removed = cleanup_snapshot(state)
        vmx_verified = verify_vmx_base_disks(state, state_file)
        if !snapshot_removed || !vmx_verified
            snapshot_name = state['snapshot_name']
            puts "Warning: failed to fully clean up VMware snapshot #{snapshot_name}; prepared state was #{state_file}."
        end

        live_storage_transfer_cleanup(transfer_dir)

        results_dir
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
        vm_storage_path = state['vm_storage_path']
        return nil if vm_storage_path.to_s.empty?

        total = 0
        paths = []
        disks.each do |disk_data|
            extent = disk_data['active_snapshot_extent']
            raise 'prepared state is missing active snapshot extent' if extent.to_s.empty?

            # This is a point-in-time value. While the VM keeps running after
            # prepare, snapshot delta extents can continue to grow.
            path = "#{vm_storage_path}/#{extent}"
            @logger.debug "Reading live snapshot delta size from #{path}"
            size = @client.file_size_bytes(path)
            raise "unable to read live snapshot extent size for #{path}" if size.nil?

            paths << path
            total += size
        end

        state['current_delta_size_bytes'] = total
        state['current_delta_size_refreshed_at'] = Time.now.utc.iso8601
        write_live2kvm_state(target_dir, state)

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

        cleanup_snapshot(state)
        cleanup_clone_dir(state)
        cleanup_local_state(target_dir, state)

        puts 'Delta prepare cleanup completed.'
        true
    end

    def disable_autostart
        @client.disable_vm_autostart(@id)
    end

    def refresh_vmx
        @logger.info "Reading vmx file #{@vmx_file}"

        file = Tempfile.create
        @client.pull_files(@vmx_file, file.path)
        vmx = ESXi::Client.parse_vmware_file(file.path)

        @logger.debug vmx.to_yaml
        @vmx = vmx
        vmx
    end

    def vmdk_info(fileName)
        file = Tempfile.create
        @client.pull_files(storage_path(fileName), file.path)
        ESXi::Client.parse_vmware_file(file.path)
    end

    # Output based on vim-cmd vmsvc/power.getstate $vmid
    def state
        @client.vm_state(@id)
    end

    def running?
        state == STATES[:RUNNING]
    end

    def poweroff?
        state == STATES[:POWEROFF]
    end

    def vmwaretools?
        load_summary

        # @summary string output is tricky to convert into a Hash
        @summary.include?('toolsStatus = "toolsOk"') &&
        @summary.include?('toolsRunningStatus = "guestToolsRunning"')
    end

    def load_summary
        @summary = @client.vm_summary(@id)

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
        "#{live2kvm_transfer_dir(target_dir)}/oneswap-delta-state.yaml"
    end

    def live2kvm_metrics_file(target_dir)
        "#{target_dir}/oneswap-metrics.yaml"
    end

    def write_live2kvm_state(target_dir, state)
        File.write(live2kvm_state_file(target_dir), state.to_yaml)
        true
    rescue StandardError => e
        @logger.error "Failed to write delta migration state: #{e.message}"
        false
    end

    def read_live2kvm_state(target_dir)
        state_file = live2kvm_state_file(target_dir)
        if !File.exist?(state_file)
            @logger.error "Delta migration state file not found at #{state_file}"
            return nil
        end

        YAML.load_file(state_file)
    rescue StandardError => e
        @logger.error "Failed to read delta migration state: #{e.message}"
        nil
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
        Dir.glob("#{path}/**/*", File::FNM_DOTMATCH).sum do |file|
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
    end

    def cleanup_leftover_oneswap_snapshots(state_file)
        snapshots = @client.snapshots(@id).select {|snapshot| oneswap_snapshot?(snapshot) }
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

    def verify_vmx_base_disks(state, state_file)
        snapshot_disks = state['disks'].to_a.map {|disk| disk['active_snapshot_descriptor'] }.compact
        still_active = []

        12.times do |attempt|
            refresh_vmx
            active_disks = self.class.active_vmdks(@vmx)
            still_active = active_disks & snapshot_disks
            still_active += active_disks.select {|disk| snapshot_descriptor?(disk) }
            still_active.uniq!
            if still_active.empty?
                puts 'Verified VMX disk backing no longer points to the OneSwap snapshot descriptor.'
                return true
            end

            sleep 5 if attempt < 11
        end

        puts "Warning: VMX still points to snapshot descriptor(s): #{still_active.join(', ')}."
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

    def cleanup_clone_dir(state)
        clone_dir = state['clone_dir'] || @clone_dir
        if clone_dir.to_s.empty? || !clone_dir.start_with?(ESXi::Client::DATASTORES_PATH)
            puts 'Warning: ESXi clone directory is missing or unsafe; skipping remote clone cleanup.'
            return
        end

        puts "Removing ESXi clone directory #{clone_dir}..."
        if @client.remove_files(clone_dir)
            puts "Removed ESXi clone directory #{clone_dir}."
        else
            puts "Warning: failed to remove ESXi clone directory #{clone_dir}; continuing cleanup."
        end
    end

    def cleanup_local_state(target_dir, state)
        transfer_dir = state['transfer_dir']
        expected_dir = live2kvm_transfer_dir(target_dir)
        if transfer_dir != expected_dir
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
            @logger.error message

            return false
        end

        ['sesparse', 'qemu-img'].each do |cmd|
            next if ESXi::Client.command_exists?(cmd)

            message = "command #{cmd} is needed for live storage transfer"
            @logger.error message
            return false
        end

        true
    end

    def live_storage_transfer_cleanup(transfer_dir, reason = nil)
        @logger.error "Aborting live storage transfer due to #{reason}" if reason

        @logger.info "Cleaning disk clone directory on ESXi host at #{@clone_dir}"
        @client.remove_files(@clone_dir)

        @logger.info "Cleaning local transfer directory at #{transfer_dir}"
        FileUtils.remove_dir(transfer_dir) if Dir.exist?(transfer_dir)
    end

    #
    # FileSystem path of a disk name
    #
    # @param [String] fileName disk name
    #
    # @return [String] Path prefixed with datastore path
    #
    def storage_path(fileName)
        "#{@vm_storage}/#{fileName}"
    end

    def self.active_vmdks(vmx_data)
        vmdks = []

        # Match example
        # scsi0:0.fileName = "alma9-clone_17-000003.vmdk"
        # scsi0:1.fileName = "alma9-clone-000003.vmdk"
        vmx_data.each do |key, value|
            if key =~ /^(scsi|ide|sata)\d+:\d+\.fileName$/
                if value.is_a?(Array)
                    value.each {|v| vmdks << v }
                else
                    vmdks << value
                end
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
