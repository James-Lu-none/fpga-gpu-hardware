# report_logic_levels.tcl
# Extract and rank the longest combinational paths (Logic Levels / LUT Depth) across the design.
# Usage in Vivado:
#   source scripts/report_logic_levels.tcl
# Or batch mode:
#   vivado -mode batch -notrace -source scripts/report_logic_levels.tcl -tclargs [checkpoint.dcp] [max_paths]

set dcp_file ""
set max_paths 50

if {[llength $argv] > 0} {
    set dcp_file [lindex $argv 0]
}
if {[llength $argv] > 1} {
    set max_paths [lindex $argv 1]
}

if {$dcp_file ne "" && [file exists $dcp_file]} {
    puts "=== Opening checkpoint: $dcp_file ==="
    open_checkpoint $dcp_file
}

puts "\n================================================================================"
puts "  1. DESIGN-WIDE LOGIC LEVEL DISTRIBUTION (report_design_analysis)"
puts "================================================================================"
catch {
    report_design_analysis -logic_level_distribution -logic_levels 1-16
}

puts "\n================================================================================"
puts "  2. TOP WORST COMBINATIONAL PATHS (RANKED BY LOGIC LEVELS)"
puts "================================================================================"

# Collect timing paths across userclk1 and other clocks
set paths [get_timing_paths -max_paths 1000 -delay_type max -nworst 1]
if {[llength $paths] == 0} {
    puts "No timing paths found in the current design."
    return
}

# Collect paths and build a dictionary sorted by logic levels
set path_records {}
foreach p $paths {
    set levels [get_property LOGIC_LEVELS $p]
    set slack [get_property SLACK $p]
    set datapath [get_property DATAPATH_DELAY $p]
    set logic_delay [get_property DATAPATH_LOGIC_DELAY $p]
    set route_delay [get_property DATAPATH_NET_DELAY $p]
    set startpoint [get_property STARTPOINT_PIN $p]
    set endpoint [get_property ENDPOINT_PIN $p]
    set clk_group [get_property GROUP $p]
    
    lappend path_records [list $levels $slack $datapath $logic_delay $route_delay $clk_group $startpoint $endpoint]
}

# Sort paths descending by logic levels, then ascending by slack
set sorted_records [lsort -decreasing -integer -index 0 $path_records]

puts [format "%-4s | %-6s | %-8s | %-9s | %-12s | %-12s | %-10s | %s" \
    "Rank" "Levels" "Slack" "DataDelay" "Logic(Delay%)" "Route(Delay%)" "Clock" "Path (Start -> End)"]
puts [string repeat "-" 120]

set count 0
array set module_hotspots {}

foreach rec $sorted_records {
    if {$count >= $max_paths} { break }
    incr count
    
    set levels [lindex $rec 0]
    set slack [lindex $rec 1]
    set datapath [lindex $rec 2]
    set logic_d [lindex $rec 3]
    set route_d [lindex $rec 4]
    set clk [lindex $rec 5]
    set start [lindex $rec 6]
    set end [lindex $rec 7]
    
    set logic_pct 0
    set route_pct 0
    if {$datapath > 0} {
        set logic_pct [expr {int(($logic_d / $datapath) * 100.0)}]
        set route_pct [expr {int(($route_d / $datapath) * 100.0)}]
    }

    # Extract module category from endpoint
    set mod_prefix "other"
    if {[regexp {u_gpu_top/u_gpc/(gen_sm_array\[\d+\]\.u_sm/[^/]+/[^/]+)} $end match sub]} {
        set mod_prefix $sub
    } elseif {[regexp {u_gpu_top/u_gpc/(gen_sm_array\[\d+\]\.u_sm/[^/]+)} $end match sub]} {
        set mod_prefix $sub
    } elseif {[regexp {u_gpu_top/u_gpc/([^/]+)} $end match sub]} {
        set mod_prefix $sub
    } elseif {[regexp {u_gpu_top/([^/]+)} $end match sub]} {
        set mod_prefix $sub
    } elseif {[regexp {([^/]+)} $end match sub]} {
        set mod_prefix $sub
    }
    
    if {![info exists module_hotspots($mod_prefix)]} {
        set module_hotspots($mod_prefix) 0
    }
    incr module_hotspots($mod_prefix)

    set severity "      "
    if {$levels >= 10} {
        set severity {[CRIT]}
    } elseif {$levels >= 7} {
        set severity {[WARN]}
    } else {
        set severity {[PASS]}
    }

    puts [format "%-4d %s | %-4d   | %-7.3fns | %-8.3fns | %-5.2fns (%2d%%) | %-5.2fns (%2d%%) | %-10s | %s -> %s" \
        $count $severity $levels $slack $datapath $logic_d $logic_pct $route_d $route_pct $clk $start $end]
}

puts "\n================================================================================"
puts "  3. TOP BOTTLENECK MODULES (Paths with Highest Logic Levels)"
puts "================================================================================"
puts [format "%-50s | %-10s" "Module Hierarchy" "Path Count"]
puts [string repeat "-" 65]

set mod_list {}
foreach {mod hits} [array get module_hotspots] {
    lappend mod_list [list $hits $mod]
}
set mod_list [lsort -decreasing -integer -index 0 $mod_list]
foreach item $mod_list {
    puts [format "%-50s | %-10d" [lindex $item 1] [lindex $item 0]]
}