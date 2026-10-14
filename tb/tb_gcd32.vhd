-- ============================================================================
-- tb_gcd32 : VHDL-2008 testbench for gcd32
--   1) Directed test gcd(14, 161) with a cycle-by-cycle trace
--   2) Corner cases (zeros, equal, powers of two, coprime extremes)
--   3) 10,000 random vectors checked against a reference model
--   Reports latency (cycles from start to done) for every test.
-- Compile with VHDL-2008 (external names are used for the internal trace).
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity tb_gcd32 is
end entity tb_gcd32;

architecture sim of tb_gcd32 is

    constant CLK_PERIOD : time := 10 ns;                 -- 100 MHz

    signal clk     : std_logic := '0';
    signal rst_n   : std_logic := '0';
    signal start   : std_logic := '0';
    signal a_in    : std_logic_vector(31 downto 0) := (others => '0');
    signal b_in    : std_logic_vector(31 downto 0) := (others => '0');
    signal busy    : std_logic;
    signal done    : std_logic;
    signal gcd_out : std_logic_vector(31 downto 0);

    signal trace   : boolean := false;
    signal sim_end : boolean := false;

    -- Unsigned -> decimal string (32-bit values exceed VHDL integer range)
    function to_udec(x : unsigned) return string is
        variable v   : unsigned(x'length - 1 downto 0) := x;
        variable s   : string(1 to 12) := (others => ' ');
        variable idx : integer := 12;
        variable d   : integer;
    begin
        if v = 0 then
            return "0";
        end if;
        while v /= 0 loop
            d      := to_integer(v rem 10);
            s(idx) := character'val(character'pos('0') + d);
            v      := v / 10;
            idx    := idx - 1;
        end loop;
        return s(idx + 1 to 12);
    end function;

    -- Reference model: Euclid with modulo
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

begin

    clk <= not clk after CLK_PERIOD / 2 when not sim_end else '0';

    dut : entity work.gcd32
        port map (clk => clk, rst_n => rst_n, start => start,
                  a_in => a_in, b_in => b_in,
                  busy => busy, done => done, gcd_out => gcd_out);

    -- ---------------- Internal trace (VHDL-2008 external names) ----------------
    trace_p : process (clk)
        alias a_i is << signal .tb_gcd32.dut.a : unsigned(31 downto 0) >>;
        alias b_i is << signal .tb_gcd32.dut.b : unsigned(31 downto 0) >>;
        alias k_i is << signal .tb_gcd32.dut.k : unsigned(4 downto 0) >>;
        variable l : line;
    begin
        if rising_edge(clk) and trace and busy = '1' then
            write(l, "  t=" & time'image(now) &
                     "  a=" & to_udec(a_i) &
                     "  b=" & to_udec(b_i) &
                     "  k=" & integer'image(to_integer(k_i)));
            writeline(output, l);
        end if;
    end process;

    -- ---------------- Stimulus ----------------
    stim_p : process
        variable errors, tests, max_lat, sum_lat : integer := 0;
        variable seed1 : positive := 12345;
        variable seed2 : positive := 67890;
        variable l     : line;

        impure function rnd(bits : natural) return unsigned is
            variable r   : real;
            variable res : unsigned(31 downto 0) := (others => '0');
        begin
            -- build 32 bits from two 16-bit draws
            uniform(seed1, seed2, r);
            res(31 downto 16) := to_unsigned(integer(trunc(r * 65536.0)) mod 65536, 16);
            uniform(seed1, seed2, r);
            res(15 downto 0)  := to_unsigned(integer(trunc(r * 65536.0)) mod 65536, 16);
            if bits < 32 then
                res := res and shift_right(to_unsigned(0, 32) - 1, 32 - bits);
            end if;
            return res;
        end function;

        procedure run(x, y : unsigned(31 downto 0); verbose : boolean) is
            variable lat : integer := 1;
            variable exp : unsigned(31 downto 0);
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
            tests   := tests + 1;
            sum_lat := sum_lat + lat;
            if lat > max_lat then max_lat := lat; end if;

            if unsigned(gcd_out) /= exp then
                errors := errors + 1;
                write(l, "FAIL gcd(" & to_udec(x) & "," & to_udec(y) & ") = " &
                         to_udec(unsigned(gcd_out)) & ", expected " & to_udec(exp));
                writeline(output, l);
            elsif verbose then
                write(l, "PASS gcd(" & to_udec(x) & "," & to_udec(y) & ") = " &
                         to_udec(unsigned(gcd_out)) &
                         "   latency = " & integer'image(lat) & " cycles");
                writeline(output, l);
            end if;
        end procedure;

        procedure banner(s : string) is
        begin
            write(l, LF & "=== " & s & " ===");
            writeline(output, l);
        end procedure;

        variable g : unsigned(31 downto 0);
    begin
        wait for 2 * CLK_PERIOD;
        wait until falling_edge(clk);
        rst_n <= '1';

        -- ---------------- 1) Required test: gcd(14, 161) ----------------
        banner("Directed test: gcd(14, 161)");
        trace <= true;
        run(to_unsigned(14, 32), to_unsigned(161, 32), true);

        -- ---------------- 2) Corner cases ----------------
        banner("Corner cases");
        run(to_unsigned(161, 32),   to_unsigned(14, 32),    true);
        run(to_unsigned(0, 32),     to_unsigned(0, 32),     true);
        run(to_unsigned(0, 32),     to_unsigned(12345, 32), true);
        run(to_unsigned(98765, 32), to_unsigned(0, 32),     true);
        run(to_unsigned(42, 32),    to_unsigned(42, 32),    true);
        run(to_unsigned(1, 32),     to_unsigned(1, 32),     true);
        run(x"80000000", x"40000000", true);
        run(x"FFFFFFFF", x"00000001", true);
        run(x"FFFFFFFF", x"FFFFFFFE", true);
        run(x"B11924E1", x"6D73E55F", true);   -- 2971215073, 1836311903 (Fibonacci)
        trace <= false;

        -- ---------------- 3) Random regression ----------------
        banner("Random regression (10000 vectors)");
        for i in 0 to 9999 loop
            case i mod 3 is
                when 0 =>
                    run(rnd(32), rnd(32), false);
                when 1 =>                                   -- many shared 2s
                    run(rnd(32) and x"FFFF0000", rnd(32) and x"FFFFF000", false);
                when others =>                              -- big common factor
                    g := rnd(16) or to_unsigned(1, 32);
                    run(resize(g * rnd(16), 32), resize(g * rnd(15), 32), false);
            end case;
        end loop;

        banner("Summary");
        write(l, "tests = " & integer'image(tests) & "   errors = " & integer'image(errors));
        writeline(output, l);
        write(l, "max latency = " & integer'image(max_lat) & " cycles   avg latency = " &
                 integer'image(sum_lat / tests) & " cycles");
        writeline(output, l);
        if errors = 0 then
            write(l, string'("ALL TESTS PASSED"));
            writeline(output, l);
        end if;

        sim_end <= true;
        wait;
    end process;

end architecture sim;
