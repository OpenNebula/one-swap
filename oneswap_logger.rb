# -------------------------------------------------------------------------- #
# Copyright 2002-2026, OpenNebula Project, OpenNebula Systems                #
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

require 'logger'

# Logging helpers for oneswap.

module OneSwapLogger

    class MultiIO

        def initialize(*targets)
            @targets = targets
        end

        def write(*args)
            errors = []
            @targets.each do |t|
                begin
                    t.write(*args)
                rescue StandardError => e
                    errors << e
                end
            end

            raise errors.first if errors.any? && errors.size == @targets.size
        end

        def close
            @targets.each do |t|
                next if [$stdout, $stderr, STDOUT, STDERR].any? {|s| t.equal?(s) }

                t.close
            end
        end

    end

    # Resolve whether verbose/diagnostic logging should be enabled.
    #
    # Verbose mode can be requested through any of three equivalent channels:
    #   * the -v/--verbose CLI flag, and
    #   * a ":verbose: true" entry in oneswap.yaml
    #     (both end up in options[:verbose] after the config file is merged), or
    #   * the ONE_SWAP_DEBUG environment variable (any value, even "").
    #
    # @param options [Hash] CLI options, already merged with the config file
    # @param env     [Hash] environment (injectable for tests)
    # @return [Boolean]
    def self.verbose?(options, env = ENV)
        !!(options[:verbose] || !env['ONE_SWAP_DEBUG'].nil?)
    end

    # Build a Logger for oneswap.
    #
    # In verbose mode it logs at DEBUG and echoes every line to the terminal
    # (STDERR) in addition to the log file
    #
    # @param log_file [IO]      open, writable log file device
    # @param verbose  [Boolean] whether verbose/debug logging is enabled
    # @param stderr   [IO]      terminal stream for the verbose echo
    #                           (injectable so it can be exercised in tests)
    # @return [Logger]
    def self.build(log_file, verbose:, stderr: STDERR)
        device = verbose ? MultiIO.new(log_file, stderr) : log_file

        logger = Logger.new(device)
        logger.level = verbose ? Logger::DEBUG : Logger::INFO
        logger
    end

end
