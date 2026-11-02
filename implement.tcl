# CI implementation entry point; source paths are relative to this script.
set hardware_root [file dirname [file normalize [info script]]]
set output [file join $hardware_root build output]
if {[info exists ::env(CI_OUTPUT_DIR)]} { set output [file normalize $::env(CI_OUTPUT_DIR)] }
file mkdir $output
set jobs [string trim [exec nproc]]
if {[info exists ::env(VIVADO_JOBS)]} { set jobs $::env(VIVADO_JOBS) }
if {![string is integer -strict $jobs] || $jobs < 1} { error "Invalid VIVADO_JOBS" }
set hardware_root [file dirname [file normalize [info script]]]
# Each CI invocation gets a clean generated project under the artifact workspace.
set ::env(FPGAGPU_PROJECT_DIR) [file join $output project]
source [file join $hardware_root create_project.tcl]
reset_run synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "Synthesis failed" }
# The VRF hardware failure occurred with ambiguous reset inference warnings.
# Stop before routing if this specific coding hazard returns.
set synth_log [open [file join [get_property DIRECTORY [get_runs synth_1]] runme.log] r]
set vrf_reset_warnings {}
while {[gets $synth_log line] >= 0} {
    if {[regexp {\[Synth 8-7137\].*(module vector_regfile|vector_regfile\.sv)} $line]} {
        lappend vrf_reset_warnings $line
    }
}
close $synth_log
if {[llength $vrf_reset_warnings]} {
    error "VRF reset inference is ambiguous:\n[join $vrf_reset_warnings \n]"
}
puts "PASS: VRF synthesis has no ambiguous reset warnings."
# Simulate the actual synthesized probe, rather than synthesizing a different
# standalone copy. All dependencies are inside this flat-port hierarchy.
if {[info exists ::env(FPGAGPU_HARDWARE_MODE)] && $::env(FPGAGPU_HARDWARE_MODE) eq "l2"} {
    open_run synth_1
    set probes [get_cells -hierarchical -filter {REF_NAME == vrf_probe || ORIG_REF_NAME == vrf_probe}]
    if {[llength $probes] != 1} { error "Expected one synthesized VRF probe, found: $probes" }
    # Report/check the exported interface before invoking XSim. Rebuilt
    # hierarchy alone does not guarantee that RTL ports survive optimization.
    set probe [lindex $probes 0]
    set probe_ports {}
    foreach pin [get_pins -of_objects $probe] {
        regsub {\[[0-9]+\]$} [get_property REF_PIN_NAME $pin] {} port_name
        lappend probe_ports $port_name
    }
    set probe_ports [lsort -unique $probe_ports]
    puts "VRF synthesized probe ports: $probe_ports"
    foreach required {clk rst_n write_enable write_addr read_addr write_data read_data} {
        if {[lsearch -exact $probe_ports $required] < 0} {
            error "VRF netlist interface lost port '$required'; actual ports: $probe_ports"
        }
    }
    set sim_dir [file join $output vrf-netlist]
    file mkdir $sim_dir
    write_verilog -force -mode funcsim -cell $probe -rename_top vrf_probe [file join $sim_dir vrf_probe_funcsim.v]
    close_design
    set previous_dir [pwd]
    cd $sim_dir
    try {
        foreach command [list \
            [list xvlog -work work --sv vrf_probe_funcsim.v [file join $hardware_root sim vrf_probe_tb.sv] [file join $::env(XILINX_VIVADO) data verilog src glbl.v]] \
            [list xelab -debug typical -L unisims_ver -s vrf_funcsim work.vrf_probe_tb work.glbl] \
            [list xsim vrf_funcsim -runall -log simulation.log]] {
            puts "RUN: VRF netlist simulation: $command"
            if {[catch {exec timeout --kill-after=5 300 {*}$command 2>@1} transcript]} {
                puts $transcript
                error "VRF netlist tool failed: [lindex $command 0]"
            }
            puts $transcript
        }
        set sim_log [open simulation.log r]
        set sim_text [read $sim_log]
        close $sim_log
        if {[string first "PASS: VRF probe functional test" $sim_text] < 0} {
            error "VRF synthesized netlist did not complete functional verification"
        }
        puts "PASS: VRF post-synthesis functional simulation."
    } finally {
        cd $previous_dir
    }
}
reset_run impl_1
launch_runs impl_1 -to_step route_design -jobs $jobs
wait_on_run impl_1
if {![string match "*route_design Complete*" [get_property STATUS [get_runs impl_1]]]} {
    error "Routing did not complete"
}
open_run impl_1
write_checkpoint -force $output/routed.dcp
report_utilization -hierarchical -file $output/utilization.rpt
report_timing_summary -delay_type min_max -report_unconstrained -file $output/timing.rpt
report_route_status -file $output/route.rpt
report_drc -file $output/drc.rpt
check_timing -verbose -file $output/check_timing.rpt

# Per-instance reports use literal name prefixes
set module_dir [file join $output modules]
file mkdir $module_dir
set manifest [open [file join $module_dir instances.tsv] w]
puts $manifest "report_id\tinstance\tinside_endpoints\toutside_endpoints"
# Include DSP cells explicitly: pipeline registers can be absorbed into DSPs.
set timing_cells [get_cells -hierarchical -filter {IS_PRIMITIVE == 1 && (IS_SEQUENTIAL == 1 || REF_NAME =~ DSP*)}]
set index 0
foreach instance [lsort [get_cells -hierarchical -filter {IS_PRIMITIVE == 0}]] {
    if {![regexp {[/.](u_sm|u_sp|u_mul)$} $instance -> kind]} { continue }
    set inside {}
    set outside {}
    set prefix "${instance}/"
    foreach cell $timing_cells {
        if {[string first $prefix $cell] == 0} {
            lappend inside $cell
        } else {
            lappend outside $cell
        }
    }
    set report_id [format "%s_%03d" [string range $kind 2 end] $index]
    incr index
    set dir [file join $module_dir $report_id]
    file mkdir $dir
    puts $manifest "$report_id\t$instance\t[llength $inside]\t[llength $outside]"
    report_utilization -cells [list $instance] -hierarchical -file $dir/utilization.rpt
    if {![llength $inside]} {
        puts "WARNING: No timing endpoints under $instance; see instances.tsv and global reports."
        continue
    }
    # Save endpoint names to make coverage/flattening effects reviewable.
    set endpoints [open $dir/endpoints.txt w]
    puts $endpoints [join $inside "\n"]
    close $endpoints
    set incoming [concat $outside [all_inputs]]
    set outgoing [concat $outside [all_outputs]]
    foreach {delay label} {max setup min hold} {
        # No negative-slack filter: passing paths remain visible.
        report_timing -delay_type $delay -from $inside -to $inside \
            -max_paths 20 -nworst 2 -file $dir/internal_${label}.rpt
        if {[llength $incoming]} {
            report_timing -delay_type $delay -from $incoming -to $inside \
                -max_paths 20 -nworst 2 -file $dir/incoming_${label}.rpt
        }
        if {[llength $outgoing]} {
            report_timing -delay_type $delay -from $inside -to $outgoing \
                -max_paths 20 -nworst 2 -file $dir/outgoing_${label}.rpt
        }
    }
}
close $manifest
if {$index == 0} {
    puts "WARNING: No SM/SP/MUL hierarchy matched; inspect synthesized hierarchy."
}

# Quality gates run only after all diagnostic reports have been written.
foreach delay_type {max min} {
    set paths [get_timing_paths -delay_type $delay_type -max_paths 1]
    if {[llength $paths] == 0} { error "No $delay_type timing paths found" }
    if {[get_property SLACK [lindex $paths 0]] < 0} { error "$delay_type timing failed" }
}
if {[llength [get_drc_violations -filter {SEVERITY == Error}]] > 0} { error "DRC errors found" }
close_project
puts "PASS: implementation, setup/hold timing and error-level DRC checks."
exit
