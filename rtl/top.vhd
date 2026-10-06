library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Top-level: test echo przez TCP. Każde odebrane 32-bitowe słowo wraca do komputera.
-- LED0 = heartbeat, LED1 = IP_Ok, LED2 = klient TCP połączony, LED3 = zmienia stan przy każdym słowie.
-- Nazwy portów zgodne z oficjalnym plikiem XDC Digilent dla Arty A7.
entity top is
    port (
        CLK100MHZ : in  std_logic;
        btn       : in  std_logic_vector(3 downto 0);   -- przyciski, btn(0) = reset (aktywny stanem wysokim)
        led       : out std_logic_vector(3 downto 0);

        -- Ethernet MII (PHY na płytce Arty)
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

    signal resetn    : std_logic;
    signal counter   : unsigned(26 downto 0) := (others => '0');

    signal rx_data   : std_logic_vector(31 downto 0);
    signal rx_valid  : std_logic;
    signal rx_ready  : std_logic;
    signal tx_data   : std_logic_vector(31 downto 0);
    signal tx_valid  : std_logic;
    signal tx_ready  : std_logic;

    signal ip_ok     : std_logic;
    signal connected : std_logic;
    signal word_tgl  : std_logic := '0';

begin

    resetn <= not btn(0);

    u_tcp : entity work.tcp_link
        generic map (
            G_IP   => x"C0A80132", -- 192.168.1.50
            G_PORT => 5000
        )
        port map (
            clk         => CLK100MHZ,
            resetn      => resetn,
            m_rx_data   => rx_data,
            m_rx_valid  => rx_valid,
            m_rx_ready  => rx_ready,
            s_tx_data   => tx_data,
            s_tx_valid  => tx_valid,
            s_tx_ready  => tx_ready,
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

    -- echo: odebrane słowo trafia prosto do nadawania
    tx_data  <= rx_data;
    tx_valid <= rx_valid;
    rx_ready <= tx_ready;

    process (CLK100MHZ)
    begin
        if rising_edge(CLK100MHZ) then
            counter <= counter + 1;
            if rx_valid = '1' and tx_ready = '1' then
                word_tgl <= not word_tgl;
            end if;
        end if;
    end process;

    led(0) <= counter(26);
    led(1) <= ip_ok;
    led(2) <= connected;
    led(3) <= word_tgl;

end architecture rtl;