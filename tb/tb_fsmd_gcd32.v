`timescale 1ns/1ps
// ============================================================================
// tb_fsmd_gcd32 : testbench for fsmd_gcd32
//   1) Required test gcd(14, 161) with a cycle-by-cycle trace of the datapath
//   2) Corner cases (order, zeros, equal, powers of two, Fibonacci)
//   3) Latency growth of gcd(2^n - 1, 1), extrapolated to the 32-bit worst case
//   4) All operand pairs 0..31, then 10,000 random vectors (same mix as
//      tb_gcd32) checked against a reference model
// Every run checks the result AND that the measured latency equals the cycle
// model of fsmd_gcd32.v: 2 + sum over the Euclid steps of (q_i + 1).
// Latency = cycles from the start cycle to the done cycle (as in tb_gcd32).
// ============================================================================
module tb_fsmd_gcd32;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [31:0] a_in = 0, b_in = 0;
    wire        busy, done;
    wire [31:0] gcd_out;

    integer errors = 0, tests = 0, max_lat = 0, sum_lat = 0;
    integer lat;                    // latency of the last run
    reg     trace = 0, verbose = 0;
    time    t_start, t_done;

    fsmd_gcd32 dut (.clk(clk), .rst_n(rst_n), .start(start),
                    .a_in(a_in), .b_in(b_in),
                    .busy(busy), .done(done), .gcd_out(gcd_out));

    always #5 clk = ~clk;   // 100 MHz

    // Reference model: Euclid with modulo
    function [31:0] ref_gcd(input [31:0] x, input [31:0] y);
        reg [31:0] t;
        begin
            while (y != 0) begin
                t = x % y; x = y; y = t;
            end
            ref_gcd = x;
        end
    endfunction

    // Cycle model: LOAD + FIN, plus (q SUBs + 1 SWAP) for every Euclid step
    function [63:0] model_lat(input [31:0] x, input [31:0] y);
        reg [31:0] t;
        begin
            model_lat = 2;
            while (y != 0) begin
                model_lat = model_lat + x / y + 1;
                t = x % y; x = y; y = t;
            end
        end
    endfunction

    // Trace: register values during the cycle, and the micro-operation the
    // controller executes at the end of it
    always @(posedge clk) if (trace && busy)
        $display("  t=%0t  a=%0d  b=%0d  %s", $time, dut.a, dut.b,
                 dut.fin ? "FIN " : dut.swap ? "SWAP" : "SUB ");

    always @(posedge clk) if (start && !busy) t_start = $time;
    always @(posedge done) t_done = $time;

    task run(input [31:0] x, input [31:0] y);
        reg [31:0] exp;
        begin
            @(negedge clk);
            a_in = x; b_in = y; start = 1;
            @(negedge clk);
            start = 0;
            lat = 1;
            while (!done) begin @(negedge clk); lat = lat + 1; end
            exp = ref_gcd(x, y);
            tests = tests + 1;
            sum_lat = sum_lat + lat;
            if (lat > max_lat) max_lat = lat;
            if (gcd_out !== exp || lat != model_lat(x, y)) begin
                errors = errors + 1;
                $display("FAIL gcd(%0d,%0d) = %0d, expected %0d; latency = %0d, model = %0d",
                         x, y, gcd_out, exp, lat, model_lat(x, y));
            end else if (verbose)
                $display("PASS gcd(%0d,%0d) = %0d   latency = %0d cycles",
                         x, y, gcd_out, lat);
        end
    endtask

    integer i, n, first;
    initial begin
        $timeformat(-9, 0, " ns", 0);
        $dumpfile("fsmd_gcd32.vcd");
        $dumpvars(0, tb_fsmd_gcd32);

        repeat (2) @(negedge clk);
        rst_n = 1;

        // ---------------- 1) Required test: gcd(14, 161) ----------------
        $display("\n=== 1) Required test: gcd(14, 161) ===");
        trace = 1; verbose = 1;
        run(32'd14, 32'd161);
        trace = 0;
        $display("  start sampled at t=%0t, done = 1 and gcd_out = %0d at t=%0t",
                 t_start, gcd_out, t_done);
        $display("  latency = 1 start cycle + %0d busy cycles = %0d cycles = %0d ns at 100 MHz",
                 lat - 1, lat, lat * 10);

        // ---------------- 2) Corner cases ----------------
        $display("\n=== 2) Corner cases ===");
        run(32'd161, 32'd14);
        run(32'd0, 32'd0);
        run(32'd0, 32'd12345);
        run(32'd98765, 32'd0);
        run(32'd42, 32'd42);
        run(32'd1, 32'd1);
        run(32'h80000000, 32'h40000000);
        run(32'hFFFFFFFF, 32'hFFFFFFFF);
        run(32'd2971215073, 32'd1836311903);   // consecutive Fibonacci: every q = 1
        $display("  gcd(4294967295,1)          not simulated: model latency = %0d cycles",
                 model_lat(32'hFFFFFFFF, 32'd1));
        $display("  gcd(4294967295,4294967294) not simulated: model latency = %0d cycles",
                 model_lat(32'hFFFFFFFF, 32'hFFFFFFFE));
        verbose = 0;
        $dumpoff;                               // the VCD covers sections 1 and 2

        // ---------------- 3) Latency growth: gcd(2^n - 1, 1) ----------------
        $display("\n=== 3) Latency growth: gcd(2^n - 1, 1) ===");
        for (n = 4; n <= 20; n = n + 4) begin
            run((32'd1 << n) - 1, 32'd1);
            $display("  n = %2d : latency = %0d cycles", n, lat);
        end
        $display("  n = 32 : latency = %0d cycles (model) = %0.1f s at 100 MHz",
                 model_lat(32'hFFFFFFFF, 32'd1), model_lat(32'hFFFFFFFF, 32'd1) * 1.0e-8);

        // ---------------- 4) Exhaustive small operands + random regression ----------------
        $display("\n=== 4) All pairs 0..31 + random regression (10000 vectors) ===");
        for (i = 0; i < 1024; i = i + 1)
            run(i / 32, i % 32);
        first = tests; sum_lat = 0; max_lat = 0;
        for (i = 0; i < 10000; i = i + 1)
            case (i % 3)
                0: run($random, $random);
                1: run($random & 32'hFFFF0000, $random & 32'hFFFFF000); // many shared 2s
                2: begin : common
                       reg [31:0] g; g = ($random & 32'hFFFF) | 1;
                       run(g * ($random & 32'hFFFF), g * ($random & 32'h7FFF)); // big common factor
                   end
            endcase
        $display("  random vectors: avg latency = %0.1f cycles   max latency = %0d cycles",
                 sum_lat * 1.0 / (tests - first), max_lat);

        $display("\n=== Summary ===");
        $display("tests = %0d   errors = %0d (result and latency checked)", tests, errors);
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("TESTS FAILED");
        $finish;
    end

endmodule
