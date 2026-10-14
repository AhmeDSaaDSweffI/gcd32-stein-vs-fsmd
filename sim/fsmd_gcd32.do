# ============================================================================
# fsmd_gcd32.do : FSMD core (rtl/fsmd_gcd32.v) with its testbench
#                 (tb/tb_fsmd_gcd32.v)
# ----------------------------------------------------------------------------
# Run from the sim/ folder of the repository:
#   vsim -c -do fsmd_gcd32.do    batch: the whole testbench, transcript in fsmd_gcd32.log
#   vsim    -do fsmd_gcd32.do    GUI:   waveform of gcd(14, 161); type "run -all"
#                                       to run the rest of the testbench
# ============================================================================
if {![file exists ../rtl/fsmd_gcd32.v]} { error "fsmd_gcd32.do: run it from the sim/ folder of the repository" }
if {[batch_mode]} { onerror {quit -f -code 1} }
onbreak {resume}

# ---- Compile ----
if {[file exists work]} { vdel -lib work -all }
vlib work
vmap work work
vlog -work work ../rtl/fsmd_gcd32.v ../tb/tb_fsmd_gcd32.v

file delete -force fsmd_gcd32.log
transcript file fsmd_gcd32.log

# ---- Batch: whole testbench ----
if {[batch_mode]} {
    # +acc keeps the signals visible to $dumpvars (fsmd_gcd32.vcd)
    vsim -t 1ps -voptargs=+acc -onfinish stop work.tb_fsmd_gcd32
    run -all
    quit -sim
    if {![info exists regression]} { quit -f }
} else {
    # ---- GUI: gcd(14, 161) ----
    vsim -t 1ps -voptargs=+acc -onfinish stop work.tb_fsmd_gcd32
    radix -unsigned
    radix define fsmd_state {
        1'b0 "IDLE",
        1'b1 "CALC",
        -default binary
    }

    set tb /tb_fsmd_gcd32
    add wave -noupdate -divider "Inputs"
    add wave -noupdate -radix binary   $tb/clk
    add wave -noupdate -radix binary   $tb/rst_n
    add wave -noupdate -radix binary   $tb/start
    add wave -noupdate -radix unsigned $tb/a_in
    add wave -noupdate -radix unsigned $tb/b_in
    add wave -noupdate -divider "Controller"
    add wave -noupdate -radix fsmd_state -label state $tb/dut/state
    add wave -noupdate -radix binary   -label load $tb/dut/load
    add wave -noupdate -radix binary   -label swap $tb/dut/swap
    add wave -noupdate -radix binary   -label sub  $tb/dut/sub
    add wave -noupdate -radix binary   -label fin  $tb/dut/fin
    add wave -noupdate -divider "Datapath"
    add wave -noupdate -radix unsigned -label dut/a $tb/dut/a
    add wave -noupdate -radix unsigned -label dut/b $tb/dut/b
    add wave -noupdate -radix binary   -label dut/a_lt_b $tb/dut/a_lt_b
    add wave -noupdate -radix binary   -label dut/b_zero $tb/dut/b_zero
    add wave -noupdate -divider "Output"
    add wave -noupdate -radix binary   $tb/done
    add wave -noupdate -radix unsigned $tb/gcd_out
    configure wave -signalnamewidth 1 -namecolwidth 150 -valuecolwidth 90 -timelineunits ns

    # Run until the first operation, gcd(14, 161), is done
    when -label first_done "$tb/done == 1" { stop }
    run -all
    nowhen first_done
    quietly set t_done [expr {[lindex $now 0] / 1000}]
    run 30 ns
    WaveRestoreCursors [list done "$t_done ns" 0]
    wave zoom range 0ns [expr {$t_done + 30}]ns
    echo "gcd(14, 161) done at $t_done ns. Type \"run -all\" to run the rest of the testbench."
}
