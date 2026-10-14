-- ============================================================================
-- gcd32 : 32-bit GCD unit, binary (Stein's) algorithm, FPGA-oriented (VHDL)
-- ----------------------------------------------------------------------------
-- Functionally identical to gcd32.v.
--
-- Per-cycle step (all decisions in ONE clock):
--   a = b                -> done, gcd = a << k
--   a even & b even      -> a>>=1, b>>=1, k++     (common factor of 2)
--   a even (b odd)       -> a>>=1
--   b even (a odd)       -> b>>=1
--   both odd, a > b      -> a = (a-b)>>1          (a-b is even, shift is free)
--   both odd, a < b      -> b = (b-a)>>1
--
-- Worst case ~64 iterations, area ~ two 32-bit subtractors + muxes + regs.
-- Handshake: pulse start with operands valid; done pulses for 1 cycle with
-- gcd_out valid (gcd_out holds until next start).
-- Convention: gcd(x,0) = x, gcd(0,0) = 0.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gcd32 is
    port (
        clk     : in  std_logic;
        rst_n   : in  std_logic;                      -- active-low sync reset
        start   : in  std_logic;
        a_in    : in  std_logic_vector(31 downto 0);
        b_in    : in  std_logic_vector(31 downto 0);
        busy    : out std_logic;
        done    : out std_logic;
        gcd_out : out std_logic_vector(31 downto 0)
    );
end entity gcd32;

architecture rtl of gcd32 is

    signal a, b      : unsigned(31 downto 0) := (others => '0');
    signal k         : unsigned(4 downto 0)  := (others => '0');   -- max 31
    signal busy_r    : std_logic := '0';
    signal done_r    : std_logic := '0';
    signal gcd_r     : unsigned(31 downto 0) := (others => '0');

    -- Two subtractors in parallel; the borrow of (a-b) selects the result,
    -- avoiding a serial compare->subtract path.
    signal a_minus_b : unsigned(32 downto 0);
    signal b_minus_a : unsigned(31 downto 0);
    signal a_lt_b    : std_logic;
    signal eq        : std_logic;

begin

    a_minus_b <= ('0' & a) - ('0' & b);
    b_minus_a <= b - a;
    a_lt_b    <= a_minus_b(32);                          -- borrow => a < b
    eq        <= '1' when a = b else '0';

    process (clk)
        variable sel : std_logic_vector(1 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                a      <= (others => '0');
                b      <= (others => '0');
                k      <= (others => '0');
                busy_r <= '0';
                done_r <= '0';
                gcd_r  <= (others => '0');
            else
                done_r <= '0';

                if start = '1' and busy_r = '0' then
                    -- Zero operands resolved immediately (no iterations)
                    if unsigned(a_in) = 0 or unsigned(b_in) = 0 then
                        gcd_r  <= unsigned(a_in) or unsigned(b_in);
                        done_r <= '1';
                    else
                        a      <= unsigned(a_in);
                        b      <= unsigned(b_in);
                        k      <= (others => '0');
                        busy_r <= '1';
                    end if;

                elsif busy_r = '1' then
                    if eq = '1' then
                        gcd_r  <= shift_left(a, to_integer(k)); -- restore 2^k
                        busy_r <= '0';
                        done_r <= '1';
                    else
                        sel := a(0) & b(0);
                        case sel is
                            when "00" =>                          -- both even
                                a <= shift_right(a, 1);
                                b <= shift_right(b, 1);
                                k <= k + 1;
                            when "01" =>                          -- a even
                                a <= shift_right(a, 1);
                            when "10" =>                          -- b even
                                b <= shift_right(b, 1);
                            when others =>                        -- both odd
                                if a_lt_b = '1' then
                                    b <= shift_right(b_minus_a, 1);
                                else
                                    a <= shift_right(a_minus_b(31 downto 0), 1);
                                end if;
                        end case;
                    end if;
                end if;
            end if;
        end if;
    end process;

    busy    <= busy_r;
    done    <= done_r;
    gcd_out <= std_logic_vector(gcd_r);

end architecture rtl;
