`timescale 1ns/1ps
// ============================================================================
// tb_compare : gcd32 (Stein) and fsmd_gcd32 (FSMD) on the same inputs
// ----------------------------------------------------------------------------
// Both cores share the clock, the reset and the operand inputs, so every
// vector reaches both on the same clock edge. Each core has its own start:
// a vector whose FSMD latency is longer than fsmd_limit cycles (default 2^24,
// change with +fsmd_limit=N) runs on the Stein core only, and the FSMD latency
// printed for it comes from the FSMD cycle model (the board measures it).
//
//   1) gcd(14, 161) on both cores, started on the same edge, cycle by cycle
//   2) the 18 directed vectors of the board test (zynq/gcd32/main.c)
//   3) latency growth: gcd(2^n - 1, 1), n = 4..32
//   4) all operand pairs 0..255 (exhaustive 8-bit)
//   5) 10,000 random vectors, the mix of tb_gcd32 and tb_fsmd_gcd32 ($random)
//   6) the 10,000 random vectors of the board test (xorshift32 of main.c)
//
// Every run checks both results against a Euclid reference and both
// latencies against the cycle model of each core. Latency = cycles from the
// start cycle to the done cycle, as in the core testbenches and the CYCLES
// register of the AXI wrappers. Sections 5 and 6 write one CSV line per
// vector (random_tbmix.csv, random_board.csv); the VCD covers section 1.
// ============================================================================
module tb_compare;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start_s = 0, start_f = 0;
    reg  [31:0] a_in = 0, b_in = 0;
    wire        busy_s, done_s, busy_f, done_f;
    wire [31:0] gcd_s, gcd_f;

    gcd32 u_stein (.clk(clk), .rst_n(rst_n), .start(start_s), .a_in(a_in), .b_in(b_in),
                   .busy(busy_s), .done(done_s), .gcd_out(gcd_s));

    fsmd_gcd32 u_fsmd (.clk(clk), .rst_n(rst_n), .start(start_f), .a_in(a_in), .b_in(b_in),
                       .busy(busy_f), .done(done_f), .gcd_out(gcd_f));

    always #5 clk = ~clk;   // 100 MHz, the PL clock on the board

    // ------------------------------------------------------------------------
    // Reference and cycle models
    // ------------------------------------------------------------------------
    // Euclid with modulo
    function [31:0] ref_gcd(input [31:0] x, input [31:0] y);
        reg [31:0] t;
        begin
            while (y != 0) begin
                t = x % y; x = y; y = t;
            end
            ref_gcd = x;
        end
    endfunction

    // gcd32: start cycle, one cycle per Stein step, then the a == b cycle;
    // zero operands finish in the start cycle
    function [63:0] stein_model(input [31:0] x, input [31:0] y);
        reg fin;
        begin
            stein_model = 1;
            fin = (x == 0 || y == 0);
            while (!fin) begin
                stein_model = stein_model + 1;
                if (x == y)                  fin = 1;
                else if (!x[0] && !y[0]) begin x = x >> 1; y = y >> 1; end
                else if (!x[0])              x = x >> 1;
                else if (!y[0])              y = y >> 1;
                else if (x < y)              y = (y - x) >> 1;
                else                         x = (x - y) >> 1;
            end
        end
    endfunction

    // fsmd_gcd32: LOAD + FIN, plus (q SUBs + 1 SWAP) for every Euclid step
    function [63:0] fsmd_model(input [31:0] x, input [31:0] y);
        reg [31:0] t;
        begin
            fsmd_model = 2;
            while (y != 0) begin
                fsmd_model = fsmd_model + x / y + 1;
                t = x % y; x = y; y = t;
            end
        end
    endfunction

    // ------------------------------------------------------------------------
    // Section 1 trace: register values before each clock edge and the
    // operation each core performs at that edge
    // ------------------------------------------------------------------------
    reg     trace = 0;
    integer cyc = 0;

    function [8*13-1:0] stein_op(input start, input busy, input [31:0] a, input [31:0] b);
        begin
            if (!busy)       stein_op = start ? "LOAD" : "idle";
            else if (a == b) stein_op = "DONE(a=b)";
            else case ({a[0], b[0]})
                2'b00:   stein_op = "a>>1,b>>1,k+1";
                2'b01:   stein_op = "a>>1";
                2'b10:   stein_op = "b>>1";
                default: stein_op = (a < b) ? "b=(b-a)>>1" : "a=(a-b)>>1";
            endcase
        end
    endfunction

    wire [8*8-1:0] fsmd_op = u_fsmd.load ? "LOAD" : u_fsmd.swap ? "SWAP" :
                             u_fsmd.sub  ? "SUB"  : u_fsmd.fin  ? "FIN(b=0)" : "idle";

    always @(posedge clk)
        if (trace && (start_s || busy_s || start_f || busy_f)) begin
            cyc = cyc + 1;
            $display("  %5d  %t | %10d %10d %3d  %s | %10d %10d  %s", cyc, $time,
                     u_stein.a, u_stein.b, u_stein.k, stein_op(start_s, busy_s, u_stein.a, u_stein.b),
                     u_fsmd.a, u_fsmd.b, fsmd_op);
        end

    time t_start_s, t_start_f, t_done_s, t_done_f;
    always @(posedge clk) if (start_s && !busy_s) t_start_s = $time;
    always @(posedge clk) if (start_f && !busy_f) t_start_f = $time;
    always @(posedge done_s) t_done_s = $time;
    always @(posedge done_f) t_done_f = $time;

    // ------------------------------------------------------------------------
    // One vector on both cores
    // ------------------------------------------------------------------------
    integer     tests = 0, errors = 0, sims_f = 0;
    reg  [63:0] fsmd_limit = 64'd16777216;
    reg  [63:0] lat_s, lat_f;           // latencies of the last run, in cycles
    reg  [31:0] exp;                    // expected result of the last run
    reg         ran_f;                  // the FSMD simulated the last run

    // Per-section statistics
    integer     n_runs, s_faster, f_faster, ties;
    reg  [63:0] sum_s, sum_f, max_s, max_f, min_s, min_f;
    integer     csv = 0;                // CSV file of the current section, 0 = none

    task stats_clear;
        begin
            n_runs = 0; s_faster = 0; f_faster = 0; ties = 0;
            sum_s = 0; sum_f = 0; max_s = 0; max_f = 0;
            min_s = {64{1'b1}}; min_f = {64{1'b1}};
        end
    endtask

    task run(input [31:0] x, input [31:0] y);
        begin
            exp   = ref_gcd(x, y);
            ran_f = (fsmd_model(x, y) <= fsmd_limit);
            @(negedge clk);
            a_in = x; b_in = y; start_s = 1; start_f = ran_f;
            @(negedge clk);
            start_s = 0; start_f = 0;
            fork
                begin
                    lat_s = 1;
                    while (!done_s) begin @(negedge clk); lat_s = lat_s + 1; end
                end
                begin
                    lat_f = 1;
                    if (ran_f)
                        while (!done_f) begin @(negedge clk); lat_f = lat_f + 1; end
                    else
                        lat_f = fsmd_model(x, y);
                end
            join
            tests = tests + 1;
            if (ran_f) sims_f = sims_f + 1;
            if (gcd_s !== exp || lat_s != stein_model(x, y)) begin
                errors = errors + 1;
                $display("FAIL gcd32      gcd(%0d,%0d) = %0d, expected %0d; latency = %0d, model = %0d",
                         x, y, gcd_s, exp, lat_s, stein_model(x, y));
            end
            if (ran_f && (gcd_f !== exp || lat_f != fsmd_model(x, y))) begin
                errors = errors + 1;
                $display("FAIL fsmd_gcd32 gcd(%0d,%0d) = %0d, expected %0d; latency = %0d, model = %0d",
                         x, y, gcd_f, exp, lat_f, fsmd_model(x, y));
            end
            n_runs = n_runs + 1;
            sum_s = sum_s + lat_s;
            sum_f = sum_f + lat_f;
            if (lat_s > max_s) max_s = lat_s;
            if (lat_f > max_f) max_f = lat_f;
            if (lat_s < min_s) min_s = lat_s;
            if (lat_f < min_f) min_f = lat_f;
            if (lat_s < lat_f)      s_faster = s_faster + 1;
            else if (lat_f < lat_s) f_faster = f_faster + 1;
            else                    ties = ties + 1;
            if (csv) $fwrite(csv, "%0d,%0d,%0d,%0d,%0d\n", x, y, exp, lat_s, lat_f);
        end
    endtask

    // Directed run with one PASS line (FAIL lines come from run)
    task run_line(input [31:0] x, input [31:0] y);
        integer e0;
        begin
            e0 = errors;
            run(x, y);
            if (errors == e0)
                $display("  PASS gcd(%0d,%0d) = %0d   stein = %0d cycles   fsmd = %0d cycles%0s",
                         x, y, exp, lat_s, lat_f, ran_f ? "" : " (model, not simulated)");
        end
    endtask

    // Totals are in cycles; 1 cycle = 10 ns = 1e-5 ms at 100 MHz
    task stats_print;
        begin
            $display("  vectors = %0d", n_runs);
            $display("  gcd32      : avg %0.2f cycles   min %0d   max %0d   total %0d cycles = %0.3f ms at 100 MHz",
                     sum_s * 1.0 / n_runs, min_s, max_s, sum_s, sum_s * 1.0e-5);
            $display("  fsmd_gcd32 : avg %0.2f cycles   min %0d   max %0d   total %0d cycles = %0.3f ms at 100 MHz",
                     sum_f * 1.0 / n_runs, min_f, max_f, sum_f, sum_f * 1.0e-5);
            $display("  faster: gcd32 on %0d vectors, fsmd_gcd32 on %0d, equal on %0d; avg fsmd/gcd32 = %0.2f",
                     s_faster, f_faster, ties, sum_f * 1.0 / sum_s);
        end
    endtask

    // ------------------------------------------------------------------------
    // Operand generator of the board test (main.c): xorshift32, three shapes
    // ------------------------------------------------------------------------
    reg [31:0] rng_state;

    function [31:0] xorshift32(input [31:0] x);
        begin
            x = x ^ (x << 13);
            x = x ^ (x >> 17);
            x = x ^ (x << 5);
            xorshift32 = x;
        end
    endfunction

    task board_pair(input integer i, output [31:0] x, output [31:0] y);
        reg [31:0] g;
        begin
            case (i % 3)
                0: begin
                    rng_state = xorshift32(rng_state); x = rng_state;
                    rng_state = xorshift32(rng_state); y = rng_state;
                end
                1: begin
                    rng_state = xorshift32(rng_state); x = rng_state & 32'hFFFF0000;
                    rng_state = xorshift32(rng_state); y = rng_state & 32'hFFFFF000;
                end
                default: begin
                    rng_state = xorshift32(rng_state); g = (rng_state & 32'hFFFF) | 1;
                    rng_state = xorshift32(rng_state); x = g * (rng_state & 32'hFFFF);
                    rng_state = xorshift32(rng_state); y = g * (rng_state & 32'h7FFF);
                end
            endcase
        end
    endtask

    // ------------------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------------------
    integer    i, n;
    reg [31:0] x, y;

    initial begin
        $timeformat(-9, 0, " ns", 6);
        if ($value$plusargs("fsmd_limit=%d", fsmd_limit))
            $display("fsmd_limit = %0d cycles", fsmd_limit);
        $dumpfile("tb_compare.vcd");
        $dumpvars(0, tb_compare);

        repeat (2) @(negedge clk);
        rst_n = 1;

        // ---------------- 1) Required test: gcd(14, 161) ----------------
        $display("\n=== 1) gcd(14, 161) on both cores (same start edge) ===");
        $display("  register values before each rising clock edge, and the operation at that edge");
        $display("                | gcd32 (Stein)                            | fsmd_gcd32");
        $display("  cycle    time |          a          b   k      operation |          a          b  operation");
        stats_clear;
        trace = 1;
        run_line(32'd14, 32'd161);
        trace = 0;
        $display("  gcd32      : start sampled at t=%0t, done = 1 with gcd_out = %0d at t=%0t: latency %0d cycles = %0d ns at 100 MHz",
                 t_start_s, gcd_s, t_done_s, lat_s, lat_s * 10);
        $display("  fsmd_gcd32 : start sampled at t=%0t, done = 1 with gcd_out = %0d at t=%0t: latency %0d cycles = %0d ns at 100 MHz",
                 t_start_f, gcd_f, t_done_f, lat_f, lat_f * 10);
        $display("  gcd32 is done %0d cycles (%0d ns) earlier: %0.2fx faster on gcd(14, 161)",
                 lat_f - lat_s, (lat_f - lat_s) * 10, lat_f * 1.0 / lat_s);
        repeat (2) @(negedge clk);
        $dumpoff;

        // ---------------- 2) Directed vectors of the board test ----------------
        $display("\n=== 2) Directed vectors of the board test (zynq/gcd32/main.c) ===");
        stats_clear;
        run_line(32'd14, 32'd161);
        run_line(32'd161, 32'd14);
        run_line(32'd0, 32'd0);
        run_line(32'd0, 32'd12345);
        run_line(32'd98765, 32'd0);
        run_line(32'd42, 32'd42);
        run_line(32'd1, 32'd1);
        run_line(32'd48, 32'd180);
        run_line(32'd1071, 32'd462);
        run_line(32'd360, 32'd1001);
        run_line(32'd111546435, 32'd5311488);
        run_line(32'h80000000, 32'h40000000);
        run_line(32'h80000000, 32'h00300000);
        run_line(32'hFFFFFFFF, 32'd1);
        run_line(32'hFFFFFFFF, 32'hFFFFFFFE);
        run_line(32'hFFFFFFFF, 32'hFFFFFFFF);
        run_line(32'd2971215073, 32'd1836311903);   // consecutive Fibonacci numbers
        run_line(32'd4294967291, 32'd4294967279);   // two largest 32-bit primes

        // ---------------- 3) Latency growth: gcd(2^n - 1, 1) ----------------
        $display("\n=== 3) Latency growth: gcd(2^n - 1, 1) ===");
        for (n = 4; n <= 32; n = n + 4) begin
            x = (64'd1 << n) - 1;
            run(x, 32'd1);
            $display("  n = %2d : stein = %0d cycles   fsmd = %0d cycles%0s", n, lat_s, lat_f,
                     ran_f ? "" : " (model)");
        end
        // The longest inputs of each core for n-bit operands: gcd32 needs at most 2n cycles,
        // at gcd(2^n - 1, 2^n - 2); fsmd_gcd32 at most 2^n + 4, at gcd(2^n - 2, 2^n - 1)
        $display("  32-bit worst cases: gcd32 2n = 64 cycles, fsmd_gcd32 2^n + 4 = 4294967300 cycles");
        run_line(32'hFFFFFFFF, 32'hFFFFFFFE);
        run_line(32'hFFFFFFFE, 32'hFFFFFFFF);

        // ---------------- 4) Exhaustive 8-bit operands ----------------
        $display("\n=== 4) All operand pairs 0..255 (exhaustive 8-bit) ===");
        stats_clear;
        for (i = 0; i < 65536; i = i + 1)
            run(i / 256, i % 256);
        stats_print;

        // ---------------- 5) Random vectors, testbench mix ----------------
        $display("\n=== 5) Random regression, mix of tb_gcd32 / tb_fsmd_gcd32 (10000 vectors, $random) ===");
        stats_clear;
        csv = $fopen("random_tbmix.csv", "w");
        $fwrite(csv, "a,b,gcd,stein_cycles,fsmd_cycles\n");
        for (i = 0; i < 10000; i = i + 1)
            case (i % 3)
                0: run($random, $random);
                1: run($random & 32'hFFFF0000, $random & 32'hFFFFF000); // many shared 2s
                2: begin : common
                       reg [31:0] g; g = ($random & 32'hFFFF) | 1;
                       run(g * ($random & 32'hFFFF), g * ($random & 32'h7FFF)); // big common factor
                   end
            endcase
        $fclose(csv);
        csv = 0;
        stats_print;

        // ---------------- 6) Random vectors of the board test ----------------
        $display("\n=== 6) Random regression of the board test (10000 vectors, xorshift32 of main.c) ===");
        stats_clear;
        rng_state = 32'h2545F491;
        csv = $fopen("random_board.csv", "w");
        $fwrite(csv, "a,b,gcd,stein_cycles,fsmd_cycles\n");
        for (i = 0; i < 10000; i = i + 1) begin
            board_pair(i, x, y);
            run(x, y);
        end
        $fclose(csv);
        csv = 0;
        stats_print;
        $display("  as the board driver prints it (integer average): gcd32 avg %0d / max %0d, fsmd_gcd32 avg %0d / max %0d",
                 sum_s / n_runs, max_s, sum_f / n_runs, max_f);

        $display("\n=== Summary ===");
        $display("tests = %0d   errors = %0d (both cores: result and latency checked; fsmd simulated in %0d, model in %0d)",
                 tests, errors, sims_f, tests - sims_f);
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("TESTS FAILED");
        $finish;
    end

endmodule
