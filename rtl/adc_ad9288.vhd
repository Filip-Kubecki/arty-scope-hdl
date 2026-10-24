library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.regmap_pkg.all;

-- =============================================================================
-- adc_ad9288.vhd - odbiór próbek z AD9288 (100 MSPS, 2 kanały, 8 bitów)
--
-- Tor danych kanału: AD9288 -> MC74LCX374 (rejestr na tym samym zegarze ENC)
-- -> piny FPGA -> rejestry IOB w tym module.
--
-- Zegar ENC (ENCA dla kanału A, ENCB dla kanału B) wyprowadza FPGA przez
-- ODDR z jednego MMCM. Ten sam zegar taktuje rejestr 74LCX374 danego kanału.
--
-- Stałe ustawienia:
--   DFS = niski (offset binary, środek skali 0x80)
--   S1  = 1, S2 = 0 (tryb normalny)
--   OC rejestrów 374 = GND (wyjścia zawsze aktywne)
--
-- Latencja od zbocza ENC do rejestru IOB: ok. 4 takty przetwornika + 1 takt
-- 374 + 1 takt IOB. Jest stała, więc nie wpływa na wyzwalanie.
--
-- Okno danych przy FPGA jest wąskie. Zapas setup/hold w samym 374 to ok.
-- 1,5 ns / 0,5 ns przed skew na płytce, a 374 dokłada własne opóźnienie CP->Q
-- (1,5-8,5 ns). Dlatego przed rejestrami IOB przewidziane jest opóźnienie IDELAY
-- na każdej linii danych. Wartość dobieramy skanem na płytce, nie z góry.
-- Opóźnienie IDELAY dodawane jest w osobnym module (po podaniu pinów).
--
-- Decymacja nie jest tutaj. Działa w osobnym module sample_decimator na
-- tym samym interfejsie próbek.
-- =============================================================================

entity adc_ad9288 is
    port (
        clk          : in  std_logic;                     -- zegar capture (100 MHz, z MMCM)
        enable       : in  std_logic;                     -- '1' = próbki ważne
        adc_a_data   : in  std_logic_vector(7 downto 0);  -- wyjście 374, kanał A
        adc_b_data   : in  std_logic_vector(7 downto 0);  -- wyjście 374, kanał B

        sample_valid : out std_logic;
        ch1          : out byte_t;                        -- kanał A
        ch2          : out byte_t                         -- kanał B
    );
end entity adc_ad9288;

architecture rtl of adc_ad9288 is

    -- rejestry wejściowe w komórkach IOB, bezpośrednio przy pinach
    signal a_in_r   : std_logic_vector(7 downto 0) := (others => '0');
    signal b_in_r   : std_logic_vector(7 downto 0) := (others => '0');
    signal enable_r : std_logic := '0';

    attribute IOB : string;
    attribute IOB of a_in_r : signal is "TRUE";
    attribute IOB of b_in_r : signal is "TRUE";

begin

    p_in : process (clk)
    begin
        if rising_edge(clk) then
            a_in_r   <= adc_a_data;
            b_in_r   <= adc_b_data;
            enable_r <= enable;
        end if;
    end process p_in;

    sample_valid <= enable_r;
    ch1          <= a_in_r;
    ch2          <= b_in_r;

end architecture rtl;
