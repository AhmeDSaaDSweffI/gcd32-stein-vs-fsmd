-- ============================================================================
-- tb_gcd32_vhdl : self-checking VHDL-2008 testbench for the VHDL gcd32
-- ----------------------------------------------------------------------------
-- The VHDL core (work.gcd32) runs in lockstep with the Verilog core
-- (verilog_lib.gcd32) on the same clock, reset and operands, and their
-- outputs are compared on every clock cycle. Every operation is also checked
-- against a Euclid reference (result) and the Stein cycle model (latency).
--
--   1) gcd(14, 161) with a cycle-by-cycle trace
--   2) the 18 directed vectors of the board test (zynq/gcd32/main.c)
--   3) all operand pairs 0..255
--   4) the 10,000 random vectors of the board test (xorshift32 of main.c)
--
-- Latency = cycles from the start cycle to the done cycle, as in the Verilog
-- testbenches and the CYCLES register on the board.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

library verilog_lib;

entity tb_gcd32_vhdl is
end entity tb_gcd32_vhdl;

architecture sim of tb_gcd32_vhdl is

    constant T : time := 10 ns;                           -- 100 MHz

    signal clk     : std_logic := '0';
    signal rst_n   : std_logic := '0';
    signal start   : std_logic := '0';
    signal a_in    : std_logic_vector(31 downto 0) := (others => '0');
    signal b_in    : std_logic_vector(31 downto 0) := (others => '0');
    signal busy    : std_logic;
    signal done    : std_logic;
    signal gcd_out : std_logic_vector(31 downto 0);

    -- Verilog core on the same inputs
    signal busy_v    : std_logic;
    signal done_v    : std_logic;
    signal gcd_out_v : std_logic_vector(31 downto 0);

    signal running    : boolean := true;
    signal trace      : boolean := false;
    signal mismatches : natural := 0;

    -- Unsigned -> decimal string (32-bit values exceed the VHDL integer range)
    function to_udec(x : unsigned) return string is
        variable v   : unsigned(x'length - 1 downto 0) := x;
        variable s   : string(1 to 12) := (others => ' ');
        variable idx : integer := 12;
    begin
        if v = 0 then
            return "0";
        end if;
        while v /= 0 loop
            s(idx) := character'val(character'pos('0') + to_integer(v rem 10));
            v      := v / 10;
            idx    := idx - 1;
        end loop;
        return s(idx + 1 to 12);
    end function;

    -- num / den with two decimals
    function fmt2(num, den : natural) return string is
        constant v : natural := (num * 100 + den / 2) / den;
    begin
        if v mod 100 < 10 then
            return integer'image(v / 100) & ".0" & integer'image(v mod 100);
        end if;
        return integer'image(v / 100) & "." & integer'image(v mod 100);
    end function;

    -- Reference result: Euclid with modulo
    function ref_gcd(x, y : unsigned(31 downto 0)) return unsigned is
        variable p : unsigned(31 downto 0) := x;
        variable q : unsigned(31 downto 0) := y;
        variable t : unsigned(31 downto 0);
    begin
        while q /= 0 loop
            t := p rem q;
            p := q;
            q := t;
        end loop;
        return p;
    end function;

    -- Reference latency: start cycle, one cycle per Stein step, then the
    -- a = b cycle; zero operands finish in the start cycle
    function stein_cycles(x, y : unsigned(31 downto 0)) return natural is
        variable a : unsigned(31 downto 0) := x;
        variable b : unsigned(31 downto 0) := y;
        variable n : natural := 1;
    begin
        if a = 0 or b = 0 then
            return 1;
        end if;
        loop
            n := n + 1;
            exit when a = b;
            if a(0) = '0' and b(0) = '0' then
                a := shift_right(a, 1);
                b := shift_right(b, 1);
            elsif a(0) = '0' then
                a := shift_right(a, 1);
            elsif b(0) = '0' then
                b := shift_right(b, 1);
            elsif a < b then
                b := shift_right(b - a, 1);
            else
                a := shift_right(a - b, 1);
            end if;
        end loop;
        return n;
    end function;

    -- Operand generator of the board test
    function xorshift32(x : unsigned(31 downto 0)) return unsigned is
        variable v : unsigned(31 downto 0) := x;
    begin
        v := v xor shift_left(v, 13);
        v := v xor shift_right(v, 17);
        v := v xor shift_left(v, 5);
        return v;
    end function;

begin

    clk <= not clk after T / 2 when running else '0';

    dut : entity work.gcd32                              -- VHDL core under test
        port map (clk => clk, rst_n => rst_n, start => start,
                  a_in => a_in, b_in => b_in,
                  busy => busy, done => done, gcd_out => gcd_out);

    ref : entity verilog_lib.gcd32                       -- Verilog core
        port map (clk => clk, rst_n => rst_n, start => start,
                  a_in => a_in, b_in => b_in,
                  busy => busy_v, done => done_v, gcd_out => gcd_out_v);

    -- ---------------- Lockstep check, every clock cycle ----------------
    lockstep : process (clk)
        variable l : line;
    begin
        if falling_edge(clk) and rst_n = '1' then
            if busy /= busy_v or done /= done_v or gcd_out /= gcd_out_v then
                if mismatches < 10 then
                    write(l, "MISMATCH at " & integer'image(now / 1 ns) & " ns: VHDL gcd_out = " &
                             to_udec(unsigned(gcd_out)) & ", Verilog gcd_out = " &
                             to_udec(unsigned(gcd_out_v)));
                    writeline(output, l);
                end if;
                mismatches <= mismatches + 1;
            end if;
        end if;
    end process;

    -- ---------------- Trace of the VHDL core registers ----------------
    trace_p : process (clk)
        alias a_i is << signal .tb_gcd32_vhdl.dut.a : unsigned(31 downto 0) >>;
        alias b_i is << signal .tb_gcd32_vhdl.dut.b : unsigned(31 downto 0) >>;
        alias k_i is << signal .tb_gcd32_vhdl.dut.k : unsigned(4 downto 0) >>;
        variable l : line;
    begin
        if rising_edge(clk) and trace and (start = '1' or busy = '1') then
            write(l, "  " & integer'image(now / 1 ns) & " ns   a = " & to_udec(a_i) &
                     "   b = " & to_udec(b_i) & "   k = " & integer'image(to_integer(k_i)));
            writeline(output, l);
        end if;
    end process;

    -- ---------------- Stimulus and checks ----------------
    stim : process
        variable l       : line;
        variable tests   : natural := 0;
        variable errors  : natural := 0;
        variable n_sec   : natural := 0;
        variable sum_sec : natural := 0;
        variable max_sec : natural := 0;
        variable rng     : unsigned(31 downto 0);
        variable x, y, g : unsigned(31 downto 0);

        procedure banner(s : string) is
        begin
            write(l, LF & "=== " & s & " ===");
            writeline(output, l);
            n_sec   := 0;
            sum_sec := 0;
            max_sec := 0;
        end procedure;

        procedure stats is
        begin
            write(l, "  vectors = " & integer'image(n_sec) & "   total = " &
                     integer'image(sum_sec) & " cycles   avg = " & fmt2(sum_sec, n_sec) &
                     " cycles   max = " & integer'image(max_sec) & " cycles");
            writeline(output, l);
        end procedure;

        -- One operation: apply operands and start on a falling edge, count the
        -- cycles until done, check result and latency
        procedure run(x, y : unsigned(31 downto 0); verbose : boolean) is
            variable lat     : natural := 1;
            variable exp     : unsigned(31 downto 0);
            variable exp_lat : natural;
        begin
            wait until falling_edge(clk);
            a_in  <= std_logic_vector(x);
            b_in  <= std_logic_vector(y);
            start <= '1';
            wait until falling_edge(clk);
            start <= '0';
            while done /= '1' loop
                wait until falling_edge(clk);
                lat := lat + 1;
            end loop;
            exp     := ref_gcd(x, y);
            exp_lat := stein_cycles(x, y);
            tests   := tests + 1;
            n_sec   := n_sec + 1;
            sum_sec := sum_sec + lat;
            if lat > max_sec then
                max_sec := lat;
            end if;
            if unsigned(gcd_out) /= exp or lat /= exp_lat then
                errors := errors + 1;
                write(l, "FAIL gcd(" & to_udec(x) & "," & to_udec(y) & ") = " &
                         to_udec(unsigned(gcd_out)) & " in " & integer'image(lat) &
                         " cycles, expected " & to_udec(exp) & " in " & integer'image(exp_lat));
                writeline(output, l);
            elsif verbose then
                write(l, "  PASS gcd(" & to_udec(x) & "," & to_udec(y) & ") = " &
                         to_udec(unsigned(gcd_out)) & "   " & integer'image(lat) & " cycles");
                writeline(output, l);
            end if;
        end procedure;

    begin
        -- Two reset cycles; operands then change on falling edges only
        wait until falling_edge(clk);
        wait until falling_edge(clk);
        rst_n <= '1';

        -- 1) Required test
        banner("1) gcd(14, 161): VHDL core registers before each rising clock edge");
        trace <= true;
        run(to_unsigned(14, 32), to_unsigned(161, 32), true);
        trace <= false;
        for i in 1 to 3 loop                       -- idle gap, keeps the waveform clear
            wait until falling_edge(clk);
        end loop;

        -- 2) Directed vectors of the board test
        banner("2) Directed vectors of the board test");
        run(to_unsigned(14, 32),        to_unsigned(161, 32),        true);
        run(to_unsigned(161, 32),       to_unsigned(14, 32),         true);
        run(to_unsigned(0, 32),         to_unsigned(0, 32),          true);
        run(to_unsigned(0, 32),         to_unsigned(12345, 32),      true);
        run(to_unsigned(98765, 32),     to_unsigned(0, 32),          true);
        run(to_unsigned(42, 32),        to_unsigned(42, 32),         true);
        run(to_unsigned(1, 32),         to_unsigned(1, 32),          true);
        run(to_unsigned(48, 32),        to_unsigned(180, 32),        true);
        run(to_unsigned(1071, 32),      to_unsigned(462, 32),        true);
        run(to_unsigned(360, 32),       to_unsigned(1001, 32),       true);
        run(to_unsigned(111546435, 32), to_unsigned(5311488, 32),    true);
        run(x"80000000",                x"40000000",                 true);
        run(x"80000000",                x"00300000",                 true);
        run(x"FFFFFFFF",                x"00000001",                 true);
        run(x"FFFFFFFF",                x"FFFFFFFE",                 true);   -- worst case, 64 cycles
        run(x"FFFFFFFF",                x"FFFFFFFF",                 true);
        run(x"B11924E1",                to_unsigned(1836311903, 32), true);   -- consecutive Fibonacci
        run(x"FFFFFFFB",                x"FFFFFFEF",                 true);   -- two largest 32-bit primes

        -- 3) Exhaustive 8-bit operands
        banner("3) All operand pairs 0..255");
        for i in 0 to 255 loop
            for j in 0 to 255 loop
                run(to_unsigned(i, 32), to_unsigned(j, 32), false);
            end loop;
        end loop;
        stats;

        -- 4) Random vectors of the board test
        banner("4) The 10,000 random vectors of the board test (xorshift32)");
        rng := x"2545F491";
        for i in 0 to 9999 loop
            case i mod 3 is
                when 0 =>
                    rng := xorshift32(rng);  x := rng;
                    rng := xorshift32(rng);  y := rng;
                when 1 =>                                -- many common factors of two
                    rng := xorshift32(rng);  x := rng and x"FFFF0000";
                    rng := xorshift32(rng);  y := rng and x"FFFFF000";
                when others =>                           -- large common factor
                    rng := xorshift32(rng);  g := (rng and x"0000FFFF") or x"00000001";
                    rng := xorshift32(rng);  x := g(15 downto 0) * rng(15 downto 0);
                    rng := xorshift32(rng);  y := g(15 downto 0) * (rng(15 downto 0) and x"7FFF");
            end case;
            run(x, y, false);
        end loop;
        stats;

        -- Let the lockstep checker see the last cycle, then report
        wait until falling_edge(clk);
        wait until falling_edge(clk);
        write(l, LF & "=== Summary ===" & LF & "tests = " & integer'image(tests) &
                 "   result/latency errors = " & integer'image(errors) &
                 "   cycles where VHDL and Verilog outputs differ = " & integer'image(mismatches));
        writeline(output, l);
        if errors = 0 and mismatches = 0 then
            write(l, string'("ALL TESTS PASSED"));
        else
            write(l, string'("TESTS FAILED"));
        end if;
        writeline(output, l);
        running <= false;
        wait;
    end process;

end architecture sim;
