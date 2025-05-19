# coding: utf-8
# -------------------------------------------------------------------------- #
# Copyright 2002-2024, OpenNebula Project, OpenNebula Systems                #
#                                                                            #
# Licensed under the Apache License, Version 2.0 (the "License"); you may    #
# not use this file except in compliance with the License. You may obtain    #
# a copy of the License at                                                   #
#                                                                            #
# http://www.apache.org/licenses/LICENSE-2.0                                 #
#                                                                            #
# Unless required by applicable law or agreed to in writing, software        #
# distributed under the License is distributed on an "AS IS" BASIS,          #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.   #
# See the License for the specific language governing permissions and        #
# limitations under the License.                                             #
#--------------------------------------------------------------------------- #

require 'one_helper'

class String
    def black;          "\e[30m#{self}\e[0m" end
    def red;            "\e[31m#{self}\e[0m" end
    def green;          "\e[32m#{self}\e[0m" end
    def brown;          "\e[33m#{self}\e[0m" end
    def blue;           "\e[34m#{self}\e[0m" end
    def magenta;        "\e[35m#{self}\e[0m" end
    def cyan;           "\e[36m#{self}\e[0m" end
    def gray;           "\e[37m#{self}\e[0m" end

    def bg_black;       "\e[40m#{self}\e[0m" end
    def bg_red;         "\e[41m#{self}\e[0m" end
    def bg_green;       "\e[42m#{self}\e[0m" end
    def bg_brown;       "\e[43m#{self}\e[0m" end
    def bg_blue;        "\e[44m#{self}\e[0m" end
    def bg_magenta;     "\e[45m#{self}\e[0m" end
    def bg_cyan;        "\e[46m#{self}\e[0m" end
    def bg_gray;        "\e[47m#{self}\e[0m" end

    def bold;           "\e[1m#{self}\e[22m" end
    def italic;         "\e[3m#{self}\e[23m" end
    def underline;      "\e[4m#{self}\e[24m" end
    def blink;          "\e[5m#{self}\e[25m" end
    def reverse_color;  "\e[7m#{self}\e[27m" end
end

# Ruby 3.x+ deprecated URI.escape, however rbvmomi still relies on it

if RUBY_VERSION.split('.')[0].to_i >= 3
    # Monkey patch the escape functionality
    module URI

        def self.escape(url)
            URI::Parser.new.escape url
        end

    end
end

##############################################################################
# Module OneVcenterHelper
##############################################################################
class OneSwapHelper < OpenNebulaHelper::OneHelper
    # true to log to /var/log/one/oneswap.*
    DEBUG = false

    @props, @options = []
    @dotskip = false # temporarily skip dots, for progress dots.

    # vCenter importer will divide rbvmomi resources
    # in this group, makes parsing easier.
    module VOBJECT
        VM         = 1
        DATACENTER = 2
        CLUSTER    = 3
    end

    #
    # onevcenter helper main constant
    # This will control everything displayed on STDOUT
    # Resources (above) uses this table
    #
    # struct:   [Array] LIST FORMAT for opennebula cli
    #           related methods: * cli_format
    #
    # columns:  [Hash(column => Integer)] Will be used in the list command,
    #           Integer represent nbytes
    #           related methods: * format_list
    #
    # cli:      [Array] with mandatory args, for example image
    #           listing needs a datastore
    #           related methods: * parse_opts
    #
    # dialogue: [Lambda] Used only for Vobject that require a previous
    #                    dialogue with the user, will be triggered
    #                    on importation process
    #           related methods: * network_dialogue
    #                            * template_dialogue
    #
    TABLE = {
        VOBJECT::VM => {
            :struct  => ['VM_LIST', 'VM'],
            :columns => { :IMID => 8, :NAME => 20, :STATE => 10, :HOST => 10, :CPU => 3, :MEM => 7, :REF => 35 },
            :cli     => [],
            :dialogue => ->(arg) {}
        },
        VOBJECT::DATACENTER => {
            :struct  => ['DATACENTER_LIST', 'DATACENTER'],
            :columns => { :DATACENTER => 30 },
            :cli     => [],
            :dialogue => ->(arg) {}
        },
        VOBJECT::CLUSTER => {
            :struct  => ['CLUSTER_LIST', 'CLUSTER'],
            :columns => { :NAME => 30, :VMCOUNT => 35 },
            :cli     => [],
            :dialgoue => ->(arg) {}
        }
    }

    if DEBUG
        LOGGER = {
            :stdout => File.open('/var/log/one/oneswap.stdout', 'a'),
            :stderr => File.open('/var/log/one/oneswap.stderr', 'a')
        }

        LOGGER[:stdout].sync = true
        LOGGER[:stderr].sync = true
    end

    ########################
    # In list command you can use this method to print a header
    #
    # @param vcenter_host [String] this text will be displayed
    #
    def show_header(vcenter_host)
        CLIHelper.scr_bold
        CLIHelper.scr_underline
        puts "# vCenter: #{vcenter_host}".ljust(50)
        CLIHelper.scr_restore
        puts
    end

    # Using for parse a String into a VOBJECT
    # We will use VOBJECT instances for handle any operatiion
    #
    # @param type [String] String representing the vCenter resource
    #
    def object_update(type)
        if type.nil?
            type = 'vms'
        else
            type = type.downcase
        end

        case type
        when 'networks'
            @vobject = VOBJECT::NETWORK
        when 'datacenters'
            @vobject = VOBJECT::DATACENTER
        when 'clusters'
            @vobject = VOBJECT::CLUSTER
        when 'vms'
            @vobject = VOBJECT::VM
        else
            raise 'Invalid object type, must be any of: '\
                  '[ networks, datacenters, clusters, vms ]'
        end
    end

    # Handles connection to vCenter.
    #
    # @param options [Hash] options for the connection
    #
    def connection_options(object_name, options)
        if  options[:host].nil? && ( options[:vcenter].nil? && options[:vuser].nil? )
            raise 'vCenter connection parameters are mandatory'\
                  " #{object_name}:\n"\
                  "\t --vcenter vCenter hostname\n"\
                  "\t --vuser username to login in vcenter\n"\
                  "got: #{options}"
        end

        password = options[:vpass] || OpenNebulaHelper::OneHelper.get_password
        {
            :user     => options[:vuser],
            :password => password,
            :host     => options[:vcenter],
            :port     => options[:port],
            :insecure => true
        }
    end

    def cli_format(hash)
        {
            TABLE[@vobject][:struct].first =>
                {
                    TABLE[@vobject][:struct].last =>
                        hash.values
                }
        }
    end

    # handles :cli section of TABLE
    # used for executing the dialogue in some VOBJECTS
    #
    # @param object_info [Hash] This is the object
    #                           with all the info related to the object
    #                           that will be imported
    #
    def cli_dialogue(object_info)
        TABLE[@vobject][:dialogue].call(object_info)
    end

    # This method iterates over the possible options for certain resources
    # and will raise an error in case of missing mandatory param
    #
    # @param opts [Hash] options object passed to the onecenter tool
    #
    def parse_opts(opts)
        object_update(opts[:object])

        res = {}
        TABLE[@vobject][:cli].each do |arg|
            raise "#{arg} it's mandadory for this op" if opts[arg].nil?

            res[arg] = method(arg).call(opts[arg])
        end

        res[:config] = parse_file(opts[:configuration]) if opts[:configuration]

        res
    end

    # This method will parse a yaml
    # Only used for a feature that adds the posibility
    # of import resources with custom params (bulk)
    #
    # @param path [String] Path of the file
    #
    def parse_file(path)
        begin
            _config = YAML.safe_load(File.read(path))
        rescue StandardError => _e
            str_error = "Unable to read '#{path}'. Invalid YAML syntax:\n"

            raise str_error
        end
    end

    # Use the attributes provided by TABLE
    # with the purpose of build a complete CLI list
    # OpenNebula way
    #
    def format_list
        config = TABLE[@vobject][:columns]
        CLIHelper::ShowTable.new do
            column :DATACENTER, :left, :expand,
                   'DATACENTER', :size => config[:DATACENTER] || 15 do |d|
                d[:datacenter]
            end

            column :IMID, 'OBJECT ID', :size=>config[:IMID] || 4 do |d|
                d[:imid]
            end

            column :REF, 'REF', :left, :adjust, :size=>config[:REF] || 15 do |d|
                d[:ref] || d[:cluster_ref]
            end

            column :NAME, 'NAME', :left, :expand,
                   :size=>config[:NAME] || 20 do |d|
                d[:name] || d[:simple_name]
            end

            column :CLUSTERS, 'CLUSTERS', :left, :expand,
                   :size=>config[:CLUSTERS] || 10 do |d|
                d = d[:clusters] if d[:clusters]
                d[:one_ids] || d[:cluster].to_s
            end

            column :PATH, 'PATH', :left, :expand,
                   :size=>config[:PATH] || 10 do |d|
                d[:path]
            end

            column :VMCOUNT, '# VMS', :left, :expand,
                   :size=>config[:PATH] || 7 do |d|
                d[:vm_count]
            end

            column :STATE, 'STATE', :left, :expand,
                   :size=>config[:STATE] || 10 do |d|
                d[:state]
            end

            column :HOST, 'HOST', :left, :expand,
                   :size=>config[:HOST] || 15 do |d|
                d[:host]
            end

            column :CPU, 'CPU', :left, :expand,
                   :size=>config[:CPU] || 5 do |d|
                d[:cpu]
            end

            column :MEM, 'MEM', :left, :expand,
                   :size=>config[:MEM] || 7 do |d|
                d[:mem]
            end

            default(*config.keys)
        end
    end

    def check_one_connectivity
        user = OpenNebula::User.new_with_id(OpenNebula::User::SELF, @client)
        rc = user.info
        if rc.class == OpenNebula::Error
            raise 'Failed to get User info, indicating authentication failed'
        end
    end

    def cleanup_passwords
        puts "Deleting password files."
        File.delete("#{@options[:work_dir]}/vpassfile")
        File.delete("#{@options[:work_dir]}/esxpassfile")
    end

    def cleanup_disks
        if @options[:delete]
            puts "Deleting vdisks in #{"#{@options[:work_dir]}/conversions"}"
            FileUtils.rm_rf("#{@options[:work_dir]}/conversions")
            if Dir.exist?("#{@options[:work_dir]}/transfers")
                FileUtils.rm_rf("#{@options[:work_dir]}/transfers")
            end
        else
            puts "Delete not enabled, leaving disks in #{"#{@options[:work_dir]}/conversions"}"
        end
    end

    def cleanup_dirs
        if @options[:delete]
            puts "Deleting everything in and including #{"#{@options[:work_dir]}"}"
            FileUtils.rm_rf("#{@options[:work_dir]}")
        else
            puts "Delete not enabled, leaving #{@options[:work_dir]} alone."
        end
    end

    def cleanup_all
        cleanup_passwords
        cleanup_disks
        cleanup_dirs
    end

    def mem_to_mb(value, unit)
        units = {
          'b' => 1.0 / (1024 * 1024),      # bytes to MB
          'bytes' => 1.0 / (1024 * 1024),  # bytes to MB
          'kb' => 1.0 / 1024,              # KB to MB
          'k' => 1.0 / 1024,               # kB (kibibytes) to MB
          'kib' => 1.0 / 1024,             # KiB to MB
          'mb' => 1.0,                     # MB to MB
          'm' => 1.0,                      # MiB to MB
          'mib' => 1.0,                    # MiB to MB
          'gb' => 1024.0,                  # GB to MB
          'g' => 1024.0,                   # GiB to MB
          'gib' => 1024.0,                 # GiB to MB
          'tb' => 1024.0 * 1024,           # TB to MB
          't' => 1024.0 * 1024,            # TiB to MB
          'tib' => 1024.0 * 1024           # TiB to MB
        }

        unit = unit.strip.downcase

        # Check if unit is within the hash keys
        if units.key?(unit)
          value_mb = value.to_f * units[unit]
          return value_mb.to_i
        else
          raise ArgumentError, "unit not valid: '#{unit}'. Valid units: 'b', 'bytes', 'KB', 'k', 'KiB', 'MB', 'M', 'MiB', 'GB', 'G', 'GiB', 'TB', 'T', 'TiB'."
        end
    end

    # This method creates a VM full clone in vCenter
    #
    # @param vi_client [RbVmomi::VIM] The vCenter client
    # @param properties [Array] The properties to retrieve from the VM
    # @param vm [RbVmomi::VIM::VirtualMachine] The VM to clone
    # @param clone_name [String] The name for the cloned VM
    #
    def clone_vm(vi_client, properties, vm, clone_name = nil)
        attr = vm.to_hash
        vm = vm.obj

        target_name = clone_name || "#{attr['name']}-clone"

        puts "\nCloning #{attr['name']} into #{target_name}\n"

        relocate_spec = RbVmomi::VIM.VirtualMachineRelocateSpec

        clone_spec = RbVmomi::VIM.VirtualMachineCloneSpec(
          location: relocate_spec,
          powerOn: false,
          template: false
        )

        clone_task = vm.CloneVM_Task(
          folder: vm.parent,
          name: target_name,
          spec: clone_spec
        )

        clone_task.wait_for_completion

        vm_pool = get_objects(vi_client, 'VirtualMachine', properties)
        cloned_vm = vm_pool.find { |r| r['name'] == "#{target_name}" }
        if cloned_vm.nil?
            raise "Unable to find Cloned VM by name '#{target_name}'"
        end
        puts "VM #{attr['name']} cloned successfully."
        cloned_vm
    end


    # This method deletes a VM in vCenter
    #
    # @param vm [RbVmomi::VIM::VirtualMachine] The VM to delete
    #
    def delete_vm(vm)
        vm = vm.obj
        vm_name = vm.name
        puts "Initiating deletion of virtual machine '#{vm.name}'..."
        destroy_task = vm.Destroy_Task
        destroy_task.wait_for_completion
        puts "Virtual machine '#{vm_name}' deleted successfully."
        return true
    end

    def tune_windows_tmpl(template)
        vm_template = template
        # Add USB tablet input device
        input_hash = { 'BUS' => 'usb', 'TYPE' => 'tablet' }
        vm_template.add_element('//VMTEMPLATE', {"INPUT" => input_hash})

        # Configure video settings
        video_hash = { 'RESOLUTION' => '1440x900', 'TYPE' => 'virtio', 'VRAM' => '16384' }
        vm_template.add_element('//VMTEMPLATE', {"VIDEO" => video_hash})

        # Configure features for Windows VM (Hyper-V and local time)
        features_hash = { 'HYPERV' => 'YES', 'LOCALTIME' => 'YES' }
        if vm_template.element_xml('FEATURES').nil? || vm_template.element_xml('FEATURES').empty?
            puts 'Create features element and add hyperv'
            vm_template.add_element('//VMTEMPLATE', {"FEATURES" => features_hash})
        else
            puts 'Add hyperv to features element'
            vm_template.add_element('//VMTEMPLATE/FEATURES', features_hash)
        end

        return vm_template
    end

    def create_vm_template_from_ova
        # Open XML domain file generated from conversion
        xml_file = Dir.glob("#{@options[:work_dir]}/conversions/*.xml")
        if xml_file.empty?
            puts "No XML domain file found"
            exit 0
        end

        domain_xml = File.read(xml_file.first)
        xml_template = Nokogiri::XML(domain_xml)

        vm_template_config = {
            "NAME" => xml_template.xpath("//name").text,
            "CPU"  => xml_template.xpath("//vcpu").text,
            "vCPU" => xml_template.xpath("//vcpu").text,
            "MEMORY" => mem_to_mb(xml_template.xpath("//memory").text, xml_template.xpath("//memory/@unit").text),
            "HYPERVISOR" => "kvm",
            "CONTEXT" => {
                "NETWORK" => "YES",
                "SSH_PUBLIC_KEY" => "$USER[SSH_PUBLIC_KEY]"
            }
        }

        local_cpu = xml_template.xpath("//cpu")
        if !local_cpu.empty?
            local_cpu_model = local_cpu.xpath("@mode").text
            if local_cpu_model.eql?("custom")
                vm_template_config["CPU_MODEL"] = {"MODEL" => "#{local_cpu.xpath("/model").text}"}
            else
                vm_template_config["CPU_MODEL"] = {"MODEL" => "host-passthrough"}
            end
        end

        # CPU Features from <features>
        local_features = xml_template.xpath("//features//*")
        if !local_features.empty?
            vm_template_config["FEATURES"] = {}
            local_features.each do |feature|
                vm_template_config["FEATURES"]["#{feature.name.upcase}"] = 'YES'
            end
        end

        # If the currentMemory attribute is present, it means memory hotplug is enabled
        # memory indicates maximum allocation of memory at boot time,
        # while currentMemory is the actual allocation of memory
        if !xml_template.xpath("//currentMemory").empty?
            vm_template_config["MEMORY_RESIZE_MODE"] = "HOTPLUG"
            vm_template_config["MEMORY_MAX"] = mem_to_mb(xml_template.xpath("//memory").text, xml_template.xpath("//memory/@unit").text)
            if !xml_template.xpath("//maxMemory").empty?
                vm_template_config["MEMORY_MAX"] = mem_to_mb(xml_template.xpath("//maxMemory").text, xml_template.xpath("//maxMemory/@unit").text)
            end

            if vm_template_config.include?("HOT_RESIZE")
                vm_template_config["HOT_RESIZE"]["MEMORY_HOT_ADD_ENABLED"] = "YES"
            else
                vm_template_config["HOT_RESIZE"] = { "MEMORY_HOT_ADD_ENABLED" => "YES" }
            end
        end

        if xml_template.xpath("//vcpus//vcpu/@hotpluggable")=='yes'
            # TODO Search max vCPU parameter in libvirt domain
            # vm_template_config["VCPU_MAX"] = "#{@props['config'][:hardware][:numCPU]}"
            # if @options[:vcpu_max]
            #     vm_template_config["VCPU_MAX"] = "#{@options[:vcpu_max]}"
            # end

            if vm_template_config.include?("HOT_RESIZE")
                vm_template_config["HOT_RESIZE"]["CPU_HOT_ADD_ENABLED"] = "YES"
            else
                vm_template_config["HOT_RESIZE"] = { "CPU_HOT_ADD_ENABLED" => "YES" }
            end
        end

        if !xml_template.xpath("//devices//graphics").empty?
            possible_options = ['spice', 'vnc', 'sdl']

            local_graphics = xml_template.xpath("//devices//graphics")
            if possible_options.include?(local_graphics.xpath("@type").text.downcase)
                vm_template_config["GRAPHICS"] = {}
                vm_template_config["GRAPHICS"]["TYPE"] = local_graphics.xpath("@type").text.upcase

                if !local_graphics.xpath("@port").empty?
                    vm_template_config["GRAPHICS"]["PORT"] = local_graphics.xpath("@port").text
                end

                if !local_graphics.xpath("@passwd").empty?
                    vm_template_config["GRAPHICS"]["PASSWD"] = local_graphics.xpath("@passwd").text
                end

                if !local_graphics.xpath("@keymap").empty?
                    vm_template_config["GRAPHICS"]["KEYMAP"] = local_graphics.xpath("@passwd").text
                end

                if !local_graphics.xpath("//listen/@address").empty?
                    vm_template_config["GRAPHICS"]["LISTEN"] = local_graphics.xpath("//listen/@address").text
                else
                    vm_template_config["GRAPHICS"]["LISTEN"] = '0.0.0.0'
                end

                # TODO command not an atribute of graphics in libvirt domain
                #if @options[:graphics_command]
                #    vm_template_config["GRAPHICS"]["COMMAND"] = @options[:graphics_command]
                #end
            else
                puts "Invalid graphics type. Please use one of the following: #{possible_options.join(', ')}"
            end
        else
            vm_template_config["GRAPHICS"] = {}
            vm_template_config["GRAPHICS"]["TYPE"] = 'VNC'
            vm_template_config["GRAPHICS"]["LISTEN"] = '0.0.0.0'
        end

        vmt = OpenNebula::Template.new(OpenNebula::Template.build_xml, @client)
        vmt.add_element('//VMTEMPLATE', vm_template_config)

        # Get network interfaces
        local_interfaces = xml_template.xpath("//devices//interface")
        if !local_interfaces.empty?
            network_ids = @options[:network].to_s.split(',').map(&:strip)

            puts "Adding #{local_interfaces} NICs using Network ID(s) #{network_ids.join(', ')}"

            nic_number = 0
            local_interfaces.each do |interface|
                network_id = network_ids[nic_number] || network_ids.last  # Reuse last ID if not enough

                net_hash = { 'NETWORK_ID' => "#{network_id}" }

                # Check for MAC Address
                if !local_interfaces.xpath("//mac/@address").empty?
                    puts "Adding MAC address to NIC##{nic_number}"
                    net_hash['MAC'] = local_interfaces.xpath("//mac/@address").text
                end

                vmt.add_element('//VMTEMPLATE', {"NIC" => net_hash})

                nic_number += 1
            end
        end

        # Add UEFI configuration
        # Create @props variable here to call template_firmware function

        # Check for EFI configuration
        if xml_template.xpath("//os/@firmware").text == 'efi'
            if xml_template.xpath("//os//loader/@secure").text == 'yes'
                @props = {
                    'config' => {
                        :firmware => 'efi',
                        :bootOptions => {
                            :efiSecureBootEnabled => 'yes'
                        }
                    }
                }
            else
                @props = {
                    'config' => {
                        :firmware => 'efi',
                        :bootOptions => {
                        }
                    }
                }
            end
        else
            @props = {
                'config' => {
                    :firmware => 'bios',
                    :bootOptions => {
                    }
                }
            }
        end
        vmt.add_element('//VMTEMPLATE', template_firmware)

        vmt
    end

    def create_base_template
        vm_template_config = {
            "NAME" => "#{@options[:name]}",
            "CPU"  => "#{@props['config'][:hardware][:numCPU]}",
            "vCPU" => "#{@props['config'][:hardware][:numCPU]}",
            "MEMORY" => "#{@props['config'][:hardware][:memoryMB]}",
            "HYPERVISOR" => "kvm"
        }

        if @options[:cpu_model]
            vm_template_config["CPU_MODEL"] = {"MODEL" => "#{@options[:cpu_model]}"}
        end

        if !@options[:disable_contextualization]
            vm_template_config["CONTEXT"] = {
                "NETWORK" => "YES",
                "SSH_PUBLIC_KEY" => "$USER[SSH_PUBLIC_KEY]"
            }
        end

        if @options[:cpu]
            vm_template_config["CPU"] = "#{@options[:cpu]}"
        end

        if @options[:vcpu]
            vm_template_config["vCPU"] = "#{@options[:vcpu]}"
        end

        if @props['config'][:memoryHotAddEnabled]
            vm_template_config["MEMORY_RESIZE_MODE"] = "HOTPLUG"
            vm_template_config["MEMORY_MAX"] = "#{@props['config'][:hardware][:memoryMB]}"
            if @options[:memory_max]
                vm_template_config["MEMORY_MAX"] = "#{@options[:memory_max]}"
            end

            if vm_template_config.include?("HOT_RESIZE")
                vm_template_config["HOT_RESIZE"]["MEMORY_HOT_ADD_ENABLED"] = "YES"
            else
                vm_template_config["HOT_RESIZE"] = { "MEMORY_HOT_ADD_ENABLED" => "YES" }
            end
        end

        if @props['config'][:cpuHotAddEnabled]
            vm_template_config["VCPU_MAX"] = "#{@props['config'][:hardware][:numCPU]}"
            if @options[:vcpu_max]
                vm_template_config["VCPU_MAX"] = "#{@options[:vcpu_max]}"
            end

            if vm_template_config.include?("HOT_RESIZE")
                vm_template_config["HOT_RESIZE"]["CPU_HOT_ADD_ENABLED"] = "YES"
            else
                vm_template_config["HOT_RESIZE"] = { "CPU_HOT_ADD_ENABLED" => "YES" }
            end
        end

        if @options[:graphics_type]
            possible_options = ['spice', 'vnc', 'sdl']

            if possible_options.include?(@options[:graphics_type].downcase)
                vm_template_config["GRAPHICS"] = {}
                vm_template_config["GRAPHICS"]["TYPE"] = @options[:graphics_type].upcase

                if @options[:graphics_port]
                    vm_template_config["GRAPHICS"]["PORT"] = @options[:graphics_port]
                end

                if @options[:graphics_password]
                    vm_template_config["GRAPHICS"]["PASSWD"] = @options[:graphics_password]
                end

                if @options[:graphics_keymap]
                    vm_template_config["GRAPHICS"]["KEYMAP"] = @options[:graphics_keymap]
                end

                if @options[:graphics_listen]
                    vm_template_config["GRAPHICS"]["LISTEN"] = @options[:graphics_listen]
                else
                    vm_template_config["GRAPHICS"]["LISTEN"] = '0.0.0.0'
                end

                if @options[:graphics_command]
                    vm_template_config["GRAPHICS"]["COMMAND"] = @options[:graphics_command]
                end
            else
                puts "Invalid graphics type. Please use one of the following: #{possible_options.join(', ')}"
            end
        else
            vm_template_config["GRAPHICS"] = {}
            vm_template_config["GRAPHICS"]["TYPE"] = 'VNC'
            vm_template_config["GRAPHICS"]["LISTEN"] = '0.0.0.0'
        end

        vmt = OpenNebula::Template.new(OpenNebula::Template.build_xml, @client)
        vmt.add_element('//VMTEMPLATE', vm_template_config)

        vmt
    end

    def template_firmware
        fw = { "OS" => { "FIRMWARE" => "BIOS" }}
        if @props['config'][:firmware] == 'efi'
            if @props['config'][:bootOptions][:efiSecureBootEnabled]
                fw['OS']['FIRMWARE'] = @options[:uefi_sec_path]
                fw['OS']['FIRMWARE_SECURE'] = 'YES'
            else
                fw['OS']['FIRMWARE'] = @options[:uefi_path]
            end
            fw['OS']['MACHINE'] = 'q35'
        end

        fw
    end

    #SCHED_DS_REQUIREMENTS = "ID=\"110\""
    #SCHED_REQUIREMENTS = "ID=\"0\" | CLUSTER_ID=\"0\""
    def template_scheduling(vmt)
        sched = {}
        if @options[:one_cluster] or @options[:one_host]
            sched['SCHED_REQUIREMENTS'] = ''
            if @options[:one_host]
                sched['SCHED_REQUIREMENTS'] << "ID=\"#{@options[:one_host]}\""
            end
            if @options[:one_host] and @options[:one_cluster]
                sched['SCHED_REQUIREMENTS'] << ' | '
            end
            if @options[:one_cluster]
                sched['SCHED_REQUIREMENTS'] << "CLUSTER_ID=\"#{@options[:one_cluster]}\""
            end
            vmt.add_element('//VMTEMPLATE', sched)
            sched = {}
        end
        if @options[:one_datastore] or @options[:one_datastore_cluster]
            sched['SCHED_DS_REQUIREMENTS'] = ''
            if @options[:one_datastore]
                sched['SCHED_DS_REQUIREMENTS'] << "ID=\"#{@options[:one_datastore]}\""
            end
            if @options[:one_datastore] and @options[:one_datastore_cluster]
                sched['SCHED_DS_REQUIREMENTS'] << ' | '
            end
            if @options[:one_datastore_cluster]
                sched['SCHED_DS_REQUIREMENTS'] << "CLUSTER_ID=\"#{@options[:one_datastore_cluster]}\""
            end
            vmt.add_element('//VMTEMPLATE', sched)
        end
        vmt
    end

    # Translate vCenter Definition to OpenNebula Template
    def create_vm_template
        vmt = create_base_template
        vmt.add_element('//VMTEMPLATE', template_firmware)

        # add any notes as the description
        if @props['config'][:annotation] && !@props['config'][:annotation].empty?
            notes = @props['config'][:annotation]
                    .gsub('\\', '\\\\')
                    .gsub('"', '\\"')
            vmt.add_element('//VMTEMPLATE', { "DESCRIPTION" => "#{notes}" })
        end

        vmt = template_scheduling(vmt)

        # detect icon
        logo = nil
        case @props['guest.guestFullName']
        when /CentOS/i;     logo = 'images/logos/centos.png'
        when /Debian/i;     logo = 'images/logos/debian.png'
        when /Red Hat/i;    logo = 'images/logos/redhat.png'
        when /Ubuntu/i;     logo = 'images/logos/ubuntu.png'
        when /Windows XP/i; logo = 'images/logos/windowsxp.png'
        when /Windows/i;    logo = 'images/logos/windows8.png'
        when /Linux/i;      logo = 'images/logos/linux.png'
        end
        vmt.add_element('//VMTEMPLATE', {'LOGO' => logo}) if logo

        vmt
    end

    def ip_version(ip_address)
        ip = IPAddr.new(ip_address) rescue nil
        return nil if !ip
        return 'IP4' if ip.ipv4?
        return 'IP6' if ip.ipv6?
    end

    # Yoinked from StackOverflow question 10262235
    def show_wait_spinner(fps=10)
        chars = %w[| / - \\]
        delay = 1.0/fps
        iter = 0
        spinner = Thread.new do
            while iter do   # Keep spinning until told otherwise
                print chars[(iter+=1) % chars.length]
                sleep delay
                print "\b"
            end
        end
        yield.tap{          # After yielding to the block, save the return value
            iter = false    # Tell the thread to exit, cleaning up after itself…
            spinner.join    # …and wait for it to do so.
        }                   # Use the block's return value as the method's
    end

    def next_suffix(suffix)
        return 'a' if suffix.empty?
        chars = suffix.chars
        if chars.last == 'z'
            chars.pop
            return next_suffix(chars.join) + 'a'
        end

        chars[-1] = chars.last.succ
        chars.join
    end

    # Runs a command and reports its execution status and output.
    #
    # @param cmd [String] The command to be executed.
    # @param out [Boolean] (optional) Whether to return the output or not.
    # @return [Array] Returns an array containing the stdout and status if out is true.
    def run_cmd_report(cmd, out=false)
        t0 = Time.now
        stdout, stderr, status = nil
        puts "Running: #{cmd}"
        show_wait_spinner {
            stdout, stderr, status = Open3.capture3(cmd)
        }
        t1 = (Time.now - t0).round(2)
        puts !status.success? ? "Failed (#{t1}s)".red : "Success (#{t1}s)".green
        if !status.success? and DEBUG
            LOGGER[:stderr].puts("     STDERR:")
            LOGGER[:stderr].puts(stderr)
            LOGGER[:stderr].puts("------------")
        end
        return stdout, status if out
    end

    def detect_distro(disk)
        print 'Inspecting disk...'
        t0 = Time.now
        distro_info = {}
        inspector_cmd = 'virt-inspector -a '\
            "#{disk} "\
            '--no-applications --no-icon'
        disk_xml = nil
        show_wait_spinner {
            stdout, _status = Open3.capture2(inspector_cmd)
            disk_xml = REXML::Document.new(stdout).root.elements
        }
        xprefix = '//operatingsystems/operatingsystem'
        if !disk_xml[xprefix]
            return nil
        end
        distro_info['distro']  = disk_xml["#{xprefix}/distro"].text
        distro_info['name']    = disk_xml["#{xprefix}/name"].text
        distro_info['os']      = disk_xml["#{xprefix}/osinfo"].text
        if distro_info['distro'] != 'windows'
            distro_info['pkg'] = disk_xml["#{xprefix}/package_format"].text
        end
        distro_info['mounts']  = {}
        mounts = disk_xml["#{xprefix}/mountpoints"].select { |d| d.is_a?(REXML::Element) }
        mounts.each do |mp|
            distro_info['mounts'][mp.text] = mp['dev'] # mountpath is the key, dev is value
        end
        distro_info['product_name'] = disk_xml["#{xprefix}/product_name"].text
        puts "Done (#{(Time.now - t0).round(2)}s)".green
        distro_info
    end

    def detect_context_package(distro)
        case distro
        when 'rhel8'
            c_files = Dir.glob("#{@options[:context]}/one-context*el8*rpm")
        when 'rhel9'
            c_files = Dir.glob("#{@options[:context]}/one-context*el9*rpm")
        when 'fedora'
            c_files = Dir.glob("#{@options[:context]}/one-context*fc*rpm")
        when 'debian'
            c_files = Dir.glob("#{@options[:context]}/one-context*deb")
        when 'alpine'
            c_files = Dir.glob("#{@options[:context]}/one-context*apk")
        when 'alt'
            c_files = Dir.glob("#{@options[:context]}/one-context*alt*rpm")
        when 'opensuse'
            c_files = Dir.glob("#{@options[:context]}/one-context*suse*rpm")
        when 'freebsd'
            c_files = Dir.glob("#{@options[:context]}/one-context*txz")
        when 'windows'
            c_files = Dir.glob("#{@options[:context]}/one-context*msi")
        end

        if c_files.length == 1
            c_files[0]
        elsif c_files.length > 1
            latest = c_files.max_by { |f| Gem::Version.new(f.match(/(\d+\.\d+\.\d+(?:-\d+)?)/)[1])}
            latest
        else
            # download the correct one
            return false
        end
    end

    def context_command(disk, osinfo)
        base_cmd = "virt-customize -q -a #{disk}"
        cmd = nil
        fallback_cmd = nil
        context_fullpath = nil

        if osinfo['name'] == 'windows'
            context_fullpath = detect_context_package('windows')
            return false unless context_fullpath
            context_basename = File.basename(context_fullpath)
            cmd = base_cmd +
                  ' --mkdir /Temp'\
                  " --copy-in #{context_fullpath}:/Temp"\
                  " --firstboot-command 'msiexec -i c:\\Temp\\#{context_basename} /quiet && del c:\\Temp\\#{context_basename}'"
            return cmd, nil
        end

        # os gives versions, so check that instead of distro
        if osinfo['os'] =~ /^(redhat-based|rhel|fedora|ubuntu|debian)/ # start_with any of these
            os = nil
            opts = []
            fallback_opts = []

            case osinfo['os']
            when /^fedora/
                os = 'fedora'
                opts = [
                    " --copy-in %{context}:/tmp",
                    " --install /tmp/%{basename}",
                    " --delete /tmp/%{basename}",
                    " --run-command 'systemctl enable systemd-networkd'",
                    " --run-command 'systemctl disable systemd-networkd-wait-online'",
                    " --run-command 'sed -i \"s/SELINUX=enforcing/SELINUX=disabled/\" /etc/selinux/config || exit 0'"
                ]
                fallback_opts = [
                    " --copy-in %{context}:/tmp",
                    " --firstboot-install /tmp/%{basename}",
                    " --run-command 'systemctl enable systemd-networkd'",
                    " --run-command 'systemctl disable systemd-networkd-wait-online'",
                    " --run-command 'sed -i \"s/SELINUX=enforcing/SELINUX=disabled/\" /etc/selinux/config || exit 0'"
                ]
            when /^redhat-based8/, /^rhel8/
                os = 'rhel8'
                opts = [
                    " --run-command 'subscription-manager repos --enable codeready-builder-for-rhel-8-$(arch)-rpms'",
                    " --run-command 'yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm'",
                    " --copy-in %{context}:/tmp",
                    " --install /tmp/%{basename}",
                    " --delete /tmp/%{basename}",
                    " --run-command 'systemctl enable NetworkManager.service || exit 0'"
                ]
                fallback_opts = [
                    " --firstboot-install epel-release",
                    " --copy-in %{context}:/tmp",
                    " --firstboot-install /tmp/%{basename}",
                    " --run-command 'systemctl enable NetworkManager.service || exit 0'"
                ]
            when /^redhat-based9/, /^rhel9/
                os = 'rhel9'
                opts = [
                    " --run-command 'subscription-manager repos --enable codeready-builder-for-rhel-9-$(arch)-rpms'",
                    " --run-command 'yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm'",
                    " --copy-in %{context}:/tmp",
                    " --install /tmp/%{basename}",
                    " --delete /tmp/%{basename}",
                    " --run-command 'systemctl enable NetworkManager.service || exit 0'"
                ]
                fallback_opts = [
                    " --firstboot-install epel-release",
                    " --copy-in %{context}:/tmp",
                    " --firstboot-install /tmp/%{basename}",
                    " --run-command 'systemctl enable NetworkManager.service || exit 0'"
                ]
            when /^ubuntu/, /^debian/
                os = 'debian'
                opts = [
                    " --uninstall cloud-init",
                    " --copy-in %{context}:/tmp",
                    " --install /tmp/%{basename}",
                    " --delete /tmp/%{basename}",
                    " --run-command 'systemctl enable network.service || exit 0'"
                ]
                fallback_opts = [
                    " --uninstall cloud-init",
                    " --copy-in %{context}:/tmp",
                    " --firstboot-install /tmp/%{basename}",
                    " --run-command 'systemctl enable network.service || exit 0'"
                ]
            end

            context_fullpath = detect_context_package(os)
            return false unless context_fullpath

            context_basename = File.basename(context_fullpath)
            vars = {
                context: context_fullpath,
                basename: context_basename
            }

            cmd = base_cmd + opts.map { |c| c % vars }.join
            fallback_cmd = base_cmd + fallback_opts.map { |c| c % vars }.join

        elsif osinfo['os'].start_with?('alt', 'opensuse', 'sles')
            os = osinfo['os'].start_with?('alt') ? 'alt' : 'opensuse'
            context_fullpath = detect_context_package(os)
            return false unless context_fullpath
            context_basename = File.basename(context_fullpath)
            cmd = base_cmd +
                    " --copy-in #{context_fullpath}:/tmp"\
                    " --install /tmp/#{context_basename}"\
                    " --delete /tmp/#{context_basename}"
            fallback_cmd = base_cmd +
                            " --copy-in #{context_fullpath}:/tmp"\
                            " --firstboot-install /tmp/#{context_basename}"

        elsif osinfo['os'].start_with?('freebsd')
            # may not mount properly sometimes due to internal fs
            context_fullpath = detect_context_package('freebsd')
            return false unless context_fullpath
            context_basename = File.basename(context_fullpath)
            cmd = base_cmd +
                    ' --install curl,bash,sudo,base64,ruby,open-vm-tools-nox11'\
                    " --copy-in #{context_fullpath}:/tmp"\
                    " --install /tmp/#{context_basename}"\
                    " --delete /tmp/#{context_basename}"
            fallback_cmd = base_cmd +
                            ' --firstboot-install curl,bash,sudo,base64,ruby,open-vm-tools-nox11'\
                            " --copy-in #{context_fullpath}:/tmp"\
                            " --firstboot-install /tmp/#{context_basename}"

        elsif osinfo['os'].start_with?('alpine')
            puts 'Alpine is not compatible with offline install, please install context manually.'.brown
            return false
        end
        return false unless context_fullpath
        return cmd, fallback_cmd
    end

    def get_win_controlset(disk)
        cmd = 'virt-win-reg'\
              " #{disk}"\
              " 'HKLM\\SYSTEM\\Select'"
        print 'Checking Windows ControlSet...'
        stdout, _status = run_cmd_report(cmd, true)
        ccs = stdout.split("\n").find { |s| s.start_with?('"Current"') }.split(':')[1].to_i
        ccs
    end

    def win_context_inject(disk, osinfo)
        puts "win_context_inject"
        cmd = "guestfish <<_EOF_
add #{disk}
run
mount #{osinfo['mounts']['/']} /
upload #{@options[:virt_tools]}/rhsrvany.exe /rhsrvany.exe
upload #{detect_context_package('windows')} /one-context.msi
_EOF_"
        print "Uploading context files to Windows disk..."
        puts 'win_context_inject cmd: ' + cmd
        run_cmd_report(cmd)

        ccs = get_win_controlset(disk)
        regfile = File.open("#{@options[:work_dir]}/service.reg", 'w')
        regfile.puts("[HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet#{"%03d" % ccs}\\services\\RHSrvAnyContext]")
        regfile.puts('"Type"=dword:00000010')
        regfile.puts('"Start"=dword:00000002')
        regfile.puts('"ErrorControl"=dword:00000001')
        regfile.puts('"ImagePath"="c:\\rhsrvany.exe"')
        regfile.puts('"DisplayName"="RHSrvAnyContext"')
        regfile.puts('"ObjectName"="LocalSystem"')
        regfile.puts
        regfile.puts("[HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet#{"%03d" % ccs}\\services\\RHSrvAnyContext\\Parameters]")
        regfile.puts('"CommandLine"="msiexec -i c:\\one-context.msi"')
        regfile.puts('"PWD"="c:\\Temp"')
        regfile.flush
        regfile.close

        cmd = 'virt-win-reg'\
              ' --merge'\
              " #{disk}"\
              " #{@options[:work_dir]}/service.reg"

        print "Merging service registry entry to install on boot..."
        run_cmd_report(cmd)
    end

    def win_virtio_command(disk)
        # requires newer version of virt-customize actually
        cmd = 'virt-customize'\
              " -a #{disk}"\
              " --inject-virtio-win #{@options[:virtio_path]}"
        puts 'win_virtio_command cmd: ' + cmd
        cmd
    end

    def qemu_ga_command(disk)
        cmd = 'virt-customize'\
              " -a #{disk}"\
              " --inject-qemu-ga #{@options[:virtio_path]}"
        puts 'qemu_ga_command cmd: ' + cmd
        cmd
    end

    def pkg_install_command(disk, pkg)
        cmd = 'virt-customize'\
              " -a #{disk}"\
              " --install #{pkg}"
        cmd
    end

    def install_pkg(disk, pkg)
        print "Installing #{pkg}..."
        run_cmd_report(pkg_install_command(disk, pkg))
    end

    def guest_run_cmd(disk, cmd)
        cmd = 'guestfish'\
              " -a #{disk}"\
              ' -i'\
              " #{cmd}"
        puts "Running: #{cmd}"
        _stdout, _stderr, _status = Open3.capture3(cmd)
    end

    def package_injection(disk, osinfo)
        injector_cmd, fallback_cmd = context_command(disk, osinfo)
        if !injector_cmd
            if osinfo['name'] == 'windows'
                win_context_inject(disk, osinfo)
            else
                puts 'Unsupported guest OS or couldn\'t find context file for context injection. Please install manually.'.brown
            end
        elsif @options[:skip_context]
            print 'Skipping context injection...'
            return
        else
            # Perhaps have a separet function that does a bit more....stuff...
            print 'Injecting one-context...'
            _stdout, status = run_cmd_report(injector_cmd, true)
            if !status.success?
                print 'Context injection command appears to have failed. Attempting fallback'.brown
                _stdout, status = run_cmd_report(fallback_cmd, true)
                if !status.success?
                    puts 'Context injection fallback command failed somehow, please install context manually.'.red
                    return
                end
                print 'Context will install on first boot, you may need to boot it twice.'.brown
            end
        end

        if osinfo['name'] == 'windows' && @options[:virtio_path]
            injector_cmd = win_virtio_command(disk)
            print 'Injecting VirtIO to Windows...'
            run_cmd_report(injector_cmd)
        end

        if @options[:qemu_ga_win] && osinfo['name'] == 'windows'
            injector_cmd = qemu_ga_command(disk)
            print 'Injecting QEMU Guest Agent...'
            run_cmd_report(injector_cmd)
        end

        if @options[:qemu_ga_linux] && osinfo['name'] != 'windows'
            install_pkg(disk, 'qemu-guest-agent')
        end
    end

    def get_objects(vim, type, properties, folder = nil)
        pc = vim.serviceInstance.content.propertyCollector
        viewmgr = vim.serviceInstance.content.viewManager
        # determine if we need to look in specific folders
        if folder
            if folder.key?(:datacenter)
                rootFolder = vim.serviceInstance.find_datacenter(folder[:datacenter])
                if not rootFolder
                    raise 'Unable to find Datacenter with name '\
                        "'#{folder[:datacenter]}'."
                end
                if folder.key?(:cluster)
                    clusterFolder = rootFolder.find_compute_resource(folder[:cluster])

                    if not clusterFolder
                        raise 'Unable to find Cluster with name '\
                            "'#{folder[:cluster]}' in Datacenter "\
                            "'#{folder[:datacenter]}'."
                    end
                    rootFolder = clusterFolder
                end
            end
        else
            rootFolder = vim.serviceInstance.content.rootFolder
        end

        view = viewmgr.CreateContainerView({
                :container => rootFolder,
                :type => [type],
                :recursive => true
            });
        filterSpec = RbVmomi::VIM.PropertyFilterSpec(
                    :objectSet => [
                        :obj => view,
                        :skip => true,
                        :selectSet => [
                            RbVmomi::VIM.TraversalSpec(
                                :name => "traverseEntities",
                                :type => "ContainerView",
                                :path => "view",
                                :skip => false
                            )]
                    ],
                    :propSet => [
                        { :type => type, :pathSet => properties }
                    ]
                );
        pc.RetrieveProperties(:specSet => [filterSpec])
    end

    def build_v2v_hybrid_cmd(xml_file)
        # virt-v2v
        #   -i disk
        #   '/path/to/local/disk'
        #   -o local
        #   -os /path/to/working/folder
        #   -of [qcow2|raw]
        command = "#{@options[:v2v_path]} -v --machine-readable"\
                  ' -i libvirtxml'\
                  " #{xml_file}"\
                  ' -o local'\
                  ' --root first'\
                  " -os #{@options[:work_dir]}/conversions/"\
                  " -of #{@options[:format]}"
        command
    end

    def build_v2v_vc_cmd
        # virt-v2v
        #   -ic 'vpx://UserName@vCenter.Host.FQDN
        #             /Datacenter/Cluster/Host?no_verify=1'
        #   -ip password_file.txt ### Should be a 0600 file with only the password, no newline
        #   'virtual-machine-name'
        #   -o local
        #   -os /path/to/working/folder
        #   -of [qcow2|raw]
        dc,cluster,host = nil
        pobj = @props['runtime.host']
        while dc.nil? || cluster.nil? || host.nil?
            host    = pobj  if pobj.class == RbVmomi::VIM::HostSystem
            cluster = pobj  if pobj.class == RbVmomi::VIM::ClusterComputeResource
            cluster = false if pobj.class == RbVmomi::VIM::ComputeResource
            dc      = pobj  if pobj.class == RbVmomi::VIM::Datacenter
            pobj = pobj[:parent]
            if pobj.nil?
                raise "Unable to find Host, Cluster, and Datacenter of VM"
            end
        end

        if cluster == false
            url = "vpx://#{CGI::escape(@options[:vuser])}@#{@options[:vcenter]}"\
                  "/#{dc[:name]}/#{host[:name]}?no_verify=1"
        else
            url = "vpx://#{CGI::escape(@options[:vuser])}@#{@options[:vcenter]}"\
                  "/#{dc[:name]}/#{cluster[:name]}/#{host[:name]}?no_verify=1"
        end

        command = "#{@options[:v2v_path]} -v --machine-readable"\
                  " -ic #{url}"\
                  " -ip #{@options[:work_dir]}/vpassfile"\
                  ' -o local'\
                  " -os #{@options[:work_dir]}/conversions/"\
                  " -of #{@options[:format]}"\
                  " '#{@props['name']}'"
        command
    end

    def build_v2v_esx_cmd
        # virt-v2v
        #   -i vmx
        #   -ic 'ssh://UserName@ESXI.host.fqdn
        #             /vmfs/volumes/datastore/vmpath/vmfile.vmx
        #   -ip password_file.txt ### Should be a 0600 file with only the password, no newline
        #   -o local
        #   -os /path/to/working/folder
        #   -of [qcow2|raw]

        # [datastore1] example-vm/example-vm.vmx
        ds_name, vmx_relpath = @props['config'][:files][:vmPathName].split('] ', 2)
        ds_name.delete!('[')
        # /vmfs/volumes/65de2b62-8488ae37-d55b-3cecefcef5a6
        ds_path = @props['config'][:datastoreUrl].find { |ds| ds[:name] == ds_name }
        vmx_fullpath = "#{ds_path[:url]}/#{vmx_relpath}"

        url = "ssh://#{CGI::escape(@options[:esxi_user])}@#{@options[:esxi_ip]}"\
              "/#{vmx_fullpath}"
        command = "#{@options[:v2v_path]} -v --machine-readable"\
                  ' -i vmx'\
                  ' -it ssh'\
                  " #{url}"\
                  " -ip #{@options[:work_dir]}/esxpassfile"\
                  ' -o local'\
                  " -os #{@options[:work_dir]}/conversions/"\
                  " -of #{@options[:format]}"
        command
    end

    def build_v2v_vddk_cmd
        # openssl s_client -connect 147.75.45.11:443 </dev/null 2>/dev/null |
        # openssl x509 -in /dev/stdin -fingerprint -sha1 -noout 2>/dev/null

        # virt-v2v
        #   -ic 'vpx://UserName@vCenter.Host.FQDN/Datacenter/Cluster/Host?no_verify=1'
        #   -ip password_file.txt ### Should be a 0600 file with only the password, no newline
        #   -it vddk
        #   -io vddk-libdir=/path/to/vmware-vix-disklib-distrib
        #   -io vddk-thumbprint=xx:xx:xx:xx... # gather this
        #   'virtual-machine-name'
        #   -o local
        #   -os /path/to/working/folder
        #   -of [qcow2|raw]
        dc,cluster,host = nil
        pobj = @props['runtime.host']
        while dc.nil? || cluster.nil? || host.nil?
            host    = pobj if pobj.class == RbVmomi::VIM::HostSystem
            cluster = pobj if pobj.class == RbVmomi::VIM::ClusterComputeResource
            dc      = pobj if pobj.class == RbVmomi::VIM::Datacenter
            pobj = pobj[:parent]
            if pobj.nil?
                raise "Unable to find Host, Cluster, and Datacenter of VM"
            end
        end

        tcp_client = TCPSocket.new(@options[:vcenter], 443)
        ssl_context = OpenSSL::SSL::SSLContext.new
        ssl_client = OpenSSL::SSL::SSLSocket.new(tcp_client, ssl_context)
        ssl_client.connect

        ssl_client.puts("GET / HTTP/1.0\r\n\r\n")
        ssl_client.read

        ssl_client.sysclose
        tcp_client.close

        cert = ssl_client.peer_cert
        @options[:vddk_thumb] = OpenSSL::Digest::SHA1.new(cert.to_der).to_s.scan(/../).join(':')

        puts "Certificate thumbprint: #{@options[:vddk_thumb]}"

        url = "vpx://#{CGI::escape(@options[:vuser])}@#{@options[:vcenter]}"\
              "/#{dc[:name]}/#{cluster[:name]}/#{host[:name]}?no_verify=1"
        command = "#{@options[:v2v_path]} -v --machine-readable"\
                  " -ic #{url}"\
                  " -ip #{@options[:work_dir]}/vpassfile"\
                  ' -it vddk'\
                  " -io vddk-libdir=#{@options[:vddk_path]}"\
                  " -io vddk-thumbprint=#{@options[:vddk_thumb]}"\
                  ' -o local'\
                  " -os #{@options[:work_dir]}/conversions/"\
                  " -of #{@options[:format]}"\
                  " '#{@props['name']}'"
        command
    end

    def build_v2v_ova
        # virt-v2v
        #   -i VM.ova
        #   -o local
        #   -os /path/to/working/folder
        #   -of [qcow2|raw]
        #   --root=[ask|single|first|/dev/sdX]

        command = "#{@options[:v2v_path]} -v --machine-readable"\
                  " -i ova #{@options[:ova]}"\
                  ' -o local'\
                  " -os #{@options[:work_dir]}/conversions/"\
                  " -of #{@options[:format]}"\
                  " --root=#{@options[:root]}"
        command
    end

    # Create and run the virt-v2v conversion
    # This uses virt-v2v to connect to vCenter/ESXi, create an overlay on the remote disk,
    #   and convert it before using qemu-img convert over nbdkit connection.  Outputs a
    #   converted qcow2/raw image and libvirt compatible xml definition.
    def run_v2v_conversion
        if @options[:hybrid]
            vc_disks = @props['config'][:hardware][:device].grep(RbVmomi::VIM::VirtualDisk).sort_by(&:key)
            local_disks = hybrid_downloader(vc_disks)
            local_xml = build_hybrid_xml(local_disks)
            local_xml_file = @options[:work_dir] + '/local.xml'
            File.open(local_xml_file, 'w') { |f| f.write(local_xml) }
            command = build_v2v_hybrid_cmd(local_xml_file)
        elsif @options[:esxi_ip]
            command = build_v2v_esx_cmd
        elsif @options[:vddk_path]
            command = build_v2v_vddk_cmd
        elsif @options[:ova]
            command = build_v2v_ova
        else
            command = build_v2v_vc_cmd
        end

        puts "Running: #{command}"

        begin
            error_check = nil
            _stdin, stdout, stderr, wait_thr = Open3.popen3(command)

            # Handle each std pipe as a separate thread
            stdout_thread = Thread.new do
                begin
                    stdout.each_line { |line| handle_stdout(line) }
                rescue StandardError => e
                    error_check = e
                end
            end

            stderr_thread = Thread.new do
                stderr.each_line { |line| handle_stderr(line) }
            end

            stdout_thread.join
            stderr_thread.join
            exit_status = wait_thr.value
            print "\n"
            # puts "Process exited with status: #{exit_status}"
            if error_check
                raise "Error: #{error_check.message}"
            end
            if exit_status != 0
                raise "virt-v2v exited in error code #{exit_status} but did not provide an error"
            end

            disks_on_file = Dir.glob("#{@options[:work_dir]}/conversions/#{@options[:name]}*").reject {|f| f.end_with?('.xml')}.sort
            puts "#{disks_on_file.length} disks on the local disk for this VM: #{disks_on_file}"
            if disks_on_file.length == 0
                raise "There are no disks on the local filesystem due to previous failures."
            end

            img_ids = create_one_images(disks_on_file)
            img_ids
        rescue StandardError => e
            # puts "Error raised: #{e.message}"
            if @props['config'][:guestFullName].include?('Windows')
                puts 'Windows not supported for fallback conversion.'.brown
                raise e
            end
            if @options[:fallback]
                puts "Error encountered, fallback enabled. Attempting Custom Conversion now."
                cleanup_disks
                run_custom_conversion
            elsif @options[:hybrid]
                puts "Hybrid conversion failed, attempting manual conversion."
                run_custom_conversion
            else
                puts "Failed. Fallback is not enabled. Raising error.".red
                raise e
            end
        end
    end

    # Create and run the qemu-img vmdk conversion
    # This uses qemu-img to convert an vmdk image to desired format (Default: qcow2).
    # Outputs a converted image location if success
    def convert_vmdk(vmdk_path, output_format: 'qcow2')
        raise "Input file not found: #{vmdk_path}" unless File.exist?(vmdk_path)
        puts "Converting disk #{vmdk_path} to #{output_format}..."
        base_name = File.basename(vmdk_path, '.vmdk')
        output_path = File.join(@options[:work_dir], 'conversions', "#{base_name}.#{output_format}")
        command = "qemu-img convert -O #{output_format} -p -S 4k -W #{vmdk_path} #{output_path}"
        t0 = Time.now
        success = system(command)
        duration = (Time.now - t0).round(2)
        if success
          puts "Disk converted successfully in #{duration} seconds."
          return output_path
        else
          raise "Failed to convert #{vmdk_path} to #{output_format}"
        end
    end

    def handle_v2v_error(line)
        LOGGER[:stderr].puts("#{Time.now.to_s[0...-6]} - #{line}") if DEBUG
        pass_list  = [
            'unable to rebuild initrd',
            'unable to find any valid modprobe configuration file',
            'only Xen kernels are installed in this guest.',
            'not enough available inodes for conversion on',
            'not enough free space for conversion on filesystem',
            'could not write to the guest filesystem'
        ]
        error_list = [
            {
                :text  => 'inspection could not detect the source guest',
                :error => 'Could not find the guest OS inside the target machine.'
            },
            {
                :text  => 'virt-v2v is unable to convert this guest type',
                :error => 'Unable to process this guest type.'
            },
            {
                :text  => 'unable to mount the disk image for writing',
                :error => 'Disk did not mount properly, try disabling Windows Hiberanation or Fast Restart in this guest.'
            },
            {
                :text  => 'filesystem was mounted read-only, even though',
                :error => 'Disk mountd read-only, try disabling Windows Hiberation or Fast Restart in this guest and cleanly shut it down.'
            },
            {
                :text  => 'inspection could not detect the source guest',
                :error => 'Unable to find, or inspect, the OS disk'
            },
            {
                :text  => 'multi-boot operating systems are not supported',
                :error => 'Multi-boot Operating Systems are not currently supported.'
            },
            {
                :text  => 'libguestfs thinks this is not an installed operating',
                :error => 'Guest does not appear to be an installed OS, but rather a LiveCD or installer disk'
            },
            {
                :text  => 'inspection of the package database failed for this Linux',
                :error => 'Failed to inspect package database for this guest.'
            },
            {
                :text  => 'no installed kernel packages were found.',
                :error => 'Can\'t find kernel packages inside VM, please ensure kernel header packages are installed in this guest'
            }
        ]

        err = pass_list.detect  { |e| line['message'].start_with?(e) }
        raise(err.red) if err

        err = error_list.detect { |e| line['message'].start_with?(e[:text]) }
        puts "DEBUG INFO: #{line['message']}".red
        err ? raise(err[:error].red)  : raise("Unknown error occurred: #{line['message']}".bg_red)
    end

    def handle_stdout(line)
        LOGGER[:stdout].puts("#{Time.now.to_s[0...-6]} - #{line}") if DEBUG
        begin
            line = JSON.parse(line)
        rescue JSON::ParserError
            if line.start_with?(/^[0-9]+\/[0-9]+$/)
                print line
                return
            end
            return
        end
        print "\n"
        STDOUT.flush
        case line['type']
        when 'error'
            print "DEBUG INFO: #{line['message']}".bg_red
            handle_v2v_error(line)
        when 'warning'
            print "#{line['message']}".brown
        when 'message'
            print "#{line['message']}".green
            if line['message'].start_with?('Converting')
                print ", this may take a long time".green
            elsif line['message'].start_with?('Copying disk')
                print ", this may take a long time".green
                print "\n"
                @dotskip = true
            end
        when 'info'
            print line['message']
        when 'progress'
            print line['message'].bg_green
        else
            print "#{line}".bg_cyan
        end
        STDOUT.flush
    end

    def handle_stderr(line)
        return if line.start_with?('nbdkit: debug:')
        return if line.start_with?('nbdkit: curl[4]: debug:')
        prefixes = {
            'guestfsd: <= list_filesystems' => "Inspecting filesystems, this can take several minutes".green,
            'guestfsd: <= inspect_os' => "Inspecting guest OS".green,
            'mpstats:' => "Gathering mountpoint stats and converting guest".green,
            'commandrvg: /usr/sbin/update-initramfs' => "Generating initramfs, this can take several minutes(20+) on many systems. Please be patient and do not interrupt the process.".brown,
            'chroot: /sysroot: running \'librpm\'' => "Querying RPMs with librpm, this can take a while".green,
            'dracut: *** Creating image file' => "Creating boot image with dracut".green
          }

          line_prefix = prefixes.keys.detect { |e| line.start_with?(e) }

          if line_prefix
            print "\n#{prefixes[line_prefix]}"
            STDOUT.flush
          else
            if !@dotskip
                @last_dot_time ||= Time.now
                if Time.now - @last_dot_time >= 0.1  # Check if 100ms have elapsed since the last dot
                    print '.'
                    @last_dot_time = Time.now
                end
            end
            LOGGER[:stderr].puts("#{Time.now.to_s[0...-6]} - #{line}") if DEBUG
          end
    end

    def create_one_images(disks)
        puts 'Creating Images in OpenNebula'
        img_ids = []
        persistent_image = @options[:persistent_img] ? 'YES' : 'NO'

        # Normalize datastore input to an array of integers
        datastores = @options[:datastore].to_s.split(',').map(&:strip).map(&:to_i)

        disks.each_with_index do |d, i|
            img = OpenNebula::Image.new(OpenNebula::Image.build_xml, @client)
            guest_info = detect_distro(d)
            os_name = false
            begin
                if guest_info
                    package_injection(d, guest_info)
                    remove_vmtools_injection(d, guest_info)
                    os_name = guest_info['name']
                end
            rescue Exception => e
                if osinfo['name'] == 'windows'
                    puts "Error with package injection. Conversion failed. Check that you have virtio and context packages in place.".red
                    exit -1
                else
                    puts "Error with package injection, converted VM may fail to boot".red
                    puts "#{e.message}"
                end
            end

            if @options[:http_transfer]
                path = "http://#{@options[:http_host]}:#{@options[:http_port]}/#{File.basename(d)}"
                server_thread = Thread.new do
                    server = WEBrick::HTTPServer.new({
                        Port: @options[:http_port],
                        DocumentRoot: File.dirname(d),
                        RequestCallback: ->(req, res) {
                            res['Cache-Control'] = 'public, max-age=3600'
                        },
                        MaxThreads: 8,
                    })

                    trap('INT') { server.shutdown }

                    server.start
                end
            else
                path = d
            end

            img.add_element('//IMAGE', {
                'NAME' => "#{@options[:name]}_#{i}",
                'TYPE' => guest_info ? 'OS' : 'DATABLOCK',
                'PATH' => path,
                'PERSISTENT' => persistent_image,
            })

            puts "Allocating image #{i} in OpenNebula"

            # Pick datastore index if available, else default to the first one
            ds_id = datastores[i] || datastores.first
            rc = img.allocate(img.to_xml, ds_id)

            if rc.class == OpenNebula::Error
                puts 'Failed to create image. Image Definition:'.red
                puts img.to_xml
            end

            img_wait_sec = @options[:img_wait] || 120
            puts 'Waiting for image to be ready. Timeout: ' + img_wait_sec.to_s + ' seconds.'

            img_wait_return = img.wait_state('READY', img_wait_sec)
            if img_wait_return == false
                puts 'Image did not become ready in time.'
                puts 'Image Short State: ' + img.short_state_str
            end

            if @options[:http_transfer]
                server_thread.kill
                server_thread.join
            end

            img_ids.append({ :id => img.id, :os => os_name })
        end

        img_ids
    end

    def hybrid_downloader(vc_disks)
        local_disks = []
        puts 'Downloading disks from vCenter storage to local disk'
        vc_disks.each_with_index do |d, i|
            # download each disk to the work dir
            remote_file = d[:backing][:fileName].sub(/^\[.+?\] /, '')
            remote_file = remote_file.sub(/\.vmdk$/, '-flat.vmdk')

            if remote_file.nil? or remote_file.empty?
                raise "Unable to determine remote path for disk #{i}.".red
            end

            local_file = @options[:work_dir] + '/transfers/' + @props['name'] + "-disk#{i}.vmdk"
            d[:backing][:datastore].download(remote_file, local_file)
            local_disks.append(local_file)
        end

        if local_disks.empty?
            raise "Unable to download any disks from vCenter storage.".red
        end

        local_disks
    end

    def build_hybrid_xml(disks)
        domain_xml = <<-XML
          <domain type='kvm'>
            <name>#{@options[:name]}</name>
            <memory unit='KiB'>1048576</memory>
            <vcpu>2</vcpu>
            <os>
              <type>hvm</type>
              <boot dev='hd'/>
            </os>
            <features>
              <acpi/>
              <apic/>
              <pae/>
            </features>
            <devices>
        XML
        suffix = 'a'
        disks.each_with_index do |d, i|
            disk_xml = <<-XML
              <disk type='file' device='disk'>
                <source file='#{d}'/>
                <target dev='sd#{suffix}' bus='scsi'/>
              </disk>
            XML
            domain_xml << disk_xml
            suffix = next_suffix(suffix)
        end
        domain_xml << '</devices></domain>'
        domain_xml
    end

    def run_custom_conversion
        if !@options[:hybrid]
            vmdks = []
            vc_disks = @props['config'][:hardware][:device].grep(RbVmomi::VIM::VirtualDisk).sort_by(&:key)
            puts 'Downloading disks from vCenter storage to local disk'
            vc_disks.each_with_index do |d, i|
                # download each disk to the work dir
                remote_file = d[:backing][:fileName].sub(/^\[.+?\] /, '').sub(/\.vmdk$/, '-flat.vmdk')
                local_file = @options[:work_dir] + '/conversions/' + @props['name'] + "-disk#{i}"
                d[:backing][:datastore].download(remote_file, local_file + '.vmdk')
                vmdks.append(local_file)
                puts "Downloaded disk ##{i}."
            end
        else
            vmdks = Dir.glob("#{@options[:work_dir]}/transfers/*.vmdk").map { |f| f.chomp('.vmdk') }
        end

        puts 'Converting disks locally'
        local_disks = []
        vmdks.each_with_index do |d, i|
            # -p to show Progress, -S 4k to set Sparse Cluster Size to 4kb, -W for out of order writes
            t0 = Time.now
            command = 'qemu-img convert'\
                      " -O #{@options[:format]}"\
                      ' -p -S 4k -W'\
                      " #{d}.vmdk #{d}.#{@options[:format]}"
            system(command) # don't need to interact or anything, just display the output straight.
            puts "Disk #{i} converted in #{(Time.now - t0).round(2)} seconds. Deleting vmdk file".green
            #puts "that's a lie, not deleting the vmdk".bg_blue
            command = "rm -f #{d}.vmdk"
            system(command)
            local_disks.append("#{d}.#{@options[:format]}")
        end

        create_one_images(local_disks)
    end

    def get_vcenter_nic_info
        con_ops = connection_options('vm', @options)
        vi_client = RbVmomi::VIM.connect(con_ops)
        properties = [
            'name',
            'key'
        ]
        distributed_networks = get_objects(vi_client, 'DistributedVirtualPortgroup', properties)

        network_types = [
            RbVmomi::VIM::VirtualVmxnet,
            RbVmomi::VIM::VirtualVmxnet2,
            RbVmomi::VIM::VirtualVmxnet3
        ]
        # Get and sort the network interfaces
        vc_nics = @props['config'][:hardware][:device].select { |d|
            network_types.any? { |nt| d.is_a?(nt) }
        }.sort_by(&:key)

        nic_backing = vc_nics.map do |n|
            if n[:backing].is_a? RbVmomi::VIM::VirtualEthernetCardDistributedVirtualPortBackingInfo
                ds_network = distributed_networks.find { |dn| dn.to_hash['key'] == n[:backing][:port][:portgroupKey] }
                [n[:key], ds_network.to_hash['name']]
            else
                [n[:key], n[:backing][:network][:name]]
            end
        end.compact.to_h

        return vc_nics, nic_backing
    end

    def add_one_nics(vm_template, vc_nics, vc_nic_backing)
        netmap = {}
        one_networks = OpenNebula::VirtualNetworkPool.new(@client)
        one_networks.info
        one_networks.each do |n|
            n.info
            next if !n['//VNET/TEMPLATE/VCENTER_NETWORK_MATCH']
            netmap[n['//VNET/TEMPLATE/VCENTER_NETWORK_MATCH']] = n['//VNET/ID']
        end

        if @options[:network] && vc_nics.length > 0
            networks = @options[:network].to_s.split(',').map(&:strip).map(&:to_i)
            if networks.length == 1
                networks = Array.new(vc_nics.length, networks.first)
            elsif networks.length != vc_nics.length
                raise "Error: Number of networks (#{networks.length}) must match number of NICs (#{vc_nics.length})"
            end

            puts "Adding #{vc_nics.length} NICs, assigning networks from #{@options[:network]}"
            nic_number = 0
            vc_nics.each_with_index do |n, index|
                guest_network = @props['guest.net'].find { |gn| gn[:deviceConfigId] == n[:key] }
                assigned_network = networks[index]
                net_templ = {'NIC' => { 'NETWORK_ID' => "#{assigned_network}" }}

                if !@options[:skip_mac]
                    puts "Adding MAC address to NIC##{nic_number}"
                    net_templ['NIC']['MAC'] = n[:macAddress]
                else
                    puts "Skipping MAC address for NIC##{nic_number}"
                end

                if !netmap.has_key?(vc_nic_backing[n[:key]])
                    network_info_found = false
                    one_networks.each do |on_network|
                        network_info = on_network.to_hash
                        if network_info.include?('VNET') && network_info['VNET']['NAME'] == vc_nic_backing[n[:key]]
                            network_info_found = true
                            net_templ['NIC']['NETWORK_ID'] = network_info['VNET']['ID']
                            net_templ['NIC']['NETWORK'] = vc_nic_backing[n[:key]]
                            break
                        end
                    end
                    unless network_info_found
                        puts "Could not find OpenNebula network matching the provided name. Setting to assigned network: #{assigned_network}"
                        net_templ['NIC']['NETWORK_ID'] = "#{assigned_network}"
                    end
                end

                if !guest_network
                    puts "Found network '#{vc_nic_backing[n[:key]]}' but no guest network information. Adding blank NIC."
                    vm_template.add_element('//VMTEMPLATE', net_templ)
                    next
                end

                if @options[:skip_ip] || !guest_network[:ipConfig]
                    vm_template.add_element('//VMTEMPLATE', net_templ)
                    puts "Added NIC##{nic_number} to network #{net_templ['NIC']['NETWORK_ID']}"
                else
                    netkey = 'NIC_ALIAS'
                    guest_network[:ipConfig][:ipAddress].each do |ip|
                        net_templ = {netkey => @options[:skip_mac] ? {} : {'MAC' => n[:macAddress] }}
                        net_templ[netkey]['NETWORK_ID'] = netmap[guest_network[:network]] || "#{assigned_network}"

                        if ip[:ipAddress]
                            ipv = "#{ip_version(ip[:ipAddress])}"
                        else
                            puts "Skipping address range creation"
                            next
                        end
                        net_templ[netkey]['PARENT'] = "NIC#{nic_number}" if netkey == 'NETWORK_ALIAS'
                        ar_template = "AR=[TYPE=#{ipv},SIZE=1,IP=#{ip[:ipAddress]}]"
                        print "Creating AR for IP #{ip[:ipAddress]}..."
                        xml = OpenNebula::VirtualNetwork.build_xml(net_templ[netkey]['NETWORK_ID'])
                        vn  = OpenNebula::VirtualNetwork.new(xml, @client)
                        rc = vn.add_ar(ar_template)
                        if rc.nil?
                            puts "Success".green
                            net_templ[netkey]['IP'] = ip[:ipAddress]
                            vm_template.add_element('//VMTEMPLATE', net_templ)
                            puts "Added NIC##{nic_number} to network #{net_templ['NIC']['NETWORK_ID']}"
                            netkey = 'NETWORK_ALIAS'
                        else
                            puts "Failed. rc = #{rc.message}".red
                        end
                    end
                end
                nic_number += 1
            end
        elsif vc_nics.length > 0
            puts "You will need to create NICs and assign networks in the VM Template in OpenNebula manually."
        end
        vm_template
    end

    # Remove VMWare Tools injection from the VM
    def remove_vmtools_injection(disk, osinfo)
        if @options[:remove_vmtools]
            puts 'Starting VMWare Tools Removal script injection...'
            if osinfo['name'] == 'windows'
                default_path = "#{SCRIPTS_LOCATION}/vmware_tools_removal.ps1"
            else
                default_path = "#{SCRIPTS_LOCATION}/vmware_tools_removal.sh"
            end
            script_path = File.exist?(default_path) ? default_path : nil
            unless script_path && File.exist?(script_path)
                puts 'Unable to find vmware_tools_removal script, please remove VMWare Tools manually.'
                return
            end
            cmd = "virt-customize -q -a #{disk} --firstboot '#{script_path}'"
            _stdout, status = run_cmd_report(cmd, true)
            if !status.success?
                puts 'Remove VMWare tools injection failed somehow, please remove VMWare Tools manually.'
                return
            end
            puts "VMware Tools removal injection completed. The script will run on the first boot.".green
        end
    end

    # Run a OpenNebula system prechecks:
    #
    # - Check if there is enough space in the datastore
    # - Check if the Image name already exists
    # - Check if the VM Template name already exists
    # - Check if the OpenNebula network exists
    #
    def one_prechecks(vm)
        puts 'Running OpenNebula prechecks...'
        ## Precheck datastore space (check if it will be enough space for the image)
        vm_obj = vm.obj
        vm_size_kb = 0

        vm_obj.config.hardware.device.each do |device|
            if device.is_a?(RbVmomi::VIM::VirtualDisk)
                vm_size_kb += device.capacityInKB
            end
        end
        vm_size_gb = vm_size_kb.to_f / (1024 * 1024)

        ds_target_id = @options[:datastore].to_i
        one_datastores = OpenNebula::DatastorePool.new(@client)
        one_datastores.info
        one_datastores.each do |ds|
            if ds.id == ds_target_id
                ds.info
                available_mb = ds['FREE_MB'].to_i
                available_kb = available_mb * 1024
                available_gb = available_mb.to_f / 1024
                if vm_size_kb > available_kb
                    raise "Not enough space in the datastore. Available: #{available_gb.round(2)} GB, VM Size: #{vm_size_gb.round(2)} GB".red
                end
            end
        end

        ## Precheck image name (check if it exists)
        one_images = OpenNebula::ImagePool.new(@client)
        one_images.info
        one_images.each do |i|
            if i.name =~ /^#{Regexp.escape(@options[:name])}_\d+$/ && ['OS', 'DATABLOCK'].include?(i.type_str)
                raise "Image with name #{@options[:name]}_{id} already exists.".red
            end
        end

        ## Precheck VM Template name (check if it exists)
        one_templates = OpenNebula::TemplatePool.new(@client)
        one_templates.info
        one_templates.each do |t|
            if t.name == @options[:name]
                raise "VM Template with name #{@options[:name]} already exists.".red
            end
        end

        ## Precheck OpenNebula Networks (check if exists)
        one_networks = OpenNebula::VirtualNetworkPool.new(@client)
        one_networks.info
        unless one_networks.any? { |n| n.id == @options[:network].to_i }
            raise "Network with ID #{@options[:network]} does not exist.".red
        end
    end

    # General method to list vCenter objects
    #
    # @param options [Hash] User CLI options
    # @param object  [Hash] Object Type
    def list(options)
        case options[:object]
        when 'datacenters'
            list_datacenters(options)
        when 'clusters'
            list_clusters(options)
        when 'vms'
            list_vms(options)
        else
            raise 'Invalid object type for listing'.brown
        end
    end

    # General wrapper to fix options and handle fatal errors
    #
    # @param name    [Hash] Object Name
    # @param options [Hash] User CLI options
    def convert(name, options)
        check_one_connectivity
        if !Dir.exist?(options[:work_dir])
            raise 'Provided working directory '\
                  "#{options[:work_dir]} doesn't exist"
        end
        options[:name] = name
        options[:work_dir] << "/#{name}"
        @options = options
        conv_path = "#{@options[:work_dir]}/conversions/"
        tran_path = "#{@options[:work_dir]}/transfers/"
        begin
            Dir.mkdir(@options[:work_dir]) if !Dir.exist?(@options[:work_dir])
            Dir.mkdir(conv_path) if !Dir.exist?(conv_path)
            Dir.mkdir(tran_path) if !Dir.exist?(tran_path)

            password_file = File.open("#{@options[:work_dir]}/vpassfile", 'w')
            password_file.print @options[:vpass]
            password_file.chmod(0600)
            password_file.close

            password_file = File.open("#{@options[:work_dir]}/esxpassfile", 'w')
            password_file.print @options[:esxi_pass]
            password_file.chmod(0600)
            password_file.close

            convert_vm
        ensure
            password_file.close unless password_file.nil? or password_file.closed?
            cleanup_all
        end
    end

    # Import a VM from file (OVA, folder with files)
    #
    # @param name    [Hash] Object Name
    # @param options [Hash] User CLI options
    def import(options)
        source = options[:ova] || options[:vmdk]
        name = File.basename(source, File.extname(source))
        check_one_connectivity
        if !Dir.exist?(options[:work_dir])
            raise 'Provided working directory '\
                  "#{options[:work_dir]} doesn't exist"
        end
        options[:name] = name
        options[:work_dir] << "/#{name}"
        @options = options
        conv_path = "#{@options[:work_dir]}/conversions/"
        tran_path = "#{@options[:work_dir]}/transfers/"
        begin
            Dir.mkdir(@options[:work_dir]) if !Dir.exist?(@options[:work_dir])
            Dir.mkdir(conv_path) if !Dir.exist?(conv_path)
            Dir.mkdir(tran_path) if !Dir.exist?(tran_path)

            if options[:vmdk]
                import_image
            else
                import_vm
            end
        ensure
            cleanup_all
        end
    end

    # List all vms
    #
    # @param options [Hash] User CLI options
    def list_vms(options)
        con_ops   = connection_options('vms', options)
        vi_client = RbVmomi::VIM.connect(con_ops)
        properties = [
            'name',
            'config.template',
            'config.uuid',
            'summary.runtime.powerState',
            'runtime.host',
            'config.hardware.numCPU',
            'config.hardware.memoryMB',
            'config.memoryHotAddEnabled',
            'config.cpuHotAddEnabled'
        ]

        if options.key?(:datacenter)
            filter = {}
            filter[:datacenter] = options[:datacenter]
            if options.key?(:cluster)
                filter[:cluster] = options[:cluster]
            end
            vms = get_objects(vi_client, 'VirtualMachine', properties, filter)
        elsif options.key?(:cluster)
            raise 'Filtering by cluster requires a datacenter.'
        else
            vms = get_objects(vi_client, 'VirtualMachine', properties)
        end

        list = []
        available_filters = [:name, :state]
        filters = nil
        if (available_filters & options.keys).any?
            filters = options.select { |key,_| available_filters.include?(key) }
        end
        vms.each do |vm|
            props = vm.to_hash
            next unless !props['config.template']
            if filters
                if filters[:name]
                    next if !props['name'].include?(filters[:name])
                end
                if filters[:state]
                    next if !props['summary.runtime.powerState'].include?(filters[:state])
                end
            end
            v = {}

            v[:imid]  = vm.obj._ref
            v[:name]  = props['name']
            v[:state] = props['summary.runtime.powerState']
            v[:host]  = props['runtime.host']
            v[:ref]   = props['config.uuid']
            v[:cpu]   = props['config.hardware.numCPU']
            v[:mem]   = props['config.hardware.memoryMB']
            list << v
        end
        format_list.show(list, options)
    end

    # List datacenters
    #
    # @param options [Hash] User CLI options
    def list_datacenters(options)
        con_ops = connection_options('datacenters', options)
        vi_client = RbVmomi::VIM.connect(con_ops)

        list  = []
        dcs = get_objects(vi_client, 'Datacenter', ['name'])

        dcs.each do |dc|
            v = {}
            conf = dc.to_hash['name']
            v[:datacenter] = conf.to_s
            list << v
        end
        format_list.show(list, options)
    end

    # List Clusters
    #
    # @param options [Hash] User CLI options
    def list_clusters(options)
        con_ops = connection_options('clusters', options)
        vi_client = RbVmomi::VIM.connect(con_ops)

        list  = []
        properties = [
            'summary.usageSummary.totalVmCount',
            'name'
        ]

        if options.key?(:datacenter)
            filter = {}
            filter[:datacenter] = options[:datacenter]
            cs = get_objects(vi_client, 'ComputeResource', properties, filter)
        else
            cs = get_objects(vi_client, 'ComputeResource', properties)
        end

        cs.each do |c|
            conf = c.to_hash
            v = {}
            v[:name] = conf['name'].to_s
            v[:vm_count] = conf['summary.usageSummary.totalVmCount']
            list << v
        end
        format_list.show(list, options)
    end

    # Import VM
    #
    # @param options [Hash] User CLI Options
    def import_vm
        # Convert OVA to KVM compatible, getting disks and XML file for the VM
        img_ids = run_v2v_conversion
        puts img_ids.nil? ? "No Images ID's reported being created".red : "Created images: #{img_ids}".green

        # Create base template using XML from OVA conversion
        vm_template = create_vm_template_from_ova

        img_ids.each do |i|
            img_hash = { 'IMAGE_ID' => "#{i[:id]}" }
            if @options[:dev_prefix]
                img_hash["DEV_PREFIX"] = "#{@options[:dev_prefix]}"
            elsif i[:os]
                if i[:os] == 'windows'
                    img_hash["DEV_PREFIX"] = "vd"
                end
            end
            vm_template.add_element('//VMTEMPLATE', {"DISK" => img_hash})
        end

        # Optimize template for Windows VMs
        if img_ids[0][:os] == 'windows'
            vm_template = tune_windows_tmpl(vm_template)
        end

        print "Allocating the VM template..."

        rc = vm_template.allocate(vm_template.to_xml)

        if rc.nil?
            puts 'Success'.green
            puts "VM Template ID: #{vm_template.id}\n"
        else
            puts 'Failed'.red
            puts "\nVM Template:\n#{vm_template.to_xml}\n"
        end
    end

    # Import Image
    #
    # @param options [Hash] User CLI Options
    #
    def import_image
        # Convert VMDK to QCOW2 compatible
        print "Converting the Image => "
        img_loc = convert_vmdk(@options[:vmdk])
        puts img_loc.nil? ? "No Image reported being converted".red : "Converted image: #{img_loc}".green

        # Import Image to OpenNebula
        print "Allocating the Image => "
        img_ids = create_one_images([img_loc])
        puts img_ids.nil? || img_ids.first[:id].nil? ? "No Image reported being created".red : "Created image: #{img_ids.first[:id]}".green
    end

    # Convert VM
    #
    # @param options [Hash] User CLI Options
    def convert_vm
        con_ops = connection_options('vm', @options)
        vi_client = RbVmomi::VIM.connect(con_ops)
        properties = [
            'config',
            'datastore',
            'guest.net',
            'guest.guestFullName',
            'name',
            'parent',
            'snapshot',
            'summary.runtime.powerState',
            'resourcePool',
            'runtime.host'
        ]

        vm_pool = get_objects(vi_client, 'VirtualMachine', properties)
        vm = vm_pool.find { |r| r['name'] == @options[:name] }
        if vm.nil?
            raise "Unable to find Virtual Machine by name '#{@options[:name]}'"
        end

        @props = vm.to_hash

        # If clone option is set, clone the VM and override VM properties
        if @options[:clone]
            begin
                cloned_vm = clone_vm(vi_client, properties, vm)
                @props = cloned_vm.to_hash
            rescue RbVmomi::Fault => e
                raise "Failed to clone VM #{@options[:name]}: #{e.message}"
            end
        end

        # Some basic preliminary checks
        if @props['summary.runtime.powerState'] != 'poweredOff'
            raise "Virtual Machine #{@options[:name]} is not Powered Off.".red
        end
        if !@props['snapshot'].nil?
            raise "Virtual Machine #{@options[:name]} cannot have existing snapshots.".red
        end
        if @props['config'][:guestFullName].include?('Windows') && @options[:custom_convert]
            raise "Windows is not supported in OpenNebula's Custom Conversion process".red
        end

        # OpenNebula system prechecks
        if !@options[:skip_prechecks]
            one_prechecks(vm)
        end

        # Gather NIC backing early because it makes a call to vCenter,
        # which may not be authenticated after X hours of converting disks
        vc_nics, vc_nic_backing = get_vcenter_nic_info

        vm_template = create_vm_template

        img_ids = @options[:custom_convert] ? run_custom_conversion : run_v2v_conversion

        puts img_ids.nil? ? "No Images ID's reported being created".red : "Created images: #{img_ids}".green

        img_ids.each do |i|
            img_hash = { 'IMAGE_ID' => "#{i[:id]}" }
            if @options[:dev_prefix]
                img_hash["DEV_PREFIX"] = "#{@options[:dev_prefix]}"
            elsif i[:os]
                if i[:os] == 'windows'
                    img_hash["DEV_PREFIX"] = "vd"
                end
            end
            vm_template.add_element('//VMTEMPLATE', {"DISK" => img_hash})
        end

        # If clone option is set, delete clean up the cloned VM
        if @options[:clone]
            puts "Cleaning up cloned VM..."
            begin
                delete_vm(cloned_vm)
            rescue RbVmomi::Fault => e
                puts "Failed to delete cloned VM #{@options[:name]}: #{e.message}, remove the cloned VM manually."
            end
        end

        # Add the NIC's now, after any conversion stuff has happened since it creates OpenNebula objects
        vm_template = add_one_nics(vm_template, vc_nics, vc_nic_backing)

        if img_ids[0][:os] == 'windows'
            vm_template = tune_windows_tmpl(vm_template)
        end

        print "Allocating the VM template..."

        rc = vm_template.allocate(vm_template.to_xml)

        if rc.nil?
            puts 'Success'.green
            puts "VM Template ID: #{vm_template.id}\n"
        else
            puts 'Failed'.red
            puts "\nVM Template:\n#{vm_template.to_xml}\n"
        end
    end
end
