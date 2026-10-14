# ============================================================================
# synth_ooc.tcl : out-of-context synthesis + place & route of both GCD cores
#                 (gcd32 = Stein, fsmd_gcd32 = FSMD) for the circuit-size and
#                 Fmax comparison
# Usage  : run from any empty folder (reports and logs go there), e.g.
#          mkdir -p synth/run && cd synth/run
#          vivado -mode batch -nojournal -source ../synth_ooc.tcl
# Target : xc7z020clg400-1 (Zybo Z7-20), default synthesis and implementation
#          settings, two runs per core:
#            area : 10.0 ns clock, the 100 MHz PL clock of the board -> circuit size
#            fmax :  3.0 ns clock, deliberately too fast -> Fmax = 1 / (3.0 ns - WNS)
#          Only register-to-register paths are timed (no I/O constraints).
# Output : <run>_<core>/ reports and ooc_summary.txt in the current folder
#          (the saved run is results/synthesis/ooc_summary.txt)
# ============================================================================

set part  xc7z020clg400-1
set here  [file dirname [file normalize [info script]]]
set root  [file dirname $here]
set cores [list \
    gcd32      [file join $root rtl gcd32.v] \
    fsmd_gcd32 [file join $root rtl fsmd_gcd32.v]]
set runs  {area 10.0 fmax 3.0}

# First number after "| <name> |" in a report_utilization string
proc util_count {rpt name} {
    if {[regexp "\\|\\s*$name\\s*\\|\\s*(\\d+)" $rpt -> n]} { return $n }
    return 0
}

# "LUT6=40 FDRE=98 ..." from the Primitives table of report_utilization
proc primitives {rpt} {
    set out {}
    set on 0
    foreach line [split $rpt "\n"] {
        if {[string match "*Ref Name*" $line]} { set on 1; continue }
        if {$on && [regexp {^\|\s*(\S+)\s*\|\s*(\d+)\s*\|} $line -> name n]} {
            lappend out "$name=$n"
        }
    }
    return [join [lsort $out] " "]
}

set table   {}
set details {}
foreach {run period} $runs {
    foreach {top rtl} $cores {
        if {![file exists $rtl]} { error "synth_ooc.tcl: $rtl not found" }
        set dir ${run}_$top
        file mkdir $dir
        set fh [open $dir/clk.xdc w]
        puts $fh "create_clock -name clk -period $period \[get_ports clk\]"
        close $fh

        # a fresh in-memory project per run, so no source or clock carries over
        create_project -in_memory -part $part
        read_verilog $rtl
        read_xdc $dir/clk.xdc
        synth_design -top $top -part $part -mode out_of_context
        opt_design
        place_design
        phys_opt_design
        route_design

        report_utilization    -file $dir/utilization.rpt
        report_timing_summary -file $dir/timing_summary.rpt
        report_timing -max_paths 1 -file $dir/critical_path.rpt

        set rpt  [report_utilization -return_string]
        set path [get_timing_paths -max_paths 1 -setup]
        set wns  [get_property SLACK $path]
        set fmax [expr {1000.0 / ($period - $wns)}]
        set crit [report_timing -max_paths 1 -return_string]
        regexp {Logic Levels:\s*([^\n]*)} $crit -> levels
        regexp {Data Path Delay:\s*([\d.]+)ns} $crit -> ddelay

        lappend table [format "%-5s %-11s %6.1f %5s %6s %4s %7s %3s %3s %7s %5s %4s %8.3f %9.0f" \
            $run $top $period [util_count $rpt "Slice LUTs"] [util_count $rpt "LUT as Logic"] \
            [util_count $rpt "Slice Registers"] [util_count $rpt "CARRY4"] [util_count $rpt "F7 Muxes"] \
            [util_count $rpt "F8 Muxes"] [util_count $rpt "Slice"] [util_count $rpt "Block RAM Tile"] \
            [util_count $rpt "DSPs"] $wns $fmax]
        lappend details "primitives $run $top: [primitives $rpt]"
        lappend details [format "critical path %s %s: %s -> %s, data path %s ns, logic levels %s" \
            $run $top [get_property STARTPOINT_PIN $path] [get_property ENDPOINT_PIN $path] $ddelay \
            [string trim $levels]]
        close_project
    }
}

set lines [list \
    "# synth_ooc.tcl: out-of-context synthesis + place & route, Vivado [version -short], $part, [clock format [clock seconds] -format {%Y-%m-%d %H:%M}]" \
    "# area run: 10 ns clock (board PL clock); fmax run: 3 ns clock, Fmax = 1000 / (clock - WNS); post-route counts" \
    [format "%-5s %-11s %6s %5s %6s %4s %7s %3s %3s %7s %5s %4s %8s %9s" \
        run core clk_ns LUTs logic FFs CARRY4 F7 F8 Slices BRAM DSP WNS_ns Fmax_MHz]]
set lines [concat $lines $table $details]

set fh [open ooc_summary.txt w]
puts $fh [join $lines "\n"]
close $fh

puts "\n==== Out-of-context results (ooc_summary.txt) ===="
puts [join $lines "\n"]
