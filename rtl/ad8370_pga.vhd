library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- ad8370_pga.vhd - sterownik wzmacniacza AD8370 (szeregowy interfejs 8-bit)
--
-- Słowo sterujące, MSB pierwszy:
--   bit 7    zakres: 1 = wysoki (HG), 0 = niski (LG)
--   bit 6-0  kod wzmocnienia 0..127
-- Wzmocnienie (liniowe): AV = kod * 0,055744 * (1 + (7,079458 - 1) * MSB)
--
-- Zapis: LTCH low, 8 taktów CLCK. Dane zmieniane przy niskim CLCK,
-- próbkowane na narastającym. LTCH high zatrzaskuje słowo.
-- Po resecie wzmacniacz ma kod LG0 (0x00), więc top powinien wysłać
-- update zaraz po resecie.
--
-- Zegar clk = 100 MHz. Półokres CLCK = 5 taktów (50 ns, okres 100 ns).
-- Minima z noty (tabela 4): tPW 25 ns, tCK 50 ns, tDS 10 ns, tES 20 ns, tEH 10 ns.
--
-- Interfejs: update = impuls (1 takt). Gdy moduł jest zajęty, żądanie jest
-- zapamiętane. Słowo jest czytane w chwili startu.
-- =============================================================================

entity ad8370_pga is
    generic (
        G_HALF_PERIOD : positive := 5     -- takty clk na pół okresu CLCK (>= 3)
    );
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;
        update     : in  std_logic;                       -- impuls: zapis słowa
        gain_word  : in  std_logic_vector(7 downto 0);    -- bit 7 zakres, 6..0 kod
        busy       : out std_logic;
        pga_clk    : out std_logic;                       -- CLCK, pin 13
        pga_data   : out std_logic;                       -- DATA, pin 14
        pga_latch  : out std_logic                        -- LTCH, pin 12
    );
end entity ad8370_pga;

architecture rtl of ad8370_pga is

    -- czasy w taktach clk (10 ns)
    constant C_T_ES : natural := 4;      -- LTCH low -> pierwsze CLCK (min 20 ns), 40 ns
    constant C_T_EH : natural := 5;      -- ostatni CLCK -> LTCH high (min 10 ns), 50 ns

    type t_state is (S_IDLE, S_LATCH_LOW, S_BIT_LO, S_BIT_HI, S_LATCH_HIGH);

    signal state_r   : t_state := S_IDLE;
    signal cnt_r     : unsigned(7 downto 0) := (others => '0');
    signal bit_idx_r : unsigned(2 downto 0) := (others => '0');
    signal sh_r      : std_logic_vector(7 downto 0) := (others => '0');
    signal pending_r : std_logic := '0';

    signal clk_r     : std_logic := '0';
    signal data_r    : std_logic := '0';
    signal latch_r   : std_logic := '1';

begin

    busy      <= '0' when state_r = S_IDLE else '1';
    pga_clk   <= clk_r;
    pga_data  <= data_r;
    pga_latch <= latch_r;

    p_fsm : process (clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state_r   <= S_IDLE;
                cnt_r     <= (others => '0');
                bit_idx_r <= (others => '0');
                sh_r      <= (others => '0');
                pending_r <= '0';
                clk_r     <= '0';
                data_r    <= '0';
                latch_r   <= '1';
            else
                -- żądanie zapamiętywane, także gdy moduł jest zajęty
                if update = '1' then
                    pending_r <= '1';
                end if;

                case state_r is

                    when S_IDLE =>
                        clk_r   <= '0';
                        data_r  <= '0';
                        latch_r <= '1';
                        if update = '1' or pending_r = '1' then
                            pending_r <= '0';
                            sh_r      <= gain_word;
                            bit_idx_r <= (others => '0');
                            latch_r   <= '0';
                            cnt_r     <= to_unsigned(C_T_ES - 1, cnt_r'length);
                            state_r   <= S_LATCH_LOW;
                        end if;

                    -- LTCH low, czekamy tES przed pierwszym CLCK
                    when S_LATCH_LOW =>
                        clk_r   <= '0';
                        latch_r <= '0';
                        data_r  <= sh_r(7);
                        if cnt_r = 0 then
                            cnt_r   <= to_unsigned(G_HALF_PERIOD - 1, cnt_r'length);
                            state_r <= S_BIT_LO;
                        else
                            cnt_r <= cnt_r - 1;
                        end if;

                    -- CLCK niski, bit na DATA (tDS przed narastającym CLCK)
                    when S_BIT_LO =>
                        clk_r  <= '0';
                        data_r <= sh_r(7);
                        if cnt_r = 0 then
                            cnt_r   <= to_unsigned(G_HALF_PERIOD - 1, cnt_r'length);
                            state_r <= S_BIT_HI;
                        else
                            cnt_r <= cnt_r - 1;
                        end if;

                    -- CLCK wysoki, wzmacniacz próbkuje DATA
                    when S_BIT_HI =>
                        clk_r <= '1';
                        if cnt_r = 0 then
                            if bit_idx_r = 7 then
                                cnt_r   <= to_unsigned(C_T_EH - 1, cnt_r'length);
                                state_r <= S_LATCH_HIGH;
                            else
                                sh_r      <= sh_r(6 downto 0) & '0';
                                bit_idx_r <= bit_idx_r + 1;
                                cnt_r     <= to_unsigned(G_HALF_PERIOD - 1, cnt_r'length);
                                state_r   <= S_BIT_LO;
                            end if;
                        else
                            cnt_r <= cnt_r - 1;
                        end if;

                    -- po ostatnim CLCK: CLCK niski, potem LTCH high (tEH)
                    when S_LATCH_HIGH =>
                        clk_r   <= '0';
                        latch_r <= '0';
                        if cnt_r = 0 then
                            latch_r <= '1';
                            state_r <= S_IDLE;
                        else
                            cnt_r <= cnt_r - 1;
                        end if;

                end case;
            end if;
        end if;
    end process p_fsm;

end architecture rtl;
