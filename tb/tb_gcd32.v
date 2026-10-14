`timescale 1ns/1ps

module tb_gcd32;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [31:0] a_in = 0, b_in = 0;
    wire        busy, done;
    wire [31:0] gcd_out;

    integer errors = 0, tests = 0, max_lat = 0, sum_lat = 0;
    reg     trace = 0;

    gcd32 dut (.clk(clk), .rst_n(rst_n), .start(start),
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

    // Optional internal trace
    always @(posedge clk) if (trace && busy)
        $display("  t=%0t  a=%0d  b=%0d  k=%0d", $time, dut.a, dut.b, dut.k);

    task run(input [31:0] x, input [31:0] y);
        integer lat;
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
            if (gcd_out !== exp) begin
                errors = errors + 1;
                $display("FAIL gcd(%0d,%0d) = %0d, expected %0d", x, y, gcd_out, exp);
            end else if (trace)
                $display("PASS gcd(%0d,%0d) = %0d   latency = %0d cycles",
                         x, y, gcd_out, lat);
        end
    endtask

    integer i;
    initial begin
        $dumpfile("gcd32.vcd");
        $dumpvars(0, tb_gcd32);

        repeat (2) @(negedge clk);
        rst_n = 1;

        // ---------------- 1) Required test: gcd(14, 161) ----------------
        $display("\n=== Directed test: gcd(14, 161) ===");
        trace = 1;
        run(32'd14, 32'd161);
        trace = 0;

        // ---------------- 2) Corner cases ----------------
        $display("\n=== Corner cases ===");
        trace = 1;
        run(32'd161, 32'd14);
        run(32'd0, 32'd0);
        run(32'd0, 32'd12345);
        run(32'd98765, 32'd0);
        run(32'd42, 32'd42);
        run(32'd1, 32'd1);
        run(32'h80000000, 32'h40000000);
        run(32'hFFFFFFFF, 32'd1);
        run(32'hFFFFFFFF, 32'hFFFFFFFE);
        run(32'd2971215073, 32'd1836311903);   // consecutive Fibonacci (Euclid worst case)
        trace = 0;
        $dumpoff;                               // the VCD covers sections 1 and 2

        // ---------------- 3) Random regression ----------------
        $display("\n=== Random regression (10000 vectors) ===");
        for (i = 0; i < 10000; i = i + 1)
            case (i % 3)
                0: run($random, $random);
                1: run($random & 32'hFFFF0000, $random & 32'hFFFFF000); // many shared 2s
                2: begin : common
                       reg [31:0] g; g = ($random & 32'hFFFF) | 1;
                       run(g * ($random & 32'hFFFF), g * ($random & 32'h7FFF)); // big common factor
                   end
            endcase

        $display("\n=== Summary ===");
        $display("tests = %0d   errors = %0d", tests, errors);
        $display("max latency = %0d cycles   avg latency = %0d cycles",
                 max_lat, sum_lat / tests);
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("TESTS FAILED");
        $finish;
    end

endmodule
// ============================================================================
// tb_gcd32 : testbench for gcd32
//   1) Directed test gcd(14, 161) with a cycle-by-cycle trace
//   2) Corner cases (zeros, equal, powers of two, coprime extremes)
//   3) 10,000 random vectors checked against a reference model
//   Reports latency (cycles from start to done) for every test.
// ============================================================================