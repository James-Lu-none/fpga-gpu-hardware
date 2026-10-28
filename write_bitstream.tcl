# Vivado 2026.1 supports at most eight threads per process.
set cpu_count [string trim [exec nproc]]
set_param general.maxThreads [expr {min(8, $cpu_count)}]
set hardware_root [file dirname [file normalize [info script]]]
set output [file join $hardware_root build output]
if {[info exists ::env(CI_OUTPUT_DIR)]} { set output [file normalize $::env(CI_OUTPUT_DIR)] }
file mkdir $output
open_checkpoint $output/routed.dcp
report_drc -file $output/bitstream-drc.rpt
if {[llength [get_drc_violations -filter {SEVERITY == Error}]] > 0} { error "DRC errors found" }
write_bitstream -force -bin_file $output/top.bit
puts "PASS: bitstream generated from routed checkpoint."
exit
