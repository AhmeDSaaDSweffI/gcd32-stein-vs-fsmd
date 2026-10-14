# ============================================================================
# fsmd_gcd32_axi.do : FSMD core behind its AXI4-Lite wrapper
#                     (axi/fsmd_gcd32_axi.v), driven by the AXI master BFM of
#                     tb/tb_fsmd_gcd32_axi.v
# ----------------------------------------------------------------------------
# Run from the sim/ folder of the repository:
#   vsim -c -do fsmd_gcd32_axi.do    batch: the whole testbench (register map,
#                                    START handling, directed vectors, 64-bit
#                                    CYCLES counter, 3,000 random driver
#                                    sequences), transcript in fsmd_gcd32_axi.log
#   vsim    -do fsmd_gcd32_axi.do    GUI:   the first driver call, gcd(14, 161):
#                                    write A, write B, write CTRL = START, poll
#                                    STATUS, read RESULT, CYCLES and CYCLES_HI
# ============================================================================
if {![file exists ../axi/fsmd_gcd32_axi.v]} { error "fsmd_gcd32_axi.do: run it from the sim/ folder of the repository" }
if {[batch_mode]} { onerror {quit -f -code 1} }
onbreak {resume}

# ---- Compile ----
if {[file exists work]} { vdel -lib work -all }
vlib work
vmap work work
vlog -work work ../rtl/fsmd_gcd32.v ../axi/fsmd_gcd32_axi.v ../tb/tb_fsmd_gcd32_axi.v

file delete -force fsmd_gcd32_axi.log
transcript file fsmd_gcd32_axi.log

# ---- Batch: whole testbench ----
if {[batch_mode]} {
    vsim -t 1ps -onfinish stop work.tb_fsmd_gcd32_axi
    run -all
    quit -sim
    if {![info exists regression]} { quit -f }
} else {
    # ---- GUI: the gcd(14, 161) driver call ----
    vsim -t 1ps -voptargs=+acc -onfinish stop work.tb_fsmd_gcd32_axi
    radix -unsigned

    set tb /tb_fsmd_gcd32_axi
    add wave -noupdate -divider "AXI4-Lite write"
    add wave -noupdate -radix binary      $tb/clk
    add wave -noupdate -radix hexadecimal $tb/awaddr
    add wave -noupdate -radix binary      $tb/awvalid
    add wave -noupdate -radix binary      $tb/awready
    add wave -noupdate -radix unsigned    $tb/wdata
    add wave -noupdate -radix binary      $tb/wvalid
    add wave -noupdate -radix binary      $tb/bvalid
    add wave -noupdate -divider "AXI4-Lite read"
    add wave -noupdate -radix hexadecimal $tb/araddr
    add wave -noupdate -radix binary      $tb/arvalid
    add wave -noupdate -radix unsigned    $tb/rdata
    add wave -noupdate -radix binary      $tb/rvalid
    add wave -noupdate -divider "fsmd_gcd32_axi wrapper"
    add wave -noupdate -color Orange -radix binary   -label start_pulse $tb/dut/start_pulse
    add wave -noupdate -color Orange -radix binary   -label core_busy   $tb/dut/core_busy
    add wave -noupdate -color Orange -radix binary   -label core_done   $tb/dut/core_done
    add wave -noupdate -color Orange -radix unsigned -label core_gcd    $tb/dut/core_gcd
    add wave -noupdate -color Orange -radix unsigned -label cycles      $tb/dut/cycles
    configure wave -signalnamewidth 1 -namecolwidth 150 -valuecolwidth 90 -timelineunits ns

    # Find the gcd(14, 161) call: from the write of A = 14 to the end of the
    # CYCLES_HI read (araddr 0x1C), the last access of the driver sequence
    quietly set ::t_a ""
    quietly set ::t_end ""
    when -label call_a "$tb/dut/reg_a == 14" {
        if {$::t_a eq ""} { set ::t_a [expr {[lindex $now 0] / 1000}] }
    }
    when -label call_end "$tb/rvalid == 1 && $tb/rready == 1 && $tb/araddr == 28" {
        if {$::t_a ne "" && $::t_end eq ""} { set ::t_end [expr {[lindex $now 0] / 1000}]; stop }
    }
    run -all
    nowhen call_a
    nowhen call_end
    run 20 ns
    WaveRestoreCursors [list {A written} "$::t_a ns" 0] [list {CYCLES_HI read} "$::t_end ns" 0]
    wave zoom range [expr {$::t_a - 40}]ns [expr {$::t_end + 20}]ns
    echo "gcd(14, 161) driver call: A written at $::t_a ns, CYCLES_HI read at $::t_end ns. Type \"run -all\" to run the rest of the testbench."
}
