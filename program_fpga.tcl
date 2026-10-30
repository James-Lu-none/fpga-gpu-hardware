# Vivado Lab: detect|program top.bin sram|flash
if {[llength $argv] != 3} { error "Expected detect|program, bitstream path and sram|flash" }
lassign $argv action bitstream mode
if {$action ni {detect program} || $mode ni {sram flash}} { error "Invalid programming action/mode" }
if {![file isfile $bitstream]} { error "Bitstream file missing: $bitstream" }
if {[file size $bitstream] <= 0 || [file size $bitstream] > 16777216} {
    error "Bitstream must fit the AX7A200B 128-Mbit (16-MiB) configuration memory"
}
set_param labtools.enable_cs_server false
open_hw_manager
try {
    # Hardware Manager launches/connects to the local hw_server.
    connect_hw_server
    set targets [get_hw_targets]
    if {[llength $targets] != 1} {
        error "Expected one JTAG target, found [llength $targets]: $targets"
    }
    current_hw_target [lindex $targets 0]
    set_property PARAM.FREQUENCY 6000000 [current_hw_target]
    open_hw_target
    set devices [get_hw_devices]
    set fpga [get_hw_devices -quiet xc7a200t*]
    if {[llength $devices] != 1 || [llength $fpga] != 1} {
        error "Expected a single XC7A200T, found: $devices"
    }
    set device [lindex $fpga 0]
    current_hw_device $device
    refresh_hw_device -update_hw_probes false $device
    puts "PASS: detected FPGA $device on [current_hw_target]"
    # Match the GUI's Micron entry (alias: N25Q128 3.3V).
    if {$mode eq "flash"} {
        set parts [get_cfgmem_parts -quiet mt25ql128-spi-x1_x2_x4]
        if {[llength $parts] != 1} { error "Configuration memory part not found or ambiguous: $parts" }
        create_hw_cfgmem -hw_device $device [lindex $parts 0]
        set cfgmem [get_property PROGRAM.HW_CFGMEM $device]
        puts "Configuration memory: mt25ql128-spi-x1_x2_x4, 128 Mbit, offset 0"
    }
    if {$action eq "program"} {
        if {$mode eq "sram"} {
            set_property PROGRAM.FILE [file normalize $bitstream] $device
            program_hw_devices -type bin $device
        } else {
            set_property PROGRAM.ADDRESS_RANGE use_file $cfgmem
            set_property PROGRAM.FILES [list [file normalize $bitstream]] $cfgmem
            set_property PROGRAM.BIN_OFFSET 0 $cfgmem
            set_property PROGRAM.UNUSED_PIN_TERMINATION pull-none $cfgmem
            set_property PROGRAM.BLANK_CHECK 0 $cfgmem
            set_property PROGRAM.ERASE 1 $cfgmem
            set_property PROGRAM.CFG_PROGRAM 1 $cfgmem
            set_property PROGRAM.VERIFY 1 $cfgmem
            # Load the indirect SPI programming bridge, then erase/write/verify.
            create_hw_bitstream -hw_device $device [get_property PROGRAM.HW_CFGMEM_BITFILE $device]
            program_hw_devices $device
            program_hw_cfgmem -hw_cfgmem $cfgmem
            boot_hw_device $device
        }
        refresh_hw_device -update_hw_probes false $device
        puts "PASS: $mode programming completed for $device"
    }

} finally {
    catch {close_hw_target}
    catch {disconnect_hw_server}
    close_hw_manager
}
exit
