# ============================================================================
# compare.do : both cores on the same inputs (tb/tb_compare.v)
# ----------------------------------------------------------------------------
# gcd32 (Stein) and fsmd_gcd32 (FSMD) share the clock, the reset and the
# operands; every vector reaches both on the same clock edge.
#
# Run from the sim/ folder of the repository:
#   vsim -c -do compare.do    batch: the whole testbench (sections 1..6),
#                             transcript in compare.log, plus tb_compare.vcd,
#                             random_tbmix.csv and random_board.csv
#   vsim    -do compare.do    GUI:   gcd(14, 161) on both cores from the same
#                             start edge (the waveform in docs/images)
#
# FSMD runs longer than 2^24 cycles are skipped and their latency is taken
# from the cycle model (see tb_compare.v). To change the limit:
#   vsim -c -do "set fsmd_limit 400000000; do compare.do"   (takes hours)
# ============================================================================
if {![file exists ../rtl/gcd32.v]} { error "compare.do: run it from the sim/ folder of the repository" }
if {[batch_mode]} { onerror {quit -f -code 1} }
onbreak {resume}

# ---- Compile ----
if {[file exists work]} { vdel -lib work -all }
vlib work
vmap work work
vlog -work work ../rtl/gcd32.v ../rtl/fsmd_gcd32.v ../tb/tb_compare.v

file delete -force compare.log
transcript file compare.log

quietly set plusargs {}
if {[info exists fsmd_limit]} { quietly lappend plusargs +fsmd_limit=$fsmd_limit }

# ---- Batch: whole testbench ----
if {[batch_mode]} {
    # +acc keeps the signals visible to $dumpvars (tb_compare.vcd)
    vsim -t 1ps -voptargs=+acc -onfinish stop {*}$plusargs work.tb_compare
    run -all
    quit -sim
    if {![info exists regression]} { quit -f }
} else {
    # ---- GUI: gcd(14, 161) on both cores ----
    vsim -t 1ps -voptargs=+acc -onfinish stop work.tb_compare
    radix -unsigned
    radix define fsmd_state {
        1'b0 "IDLE",
        1'b1 "CALC",
        -default binary
    }

    set tb /tb_compare
    add wave -noupdate -divider "Testbench (shared)"
    add wave -noupdate -radix binary   $tb/clk
    add wave -noupdate -radix binary   $tb/rst_n
    add wave -noupdate -radix unsigned $tb/a_in
    add wave -noupdate -radix unsigned $tb/b_in
    add wave -noupdate -divider "gcd32 (Stein)"
    add wave -noupdate -color Cyan -radix binary   $tb/start_s
    add wave -noupdate -color Cyan -radix binary   $tb/busy_s
    add wave -noupdate -color Cyan -radix unsigned -label u_stein/a $tb/u_stein/a
    add wave -noupdate -color Cyan -radix unsigned -label u_stein/b $tb/u_stein/b
    add wave -noupdate -color Cyan -radix unsigned -label u_stein/k $tb/u_stein/k
    add wave -noupdate -color Cyan -radix binary   $tb/done_s
    add wave -noupdate -color Cyan -radix unsigned $tb/gcd_s
    add wave -noupdate -divider "fsmd_gcd32 (FSMD)"
    add wave -noupdate -color Orange -radix binary     $tb/start_f
    add wave -noupdate -color Orange -radix fsmd_state -label u_fsmd/state $tb/u_fsmd/state
    add wave -noupdate -color Orange -radix ascii      $tb/fsmd_op
    add wave -noupdate -color Orange -radix unsigned   -label u_fsmd/a $tb/u_fsmd/a
    add wave -noupdate -color Orange -radix unsigned   -label u_fsmd/b $tb/u_fsmd/b
    add wave -noupdate -color Orange -radix binary     $tb/done_f
    add wave -noupdate -color Orange -radix unsigned   $tb/gcd_f
    configure wave -signalnamewidth 1 -namecolwidth 150 -valuecolwidth 90 -timelineunits ns

    # Run until both cores are done with gcd(14, 161): Stein first, then FSMD
    quietly set ::t_stein ""
    when -label stein_done "$tb/done_s == 1" {
        if {$::t_stein eq ""} { set ::t_stein [expr {[lindex $now 0] / 1000}] }
    }
    when -label fsmd_done "$tb/done_f == 1" { stop }
    run -all
    nowhen stein_done
    nowhen fsmd_done
    quietly set t_fsmd [expr {[lindex $now 0] / 1000}]
    run 30 ns
    WaveRestoreCursors [list {Stein done} "$::t_stein ns" 0] [list {FSMD done} "$t_fsmd ns" 0]
    wave zoom range 0ns [expr {$t_fsmd + 30}]ns
    echo "gcd(14, 161): Stein done at $::t_stein ns, FSMD done at $t_fsmd ns. Type \"run -all\" to run the rest of the testbench."
}
