require 'open3'
require 'logger'

#
# SSH ESXI Client to perform CLI operations on a given ESXi host
#
class ESXiClient

    CTRL_CMD = 'vim-cmd'
    USER = 'root'

    def initialize(host, logger)
        @host = host
        @logger = logger
    end

    # TODO: Parse ESXi output to hash
    def list_vms
        actions = 'getallvms'
        o, e, s = vm_cmd(actions)
        o
    end

    def vm_id(vm_name)
        # vms =
    end

    def snapshot_vm(vm_id, snapshot_name = self.class.default_snapshot_name)
        @logger.info "Creating snapshot #{snapshot_name} for VM #{vm_id}"

        actions = "snapshot.create #{vm_id} #{snapshot_name}"
        o, e, s = vm_cmd(actions)
        s
    end

    def shutdown_vm(vm_id, vmware_tools = false)
        @logger.info "Shutting down VM #{vm_id}"

        action = if vmware_tools
                     'power.shutdown'
                 else
                     'power.off'
                 end

        actions = "#{action} #{vm_id}"
        o, e, s = vm_cmd(actions)
        s
    end

    def start_vm(vm_id)
        @logger.info "Starting VM #{vm_id}"

        actions = "power.on #{vm_id}"
        vm_cmd(actions)
    end

    def disable_vm_autostart(vm_id)
        @logger.info "Disabling autostart for VM #{vm_id}"

        actions = "autostartmanager/update_autostartentry #{vm_id} 'none' '0' '0' 'none' '0' 'yes'"
        host_cmd(actions)
    end

    def clone_virtual_disk(source, target)
        @logger.info "Cloning disk #{source} to #{target}"

        args = "--clonevirtualdisk #{source} #{target} -d thin"
        o, e, s = vmkfstools(args)

        return unless s.zero?

        @logger.info "Failed to clone virtual disk #{source} to #{target}"
        @logger.error e
        @logger.error o

        raise "#{o}\n#{e}"
    end

    def vmkfstools(options = '')
        cmd = "vmkfstools #{options}"
        ssh(cmd)
    end

    private

    def vm_cmd(actions)
        cmd = "#{CTRL_CMD} vmsvc/#{actions}"
        ssh(cmd)
    end

    def host_cmd
        cmd = "#{CTRL_CMD} hostsvc/#{actions}"
        ssh(cmd)
    end

    #
    # vSphere Client UI suggested snapshot name
    #
    # @return [String]
    #
    def self.default_snapshot_name
        Time.now.strftime('VM Snapshot %-m/%-d/%Y, %-I:%M:%S %p')
    end

    # Command helpers

    def scp(source, target)
        cmd = "scp #{USER}@#{@host}:#{source} #{target}"
        execute(cmd)
    end

    #
    # Execute a command remotely via SSH
    #
    # @param [String] cmd Command to be executed
    #
    # @return [Array] stdout, stderr, exitstatus
    #
    def ssh(cmd)
        ssh_cmd = "ssh #{USER}@#{@host} #{cmd}"
        execute(ssh_cmd)
    end

    def execute(cmd)
        stdout, stderr, status = Open3.capture3(cmd)

        @logger.info "Running command #{cmd}"

        if !status.success?
            @logger.error stderr
            @logger.info stdout
        end

        [stdout, stderr, status.success?]
    end

end
