#!/usr/bin/env ruby

require 'yaml'
require_relative '../esxi_client'
require_relative '../esxi_vm'

conf = YAML.load_file('conf.yaml')

log_output = conf[:log][:output]
log_output = eval(log_output) if log_output[0] == '$'
logger = Logger.new(log_output)
logger.level = Logger.const_get(conf[:log][:level])

############################################

client = ESXi::Client.new(conf[:esxi_host], logger)

vm = client.get_vm_by_name(conf[:vm])
vm.running?
vm.list_active_disks
vm.disks_chains

# vm.start
# vm.create_snapshot
# vm.disable_autostart
# vm.shutdown
