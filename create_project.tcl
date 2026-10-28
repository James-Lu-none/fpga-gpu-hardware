# Vivado 2026.1 supports at most eight threads per process.
set cpu_count [string trim [exec nproc]]
set_param general.maxThreads [expr {min(8, $cpu_count)}]
# Shared project recipe: source in the GUI Tcl console or use -source in batch.
set hardware_root [file dirname [file normalize [info script]]]
set project_dir [file join $hardware_root build vivado]
if {[info exists ::env(FPGAGPU_PROJECT_DIR)]} {
    set project_dir [file normalize $::env(FPGAGPU_PROJECT_DIR)]
}
# No -force: never overwrite an existing GUI project silently.
create_project fpga-gpu $project_dir -part xc7a200tfbg484-2
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
# Refresh the source list for GUI and batch builds from one definition.
namespace eval fpgagpu_sources {
    proc collect {directory extensions} {
        set result {}
        foreach path [lsort [glob -nocomplain -directory $directory *]] {
            if {[file isdirectory $path]} {
                lappend result {*}[collect $path $extensions]
            } elseif {[file extension $path] in $extensions} {
                lappend result $path
            }
        }
        return $result
    }
}
set hardware_root [file dirname [file normalize [info script]]]
set rtl_files [fpgagpu_sources::collect [file join $hardware_root rtl] {.sv .v .vh .svh .vhd .vhdl .mem .hex}]
if {![llength $rtl_files]} { error "No RTL sources found" }
add_files -norecurse -fileset sources_1 $rtl_files
set headers [fpgagpu_sources::collect [file join $hardware_root rtl] {.vh .svh}]
set include_dirs [list [file join $hardware_root rtl]]
foreach header $headers {
    set_property file_type {Verilog Header} [get_files $header]
    lappend include_dirs [file dirname $header]
}
set_property include_dirs [lsort -unique $include_dirs] [get_filesets sources_1]
set_property include_dirs [lsort -unique $include_dirs] [get_filesets sim_1]
set_property top top [get_filesets sources_1]
set constraints [fpgagpu_sources::collect [file join $hardware_root constrs] {.xdc}]
if {![llength $constraints]} { error "No constraints found" }
add_files -norecurse -fileset constrs_1 $constraints
set timing [file join $hardware_root constrs timing.xdc]
if {[file exists $timing]} { set_property PROCESSING_ORDER LATE [get_files $timing] }
update_compile_order -fileset sources_1

# Import only the IPs used by the original project. Keep XCI and auxiliary
# inputs versioned; output products are regenerated in the build directory.
foreach name {axi_dwidth_converter_0 axi_clock_converter_0 axi_crossbar_0
              xdma_0 blk_mem_gen_0 axi_uartlite_0 axi_crossbar_1
              axi_bram_ctrl_0 mig_7series_0} {
    set xci [file join $hardware_root fpga-gpu.srcs sources_1 ip $name ${name}.xci]
    if {![file exists $xci]} { error "Missing IP configuration: $xci" }
    import_ip -files [list $xci]
}
report_ip_status
# Deliberately do not auto-upgrade IPs; version changes require review.
generate_target all [get_ips]
# create_ip_run accepts only one IP per invocation.
foreach ip [get_ips] {
    create_ip_run $ip
}
update_compile_order -fileset sources_1
puts "Project created: [file join $project_dir fpga-gpu.xpr]"
