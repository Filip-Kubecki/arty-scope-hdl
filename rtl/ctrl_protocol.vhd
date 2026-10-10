library ieee;
use ieee.std_logic_1164.all;
use work.regmap_pkg.all;

-- =============================================================================
-- ctrl_protocol.vhd
-- Tor sterowania: bajty z TCP przechodzą przez parser ramek, obsługę
-- rejestrów i nadajnik odpowiedzi, a odpowiedź wraca do TCP.
--
-- Przepływ: frame_rx -> reg_access -> frame_tx -> resp_done -> frame_rx.
-- Jedno żądanie w toku, bo frame_rx wstrzymuje odbiór do końca odpowiedzi.
-- =============================================================================

entity ctrl_protocol is
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;
        link_up    : in  std_logic;                 -- '0' = klient rozłączony

        -- bajty z TCP
        rx_data    : in  byte_t;
        rx_valid   : in  std_logic;
        rx_ready   : out std_logic;

        -- bajty do TCP
        tx_data    : out byte_t;
        tx_valid   : out std_logic;
        tx_ready   : in  std_logic;

        -- polecenia do logiki akwizycji
        cmd_valid  : out std_logic;
        cmd_addr   : out byte_t;

        -- wyjście debugowe
        debug_led  : out byte_t
    );
end entity ctrl_protocol;

architecture rtl of ctrl_protocol is

    -- frame_rx -> reg_access
    signal request_valid : std_logic;
    signal request_cmd   : byte_t;
    signal request_addr  : byte_t;
    signal request_data  : word_t;

    -- reg_access -> frame_tx
    signal response_valid : std_logic;
    signal response_cmd   : byte_t;
    signal response_addr  : byte_t;
    signal response_data  : word_t;

    -- frame_tx -> frame_rx
    signal tx_done       : std_logic;
    signal tx_busy       : std_logic;

    -- liczniki z frame_rx (podłączenie do rejestrów statusu w kolejnym kroku)
    signal frame_ok      : std_logic;
    signal bad_magic     : std_logic;

begin

    u_frame_rx : entity work.frame_rx
        port map (
            clk       => clk,
            rst       => rst,
            link_up   => link_up,
            rx_data   => rx_data,
            rx_valid  => rx_valid,
            rx_ready  => rx_ready,
            req_valid => request_valid,
            req_cmd   => request_cmd,
            req_addr  => request_addr,
            req_data  => request_data,
            resp_done => tx_done,
            frame_ok  => frame_ok,
            bad_magic => bad_magic);

    u_reg_access : entity work.reg_access
        port map (
            clk            => clk,
            rst            => rst,
            request_start  => request_valid,
            request_cmd    => request_cmd,
            request_addr   => request_addr,
            request_data   => request_data,
            response_valid => response_valid,
            response_cmd   => response_cmd,
            response_addr  => response_addr,
            response_data  => response_data,
            cmd_valid      => cmd_valid,
            cmd_addr       => cmd_addr,
            debug_led      => debug_led);

    u_frame_tx : entity work.frame_tx
        port map (
            clk       => clk,
            rst       => rst,
            link_up   => link_up,
            trigger   => response_valid,
            resp_cmd  => response_cmd,
            resp_addr => response_addr,
            resp_data => response_data,
            busy      => tx_busy,
            done      => tx_done,
            tx_data   => tx_data,
            tx_valid  => tx_valid,
            tx_ready  => tx_ready);

end architecture rtl;
