library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.regmap_pkg.all;

-- =============================================================================
-- ctrl_protocol.vhd
-- Tor sterowania: bajty z TCP przechodzą przez parser ramek, obsługę
-- rejestrów i nadajniki. Odpowiedź 8-bajtów idzie przez frame_tx.
-- Po READ_RECORD (gdy rekord jest gotowy) za odpowiedzią idzie blok danych
-- z measurement_data_tx. resp_done do frame_rx pojawia się dopiero po
-- zakończeniu bloku, jedno żądanie w toku.
--
-- Przepływ: frame_rx -> reg_access -> frame_tx -> [measurement_data_tx] -> frame_rx.
--
-- Konfiguracja aktywna z reg_access jest wyprowadzana na zewnątrz
-- (do acquisition_ctrl) oraz używana tutaj do nadajnika rekordu.
--
-- Mapowanie odczytu: indeks próbki i (0..N-1) -> slot (record_base + i) mod N.
--   dwa kanały: adres słowa = slot, połówka nieistotna;
--   jeden kanał: adres słowa = slot / 2, połówka = slot mod 2.
-- =============================================================================

entity ctrl_protocol is
    port (
        -- System
        clk                   : in  std_logic;
        rst                   : in  std_logic;
        link_up               : in  std_logic;   -- '0' = klient rozłączony

        -- Bajty z TCP - RX
        rx_data               : in  byte_t;
        rx_valid              : in  std_logic;
        rx_ready              : out std_logic;

        -- Bajty do TCP - TX
        tx_data               : out byte_t;
        tx_valid              : out std_logic;
        tx_ready              : in  std_logic;

        -- Polecenia do logiki akwizycji
        cmd_valid             : out std_logic;
        cmd_addr              : out byte_t;

        -- Wyjście debug
        debug_led             : out byte_t;

        -- Stan akwizycji (wskaźniki w slotach)
        acquisition_state           : in  byte_t;
        acquisition_record_id       : in  word_t;
        acquisition_write_pointer   : in  unsigned(16 downto 0);
        acquisition_trigger_pointer : in  unsigned(16 downto 0);

        -- Konfiguracja aktywna (do acquisition_ctrl)
        record_length         : out word_t;
        pre_length            : out word_t;
        channel_mask          : out byte_t;
        trigger_source        : out byte_t;
        trigger_edge          : out byte_t;
        trigger_level         : out byte_t;
        trigger_hysteresis    : out byte_t;

        -- Offsety DAC (aktywne) i impuls po udanym COMMIT
        offset_a              : out std_logic_vector(11 downto 0);
        offset_b              : out std_logic_vector(11 downto 0);
        commit_ok             : out std_logic;

        -- Wzmocnienie PGA AD8370 (aktywne, słowo: bit 7 zakres, bity 6..0 kod)
        gain_a                : out byte_t;
        gain_b                : out byte_t;

        -- Pozycja początku rekordu w buforze cyklicznym (slot, z acquisition_ctrl)
        record_base           : in  unsigned(16 downto 0);

        -- Odczyt pamięci rekordu (adres słowa)
        rd_addr               : out unsigned(15 downto 0);
        rd_data               : in  std_logic_vector(15 downto 0)
    );
end entity ctrl_protocol;

architecture rtl of ctrl_protocol is

    -- konfiguracja aktywna z reg_access
    signal control_record_length      : word_t;
    signal control_pre_length         : word_t;
    signal control_trigger_source     : byte_t;
    signal control_trigger_edge       : byte_t;
    signal control_trigger_level      : byte_t;
    signal control_trigger_hysteresis : byte_t;
    signal measurement_channel_mask   : byte_t;

    -- indeks próbki z measurement_data_tx (przed mapowaniem)
    signal record_index   : unsigned(16 downto 0) := (others => '0');
    -- połówka słowa dla jednego kanału (z mapowania)
    signal rd_half        : std_logic := '0';

    -- frame_rx -> reg_access
    signal request_valid  : std_logic;
    signal request_cmd    : byte_t;
    signal request_addr   : byte_t;
    signal request_data   : word_t;

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

    -- liczniki z frame_rx
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
            clk                         => clk,
            rst                         => rst,
            request_start               => request_valid,
            request_cmd                 => request_cmd,
            request_addr                => request_addr,
            request_data                => request_data,
            response_valid              => response_valid,
            response_cmd                => response_cmd,
            response_addr               => response_addr,
            response_data               => response_data,
            cmd_valid                   => cmd_valid,
            cmd_addr                    => cmd_addr,
            record_req                  => record_req,
            active_record_length        => control_record_length,
            active_channel_mask         => measurement_channel_mask,
            active_pre_length           => control_pre_length,
            active_trigger_source       => control_trigger_source,
            active_trigger_edge         => control_trigger_edge,
            active_trigger_level        => control_trigger_level,
            active_trigger_hysteresis   => control_trigger_hysteresis,
            active_offset_a             => offset_a,
            active_offset_b             => offset_b,
            active_gain_a               => gain_a,
            active_gain_b               => gain_b,
            commit_ok_pulse             => commit_ok,
            acquisition_state           => acquisition_state,
            acquisition_record_id       => acquisition_record_id,
            acquisition_write_pointer   => acquisition_write_pointer,
            acquisition_trigger_pointer => acquisition_trigger_pointer,
            frame_ok_pulse              => frame_ok,
            bad_magic_pulse             => bad_magic,
            debug_led                   => debug_led
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
            samples      => control_record_length,
            channel_mask => measurement_channel_mask,
            trigger_pos  => control_pre_length,
            rd_addr      => record_index,
            rd_half      => rd_half,
            rd_data      => rd_data,
            tx_data      => rec_tx_data,
            tx_valid     => rec_tx_valid,
            tx_ready     => rec_tx_ready,
            busy         => rec_busy,
            done         => rec_done,
            link_up      => link_up
        );

    -- Mapowanie indeksu na slot i adres słowa: slot = (base + indeks) mod N
    p_read_map : process (record_index, record_base, control_record_length, measurement_channel_mask)
        variable v_sum : integer;
        variable v_n   : integer;
    begin
        v_n   := to_integer(unsigned(control_record_length));
        v_sum := to_integer(record_base) + to_integer(record_index);
        if v_sum >= v_n then
            v_sum := v_sum - v_n;
        end if;

        if measurement_channel_mask(1 downto 0) = "11" then
            rd_addr <= to_unsigned(v_sum, 16);
            rd_half <= '0';
        else
            rd_addr <= to_unsigned(v_sum / 2, 16);
            if v_sum mod 2 = 1 then
                rd_half <= '1';
            else
                rd_half <= '0';
            end if;
        end if;
    end process p_read_map;

    -- Sekwencja: READ_RECORD ustawia pending, po odpowiedzi startuje blok,
    -- po bloku active gaśnie
    p_seq : process (clk)
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
    end process p_seq;

    -- MUX nadawania: w trakcie bloku nadaje measurement_data_tx
    tx_data        <= rec_tx_data  when rec_active = '1' else frame_tx_data;
    tx_valid       <= rec_tx_valid when rec_active = '1' else frame_tx_valid;
    frame_tx_ready <= '0'          when rec_active = '1' else tx_ready;
    rec_tx_ready   <= tx_ready     when rec_active = '1' else '0';

    -- resp_done do frame_rx: koniec bloku, a gdy blok czeka, nie kończymy ramki
    resp_done_s <= rec_done    when rec_active = '1' else
                   '0'         when rec_pending = '1' else
                   frame_done;

    -- konfiguracja na zewnątrz
    record_length      <= control_record_length;
    pre_length         <= control_pre_length;
    channel_mask       <= measurement_channel_mask;
    trigger_source     <= control_trigger_source;
    trigger_edge       <= control_trigger_edge;
    trigger_level      <= control_trigger_level;
    trigger_hysteresis <= control_trigger_hysteresis;

end architecture rtl;
