# ============================================================================
# regression.do : all seven testbenches in batch mode, with a pass/fail summary
# ----------------------------------------------------------------------------
# Run from the sim/ folder of the repository:
#   vsim -c -do regression.do
#
# Each test writes its transcript to <test>.log. A test passes when its
# testbench prints "ALL TESTS PASSED" (each one checks every result against a
# Euclid reference; all but tb_gcd32 (Verilog and VHDL) also check every
# latency against the cycle model of the core).
# The summary is printed at the end and saved in regression.log; the exit
# code is the number of failed tests (0 = all passed).
# ============================================================================
if {![batch_mode]} { error "regression.do runs in batch mode: vsim -c -do regression.do" }
if {![file exists ../rtl/gcd32.v]} { error "regression.do: run it from the sim/ folder of the repository" }

quietly set regression 1
quietly set tests {
    gcd32           "Stein core, Verilog testbench"
    gcd32_vhdl      "Stein core in VHDL, VHDL testbench"
    vhdl_vs_verilog "VHDL core vs Verilog core, lockstep"
    fsmd_gcd32      "FSMD core"
    compare         "Both cores, same inputs"
    gcd32_axi       "Stein core behind AXI4-Lite"
    fsmd_gcd32_axi  "FSMD core behind AXI4-Lite"
}

quietly set lines {}
quietly set failed 0
foreach {t what} $tests {
    quietly set t0 [clock seconds]
    do $t.do
    transcript file ""

    # Pass = the testbench printed ALL TESTS PASSED, and no TESTS FAILED
    quietly set fh [open $t.log]
    quietly set txt [read $fh]
    close $fh
    if {[string match "*ALL TESTS PASSED*" $txt] && ![string match "*TESTS FAILED*" $txt]} {
        quietly set result PASS
    } else {
        quietly set result FAIL
        incr failed
    }
    # The testbench's own summary line, e.g. "tests = 10011   errors = 0"
    quietly set detail ""
    regexp -line {^# (tests = [^\n]*|checks = [^\n]*)$} $txt -> detail
    lappend lines [format "%-16s %-38s %-4s %4d s   %s" \
        $t $what $result [expr {[clock seconds] - $t0}] [string trim $detail]]
}

quietly set ntests [expr {[llength $tests] / 2}]
if {$failed == 0} {
    quietly set verdict "ALL $ntests TESTBENCHES PASSED"
} else {
    quietly set verdict "$failed OF $ntests TESTBENCHES FAILED"
}
quietly set date [clock format [clock seconds] -format {%Y-%m-%d %H:%M}]
quietly set summary [concat [list "" "==== Regression summary ($date) ===="] $lines [list $verdict]]
foreach l $summary { echo $l }
quietly set fh [open regression.log w]
puts $fh [join $summary "\n"]
close $fh

quit -f -code $failed
