`timescale 1ns/1ps
// ============================================================================
// fsmd_gcd32 : 32-bit GCD unit, FSMD (controller FSM + datapath),
//              subtraction-based Euclidean algorithm, area-oriented
// ----------------------------------------------------------------------------
// Algorithm (Euclid, "a mod b" done by repeated subtraction):
//     while (b != 0)
//         if (a < b) swap(a, b);       // keep the larger value in a
//         else       a = a - b;
//     gcd = a
// gcd(x,0) = x and gcd(0,0) = 0 fall out of the loop, so zero operands need
// no extra logic.
//
// Datapath  : registers a, b, gcd_out and ONE 32-bit subtractor (a - b).
//             Its borrow is also the comparator (a < b); the only other
//             status signal is a zero detector on b.
// Controller: 2 states, one micro-operation per clock:
//
//                start / LOAD
//       IDLE -------------------> CALC --+   b != 0 :  a < b ? SWAP : SUB
//        ^                         |  ^  |
//        |       b == 0 / FIN      |  +--+
//        +-------------------------+
//
//     LOAD : a <= a_in, b <= b_in      SWAP : a <= b, b <= a
//     SUB  : a <= a - b                FIN  : gcd_out <= a, done pulse
//
// Latency (start cycle to done cycle, same convention as tb_gcd32):
//     2 + sum over the Euclid steps of (q_i + 1) cycles, q_i = quotients
//     gcd(14,161) = 18 cycles; worst case gcd(1, 2^32-1) = 2^32 + 3 cycles.
//
// Same ports and handshake as gcd32 (Stein core), so the two are drop-in
// replacements: pulse start with a_in/b_in valid (ignored while busy);
// done pulses for 1 cycle with gcd_out valid; gcd_out holds until the next
// done. ready = ~busy.
// ============================================================================
module fsmd_gcd32 (
    input  wire        clk,
    input  wire        rst_n,      // active-low synchronous reset
    input  wire        start,
    input  wire [31:0] a_in,
    input  wire [31:0] b_in,
    output wire        busy,
    output reg         done,
    output reg  [31:0] gcd_out
);

    // ------------------------------------------------------------------------
    // Datapath: operands and status signals
    // ------------------------------------------------------------------------
    reg  [31:0] a, b;

    wire [32:0] a_minus_b = {1'b0, a} - {1'b0, b};
    wire        a_lt_b    = a_minus_b[32];        // borrow => a < b
    wire        b_zero    = (b == 32'd0);         // loop finished

    // ------------------------------------------------------------------------
    // Controller
    // ------------------------------------------------------------------------
    localparam S_IDLE = 1'b0,
               S_CALC = 1'b1;

    reg state, state_next;
    reg load, swap, sub, fin;                     // control signals (one-hot)

    always @* begin
        state_next = state;
        {load, swap, sub, fin} = 4'b0000;
        case (state)
            S_IDLE:
                if (start) begin
                    load       = 1'b1;
                    state_next = S_CALC;
                end
            S_CALC:
                if (b_zero) begin
                    fin        = 1'b1;
                    state_next = S_IDLE;
                end else if (a_lt_b)
                    swap = 1'b1;
                else
                    sub  = 1'b1;
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            done  <= 1'b0;
        end else begin
            state <= state_next;
            done  <= fin;
        end
    end

    assign busy = (state == S_CALC);              // the state flip-flop itself

    // ------------------------------------------------------------------------
    // Datapath registers
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            a       <= 32'd0;
            b       <= 32'd0;
            gcd_out <= 32'd0;
        end else begin
            if (load) begin
                a <= a_in;
                b <= b_in;
            end else if (swap) begin
                a <= b;
                b <= a;
            end else if (sub) begin
                a <= a_minus_b[31:0];
            end

            if (fin)
                gcd_out <= a;
        end
    end

endmodule
