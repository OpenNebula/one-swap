require_relative 'command'

#
# SSH ESXI Client to perform CLI operations on a given ESXi host
#
class ESXiClient

    CTRL_CMD = 'vim-cmd'
    USER = 'root'

    def initialize(host)
        @host = host
    end

    def list_vms
        actions = 'getallvms'
        vm_cmd(actions)
    end

    def snapshot_vm(vm_id, snapshot_name = self.class.default_snapshot_name)
        actions = "snapshot.create #{vm_id} #{snapshot_name}"
        vm_cmd(actions)
    end

    def shutdown_vm(vm_id, vmware_tools = false)
        action = if vmware_tools
                     'power.shutdown'
                 else
                     'power.off'
                 end

        actions = "#{action} #{vm_id}"
        vm_cmd(actions)
    end

    def start_vm(vm_id)
        actions = "power.on #{vm_id}"
        vm_cmd(actions)
    end

    def disable_vm_autostart(vm_id)
        actions = "autostartmanager/update_autostartentry #{vm_id} 'none' '0' '0' 'none' '0' 'yes'"
        host_cmd(actions)
    end

    def clone_virtual_disk(source, target)
        args = "--clonevirtualdisk #{source} #{target} -d thin"
        o, e, s = vmkfstools(args)

        return unless s.zero?

        STDERR.puts "Failed to clone virtual disk #{source} to #{target}"
        raise "#{o}\n#{e}"
    end

    def vmkfstools(options = '')
        cmd = "vmkfstools #{options}"
        ssh(cmd)
    end

    private

    def vm_cmd(actions)
        cmd = "#{CONTROL_CMD} vmsvc/#{actions}"
        ssh(cmd)
    end

    def host_cmd
        cmd = "#{CONTROL_CMD} hostsvc/#{actions}"
        ssh(cmd)
    end

    def scp(source, target)
        Command.scp(USER, @host, source, target)
    end

    def ssh(cmd)
        Command.ssh(USER, @host, cmd)
    end

    #
    # vSphere Client UI suggested snapshot name
    #
    # @return [String]
    #
    def self.default_snapshot_name
        Time.now.strftime('VM Snapshot %-m/%-d/%Y, %-I:%M:%S %p')
    end

end
