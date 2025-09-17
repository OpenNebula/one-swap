require 'tempfile'
require 'yaml'

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

    def live_storage_transfer(target_dir)
        transfer_dir = "#{target_dir}/esxi_client-#{@name}"

        return false unless live_storage_transfer_precheck

        live_storage_transfer_cleanup(transfer_dir)

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
            clone_target = "#{@clone_dir}/clone_#{parent_disk}"

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
        convert_dir = "#{transfer_dir}/raw"
        Dir.mkdir(convert_dir)

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

        @logger.warn "Shutting down VM #{@name}. Downtime begins"
        if !shutdown
            message = "failed to shut down VM #{@name}"
            live_storage_transfer_cleanup(transfer_dir, message)
            return false
        end

        # transfer and apply active snapshot vmdk
        active_disks.each do |disk|
            target = transfer_dir

            # copy vmdk metadata + bits
            ['', '-sesparse'].each do |suffix|
                source = storage_path("#{disk}#{suffix}.vmdk")

                next if @client.pull_files(source, target)

                message = "failed disk #{disk} transfer"
                live_storage_transfer_cleanup(transfer_dir, message)
                return false
            end

            # apply active snapshot to flat converted disk
            disk_name = disk.chomp('.vmdk')

            raw_disk = "#{convert_dir}/#{disk_name}.raw"
            snapshot = "#{transfer_dir}/#{disk_name}-sesparse.vmdk"

            next if @client.apply_vmdk_snapshot_to_raw(snapshot, raw_disk)

            message = "failed applying snapshot #{snapshot} to raw disk #{raw_disk}"
            live_storage_transfer_cleanup(transfer_dir, message)
            return false
        end

        live_storage_transfer_cleanup(transfer_dir)
        @logger.info "Live migrated disks #{Dir.children(convert_dir)}"
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

    def live_storage_transfer_precheck
        if !running?
            message = "Cannot perform live storage transfer on a non #{STATES[:RUNNING]} VM"
            @logger.error message

            return false
        end

        ['sesparse, qemu-img'].each do |cmd|
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
        @client.remove_files(@clone_dir) if Dir.exist?(@clone_dir)

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
