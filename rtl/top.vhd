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
-- Kolory są przypisane w sekcji przypisań na końcu pliku.
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

    signal resetn      : std_logic;
    signal stream_sel  : std_logic;
    signal ctrl_rst    : std_logic;
    signal counter     : unsigned(26 downto 0) := (others => '0');
    signal act_cnt     : unsigned(21 downto 0) := (others => '0');

    -- TCP (fc1002_mii_tcp_link)
    signal m_rx_data   : std_logic_vector(7 downto 0);
    signal m_rx_valid  : std_logic;
    signal m_rx_ready  : std_logic;
    signal s_tx_data   : std_logic_vector(7 downto 0);
    signal s_tx_valid  : std_logic;
    signal s_tx_ready  : std_logic;
    signal ip_ok       : std_logic;
    signal connected   : std_logic;

    -- ctrl_protocol
    signal ctrl_rx_ready : std_logic;
    signal ctrl_tx_data  : byte_t;
    signal ctrl_tx_valid : std_logic;
    signal ctrl_tx_ready : std_logic;
    signal ctrl_cmd_valid: std_logic;
    signal ctrl_cmd_addr : byte_t;
    signal debug_led_s   : byte_t;

    -- test ciągłego przesyłu
    signal stream_data  : std_logic_vector(7 downto 0) := (others => '0');
    signal stream_valid : std_logic := '0';

begin

    resetn     <= not btn(0);
    stream_sel <= sw(0);
    ctrl_rst   <= (not resetn) or stream_sel;

    u_tcp : entity work.fc1002_mii_tcp_link
        generic map (
            G_IP   => x"C0A80132",   -- 192.168.1.50
            G_PORT => 5000
        )
        port map (
            clk         => CLK100MHZ,
            resetn      => resetn,

            m_rx_data   => m_rx_data,
            m_rx_valid  => m_rx_valid,
            m_rx_ready  => m_rx_ready,

            s_tx_data   => s_tx_data,
            s_tx_valid  => s_tx_valid,
            s_tx_ready  => s_tx_ready,

            ip_ok       => ip_ok,
            connected   => connected,

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
            clk       => CLK100MHZ,
            rst       => ctrl_rst,
            link_up   => connected,
            rx_data   => m_rx_data,
            rx_valid  => m_rx_valid,
            rx_ready  => ctrl_rx_ready,
            tx_data   => ctrl_tx_data,
            tx_valid  => ctrl_tx_valid,
            tx_ready  => ctrl_tx_ready,
            cmd_valid => ctrl_cmd_valid,
            cmd_addr  => ctrl_cmd_addr,
            debug_led => debug_led_s
        );

    -- wybór źródła bajtów wysyłanych do TCP
    s_tx_data     <= stream_data  when stream_sel = '1' else ctrl_tx_data;
    s_tx_valid    <= stream_valid when stream_sel = '1' else ctrl_tx_valid;
    ctrl_tx_ready <= '0'          when stream_sel = '1' else s_tx_ready;

    -- wybór odbiorcy bajtów z TCP; w trybie ciągłym bajty są odrzucane
    m_rx_ready <= '1' when stream_sel = '1' else ctrl_rx_ready;

    -- generator licznika dla testu ciągłego przesyłu
    p_stream : process (CLK100MHZ)
    begin
        if rising_edge(CLK100MHZ) then
            if resetn = '0' or stream_sel = '0' or connected = '0' then
                stream_data  <= (others => '0');
                stream_valid <= '0';
            else
                stream_valid <= '1';
                if stream_valid = '1' and s_tx_ready = '1' then
                    stream_data <= std_logic_vector(unsigned(stream_data) + 1);
                end if;
            end if;
        end if;
    end process p_stream;

    -- aktywność odbioru: LED3 świeci przez chwilę po każdym odebranym bajcie
    p_activity : process (CLK100MHZ)
    begin
        if rising_edge(CLK100MHZ) then
            counter <= counter + 1;

            if resetn = '0' then
                act_cnt <= (others => '0');
            elsif m_rx_valid = '1' and m_rx_ready = '1' then
                act_cnt <= (others => '1');
            elsif act_cnt /= 0 then
                act_cnt <= act_cnt - 1;
            end if;
        end if;
    end process p_activity;

    -- zwykłe LED-y
    led(0) <= counter(26);
    led(1) <= ip_ok;
    led(2) <= connected;
    led(3) <= '1' when (stream_sel = '1') or (act_cnt /= 0) else '0';

    -- LED-y RGB: każdy bit debug_led steruje jednym kolorem
    led0_r <= debug_led_s(0);
    led0_g <= debug_led_s(1);
    led0_b <= debug_led_s(2);
    led1_r <= debug_led_s(3);
    led1_g <= debug_led_s(4);
    led1_b <= debug_led_s(5);
    led2_r <= debug_led_s(6);
    led2_g <= debug_led_s(7);
    led2_b <= '0';
    led3_r <= '0';
    led3_g <= '0';
    led3_b <= '0';

end architecture rtl;