library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- dac_offset_test.vhd - test sprzętowy MCP4822
-- Kanał A: rampa 0..4095, krok co 1 ms (pełny przebieg ok. 4,1 s).
-- Kanał B: stały środek skali 0x800.
-- Zegar płytki 100 MHz, reset z licznika po starcie.
-- =============================================================================

entity dac_offset_test is
    port (
        CLK100MHZ  : in  std_logic;
        dac_cs_n   : out std_logic;
        dac_sck    : out std_logic;
        dac_sdi    : out std_logic;
        dac_ldac_n : out std_logic
    );
end entity dac_offset_test;

architecture rtl of dac_offset_test is

    constant C_TICK_DIV : natural := 488_281;      -- 1 ms przy 100 MHz

    signal por_cnt  : unsigned(15 downto 0) := (others => '0');
    signal rst      : std_logic := '1';
    signal tick_cnt : unsigned(18 downto 0) := (others => '0');
    signal tick     : std_logic := '0';
    signal ramp     : unsigned(11 downto 0) := (others => '0');

begin

    -- reset po starcie: ok. 0,65 ms
    p_por : process (CLK100MHZ)
    begin
        if rising_edge(CLK100MHZ) then
            if por_cnt /= x"FFFF" then
                por_cnt <= por_cnt + 1;
                rst     <= '1';
            else
                rst     <= '0';
            end if;
        end if;
    end process p_por;

    -- impuls co 1 ms i krok rampy
    p_tick : process (CLK100MHZ)
    begin
        if rising_edge(CLK100MHZ) then
            tick <= '0';
            if rst = '1' then
                tick_cnt <= (others => '0');
                ramp     <= (others => '0');
            elsif tick_cnt = C_TICK_DIV - 1 then
                tick_cnt <= (others => '0');
                tick     <= '1';
                ramp     <= ramp + 1;
            else
                tick_cnt <= tick_cnt + 1;
            end if;
        end if;
    end process p_tick;

    u_dac : entity work.mcp4822_dac
        generic map (
            G_HALF_PERIOD => 5,
            G_GAIN_1X     => true
        )
        port map (
            clk        => CLK100MHZ,
            rst        => rst,
            update     => tick,
            code_a     => std_logic_vector(ramp),
            code_b     => x"800",
            busy       => open,
            dac_cs_n   => dac_cs_n,
            dac_sck    => dac_sck,
            dac_sdi    => dac_sdi,
            dac_ldac_n => dac_ldac_n
        );

end architecture rtl;
