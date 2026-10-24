library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- mcp4822_dac.vhd - sterownik DAC MCP4822 (2 x 12 bit, SPI) do kalibracji
-- offsetu DC obu kanałów.
--
-- Ramka zapisu: 16 bitów, MSB first, SPI tryb 0,0 (SCK w spoczynku niski).
--   bit 15    A/B   : 0 = DAC A, 1 = DAC B
--   bit 14    -     : bez znaczenia (0)
--   bit 13    GA    : 1 = wzmocnienie 1x (VOUT = VREF*D/4096), 0 = 2x
--   bit 12    SHDN  : 1 = kanał aktywny
--   bit 11-0  D     : kod 0..4095
--
-- Sekwencja update:
--   1. ramka A (CS low, 16 taktów SCK, CS high)
--   2. ramka B (CS low, 16 taktów SCK, CS high)
--   3. impuls LDAC low -> oba wyjścia zmieniają się jednocześnie
--
-- Zegar clk = 100 MHz. G_HALF_PERIOD = 5 -> SCK 10 MHz (limit noty 20 MHz).
-- Odstępy tCSSR, tCSH, tLS, tLD liczone w taktach clk z zapasem
-- względem minimum z noty.
--
-- Zasilanie: VDD = 5 V. Wejścia DAC (CS, SCK, SDI, LDAC) sterowane z FPGA
-- przez translatory 3,3 V -> 5 V (strona 5 V daje poziom bliski 5 V).
-- VIH = 0,7*VDD = 3,5 V, VIL max = 0,2*VDD = 1 V.
--
-- Interfejs: update = impuls (1 takt). Gdy moduł jest zajęty, żądanie jest
-- zapamiętane i obsłużone po zakończeniu. Kody są czytane w chwili startu.
-- Po resecie wyjścia są w wysokiej impedancji, więc top powinien wysłać
-- update zaraz po resecie.
-- =============================================================================

entity mcp4822_dac is
    generic (
        G_HALF_PERIOD : positive := 5;      -- takty clk na pół okresu SCK (>= 2)
        G_GAIN_1X     : boolean  := true    -- true: 1x (0..VREF), false: 2x (0..2*VREF)
    );
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;
        update     : in  std_logic;                      -- impuls: zapis obu kanałów + LDAC
        code_a     : in  std_logic_vector(11 downto 0);  -- kod offsetu kanału A
        code_b     : in  std_logic_vector(11 downto 0);  -- kod offsetu kanału B
        busy       : out std_logic;
        dac_cs_n   : out std_logic;
        dac_sck    : out std_logic;
        dac_sdi    : out std_logic;
        dac_ldac_n : out std_logic
    );
end entity mcp4822_dac;

architecture rtl of mcp4822_dac is

    -- czasy w taktach clk (100 MHz -> 10 ns)
    constant C_T_CSSR   : natural := 4;     -- CS low -> pierwsze zbocze SCK (min 40 ns)
    constant C_T_CSH    : natural := 4;     -- CS high między ramkami (min 15 ns)
    constant C_T_LS     : natural := 5;     -- CS high -> LDAC low (min 40 ns)
    constant C_T_LD     : natural := 12;    -- impuls LDAC low (min 100 ns)

    -- bit GA z generica (VHDL-2008: bez wyrażenia warunkowego w stałej)
    function gain_bit return std_logic is
    begin
        if G_GAIN_1X then
            return '1';
        else
            return '0';
        end if;
    end function gain_bit;

    type t_state is (S_IDLE, S_SETUP, S_LO, S_HI, S_TCHS, S_CSH, S_LDAC_WAIT, S_LDAC_LOW);

    signal state_r   : t_state := S_IDLE;
    signal cnt_r     : unsigned(7 downto 0) := (others => '0');
    signal bit_cnt_r : unsigned(3 downto 0) := (others => '0');
    signal frame_r   : std_logic := '0';    -- 0 = ramka A, 1 = ramka B
    signal pending_r : std_logic := '0';
    signal sh_r      : std_logic_vector(15 downto 0) := (others => '0');
    signal word_b_r  : std_logic_vector(15 downto 0) := (others => '0');

    signal cs_n_r    : std_logic := '1';
    signal sck_r     : std_logic := '0';
    signal sdi_r     : std_logic := '0';
    signal ldac_n_r  : std_logic := '1';

    -- budowa 16-bitowej ramki zapisu MCP4822
    function make_word (
        is_b : std_logic;
        gain : std_logic;
        code : std_logic_vector(11 downto 0)
    ) return std_logic_vector is
        variable w : std_logic_vector(15 downto 0) := (others => '0');
    begin
        w(15)          := is_b;
        w(13)          := gain;
        w(12)          := '1';              -- SHDN = 1: kanał aktywny
        w(11 downto 0) := code;
        return w;
    end function make_word;

begin

    busy       <= '0' when state_r = S_IDLE else '1';
    dac_cs_n   <= cs_n_r;
    dac_sck    <= sck_r;
    dac_sdi    <= sdi_r;
    dac_ldac_n <= ldac_n_r;

    p_fsm : process (clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state_r   <= S_IDLE;
                cnt_r     <= (others => '0');
                bit_cnt_r <= (others => '0');
                frame_r   <= '0';
                pending_r <= '0';
                sh_r      <= (others => '0');
                word_b_r  <= (others => '0');
                cs_n_r    <= '1';
                sck_r     <= '0';
                sdi_r     <= '0';
                ldac_n_r  <= '1';
            else
                -- żądanie zapamiętywane, także gdy moduł jest zajęty
                if update = '1' then
                    pending_r <= '1';
                end if;

                case state_r is

                    when S_IDLE =>
                        cs_n_r   <= '1';
                        sck_r    <= '0';
                        ldac_n_r <= '1';
                        if update = '1' or pending_r = '1' then
                            pending_r <= '0';
                            sh_r      <= make_word('0', gain_bit, code_a);
                            word_b_r  <= make_word('1', gain_bit, code_b);
                            frame_r   <= '0';
                            bit_cnt_r <= (others => '0');
                            cs_n_r    <= '0';
                            cnt_r     <= to_unsigned(C_T_CSSR - 1, cnt_r'length);
                            state_r   <= S_SETUP;
                        end if;

                    -- CS low, czekamy tCSSR przed pierwszym zboczem SCK
                    when S_SETUP =>
                        cs_n_r <= '0';
                        sck_r  <= '0';
                        if cnt_r = 0 then
                            cnt_r   <= to_unsigned(G_HALF_PERIOD - 1, cnt_r'length);
                            state_r <= S_LO;
                        else
                            cnt_r <= cnt_r - 1;
                        end if;

                    -- SCK niski, bit na SDI (zmiana przy opadającym SCK)
                    when S_LO =>
                        sck_r <= '0';
                        sdi_r <= sh_r(15);
                        if cnt_r = 0 then
                            cnt_r   <= to_unsigned(G_HALF_PERIOD - 1, cnt_r'length);
                            state_r <= S_HI;
                        else
                            cnt_r <= cnt_r - 1;
                        end if;

                    -- SCK wysoki, DAC próbkuje SDI na tym zboczu
                    when S_HI =>
                        sck_r <= '1';
                        if cnt_r = 0 then
                            if bit_cnt_r = 15 then
                                cnt_r   <= to_unsigned(G_HALF_PERIOD - 1, cnt_r'length);
                                state_r <= S_TCHS;
                            else
                                sh_r      <= sh_r(14 downto 0) & '0';
                                bit_cnt_r <= bit_cnt_r + 1;
                                cnt_r     <= to_unsigned(G_HALF_PERIOD - 1, cnt_r'length);
                                state_r   <= S_LO;
                            end if;
                        else
                            cnt_r <= cnt_r - 1;
                        end if;

                    -- po ostatnim zboczu: SCK niski, potem CS high (tCHS)
                    when S_TCHS =>
                        sck_r <= '0';
                        if cnt_r = 0 then
                            cnt_r   <= to_unsigned(C_T_CSH - 1, cnt_r'length);
                            state_r <= S_CSH;
                        else
                            cnt_r <= cnt_r - 1;
                        end if;

                    -- CS high: po ramce A ramka B, po ramce B LDAC
                    when S_CSH =>
                        cs_n_r   <= '1';
                        sck_r    <= '0';
                        ldac_n_r <= '1';
                        if cnt_r = 0 then
                            if frame_r = '0' then
                                frame_r   <= '1';
                                sh_r      <= word_b_r;
                                bit_cnt_r <= (others => '0');
                                cs_n_r    <= '0';
                                cnt_r     <= to_unsigned(C_T_CSSR - 1, cnt_r'length);
                                state_r   <= S_SETUP;
                            else
                                cnt_r   <= to_unsigned(C_T_LS - 1, cnt_r'length);
                                state_r <= S_LDAC_WAIT;
                            end if;
                        else
                            cnt_r <= cnt_r - 1;
                        end if;

                    -- tLS: od CS high do LDAC low
                    when S_LDAC_WAIT =>
                        cs_n_r   <= '1';
                        sck_r    <= '0';
                        ldac_n_r <= '1';
                        if cnt_r = 0 then
                            cnt_r   <= to_unsigned(C_T_LD - 1, cnt_r'length);
                            state_r <= S_LDAC_LOW;
                        else
                            cnt_r <= cnt_r - 1;
                        end if;

                    -- LDAC low: przepisanie rejestrów wejściowych do wyjść DAC
                    when S_LDAC_LOW =>
                        cs_n_r   <= '1';
                        ldac_n_r <= '0';
                        if cnt_r = 0 then
                            state_r <= S_IDLE;
                        else
                            cnt_r <= cnt_r - 1;
                        end if;

                end case;
            end if;
        end if;
    end process p_fsm;

end architecture rtl;