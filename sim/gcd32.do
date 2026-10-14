# ============================================================================
# gcd32.do : Stein core (rtl/gcd32.v) with its Verilog testbench (tb/tb_gcd32.v)
# ----------------------------------------------------------------------------
# Run from the sim/ folder of the repository:
#   vsim -c -do gcd32.do    batch: the whole testbench, transcript in gcd32.log
#   vsim    -do gcd32.do    GUI:   waveform of gcd(14, 161); type "run -all"
#                                  to run the rest of the testbench
# ============================================================================
if {![file exists ../rtl/gcd32.v]} { error "gcd32.do: run it from the sim/ folder of the repository" }
if {[batch_mode]} { onerror {quit -f -code 1} }
onbreak {resume}

# ---- Compile ----
if {[file exists work]} { vdel -lib work -all }
vlib work
vmap work work
vlog -work work ../rtl/gcd32.v ../tb/tb_gcd32.v

file delete -force gcd32.log
transcript file gcd32.log

# ---- Batch: whole testbench ----
if {[batch_mode]} {
    # +acc keeps the signals visible to $dumpvars (gcd32.vcd)
    vsim -t 1ps -voptargs=+acc -onfinish stop work.tb_gcd32
    run -all
    quit -sim
    if {![info exists regression]} { quit -f }
} else {
    # ---- GUI: gcd(14, 161) ----
    vsim -t 1ps -voptargs=+acc -onfinish stop work.tb_gcd32
    radix -unsigned

    add wave -noupdate -divider "Inputs"
    add wave -noupdate -radix binary   /tb_gcd32/clk
    add wave -noupdate -radix binary   /tb_gcd32/rst_n
    add wave -noupdate -radix binary   /tb_gcd32/start
    add wave -noupdate -radix unsigned /tb_gcd32/a_in
    add wave -noupdate -radix unsigned /tb_gcd32/b_in
    add wave -noupdate -divider "gcd32 (Stein)"
    add wave -noupdate -radix binary   /tb_gcd32/busy
    add wave -noupdate -radix unsigned -label dut/a /tb_gcd32/dut/a
    add wave -noupdate -radix unsigned -label dut/b /tb_gcd32/dut/b
    add wave -noupdate -radix unsigned -label dut/k /tb_gcd32/dut/k
    add wave -noupdate -radix binary   -label dut/a_lt_b /tb_gcd32/dut/a_lt_b
    add wave -noupdate -radix binary   /tb_gcd32/done
    add wave -noupdate -radix unsigned /tb_gcd32/gcd_out
    configure wave -signalnamewidth 1 -namecolwidth 150 -valuecolwidth 90 -timelineunits ns

    # Run until the first operation, gcd(14, 161), is done
    when -label first_done {/tb_gcd32/done == 1} { stop }
    run -all
    nowhen first_done
    quietly set t_done [expr {[lindex $now 0] / 1000}]
    run 30 ns
    WaveRestoreCursors [list done "$t_done ns" 0]
    wave zoom range 0ns [expr {$t_done + 30}]ns
    echo "gcd(14, 161) done at $t_done ns. Type \"run -all\" to run the rest of the testbench."
}
