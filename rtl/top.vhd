library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Top-level: testy TCP. Tryb echa (domyślny) i tryb strumienia, BTN1 przełącza tryb, BTN0 resetuje
entity top is
    port (
        CLK100MHZ : in  std_logic;
        btn       : in  std_logic_vector(3 downto 0);
        led       : out std_logic_vector(3 downto 0);

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

    signal resetn    : std_logic;
    signal counter   : unsigned(26 downto 0) := (others => '0');

    -- strumień bajtów z/do tcp_link
    signal rx_data   : std_logic_vector(7 downto 0);
    signal rx_valid  : std_logic;
    signal rx_ready  : std_logic;
    signal tx_data   : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_valid  : std_logic := '0';
    signal tx_ready  : std_logic;

    signal ip_ok     : std_logic;
    signal connected : std_logic;

    -- impuls aktywności dla LED3
    signal act_cnt   : unsigned(21 downto 0) := (others => '0');

    -- tryb: '0' echo, '1' strumień
    signal stream_mode : std_logic := '0';
    signal mode_prev   : std_logic := '0';

    -- obsługa BTN1
    signal btn1_sync  : std_logic_vector(1 downto 0) := (others => '0');
    signal btn1_state : std_logic := '0';
    signal btn1_prev  : std_logic := '0';
    signal db_cnt     : unsigned(20 downto 0) := (others => '0');

begin

    resetn <= not btn(0);

    u_tcp : entity work.fc1002_mii_tcp_link
        generic map (
            G_IP   => x"C0A80132",   -- 192.168.1.50
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

    -- w trybie strumienia odbierane bajty są odrzucane
    rx_ready <= '1' when stream_mode = '1' else not tx_valid;

    -- Przełączanie trybu BTN1
    process (CLK100MHZ)
    begin
        if rising_edge(CLK100MHZ) then
            btn1_sync <= btn1_sync(0) & btn(1);
            btn1_prev <= btn1_state;

            if btn1_sync(1) /= btn1_state then
                if db_cnt(20) = '1' then
                    btn1_state <= btn1_sync(1);
                    db_cnt     <= (others => '0');
                else
                    db_cnt <= db_cnt + 1;
                end if;
            else
                db_cnt <= (others => '0');
            end if;

            if resetn = '0' then
                stream_mode <= '0';
            elsif btn1_state = '1' and btn1_prev = '0' then
                stream_mode <= not stream_mode;
            end if;
        end if;
    end process;

    -- Nadawanie: echo albo strumień
    process (CLK100MHZ)
    begin
        if rising_edge(CLK100MHZ) then
            counter <= counter + 1;

            if resetn = '0' then
                tx_valid  <= '0';
                tx_data   <= (others => '0');
                act_cnt   <= (others => '0');
                mode_prev <= '0';
            else
                mode_prev <= stream_mode;

                if stream_mode /= mode_prev then
                    -- zmiana trybu
                    tx_valid <= '0';
                    tx_data  <= (others => '0');

                elsif stream_mode = '1' then
                    -- strumień
                    if connected = '0' then
                        tx_valid <= '0';
                        tx_data  <= (others => '0');
                    else
                            tx_valid <= '1';
                        if tx_valid = '1' and tx_ready = '1' then
                            tx_data <= std_logic_vector(unsigned(tx_data) + 1);
                        end if;
                    end if;

                else
                    -- echo
                    if tx_valid = '1' and tx_ready = '1' then
                        tx_valid <= '0';
                    end if;

                    if rx_valid = '1' and rx_ready = '1' then
                        tx_data  <= rx_data;
                        tx_valid <= '1';
                        act_cnt  <= (others => '1');
                    elsif act_cnt /= 0 then
                        act_cnt <= act_cnt - 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    led(0) <= counter(26);
    led(1) <= ip_ok;
    led(2) <= connected;
    led(3) <= '1' when (stream_mode = '1') or (act_cnt /= 0) else '0';

end architecture rtl;
