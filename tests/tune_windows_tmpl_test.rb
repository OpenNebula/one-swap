# Unit tests for WindowsTuner#tune_windows_tmpl
# Run with: ruby tests/tune_windows_tmpl_test.rb

require 'nokogiri'
require 'minitest'
require_relative '../windows_tuner'

class GroupedReporter < Minitest::AbstractReporter
    GROUPS = {
        'INPUT'      => /input/,
        'VIDEO'      => /video/,
        'RAW'        => /raw/,
        'FEATURES'   => /features/,
        'CPU_MODEL'  => /cpu_model/,
        'OS'         => /arch|machine|sd_disk|_os_/,
        'CONTEXT'    => /context|report_ready|token/
    }.freeze

    DISPLAY_ORDER = %w[INPUT VIDEO FEATURES CPU_MODEL OS CONTEXT RAW].freeze

    GREEN = "\e[32m"
    RED   = "\e[31m"
    BOLD  = "\e[1m"
    DIM   = "\e[2m"
    RESET = "\e[0m"

    def initialize
        @results = []
    end

    def record(result)
        @results << result
    end

    def report
        puts
        puts "#{BOLD}WindowsTuner#tune_windows_tmpl#{RESET}"
        puts '─' * 50

        grouped = Hash.new { |h, k| h[k] = [] }
        ungrouped = []

        @results.each do |r|
            group = GROUPS.find { |_, pat| r.name.match?(pat) }&.first
            group ? grouped[group] << r : ungrouped << r
        end

        DISPLAY_ORDER.each do |group|
            next unless grouped[group]&.any?

            puts "\n  #{BOLD}#{group}#{RESET}"
            grouped[group].sort_by(&:name).each {|r| print_result(r) }
        end

        if ungrouped.any?
            puts "\n  #{BOLD}Other#{RESET}"
            ungrouped.sort_by(&:name).each {|r| print_result(r) }
        end

        total  = @results.size
        passed = @results.count(&:passed?)
        failed = total - passed
        color  = failed > 0 ? RED : GREEN

        puts
        puts "#{color}#{BOLD}#{passed}/#{total} passed#{failed > 0 ? ", #{failed} failed" : ''}#{RESET}"
        puts
    end

    def passed?
        @results.all?(&:passed?)
    end

    private

    def print_result(r)
        label = r.name.sub(/^test_/, '').tr('_', ' ')
        if r.passed?
            puts "    #{GREEN}✓#{RESET} #{label}"
        else
            puts "    #{RED}✗#{RESET} #{label}"
            r.failure.message.each_line do |line|
                puts "        #{DIM}#{line.chomp}#{RESET}"
            end
        end
    end
end

Minitest.extensions << 'oneswap_grouped'
module Minitest
    def self.plugin_oneswap_grouped_init(_options)
        reporter.reporters.replace([GroupedReporter.new])
    end
end

require 'minitest/autorun'

class TemplateStub
    ROOT = 'VMTEMPLATE'

    def initialize(extra_xml = '')
        @doc = Nokogiri::XML("<#{ROOT}>#{extra_xml}</#{ROOT}>")
        @xml = @doc.root
    end

    def element_xml(xpath)
        @xml.xpath(xpath).to_s
    end

    def add_element(xpath, elems)
        target = @xml.xpath(xpath).first
        raise "XPath '#{xpath}' not found in template" unless target

        elems.each do |key, value|
            node = Nokogiri::XML::Node.new(key.to_s, @doc)
            if value.is_a?(Hash)
                value.each do |k2, v2|
                    child = Nokogiri::XML::Node.new(k2.to_s, @doc)
                    child.content = v2.to_s
                    node.add_child(child)
                end
            else
                node.content = value.to_s
            end
            target.add_child(node)
        end
    end

    def to_xml
        @doc.to_xml
    end

    def xpath_text(xpath)
        @xml.xpath(xpath).text
    end

    def xpath_count(xpath)
        @xml.xpath(xpath).size
    end
end

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------
class TuneWindowsTmplTest < Minitest::Test
    include WindowsTuner

    # Helper: run tune_windows_tmpl on a fresh empty template
    def empty_template
        tune_windows_tmpl(TemplateStub.new)
    end

    # --- INPUT ---

    def test_adds_usb_tablet_input
        t = empty_template
        assert_equal 'usb',    t.xpath_text('INPUT/BUS')
        assert_equal 'tablet', t.xpath_text('INPUT/TYPE')
    end

    # --- VIDEO ---

    def test_adds_virtio_video
        t = empty_template
        assert_equal 'virtio',  t.xpath_text('VIDEO/TYPE')
        assert_equal '16384',   t.xpath_text('VIDEO/VRAM')
        assert_equal '1440x900', t.xpath_text('VIDEO/RESOLUTION')
    end

    # --- FEATURES ---

    def test_creates_features_when_absent
        t = empty_template
        refute_empty t.element_xml('FEATURES')
    end

    def test_features_hyperv_enabled
        assert_equal 'YES', empty_template.xpath_text('FEATURES/HYPERV')
    end

    def test_features_localtime_enabled
        assert_equal 'YES', empty_template.xpath_text('FEATURES/LOCALTIME')
    end

    def test_features_acpi_apic_pae_enabled
        t = empty_template
        assert_equal 'YES', t.xpath_text('FEATURES/ACPI')
        assert_equal 'YES', t.xpath_text('FEATURES/APIC')
        assert_equal 'YES', t.xpath_text('FEATURES/PAE')
    end

    def test_features_guest_agent_disabled_by_default
        assert_equal 'NO', empty_template.xpath_text('FEATURES/GUEST_AGENT')
    end

    def test_features_guest_agent_enabled_when_qemu_ga_win_set
        t = tune_windows_tmpl(TemplateStub.new, { :qemu_ga_win => '/path/to/virtio-win' })
        assert_equal 'YES', t.xpath_text('FEATURES/GUEST_AGENT')
    end

    def test_features_virtio_queues_auto
        t = empty_template
        assert_equal 'auto', t.xpath_text('FEATURES/VIRTIO_SCSI_QUEUES')
        assert_equal 'auto', t.xpath_text('FEATURES/VIRTIO_BLK_QUEUES')
    end

    def test_merges_into_existing_features_element
        stub = TemplateStub.new('<FEATURES><ACPI>NO</ACPI></FEATURES>')
        t = tune_windows_tmpl(stub)
        assert_equal 'YES', t.xpath_text('FEATURES/HYPERV')
        assert_equal 1, t.xpath_count('FEATURES')
    end

    # --- CPU_MODEL ---

    def test_sets_host_passthrough_cpu_model_when_absent
        assert_equal 'host-passthrough', empty_template.xpath_text('CPU_MODEL/MODEL')
    end

    def test_does_not_overwrite_existing_cpu_model
        stub = TemplateStub.new('<CPU_MODEL><MODEL>Skylake-Client</MODEL></CPU_MODEL>')
        t = tune_windows_tmpl(stub)
        assert_equal 'Skylake-Client', t.xpath_text('CPU_MODEL/MODEL')
        assert_equal 1, t.xpath_count('CPU_MODEL')
    end

    # --- OS  ---

    def test_sets_arch_x86_64_when_os_absent
        assert_equal 'x86_64', empty_template.xpath_text('OS/ARCH')
    end

    def test_adds_arch_into_existing_os_element
        stub = TemplateStub.new('<OS><FIRMWARE>/usr/share/edk2/ovmf/OVMF_CODE.fd</FIRMWARE></OS>')
        t = tune_windows_tmpl(stub)
        assert_equal 'x86_64', t.xpath_text('OS/ARCH')
        refute_empty t.xpath_text('OS/FIRMWARE')
        assert_equal 1, t.xpath_count('OS')
    end

    def test_sets_machine_q35_when_os_absent
        assert_equal 'q35', empty_template.xpath_text('OS/MACHINE')
    end

    def test_does_not_overwrite_existing_machine_type
        stub = TemplateStub.new('<OS><MACHINE>pc</MACHINE></OS>')
        t = tune_windows_tmpl(stub)
        assert_equal 'pc', t.xpath_text('OS/MACHINE')
        assert_equal 1, t.xpath_count('OS/MACHINE')
    end

    def test_sets_sd_disk_bus_scsi_when_os_absent
        assert_equal 'scsi', empty_template.xpath_text('OS/SD_DISK_BUS')
    end

    def test_does_not_overwrite_existing_sd_disk_bus
        stub = TemplateStub.new('<OS><SD_DISK_BUS>virtio</SD_DISK_BUS></OS>')
        t = tune_windows_tmpl(stub)
        assert_equal 'virtio', t.xpath_text('OS/SD_DISK_BUS')
        assert_equal 1, t.xpath_count('OS/SD_DISK_BUS')
    end

    # --- CONTEXT: REPORT_READY / TOKEN ---

    def test_does_not_add_report_ready_without_context_element
        t = empty_template
        assert_empty t.element_xml('CONTEXT')
    end

    def test_adds_report_ready_and_token_when_context_present
        stub = TemplateStub.new('<CONTEXT><NETWORK>YES</NETWORK></CONTEXT>')
        t = tune_windows_tmpl(stub)
        assert_equal 'YES', t.xpath_text('CONTEXT/REPORT_READY')
        assert_equal 'YES', t.xpath_text('CONTEXT/TOKEN')
    end

    def test_preserves_existing_context_entries
        stub = TemplateStub.new('<CONTEXT><NETWORK>YES</NETWORK><SSH_PUBLIC_KEY>$USER[SSH_PUBLIC_KEY]</SSH_PUBLIC_KEY></CONTEXT>')
        t = tune_windows_tmpl(stub)
        assert_equal 'YES',                     t.xpath_text('CONTEXT/NETWORK')
        assert_equal '$USER[SSH_PUBLIC_KEY]',    t.xpath_text('CONTEXT/SSH_PUBLIC_KEY')
    end

    # --- RAW ---

    def test_adds_raw_block_when_absent
        t = empty_template
        refute_empty t.element_xml('RAW')
    end

    def test_raw_type_is_kvm
        assert_equal 'kvm', empty_template.xpath_text('RAW/TYPE')
    end

    def test_raw_validate_is_yes
        assert_equal 'YES', empty_template.xpath_text('RAW/VALIDATE')
    end

    def test_raw_data_contains_hyperv_features
        data = empty_template.xpath_text('RAW/DATA')
        assert_match(/<hyperv>/,                    data)
        assert_match(/relaxed state='on'/,          data)
        assert_match(/spinlocks state='on'/,        data)
        assert_match(/vapic state='on'/,            data)
        assert_match(/stimer state='on'/,           data)
        assert_match(/tlbflush state='on'/,         data)
        assert_match(/frequencies state='on'/,      data)
        assert_match(/ipi state='on'/,              data)
        assert_match(/evmcs state='off'/,           data)
        assert_match(/reenlightenment state='off'/, data)
    end

    def test_raw_data_contains_clock_tuning
        data = empty_template.xpath_text('RAW/DATA')
        assert_match(/<clock offset='utc'>/,             data)
        assert_match(/hpet.*present='no'/,               data)
        assert_match(/hypervclock.*present='yes'/,       data)
        assert_match(/pit.*tickpolicy='delay'/,          data)
        assert_match(/rtc.*tickpolicy='catchup'/,        data)
    end

    def test_does_not_overwrite_existing_raw_block
        stub = TemplateStub.new('<RAW><TYPE>kvm</TYPE><DATA>custom</DATA></RAW>')
        t = tune_windows_tmpl(stub)
        assert_equal 'custom', t.xpath_text('RAW/DATA')
        assert_equal 1, t.xpath_count('RAW')
    end
end
