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

##############################################################################
# Module OneVcenterHelper
##############################################################################
class OneSwapHelper < OpenNebulaHelper::OneHelper

    @props, @options = []
    # true to log to /var/log/one/oneswap.*
    DEBUG = false

    # vCenter importer will divide rvmomi resources
    # in this group, makes parsing easier.
    module VOBJECT
        DATASTORE  = 1
        TEMPLATE   = 2
        NETWORK    = 3
        IMAGE      = 4
        HOST       = 5
        VM         = 6
        DATACENTER = 7
        CLUSTER    = 8
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
        VOBJECT::DATASTORE => {
            :struct  => ['DATASTORE_LIST', 'DATASTORE'],
            :columns =>
                { :IMID => 5, :REF => 15, :NAME => 50, :CLUSTERS => 10 },
            :cli     => [:host],
            :dialogue => ->(arg) {}
        },
        VOBJECT::TEMPLATE => {
            :struct  => ['TEMPLATE_LIST', 'TEMPLATE'],
            :columns => { :IMID => 5, :REF => 10, :NAME => 50 },
            :cli     => [:host],
            :dialogue => ->(arg) { OneVcenterHelper.template_dialogue(arg) }
        },
        VOBJECT::NETWORK => {
            :struct  => ['NETWORK_LIST', 'NETWORK'],
            :columns => {
                :IMID => 5,
                :REF => 15,
                :NAME => 30,
                :CLUSTERS => 20
            },
            :cli     => [:host],
            :dialogue => ->(arg) { OneVcenterHelper.network_dialogue(arg) }
        },
        VOBJECT::IMAGE => {
            :struct  => ['IMAGE_LIST', 'IMAGE'],
            :columns => { :IMID => 5, :REF => 35, :PATH => 60 },
            :cli     => [:host, :datastore],
            :dialogue => ->(arg) {}
        },
        VOBJECT::HOST => {
            :struct  => ['HOST_LIST', 'HOST'],
            :columns => { :NAME => 30, :DATACENTER => 15, :CLUSTERS => 15, :REF => 35 },
            :cli     => [],
            :dialogue => ->(arg) {}
        },
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
            :port     => options[:port]
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
            str_error="Unable to read '#{path}'. Invalid YAML syntax:\n"

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
    
    def cleanup_directories(passwords=false, disks=false)
        if passwords
            puts "Deleting password files."
            File.delete("#{@options[:work_dir]}/vpassfile")
            File.delete("#{@options[:work_dir]}/esxpassfile")
        end
        if @options[:delete] && disks
            puts "Deleting vdisks in #{"#{@options[:work_dir]}/conversions/"}"
            # FileUtils.rm_rf("#{@options[:work_dir]}/conversions/")
        else
            puts "NOT deleting vdisks in #{"#{@options[:work_dir]}/conversions/"}"
        end
    end

    # Translate vCenter Definition to OpenNebula Template
    def translate_template(disks)
        vmt = OpenNebula::Template.new(OpenNebula::Template.build_xml, @client)
        vmt.add_element('//VMTEMPLATE', {
            "NAME" => "#{@props['name']}",
            "CPU"  => "#{@props['config'][:hardware][:numCPU]}",
            "vCPU" => "#{@props['config'][:hardware][:numCPU]}",
            "MEMORY" => "#{@props['config'][:hardware][:memoryMB]}",
            "HYPERVISOR" => "kvm",
            "CONTEXT" => {
                "NETWORK" => "YES",
                "SSH_PUBLIC_KEY" => "$USER[SSH_PUBLIC_KEY]"
            }
        })

        # Default to BIOS if UEFI is not defined.
        fw = { "OS" => { "FIRMWARE" => "BIOS" }}
        if @props['config'][:firmware] == 'efi'
            if @props['config'][:bootOptions][:efiSecureBootEnabled]
                fw['OS']['FIRMWARE'] = '/usr/share/OVMF/OVMF_CODE.secboot.fd'
                fw['OS']['FIRMWARE_SECURE'] = 'YES'
            else
                fw['OS']['FIRMWARE'] = '/usr/share/OVMF/OVMF_CODE.fd'
            end
        end

        vmt.add_element('//VMTEMPLATE', fw)

        if @props['config'][:annotation] && !@props['config'][:annotation].empty?
            notes = @props['config'][:annotation]
                    .gsub('\\', '\\\\')
                    .gsub('"', '\\"')
            vmt.add_element('//VMTEMPLATE', { "DESCRIPTION" => "#{notes}" })
        end

        # Add disks here
        disks.each do |d|
            vmt.add_element('//VMTEMPLATE', {"DISK" => { "IMAGE_ID" => "#{d}" }})
        end

        logo = nil
        case @props['guest.guestFullName']
        when /CentOS/i
            logo = 'images/logos/centos.png'
        when /Debian/i
            logo = 'images/logos/debian.png'
        when /Red Hat/i
            logo = 'images/logos/redhat.png'
        when /Ubuntu/i
            logo = 'images/logos/ubuntu.png'
        when /Windows XP/i
            logo = 'images/logos/windowsxp.png'
        when /Windows/i
            logo = 'images/logos/windows8.png'
        when /Linux/i
            logo = 'images/logos/linux.png'
        end
        vmt.add_element('//VMTEMPLATE', {'LOGO' => logo}) if logo

        vmt
    end

    def ip_version(ip_address)
        ip = IPAddr.new(ip_address) rescue nil
        if ip
            return 'IP4' if ip.ipv4?
            return 'IP6' if ip.ipv6?
        else
            return nil
        end
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

    def run_cmd_report(cmd, out=false)
        t0 = Time.now
        stdout, _stderr, status = nil
        show_wait_spinner {
            stdout, _stderr, status = Open3.capture3(cmd)
        }
        t1 = (Time.now - t0).round(2)
        puts !status.success? ? "Failed (#{t1}s)".red : "Success (#{t1}s)".green
        if !status.success?
            puts "STDERR:".red
            puts _stderr
            puts "-------".red
        end
        return stdout if out
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
            c_files = Dir.glob("#{@options[:context_path]}/one-context*el8*rpm")
        when 'rhel9'
            c_files = Dir.glob("#{@options[:context_path]}/one-context*el9*rpm")
        when 'debian'
            c_files = Dir.glob("#{@options[:context_path]}/one-context*deb")
        when 'alpine'
            c_files = Dir.glob("#{@options[:context_path]}/one-context*apk")
        when 'alt'
            c_files = Dir.glob("#{@options[:context_path]}/one-context*alt*rpm")
        when 'opensuse'
            c_files = Dir.glob("#{@options[:context_path]}/one-context*suse*rpm")
        when 'freebsd'
            c_files = Dir.glob("#{@options[:context_path]}/one-context*txz")
        when 'windows'
            c_files = Dir.glob("#{@options[:context_path]}/one-context*msi")
        end

        if c_files.length == 1
            c_files[0]
        else
            latest = c_files.max_by { |f| Gem::Version.new(f.match(/(\d+\.\d+\.\d+)\.msi$/)[1])}
            latest
        end
    end

    def context_command(disk, osinfo)
        cmd = nil
        if osinfo['name'] == 'windows'
            return false
        else
            # os gives versions, so check that instead of distro
            if osinfo['os'].start_with?('redhat-based')
                if osinfo['os'].start_with?('redhat-based8')
                    context_fullpath = detect_context_package('rhel8')
                elsif osinfo['os'].start_with?('redhat-based9')
                    context_fullpath = detect_context_package('rhel9')
                end
                context_basename = File.basename(context_fullpath)
                cmd = 'virt-customize -q'\
                      " -a #{disk}"\
                      ' --install epel-release'\
                      " --copy-in #{context_fullpath}:/tmp"\
                      " --install /tmp/#{context_basename}"\
                      " --delete /tmp/#{context_basename}"\
                      " --run-command 'systemctl enable network.service'"
            end
            if osinfo['os'].start_with?('ubuntu') || osinfo['os'].start_with?('debian')
                context_fullpath = detect_context_package('debian')
                context_basename = File.basename(context_fullpath)
                cmd = 'virt-customize -q'\
                      " -a #{disk}"\
                      ' --uninstall cloud-init'\
                      " --copy-in #{context_fullpath}:/tmp"\
                      " --install /tmp/#{context_basename}"\
                      " --delete /tmp/#{context_basename}"\
                      " --run-command 'systemctl enable network.service'"
            end
            if osinfo['os'].start_with?('alt')
                context_fullpath = detect_context_package('alt')
                context_basename = File.basename(context_fullpath)
                cmd = 'virt-customize -q'\
                      " -a #{disk}"\
                      " --copy-in #{context_fullpath}:/tmp"\
                      " --install /tmp/#{context_basename}"\
                      " --delete /tmp/#{context_basename}"
            end
            if osinfo['os'].start_with?('opensuse')
                context_fullpath = detect_context_package('freebsd')
                context_basename = File.basename(context_fullpath)
                cmd = 'virt-customize -q'\
                      " -a #{disk}"\
                      " --copy-in #{context_fullpath}:/tmp"\
                      " --install /tmp/#{context_basename}"\
                      " --delete /tmp/#{context_basename}"
            end
            if osinfo['os'].start_with?('freebsd')
                # may not mount properly sometimes due to internal fs
                context_fullpath = detect_context_package('freebsd')
                context_basename = File.basename(context_fullpath)
                cmd = 'virt-customize -q'\
                      " -a #{disk}"\
                      ' --install curl,bash,sudo,base64,ruby,open-vm-tools-nox11'\
                      " --copy-in #{context_fullpath}:/tmp"\
                      " --install /tmp/#{context_basename}"\
                      " --delete /tmp/#{context_basename}"
            end
            if osinfo['os'].start_with?('alpine')
                puts 'Alpine is not compatible with offline install, please install context manually.'.brown
            end
        end
        cmd
    end

    def get_win_controlset(disk)
        cmd = 'virt-win-reg'\
              " #{disk}"\
              " 'HKLM\\SYSTEM\\Select'"
        print 'Checking Windows ControlSet...'
        stdout = run_cmd_report(cmd, out=true)
        ccs = stdout.split("\n").find { |s| s.start_with?('"Current"') }.split(':')[1].to_i
        ccs
    end

    def win_context_inject(disk, osinfo)
        cmd = "guestfish <<_EOF_
add #{disk}
run
mount #{osinfo['mounts']['/']} /
upload #{@options[:virt_tools]}/rhsrvany.exe /rhsrvany.exe
upload #{detect_context_package('windows')} /one-context.msi
_EOF_"
        print "Uploading context files to Windows disk..."
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
        cmd
    end

    def qemu_ga_command(disk)
        cmd = 'virt-customize'\
              " -a #{disk}"\
              " --inject-qemu-ga #{@options[:virtio_path]}"
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
        _stdout, _stderr, status = Open3.capture3(cmd)
    end

    def package_injection(disk, osinfo)
        puts "Injecting/installing packages"

        injector_cmd = context_command(disk, osinfo)
        if !injector_cmd
            if osinfo['name'] == 'windows'
                win_context_inject(disk, osinfo)
            else
                puts 'Unsupported guest OS for context injection.'
            end
        else
            print 'Injecting one-context...'
            run_cmd_report(injector_cmd)
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

    # Get objects 
    def get_objects(vi_client, type, properties, folder = nil)
        vim = vi_client.vim
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
            host    = pobj if pobj.class == RbVmomi::VIM::HostSystem
            cluster = pobj if pobj.class == RbVmomi::VIM::ClusterComputeResource
            dc      = pobj if pobj.class == RbVmomi::VIM::Datacenter
            pobj = pobj[:parent]
            if pobj.nil?
                raise "Unable to find Host, Cluster, and Datacenter of VM"
            end
        end

        v2v_path = 'virt-v2v' # gather this information eventually
        url = "vpx://#{CGI::escape(@options[:vuser])}@#{@options[:vcenter]}"\
              "/#{dc[:name]}/#{cluster[:name]}/#{host[:name]}?no_verify=1"
        command = "#{v2v_path} -v --machine-readable"\
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

        v2v_path = 'virt-v2v'
        url = "ssh://#{CGI::escape(@options[:esxi_user])}@#{@options[:esxi_ip]}"\
              "/#{vmx_fullpath}"
        command = "#{v2v_path} -v --machine-readable"\
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
        pobj = props['runtime.host']
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
        response = ssl_client.read
        
        ssl_client.sysclose
        tcp_client.close
        
        cert = ssl_client.peer_cert
        @options[:vddk_thumb] = OpenSSL::Digest::SHA1.new(cert.to_der).to_s.scan(/../).join(':')
        
        puts "Certificate thumbprint: #{@options[:vddk_thumb]}"

        v2v_path = 'virt-v2v' # gather this information eventually
        url = "vpx://#{CGI::escape(@options[:vuser])}@#{@options[:vcenter]}"\
              "/#{dc[:name]}/#{cluster[:name]}/#{host[:name]}?no_verify=1"
        command = "#{v2v_path} -v --machine-readable"\
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

    # Create and run the virt-v2v conversion
    # This uses virt-v2v to connect to vCenter/ESXi, create an overlay on the remote disk,
    #   and convert it before using qemu-img convert over nbdkit connection.  Outputs a
    #   converted qcow2/raw image and libvirt compatible xml definition.
    def run_v2v_conversion
        if @options[:esxi_ip]
            command = build_v2v_esx_cmd
        elsif @options[:vddk_path]
            command = build_v2v_vddk_cmd
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

            disks_on_file = Dir.glob("#{@options[:work_dir]}/conversions/#{@options[:name]}*").sort
            puts "#{disks_on_file.length} disks on the local disk for this VM: #{disks_on_file.to_s}"
            if disks_on_file.length == 0
                raise "There are no disks on the local filesystem due to previous failures."
            end
    
            img_ids = create_one_images(disks_on_file)
            img_ids
        rescue StandardError => e
            # puts "Error raised: #{e.message}"
            if @options[:fallback] && !@props['config'][:guestFullName].include?('Windows')
                puts "Error encountered, fallback enabled. Attempting Custom Conversion now."
                cleanup_directories(passwords=false, disks=true)
                run_custom_conversion
            else
                if @props['config'][:guestFullName].include?('Windows')
                    puts 'Windows not supported for fallback conversion.'.brown
                else
                    puts "Failed. Fallback is not enabled. Raising error.".red
                end
                raise e
            end
        end
    end

    def handle_v2v_error(line)
        LOGGER[:stderr].puts(line)
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
        err ? raise(err[:error].red)  : raise("Unknown error occurred: #{line['message']}".bg_red)
    end

    def handle_stdout(line)
        LOGGER[:stdout].puts(line) if DEBUG
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
            end
        when 'info'
            print line['message']
        when 'progress'
            print line['message'].bg_green
        else
            print "#{line}".bg_cyan
        end
    end

    def handle_stderr(line)
        return if line.start_with?('nbdkit: debug:')
        prefixes = [
            'guestfsd: <= list_filesystems',
            'guestfsd: <= inspect_os',
            'mpstats:',
            'commandrvg: /usr/sbin/update-initramfs'
        ]

        case prefixes.detect { |e| line.start_with?(e) }
        when prefixes[0]
            print "\n"
            STDOUT.flush
            print "Inspecting filesystems".green
        when prefixes[1]
            print "\n"
            STDOUT.flush
            print "Inspecting guest OS".green
        when prefixes[2]
            print "\n"
            STDOUT.flush
            print "Gathering mountpoint stats".green
        when prefixes[3]
            print "\n"
            STDOUT.flush
            print "Generating initramfs, this can take several minutes(20+) on many systems. Please be patient and do not interrupt the process.".brown
        else
            print '.'
            LOGGER[:stderr].puts(line) if DEBUG
        end
    end

    def create_one_images(disks)
        puts 'Creating Images in OpenNebula'
        img_ids = []
        disks.each_with_index do |d, i|
            img = OpenNebula::Image.new(OpenNebula::Image.build_xml, @client)
            guest_info = detect_distro(d)
            if guest_info
                package_injection(d, guest_info)
            end
            img.add_element('//IMAGE', {
                    'NAME' => "#{@options[:name]}_#{i}",
                    'TYPE' => guest_info ? 'OS' : 'DATABLOCK',
                    'PATH' => "#{d}"
                })
            rc = img.allocate(img.to_xml, @options[:datastore])
            if rc.class == OpenNebula::Error
                puts 'Failed to create image. Image Definition:'.red
                puts img.to_xml
            end
            img_ids.append(img.id)
        end
        img_ids
    end

    def run_custom_conversion
        # Things that need to happen in this function:
        # Copy the disk(s) over here from the properties data, keep them in order
        # Convert the disk(s) to QCOW2 or RAW format (in options)
        # Install virtio drivers and one context, anything else required
        #   using guestfish
        vc_disks = @props['config'][:hardware][:device].grep(RbVmomi::VIM::VirtualDisk).sort_by(&:key)
        disk_n = 0
        local_disks = []
        puts 'Downloading disks from vCenter storage to local disk'
        vc_disks.each_with_index do |d, i|
            # download each disk to the work dir
            remote_file = d[:backing][:fileName].split(' ')[1].gsub(/\.vmdk$/, '-flat.vmdk')
            local_file = @options[:work_dir] + '/conversions/' + @props['name'] + "-disk#{disk_n}"
            d[:backing][:datastore].download(remote_file, local_file + '.vmdk')

            puts "Downloaded disk ##{i}. Converting. This may take a long time for larger disks."
            # -p to show Progress, -S 4k to set Sparse Cluster Size to 4kb, -W for out of order writes
            t0 = Time.now
            command = 'qemu-img convert'\
                      " -O #{@options[:format]}"\
                      ' -p -S 4k -W'\
                      " #{local_file}.vmdk #{local_file}.#{@options[:format]}"
            system(command) # don't need to interact or anything, just display the output straight.
            puts "Disk #{i} converted in #{(Time.now - t0).round(2)} seconds. Deleting vmdk file".green
            puts "that's a lie, not deleting the vmdk".bg_blue
            # command = "rm -f #{local_file}.vmdk"
            # system(command)
            local_disks.append("#{local_file}.#{@options[:format]}")
        end

        create_one_images(local_disks)
    end

    def add_one_nics(vm_template)
        network_types = [
            RbVmomi::VIM::VirtualVmxnet,
            RbVmomi::VIM::VirtualVmxnet2,
            RbVmomi::VIM::VirtualVmxnet3
        ]
        vc_nets = @props['config'][:hardware][:device].select { |d|
            network_types.any? { |nt| d.is_a?(nt) }
        }.sort_by(&:key)

        netmap = {}
        one_networks = OpenNebula::VirtualNetworkPool.new(@client)
        one_networks.info
        one_networks.each do |n|
            n.info
            next if !n['//VNET/TEMPLATE/VCENTER_NETWORK_MATCH']
            netmap[n['//VNET/TEMPLATE/VCENTER_NETWORK_MATCH']] = n['//VNET/ID']
        end
        # puts netmap

        if @options[:network] && vc_nets.length > 0
            # Change this to check existing ONE vnets for VCENTER_NETWORK_MATCH attribute instead, per network.
            puts "Adding #{vc_nets.length} NICs, defaulting to Network ID #{@options[:network]} if there is no match"
            nic_number=0
            vc_nets.each do |n|
                # find nic with same device key
                guest_network = @props['guest.net'].find { |gn| gn[:deviceConfigId] == n[:key] }
                net_templ = {'NIC' => {
                    'NETWORK_ID'  => "#{@options[:network]}"
                }}

                if !@options[:skip_mac]
                    net_templ['NIC']['MAC'] = n[:macAddress]
                end

                if !netmap.has_key?(n[:backing][:network][:name])
                    net_templ['NIC']['NETWORK_ID'] = "#{netmap[n[:backing][:network][:name]]}"
                end

                if !guest_network
                    # no guest network information, but still have networks...
                    puts "Found network '#{n[:backing][:network][:name]}' but no guest network information. Adding blank NIC."
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
                        if !netmap.has_key?(guest_network[:network])
                            puts "Missing VCENTER_NETWORK_MATCH attribute in OpenNebula network(s).  Unable to correlate all networks."
                            puts "Defaulting to provided ID: #{@options[:network]}"
                            net_templ[netkey]['NETWORK_ID'] = "#{@options[:network]}"
                        else
                            net_templ[netkey]['NETWORK_ID'] = "#{netmap[guest_network[:network]]}"
                        end
                        # create single IP in an address range of OpenNebula network for each IP on the NIC
                        if ip[:ipAddress]
                            ipv = "#{ip_version(ip[:ipAddress])}"
                        else
                            puts "Skipping address range creation"
                            next
                        end
                        if netkey =='NETWORK_ALIAS'
                            net_templ[netkey]['PARENT'] = "NIC#{nic_number}"
                        end
                        ar_template = "AR=[TYPE=#{ipv},SIZE=1,IP=#{ip[:ipAddress]}]"
                        print "Creating AR for IP #{ip[:ipAddress]}..."
                        xml = OpenNebula::VirtualNetwork.build_xml(net_templ[netkey]['ID'])
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
                
                #vm_template.add_element('//VMTEMPLATE', net_templ)
            end
        elsif vc_nets.length > 0
            puts "You will need to create NICs and assign networks in the VM Template in OpenNebula manually."
        end
        vm_template
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
        else
            list_vms(options)
        end
    end

    # General wrapper to fix options and handle fatal errors
    #
    # @param name    [Hash] Object Name
    # @param options [Hash] User CLI options
    def convert(name, options)
        if !Dir.exist?(options[:work_dir])
            raise 'Provided working directory '\
                  "#{options[:work_dir]} doesn't exist"
        end
        options[:name] = name
        @options = options
        conv_path = "#{@options[:work_dir]}/conversions/"
        begin
            Dir.mkdir(conv_path) if !Dir.exist?(conv_path)

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
            cleanup_directories(passwords=true, disks=true)
        end
    end

    # List all vms
    #
    # @param options [Hash] User CLI options
    def list_vms(options)
        con_ops   = connection_options('vms', options)
        vi_client = VCenterDriver::VIClient.new(con_ops)
        properties = [
            'name',
            'config.template',
            'config.uuid',
            'summary.runtime.powerState',
            'runtime.host',
            'config.hardware.numCPU',
            'config.hardware.memoryMB'
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
            filters = options.select { |key,value| available_filters.include?(key) }
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
        vi_client = VCenterDriver::VIClient.new(con_ops)

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
        vi_client = VCenterDriver::VIClient.new(con_ops)

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

    # Show VM
    #
    # @param options [Hash] User CLI Options
    def convert_vm
        con_ops = connection_options('vm', @options)
        vi_client = VCenterDriver::VIClient.new(con_ops)
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

        if @props['summary.runtime.powerState'] != 'poweredOff'
            raise "Virtual Machine #{@options[:name]} is not Powered Off.".red
        end

        if !@props['snapshot'].nil?
            raise "Virtual Machine #{@options[:name]} cannot have existing snapshots.".red
        end

        if @props['config'][:guestFullName].include?('Windows') && @options[:custom_convert]
            raise "Windows is not supported in OpenNebula's Custom Conversion process".red
        end

        img_ids = @options[:custom_convert] ? run_custom_conversion : run_v2v_conversion

        puts img_ids.nil? ? "No Images ID's reported being created".red : "Created images: #{img_ids}".green

        vm_template = translate_template(img_ids)
        vm_template = add_one_nics(vm_template)

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
