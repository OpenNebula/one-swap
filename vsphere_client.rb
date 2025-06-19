require 'net/http'
require 'uri'
require 'json'

#
# Client for the vCenter REST API
#
class VSphereClient

    attr_reader :vcenter

    def initialize(vcenter, user, password, logger)
        @vcenter = vcenter
        @logger = logger

        @session_id = open_session(vcenter, user, password)
    end

    #
    # Fetch a list of VMs matching the given name
    #
    # @param [String] name VM Name to filter from
    #
    # @return [Array] list of matching VMs
    #
    def get_vms(name)
        uri = URI("https://#{vcenter}/rest/vcenter/vm?filter.names=#{name}")
        request = Net::HTTP::Get.new(uri)
        request['vmware-api-session-id'] = @session_id

        @logger.info("Requesting information of VM: #{name}")
        response = https_request(uri) {|http| http.request(request) }
        vms = JSON.parse(response.body)['value'] # list of vms matching name

        if vms.empty?
            @logger.error("VM '#{name}' not found")
            return
        end

        @logger.info("Found VMs matching name '#{name}'")
        @logger.debug(vms)

        return vms
    end

    #
    # Looks up VM tags for a given VM ID
    #
    # @param [String] vm_id Virtual Machine Identifier
    #
    # @return [String] Tag Name
    #
    def get_vm_tags(vm_id)
        uri = URI("https://#{vcenter}/rest/com/vmware/cis/tagging/tag-association?~action=list-attached-tags")
        request = Net::HTTP::Post.new(uri)
        request['Content-Type'] = 'application/json'
        request.body = {
            'object_id' => {
                'id' => vm_id,
            'type' => 'VirtualMachine'
            }
        }.to_json

        @logger.info("Reading tags from VM ID: #{vm_id}")
        tag_ids = session_https_request(request, uri)

        tag_ids.map do |id|
            tag = tag_info(id)
            name = tag['name']

            @logger.debug("Resolved tag ID #{id} to name '#{name}'")
            name
        end
    end

    #
    # Returns the tag information of a given Tag ID
    #
    # @param [Int] id Tag ID
    #
    # @return [Hash] Tag information
    #
    def tag_info(id)
        uri = URI("https://#{vcenter}/rest/com/vmware/cis/tagging/tag/id:#{id}")
        request = Net::HTTP::Get.new(uri)

        @logger.debug("Fetching tag info for tag ID: #{id}")
        tag_info = session_https_request(request, uri)
        @logger.debug(tag_info)

        return tag_info
    end

    private

    #
    # Creates a new session ID in vCenter
    #
    # @param [String] vcenter endpoint where vCenter is reachable
    # @param [String] vuser Username
    # @param [String] vpass Password
    #
    # @return [String] Session ID
    #
    def open_session(vcenter, vuser, vpass)
        uri = URI("https://#{vcenter}/rest/com/vmware/cis/session")
        request = Net::HTTP::Post.new(uri)
        request.basic_auth(vuser, vpass)

        @logger.debug("Opening session for user: #{vuser}")
        response = https_request(uri) {|http| http.request(request) }
        session_id = JSON.parse(response.body)['value']
        @logger.info("Established a connection to #{@vcenter}")

        return session_id
    end

    def session_https_request(request, uri)
        @logger.debug(request.body)

        request['vmware-api-session-id'] = @session_id
        response = https_request(uri) {|http| http.request(request) }
        JSON.parse(response.body)['value']
    end

    def https_request(uri, &block)
        response = Net::HTTP.start(uri.hostname, uri.port,
                                   :use_ssl => true,
                                   :verify_mode => OpenSSL::SSL::VERIFY_NONE,
                                   &block)

        if response.code.to_i >= 400
            @logger.error("HTTP #{response.code} from #{uri}: #{response.body}")
            raise "HTTP error #{response.code}"
        end

        return response
    end

end
