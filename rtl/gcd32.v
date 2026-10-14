`timescale 1ns/1ps

module gcd32 (
    input  wire        clk,
    input  wire        rst_n,      // active-low synchronous reset
    input  wire        start,
    input  wire [31:0] a_in,
    input  wire [31:0] b_in,
    output reg         busy,
    output reg         done,
    output reg  [31:0] gcd_out
);

    reg [31:0] a, b;
    reg [4:0]  k;                   // common power of two (max 31)

    // Two subtractors in parallel: the sign of (a-b) selects which result is
    // used, avoiding a serial compare->subtract path (shorter critical path).
    wire [32:0] a_minus_b = {1'b0, a} - {1'b0, b};
    wire [31:0] b_minus_a = b - a;
    wire        a_lt_b    = a_minus_b[32];        // borrow => a < b
    wire        eq        = (a == b);

    always @(posedge clk) begin
        if (!rst_n) begin
            a       <= 32'd0;
            b       <= 32'd0;
            k       <= 5'd0;
            busy    <= 1'b0;
            done    <= 1'b0;
            gcd_out <= 32'd0;
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                // Zero operands are resolved immediately (no iterations).
                if (a_in == 32'd0 || b_in == 32'd0) begin
                    gcd_out <= a_in | b_in;
                    done    <= 1'b1;
                end else begin
                    a    <= a_in;
                    b    <= b_in;
                    k    <= 5'd0;
                    busy <= 1'b1;
                end
            end else if (busy) begin
                if (eq) begin
                    gcd_out <= a << k;      // restore the common 2^k factor
                    busy    <= 1'b0;
                    done    <= 1'b1;
                end else begin
                    case ({a[0], b[0]})
                        2'b00: begin        // both even
                            a <= a >> 1;
                            b <= b >> 1;
                            k <= k + 5'd1;
                        end
                        2'b01: a <= a >> 1; // a even
                        2'b10: b <= b >> 1; // b even
                        2'b11: begin        // both odd
                            if (a_lt_b) b <= b_minus_a     >> 1;
                            else        a <= a_minus_b[31:0] >> 1;
                        end
                    endcase
                end
            end
        end
    end

endmodule
// ============================================================================
// gcd32 : 32-bit GCD unit, binary (Stein's) algorithm, FPGA-oriented
// ----------------------------------------------------------------------------
// Why binary GCD and not Euclid?
//   * Euclid with division needs a 32-bit divider  -> huge area.
//   * Euclid with repeated subtraction is tiny, but worst case is ~2^32 cycles
//     (e.g. gcd(0xFFFFFFFF, 1)).
//   * Stein's algorithm only needs shifts (free wiring), one compare and a
//     subtract. Every cycle removes at least one bit from a or b, so the
//     worst case is bounded by ~64 iterations, while area stays at roughly
//     two 32-bit subtractors (on carry chains) + muxes + registers.
//
// Per-cycle step (all decisions in ONE clock):
//   a == b               -> done, gcd = a << k
//   a even & b even      -> a>>=1, b>>=1, k++     (common factor of 2)
//   a even (b odd)       -> a>>=1
//   b even (a odd)       -> b>>=1
//   both odd, a > b      -> a = (a-b)>>1          (a-b is even, shift is free)
//   both odd, a < b      -> b = (b-a)>>1
//
// Handshake: pulse start with operands valid; 'done' pulses for 1 cycle with
// gcd_out valid (gcd_out holds its value until the next start).
// Convention: gcd(x,0) = x, gcd(0,0) = 0.
// ============================================================================
