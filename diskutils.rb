require_relative 'command'

module DiskUtils

    def self.convert(input, output, input_format, output_format)
        cmd = "qemu-img convert -p -f #{input_format} #{input} -O #{output_format} #{output}"
        Command.execute(cmd)
    end

    def self.sesparse(snapshot_vmdk, raw_vmdk)
        cmd = "sesparse #{snapshot_vmdk} #{raw_vmdk}"
        Command.execute(cmd)
    end

    # TODO: Custom OS morphing
    def self.os_morph(disk)
        cmd = "virt-v2v-in-place -i disk #{disk}"
        Command.execute(cmd)
    end

end
