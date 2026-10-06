library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tcp_link is
    generic (
        G_IP   : std_logic_vector(31 downto 0) := x"C0A80132";  -- 192.168.1.50
        G_PORT : natural := 5000
    );
    port (
        clk    : in  std_logic;   -- 100 MHz
        resetn : in  std_logic;   -- aktywny stanem niskim

        -- odebrane słowa (komputer -> FPGA)
        m_rx_data  : out std_logic_vector(31 downto 0);
        m_rx_valid : out std_logic;
        m_rx_ready : in  std_logic;

        -- słowa do wysłania (FPGA -> komputer)
        s_tx_data  : in  std_logic_vector(31 downto 0);
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
end entity tcp_link;

architecture behavioral of tcp_link is

    -- Deklaracja rdzenia według tabeli sygnałów ze strony fpga-cores.com
    component FC1002_MII
        port (
            Clk             : in    std_logic;
            Reset           : in    std_logic;
            UseDHCP         : in    std_logic;
            IP_Addr         : in    std_logic_vector(31 downto 0);
            IP_Ok           : out   std_logic;
            MII_REF_CLK_25M : out   std_logic;
            MII_RST_N       : out   std_logic;
            MII_COL         : in    std_logic;
            MII_CRS         : in    std_logic;
            MII_RX_CLK      : in    std_logic;
            MII_CRS_DV      : in    std_logic;
            MII_RXD         : in    std_logic_vector(3 downto 0);
            MII_RXERR       : in    std_logic;
            MII_TX_CLK      : in    std_logic;
            MII_TXEN        : out   std_logic;
            MII_TXD         : out   std_logic_vector(3 downto 0);
            MII_MDC         : out   std_logic;
            MII_MDIO        : inout std_logic;
            SPI_CSn         : out   std_logic;
            SPI_SCK         : out   std_logic;
            SPI_MOSI        : out   std_logic;
            SPI_MISO        : in    std_logic;
            LA0_TrigIn      : in    std_logic;
            LA0_Clk         : in    std_logic;
            LA0_TrigOut     : out   std_logic;
            LA0_Signals     : in    std_logic_vector(31 downto 0);
            LA0_SampleEn    : in    std_logic;
            TCP0_Service    : in    std_logic_vector(15 downto 0);
            TCP0_ServerPort : in    std_logic_vector(15 downto 0);
            TCP0_Connected  : out   std_logic;
            TCP0_AllAcked   : out   std_logic;
            TCP0_nTxFree    : out   std_logic_vector(15 downto 0);
            TCP0_nRxData    : out   std_logic_vector(15 downto 0);
            TCP0_TxData     : in    std_logic_vector(7 downto 0);
            TCP0_TxValid    : in    std_logic;
            TCP0_TxReady    : out   std_logic;
            TCP0_RxData     : out   std_logic_vector(7 downto 0);
            TCP0_RxValid    : out   std_logic;
            TCP0_RxReady    : in    std_logic
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
    
    -- Sygnał pomocniczy do łączenia sygnałów dla proba
    signal ila_probe2 : std_logic_vector(4 downto 0);

    type rx_state_t is (r_collect, r_present);
    type tx_state_t is (t_idle, t_send);

    signal Q_stateR, N_stateR : rx_state_t;
    signal Q_state,  N_state  : tx_state_t;
    signal Q_dataR,  N_dataR  : std_logic_vector(31 downto 0);
    signal Q_data,   N_data   : std_logic_vector(31 downto 0);
    signal Q_bytecountR, N_bytecountR : integer range 0 to 3;
    signal Q_bytecount,  N_bytecount  : integer range 0 to 3;

    signal reset         : std_logic;
    signal tcp_connected : std_logic;
    signal tcp_tx_data   : std_logic_vector(7 downto 0);
    signal tcp_tx_valid  : std_logic;
    signal tcp_tx_ready  : std_logic;
    signal tcp_rx_data   : std_logic_vector(7 downto 0);
    signal tcp_rx_valid  : std_logic;
    signal tcp_rx_ready  : std_logic;

begin

    reset     <= not resetn;
    connected <= tcp_connected;

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
            TCP0_TxData     => tcp_tx_data,
            TCP0_TxValid    => tcp_tx_valid,
            TCP0_TxReady    => tcp_tx_ready,
            TCP0_RxData     => tcp_rx_data,
            TCP0_RxValid    => tcp_rx_valid,
            TCP0_RxReady    => tcp_rx_ready
        );
        
    ila_probe2 <= tcp_rx_valid & tcp_rx_ready & tcp_tx_valid & tcp_tx_ready & tcp_connected;
    
    u_ila : ila_0
    port map (
        clk    => clk,
        probe0 => tcp_rx_data,
        probe1 => tcp_tx_data,
        probe2 => ila_probe2
    );

    -- Odbiór: składa 4 bajty w jedno 32-bitowe słowo
    eth_rcv_comb : process (Q_stateR, Q_dataR, Q_bytecountR,
                            tcp_rx_valid, tcp_rx_data, m_rx_ready, tcp_connected)
    begin
        N_stateR     <= Q_stateR;
        N_dataR      <= Q_dataR;
        N_bytecountR <= Q_bytecountR;
        tcp_rx_ready <= '0';
        m_rx_valid   <= '0';

        case Q_stateR is
            when r_collect =>
                tcp_rx_ready <= '1';
                if tcp_rx_valid = '1' then
                    N_dataR <= Q_dataR(23 downto 0) & tcp_rx_data;
                    if Q_bytecountR = 3 then
                        N_bytecountR <= 0;
                        N_stateR     <= r_present;   -- całe słowo odebrane
                    else
                        N_bytecountR <= Q_bytecountR + 1;
                    end if;
                end if;

            when r_present =>
                m_rx_valid <= '1';
                if m_rx_ready = '1' then
                    N_stateR <= r_collect;
                end if;
        end case;

        -- utrata połączenia: porzuć niedokończone słowo
        if tcp_connected = '0' then
            N_stateR     <= r_collect;
            N_bytecountR <= 0;
        end if;
    end process;

    m_rx_data <= Q_dataR;

    -- Nadawanie: wysyła 32-bitowe słowo jako 4 bajty (najstarszy pierwszy)
    eth_ifc_comb : process (Q_state, Q_data, Q_bytecount,
                            s_tx_valid, s_tx_data, tcp_tx_ready, tcp_connected)
    begin
        N_state      <= Q_state;
        N_data       <= Q_data;
        N_bytecount  <= Q_bytecount;
        s_tx_ready   <= '0';
        tcp_tx_valid <= '0';

        case Q_state is
            when t_idle =>
                if tcp_connected = '1' then
                    s_tx_ready <= '1';
                    if s_tx_valid = '1' then
                        N_data      <= s_tx_data;
                        N_bytecount <= 0;
                        N_state     <= t_send;
                    end if;
                end if;

            when t_send =>
                tcp_tx_valid <= '1';
                if tcp_tx_ready = '1' then -- bajt przyjęty przez rdzeń
                    if Q_bytecount = 3 then
                        N_state <= t_idle;
                    else
                        N_data      <= Q_data(23 downto 0) & x"00";
                        N_bytecount <= Q_bytecount + 1;
                    end if;
                end if;
        end case;

        -- utrata połączenia: przerwij wysyłanie
        if tcp_connected = '0' then
            N_state <= t_idle;
        end if;
    end process;

    tcp_tx_data <= Q_data(31 downto 24);

    -- Rejestry stanu
    eth_seq : process (clk)
    begin
        if rising_edge(clk) then
            if resetn = '0' then
                Q_stateR     <= r_collect;
                Q_state      <= t_idle;
                Q_dataR      <= (others => '0');
                Q_data       <= (others => '0');
                Q_bytecountR <= 0;
                Q_bytecount  <= 0;
            else
                Q_stateR     <= N_stateR;
                Q_state      <= N_state;
                Q_dataR      <= N_dataR;
                Q_data       <= N_data;
                Q_bytecountR <= N_bytecountR;
                Q_bytecount  <= N_bytecount;
            end if;
        end if;
    end process;

end architecture behavioral;
