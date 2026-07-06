require 'open3'
require 'logger'
require 'fileutils'
require 'tempfile'
require 'shellwords'

module ESXi; end

# SSH ESXI Client to perform CLI operations on a given ESXi host
class ESXi::Client

    CTRL_CMD = 'vim-cmd'
    USER = 'root'
    DATASTORES_PATH = '/vmfs/volumes'
    CLI_UTILS = ['sesparse', 'qemu-img', 'virt-v2v-in-place']

    attr_reader :logger

    def initialize(host, logger = self.class.stdout_logger, options = {})
        @host = host
        @logger = logger
        @user = options[:user] || USER
        @password = options[:password]
        @non_interactive = options[:non_interactive] || false
        @ssh_options = ''
        @ssh_env = {}

        authenticate!
        dependency_precheck

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

    #
    # Create a VM snapshot
    #
    # @param [Integer] vm_id Virtual Machine ID
    # @param [String] name Snapshot Name
    # @param [Hash] options Snapshot options
    # @option options [String] :description Snapshot description
    # @option options [Bool] :memory Inlcude the VM memory in the snapshot.
    # @option options [Bool] :quiesce Quiesce the filesystem. Requires vmwaretools in the VM.
    #
    # @return [Bool] Whether the snapshot succeds or not
    #
    def snapshot_vm(vm_id, name = self.class.default_snapshot_name,
                    options = self.class.default_snapshot_options)
        @logger.info "Creating snapshot '#{name}' for VM #{vm_id}"
        @logger.debug options

        description = options[:description]
        memory = options[:memory] ? 1 : 0
        quiesce = options[:quiesce] ? 1 : 0

        actions = "snapshot.create #{vm_id} \"#{name}\" \"#{description}\" #{memory} #{quiesce}"
        _, _, s = vm_cmd(actions)
        s
    end

    def snapshot_id_by_name(vm_id, name)
        actions = "snapshot.get #{vm_id}"
        stdout, _stderr, status = vm_cmd(actions)
        return nil unless status

        current_id = nil
        current_name = nil
        stdout.each_line do |line|
            current_id = Regexp.last_match(1) if line =~ /Snapshot Id\s*:\s*(\d+)/
            current_name = Regexp.last_match(1).strip if line =~ /Snapshot Name\s*:\s*(.*)$/
            return current_id if current_id && current_name == name
        end

        nil
    end

    def snapshots(vm_id)
        actions = "snapshot.get #{vm_id}"
        stdout, _stderr, status = vm_cmd(actions)
        return [] unless status

        snapshots = []
        current = nil
        stdout.each_line do |line|
            if line =~ /Snapshot Id\s*:\s*(\d+)/
                current = { :id => Regexp.last_match(1) }
                snapshots << current
            elsif current && line =~ /Snapshot Name\s*:\s*(.*)$/
                current[:name] = Regexp.last_match(1).strip
            elsif current && line =~ /Snapshot Desciption\s*:\s*(.*)$/
                current[:description] = Regexp.last_match(1).strip
            elsif current && line =~ /Snapshot Description\s*:\s*(.*)$/
                current[:description] = Regexp.last_match(1).strip
            end
        end

        snapshots
    end

    def remove_snapshot_vm(vm_id, snapshot_id)
        actions = "snapshot.remove #{vm_id} #{snapshot_id} false"
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

    def vm_summary(vm_id)
        actions = "get.summary #{vm_id}"
        o, _, s = vm_cmd(actions)

        if !s
            @logger.error "Failed to get VM #{vm_id} summary"
            return
        end

        @logger.debug "VM #{vm_id} summary\n#{o}"

        o
    end

    def clone_virtual_disk(source, target)
        log_host_operation("Cloning disk #{source} to #{target}")

        cmd = "vmkfstools --clonevirtualdisk #{source} #{target} -d thin"
        message = "Failed to clone virtual disk #{source} to #{target}"

        t0 = Time.now
        return false unless simple_ssh_execution(cmd, message)

        @logger.info("Clone time #{Time.now - t0}")

        true
    end

    def vm_cmd(actions)
        cmd = "#{CTRL_CMD} vmsvc/#{actions}"
        ssh(cmd)
    end

    def host_cmd(actions)
        cmd = "#{CTRL_CMD} hostsvc/#{actions}"
        ssh(cmd)
    end

    def pull_files(files, target)
        source = "#{@host}:#{files}"
        @logger.info "Copying files from #{source} to #{target}"
        scp("#{@user}@#{source}", target)
    end

    def remove_files(target)
        log_host_operation("Removing files #{target}")

        if !target.start_with?(DATASTORES_PATH)
            @logger.error 'Cannot remove files outside of datastore directories'
            return false
        end

        cmd = "rm -r #{Shellwords.escape(target)}"
        message = "Failed to remove files at #{target} on ESXi host #{@host}"
        simple_ssh_execution(cmd, message)
    end

    def create_dir(dir)
        log_host_operation("Creating directory #{dir}")

        cmd = "mkdir -p #{dir}"
        message = "Failed to create directory #{dir} on ESXi host #{@host}"
        simple_ssh_execution(cmd, message)
    end

    def create_zero_file(path, size_mib)
        if !path.start_with?(DATASTORES_PATH) || path.include?("'")
            @logger.error "Refusing to create file outside datastore path: #{path}"
            return false
        end

        size_mib = size_mib.to_i
        return false if size_mib <= 0

        cmd = "dd if=/dev/zero of=#{Shellwords.escape(path)} bs=1M count=#{size_mib}"
        message = "Failed to create benchmark file #{path} on ESXi host #{@host}"
        simple_ssh_execution(cmd, message)
    end

    def convert_vmdk(source_vmdk, target, format)
        @logger.info "Converting #{source_vmdk} to format #{format} at #{target}"

        cmd = "qemu-img convert -p -f vmdk #{source_vmdk} -O #{format} #{target}"

        t0 = Time.now
        message = "Failed to convert #{source_vmdk} to #{format} #{target}"

        s = live_execution(cmd, message)

        if s
            @logger.info("Conversion time #{Time.now - t0}")
        else
            FileUtils.rm
        end

        s
    end

    def apply_vmdk_snapshot_to_raw(snapshot_vmdk, converted_parent_raw)
        cmd = "sesparse #{snapshot_vmdk} #{converted_parent_raw}"
        message = "Failed to apply snapshot #{snapshot_vmdk} to #{converted_parent_raw}"
        live_execution(cmd, message)
    end

    def os_morph(root_image, options = '')
        @logger.info "Converting disk #{root_image} to KVM"

        cmd = "virt-v2v-in-place -i disk #{root_image} #{options}"
        message = "Failed to convert Guest OS at #{root_image}"

        live_execution(cmd, message)
    end

    def file_size_bytes(path)
        if !path.start_with?(DATASTORES_PATH) || path.include?("'")
            @logger.error "Refusing to read file size outside datastore path: #{path}"
            return nil
        end

        stdout, _stderr, status = ssh("ls -ln \"#{path}\"")
        return nil unless status

        size = stdout.lines.last.to_s.split[4]
        return nil unless size && size =~ /^\d+$/

        size.to_i
    end

    private

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

    def self.default_snapshot_name
        Time.now.strftime('VM Snapshot %-m/%-d/%Y, %-I:%M:%S %p')
    end

    def self.default_snapshot_options
        {
            :description => 'OneSwap ESXi client snapshot',
            :memory => false,
            :quiesce => false
        }
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

    def self.command_exists?(cmd)
        ENV['PATH'].split(File::PATH_SEPARATOR).any? do |dir|
            File.executable?(File.join(dir, cmd))
        end
    end

    def self.stdout_logger
        logger = Logger.new($stdout)
        logger.level = Logger.const_get('INFO')
        logger
    end

    def authenticate!
        check_cmd = "#{CTRL_CMD} -v"
        @ssh_options = '-o BatchMode=yes -o NumberOfPasswordPrompts=0'
        @ssh_env = {}
        _, _, s = ssh(check_cmd)
        return true if s

        if @password && !@password.to_s.empty?
            configure_password_auth
            _, _, s = ssh(check_cmd)
            return true if s
        end

        if !@non_interactive
            @ssh_options = '-o NumberOfPasswordPrompts=3'
            @ssh_env = {}
            _, _, s = ssh(check_cmd)
            return true if s
        end

        raise "Unable to authenticate to ESXi host #{@user}@#{@host}. Configure passwordless SSH or set esxi_user/esxi_pass. Authentication failed after 3 attempts."
    end

    def dependency_precheck
        CLI_UTILS.each do |cmd|
            if !ESXi::Client.command_exists?(cmd)
                message = "Command #{cmd} not found. Limited functionality available"
                @logger.warn message
            end
        end
    end

    def simple_ssh_execution(cmd, error_message = nil)
        _, _, s = ssh(cmd)

        @logger.error error_message if !s && error_message

        s
    end

    def ssh(cmd)
        ssh_cmd = "ssh #{@ssh_options} #{@user}@#{@host} '#{cmd}'"
        execute(ssh_cmd, @ssh_env)
    end

    def scp(source, target)
        cmd = "scp #{@ssh_options} -r #{source} #{target}"
        message = "Failed to perform remote copy from #{source} to #{target}"
        live_execution(cmd, message, @ssh_env)
    end

    def simple_execution(cmd, error_message = nil)
        _, _, s = execute(cmd)

        @logger.error error_message if !s && error_message

        s
    end

    def live_execution(cmd, error_message = nil, env = {})
        status = nil
        Open3.popen3(env, cmd) do |stdin, stdout, stderr, wait_thr|
            stdin.close

            threads = []
            threads << Thread.new { stdout.each_line {|line| puts line } }
            threads << Thread.new { stderr.each_line {|line| STDERR.puts line } }

            threads.each(&:join)
            status = wait_thr.value.success?
        end

        @logger.error(error_message) if !status && error_message

        status
    end

    def execute(cmd, env = {})
        @logger.debug "Running command #{cmd}"

        t0 = Time.now
        stdout, stderr, status = Open3.capture3(env, cmd)
        @logger.debug "Execution time #{Time.now - t0}"

        if !status.success?
            @logger.error stderr
            @logger.info stdout
        end

        [stdout, stderr, status.success?]
    end

    def log_host_operation(operation_message)
        @logger.info("#{operation_message} on ESXi host #{@host}")
    end

    def configure_password_auth
        @askpass_file = Tempfile.new('oneswap-esxi-askpass')
        @askpass_file.write("#!/bin/sh\nprintf '%s\\n' #{Shellwords.escape(@password)}\n")
        @askpass_file.close
        File.chmod(0o700, @askpass_file.path)

        @ssh_options = '-o BatchMode=no -o NumberOfPasswordPrompts=1'
        @ssh_env = {
            'SSH_ASKPASS' => @askpass_file.path,
            'SSH_ASKPASS_REQUIRE' => 'force',
            'DISPLAY' => ENV['DISPLAY'].to_s.empty? ? 'none:0' : ENV['DISPLAY']
        }
    end

end
