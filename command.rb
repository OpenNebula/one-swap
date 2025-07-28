require 'open3'

#
# Assumes passwordless SSH for remote command execution
#
module Command

    def self.scp(user, host, source, target)
        cmd = "scp #{user}@#{host}:#{source} #{target}"
        self.class.execute(cmd)
    end

    #
    # Execute a command remotely via SSH
    #
    # @param [String] cmd Command to be executed
    #
    # @return [Array] stdout, stderr, exitstatus
    #
    def self.ssh(user, host, cmd)
        ssh_cmd = "ssh #{user}@#{host} #{cmd}"
        self.class.execute(ssh_cmd)
    end

    def self.execute(cmd)
        stdout, stderr, status = Open3.capture3(cmd)

        STDERR.puts "#{stderr}/n#{stdout}" unless status.zero?

        [stdout, stderr, status]
    end

end
