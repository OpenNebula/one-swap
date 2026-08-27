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

require 'json'
require 'logger'
require 'net/http'
require 'openssl'
require 'uri'

# NetApp Shift Toolkit client for OneSwap.
#
# Talks to the Shift appliance REST API directly. The endpoints, ports and
# payloads mirror NetApp's own shift-api-automation Python modules.
#
# Services live on three ports:
#
#   3698  tenant sessions
#   3700  setup      -- sites, resource groups, blueprints, compliance
#   3704  recovery   -- executions and job steps
#
# The division of labour with the Shift UI is deliberate: an operator creates
# the source site, destination site, resource group(s) and blueprint by hand,
# which is how they choose which wave of VMs moves when. OneSwap only runs a
# blueprint and imports what comes out, and never writes to the setup side.
#
#   shift = NetAppShift::Helper.new(
#       :server   => 'https://10.0.0.5',
#       :username => 'admin',
#       :password => 'secret',
#       :logger   => @logger
#   )
#
#   shift.blueprint_vm_names('bp1')       # => ['web01', 'db01']
#   shift.run_compliance_check('bp1')
#   id = shift.trigger_conversion('bp1')  # raises AlreadyExecuted if it ran
#   shift.wait_for_completion('bp1', id)
#   shift.converted_disks('web01', '/mnt/shift', 2)
#   # => ['/mnt/shift/web01.qcow2', '/mnt/shift/web01_1.qcow2']
#
module NetAppShift

    class Error < StandardError; end

    # The appliance rejected a request, or answered in a shape we cannot use.
    class OperationError < Error

        attr_reader :code, :http_status

        # message is optional so `raise NetAppShift::AlreadyExecuted` works
        # like any other exception class.
        def initialize(message = nil, code: nil, http_status: nil)
            super(message)
            @code        = code
            @http_status = http_status
        end

    end

    # Shift refuses to execute a blueprint that already converted
    # successfully. For OneSwap that is a no-op rather than a failure: the
    # disks it wants are already on the datastore. Clearing the previous
    # execution is a Shift UI action (NetApp ship removeBpJobs.ps1 for it);
    # OneSwap stays read-only against that API.
    class AlreadyExecuted < OperationError; end

    # Shift refuses to convert while any VM in the blueprint is running,
    # unless the caller opts in to a point-in-time snapshot of the live VM.
    # Carries the names the appliance reported so the caller can act on them.
    class PoweredOnVms < OperationError

        attr_reader :vm_names

        def initialize(message = nil, code: nil, http_status: nil, vm_names: [])
            super(message, :code => code, :http_status => http_status)
            @vm_names = vm_names
        end

    end

    class Helper

        SESSION_PORT  = 3698
        SETUP_PORT    = 3700
        RECOVERY_PORT = 3704

        # The only execution type OneSwap uses. Shift also offers "migrate",
        # which builds a VM on the destination hypervisor -- not possible here,
        # because the destination is a qcow2 on an NFS export rather than a
        # hypervisor Shift can drive.
        CONVERSION = 'convert'.freeze

        # Terminal states, shared by job steps and executions. Everything else
        # means still pending or running.
        STATE_SUCCESS = 4
        STATE_FAILED  = 5

        # API paths. Collected here because the appliance is inconsistent
        # about casing -- the status collection is "drplan", the per-plan
        # execution path is "drPlan". Both are verified against a live
        # appliance; neither is a typo to be "corrected".
        PATH_SITES            = '/api/setup/site'.freeze
        PATH_BLUEPRINTS       = '/api/setup/drplan'.freeze
        PATH_RESOURCE_GROUPS  = '/api/setup/protectionGroup'.freeze
        PATH_BLUEPRINT_STATUS = '/api/recovery/drplan/status'.freeze

        def self.path_compliance_request(blueprint_id)
            "/api/setup/compliance/drplan/#{blueprint_id}/checkrequest?async=true"
        end

        # The task id goes in both the path and the query string; that is what
        # the appliance expects, odd as it reads.
        def self.path_compliance_status(task_id)
            "/api/setup/compliance/drplan/#{task_id}/checkrequest?taskId=#{task_id}"
        end

        def self.path_execution(blueprint_id, mode)
            "/api/recovery/drPlan/#{blueprint_id}/#{mode}/execution"
        end

        def self.path_execution_steps(execution_id)
            "/api/recovery/execution/#{execution_id}/steps"
        end

        # Returned when a blueprint has already been executed successfully.
        ERR_ALREADY_EXECUTED = 'ERSCSTEX009'.freeze

        # Returned when a VM in the blueprint is still running. Overridable
        # with the ignorePoweredOnVms flag, which is what the Shift UI sends
        # when its "Continue" prompt is accepted.
        ERR_VMS_POWERED_ON = 'ERSCSTEX022'.freeze

        DEFAULTS = {
            # Per-request socket timeouts.
            :http_timeout             => 30,
            # Requesting and polling a compliance check are both slow calls.
            :compliance_timeout       => 300,
            # A freshly created blueprint needs a moment before it will pass a
            # compliance check.
            :compliance_settle        => 20,
            :compliance_poll_interval => 5,
            :compliance_poll_limit    => 24,
            # How often to re-check a running execution.
            :status_poll_interval     => 30
        }.freeze

        attr_reader :logger, :server

        # @param options [Hash]
        # @option options :server   [String] appliance base URL, scheme and
        #   host only -- the service port is appended per call
        # @option options :username [String]
        # @option options :password [String]
        # @option options :logger   [Logger]
        # @option options :timeouts [Hash] overrides for DEFAULTS
        def initialize(options = {})
            @server   = normalize_server(options[:server])
            @username = options[:username].to_s
            @password = options[:password].to_s

            if @username.empty? || @password.empty?
                raise ArgumentError, 'Shift :username and :password are required'
            end

            @logger   = options[:logger] || self.class.stdout_logger
            @timeouts = DEFAULTS.merge(options[:timeouts] || {})
        end

        def self.stdout_logger
            logger = Logger.new(STDOUT)
            logger.level = Logger::INFO
            logger
        end

        # ------------------------------------------------------------------ #
        # Reads                                                               #
        # ------------------------------------------------------------------ #

        # Sites registered on the appliance. Cheap connectivity and credential
        # preflight.
        def sites
            api_session {|sid| api_list(sid, SETUP_PORT, PATH_SITES) }
        end

        # Blueprints registered on the appliance.
        def blueprints
            api_session {|sid| api_list(sid, SETUP_PORT, PATH_BLUEPRINTS) }
        end

        # VMs a blueprint covers, in resource-group order. This is what one
        # execution of it will convert.
        #
        # @return [Array<Hash>] :name, :id, :resource_group
        def blueprint_vms(blueprint_name)
            api_session do |sid|
                blueprint = find_blueprint(sid, blueprint_name)

                rg_ids = Array(blueprint['protectionGroups']).map {|rg| rg['_id'] }.compact
                groups = api_list(sid, SETUP_PORT, PATH_RESOURCE_GROUPS)
                         .select {|rg| rg_ids.include?(rg['_id']) }

                vms = groups.flat_map do |rg|
                    Array(rg['vms']).map do |vm|
                        # Logged so the fields the appliance actually returns
                        # can be surfaced as columns without guessing at them.
                        @logger.debug("NetApp Shift: blueprint VM -> #{vm.inspect}")

                        { :name           => vm['name'],
                          :id             => vm['_id'],
                          :resource_group => rg['name'] }
                    end
                end.reject {|vm| vm[:name].nil? }

                if vms.empty?
                    raise OperationError,
                          "Blueprint '#{blueprint_name}' has no VMs in its resource group(s)"
                end

                vms
            end
        end

        # Just the names, in the same order.
        #
        # @return [Array<String>]
        def blueprint_vm_names(blueprint_name)
            blueprint_vms(blueprint_name).map {|vm| vm[:name] }
        end

        # Every blueprint on the appliance with the resource groups and VMs it
        # covers, for choosing which one to run.
        #
        # @return [Array<Hash>] :name, :id, :resource_groups, :vms
        def blueprint_summaries
            api_session do |sid|
                by_id = api_list(sid, SETUP_PORT, PATH_RESOURCE_GROUPS)
                        .each_with_object({}) {|rg, acc| acc[rg['_id']] = rg }

                api_list(sid, SETUP_PORT, PATH_BLUEPRINTS).map do |bp|
                    groups = Array(bp['protectionGroups']).map {|rg| by_id[rg['_id']] }.compact

                    {
                        :name            => bp['name'],
                        :id              => bp['_id'],
                        :resource_groups => groups.map {|rg| rg['name'] }.compact,
                        :vms             => groups.flat_map do |rg|
                            Array(rg['vms']).map {|vm| vm['name'] }
                        end.compact
                    }
                end
            end
        end

        # Whether a blueprint has already run, is running, or failed -- nil if
        # it has never run or the appliance does not list it.
        #
        # Read from the blueprint's lastExecution, which carries a numeric
        # status and the execution type:
        #
        #   {"drPlan" => {"_id" => .., "name" => ..},
        #    "lastExecution" => {"_id" => .., "status" => 4, "type" => "convert"}}
        #
        # (NetApp's own client read a "recoveryStatus" string off drPlan
        # instead; appliances in the field do not return that field.)
        #
        # Still only an optimisation -- it saves a pointless compliance check
        # and trigger. The reliable signal that a blueprint cannot run again
        # is the AlreadyExecuted raised by #trigger_conversion.
        #
        # @return [Hash, nil] :status, :type, :execution_id, :complete, :failed, :running
        def blueprint_execution_state(blueprint_name)
            api_session do |sid|
                id       = find_blueprint(sid, blueprint_name)['_id']
                response = api_get(sid, RECOVERY_PORT, PATH_BLUEPRINT_STATUS)

                @logger.debug("NetApp Shift: drplan/status -> #{response.inspect}")

                entries = response.is_a?(Hash) ? Array(response['list']) : Array(response)
                entry   = entries.find do |e|
                    e.is_a?(Hash) && e.dig('drPlan', '_id') == id
                end

                if entry.nil?
                    @logger.debug("NetApp Shift: blueprint #{id} absent from drplan/status")
                    next nil
                end

                last = entry['lastExecution']

                if last.nil?
                    @logger.debug("NetApp Shift: blueprint #{id} has no lastExecution")
                    next nil
                end

                status = last['status']

                {
                    :status       => status,
                    :type         => last['type'],
                    :execution_id => last['_id'],
                    :complete     => status == STATE_SUCCESS,
                    :failed       => status == STATE_FAILED,
                    :running      => ![STATE_SUCCESS, STATE_FAILED].include?(status)
                }
            end
        end

        # Job steps of an execution. Each carries a 'description' and a
        # 'status' (see STATE_SUCCESS / STATE_FAILED).
        #
        # @return [Array<Hash>]
        def job_steps(execution_id)
            api_session do |sid|
                response = api_get(sid, RECOVERY_PORT,
                                   self.class.path_execution_steps(execution_id))

                Array(response['steps'])
            end
        end

        # Overall state of an execution, derived from its job steps. This is
        # keyed by execution id rather than blueprint, so unlike
        # #blueprint_execution_state it does not depend on the blueprint being
        # listed anywhere.
        #
        # @return [Symbol] :complete, :failed, :running or :unknown
        def execution_status(execution_id)
            classify_steps(job_steps(execution_id))
        end

        # Paths of the converted disks for a VM on the locally mounted source
        # NFS datastore, in disk order.
        #
        # Observed Shift naming (verified on hardware, single and multi-disk):
        # the first disk is "<vm-name>.qcow2" and each additional disk is
        # "<vm-name>_<n>.qcow2", all in the datastore root next to the VM's
        # folder. Disk order is assumed to follow the source device order.
        #
        # @param count [Integer] number of disks the VM has
        # @return [Array<String>] existing paths, first disk first
        # @raise [Error] naming every expected file that is missing
        def converted_disks(vm_name, mount, count)
            if count.to_i < 1
                raise ArgumentError, 'converted_disks requires a positive disk count'
            end

            expected = [File.join(mount.to_s, "#{vm_name}.qcow2")]
            (1...count.to_i).each do |i|
                expected << File.join(mount.to_s, "#{vm_name}_#{i}.qcow2")
            end

            missing = expected.reject {|path| File.file?(path) }

            unless missing.empty?
                raise Error,
                      "Converted disk(s) not found for '#{vm_name}': #{missing.join(', ')}. " \
                      'Verify the mount point and that the blueprint execution completed.'
            end

            expected
        end

        # ------------------------------------------------------------------ #
        # Actions                                                             #
        # ------------------------------------------------------------------ #

        # Request a compliance check for a blueprint and poll until it
        # succeeds.
        #
        # @return [Hash] :task_id and the appliance's :result payload
        # @raise [OperationError] if it fails or never settles
        def run_compliance_check(blueprint_name, settle: nil)
            settle = settle.nil? ? @timeouts[:compliance_settle].to_i : settle.to_i

            # A blueprint needs a moment to settle before it will pass a check.
            # Matches NetApp's own client; done before opening a session so one
            # is not held idle.
            if settle > 0
                @logger.info("NetApp Shift: letting blueprint '#{blueprint_name}' " \
                             "settle for #{settle}s before the compliance check")
                sleep settle
            end

            api_session do |sid|
                id = find_blueprint(sid, blueprint_name)['_id']

                started = api_post(sid, SETUP_PORT,
                                   self.class.path_compliance_request(id),
                                   :timeout => @timeouts[:compliance_timeout])

                task_id = started['taskId']

                if task_id.nil?
                    raise OperationError,
                          "Compliance check for '#{blueprint_name}' returned no task id"
                end

                @logger.info("NetApp Shift: compliance check task #{task_id}")

                poll_compliance(sid, task_id, blueprint_name)
            end
        end

        # Execute a blueprint. With CONVERSION this converts the disks only;
        # no VM is built on the target hypervisor.
        #
        # @param ignore_powered_on [Boolean] convert from a point-in-time
        #   snapshot even if VMs in the blueprint are running. This is the
        #   override behind the Shift UI's "Continue" prompt; the resulting
        #   image is crash-consistent, not quiesced.
        # @return [String] the execution id
        # @raise [AlreadyExecuted] if the blueprint has already converted
        # @raise [PoweredOnVms] if VMs are running and the override is off
        def trigger_conversion(blueprint_name, ignore_powered_on: false)
            api_session do |sid|
                id = find_blueprint(sid, blueprint_name)['_id']

                payload = {
                    'serviceAccounts' => {
                        'common' => { 'loginId' => nil, 'password' => nil },
                        'vms'    => []
                    }
                }

                # Only added when asked for, so the default request stays
                # byte-identical to the one already known to work.
                payload['ignorePoweredOnVms'] = true if ignore_powered_on

                response = api_post(sid, RECOVERY_PORT,
                                    self.class.path_execution(id, CONVERSION),
                                    :body => payload)

                execution_id = response['_id'] || deep_find(response, '_id')

                if execution_id.nil?
                    raise OperationError,
                          "Shift accepted the execution of '#{blueprint_name}' but " \
                          'returned no execution id'
                end

                execution_id
            end
        end

        # Block until an execution reaches a terminal state.
        #
        # Completion is read from the execution's own job steps, so this works
        # regardless of whether the blueprint shows up in the appliance's
        # blueprint status list. A fresh session is opened per poll so a long
        # conversion cannot outlive its session.
        #
        # @param timeout [Integer, nil] overall ceiling in seconds; nil or 0
        #   waits indefinitely (the caller decides how to surface Ctrl+C)
        # @return [Hash] :status and the final :steps
        def wait_for_completion(blueprint_name, execution_id, timeout: nil, interval: nil)
            interval = (interval || @timeouts[:status_poll_interval]).to_f
            deadline = Time.now + timeout.to_f if timeout && timeout.to_f > 0
            t0       = Time.now

            loop do
                steps = job_steps(execution_id)

                case classify_steps(steps)
                when :complete
                    return { :status => 'complete', :steps => steps }
                when :failed
                    failed = steps.select {|s| s['status'] == STATE_FAILED }
                                  .map {|s| s['description'] }.compact
                    raise OperationError,
                          "Shift execution #{execution_id} of '#{blueprint_name}' failed" \
                          "#{failed.empty? ? '' : " at: #{failed.join(', ')}"}"
                end

                waited = (Time.now - t0).round
                @logger.info("NetApp Shift: execution #{execution_id} still running " \
                             "after #{waited}s")

                if deadline && Time.now >= deadline
                    raise OperationError,
                          "Timed out after #{waited}s waiting for execution #{execution_id} " \
                          "of blueprint '#{blueprint_name}'"
                end

                sleep interval
            end
        end

        private

        # Every step succeeded / any step failed / still working / no steps yet.
        def classify_steps(steps)
            return :unknown if steps.empty?

            statuses = steps.map {|s| s['status'] }

            return :failed   if statuses.include?(STATE_FAILED)
            return :complete if statuses.all? {|s| s == STATE_SUCCESS }

            :running
        end

        def poll_compliance(session_id, task_id, blueprint_name)
            limit    = @timeouts[:compliance_poll_limit].to_i
            interval = @timeouts[:compliance_poll_interval].to_f

            limit.times do
                response = api_post(session_id, SETUP_PORT,
                                    self.class.path_compliance_status(task_id),
                                    :timeout => @timeouts[:compliance_timeout])

                status = response['status'].to_s

                if status == 'succeeded'
                    # The result carries the appliance's per-check findings.
                    # Logged rather than discarded so a check that "passed"
                    # but flagged something is still visible.
                    @logger.debug("NetApp Shift: compliance result -> #{response['result'].inspect}")

                    return { :task_id => task_id, :result => response['result'] }
                end

                if ['failed', 'error'].include?(status)
                    raise OperationError,
                          "Compliance check for '#{blueprint_name}' #{status}: " \
                          "#{response['result'].inspect}"
                end

                @logger.debug("NetApp Shift: compliance #{task_id} is #{status}")
                sleep interval
            end

            raise OperationError,
                  "Compliance check for '#{blueprint_name}' did not finish within " \
                  "#{(limit * interval).round}s"
        end

        def find_blueprint(session_id, blueprint_name)
            all       = api_list(session_id, SETUP_PORT, PATH_BLUEPRINTS)
            blueprint = all.find {|bp| bp['name'] == blueprint_name }

            if blueprint.nil?
                known = all.map {|bp| bp['name'] }.compact
                raise OperationError,
                      "Blueprint '#{blueprint_name}' not found on #{@server}. " \
                      "Available blueprints: #{known.empty? ? '(none)' : known.join(', ')}"
            end

            blueprint
        end

        # Shift's URI is built as "<server>:<port>/api/...", so the value has
        # to carry a scheme and nothing else.
        def normalize_server(server)
            value = server.to_s.strip.sub(%r{/+\z}, '')

            raise ArgumentError, 'Shift :server is required' if value.empty?

            value = "https://#{value}" unless value.match?(%r{\A\w+://})

            if value.match?(%r{\A\w+://[^/]+:\d+\z})
                raise ArgumentError,
                      "Shift :server must not include a port (#{value}); the service " \
                      'port is chosen per request'
            end

            value
        end

        # ---------------------------- transport --------------------------- #

        # Open a session, yield its id, end the session. Re-entrant: nested
        # calls reuse the open session rather than opening another.
        def api_session
            return yield(@session_id) if @session_id

            response = api_request(Net::HTTP::Post, SESSION_PORT, '/api/tenant/session',
                                   :body => { 'loginId' => @username,
                                              'password' => @password })

            sid = response.dig('session', '_id') || deep_find(response, '_id')

            raise OperationError, 'Shift session: no session id in response' if sid.nil?

            @session_id = sid

            begin
                yield sid
            ensure
                @session_id = nil
                begin
                    api_request(Net::HTTP::Post, SESSION_PORT, '/api/tenant/session/end',
                                :body => { 'sessionId' => sid }, :session => sid)
                rescue StandardError => e
                    @logger.warn("NetApp Shift: could not end session: #{e.message}")
                end
            end
        end

        def api_get(session_id, port, path, timeout: nil)
            api_request(Net::HTTP::Get, port, path,
                        :session => session_id, :timeout => timeout)
        end

        def api_post(session_id, port, path, body: nil, timeout: nil)
            api_request(Net::HTTP::Post, port, path,
                        :session => session_id, :body => body, :timeout => timeout)
        end

        # GET a paged setup collection and return its 'list'.
        def api_list(session_id, port, path)
            Array(api_get(session_id, port, path)['list'])
        end

        # One JSON request. TLS verification is disabled to match NetApp's own
        # client -- Shift appliances ship self-signed certificates.
        def api_request(method_class, port, path, body: nil, session: nil, timeout: nil)
            timeout = (timeout || @timeouts[:http_timeout]).to_i
            uri     = URI.parse("#{@server}:#{port}#{path}")
            http    = Net::HTTP.new(uri.host, uri.port)

            http.use_ssl      = uri.scheme == 'https'
            http.verify_mode  = OpenSSL::SSL::VERIFY_NONE if http.use_ssl?
            http.open_timeout = timeout
            http.read_timeout = timeout

            request = method_class.new(uri.request_uri)
            request['Content-Type'] = 'application/json'
            request['netapp-sie-sessionid'] = session if session
            request.body = JSON.generate(body) if body

            @logger.debug("NetApp Shift: #{method_class::METHOD} #{uri}")

            response = http.request(request)

            raise_api_error(response, path) unless response.is_a?(Net::HTTPSuccess)

            response.body.to_s.empty? ? {} : JSON.parse(response.body)
        rescue JSON::ParserError => e
            raise OperationError, "Shift API #{path} returned invalid JSON: #{e.message}"
        rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
            raise OperationError, "Shift API #{path} failed: #{e.class}: #{e.message}"
        end

        # Turn an error response into the most useful exception available.
        # The appliance answers with
        #   {"level":"error","message":"...","errors":[{"code":"...","message":"..."}]}
        # so the readable message is pulled out rather than dumping the blob.
        def raise_api_error(response, path)
            parsed = begin
                JSON.parse(response.body.to_s)
            rescue JSON::ParserError
                nil
            end

            # The appliance's top-level "message" is often the literal string
            # "[object Object]", so the first entry of "errors" is the one
            # worth reading. Later entries carry structured detail instead.
            errors  = parsed.is_a?(Hash) ? Array(parsed['errors']).select {|e| e.is_a?(Hash) } : []
            detail  = errors.first || (parsed.is_a?(Hash) ? parsed : nil)
            code    = detail.is_a?(Hash) ? detail['code'] : nil
            message = (detail.is_a?(Hash) && detail['message']) ||
                      response.body.to_s[0, 300]

            if code == ERR_ALREADY_EXECUTED || message.to_s.match?(/No further execution is allowed/i)
                raise AlreadyExecuted.new(message.to_s,
                                          :code => code,
                                          :http_status => response.code.to_i)
            end

            if code == ERR_VMS_POWERED_ON
                raise PoweredOnVms.new(
                    message.to_s,
                    :code        => code,
                    :http_status => response.code.to_i,
                    :vm_names    => errors.flat_map {|e| Array(e['poweredOnVmNames']) }.compact.uniq
                )
            end

            raise OperationError.new(
                "Shift API #{path} returned #{response.code}: #{message}",
                :code => code, :http_status => response.code.to_i
            )
        end

        # First value for key anywhere in a nested structure; the session
        # response nests the id.
        def deep_find(obj, key)
            case obj
            when Hash
                return obj[key] if obj.key?(key)

                obj.each_value do |v|
                    found = deep_find(v, key)
                    return found unless found.nil?
                end
                nil
            when Array
                obj.each do |item|
                    found = deep_find(item, key)
                    return found unless found.nil?
                end
                nil
            end
        end

    end

end
