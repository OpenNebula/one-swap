#!/usr/bin/env ruby
# Runs two levels:
#   1. Unit tests for inject_dns_resolv_conf logic
#   2. Smoke test that calls virt-customize --copy-in on a qcow2 image and verifies resolv.conf inside the guest (requires libguestfs tools)
#
# Usage:
#   ruby tests/inject_dns.rb
#   ruby tests/inject_dns.rb --smoke

require 'tmpdir'
require 'fileutils'

SMOKE = ARGV.include?('--smoke')

class InjectDnsTestHelper

    def initialize(opts = {})
        @options = opts
    end

    def inject_dns_resolv_conf
        val = @options[:inject_dns].to_s.strip
        if val == 'host'
            unless File.exist?('/etc/resolv.conf')
                puts 'Warning: --inject-dns host specified but /etc/resolv.conf not found on host, skipping.'.brown
                return nil
            end
            real_path = File.realpath('/etc/resolv.conf')
            tmp_resolv = "#{@options[:work_dir]}/resolv.conf"
            File.open(real_path, 'rb') do |src|
                File.open(tmp_resolv, 'wb') {|dst| IO.copy_stream(src, dst) }
            end
            puts "Injecting host resolv.conf (from #{real_path}) into guest..."
            return tmp_resolv
        else
            ips = val.split(',').map(&:strip).reject(&:empty?)
            if ips.empty?
                puts 'Warning: --inject-dns value is not valid, skipping DNS injection.'
                return nil
            end
            tmp_resolv = "#{@options[:work_dir]}/resolv.conf"
            File.write(tmp_resolv, ips.map {|ip| "nameserver #{ip}" }.join("\n") + "\n")
            puts "Injecting custom resolv.conf (#{ips.join(', ')}) into guest for DNS resolution..."
            return tmp_resolv
        end
    end

end

def pass(msg) = puts("  \e[32m✓\e[0m #{msg}")
def fail_test(msg) = (puts("  \e[31m✗\e[0m #{msg}"); $failures += 1)
def section(title) = puts("\n\e[1m#{title}\e[0m")

$failures = 0

def make_helper(opts = {}) = InjectDnsTestHelper.new(opts)

section '1. Unit tests for inject_dns_resolv_conf'

Dir.mktmpdir('oneswap_dns_test') do |tmpdir|

    begin
        h = make_helper(inject_dns: 'host', work_dir: tmpdir)
        result = h.send(:inject_dns_resolv_conf)
        if File.exist?('/etc/resolv.conf')
            expected_path = "#{tmpdir}/resolv.conf"
            if result == expected_path &&
               File.exist?(expected_path) &&
               File.read(expected_path) == File.read(File.realpath('/etc/resolv.conf'))
                pass "1a. 'host' copies resolved content to work_dir/resolv.conf"
            else
                fail_test "1a. Expected #{expected_path.inspect} with host resolv.conf content, got #{result.inspect}"
            end
        else
            if result.nil?
                pass "1a. 'host' returns nil when /etc/resolv.conf does not exist (expected on this host)"
            else
                fail_test "1a. Expected nil but got #{result.inspect}"
            end
        end
    rescue => e
        fail_test "1a. Raised unexpected exception: #{e}"
    end

    begin
        h = make_helper(inject_dns: '8.8.8.8', work_dir: tmpdir)
        result = h.send(:inject_dns_resolv_conf)
        expected_path = "#{tmpdir}/resolv.conf"
        if result == expected_path &&
           File.exist?(expected_path) &&
           File.read(expected_path).chomp == 'nameserver 8.8.8.8'
            pass "1b. Single IP generates correct resolv.conf at work_dir"
        else
            fail_test "1b. Single IP: path=#{result.inspect}, content=#{File.exist?(expected_path) ? File.read(expected_path).inspect : '(missing)'}"
        end
    rescue => e
        fail_test "1b. Raised unexpected exception: #{e}"
    end

    begin
        h = make_helper(inject_dns: '8.8.8.8,1.1.1.1,9.9.9.9', work_dir: tmpdir)
        result = h.send(:inject_dns_resolv_conf)
        expected_path = "#{tmpdir}/resolv.conf"
        expected_content = "nameserver 8.8.8.8\nnameserver 1.1.1.1\nnameserver 9.9.9.9\n"
        actual_content = File.exist?(expected_path) ? File.read(expected_path) : nil
        if result == expected_path && actual_content == expected_content
            pass "1c. Multiple IPs generate correct multi-nameserver resolv.conf"
        else
            fail_test "1c. Multiple IPs: path=#{result.inspect}, content=#{actual_content.inspect}"
        end
    rescue => e
        fail_test "1c. Raised unexpected exception: #{e}"
    end

    begin
        h = make_helper(inject_dns: ' 8.8.8.8 , 1.1.1.1 ', work_dir: tmpdir)
        result = h.send(:inject_dns_resolv_conf)
        content = File.exist?("#{tmpdir}/resolv.conf") ? File.read("#{tmpdir}/resolv.conf") : ''
        if content.include?('nameserver 8.8.8.8') && content.include?('nameserver 1.1.1.1') &&
           !content.include?('nameserver  ')
            pass "1d. Whitespace around IPs is trimmed"
        else
            fail_test "1d. Whitespace trimming: content=#{content.inspect}"
        end
    rescue => e
        fail_test "1d. Raised unexpected exception: #{e}"
    end

    begin
        h = make_helper(inject_dns: '   ', work_dir: tmpdir)
        result = h.send(:inject_dns_resolv_conf)
        if result.nil?
            pass "1e. Empty/whitespace-only value returns nil (no injection)"
        else
            fail_test "1e. Expected nil but got #{result.inspect}"
        end
    rescue => e
        fail_test "1e. Raised unexpected exception: #{e}"
    end

end

unless SMOKE
    puts "\nSkipping smoke test (pass --smoke to enable)"
    puts "\nRequires: qemu-img, virt-format, guestfish"
else
    section '2. Smoke test — guestfish copy-in on a real ext4 disk image'

    %w[qemu-img virt-format guestfish].each do |tool|
        unless system("which #{tool} > /dev/null 2>&1")
            puts "  \e[33m⚠\e[0m  #{tool} not found, skipping smoke test"
            exit $failures > 0 ? 1 : 0
        end
    end

    Dir.mktmpdir('oneswap_dns_smoke') do |tmpdir|
        disk      = "#{tmpdir}/test.qcow2"
        resolv_in = "#{tmpdir}/resolv.conf"

        puts '  Creating minimal ext4 disk image (32 MB)...'
        ok = system("qemu-img create -f qcow2 #{disk} 32M > /dev/null 2>&1") &&
             system("virt-format --filesystem=ext4 -a #{disk} > /dev/null 2>&1")
        unless ok
            fail_test '2. Failed to create/format test disk image'
        else
            dev = `guestfish -a #{disk} -- run : list-filesystems 2>/dev/null`.split(':').first.to_s.strip
            if dev.empty?
                fail_test '2. Could not detect filesystem device in test image'
            else
                puts "  Detected filesystem device: #{dev}"

                guestfish_run = lambda do |script|
                    IO.popen('guestfish', 'r+') {|gf| gf.write(script); gf.close_write; gf.read }
                end

                guestfish_cat = lambda do |path|
                    `guestfish -a #{disk} -m #{dev} -- cat #{path} 2>/dev/null`.strip
                end

                h = make_helper(inject_dns: 'host', work_dir: tmpdir)
                resolv_src = h.send(:inject_dns_resolv_conf)
                expected = File.read(resolv_src).strip

                guestfish_run.call(<<~SCRIPT)
                    add #{disk}
                    run
                    mount #{dev} /
                    mkdir-p /etc
                    copy-in #{resolv_src} /etc/
                    exit
                SCRIPT

                actual = guestfish_cat.call('/etc/resolv.conf')

                if actual == expected
                    pass "2a. 'host' mode: resolv.conf injected correctly into guest:\n" \
                         "       #{actual.gsub("\n", "\n       ")}"
                else
                    fail_test "2a. 'host' mode content mismatch.\n" \
                              "       expected: #{expected.inspect}\n" \
                              "       got:      #{actual.inspect}"
                end

                h2 = make_helper(inject_dns: '8.8.8.8,1.1.1.1', work_dir: tmpdir)
                resolv_src2 = h2.send(:inject_dns_resolv_conf)

                guestfish_run.call(<<~SCRIPT)
                    add #{disk}
                    run
                    mount #{dev} /
                    copy-in #{resolv_src2} /etc/
                    exit
                SCRIPT

                actual2   = guestfish_cat.call('/etc/resolv.conf')
                expected2 = "nameserver 8.8.8.8\nnameserver 1.1.1.1"

                if actual2 == expected2
                    pass "2b. Custom IPs mode: resolv.conf injected correctly:\n" \
                         "       #{actual2.gsub("\n", "\n       ")}"
                else
                    fail_test "2b. Custom IPs mode content mismatch.\n" \
                              "       expected: #{expected2.inspect}\n" \
                              "       got:      #{actual2.inspect}"
                end
            end
        end
    end
end

puts
if $failures == 0
    puts "\e[32mAll tests passed.\e[0m"
    exit 0
else
    puts "\e[31m#{$failures} test(s) failed.\e[0m"
    exit 1
end
