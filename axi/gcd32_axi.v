`timescale 1ns/1ps
// ============================================================================
// gcd32_axi : AXI4-Lite slave wrapper for gcd32
// ----------------------------------------------------------------------------
// Register map (32-bit registers, byte offsets from the base address)
//
//   0x00  CTRL    W   bit0 START  write 1 -> one-cycle start pulse to the core
//                                  (ignored while BUSY). Reads back as 0.
//   0x04  STATUS  R   bit0 BUSY   operation in progress
//                     bit1 DONE   result valid; sticky, cleared by START
//   0x08  A       RW  operand a
//   0x0C  B       RW  operand b
//   0x10  RESULT  R   gcd(a, b) of the last completed operation
//   0x14  CYCLES  R   clock cycles from START to DONE of the last operation
//   0x18  ID      R   0x47434431 ("GCD1"), lets software check the bitstream
//
// Other offsets in the 4 KB window read as 0, and writes to read-only
// registers are ignored. All responses are OKAY.
//
// Usage: write A, write B, write CTRL=1, poll STATUS until DONE, read RESULT.
//
// AXI notes: AW and W are accepted together (AWREADY/WREADY are asserted only
// once both AWVALID and WVALID are high), which AXI permits. Each channel
// handles one transaction at a time and honours BREADY/RREADY backpressure.
// ============================================================================
module gcd32_axi (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn" *)
    input  wire        s_axi_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire        s_axi_aresetn,

    // Write address channel
    input  wire [11:0] s_axi_awaddr,
    input  wire [2:0]  s_axi_awprot,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    // Write data channel
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    // Write response channel
    output wire [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    // Read address channel
    input  wire [11:0] s_axi_araddr,
    input  wire [2:0]  s_axi_arprot,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    // Read data channel
    output reg  [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready
);

    // Register indices (byte offset / 4)
    localparam [9:0] REG_CTRL   = 10'd0,
                     REG_STATUS = 10'd1,
                     REG_A      = 10'd2,
                     REG_B      = 10'd3,
                     REG_RESULT = 10'd4,
                     REG_CYCLES = 10'd5,
                     REG_ID     = 10'd6;

    localparam [31:0] ID_VALUE = 32'h47434431;  // "GCD1"

    wire clk   = s_axi_aclk;
    wire rst_n = s_axi_aresetn;

    reg  [31:0] reg_a, reg_b;
    reg         start_pulse;        // one-cycle start strobe to the core
    reg         done_flag;          // sticky DONE seen by software
    reg  [31:0] cycles;

    wire        core_busy, core_done;
    wire [31:0] core_gcd;

    gcd32 u_core (
        .clk     (clk),
        .rst_n   (rst_n),
        .start   (start_pulse),
        .a_in    (reg_a),
        .b_in    (reg_b),
        .busy    (core_busy),
        .done    (core_done),
        .gcd_out (core_gcd)
    );

    // Byte-lane merge for WSTRB
    function [31:0] apply_wstrb(input [31:0] old, input [31:0] data, input [3:0] strb);
        integer i;
        begin
            for (i = 0; i < 4; i = i + 1)
                apply_wstrb[i*8 +: 8] = strb[i] ? data[i*8 +: 8] : old[i*8 +: 8];
        end
    endfunction

    // ------------------------------------------------------------------------
    // Write channels
    // ------------------------------------------------------------------------
    wire wr_accept = s_axi_awvalid && s_axi_wvalid && !s_axi_awready && !s_axi_bvalid;
    wire wr_en     = s_axi_awvalid && s_axi_awready && s_axi_wvalid && s_axi_wready;
    wire [9:0] wr_idx = s_axi_awaddr[11:2];

    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
        end else begin
            s_axi_awready <= wr_accept;     // single-cycle ready pulses
            s_axi_wready  <= wr_accept;
            if (wr_en)
                s_axi_bvalid <= 1'b1;
            else if (s_axi_bready)
                s_axi_bvalid <= 1'b0;
        end
    end

    assign s_axi_bresp = 2'b00;             // OKAY

    always @(posedge clk) begin
        if (!rst_n) begin
            reg_a       <= 32'd0;
            reg_b       <= 32'd0;
            start_pulse <= 1'b0;
        end else begin
            start_pulse <= 1'b0;            // self-clearing: high for one cycle only
            if (wr_en) begin
                case (wr_idx)
                    REG_CTRL:
                        if (s_axi_wstrb[0] && s_axi_wdata[0] && !core_busy && !start_pulse)
                            start_pulse <= 1'b1;
                    REG_A: reg_a <= apply_wstrb(reg_a, s_axi_wdata, s_axi_wstrb);
                    REG_B: reg_b <= apply_wstrb(reg_b, s_axi_wdata, s_axi_wstrb);
                    default: ;
                endcase
            end
        end
    end

    // ------------------------------------------------------------------------
    // Status and latency counter
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            done_flag <= 1'b0;
            cycles    <= 32'd0;
        end else begin
            if (start_pulse)
                done_flag <= 1'b0;
            else if (core_done)
                done_flag <= 1'b1;

            if (start_pulse)
                cycles <= 32'd1;
            else if (core_busy)
                cycles <= cycles + 32'd1;
        end
    end

    // BUSY also covers the start cycle, and DONE also covers the cycle where
    // the core pulses done (busy has just dropped, done_flag is not set yet),
    // so a STATUS read after START never sees BUSY=0 and DONE=0.
    wire [31:0] status = {30'd0, done_flag | core_done, core_busy | start_pulse};

    // ------------------------------------------------------------------------
    // Read channels
    // ------------------------------------------------------------------------
    wire rd_accept = s_axi_arvalid && !s_axi_arready && !s_axi_rvalid;
    wire rd_en     = s_axi_arvalid && s_axi_arready;

    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= 32'd0;
        end else begin
            s_axi_arready <= rd_accept;
            if (rd_en) begin
                s_axi_rvalid <= 1'b1;
                case (s_axi_araddr[11:2])
                    REG_STATUS: s_axi_rdata <= status;
                    REG_A:      s_axi_rdata <= reg_a;
                    REG_B:      s_axi_rdata <= reg_b;
                    REG_RESULT: s_axi_rdata <= core_gcd;
                    REG_CYCLES: s_axi_rdata <= cycles;
                    REG_ID:     s_axi_rdata <= ID_VALUE;
                    default:    s_axi_rdata <= 32'd0;   // CTRL and unmapped
                endcase
            end else if (s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    assign s_axi_rresp = 2'b00;             // OKAY

endmodule
