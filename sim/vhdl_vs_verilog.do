# ============================================================================
# vhdl_vs_verilog.do : the VHDL Stein core (rtl/gcd32.vhd) in lockstep with the
#                      Verilog one (rtl/gcd32.v), tb/tb_gcd32_vhdl.vhd
# ----------------------------------------------------------------------------
# Both cores get the same clock, reset and operands, and their outputs are
# compared on every clock cycle (mixed-language simulation: the Verilog core
# is compiled into library verilog_lib).
#
# Run from the sim/ folder of the repository:
#   vsim -c -do vhdl_vs_verilog.do    batch: the whole testbench, transcript in
#                                     vhdl_vs_verilog.log
#   vsim    -do vhdl_vs_verilog.do    GUI:   waveform of gcd(14, 161) on both cores
# ============================================================================
if {![file exists ../rtl/gcd32.vhd]} { error "vhdl_vs_verilog.do: run it from the sim/ folder of the repository" }
if {[batch_mode]} { onerror {quit -f -code 1} }
onbreak {resume}

# ---- Compile ----
foreach lib {work verilog_lib} {
    if {[file exists $lib]} { vdel -lib $lib -all }
    vlib $lib
    vmap $lib $lib
}
vlog -work verilog_lib ../rtl/gcd32.v
vcom -2008 -work work ../rtl/gcd32.vhd ../tb/tb_gcd32_vhdl.vhd

file delete -force vhdl_vs_verilog.log
transcript file vhdl_vs_verilog.log

# ---- Batch: whole testbench ----
# (-t 1ps: the Verilog core declares `timescale 1ns/1ps)
if {[batch_mode]} {
    vsim -t 1ps -L verilog_lib work.tb_gcd32_vhdl
    run -all
    quit -sim
    if {![info exists regression]} { quit -f }
} else {
    # ---- GUI: gcd(14, 161) ----
    vsim -t 1ps -voptargs=+acc -L verilog_lib work.tb_gcd32_vhdl
    radix -unsigned

    set tb /tb_gcd32_vhdl
    add wave -noupdate -divider "Inputs"
    add wave -noupdate -radix binary   $tb/clk
    add wave -noupdate -radix binary   $tb/rst_n
    add wave -noupdate -radix binary   $tb/start
    add wave -noupdate -radix unsigned $tb/a_in
    add wave -noupdate -radix unsigned $tb/b_in
    add wave -noupdate -divider "VHDL gcd32 (dut)"
    add wave -noupdate -color Cyan -radix binary   $tb/busy
    add wave -noupdate -color Cyan -radix unsigned -label dut/a $tb/dut/a
    add wave -noupdate -color Cyan -radix unsigned -label dut/b $tb/dut/b
    add wave -noupdate -color Cyan -radix unsigned -label dut/k $tb/dut/k
    add wave -noupdate -color Cyan -radix binary   $tb/done
    add wave -noupdate -color Cyan -radix unsigned $tb/gcd_out
    add wave -noupdate -divider "Verilog gcd32 (ref)"
    add wave -noupdate -color Orange -radix binary   $tb/busy_v
    add wave -noupdate -color Orange -radix binary   $tb/done_v
    add wave -noupdate -color Orange -radix unsigned $tb/gcd_out_v
    add wave -noupdate -radix unsigned $tb/mismatches
    configure wave -signalnamewidth 1 -namecolwidth 150 -valuecolwidth 90 -timelineunits ns

    # Run until the first operation, gcd(14, 161), is done
    when -label first_done "$tb/done == '1'" { stop }
    run -all
    nowhen first_done
    quietly set t_done [expr {[lindex $now 0] / 1000}]
    run 30 ns
    WaveRestoreCursors [list done "$t_done ns" 0]
    wave zoom range 0ns [expr {$t_done + 30}]ns
    echo "gcd(14, 161) done at $t_done ns. Type \"run -all\" to run the rest of the testbench."
}
