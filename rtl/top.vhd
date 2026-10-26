library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.regmap_pkg.all;
library unisim;
use unisim.vcomponents.all;

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
-- DAC MCP4822 (offsety kanałów): wysyłany po COMMIT (commit_ok) oraz raz
-- po resecie, żeby wyjścia dostały wartości z rejestrów.
--
-- PGA AD8370 (kanał A): słowo wzmocnienia wysyłane po COMMIT oraz raz
-- po resecie. PWUP podciągnięty do VCC na płytce.
--
-- ADC AD9288 (2 kanały): zegar ENC A i B z ODDR, 100 MHz bez dzielnika
-- (D1='1', D2='0' na CLK100MHZ). Wybór trybu: S1=1, S2=1 (działa w testach;
-- tryb normalny według noty to S1=1, S2=0 - do sprawdzenia).
-- Półokres 5 ns jest na granicy minimalnej szerokości impulsu w nocie (4,3 ns).
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

        -- ADC AD9288 (równoległy, 100 MSPS, 2 kanały)
        adc_sel1    : out std_logic;   -- A11, S1
        adc_sel2    : out std_logic;   -- B11, S2
        adc_enc_a   : out std_logic;   -- PMOD D, D4
        adc_enc_b   : out std_logic;   -- PMOD A, D12
        adc_a_data  : in  std_logic_vector(7 downto 0);
        adc_b_data  : in  std_logic_vector(7 downto 0);

        -- DAC (MCP4822, PMOD D)
        dac_cs_n    : out std_logic;
        dac_sck     : out std_logic;
        dac_sdi     : out std_logic;
        dac_ldac_n  : out std_logic;

        -- PGA AD8370, kanał A (PMOD D: clk E2, data D2, latch H2)
        pga_a_clk   : out std_logic;
        pga_a_data  : out std_logic;
        pga_a_latch : out std_logic;

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

    -- Odczyt pamięci rekordu (control_protocol -> sample_mem), adres słowa
    signal control_read_address : unsigned(15 downto 0);
    signal memory_read_data     : std_logic_vector(15 downto 0);

    -- Akwizycja
    signal acquisition_enable          : std_logic;
    signal acquisition_state           : byte_t;
    signal acquisition_record_id       : word_t;

    -- konfiguracja aktywna (z ctrl_protocol, do acquisition_ctrl)
    signal control_record_length      : word_t;
    signal control_pre_length         : word_t;
    signal control_channel_mask       : byte_t;
    signal control_trigger_source     : byte_t;
    signal control_trigger_edge       : byte_t;
    signal control_trigger_level      : byte_t;
    signal control_trigger_hysteresis : byte_t;

    -- offsety DAC (aktywne) i impuls po COMMIT
    signal control_offset_a           : std_logic_vector(11 downto 0);
    signal control_offset_b           : std_logic_vector(11 downto 0);
    signal control_commit_ok          : std_logic;

    -- wzmocnienie PGA (aktywne, słowo AD8370)
    signal control_gain_a             : byte_t;
    signal control_gain_b             : byte_t;

    -- sterowanie DAC i PGA
    signal dac_reset                  : std_logic;
    signal dac_update                 : std_logic;
    signal dac_boot_kick              : std_logic := '0';
    signal dac_boot_pending           : std_logic := '1';
    signal pga_a_update               : std_logic;

    -- pozycje w buforze cyklicznym (sloty, 17 bitów)
    signal acquisition_record_base     : unsigned(16 downto 0);
    signal acquisition_write_pointer   : unsigned(16 downto 0);
    signal acquisition_trigger_pointer : unsigned(16 downto 0);

    -- zapis do pamięci (adres słowa, zezwolenia na bajty)
    signal acquisition_mem_we_lo       : std_logic;
    signal acquisition_mem_we_hi       : std_logic;
    signal acquisition_mem_address     : unsigned(15 downto 0);
    signal acquisition_mem_data        : std_logic_vector(15 downto 0);

    -- ADC (AD9288)
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

    -- Test ciągłego przesyłu
    signal stream_test_data  : std_logic_vector(7 downto 0) := (others => '0');
    signal stream_test_valid : std_logic := '0';

begin

    system_reset_n    <= not btn(0);
    stream_mode       <= sw(0);
    control_reset     <= (not system_reset_n) or stream_mode;
    acquisition_reset <= not system_reset_n;
    dac_reset         <= not system_reset_n;
    dac_update        <= dac_boot_kick or control_commit_ok;
    pga_a_update      <= dac_boot_kick or control_commit_ok;

    -- ADC AD9288: wybór trybu (S1=1, S2=1, jak w testach)
    adc_sel1  <= '1';
    adc_sel2  <= '1';

    -- zegar kodujący 100 MHz: ODDR z CLK100MHZ, D1='1' na zboczu narastającym,
    -- D2='0' na opadającym -> przebieg o okresie 10 ns
    u_adc_enc_a : ODDR
        generic map (
            DDR_CLK_EDGE => "OPPOSITE_EDGE",
            INIT         => '0',
            SRTYPE       => "SYNC"
        )
        port map (
            C  => CLK100MHZ,
            CE => '1',
            D1 => '1',
            D2 => '0',
            R  => '0',
            S  => '0',
            Q  => adc_enc_a
        );

    u_adc_enc_b : ODDR
        generic map (
            DDR_CLK_EDGE => "OPPOSITE_EDGE",
            INIT         => '0',
            SRTYPE       => "SYNC"
        )
        port map (
            C  => CLK100MHZ,
            CE => '1',
            D1 => '1',
            D2 => '0',
            R  => '0',
            S  => '0',
            Q  => adc_enc_b
        );

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
            clk                         => CLK100MHZ,
            rst                         => control_reset,
            link_up                     => tcp_client_connected,
            rx_data                     => tcp_rx_data,
            rx_valid                    => tcp_rx_valid,
            rx_ready                    => control_rx_ready,
            tx_data                     => control_tx_data,
            tx_valid                    => control_tx_valid,
            tx_ready                    => control_tx_ready,
            cmd_valid                   => control_command_valid,
            cmd_addr                    => control_command_addr,
            debug_led                   => debug_led_bits,
            acquisition_state           => acquisition_state,
            acquisition_record_id       => acquisition_record_id,
            acquisition_write_pointer   => acquisition_write_pointer,
            acquisition_trigger_pointer => acquisition_trigger_pointer,
            record_length               => control_record_length,
            pre_length                  => control_pre_length,
            channel_mask                => control_channel_mask,
            trigger_source              => control_trigger_source,
            trigger_edge                => control_trigger_edge,
            trigger_level               => control_trigger_level,
            trigger_hysteresis          => control_trigger_hysteresis,
            offset_a                    => control_offset_a,
            offset_b                    => control_offset_b,
            commit_ok                   => control_commit_ok,
            gain_a                      => control_gain_a,
            gain_b                      => control_gain_b,
            record_base                 => acquisition_record_base,
            rd_addr                     => control_read_address,
            rd_data                     => memory_read_data
        );

    u_adc : entity work.adc_ad9288
        port map (
            clk          => CLK100MHZ,
            enable       => acquisition_enable,
            adc_a_data   => adc_a_data,
            adc_b_data   => adc_b_data,
            sample_valid => adc_sample_valid,
            ch1          => adc_ch1,
            ch2          => adc_ch2
        );

    u_dac : entity work.mcp4822_dac
        generic map (
            G_HALF_PERIOD => 5,
            G_GAIN_1X     => true
        )
        port map (
            clk        => CLK100MHZ,
            rst        => dac_reset,
            update     => dac_update,
            code_a     => control_offset_a,
            code_b     => control_offset_b,
            busy       => open,
            dac_cs_n   => dac_cs_n,
            dac_sck    => dac_sck,
            dac_sdi    => dac_sdi,
            dac_ldac_n => dac_ldac_n
        );

    u_pga_a : entity work.ad8370_pga
        generic map (
            G_HALF_PERIOD => 5
        )
        port map (
            clk       => CLK100MHZ,
            rst       => dac_reset,
            update    => pga_a_update,
            gain_word => control_gain_a,
            busy      => open,
            pga_clk   => pga_a_clk,
            pga_data  => pga_a_data,
            pga_latch => pga_a_latch
        );

    u_acq : entity work.acquisition_ctrl
        port map (
            clk                => CLK100MHZ,
            rst                => acquisition_reset,
            cmd_valid          => control_command_valid,
            cmd_addr           => control_command_addr,
            sample_valid       => adc_sample_valid,
            ch1                => adc_ch1,
            ch2                => adc_ch2,
            record_length      => control_record_length,
            pre_length         => control_pre_length,
            channel_mask       => control_channel_mask,
            trigger_source     => control_trigger_source,
            trigger_edge       => control_trigger_edge,
            trigger_level      => control_trigger_level,
            trigger_hysteresis => control_trigger_hysteresis,
            enable             => acquisition_enable,
            mem_we_lo          => acquisition_mem_we_lo,
            mem_we_hi          => acquisition_mem_we_hi,
            mem_addr           => acquisition_mem_address,
            mem_data           => acquisition_mem_data,
            record_base        => acquisition_record_base,
            trigger_pointer    => acquisition_trigger_pointer,
            write_pointer      => acquisition_write_pointer,
            state              => acquisition_state,
            record_id          => acquisition_record_id
        );

    u_mem : entity work.sample_mem
        port map (
            clk   => CLK100MHZ,
            we_lo => acquisition_mem_we_lo,
            we_hi => acquisition_mem_we_hi,
            waddr => acquisition_mem_address(14 downto 0),
            wdata => acquisition_mem_data,
            raddr => control_read_address(14 downto 0),
            rdata => memory_read_data
        );

    -- Impuls startowy DAC i PGA po resecie: wyjścia dostają kody z rejestrów
    p_dac_boot : process (CLK100MHZ)
    begin
        if rising_edge(CLK100MHZ) then
            dac_boot_kick <= '0';
            if system_reset_n = '0' then
                dac_boot_pending <= '1';
            elsif dac_boot_pending = '1' then
                dac_boot_pending <= '0';
                dac_boot_kick    <= '1';
            end if;
        end if;
    end process p_dac_boot;

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