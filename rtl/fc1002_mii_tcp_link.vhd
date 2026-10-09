library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Wrapper rdzenia FC1002_MII (stały adres IP, bez DHCP).
-- Moduł nie zawiera logiki protokołu: udostępnia strumień bajtów z/do TCP
-- oraz sygnały stanu. Rdzeń działa jako serwer TCP, komputer łączy się jako klient na G_IP:G_PORT.
--
-- Interfejs bajtowy (handshake valid/ready, transfer w takcie, w którym oba sygnały są wysokie):
--   m_rx_*  bajty odebrane z komputera (wyjście modułu)
--   s_tx_*  bajty do wysłania do komputera (wejście modułu)

entity fc1002_mii_tcp_link is
    generic (
        G_IP   : std_logic_vector(31 downto 0) := x"C0A80132";  -- 192.168.1.50
        G_PORT : natural := 5000
    );
    port (
        clk    : in  std_logic;   -- 100 MHz
        resetn : in  std_logic;   -- aktywny stanem niskim

        -- bajty odebrane (komputer -> FPGA)
        m_rx_data  : out std_logic_vector(7 downto 0);
        m_rx_valid : out std_logic;
        m_rx_ready : in  std_logic;

        -- bajty do wysłania (FPGA -> komputer)
        s_tx_data  : in  std_logic_vector(7 downto 0);
        s_tx_valid : in  std_logic;
        s_tx_ready : out std_logic;

        -- status
        ip_ok      : out std_logic;
        connected  : out std_logic;

        -- MII (PHY na płytce Arty)
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
end entity fc1002_mii_tcp_link;

architecture structural of fc1002_mii_tcp_link is

    -- Deklaracja rdzenia według tabeli sygnałów ze strony fpga-cores.com.
    component FC1002_MII
        port (
            Clk             : in    std_logic;                       -- zegar systemowy 100 MHz
            Reset           : in    std_logic;                       -- reset, aktywny stanem wysokim

            -- Adres IP
            UseDHCP         : in    std_logic;                       -- '1' = adres z DHCP, '0' = stały adres
            IP_Addr         : in    std_logic_vector(31 downto 0);   -- stały adres IP (gdy UseDHCP = '0')
            IP_Ok           : out   std_logic;                       -- adres IP gotowy

            -- MII: zegary i reset PHY
            MII_REF_CLK_25M : out   std_logic;                       -- ciągły zegar 25 MHz dla PHY
            MII_RST_N       : out   std_logic;                       -- reset PHY, aktywny stanem niskim
            MII_RX_CLK      : in    std_logic;                       -- zegar odbioru z PHY
            MII_TX_CLK      : in    std_logic;                       -- zegar nadawania z PHY

            -- MII: odbiór
            MII_CRS_DV      : in    std_logic;                       -- odbierane dane ważne
            MII_RXD         : in    std_logic_vector(3 downto 0);    -- odbierane dane (4 bity)
            MII_RXERR       : in    std_logic;                       -- błąd odbioru
            MII_CRS         : in    std_logic;
            MII_COL         : in    std_logic;

            -- MII: nadawanie
            MII_TXEN        : out   std_logic;                       -- nadawanie włączone
            MII_TXD         : out   std_logic_vector(3 downto 0);    -- nadawane dane (4 bity)

            -- MII: zarządzanie PHY
            MII_MDC         : out   std_logic;                       -- zegar interfejsu zarządzania
            MII_MDIO        : inout std_logic;                       -- dane interfejsu zarządzania

            -- SPI: programowanie pamięci flash przez sieć (nieużywane)
            SPI_CSn         : out   std_logic;                       -- wybór układu
            SPI_SCK         : out   std_logic;                       -- zegar
            SPI_MOSI        : out   std_logic;                       -- dane do pamięci
            SPI_MISO        : in    std_logic;                       -- dane z pamięci

            -- Wbudowany analizator logiczny rdzenia (nieużywany)
            LA0_TrigIn      : in    std_logic;                       -- wejście wyzwalania
            LA0_Clk         : in    std_logic;                       -- zegar próbkowania
            LA0_TrigOut     : out   std_logic;                       -- wyjście wyzwalania
            LA0_Signals     : in    std_logic_vector(31 downto 0);   -- próbkowane sygnały
            LA0_SampleEn    : in    std_logic;                       -- zezwolenie na próbkowanie

            -- TCP: konfiguracja i stan serwera
            TCP0_Service    : in    std_logic_vector(15 downto 0);   -- pole "Service"
            TCP0_ServerPort : in    std_logic_vector(15 downto 0);   -- lokalny port serwera TCP
            TCP0_Connected  : out   std_logic;                       -- klient połączony
            TCP0_AllAcked   : out   std_logic;                       -- całość wysłanych danych potwierdzona
            TCP0_nTxFree    : out   std_logic_vector(15 downto 0);   -- wolne bajty w buforze nadawczym
            TCP0_nRxData    : out   std_logic_vector(15 downto 0);   -- bajty czekające w buforze odbiorczym

            -- TCP: nadawanie (FPGA -> komputer)
            TCP0_TxData     : in    std_logic_vector(7 downto 0);    -- bajt do wysłania
            TCP0_TxValid    : in    std_logic;                       -- bajt ważny
            TCP0_TxReady    : out   std_logic;                       -- rdzeń gotowy przyjąć bajt

            -- TCP: odbiór (komputer -> FPGA)
            TCP0_RxData     : out   std_logic_vector(7 downto 0);    -- odebrany bajt
            TCP0_RxValid    : out   std_logic;                       -- bajt ważny
            TCP0_RxReady    : in    std_logic                        -- odbiorca gotowy przyjąć bajt
        );
    end component;

    -- Debug IP CORE ILA
    component ila_0
        port (
            clk    : in std_logic;
            probe0 : in std_logic_vector(7 downto 0);
            probe1 : in std_logic_vector(7 downto 0);
            probe2 : in std_logic_vector(4 downto 0)
        );
    end component;

    signal reset : std_logic;

    -- Wyjścia rdzenia przechodzą przez sygnały wewnętrzne, bo porty wyjściowe
    -- modułu nie mogą być odczytywane (potrzebne dla ILA).
    signal tcp_connected : std_logic;
    signal tcp_rx_data   : std_logic_vector(7 downto 0);
    signal tcp_rx_valid  : std_logic;
    signal tcp_tx_ready  : std_logic;

    -- Sygnał pomocniczy do łączenia sygnałów dla proba
    signal ila_probe2 : std_logic_vector(4 downto 0);

begin

    reset <= not resetn;   -- rdzeń ma reset aktywny stanem wysokim

    u_core : FC1002_MII
        port map (
            Clk             => clk,
            Reset           => reset,
            UseDHCP         => '0',
            IP_Addr         => G_IP,
            IP_Ok           => ip_ok,
            MII_REF_CLK_25M => eth_ref_clk,
            MII_RST_N       => eth_rstn,
            MII_COL         => eth_col,
            MII_CRS         => eth_crs,
            MII_RX_CLK      => eth_rx_clk,
            MII_CRS_DV      => eth_rx_dv,
            MII_RXD         => eth_rxd,
            MII_RXERR       => eth_rxerr,
            MII_TX_CLK      => eth_tx_clk,
            MII_TXEN        => eth_tx_en,
            MII_TXD         => eth_txd,
            MII_MDC         => eth_mdc,
            MII_MDIO        => eth_mdio,
            SPI_CSn         => open,
            SPI_SCK         => open,
            SPI_MOSI        => open,
            SPI_MISO        => '0',
            LA0_TrigIn      => '0',
            LA0_Clk         => clk,
            LA0_TrigOut     => open,
            LA0_Signals     => (others => '0'),
            LA0_SampleEn    => '0',
            TCP0_Service    => (others => '0'),
            TCP0_ServerPort => std_logic_vector(to_unsigned(G_PORT, 16)),
            TCP0_Connected  => tcp_connected,
            TCP0_AllAcked   => open,
            TCP0_nTxFree    => open,
            TCP0_nRxData    => open,
            TCP0_TxData     => s_tx_data,
            TCP0_TxValid    => s_tx_valid,
            TCP0_TxReady    => tcp_tx_ready,
            TCP0_RxData     => tcp_rx_data,
            TCP0_RxValid    => tcp_rx_valid,
            TCP0_RxReady    => m_rx_ready
        );

    -- Wyprowadzenie sygnałów rdzenia na porty modułu
    connected  <= tcp_connected;
    m_rx_data  <= tcp_rx_data;
    m_rx_valid <= tcp_rx_valid;
    s_tx_ready <= tcp_tx_ready;

    -- ILA: podgląd strumienia bajtów i sygnałów handshake'u po stronie rdzenia
    ila_probe2 <= tcp_rx_valid & m_rx_ready & s_tx_valid & tcp_tx_ready & tcp_connected;

    u_ila : ila_0
        port map (
            clk    => clk,
            probe0 => tcp_rx_data,
            probe1 => s_tx_data,
            probe2 => ila_probe2
        );

end architecture structural;
