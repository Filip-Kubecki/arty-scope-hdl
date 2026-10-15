library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.regmap_pkg.all;

-- =============================================================================
-- ctrl_protocol.vhd
-- Tor sterowania: bajty z TCP przechodzą przez parser ramek, obsługę
-- rejestrów i nadajniki. Odpowiedź 8-bajtów idzie przez frame_tx.
-- Po READ_RECORD (gdy rekord z danymi jest gotowy) za odpowiedzią 
-- idzie blok danych pomiarowych z measurement_data_tx. 
-- resp_done do frame_rx pojawia się dopiero po zakończeniu bloku, jedno żądanie w toku.
--
-- Przepływ: frame_rx -> reg_access -> frame_tx -> [measurement_data_tx] -> frame_rx.
--
-- Parametry rekordu (tymczasowo, do zastąpienia konfiguracją):
--   G_RECORD_SAMPLES  liczba próbek na kanał
--   REC_CHANNEL_MASK  jeden kanał (ch2 jest nieobsługiwany - zera)
-- =============================================================================

entity ctrl_protocol is
    generic (
        G_RECORD_SAMPLES : natural := 8192
    );
    port (
        -- System
        clk        : in  std_logic;
        rst        : in  std_logic;
        link_up    : in  std_logic;                 -- '0' = klient rozłączony

        -- Bajty z TCP - RX
        rx_data    : in  byte_t;
        rx_valid   : in  std_logic;
        rx_ready   : out std_logic;

        -- Bajty do TCP - TX
        tx_data    : out byte_t;
        tx_valid   : out std_logic;
        tx_ready   : in  std_logic;

        -- Polecenia do logiki akwizycji
        cmd_valid  : out std_logic;
        cmd_addr   : out byte_t;

        -- Wyjście debug
        debug_led  : out byte_t;

        -- Stan akwizycji
        acquisition_state     : in  byte_t;
        acquisition_record_id : in  word_t;

        -- Odczyt pamięci rekordu
        rd_addr    : out unsigned(12 downto 0);
        rd_data    : in  std_logic_vector(15 downto 0)
    );
end entity ctrl_protocol;

architecture rtl of ctrl_protocol is

    constant REC_CHANNEL_MASK : byte_t := x"01";
    constant REC_SAMPLES      : word_t := std_logic_vector(to_unsigned(G_RECORD_SAMPLES, 32));

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

    -- reg_access -> sekwencja rekordu
    signal record_req     : std_logic;

    -- frame_tx
    signal frame_done     : std_logic;
    signal frame_busy     : std_logic;
    signal frame_tx_data  : byte_t;
    signal frame_tx_valid : std_logic;
    signal frame_tx_ready : std_logic;

    -- measurement_data_tx
    signal rec_start      : std_logic;
    signal rec_busy       : std_logic;
    signal rec_done       : std_logic;
    signal rec_tx_data    : byte_t;
    signal rec_tx_valid   : std_logic;
    signal rec_tx_ready   : std_logic;

    -- sekwencja: czy czekamy na koniec odpowiedzi / nadajemy blok
    signal rec_pending    : std_logic := '0';
    signal rec_active     : std_logic := '0';

    -- do frame_rx
    signal resp_done_s    : std_logic;

    -- liczniki z frame_rx (podłączenie do rejestrów statusu w kolejnym kroku)
    signal frame_ok       : std_logic;
    signal bad_magic      : std_logic;

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
            resp_done => resp_done_s,
            frame_ok  => frame_ok,
            bad_magic => bad_magic
          );

    u_reg_access : entity work.reg_access
        port map (
            clk                   => clk,
            rst                   => rst,
            request_start         => request_valid,
            request_cmd           => request_cmd,
            request_addr          => request_addr,
            request_data          => request_data,
            response_valid        => response_valid,
            response_cmd          => response_cmd,
            response_addr         => response_addr,
            response_data         => response_data,
            cmd_valid             => cmd_valid,
            cmd_addr              => cmd_addr,
            record_req            => record_req,
            acquisition_state     => acquisition_state,
            acquisition_record_id => acquisition_record_id,
            debug_led             => debug_led,
            frame_ok_pulse  => frame_ok,
            bad_magic_pulse => bad_magic
          );

    u_frame_tx : entity work.frame_tx
        port map (
            clk       => clk,
            rst       => rst,
            link_up   => link_up,
            trigger   => response_valid,
            resp_cmd  => response_cmd,
            resp_addr => response_addr,
            resp_data => response_data,
            busy      => frame_busy,
            done      => frame_done,
            tx_data   => frame_tx_data,
            tx_valid  => frame_tx_valid,
            tx_ready  => frame_tx_ready
          );

    -- Start bloku zaraz po zakończeniu 8-bajtowej odpowiedzi
    rec_start <= '1' when (rec_pending = '1' and frame_done = '1') else '0';

    u_measurement_data_tx : entity work.measurement_data_tx
        port map (
            clk          => clk,
            rst          => rst,
            start        => rec_start,
            record_id    => acquisition_record_id,
            samples      => REC_SAMPLES,
            channel_mask => REC_CHANNEL_MASK,
            rd_addr      => rd_addr,
            rd_data      => rd_data,
            tx_data      => rec_tx_data,
            tx_valid     => rec_tx_valid,
            tx_ready     => rec_tx_ready,
            busy         => rec_busy,
            done         => rec_done,
            link_up      => link_up
          );

    -- sekwencja: READ_RECORD ustawia pending, po odpowiedzi startuje blok,
    -- po bloku active gaśnie
    process (clk)
    begin
        if rising_edge(clk) then
            if rst = '1' or link_up = '0' then
                rec_pending <= '0';
                rec_active  <= '0';
            else
                if record_req = '1' then
                    rec_pending <= '1';
                end if;

                if rec_pending = '1' and frame_done = '1' then
                    rec_pending <= '0';
                    rec_active  <= '1';
                end if;

                if rec_active = '1' and rec_done = '1' then
                    rec_active <= '0';
                end if;
            end if;
        end if;
    end process;

    -- MUX nadawania: w trakcie bloku nadaje measurement_data_tx
    tx_data        <= rec_tx_data  when rec_active = '1' else frame_tx_data;
    tx_valid       <= rec_tx_valid when rec_active = '1' else frame_tx_valid;
    frame_tx_ready <= '0'          when rec_active = '1' else tx_ready;
    rec_tx_ready   <= tx_ready     when rec_active = '1' else '0';

    -- resp_done do frame_rx: koniec bloku, a gdy bloku się kończy, koniec ramki
    resp_done_s <= rec_done    when rec_active = '1' else
                   '0'         when rec_pending = '1' else
                   frame_done;

end architecture rtl;
