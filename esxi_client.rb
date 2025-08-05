require 'open3'
require 'logger'

module ESXi; end

# SSH ESXI Client to perform CLI operations on a given ESXi host
class ESXi::Client

    CTRL_CMD = 'vim-cmd'
    USER = 'root'

    attr_reader :logger

    def initialize(host, logger)
        @host = host
        @logger = logger

        @vm_list = []
    end

    def list_vms
        actions = 'getallvms'
        o, _e, s = vm_cmd(actions)

        @logger.debug o

        return [] unless s

        @vm_list = self.class.vmsvc_getallvms_to_array(o)
    end

    def get_vm_by_name(name)
        list_vms if @vm_list.empty?

        @vm_list.each do |vm|
            next unless vm[:name] == name

            @logger.debug vm

            return ESXi::VirtualMachine.new(self, vm)
        end
    end

    def snapshot_vm(vm_id, snapshot_name = self.class.default_snapshot_name)
        @logger.info "Creating snapshot #{snapshot_name} for VM #{vm_id}"

        actions = "snapshot.create #{vm_id} \"#{snapshot_name}\""
        _, _, s = vm_cmd(actions)
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
        _, _, s = vm_cmd(actions)
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

    def vm_state(vm_id)
        actions = "power.getstate #{vm_id}"
        o, _, s = vm_cmd(actions)

        if !s
            @logger.error 'Could not read VM state'
            return
        end

        state = o.lines.last.chomp

        @logger.info "VM #{vm_id} state is #{state}"

        state
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

    def vm_cmd(actions)
        cmd = "#{CTRL_CMD} vmsvc/#{actions}"
        ssh(cmd)
    end

    def host_cmd(actions)
        cmd = "#{CTRL_CMD} hostsvc/#{actions}"
        ssh(cmd)
    end

    def pull_files(source, target)
        scp("#{USER}@#{@host}:#{source}", target)
    end

    def self.vmsvc_getallvms_to_array(getallvms_output)
        lines = getallvms_output.lines.map(&:strip)

        return [] if lines.empty?

        lines.shift # remove header
        # Skip the first line if it contains column names
        lines.reject! do |line|
            line =~ /^Vmid\s+/
        end
        vms = []
        lines.each do |line|
            # Split line into at most 6 parts (to handle annotations with spaces)
            parts = line.split(/\s{2,}/, 6)

            vm = {
                :vmid => parts[0].to_i,
                :name => parts[1],
                :file => parts[2],
                :guest_os => parts[3],
                :version => parts[4],
                :annotation => parts[5] || nil
            }

            vms << vm
        end

        vms
    end

    #
    # Maps vmware files to a hash. Works with VMX and VMDK file descriptors
    #
    # @param [String] path file path on the filesystem
    #
    # @return [Hash] mapped vmx/vmdk
    #
    def self.parse_vmware_file(path)
        config = {}

        File.foreach(path, :chomp => true) do |line|
            next if line.strip.empty? || line.strip.start_with?('#', '//')

            if line =~ /^(.+?)\s*=\s*"(.*)"$/
                key   = Regexp.last_match(1).strip
                value = Regexp.last_match(2)

                if config.key?(key)
                    config[key] = Array(config[key]) << value
                else
                    config[key] = value
                end
            end
        end

        config
    end

    #
    # vSphere Client UI suggested snapshot name
    #
    # @return [String]
    #
    def self.default_snapshot_name
        Time.now.strftime('VM Snapshot %-m/%-d/%Y, %-I:%M:%S %p')
    end

    private

    def ssh(cmd)
        ssh_cmd = "ssh #{USER}@#{@host} '#{cmd}'"
        execute(ssh_cmd)
    end

    def scp(source, target)
        cmd = "scp -r #{source} #{target}"
        execute(cmd)
    end

    def execute(cmd)
        @logger.debug "Running command #{cmd}"

        t0 = Time.now
        stdout, stderr, status = Open3.capture3(cmd)
        @logger.debug "Execution time #{Time.now - t0}"

        if !status.success?
            @logger.error stderr
            @logger.info stdout
        end

        [stdout, stderr, status.success?]
    end

end
