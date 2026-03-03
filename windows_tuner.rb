# Mixin module that applies Windows optimizations to an OpenNebula VM Template

module WindowsTuner
    # Apply Windows template optimizations
    #
    # Idempotent where possible: existing FEATURES, CPU_MODEL, OS and RAW
    # blocks are extended

    def tune_windows_tmpl(template, opts = {})
        vm_template = template

        # Add USB tablet input device for proper mouse pointer handling
        input_hash = { 'BUS' => 'usb', 'TYPE' => 'tablet' }
        vm_template.add_element('//VMTEMPLATE', { 'INPUT' => input_hash })

        # Configure video settings
        video_hash = { 'RESOLUTION' => '1440x900', 'TYPE' => 'virtio', 'VRAM' => '16384' }
        vm_template.add_element('//VMTEMPLATE', { 'VIDEO' => video_hash })

        # GUEST_AGENT exposes the virtio-serial channel for the QEMU guest agent.
        # Only enable it when the agent MSI is actually going to be installed.
        guest_agent = opts[:qemu_ga_win] ? 'YES' : 'NO'

        # Configure features
        features_hash = {
            'ACPI'               => 'YES',
            'PAE'                => 'YES',
            'APIC'               => 'YES',
            'HYPERV'             => 'YES',
            'LOCALTIME'          => 'YES',
            'GUEST_AGENT'        => guest_agent,
            'VIRTIO_SCSI_QUEUES' => 'auto',
            'VIRTIO_BLK_QUEUES'  => 'auto'
        }
        if vm_template.element_xml('FEATURES').nil? || vm_template.element_xml('FEATURES').empty?
            vm_template.add_element('//VMTEMPLATE', { 'FEATURES' => features_hash })
        else
            vm_template.add_element('//VMTEMPLATE/FEATURES', features_hash)
        end

        # Set host-passthrough CPU model if not already configured
        if vm_template.element_xml('CPU_MODEL').nil? || vm_template.element_xml('CPU_MODEL').empty?
            vm_template.add_element('//VMTEMPLATE', { 'CPU_MODEL' => { 'MODEL' => 'host-passthrough' } })
        end

        # Set architecture explicitly to x86_64
        if vm_template.element_xml('OS').nil? || vm_template.element_xml('OS').empty?
            vm_template.add_element('//VMTEMPLATE', { 'OS' => { 'ARCH' => 'x86_64' } })
        else
            vm_template.add_element('//VMTEMPLATE/OS', { 'ARCH' => 'x86_64' })
        end

        # Signal OpenNebula when one-context has finished initializing the VM.
        unless vm_template.element_xml('CONTEXT').nil? || vm_template.element_xml('CONTEXT').empty?
            vm_template.add_element('//VMTEMPLATE/CONTEXT', { 'REPORT_READY' => 'YES', 'TOKEN' => 'YES' })
        end

        hyperv_raw = <<~XML.strip
            <features>
              <hyperv>
                <evmcs state='off'/>
                <frequencies state='on'/>
                <ipi state='on'/>
                <reenlightenment state='off'/>
                <relaxed state='on'/>
                <reset state='off'/>
                <runtime state='on'/>
                <spinlocks state='on' retries='8191'/>
                <stimer state='on'/>
                <synic state='on'/>
                <tlbflush state='on'/>
                <vapic state='on'/>
                <vpindex state='on'/>
              </hyperv>
            </features>
            <clock offset='utc'>
              <timer name='hpet' present='no'/>
              <timer name='hypervclock' present='yes'/>
              <timer name='pit' tickpolicy='delay'/>
              <timer name='rtc' tickpolicy='catchup'/>
            </clock>
        XML
        if vm_template.element_xml('RAW').nil? || vm_template.element_xml('RAW').empty?
            vm_template.add_element('//VMTEMPLATE',
                                    { 'RAW' => { 'TYPE' => 'kvm', 'DATA' => hyperv_raw, 'VALIDATE' => 'YES' } })
        end

        vm_template
    end
end
