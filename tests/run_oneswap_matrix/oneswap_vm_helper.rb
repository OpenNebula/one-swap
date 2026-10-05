#!/usr/bin/env ruby

ONE_LOCATION = ENV['ONE_LOCATION']
ruby_lib = ONE_LOCATION ? "#{ONE_LOCATION}/lib/ruby" : '/usr/lib/one/ruby'
gems = ONE_LOCATION ? "#{ONE_LOCATION}/share/gems" : '/usr/share/one/gems'

if File.directory?(gems)
  # Keep Ruby's startup RubyGems on the load path to avoid loading a second copy.
  require 'rubygems'
  Gem.use_paths(File.realpath(gems))
end

$LOAD_PATH.concat([ruby_lib, "#{ruby_lib}/cli"])

require 'command_parser'
require 'rbvmomi'
require 'one_helper/oneswap_helper'
require 'optparse'
require 'yaml'
require 'timeout'

vim = nil

begin
  config_file = '/etc/one/oneswap.yaml'
  timestamp_file = nil
  wait_timeout = 3600

  parser = OptionParser.new do |opts|
    opts.banner =
      'Usage: oneswap_vm_helper.rb COMMAND VM_NAME --config-file PATH'

    opts.on('--timestamp-file PATH') { |path| timestamp_file = path }
    opts.on('--timeout SECONDS', Integer) { |seconds| wait_timeout = seconds }

    opts.on('--config-file PATH') do |path|
      config_file = path
    end
  end

  parser.parse!(ARGV)

  raise parser.banner unless ARGV.length == 2

  command = ARGV.fetch(0)
  name    = ARGV.fetch(1)

  raise 'Timeout must be positive' unless wait_timeout.positive?
  if command == 'wait-powered-off' && timestamp_file.to_s.empty?
    raise '--timestamp-file is required for wait-powered-off'
  end

  config = YAML.safe_load(
    File.read(config_file),
    permitted_classes: [Symbol],
    aliases: true
  )

  raise 'Config must be a YAML mapping' unless config.is_a?(Hash)

  config = config.transform_keys do |key|
    key.to_s.sub(/^:/, '').to_sym
  end

  [:vcenter, :vuser, :vpass].each do |key|
    raise "Missing config setting: #{key}" if config[key].to_s.empty?
  end

  helper = OneSwapHelper.new

  Timeout.timeout(command == 'wait-powered-off' ? wait_timeout : 120) do
    vim = RbVmomi::VIM.connect(
      helper.connection_options('vm', config)
    )

    matches = helper
              .get_objects(vim, 'VirtualMachine', ['name'])
              .select { |entry| entry['name'] == name }

    raise "VM not found: #{name}" if matches.empty?

    if matches.length != 1
      raise "Ambiguous VM name: #{name}"
    end

    vm = matches.first.obj

    case command
    when 'state'
      state = vm.runtime.powerState
      puts "#{name}: #{state}"

    when 'power-on'
      state = vm.runtime.powerState

      case state
      when 'poweredOff'
        puts "#{name}: powering on"
        vm.PowerOnVM_Task.wait_for_completion

      when 'poweredOn'
        puts "#{name}: already poweredOn"

      else
        raise "Refusing to start VM in state #{state.inspect}"
      end

      sleep 1 until vm.runtime.powerState == 'poweredOn'

      puts "#{name}: poweredOn"

    when 'wait-tools-ready'
      loop do
        guest = vm.guest
        if vm.runtime.powerState == 'poweredOn' &&
           guest.toolsStatus == 'toolsOk' &&
           guest.toolsRunningStatus == 'guestToolsRunning'
          puts "#{name}: poweredOn, toolsOk, guestToolsRunning"
          break
        end
        sleep 1
      end

    when 'wait-powered-off'
      loop do
        if vm.runtime.powerState == 'poweredOff'
          observed_at = Time.now.to_i
          File.write(timestamp_file, "#{observed_at}\n")
          puts "#{name}: poweredOff at #{observed_at}"
          break
        end
        sleep 1
      end

    when 'snapshots'
      snapshot_info = vm.snapshot

      if snapshot_info.nil?
        puts "#{name}: no snapshots"
      else
        warn "ERROR: #{name} has existing VMware snapshots:"

        walk = lambda do |nodes, depth = 0|
          nodes.each do |node|
            warn "  #{'  ' * depth}- #{node.name}"

            walk.call(
              node.childSnapshotList || [],
              depth + 1
            )
          end
        end

        walk.call(snapshot_info.rootSnapshotList || [])

        exit 2
      end

    else
      raise "Unknown command: #{command}"
    end
  end

rescue StandardError => e
  warn "VM helper failed: #{e.class}: #{e.message}"
  exit 1

ensure
  begin
    Timeout.timeout(10) { vim.close } if vim
  rescue StandardError => e
    warn "Warning: failed to close vCenter connection: #{e.message}"
  end
end
