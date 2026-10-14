`timescale 1ns/1ps
// ============================================================================
// tb_gcd32_axi : AXI4-Lite level testbench for gcd32_axi
//   * AXI master BFM with random AW/W ordering and random BREADY/RREADY delays
//   * Protocol checks: BVALID/RVALID held until accepted, RDATA stable
//   * START is checked to be exactly one cycle per accepted CTRL write
//   * Register map, WSTRB, START-while-busy, corner cases, random regression
//     against a reference model (result and CYCLES latency)
// Run: see sim stage of run_all.sh (xvlog / xelab / xsim)
// ============================================================================
module tb_gcd32_axi;

    localparam [11:0] CTRL = 12'h00, STATUS = 12'h04, A = 12'h08, B = 12'h0C,
                      RESULT = 12'h10, CYCLES = 12'h14, ID = 12'h18;

    reg         clk = 0;
    reg         rst_n = 0;
    reg  [11:0] awaddr = 0;  reg awvalid = 0;  wire awready;
    reg  [31:0] wdata = 0;   reg [3:0] wstrb = 0;  reg wvalid = 0;  wire wready;
    wire [1:0]  bresp;       wire bvalid;  reg bready = 0;
    reg  [11:0] araddr = 0;  reg arvalid = 0;  wire arready;
    wire [31:0] rdata;       wire [1:0] rresp;  wire rvalid;  reg rready = 0;

    integer errors = 0, tests = 0, start_count = 0, seed = 1;

    gcd32_axi dut (
        .s_axi_aclk(clk), .s_axi_aresetn(rst_n),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b000), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'b000), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready));

    always #5 clk = ~clk;   // 100 MHz, same as FCLK_CLK0 in the block design

    function integer rnd(input integer n);
        rnd = ($random(seed) & 32'h7fffffff) % n;
    endfunction

    // ---------------- Reference models ----------------
    function [31:0] ref_gcd(input [31:0] x, input [31:0] y);
        reg [31:0] t;
        begin
            while (y != 0) begin t = x % y; x = y; y = t; end
            ref_gcd = x;
        end
    endfunction

    // Expected CYCLES value: start cycle + one cycle per Stein step + final compare
    function [31:0] ref_cycles(input [31:0] x, input [31:0] y);
        integer n;
        begin
            n = 0;
            if (x == 0 || y == 0) ref_cycles = 1;
            else begin
                while (x != y) begin
                    case ({x[0], y[0]})
                        2'b00: begin x = x >> 1; y = y >> 1; end
                        2'b01: x = x >> 1;
                        2'b10: y = y >> 1;
                        2'b11: if (x < y) y = (y - x) >> 1; else x = (x - y) >> 1;
                    endcase
                    n = n + 1;
                end
                ref_cycles = n + 2;
            end
        end
    endfunction

    // ---------------- Monitors ----------------
    reg        prev_start = 0, prev_bvalid = 0, prev_bready = 0, prev_rvalid = 0, prev_rready = 0;
    reg [31:0] prev_rdata = 0;
    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.start_pulse) start_count = start_count + 1;
            if (dut.start_pulse && prev_start) begin
                errors = errors + 1; $display("ERROR: start pulse wider than one cycle at t=%0t", $time);
            end
            if (prev_bvalid && !prev_bready && !bvalid) begin
                errors = errors + 1; $display("ERROR: BVALID dropped before BREADY at t=%0t", $time);
            end
            if (prev_rvalid && !prev_rready && (!rvalid || rdata !== prev_rdata)) begin
                errors = errors + 1; $display("ERROR: RVALID/RDATA changed before RREADY at t=%0t", $time);
            end
        end
        prev_start  <= dut.start_pulse;
        prev_bvalid <= bvalid;  prev_bready <= bready;
        prev_rvalid <= rvalid;  prev_rready <= rready;  prev_rdata <= rdata;
    end

    // ---------------- AXI4-Lite master BFM ----------------
    // Inputs are driven on the falling edge, handshakes sampled on the rising edge.
    task axi_write(input [11:0] addr, input [31:0] data, input [3:0] strb);
        integer aw_dly, w_dly, t;
        reg aw_done, w_done;
        begin
            aw_dly = rnd(4); w_dly = rnd(4);        // random AW/W order and skew
            aw_done = 0; w_done = 0; t = 0;
            @(negedge clk);
            while (!(aw_done && w_done)) begin
                if (!aw_done && t >= aw_dly) begin awaddr = addr; awvalid = 1; end
                if (!w_done  && t >= w_dly)  begin wdata = data; wstrb = strb; wvalid = 1; end
                @(posedge clk);
                if (awvalid && awready) aw_done = 1;
                if (wvalid && wready)   w_done  = 1;
                @(negedge clk);
                if (aw_done) awvalid = 0;
                if (w_done)  wvalid  = 0;
                t = t + 1;
                if (t > 100) begin $display("FATAL: write handshake timeout"); $finish; end
            end
            repeat (rnd(3)) @(negedge clk);         // BREADY backpressure
            bready = 1;
            @(posedge clk); while (!bvalid) @(posedge clk);
            if (bresp !== 2'b00) begin errors = errors + 1; $display("ERROR: BRESP=%b", bresp); end
            @(negedge clk); bready = 0;
        end
    endtask

    task axi_read(input [11:0] addr, output [31:0] data);
        begin
            @(negedge clk);
            repeat (rnd(3)) @(negedge clk);
            araddr = addr; arvalid = 1;
            @(posedge clk); while (!arready) @(posedge clk);
            @(negedge clk); arvalid = 0;
            repeat (rnd(3)) @(negedge clk);         // RREADY backpressure
            rready = 1;
            @(posedge clk); while (!rvalid) @(posedge clk);
            data = rdata;
            if (rresp !== 2'b00) begin errors = errors + 1; $display("ERROR: RRESP=%b", rresp); end
            @(negedge clk); rready = 0;
        end
    endtask

    task expect_reg(input [11:0] addr, input [31:0] exp, input [8*24-1:0] what);
        reg [31:0] v;
        begin
            axi_read(addr, v);
            tests = tests + 1;
            if (v !== exp) begin
                errors = errors + 1;
                $display("FAIL %0s: read 0x%08h, expected 0x%08h", what, v, exp);
            end
        end
    endtask

    // Full software sequence: A, B, START, poll STATUS, RESULT, CYCLES
    task run(input [31:0] x, input [31:0] y, input verbose);
        reg [31:0] st, g, cyc;
        integer polls, starts0;
        begin
            axi_write(A, x, 4'hF);
            axi_write(B, y, 4'hF);
            starts0 = start_count;
            axi_write(CTRL, 32'h1, 4'h1);
            axi_read(STATUS, st);
            if (st[1:0] == 2'b00) begin
                errors = errors + 1;
                $display("ERROR: STATUS idle right after START for gcd(%0d,%0d)", x, y);
            end
            polls = 0;
            while (!st[1]) begin
                axi_read(STATUS, st);
                polls = polls + 1;
                if (polls > 200) begin $display("FATAL: DONE never set for gcd(%0d,%0d)", x, y); $finish; end
            end
            axi_read(RESULT, g);
            axi_read(CYCLES, cyc);
            tests = tests + 1;
            if (start_count != starts0 + 1) begin
                errors = errors + 1;
                $display("ERROR: %0d start pulses for one START write", start_count - starts0);
            end
            if (g !== ref_gcd(x, y) || cyc !== ref_cycles(x, y)) begin
                errors = errors + 1;
                $display("FAIL gcd(%0d,%0d) = %0d (%0d cycles), expected %0d (%0d cycles)",
                         x, y, g, cyc, ref_gcd(x, y), ref_cycles(x, y));
            end else if (verbose)
                $display("PASS gcd(%0d,%0d) = %0d   cycles = %0d", x, y, g, cyc);
        end
    endtask

    integer i, starts0;
    reg [31:0] v, gc;

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;

        $display("\n=== Register map ===");
        expect_reg(ID,     32'h47434431, "ID");
        expect_reg(STATUS, 32'h0,        "STATUS after reset");
        expect_reg(RESULT, 32'h0,        "RESULT after reset");
        expect_reg(12'h01C, 32'h0,       "unmapped 0x01C");
        expect_reg(12'hFFC, 32'h0,       "unmapped 0xFFC");
        axi_write(A, 32'h11223344, 4'hF);
        axi_write(B, 32'hCAFEF00D, 4'hF);
        expect_reg(A, 32'h11223344, "A readback");
        expect_reg(B, 32'hCAFEF00D, "B readback");
        axi_write(A, 32'hAABBCCDD, 4'b0101);
        expect_reg(A, 32'h11BB33DD, "A after WSTRB=0101");
        expect_reg(CTRL, 32'h0, "CTRL reads as 0");
        axi_write(ID, 32'hFFFFFFFF, 4'hF);
        expect_reg(ID, 32'h47434431, "ID after write");

        $display("\n=== START handling ===");
        starts0 = start_count;
        axi_write(CTRL, 32'h1, 4'b1110);            // byte 0 not enabled -> no start
        axi_write(CTRL, 32'h0, 4'hF);               // START=0 -> no start
        tests = tests + 1;
        if (start_count != starts0) begin
            errors = errors + 1; $display("FAIL: START issued without WSTRB[0] && WDATA[0]");
        end
        // Second START while the core is busy must be ignored
        axi_write(A, 32'h80000000, 4'hF);
        axi_write(B, 32'd1, 4'hF);
        starts0 = start_count;
        axi_write(CTRL, 32'h1, 4'h1);
        axi_write(CTRL, 32'h1, 4'h1);               // core busy (~33 cycles) -> ignored
        v = 0;
        while (!v[1]) axi_read(STATUS, v);
        expect_reg(RESULT, 32'd1, "RESULT after START-while-busy");
        tests = tests + 1;
        if (start_count != starts0 + 1) begin
            errors = errors + 1; $display("FAIL: START while busy was not ignored");
        end
        $display("start handling checked");

        $display("\n=== Directed vectors ===");
        run(32'd14, 32'd161, 1);
        run(32'd161, 32'd14, 1);
        run(32'd0, 32'd0, 1);
        run(32'd0, 32'd12345, 1);
        run(32'd98765, 32'd0, 1);
        run(32'd42, 32'd42, 1);
        run(32'd1, 32'd1, 1);
        run(32'd48, 32'd180, 1);
        run(32'h80000000, 32'h40000000, 1);
        run(32'hFFFFFFFF, 32'd1, 1);
        run(32'hFFFFFFFF, 32'hFFFFFFFE, 1);
        run(32'd2971215073, 32'd1836311903, 1);

        $display("\n=== Random regression (3000 vectors) ===");
        for (i = 0; i < 3000; i = i + 1)
            case (i % 3)
                0: run($random(seed), $random(seed), 0);
                1: run($random(seed) & 32'hFFFF0000, $random(seed) & 32'hFFFFF000, 0);
                2: begin
                       gc = ($random(seed) & 32'hFFFF) | 1;
                       run(gc * ($random(seed) & 32'hFFFF), gc * ($random(seed) & 32'h7FFF), 0);
                   end
            endcase

        $display("\n=== Summary ===");
        $display("checks = %0d   errors = %0d", tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("TESTS FAILED");
        $finish;
    end

    initial begin
        #50_000_000;
        $display("FATAL: simulation watchdog expired");
        $finish;
    end

endmodule
