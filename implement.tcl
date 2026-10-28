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
