--------------------------------------------------------------------------------
-- mcp3201_spi.vhd
--
-- SPI master for the MCP3201 12-bit ADC. Drives ADC_CLK and ADC_CS, reads
-- the serial conversion result on ADC_DOUT, and outputs the 12-bit sample
-- with a one-cycle data_valid pulse. SPI clock runs at ~1.5625MHz, derived
-- from the 100MHz system clock via PRESCALER.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity mcp3201_spi is
    Port(
        Clock100MHz : in  STD_LOGIC;
        reset       : in  STD_LOGIC;
        enable      : in  STD_LOGIC;
        ADC_CLK     : out STD_LOGIC;
        ADC_CS      : out STD_LOGIC;
        ADC_DOUT    : in  STD_LOGIC;
        data_out    : out STD_LOGIC_VECTOR(11 downto 0);
        data_valid  : out STD_LOGIC
    );
end mcp3201_spi;

architecture Behavioral of mcp3201_spi is
    -- ADC_SAMPLE: 2 SPI clock cycles for the converter's sample/hold window
    -- ADC_NULL: 1 cycle for the null bit preceding the 12 data bits
    -- ADC_TRANSFER: 12 cycles reading B11..B0, MSB first
    type adc_state_t is (
        ADC_IDLE,
        ADC_ASSERT_CS,
        ADC_SAMPLE,
        ADC_NULL,
        ADC_TRANSFER,
        ADC_DEASSERT_CS,
        ADC_DONE
    );
    signal adc_state : adc_state_t := ADC_IDLE;

    signal clk_en    : STD_LOGIC := '0';
    signal clk_reg   : STD_LOGIC := '0';
    signal cs_reg    : STD_LOGIC := '1';

    signal shift_reg : STD_LOGIC_VECTOR(11 downto 0) := (others => '0');
    signal bit_cnt   : unsigned(3 downto 0) := (others => '0');
    signal clk_cnt   : unsigned(1 downto 0) := (others => '0');

    -- Idle gap enforced between conversions (CS high time)
    signal idle_cnt  : unsigned(6 downto 0) := (others => '0');
    constant IDLE_TIME : unsigned(6 downto 0) := to_unsigned(100, 7);

begin
    ADC_CLK <= clk_reg;
    ADC_CS  <= cs_reg;

    -- Divides 100MHz system clock down to the SPI clock rate for the ADC
    PRESCALER : process(Clock100MHz)
        constant DIV : integer := 31;
        variable cnt : integer range 0 to DIV := 0;
    begin
        if rising_edge(Clock100MHz) then
            if reset = '1' then
                cnt    := 0;
                clk_en <= '0';
            else
                clk_en <= '0';
                if cnt = DIV then
                    cnt    := 0;
                    clk_en <= '1';
                else
                    cnt := cnt + 1;
                end if;
            end if;
        end if;
    end process;

    -- Main SPI sequencing state machine for the MCP3201
    ADC_FSM : process(Clock100MHz)
    begin
        if rising_edge(Clock100MHz) then
            if reset = '1' then
                adc_state  <= ADC_IDLE;
                cs_reg     <= '1';
                clk_reg    <= '0';
                bit_cnt    <= (others => '0');
                clk_cnt    <= (others => '0');
                idle_cnt   <= (others => '0');
                data_valid <= '0';
                data_out   <= (others => '0');
            else
                data_valid <= '0';

                case adc_state is

                    when ADC_IDLE =>
                        cs_reg  <= '1';
                        clk_reg <= '0';
                        bit_cnt <= (others => '0');
                        clk_cnt <= (others => '0');
                        if enable = '1' then
                            idle_cnt <= idle_cnt + 1;
                            if idle_cnt >= IDLE_TIME then
                                idle_cnt  <= (others => '0');
                                adc_state <= ADC_ASSERT_CS;
                            end if;
                        else
                            idle_cnt <= (others => '0');
                        end if;

                    when ADC_ASSERT_CS =>
                        cs_reg    <= '0';
                        clk_reg   <= '0';
                        adc_state <= ADC_SAMPLE;

                    when ADC_SAMPLE =>
                        if clk_en = '1' then
                            clk_reg <= not clk_reg;
                            if clk_reg = '1' then
                                clk_cnt <= clk_cnt + 1;
                                if clk_cnt = 1 then
                                    clk_cnt   <= (others => '0');
                                    adc_state <= ADC_NULL;
                                end if;
                            end if;
                        end if;

                    when ADC_NULL =>
                        if clk_en = '1' then
                            clk_reg <= not clk_reg;
                            if clk_reg = '1' then
                                adc_state <= ADC_TRANSFER;
                            end if;
                        end if;

                    when ADC_TRANSFER =>
                        if clk_en = '1' then
                            if clk_reg = '0' then
                                clk_reg   <= '1';
                                shift_reg <= shift_reg(10 downto 0) & ADC_DOUT;
                            else
                                clk_reg <= '0';
                                if bit_cnt = 11 then
                                    adc_state <= ADC_DEASSERT_CS;
                                else
                                    bit_cnt <= bit_cnt + 1;
                                end if;
                            end if;
                        end if;

                    when ADC_DEASSERT_CS =>
                        cs_reg    <= '1';
                        clk_reg   <= '0';
                        adc_state <= ADC_DONE;

                    when ADC_DONE =>
                        data_out   <= shift_reg;
                        data_valid <= '1';
                        adc_state  <= ADC_IDLE;

                    when others =>
                        adc_state <= ADC_IDLE;

                end case;
            end if;
        end if;
    end process;

end Behavioral;
