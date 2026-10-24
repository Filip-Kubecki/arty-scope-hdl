library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.regmap_pkg.all;

-- =============================================================================
-- sample_decimator.vhd - decymacja strumienia próbek w logice FPGA
--
-- Przepuszcza co N-tą próbkę wejściową (N = decimation, 1 = bez decymacji).
-- Liczy tylko próbki z sample_valid_in = '1'. Wyjście jest rejestrowane,
-- opóźnienie 1 takt.
--
-- Decymacja nie filtruje sygnału, więc działa jak zmiana częstotliwości
-- próbkowania: aliasing jest taki sam jak przy niższym zegarze.
--
-- decimation zmienia się tylko przez COMMIT w IDLE, więc w czasie
-- akwizycji jest stała.
-- =============================================================================

entity sample_decimator is
    port (
        clk              : in  std_logic;
        rst              : in  std_logic;
        decimation       : in  unsigned(15 downto 0);   -- N >= 1

        sample_valid_in  : in  std_logic;
        ch1_in           : in  byte_t;
        ch2_in           : in  byte_t;

        sample_valid_out : out std_logic;
        ch1_out          : out byte_t;
        ch2_out          : out byte_t
    );
end entity sample_decimator;

architecture rtl of sample_decimator is

    -- licznik w dół: 0 oznacza, że bieżąca próbka przechodzi dalej
    signal count_r     : unsigned(15 downto 0) := (others => '0');
    signal valid_r     : std_logic := '0';
    signal ch1_r       : byte_t    := (others => '0');
    signal ch2_r       : byte_t    := (others => '0');

begin

    sample_valid_out <= valid_r;
    ch1_out          <= ch1_r;
    ch2_out          <= ch2_r;

    p_dec : process (clk)
        variable v_period : unsigned(15 downto 0);
    begin
        if rising_edge(clk) then
            valid_r <= '0';

            if rst = '1' then
                count_r <= (others => '0');

            elsif sample_valid_in = '1' then
                if count_r = 0 then
                    valid_r <= '1';
                    ch1_r   <= ch1_in;
                    ch2_r   <= ch2_in;

                    -- N = 0 traktujemy jak 1 (bez decymacji)
                    if decimation <= 1 then
                        v_period := (others => '0');
                    else
                        v_period := decimation - 1;
                    end if;
                    count_r <= v_period;
                else
                    count_r <= count_r - 1;
                end if;
            end if;
        end if;
    end process p_dec;

end architecture rtl;
