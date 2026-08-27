# Unit tests for NetAppShift::Helper (netapp_shift_helper.rb).
#
# Run with: ruby tests/netapp_shift_helper_test.rb
#
# netapp_shift_helper.rb has no OpenNebula dependencies, so unlike the
# oneswap_helper tests no require shims are needed. The appliance is faked at
# the single transport chokepoint (#api_request), which exercises every
# endpoint path, payload and response-handling decision above it.

require 'minitest/autorun'
require 'json'
require 'logger'
require 'tmpdir'

require_relative '../netapp_shift_helper'

QUIET = Logger.new(File::NULL)

# Records every request and replays canned responses. Routes are keyed by
# path (String for exact match, Regexp otherwise); a callable route is invoked
# per request so a sequence of differing responses can be replayed.
class FakeAppliance

    SESSION = {
        '/api/tenant/session'     => { 'session' => { '_id' => 'sid-1' } },
        '/api/tenant/session/end' => {}
    }.freeze

    attr_reader :calls

    def initialize(routes = {})
        @routes = SESSION.merge(routes)
        @calls  = []
    end

    def handle(method_class, port, path, body: nil, session: nil, timeout: nil)
        @calls << { :verb => method_class::METHOD, :port => port, :path => path,
                    :body => body, :session => session, :timeout => timeout }

        key = @routes.keys.find {|k| k.is_a?(Regexp) ? path.match?(k) : k == path }

        raise "test: unrouted #{method_class::METHOD} #{path}" if key.nil?

        route = @routes[key]
        route.respond_to?(:call) ? route.call : route
    end

    def paths(verb = nil)
        @calls.select {|c| verb.nil? || c[:verb] == verb }.map {|c| c[:path] }
    end

    def find(path_fragment)
        @calls.find {|c| c[:path].include?(path_fragment) }
    end

end

# Replays the given responses in order, repeating the last one forever.
def sequence(*responses)
    queue = responses.dup
    -> { queue.length > 1 ? queue.shift : queue.first }
end

def helper_with(routes = {}, options = {})
    helper = NetAppShift::Helper.new({ :server   => 'https://shift.local',
                                       :username => 'admin',
                                       :password => 's3cr3t',
                                       :logger   => QUIET }.merge(options))
    fake = FakeAppliance.new(routes)

    helper.define_singleton_method(:api_request) do |mc, port, path, **kw|
        fake.handle(mc, port, path, **kw)
    end
    # never actually wait in tests
    helper.define_singleton_method(:sleep) {|*| nil }

    [helper, fake]
end

BLUEPRINTS = {
    'list' => [
        { '_id' => 'bp-1', 'name' => 'multidisk', 'protectionGroups' => [{ '_id' => 'rg-1' }] },
        { '_id' => 'bp-2', 'name' => 'waves',
          'protectionGroups' => [{ '_id' => 'rg-1' }, { '_id' => 'rg-2' }] }
    ]
}.freeze

GROUPS = {
    'list' => [
        { '_id' => 'rg-1', 'name' => 'group1',
          'vms' => [{ '_id' => 'vm-1', 'name' => 'web01' },
                    { '_id' => 'vm-2', 'name' => 'web02' }] },
        { '_id' => 'rg-2', 'name' => 'group2', 'vms' => [{ '_id' => 'vm-3', 'name' => 'db01' }] },
        { '_id' => 'rg-9', 'name' => 'unrelated', 'vms' => [{ '_id' => 'vm-9', 'name' => 'other' }] }
    ]
}.freeze

SETUP_ROUTES = {
    '/api/setup/drplan'          => BLUEPRINTS,
    '/api/setup/protectionGroup' => GROUPS
}.freeze

def steps(*statuses)
    { 'steps' => statuses.each_with_index.map do |s, i|
        { 'description' => "step #{i}", 'status' => s }
    end }
end

class ConstructorTest < Minitest::Test

    def test_bare_host_gets_https
        helper, = helper_with({}, :server => '10.0.0.5')
        assert_equal 'https://10.0.0.5', helper.server
    end

    def test_trailing_slash_stripped
        helper, = helper_with({}, :server => 'https://shift.local/')
        assert_equal 'https://shift.local', helper.server
    end

    def test_port_rejected
        err = assert_raises(ArgumentError) { helper_with({}, :server => 'https://10.0.0.5:3700') }
        assert_includes err.message, 'must not include a port'
    end

    def test_missing_credentials_rejected
        assert_raises(ArgumentError) { helper_with({}, :username => '') }
        assert_raises(ArgumentError) { helper_with({}, :password => '') }
    end

end

class BlueprintVmNamesTest < Minitest::Test

    def test_single_group
        helper, = helper_with(SETUP_ROUTES)
        assert_equal %w[web01 web02], helper.blueprint_vm_names('multidisk')
    end

    def test_multiple_groups_in_order
        helper, = helper_with(SETUP_ROUTES)
        assert_equal %w[web01 web02 db01], helper.blueprint_vm_names('waves')
    end

    def test_unknown_blueprint_lists_available
        helper, = helper_with(SETUP_ROUTES)

        err = assert_raises(NetAppShift::OperationError) { helper.blueprint_vm_names('nope') }

        assert_includes err.message, 'multidisk'
        assert_includes err.message, 'waves'
    end

    def test_session_opened_and_ended
        helper, fake = helper_with(SETUP_ROUTES)
        helper.blueprint_vm_names('multidisk')

        assert_includes fake.paths, '/api/tenant/session'
        assert_includes fake.paths, '/api/tenant/session/end'
    end

    def test_session_ended_even_on_failure
        helper, fake = helper_with(SETUP_ROUTES)
        assert_raises(NetAppShift::OperationError) { helper.blueprint_vm_names('nope') }

        assert_includes fake.paths, '/api/tenant/session/end'
    end

    def test_blueprint_vms_carry_their_resource_group
        helper, = helper_with(SETUP_ROUTES)

        assert_equal [{ :name => 'web01', :id => 'vm-1', :resource_group => 'group1' },
                      { :name => 'web02', :id => 'vm-2', :resource_group => 'group1' },
                      { :name => 'db01',  :id => 'vm-3', :resource_group => 'group2' }],
                     helper.blueprint_vms('waves')
    end

    def test_blueprint_summaries_join_groups_and_vms
        helper, = helper_with(SETUP_ROUTES)
        summaries = helper.blueprint_summaries

        assert_equal %w[multidisk waves], summaries.map {|bp| bp[:name] }

        waves = summaries.find {|bp| bp[:name] == 'waves' }
        assert_equal %w[group1 group2], waves[:resource_groups]
        assert_equal %w[web01 web02 db01], waves[:vms]

        # the unrelated group is not attached to any blueprint
        refute_includes summaries.flat_map {|bp| bp[:vms] }, 'other'
    end

    def test_blueprint_summaries_survive_a_dangling_group_reference
        blueprints = { 'list' => [{ '_id' => 'bp-x', 'name' => 'stale',
                                    'protectionGroups' => [{ '_id' => 'gone' }] }] }
        helper, = helper_with(SETUP_ROUTES.merge('/api/setup/drplan' => blueprints))

        assert_equal [{ :name => 'stale', :id => 'bp-x',
                        :resource_groups => [], :vms => [] }],
                     helper.blueprint_summaries
    end

    def test_session_is_reused_not_reopened
        helper, fake = helper_with(SETUP_ROUTES)
        helper.blueprint_vm_names('multidisk')

        # one open for the whole call, despite two setup GETs inside it
        assert_equal 1, fake.paths.count('/api/tenant/session')
        assert_equal 'sid-1', fake.find('/api/setup/drplan')[:session]
    end

end

class BlueprintExecutionStateTest < Minitest::Test

    # Verbatim shape from a live appliance. Note there is no "recoveryStatus"
    # on drPlan -- the state lives on lastExecution.
    def entry(exec_status, exec_id = 'ex-1', bp_id = 'bp-1', type = 'convert')
        {
            'drPlan'        => { '_id' => bp_id, 'name' => 'multidisk',
                                 'activeSite' => 'source', 'vmSuccessCount' => 0 },
            'lastExecution' => exec_status.nil? ? nil : { '_id' => exec_id,
                                                          'status' => exec_status,
                                                          'type' => type },
            'lastPrepareVmExecution' => nil
        }
    end

    def state_helper(status_body)
        helper_with(SETUP_ROUTES.merge(NetAppShift::Helper::PATH_BLUEPRINT_STATUS => status_body))
    end

    def test_completed_conversion
        helper, fake = state_helper([entry(NetAppShift::Helper::STATE_SUCCESS)])
        state = helper.blueprint_execution_state('multidisk')

        assert state[:complete]
        refute state[:running]
        refute state[:failed]
        assert_equal 'ex-1', state[:execution_id]
        assert_equal 'convert', state[:type]
        assert_equal NetAppShift::Helper::RECOVERY_PORT,
                     fake.find(NetAppShift::Helper::PATH_BLUEPRINT_STATUS)[:port]
    end

    def test_failed_execution
        helper, = state_helper([entry(NetAppShift::Helper::STATE_FAILED)])
        state = helper.blueprint_execution_state('multidisk')

        assert state[:failed]
        refute state[:complete]
        refute state[:running]
    end

    def test_in_flight_execution_is_running
        helper, = state_helper([entry(2)])
        state = helper.blueprint_execution_state('multidisk')

        assert state[:running]
        refute state[:complete]
        refute state[:failed]
        assert_equal 'ex-1', state[:execution_id]
    end

    def test_never_executed_returns_nil
        helper, = state_helper([entry(nil)])
        assert_nil helper.blueprint_execution_state('multidisk')
    end

    def test_absent_blueprint_returns_nil
        helper, = state_helper([entry(NetAppShift::Helper::STATE_SUCCESS, 'ex-9', 'bp-other')])
        assert_nil helper.blueprint_execution_state('multidisk')
    end

    def test_empty_list_returns_nil
        helper, = state_helper([])
        assert_nil helper.blueprint_execution_state('multidisk')
    end

    def test_tolerates_list_envelope
        helper, = state_helper('list' => [entry(NetAppShift::Helper::STATE_SUCCESS)])
        assert helper.blueprint_execution_state('multidisk')[:complete]
    end

    def test_tolerates_junk_entries
        helper, = state_helper(['nonsense', nil, entry(NetAppShift::Helper::STATE_SUCCESS)])
        assert helper.blueprint_execution_state('multidisk')[:complete]
    end

end

class ExecutionStatusTest < Minitest::Test

    S = NetAppShift::Helper::STATE_SUCCESS
    F = NetAppShift::Helper::STATE_FAILED

    def status_for(body)
        helper, = helper_with(%r{/api/recovery/execution/.*/steps} => body)
        helper.execution_status('ex-1')
    end

    def test_all_success_is_complete
        assert_equal :complete, status_for(steps(S, S, S))
    end

    def test_any_failure_is_failed
        assert_equal :failed, status_for(steps(S, F, S))
    end

    def test_mixed_pending_is_running
        assert_equal :running, status_for(steps(S, 2, S))
    end

    def test_no_steps_is_unknown
        assert_equal :unknown, status_for('steps' => [])
    end

    def test_hits_the_execution_scoped_path
        helper, fake = helper_with(%r{/api/recovery/execution/.*/steps} => steps(S))
        helper.execution_status('ex-42')

        assert_includes fake.paths, '/api/recovery/execution/ex-42/steps'
    end

end

class WaitForCompletionTest < Minitest::Test

    S = NetAppShift::Helper::STATE_SUCCESS
    F = NetAppShift::Helper::STATE_FAILED

    def waiter(*bodies)
        helper_with(%r{/api/recovery/execution/.*/steps} => sequence(*bodies))
    end

    def test_returns_when_all_steps_succeed
        helper, = waiter(steps(S, S))
        result = helper.wait_for_completion('bp', 'ex-1')

        assert_equal 'complete', result[:status]
        assert_equal 2, result[:steps].length
    end

    def test_polls_while_running
        helper, fake = waiter(steps(S, 2), steps(S, 2), steps(S, S))
        assert_equal 'complete', helper.wait_for_completion('bp', 'ex-1')[:status]
        assert_equal 3, fake.paths.count('/api/recovery/execution/ex-1/steps')
    end

    def test_raises_naming_the_failed_step
        helper, = waiter(steps(S, F))

        err = assert_raises(NetAppShift::OperationError) { helper.wait_for_completion('bp', 'ex-1') }

        assert_includes err.message, 'step 1'
        assert_includes err.message, 'ex-1'
    end

    def test_overall_timeout
        helper, = waiter(steps(S, 2))

        err = assert_raises(NetAppShift::OperationError) do
            helper.wait_for_completion('bp', 'ex-1', :timeout => 1e-9)
        end

        assert_includes err.message, 'Timed out'
    end

    def test_nil_timeout_keeps_waiting
        helper, = waiter(steps(2), steps(2), steps(2), steps(2), steps(S))
        assert_equal 'complete', helper.wait_for_completion('bp', 'ex-1', :timeout => nil)[:status]
    end

end

class ComplianceCheckTest < Minitest::Test

    def compliance_helper(*poll_bodies, request: { 'taskId' => 'task-9' })
        helper_with(
            SETUP_ROUTES.merge(
                %r{/checkrequest\?async=true} => request,
                %r{/checkrequest\?taskId=}    => sequence(*poll_bodies)
            ),
            :timeouts => { :compliance_settle => 0 }
        )
    end

    def test_requests_then_polls_until_succeeded
        helper, fake = compliance_helper({ 'status' => 'running' },
                                         { 'status' => 'succeeded', 'result' => [{ 'a' => 1 }] })
        result = helper.run_compliance_check('multidisk')

        assert_equal 'task-9', result[:task_id]
        assert_equal [{ 'a' => 1 }], result[:result]
        assert_includes fake.paths, '/api/setup/compliance/drplan/bp-1/checkrequest?async=true'
        # the task id goes in both the path and the query on the poll
        assert_includes fake.paths,
                        '/api/setup/compliance/drplan/task-9/checkrequest?taskId=task-9'
    end

    def test_uses_the_setup_port
        helper, fake = compliance_helper({ 'status' => 'succeeded' })
        helper.run_compliance_check('multidisk')

        assert_equal NetAppShift::Helper::SETUP_PORT, fake.find('checkrequest')[:port]
    end

    def test_missing_task_id_raises
        helper, = compliance_helper({ 'status' => 'succeeded' }, :request => {})

        err = assert_raises(NetAppShift::OperationError) { helper.run_compliance_check('multidisk') }
        assert_includes err.message, 'no task id'
    end

    def test_failed_status_raises
        helper, = compliance_helper({ 'status' => 'failed', 'result' => ['bad'] })

        err = assert_raises(NetAppShift::OperationError) { helper.run_compliance_check('multidisk') }
        assert_includes err.message, 'failed'
    end

    def test_gives_up_after_the_poll_limit
        helper, = helper_with(
            SETUP_ROUTES.merge(%r{/checkrequest\?async=true} => { 'taskId' => 't' },
                               %r{/checkrequest\?taskId=}    => { 'status' => 'running' }),
            :timeouts => { :compliance_settle => 0, :compliance_poll_limit => 3,
                           :compliance_poll_interval => 0 }
        )

        err = assert_raises(NetAppShift::OperationError) { helper.run_compliance_check('multidisk') }
        assert_includes err.message, 'did not finish'
    end

end

class TriggerConversionTest < Minitest::Test

    def trigger_helper(response)
        helper_with(SETUP_ROUTES.merge(%r{/execution\z} => response))
    end

    def test_returns_execution_id_from_the_convert_path
        helper, fake = trigger_helper('_id' => 'ex-77')

        assert_equal 'ex-77', helper.trigger_conversion('multidisk')
        # capital P in drPlan here, unlike /api/recovery/drplan/status
        assert_includes fake.paths, '/api/recovery/drPlan/bp-1/convert/execution'
        assert_equal NetAppShift::Helper::RECOVERY_PORT, fake.find('/execution')[:port]
    end

    def test_sends_the_empty_service_accounts_payload
        helper, fake = trigger_helper('_id' => 'ex-77')
        helper.trigger_conversion('multidisk')

        assert_equal({ 'common' => { 'loginId' => nil, 'password' => nil }, 'vms' => [] },
                     fake.find('/execution')[:body]['serviceAccounts'])
    end

    # The default request must stay exactly as it is today; the override is
    # only sent when explicitly asked for.
    def test_powered_on_override_is_absent_by_default
        helper, fake = trigger_helper('_id' => 'ex-77')
        helper.trigger_conversion('multidisk')

        refute fake.find('/execution')[:body].key?('ignorePoweredOnVms')
    end

    def test_powered_on_override_is_sent_when_requested
        helper, fake = trigger_helper('_id' => 'ex-77')
        helper.trigger_conversion('multidisk', :ignore_powered_on => true)

        assert_equal true, fake.find('/execution')[:body]['ignorePoweredOnVms']
    end

    def test_finds_a_nested_execution_id
        helper, = trigger_helper('execution' => { '_id' => 'ex-nested' })
        assert_equal 'ex-nested', helper.trigger_conversion('multidisk')
    end

    def test_missing_execution_id_raises
        helper, = trigger_helper({})

        err = assert_raises(NetAppShift::OperationError) { helper.trigger_conversion('multidisk') }
        assert_includes err.message, 'no execution id'
    end

end

# Fake Net::HTTPResponse for the error-translation layer
FakeResponse = Struct.new(:code, :body) do
    def is_a?(klass)
        klass == Net::HTTPSuccess ? false : super
    end
end

class ApiErrorTranslationTest < Minitest::Test

    # Verbatim body from a real appliance, trimmed. Note their "succesful"
    # typo -- never match on it.
    ERSCSTEX009_BODY = {
        'level'   => 'error',
        'message' => 'ERSCSTEX009: The -convert execution is succesful for Blueprint ' \
                     '- 588314a3. No further execution is allowed.',
        'errors'  => [{
            'code'    => 'ERSCSTEX009',
            'message' => 'ERSCSTEX009: The -convert execution is succesful for ' \
                         'Blueprint - 588314a3. No further execution is allowed.',
            'level'   => 'error'
        }]
    }.freeze

    def raise_for(code, body)
        helper = NetAppShift::Helper.allocate
        helper.send(:raise_api_error, FakeResponse.new(code, body), '/some/path')
    end

    def test_already_executed_is_its_own_error
        err = assert_raises(NetAppShift::AlreadyExecuted) do
            raise_for('500', JSON.generate(ERSCSTEX009_BODY))
        end

        assert_equal 'ERSCSTEX009', err.code
        assert_equal 500, err.http_status
        assert_includes err.message, 'No further execution is allowed'
    end

    def test_already_executed_detected_without_a_code
        body = { 'message' => 'No further execution is allowed.' }

        assert_raises(NetAppShift::AlreadyExecuted) { raise_for('500', JSON.generate(body)) }
    end

    # Verbatim from a live appliance. Note the top-level message is their
    # "[object Object]" bug, and the VM names live in a *second* error object.
    ERSCSTEX022_BODY = {
        'level'   => 'error',
        'message' => '[object Object]',
        'errors'  => [
            {
                'uid'     => 'c268a134-68f0-4fda-b22d-64731cd4df48',
                'code'    => 'ERSCSTEX022',
                'message' => "ERSCSTEX022: Cannot execute the 'convert' action - as some " \
                             'VMs are still powered on. Powered on VMs - ' \
                             'u2505-oneswap-test_netappshift,oneswap-shift-multidisk',
                'level'   => 'error'
            },
            {
                'executionType'     => 'convert',
                'poweredOnVmNames'  => ['u2505-oneswap-test_netappshift',
                                        'oneswap-shift-multidisk'],
                'poweredOffVmNames' => [],
                'code'              => '',
                'message'           => '[object Object]'
            }
        ]
    }.freeze

    def test_powered_on_vms_is_its_own_error_carrying_the_names
        err = assert_raises(NetAppShift::PoweredOnVms) do
            raise_for('500', JSON.generate(ERSCSTEX022_BODY))
        end

        assert_equal 'ERSCSTEX022', err.code
        assert_equal 500, err.http_status
        assert_equal ['u2505-oneswap-test_netappshift', 'oneswap-shift-multidisk'],
                     err.vm_names
        # the readable message, not the "[object Object]" top-level one
        assert_includes err.message, 'still powered on'
        refute_includes err.message, '[object Object]'
    end

    def test_other_errors_surface_the_appliance_message
        body = { 'errors' => [{ 'code' => 'ERAUTH001', 'message' => 'Session expired' }] }

        err = assert_raises(NetAppShift::OperationError) { raise_for('401', JSON.generate(body)) }

        refute_kind_of NetAppShift::AlreadyExecuted, err
        assert_includes err.message, 'Session expired'
        assert_includes err.message, '401'
        assert_equal 'ERAUTH001', err.code
    end

    def test_non_json_body_still_raises_usefully
        err = assert_raises(NetAppShift::OperationError) { raise_for('502', '<html>bad gateway</html>') }

        assert_includes err.message, '502'
        assert_includes err.message, 'bad gateway'
    end

end

class ConvertedDisksTest < Minitest::Test

    def bare
        NetAppShift::Helper.allocate
    end

    def test_single_disk
        Dir.mktmpdir do |mount|
            File.write(File.join(mount, 'web01.qcow2'), 'x')
            assert_equal [File.join(mount, 'web01.qcow2')], bare.converted_disks('web01', mount, 1)
        end
    end

    def test_multi_disk_ordering
        Dir.mktmpdir do |mount|
            ['multi.qcow2', 'multi_1.qcow2', 'multi_2.qcow2'].each do |f|
                File.write(File.join(mount, f), 'x')
            end

            assert_equal ['multi.qcow2', 'multi_1.qcow2', 'multi_2.qcow2'],
                         bare.converted_disks('multi', mount, 3).map {|d| File.basename(d) }
        end
    end

    def test_missing_disks_named_in_error
        Dir.mktmpdir do |mount|
            File.write(File.join(mount, 'web01.qcow2'), 'x')

            err = assert_raises(NetAppShift::Error) { bare.converted_disks('web01', mount, 2) }
            assert_includes err.message, 'web01_1.qcow2'
        end
    end

    def test_does_not_glob_similar_names
        Dir.mktmpdir do |mount|
            File.write(File.join(mount, 'web01-old.qcow2'), 'x')
            assert_raises(NetAppShift::Error) { bare.converted_disks('web01', mount, 1) }
        end
    end

    def test_rejects_non_positive_count
        assert_raises(ArgumentError) { bare.converted_disks('web01', '/mnt', 0) }
    end

end
