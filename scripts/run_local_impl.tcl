set hardware_root [file dirname [file dirname [file normalize [info script]]]]
set output [file join $hardware_root build output_local]
set project_dir [file join $output project]
set project_file [file join $project_dir fpga-gpu.xpr]

set jobs 8
if {[info exists ::env(VIVADO_JOBS)]} { set jobs $::env(VIVADO_JOBS) }

puts "=== Opening Project: $project_file ==="
open_project $project_file

# Ensure all source files in rtl/ are up to date
remove_files -quiet [get_files -quiet *gpu_pkg.sv]
remove_files -quiet [get_files -quiet *gpu_defines.vh]

set new_file [file join $hardware_root rtl sm dynamic_coalescing_engine.sv]
if {[file exists $new_file]} {
    add_files -norecurse -fileset sources_1 $new_file
}
set defines_file [file join $hardware_root rtl common gpu_defines.vh]
if {[file exists $defines_file]} {
    add_files -norecurse -fileset sources_1 $defines_file
    set_property file_type "Verilog Header" [get_files -quiet $defines_file]
}
set_property include_dirs [list [file join $hardware_root rtl common]] [get_filesets sources_1]
update_compile_order -fileset sources_1

puts "=== Resetting and Launching synth_1 (jobs=$jobs) ==="
reset_run -quiet impl_1
reset_run synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "Synthesis failed! Check [get_property DIRECTORY [get_runs synth_1]]/runme.log"
}
puts "=== Synthesis completed successfully ==="

puts "=== Resetting and Launching impl_1 (route_design, jobs=$jobs) ==="
reset_run impl_1
launch_runs impl_1 -to_step route_design -jobs $jobs
wait_on_run impl_1
if {![string match "*route_design Complete*" [get_property STATUS [get_runs impl_1]]]} {
    error "Implementation/Routing failed! Check [get_property DIRECTORY [get_runs impl_1]]/runme.log"
}
puts "=== Routing completed successfully ==="

puts "=== Opening impl_1 run to export checkpoint and reports ==="
open_run impl_1
set routed_dcp [file join $output routed.dcp]
write_checkpoint -force $routed_dcp
set timing_rpt [file join $output timing.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -max_paths 50 -file $timing_rpt
set util_rpt [file join $output utilization.rpt]
report_utilization -hierarchical -file $util_rpt

puts "=== Saved routed.dcp to: $routed_dcp ==="
puts "=== Saved timing report to: $timing_rpt ==="
close_design
close_project
puts "=== Finished local implementation successfully! ==="

