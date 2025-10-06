require 'tempfile'
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
        return false unless live_storage_transfer_precheck

        transfer_dir = "#{target_dir}/esxi_client-#{@name}"
        live_storage_transfer_cleanup(transfer_dir)

        results_dir = "#{target_dir}/esxi2kvm-#{@name}"
        FileUtils.rm_r(results_dir) if Dir.exist?(results_dir)

        @logger.info "Creating premigrate snapshot for VM #{@name}"
        if !(if vmwaretools?
                 create_snapshot
             else
                 name = ESXi::Client.default_snapshot_name
                 options = ESXi::Client.default_snapshot_options.merge({ :quiesce => true })
                 create_snapshot(name, options)
             end)

            @logger.error 'Aborting live storage transfer due to failed snapshot creation'
            return false
        end

        FileUtils.mkdir_p(transfer_dir) unless Dir.exist?(transfer_dir)
        if !@client.create_dir(@clone_dir)
            message = "Aborting live storage transfer. Cannot create remote clone directory #{@clone_dir}"
            @logger.error message
            return false
        end

        refresh_vmx # snapshots created new active disks
        active_disks.each do |disk|
            vmdk_data = vmdk_info(disk)
            parent_disk = vmdk_data['parentFileNameHint']

            clone_source = storage_path(parent_disk)
            clone_target = "#{@clone_dir}/#{parent_disk}"

            next if @client.clone_virtual_disk(clone_source, clone_target)

            message = "failed disk #{parent_disk} clone"

            live_storage_transfer_cleanup(transfer_dir, message)
            return false
        end

        @logger.info "Transferring VM #{@name} storage to #{transfer_dir}"
        if !@client.pull_files("#{@clone_dir}/*", transfer_dir)
            message = "failed disk #{parent_disk} transfer"
            live_storage_transfer_cleanup(transfer_dir, message)
            return false
        end

        cloned_vmdk_list = Dir.children(transfer_dir)

        convert_dir = "#{transfer_dir}/convert"
        Dir.mkdir(convert_dir) unless Dir.exist?(convert_dir)

        cloned_vmdk_list.each do |file|
            next if file.end_with?('-flat.vmdk')

            source = "#{transfer_dir}/#{file}"
            target = "#{convert_dir}/#{file.chomp('.vmdk')}.raw"
            format = 'raw'

            next if @client.convert_vmdk(source, target, format)

            message = "failed disk #{source} conversion"
            live_storage_transfer_cleanup(transfer_dir, message)
            return false
        end

        t0 = Time.now
        @logger.warn "Shutting down VM #{@name}. Downtime begins"
        if !shutdown
            message = "failed to shut down VM #{@name}"
            live_storage_transfer_cleanup(transfer_dir, message)
            return false
        end

        # transfer and apply active snapshot vmdk
        active_disks.each do |disk|
            # alma9-clone_17-000022.vmdk
            # alma9-clone --> vm name
            # _17 --> disk identifier
            # --> 000022 snapshots
            disk_name = disk.chomp('.vmdk')

            vmdk_data = vmdk_info(disk)
            parent_disk = vmdk_data['parentFileNameHint']
            parent_disk_name = parent_disk.chomp('.vmdk')

            # copy vmdk metadata + bits
            ['', '-sesparse'].each do |suffix|
                source = storage_path("#{disk_name}#{suffix}.vmdk")

                next if @client.pull_files(source, transfer_dir)

                message = "failed vmdk file #{disk} transfer"
                live_storage_transfer_cleanup(transfer_dir, message)
                return false
            end

            # apply active snapshot to flat converted disk
            snapshot = "#{transfer_dir}/#{disk_name}-sesparse.vmdk"
            parent = "#{convert_dir}/#{parent_disk_name}.raw"

            next if @client.apply_vmdk_snapshot_to_raw(snapshot, parent)

            message = "failed applying snapshot #{snapshot} to raw parent disk #{parent}"
            live_storage_transfer_cleanup(transfer_dir, message)
            return false
        end

        converted_disks = Dir.children(convert_dir)
        converted_disks.each do |disk|
            root_disk_path = "#{convert_dir}/#{disk}"

            break if @client.os_morph(root_disk_path, VIRT_V2V_OPTIONS_EXTRA)

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

        t_downtime = Time.now - t0
        t_downtime_formatted = Time.at(t_downtime).utc.strftime("%M:%S")

        @logger.info "Migrated VM #{@name} to KVM with downtime #{t_downtime_formatted}. VM disks at #{results_dir}"
        @logger.info "VM disks at #{results_dir}"

        live_storage_transfer_cleanup(transfer_dir)

        results_dir
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
