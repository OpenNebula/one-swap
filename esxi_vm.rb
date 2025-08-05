require 'tempfile'

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
        @datastore_path = "/vmfs/volumes/#{@datastore}/#{@name}"
        @vmx_file = "#{@datastore_path}/#{@name}.vmx"
        @vmx = {}
    end

    def shutdown
        @client.shutdown_vm(@id)
    end

    def start
        @client.start_vm(@id)
    end

    def create_snapshot(snapshot_name = nil)
        args = [@id]
        args << snapshot_name if snapshot_name

        @client.snapshot_vm(*args)
    end

    def disable_autostart
        @client.disable_vm_autostart(@id)
    end

    def load_vmx
        @logger.info "Reading vmx file #{@vmx_file}"

        file = Tempfile.create
        @client.pull_files(@vmx_file, file.path)
        vmx = ESXi::Client.parse_vmware_file(file.path)

        @logger.debug vmx.to_yaml
        @vmx = vmx
        vmx
    end

    # TODO: Optimize for a single ssh connection
    def disk_chain(fileName, chain = [])
        file = Tempfile.create
        @client.pull_files("#{@datastore_path}/#{fileName}", file.path)
        vmdk_data = ESXi::Client.parse_vmware_file(file.path)

        chain << fileName

        if (parent = vmdk_data['parentFileNameHint'])
            disk_chain(parent, chain)
        end

        chain
    end

    def disks_chains
        t0 = Time.now
        threads = []

        list_active_disks.each do |disk|
            threads << Thread.new(disk) do |d|
                disk_chain(d)
            end
        end

        chains = threads.map(&:value)
        chains.each do |chain|
            @logger.info "Disk chain\n #{chain.to_yaml}"
        end

        @logger.debug "Disks chains resolution time #{Time.now - t0}"

        chains
    end

    # Output based on vim-cmd vmsvc/power.getstate $vmid
    def state
        @client.vm_state(@id)
    end

    def running?
        state == STATES[:RUNNING]
    end

    def stopped?
        state == STATES[:POWEROFF]
    end

    def list_active_disks
        load_vmx if @vmx.empty?

        disks = self.class.active_vmdks(@vmx)
        @logger.info("VM #{@name} has the following active disks: #{disks}")
        disks
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
