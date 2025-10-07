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

def live_execution(cmd)
    status = nil
    Open3.popen3(cmd) do |stdin, stdout, stderr, wait_thr|
        stdin.close

        threads = []
        threads << Thread.new { stdout.each_line {|line| puts line } }
        threads << Thread.new { stderr.each_line {|line| STDERR.puts line } }

        threads.each(&:join)
        status = wait_thr.value.success?
    end

    status
end

vm = conf[:vm]
cmd = "oneswap convert #{vm} --delta"

live_execution(cmd)
