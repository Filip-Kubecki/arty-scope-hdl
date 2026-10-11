library ieee;
use ieee.std_logic_1164.all;
use work.regmap_pkg.all;

-- =============================================================================
-- adc_mcp3201.vhd - wrapper na adc mcp3201
-- Źródło próbek oparte na MCP3201 (12 bitów, jeden kanał, SPI).
-- Zgodne z kontraktem: sample_valid, ch1, ch2 po 8 bitów.
-- Próbka 12-bitowa jest obcinana do 8 starszych bitów. ch2 jest zerem.
-- =============================================================================

entity adc_mcp3201 is
    port (
        clk          : in  std_logic;
        rst          : in  std_logic;
        enable       : in  std_logic;             -- '1' = produkuj próbki
        sample_valid : out std_logic;             -- impuls: próbka gotowa
        ch1          : out byte_t;
        ch2          : out byte_t;                -- zawsze 0, jeden kanał

        -- piny MCP3201
        adc_clk      : out std_logic;
        adc_cs       : out std_logic;
        adc_dout     : in  std_logic
    );
end entity adc_mcp3201;

architecture rtl of adc_mcp3201 is

    signal data12  : std_logic_vector(11 downto 0);
    signal valid12 : std_logic;

begin

    u_reader : entity work.mcp3201_spi
        port map (
            Clock100MHz => clk,
            reset       => rst,
            enable      => enable,
            ADC_CLK     => adc_clk,
            ADC_CS      => adc_cs,
            ADC_DOUT    => adc_dout,
            data_out    => data12,
            data_valid  => valid12
        );

    sample_valid <= valid12;
    ch1          <= data12(11 downto 4);
    ch2          <= (others => '0');

end architecture rtl;
