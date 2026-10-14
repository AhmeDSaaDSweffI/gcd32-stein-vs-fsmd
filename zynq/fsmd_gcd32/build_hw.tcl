# ============================================================================
# build_hw.tcl : batch Vivado flow for the fsmd_gcd32 AXI accelerator (Zybo Z7-20)
# ----------------------------------------------------------------------------
# Usage (from any directory):
#   vivado -mode batch -nojournal -log build/vivado_hw.log -source build_hw.tcl
#   JOBS=4 vivado -mode batch -source build_hw.tcl      # limit parallel jobs
#
# Steps:
#   1. Package fsmd_gcd32 + fsmd_gcd32_axi as an IP
#      (build/ip_repo, user.org:user:fsmd_gcd32_axi:1.0)
#   2. Block design: Zynq PS7 (Zybo Z7-20 board preset) + GCD IP on M_AXI_GP0,
#      clocks/resets/interconnect via connection automation, GCD at 0x43C0_0000
#   3. HDL wrapper, synthesis, implementation, bitstream, timing check
#   4. Export build/fsmd_gcd_zynq.xsa (bitstream included) and build/fsmd_gcd_zynq.bit
#
# To retarget another clg400 board, change ::board_part below and add that
# board's files under zynq/board_files/ (or set the PS7 configuration by hand).
# ============================================================================

set here      [file dirname [file normalize [info script]]]
set root      [file normalize [file join $here .. ..]]
set rtl_dir   [file join $root rtl]
set axi_dir   [file join $root axi]
set board_dir [file join $root zynq board_files]
set build     [file join $here build]
set ip_repo   [file join $build ip_repo]
set proj_dir  [file join $build vivado]
set xsa_file  [file join $build fsmd_gcd_zynq.xsa]
set bit_file  [file join $build fsmd_gcd_zynq.bit]

set part       xc7z020clg400-1
set board_part digilentinc.com:zybo-z7-20:part0:1.2
set gcd_base   0x43C00000

if {[info exists ::env(JOBS)]} {
    set jobs $::env(JOBS)
} elseif {[catch {exec nproc} jobs]} {
    set jobs 4
}

proc banner {msg} { puts "\n==== $msg ====" }

proc check_run {run} {
    if {[get_property PROGRESS [get_runs $run]] ne "100%"} {
        error "$run failed: [get_property STATUS [get_runs $run]]\
               (see [get_property DIRECTORY [get_runs $run]]/runme.log)"
    }
}

file mkdir $build
set_param board.repoPaths [list $board_dir]
if {[get_board_parts -quiet $board_part] eq ""} {
    error "Board part $board_part not found in $board_dir"
}

# ----------------------------------------------------------------------------
# 1. Package the RTL as an IP
# ----------------------------------------------------------------------------
banner "Packaging fsmd_gcd32_axi IP"
file delete -force $ip_repo [file join $build ip_pkg]
create_project -force ip_pkg [file join $build ip_pkg] -part $part
add_files -norecurse [list [file join $rtl_dir fsmd_gcd32.v] [file join $axi_dir fsmd_gcd32_axi.v]]
set_property top fsmd_gcd32_axi [current_fileset]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $ip_repo -vendor user.org -library user \
    -taxonomy /UserIP -import_files -set_current true
set core [ipx::current_core]
set_property -dict [list \
    name          fsmd_gcd32_axi \
    version       1.0 \
    core_revision 1 \
    display_name  {FSMD GCD32 AXI4-Lite accelerator} \
    description   {32-bit subtraction-based Euclid GCD (FSMD) with an AXI4-Lite register interface} \
] $core
set_property supported_families {zynq Production} $core
ipx::associate_bus_interfaces -busif s_axi -clock s_axi_aclk $core
# One 4 KB register window
set_property range 4096 [ipx::get_address_blocks -of_objects \
    [ipx::get_memory_maps s_axi -of_objects $core]]
ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::check_integrity $core
ipx::save_core $core
close_project

# ----------------------------------------------------------------------------
# 2. Project and block design
# ----------------------------------------------------------------------------
banner "Creating block design"
file delete -force $proj_dir
create_project -force fsmd_gcd_zynq $proj_dir -part $part
set_property board_part $board_part [current_project]
set_property target_language Verilog [current_project]
set_property ip_repo_paths [list $ip_repo] [current_project]
update_ip_catalog -rebuild

create_bd_design system

# Zynq PS: DDR, MIO, PS clock and UART1 (MIO 48/49) come from the board preset
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} \
    $ps7
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0            {1} \
    CONFIG.PCW_EN_CLK0_PORT             {1} \
    CONFIG.PCW_EN_RST0_PORT             {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
] $ps7

# GCD accelerator; automation adds the AXI interconnect, proc_sys_reset and
# connects FCLK_CLK0 / FCLK_RESET0_N
create_bd_cell -type ip -vlnv user.org:user:fsmd_gcd32_axi:1.0 gcd
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config {Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} Master {/ps7/M_AXI_GP0} \
             Slave {/gcd/s_axi} ddr_seg {Auto} intc_ip {New AXI Interconnect} master_apm {0}} \
    [get_bd_intf_pins gcd/s_axi]

# Fixed address so main.c can use a known base address
assign_bd_address
set seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps7/Data] -filter {NAME =~ "*gcd*"}]
if {[llength $seg] != 1} { error "Expected one address segment for gcd, got '$seg'" }
set_property range  4K        $seg
set_property offset $gcd_base $seg
puts "GCD address segment: $seg  offset=[get_property OFFSET $seg]  range=[get_property RANGE $seg]"

validate_bd_design
save_bd_design

set bd_file [get_files system.bd]
generate_target all $bd_file
add_files -norecurse [make_wrapper -files $bd_file -top]
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

# ----------------------------------------------------------------------------
# 3. Synthesis, implementation, bitstream
# ----------------------------------------------------------------------------
banner "Synthesis ($jobs jobs)"
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
check_run synth_1

banner "Implementation and bitstream"
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
check_run impl_1

open_run impl_1
report_timing_summary -file [file join $build timing_summary.rpt]
report_utilization    -file [file join $build utilization.rpt]
report_utilization    -hierarchical -file [file join $build utilization_hier.rpt]
report_power          -file [file join $build power.rpt]
set wns [get_property SLACK [get_timing_paths -setup -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -hold  -max_paths 1]]
puts "Timing: WNS = $wns ns, WHS = $whs ns"
if {$wns < 0 || $whs < 0} {
    error "Timing not met (see [file join $build timing_summary.rpt])"
}

# ----------------------------------------------------------------------------
# 4. Export hardware
# ----------------------------------------------------------------------------
banner "Exporting hardware"
write_hw_platform -fixed -include_bit -force -file $xsa_file
file copy -force [file join [get_property DIRECTORY [get_runs impl_1]] system_wrapper.bit] $bit_file

puts "\nXSA       : $xsa_file"
puts "Bitstream : $bit_file"
puts "BUILD_HW OK"
