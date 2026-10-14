# ============================================================================
# run_sw.tcl : XSCT flow for the fsmd_gcd32 accelerator (Vitis 2021.1, Zybo Z7-20)
# ----------------------------------------------------------------------------
# Usage (from any directory):
#   xsct run_sw.tcl          build the software, then program and run the board
#   xsct run_sw.tcl build    create workspace, platform and app, build the ELF
#   xsct run_sw.tcl run      program the bitstream and run the existing ELF
#
# Input : build/fsmd_gcd_zynq.xsa from build_hw.tcl
# Output: build/vitis_ws/gcd_app/Release/gcd_app.elf
#
# The run step needs the board powered, a JTAG cable connected (on-board
# Digilent USB or a Platform Cable USB II) and the boot-mode jumper (JP5) on
# JTAG. Program output goes to PS UART1 at 115200 8N1 (run_all.sh captures it).
# ============================================================================

set here      [file dirname [file normalize [info script]]]
set build     [file join $here build]
set xsa       [file join $build fsmd_gcd_zynq.xsa]
set ws        [file join $build vitis_ws]
set platform  gcd_platform
set domain    standalone_domain
set app       gcd_app
set elf       [file join $ws $app Release $app.elf]
set hw_dir    [file join $ws $platform hw]

set gcd_base  0x43C00000
set gcd_id    0x47434432

set mode [expr {$argc > 0 ? [lindex $argv 0] : "all"}]
if {$mode ni {all build run}} {
    puts "usage: xsct run_sw.tcl \[all|build|run\]"
    exit 2
}

proc banner {msg} { puts "\n==== $msg ====" }

# ----------------------------------------------------------------------------
# Software build
# ----------------------------------------------------------------------------
proc build_sw {} {
    global here xsa ws platform domain app elf

    if {![file exists $xsa]} { error "$xsa not found, run build_hw.tcl first" }

    banner "Creating Vitis workspace $ws"
    file delete -force $ws
    setws $ws

    # Standalone BSP on CPU0; no FSBL is needed for JTAG boot
    platform create -name $platform -hw $xsa -no-boot-bsp
    domain create -name $domain -os standalone -proc ps7_cortexa9_0
    bsp config stdin  ps7_uart_1
    bsp config stdout ps7_uart_1
    platform generate

    app create -name $app -platform $platform -domain $domain -template {Empty Application(C)}
    importsources -name $app -path [file join $here main.c]
    app config -name $app build-config release

    banner "Building $app"
    app build -name $app
    if {![file exists $elf]} { error "Build failed, $elf not found" }
    puts "ELF: $elf"
}

# ----------------------------------------------------------------------------
# JTAG: program PL, initialise PS, check the core, download and run the ELF
# ----------------------------------------------------------------------------
proc select_target {filter what} {
    # The JTAG chain can take a moment to show up after hw_server starts
    for {set i 0} {$i < 20} {incr i} {
        if {![catch {targets -set -nocase -filter $filter}]} { return }
        after 250
    }
    error "No $what target found on JTAG. Check that the board is powered, the\
           JTAG cable is connected, JP5 is set to JTAG, and the cable drivers\
           are installed. Visible targets:\n[targets]"
}

proc reg_read {offset} {
    global gcd_base
    return [mrd -value [expr {$gcd_base + $offset}]]
}

proc reg_write {offset value} {
    global gcd_base
    mwr [expr {$gcd_base + $offset}] $value
}

# Register-level check over JTAG, independent of the UART
proc smoke_test {} {
    global gcd_id
    set id [reg_read 0x18]
    if {$id != $gcd_id} {
        error [format "GCD ID register reads 0x%08X, expected 0x%08X" $id $gcd_id]
    }
    reg_write 0x08 14
    reg_write 0x0C 161
    reg_write 0x00 1
    set status [reg_read 0x04]
    set result [reg_read 0x10]
    set cycles [reg_read 0x14]
    puts [format "JTAG smoke test: ID=0x%08X  gcd(14, 161) = %d  (%d cycles)" $id $result $cycles]
    if {!($status & 0x2) || $result != 7} {
        error [format "smoke test failed: STATUS=0x%X RESULT=%d" $status $result]
    }
}

proc run_hw {} {
    global elf hw_dir

    if {![file exists $elf]} { error "$elf not found, run 'xsct run_sw.tcl build' first" }
    # Use the hardware files the ELF was built against (copied into the platform)
    set bit      [lindex [glob -nocomplain [file join $hw_dir *.bit]] 0]
    set hw_xsa   [lindex [glob -nocomplain [file join $hw_dir *.xsa]] 0]
    set ps7_init [file join $hw_dir ps7_init.tcl]
    if {$bit eq "" || $hw_xsa eq "" || ![file exists $ps7_init]} {
        error "Bitstream, XSA or ps7_init.tcl missing in $hw_dir"
    }

    banner "Connecting to hw_server"
    connect                             ;# starts a local hw_server if needed

    select_target {name =~ "APU*"} "Zynq APU"
    rst -system
    after 3000

    banner "Programming PL: [file tail $bit]"
    select_target {name =~ "xc7z020*"} "xc7z020 FPGA"
    fpga -file $bit

    banner "Initialising PS (ps7_init)"
    select_target {name =~ "APU*"} "Zynq APU"
    loadhw -hw $hw_xsa -mem-ranges [list {0x40000000 0xbfffffff}] -regs
    configparams force-mem-access 1
    uplevel #0 [list source $ps7_init]
    uplevel #0 ps7_init
    uplevel #0 ps7_post_config          ;# enables PS-PL level shifters, releases FCLK reset

    select_target {name =~ "*A9*#0"} "Cortex-A9 #0"
    catch {stop}
    smoke_test

    banner "Downloading and running [file tail $elf]"
    dow $elf
    configparams force-mem-access 0
    con
    puts "Program running on CPU0; output is on PS UART1 (115200 8N1)."
    disconnect
}

# ----------------------------------------------------------------------------
if {[catch {
    if {$mode in {all build}} { build_sw }
    if {$mode in {all run}}   { run_hw }
} err]} {
    puts "\nERROR: $err"
    exit 1
}
puts "\nRUN_SW OK"
exit 0
