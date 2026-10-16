library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.regmap_pkg.all;

-- =============================================================================
-- top.vhd
-- Najwyższy poziom układu.
--
-- Tryb wybiera sw(0):
--   '0'  sterowanie: bajty z TCP obsługuje ctrl_protocol
--   '1'  test ciągłego przesyłu: do TCP płynie licznik 8-bitowy,
--        odebrane bajty są odrzucane, ctrl_protocol jest w resecie
--
-- Zwykłe LED-y:
--   led(0)  puls pracy układu
--   led(1)  adres IP gotowy
--   led(2)  klient połączony
--   led(3)  tryb ciągły albo aktywność odbioru z TCP
--
-- LED-y RGB (led0..led2) pokazują debug_led z ctrl_protocol, bit = kolor.
--
-- BTN0 resetuje układ.
-- =============================================================================

entity top is
    port (
        CLK100MHZ : in  std_logic;
        btn       : in  std_logic_vector(3 downto 0);
        sw        : in  std_logic_vector(3 downto 0);
        led       : out std_logic_vector(3 downto 0);

        -- RGB LED
        led0_r, led0_g, led0_b : out std_logic;
        led1_r, led1_g, led1_b : out std_logic;
        led2_r, led2_g, led2_b : out std_logic;
        led3_r, led3_g, led3_b : out std_logic;

        -- ADC (MCP3201)
        ADC_CLK     : out std_logic;
        ADC_CS      : out std_logic;
        ADC_DOUT    : in  std_logic;

        -- Ethernet MII
        eth_ref_clk : out   std_logic;
        eth_rstn    : out   std_logic;
        eth_col     : in    std_logic;
        eth_crs     : in    std_logic;
        eth_rx_clk  : in    std_logic;
        eth_rx_dv   : in    std_logic;
        eth_rxd     : in    std_logic_vector(3 downto 0);
        eth_rxerr   : in    std_logic;
        eth_tx_clk  : in    std_logic;
        eth_tx_en   : out   std_logic;
        eth_txd     : out   std_logic_vector(3 downto 0);
        eth_mdc     : out   std_logic;
        eth_mdio    : inout std_logic
    );
end entity top;

architecture rtl of top is

    -- Resety i tryb pracy
    signal system_reset_n     : std_logic;
    signal stream_mode        : std_logic;
    signal control_reset      : std_logic;
    signal acquisition_reset  : std_logic;

    -- Liczniki pomocnicze
    signal heartbeat_counter  : unsigned(26 downto 0) := (others => '0');
    signal rx_activity_counter : unsigned(21 downto 0) := (others => '0');

    -- Odczyt pamięci rekordu (control_protocol -> sample_mem)
    signal control_read_address : unsigned(12 downto 0);
    signal memory_read_data     : std_logic_vector(15 downto 0);

    -- Akwizycja
    signal acquisition_enable          : std_logic;
    signal acquisition_state           : byte_t;
    signal acquisition_record_id       : word_t;
    signal acquisition_mem_write_enable : std_logic;
    signal acquisition_mem_address     : unsigned(12 downto 0);
    signal acquisition_mem_data        : std_logic_vector(15 downto 0);

    -- ADC (mcp3201)
    signal adc_sample_valid : std_logic;
    signal adc_ch1          : byte_t;
    signal adc_ch2          : byte_t;

    -- TCP (fc1002_mii_tcp_link)
    signal tcp_rx_data          : std_logic_vector(7 downto 0);
    signal tcp_rx_valid         : std_logic;
    signal tcp_rx_ready         : std_logic;
    signal tcp_tx_data          : std_logic_vector(7 downto 0);
    signal tcp_tx_valid         : std_logic;
    signal tcp_tx_ready         : std_logic;
    signal ip_address_ready     : std_logic;
    signal tcp_client_connected : std_logic;

    -- ctrl_protocol
    signal control_rx_ready      : std_logic;
    signal control_tx_data       : byte_t;
    signal control_tx_valid      : std_logic;
    signal control_tx_ready      : std_logic;
    signal control_command_valid : std_logic;
    signal control_command_addr  : byte_t;
    signal debug_led_bits        : byte_t;
    signal control_record_length : word_t;

    -- Test ciągłego przesyłu
    signal stream_test_data  : std_logic_vector(7 downto 0) := (others => '0');
    signal stream_test_valid : std_logic := '0';

begin

    system_reset_n    <= not btn(0);
    stream_mode       <= sw(0);
    control_reset     <= (not system_reset_n) or stream_mode;
    acquisition_reset <= not system_reset_n;

    u_tcp : entity work.fc1002_mii_tcp_link
        generic map (
            G_IP   => x"C0A80132",   -- 192.168.1.50
            G_PORT => 5000
        )
        port map (
            clk         => CLK100MHZ,
            resetn      => system_reset_n,

            m_rx_data   => tcp_rx_data,
            m_rx_valid  => tcp_rx_valid,
            m_rx_ready  => tcp_rx_ready,

            s_tx_data   => tcp_tx_data,
            s_tx_valid  => tcp_tx_valid,
            s_tx_ready  => tcp_tx_ready,

            ip_ok       => ip_address_ready,
            connected   => tcp_client_connected,

            eth_ref_clk => eth_ref_clk,
            eth_rstn    => eth_rstn,
            eth_col     => eth_col,
            eth_crs     => eth_crs,
            eth_rx_clk  => eth_rx_clk,
            eth_rx_dv   => eth_rx_dv,
            eth_rxd     => eth_rxd,
            eth_rxerr   => eth_rxerr,
            eth_tx_clk  => eth_tx_clk,
            eth_tx_en   => eth_tx_en,
            eth_txd     => eth_txd,
            eth_mdc     => eth_mdc,
            eth_mdio    => eth_mdio
        );

    u_ctrl : entity work.ctrl_protocol
        port map (
            clk                   => CLK100MHZ,
            rst                   => control_reset,
            link_up               => tcp_client_connected,
            rx_data               => tcp_rx_data,
            rx_valid              => tcp_rx_valid,
            rx_ready              => control_rx_ready,
            tx_data               => control_tx_data,
            tx_valid              => control_tx_valid,
            tx_ready              => control_tx_ready,
            cmd_valid             => control_command_valid,
            cmd_addr              => control_command_addr,
            debug_led             => debug_led_bits,
            acquisition_state     => acquisition_state,
            acquisition_record_id => acquisition_record_id,
            rd_addr               => control_read_address,
            rd_data               => memory_read_data,
            record_length         => control_record_length
        );

    u_adc : entity work.adc_mcp3201
        port map (
            clk          => CLK100MHZ,
            rst          => acquisition_reset,
            enable       => acquisition_enable,
            sample_valid => adc_sample_valid,
            ch1          => adc_ch1,
            ch2          => adc_ch2,
            adc_clk      => ADC_CLK,
            adc_cs       => ADC_CS,
            adc_dout     => ADC_DOUT
        );

    u_acq : entity work.acquisition_ctrl
        port map (
            clk          => CLK100MHZ,
            rst          => acquisition_reset,
            cmd_valid    => control_command_valid,
            cmd_addr     => control_command_addr,
            sample_valid => adc_sample_valid,
            ch1          => adc_ch1,
            ch2          => adc_ch2,
            enable       => acquisition_enable,
            mem_we       => acquisition_mem_write_enable,
            mem_addr     => acquisition_mem_address,
            mem_data     => acquisition_mem_data,
            state        => acquisition_state,
            record_id    => acquisition_record_id,
            record_length => control_record_length
        );

    u_mem : entity work.sample_mem
        port map (
            clk   => CLK100MHZ,
            we    => acquisition_mem_write_enable,
            waddr => acquisition_mem_address,
            wdata => acquisition_mem_data,
            raddr => control_read_address,
            rdata => memory_read_data
        );

    -- Wybór źródła bajtów wysyłanych do TCP
    tcp_tx_data      <= stream_test_data  when stream_mode = '1' else control_tx_data;
    tcp_tx_valid     <= stream_test_valid when stream_mode = '1' else control_tx_valid;
    control_tx_ready <= '0'               when stream_mode = '1' else tcp_tx_ready;

    -- Wybór odbiorcy bajtów z TCP; w trybie ciągłym bajty są odrzucane
    tcp_rx_ready <= '1' when stream_mode = '1' else control_rx_ready;

    -- Generator licznika dla testu ciągłego przesyłu
    p_stream_test : process (CLK100MHZ)
    begin
        if rising_edge(CLK100MHZ) then
            if system_reset_n = '0' or stream_mode = '0' or tcp_client_connected = '0' then
                stream_test_data  <= (others => '0');
                stream_test_valid <= '0';
            else
                stream_test_valid <= '1';
                if stream_test_valid = '1' and tcp_tx_ready = '1' then
                    stream_test_data <= std_logic_vector(unsigned(stream_test_data) + 1);
                end if;
            end if;
        end if;
    end process p_stream_test;

    -- Aktywność odbioru: LED3 świeci przez chwilę po każdym odebranym bajcie
    p_rx_activity : process (CLK100MHZ)
    begin
        if rising_edge(CLK100MHZ) then
            heartbeat_counter <= heartbeat_counter + 1;

            if system_reset_n = '0' then
                rx_activity_counter <= (others => '0');
            elsif tcp_rx_valid = '1' and tcp_rx_ready = '1' then
                rx_activity_counter <= (others => '1');
            elsif rx_activity_counter /= 0 then
                rx_activity_counter <= rx_activity_counter - 1;
            end if;
        end if;
    end process p_rx_activity;

    -- Zwykłe LED-y
    led(0) <= heartbeat_counter(26);
    led(1) <= ip_address_ready;
    led(2) <= tcp_client_connected;
    led(3) <= '1' when (stream_mode = '1') or (rx_activity_counter /= 0) else '0';

    -- LED-y RGB: każdy bit debug_led steruje jednym kolorem
    led0_r <= debug_led_bits(0);
    led0_g <= debug_led_bits(1);
    led0_b <= debug_led_bits(2);
    led1_r <= debug_led_bits(3);
    led1_g <= debug_led_bits(4);
    led1_b <= debug_led_bits(5);
    led2_r <= debug_led_bits(6);
    led2_g <= debug_led_bits(7);
    led2_b <= '0';
    led3_r <= '0';
    led3_g <= '0';
    led3_b <= '0';

end architecture rtl;
