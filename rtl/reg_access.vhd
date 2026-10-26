library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.regmap_pkg.all;

-- =============================================================================
-- reg_access.vhd
-- Obsługa zapisu i odczytu rejestrów: sprawdzenie adresu, komendy i uprawnień,
-- wykonanie operacji, budowa odpowiedzi.
--
-- Konfiguracja (kopia oczekująca i aktywna):
--   ACQUISITION_RECORD_LENGTH   1..limit(maska), patrz niżej
--   ACQUISITION_CHANNEL_MASK    bit 0 = ch1, bit 1 = ch2; 0 niepoprawne
--   ACQUISITION_PRETRIGGER      0..limit(maska)-1
--   TRIGGER_SOURCE              0x00 ch1, 0x01 ch2
--   TRIGGER_EDGE                0x00 narastająca, 0x01 opadająca, 0x02 obie
--   TRIGGER_LEVEL               0..255 (kody ADC)
--   TRIGGER_HYSTERESIS          0..255 (kody ADC)
--   CHANNEL1_OFFSET             0..4095 (kod DAC MCP4822, kanał A)
--   CHANNEL2_OFFSET             0..4095 (kod DAC MCP4822, kanał B)
--   CHANNEL1_GAIN               słowo AD8370, kanał A: bit 7 zakres, bity 6..0 kod
--   CHANNEL2_GAIN               słowo AD8370, kanał B: bit 7 zakres, bity 6..0 kod
--   Limit długości: dwa kanały (11) RECORD_MAX_SAMPLES, jeden kanał (01, 10)
--   2*RECORD_MAX_SAMPLES (dwie próbki w słowie pamięci).
--   Zapis: wartość poza zakresem -> ERROR_BAD_VALUE, poprzednia zostaje.
--   Zapis długości albo maski sprawdza się względem oczekującej drugiej wartości.
--   Zapis gain: każdy bajt jest poprawny, bez walidacji.
--   Odczyt: kopia oczekująca.
--
--   COMMAND_COMMIT: kopiuje oczekującą do aktywnej, tylko w IDLE.
--     Reguły krzyżowe: długość <= limit(maska), pre < N,
--     źródło wyzwalania włączone w masce kanałów.
--     Naruszenie -> ERROR_BAD_VALUE, nic nie zmienia.
--     Udany COMMIT daje impuls commit_ok_pulse (top wysyła offsety do DAC
--     i słowa gain do PGA).
--   COMMAND_RESET_CONFIG: wartości domyślne do kopii oczekującej.
--
-- Stan akwizycji tylko do odczytu (w slotach, 17 bitów):
--   ACQUISITION_WRITE_POINTER    bieżący slot zapisu w buforze cyklicznym
--   ACQUISITION_TRIGGER_POINTER  slot próbki wyzwalającej (zapamiętany w chwili wyzwolenia)
--
-- Liczniki protokołu (zapis do rejestrów tylko przez COMMAND_CLEAR_COUNTERS):
--   COUNTER_FRAMES_OK, COUNTER_BAD_MAGIC (impulsy z frame_rx)
--   COUNTER_UNKNOWN_COMMAND, COUNTER_BAD_ADDRESS (liczone tutaj)
--
-- Strefa komend 0x10-0x17: zapis daje RESPONSE_WRITE z danymi 0 i impuls
-- cmd_valid, z wyjątkiem COMMIT, RESET_CONFIG, CLEAR_COUNTERS i READ_RECORD,
-- które są obsługiwane tutaj. Odczyt strefy komend daje ERROR_WRITE_ONLY.
--
-- Czas: odpowiedź i impulsy wyjściowe pojawiają się takt po request_start.
-- request_* muszą być stabilne do response_valid.
-- Dane błędu: kod w najmłodszym bajcie, reszta zerowa.
-- =============================================================================

entity reg_access is
    port (
        clk             : in  std_logic;
        rst             : in  std_logic;

        -- żądanie z ctrl_protocol
        request_start   : in  std_logic;
        request_cmd     : in  byte_t;
        request_addr    : in  byte_t;
        request_data    : in  word_t;

        -- odpowiedź (1 takt po request_start)
        response_valid  : out std_logic;
        response_cmd    : out byte_t;
        response_addr   : out byte_t;
        response_data   : out word_t;

        -- polecenie do logiki akwizycji (impuls, tylko zapisy do strefy komend)
        cmd_valid       : out std_logic;
        cmd_addr        : out byte_t;

        -- żądanie wysłania rekordu (tylko READ_RECORD przy stanie READY)
        record_req      : out std_logic;

        -- konfiguracja aktywna
        active_record_length      : out word_t;
        active_channel_mask       : out byte_t;
        active_pre_length         : out word_t;
        active_trigger_source     : out byte_t;
        active_trigger_edge       : out byte_t;
        active_trigger_level      : out byte_t;
        active_trigger_hysteresis : out byte_t;

        -- offsety DAC (aktywne), wzmocnienie PGA (aktywne) i impuls po udanym COMMIT
        active_offset_a           : out std_logic_vector(11 downto 0);
        active_offset_b           : out std_logic_vector(11 downto 0);
        active_gain_a             : out byte_t;
        active_gain_b             : out byte_t;
        commit_ok_pulse           : out std_logic;

        -- stan akwizycji
        acquisition_state           : in  byte_t;
        acquisition_record_id       : in  word_t;
        acquisition_write_pointer   : in  unsigned(16 downto 0);
        acquisition_trigger_pointer : in  unsigned(16 downto 0);

        -- zdarzenia z parsera ramek (impulsy 1 takt)
        frame_ok_pulse  : in  std_logic;
        bad_magic_pulse : in  std_logic;

        -- wyjście debugowe
        debug_led       : out byte_t
    );
end entity reg_access;

architecture rtl of reg_access is

    constant DEFAULT_RECORD_LENGTH : word_t := std_logic_vector(to_unsigned(RECORD_MAX_SAMPLES, 32));
    constant DEFAULT_CHANNEL_MASK  : byte_t := x"01";
    constant DEFAULT_PRE_LENGTH    : word_t := (others => '0');
    constant DEFAULT_TRIG_SOURCE   : byte_t := x"00";
    constant DEFAULT_TRIG_EDGE     : byte_t := x"00";
    constant DEFAULT_TRIG_LEVEL    : byte_t := x"80";
    constant DEFAULT_TRIG_HYST     : byte_t := x"00";
    constant DEFAULT_OFFSET        : std_logic_vector(11 downto 0) := x"800";  -- środek skali
    constant DEFAULT_GAIN          : byte_t := x"00";                          -- AD8370 po resecie: LG0

    -- Maksymalna długość rekordu dla danej maski kanałów.
    -- Jeden kanał zajmuje pół słowa, więc mieści się dwa razy więcej próbek.
    function max_samples (mask : byte_t) return word_t is
    begin
        if mask(1 downto 0) = "11" then
            return std_logic_vector(to_unsigned(RECORD_MAX_SAMPLES, 32));
        else
            return std_logic_vector(to_unsigned(2 * RECORD_MAX_SAMPLES, 32));
        end if;
    end function max_samples;

    -- Rejestry DEBUG_*
    signal debug_scratch0_r : word_t := (others => '0');
    signal debug_scratch1_r : word_t := (others => '0');
    signal debug_led_r      : word_t := (others => '0');

    -- Konfiguracja: kopia oczekująca
    signal pending_record_length      : word_t := DEFAULT_RECORD_LENGTH;
    signal pending_channel_mask       : byte_t := DEFAULT_CHANNEL_MASK;
    signal pending_pre_length         : word_t := DEFAULT_PRE_LENGTH;
    signal pending_trigger_source     : byte_t := DEFAULT_TRIG_SOURCE;
    signal pending_trigger_edge       : byte_t := DEFAULT_TRIG_EDGE;
    signal pending_trigger_level      : byte_t := DEFAULT_TRIG_LEVEL;
    signal pending_trigger_hysteresis : byte_t := DEFAULT_TRIG_HYST;
    signal pending_offset_a           : std_logic_vector(11 downto 0) := DEFAULT_OFFSET;
    signal pending_offset_b           : std_logic_vector(11 downto 0) := DEFAULT_OFFSET;
    signal pending_gain_a             : byte_t := DEFAULT_GAIN;
    signal pending_gain_b             : byte_t := DEFAULT_GAIN;

    -- Konfiguracja: kopia aktywna
    signal active_record_length_r      : word_t := DEFAULT_RECORD_LENGTH;
    signal active_channel_mask_r       : byte_t := DEFAULT_CHANNEL_MASK;
    signal active_pre_length_r         : word_t := DEFAULT_PRE_LENGTH;
    signal active_trigger_source_r     : byte_t := DEFAULT_TRIG_SOURCE;
    signal active_trigger_edge_r       : byte_t := DEFAULT_TRIG_EDGE;
    signal active_trigger_level_r      : byte_t := DEFAULT_TRIG_LEVEL;
    signal active_trigger_hysteresis_r : byte_t := DEFAULT_TRIG_HYST;
    signal active_offset_a_r           : std_logic_vector(11 downto 0) := DEFAULT_OFFSET;
    signal active_offset_b_r           : std_logic_vector(11 downto 0) := DEFAULT_OFFSET;
    signal active_gain_a_r             : byte_t := DEFAULT_GAIN;
    signal active_gain_b_r             : byte_t := DEFAULT_GAIN;
    signal commit_ok_r                 : std_logic := '0';

    -- Liczniki protokołu
    signal counter_frames_ok        : unsigned(31 downto 0) := (others => '0');
    signal counter_bad_magic        : unsigned(31 downto 0) := (others => '0');
    signal counter_unknown_command  : unsigned(31 downto 0) := (others => '0');
    signal counter_bad_address      : unsigned(31 downto 0) := (others => '0');

    -- Wyjścia
    signal response_valid_r : std_logic := '0';
    signal response_cmd_r   : byte_t    := (others => '0');
    signal response_addr_r  : byte_t    := (others => '0');
    signal response_data_r  : word_t    := (others => '0');
    signal cmd_valid_r      : std_logic := '0';
    signal cmd_addr_r       : byte_t    := (others => '0');
    signal record_req_r     : std_logic := '0';

begin

    response_valid            <= response_valid_r;
    response_cmd              <= response_cmd_r;
    response_addr             <= response_addr_r;
    response_data             <= response_data_r;
    cmd_valid                 <= cmd_valid_r;
    cmd_addr                  <= cmd_addr_r;
    record_req                <= record_req_r;
    active_record_length      <= active_record_length_r;
    active_channel_mask       <= active_channel_mask_r;
    active_pre_length         <= active_pre_length_r;
    active_trigger_source     <= active_trigger_source_r;
    active_trigger_edge       <= active_trigger_edge_r;
    active_trigger_level      <= active_trigger_level_r;
    active_trigger_hysteresis <= active_trigger_hysteresis_r;
    active_offset_a           <= active_offset_a_r;
    active_offset_b           <= active_offset_b_r;
    active_gain_a             <= active_gain_a_r;
    active_gain_b             <= active_gain_b_r;
    commit_ok_pulse           <= commit_ok_r;
    debug_led                 <= debug_led_r(7 downto 0);

    p_req : process (clk)
        variable v_addr : integer;
        variable v_err  : boolean;
        variable v_code : byte_t;
        variable v_data : word_t;
        variable v_mask : byte_t;
    begin
        if rising_edge(clk) then
            response_valid_r <= '0';
            cmd_valid_r      <= '0';
            record_req_r     <= '0';
            commit_ok_r      <= '0';

            -- zdarzenia z parsera ramek zwiększają liczniki niezależnie od żądania
            if frame_ok_pulse = '1' then
                counter_frames_ok <= counter_frames_ok + 1;
            end if;
            if bad_magic_pulse = '1' then
                counter_bad_magic <= counter_bad_magic + 1;
            end if;

            if rst = '1' then
                debug_scratch0_r              <= (others => '0');
                debug_scratch1_r              <= (others => '0');
                debug_led_r                   <= (others => '0');
                pending_record_length         <= DEFAULT_RECORD_LENGTH;
                pending_channel_mask          <= DEFAULT_CHANNEL_MASK;
                pending_pre_length            <= DEFAULT_PRE_LENGTH;
                pending_trigger_source        <= DEFAULT_TRIG_SOURCE;
                pending_trigger_edge          <= DEFAULT_TRIG_EDGE;
                pending_trigger_level         <= DEFAULT_TRIG_LEVEL;
                pending_trigger_hysteresis    <= DEFAULT_TRIG_HYST;
                pending_offset_a              <= DEFAULT_OFFSET;
                pending_offset_b              <= DEFAULT_OFFSET;
                pending_gain_a                <= DEFAULT_GAIN;
                pending_gain_b                <= DEFAULT_GAIN;
                active_record_length_r        <= DEFAULT_RECORD_LENGTH;
                active_channel_mask_r         <= DEFAULT_CHANNEL_MASK;
                active_pre_length_r           <= DEFAULT_PRE_LENGTH;
                active_trigger_source_r       <= DEFAULT_TRIG_SOURCE;
                active_trigger_edge_r         <= DEFAULT_TRIG_EDGE;
                active_trigger_level_r        <= DEFAULT_TRIG_LEVEL;
                active_trigger_hysteresis_r   <= DEFAULT_TRIG_HYST;
                active_offset_a_r             <= DEFAULT_OFFSET;
                active_offset_b_r             <= DEFAULT_OFFSET;
                active_gain_a_r               <= DEFAULT_GAIN;
                active_gain_b_r               <= DEFAULT_GAIN;
                counter_frames_ok             <= (others => '0');
                counter_bad_magic             <= (others => '0');
                counter_unknown_command       <= (others => '0');
                counter_bad_address           <= (others => '0');

            elsif request_start = '1' then
                v_addr := to_integer(unsigned(request_addr));
                v_err  := false;
                v_code := ERROR_BAD_ADDRESS;
                v_data := (others => '0');

                if request_cmd = COMMAND_WRITE then

                    -- rejestry debug: zapis i odczyt
                    if request_addr = ADDR_DEBUG_SCRATCH0 then
                        debug_scratch0_r <= request_data;
                        v_data           := request_data;

                    elsif request_addr = ADDR_DEBUG_SCRATCH1 then
                        debug_scratch1_r <= request_data;
                        v_data           := request_data;

                    elsif request_addr = ADDR_DEBUG_LED then
                        debug_led_r <= request_data;
                        v_data      := request_data;

                    -- konfiguracja oczekująca: walidacja przy zapisie
                    elsif request_addr = ADDR_ACQUISITION_RECORD_LENGTH then
                        if unsigned(request_data) >= 1
                           and unsigned(request_data) <= unsigned(max_samples(pending_channel_mask)) then
                            pending_record_length <= request_data;
                            v_data                := request_data;
                        else
                            v_err  := true;
                            v_code := ERROR_BAD_VALUE;
                        end if;

                    elsif request_addr = ADDR_ACQUISITION_CHANNEL_MASK then
                        v_mask := (others => '0');
                        v_mask(1 downto 0) := request_data(1 downto 0);
                        if request_data(1 downto 0) = "00"
                           or unsigned(pending_record_length) > unsigned(max_samples(v_mask)) then
                            v_err  := true;
                            v_code := ERROR_BAD_VALUE;
                        else
                            pending_channel_mask <= v_mask;
                            v_data := (others => '0');
                            v_data(7 downto 0) := v_mask;
                        end if;

                    elsif request_addr = ADDR_ACQUISITION_PRETRIGGER then
                        if unsigned(request_data) <= unsigned(max_samples(pending_channel_mask)) - 1 then
                            pending_pre_length <= request_data;
                            v_data             := request_data;
                        else
                            v_err  := true;
                            v_code := ERROR_BAD_VALUE;
                        end if;

                    elsif request_addr = ADDR_TRIGGER_SOURCE then
                        if unsigned(request_data) <= 1 then
                            pending_trigger_source <= request_data(7 downto 0);
                            v_data                 := x"000000" & request_data(7 downto 0);
                        else
                            v_err  := true;
                            v_code := ERROR_BAD_VALUE;
                        end if;

                    elsif request_addr = ADDR_TRIGGER_EDGE then
                        if unsigned(request_data) <= 2 then
                            pending_trigger_edge <= request_data(7 downto 0);
                            v_data               := x"000000" & request_data(7 downto 0);
                        else
                            v_err  := true;
                            v_code := ERROR_BAD_VALUE;
                        end if;

                    elsif request_addr = ADDR_TRIGGER_LEVEL then
                        if unsigned(request_data) <= 255 then
                            pending_trigger_level <= request_data(7 downto 0);
                            v_data                := x"000000" & request_data(7 downto 0);
                        else
                            v_err  := true;
                            v_code := ERROR_BAD_VALUE;
                        end if;

                    elsif request_addr = ADDR_TRIGGER_HYSTERESIS then
                        if unsigned(request_data) <= 255 then
                            pending_trigger_hysteresis <= request_data(7 downto 0);
                            v_data                     := x"000000" & request_data(7 downto 0);
                        else
                            v_err  := true;
                            v_code := ERROR_BAD_VALUE;
                        end if;

                    -- wzmocnienie PGA: każdy bajt poprawny, bez walidacji
                    elsif request_addr = ADDR_CHANNEL1_GAIN then
                        pending_gain_a <= request_data(7 downto 0);
                        v_data         := x"000000" & request_data(7 downto 0);

                    elsif request_addr = ADDR_CHANNEL2_GAIN then
                        pending_gain_b <= request_data(7 downto 0);
                        v_data         := x"000000" & request_data(7 downto 0);

                    -- offsety DAC: 12 bitów, 0..4095
                    elsif request_addr = ADDR_CHANNEL1_OFFSET or request_addr = ADDR_CHANNEL2_OFFSET then
                        if unsigned(request_data) <= 4095 then
                            if request_addr = ADDR_CHANNEL1_OFFSET then
                                pending_offset_a <= request_data(11 downto 0);
                            else
                                pending_offset_b <= request_data(11 downto 0);
                            end if;
                            v_data := (others => '0');
                            v_data(11 downto 0) := request_data(11 downto 0);
                        else
                            v_err  := true;
                            v_code := ERROR_BAD_VALUE;
                        end if;

                    -- rejestry tylko do odczytu
                    elsif request_addr = ADDR_DEVICE_ID or request_addr = ADDR_PROTOCOL_VERSION
                          or request_addr = ADDR_DEBUG_CONST
                          or request_addr = ADDR_ACQUISITION_STATE
                          or request_addr = ADDR_ACQUISITION_RECORD_ID
                          or request_addr = ADDR_ACQUISITION_WRITE_POINTER
                          or request_addr = ADDR_ACQUISITION_TRIGGER_POINTER
                          or request_addr = ADDR_COUNTER_FRAMES_OK
                          or request_addr = ADDR_COUNTER_BAD_MAGIC
                          or request_addr = ADDR_COUNTER_UNKNOWN_COMMAND
                          or request_addr = ADDR_COUNTER_BAD_ADDRESS then
                        v_err  := true;
                        v_code := ERROR_READ_ONLY;

                    -- odczyt rekordu: tylko gdy READY
                    elsif request_addr = ADDR_COMMAND_READ_RECORD then
                        if acquisition_state = x"03" then
                            record_req_r <= '1';
                            v_data       := (others => '0');
                        else
                            v_err  := true;
                            v_code := ERROR_NOT_READY;
                        end if;

                    -- COMMIT: tylko w IDLE, z regułami krzyżowymi
                    elsif request_addr = ADDR_COMMAND_COMMIT then
                        if acquisition_state /= x"00" then
                            v_err  := true;
                            v_code := ERROR_BAD_VALUE;
                        elsif unsigned(pending_record_length) > unsigned(max_samples(pending_channel_mask)) then
                            v_err  := true;
                            v_code := ERROR_BAD_VALUE;
                        elsif unsigned(pending_pre_length) >= unsigned(pending_record_length) then
                            v_err  := true;
                            v_code := ERROR_BAD_VALUE;
                        elsif (pending_trigger_source = x"00" and pending_channel_mask(0) = '0')
                              or (pending_trigger_source = x"01" and pending_channel_mask(1) = '0') then
                            v_err  := true;
                            v_code := ERROR_BAD_VALUE;
                        else
                            active_record_length_r      <= pending_record_length;
                            active_channel_mask_r       <= pending_channel_mask;
                            active_pre_length_r         <= pending_pre_length;
                            active_trigger_source_r     <= pending_trigger_source;
                            active_trigger_edge_r       <= pending_trigger_edge;
                            active_trigger_level_r      <= pending_trigger_level;
                            active_trigger_hysteresis_r <= pending_trigger_hysteresis;
                            active_offset_a_r           <= pending_offset_a;
                            active_offset_b_r           <= pending_offset_b;
                            active_gain_a_r             <= pending_gain_a;
                            active_gain_b_r             <= pending_gain_b;
                            commit_ok_r                 <= '1';
                            v_data                      := (others => '0');
                        end if;

                    -- RESET_CONFIG: wartości domyślne do kopii oczekującej
                    elsif request_addr = ADDR_COMMAND_RESET_CONFIG then
                        pending_record_length      <= DEFAULT_RECORD_LENGTH;
                        pending_channel_mask       <= DEFAULT_CHANNEL_MASK;
                        pending_pre_length         <= DEFAULT_PRE_LENGTH;
                        pending_trigger_source     <= DEFAULT_TRIG_SOURCE;
                        pending_trigger_edge       <= DEFAULT_TRIG_EDGE;
                        pending_trigger_level      <= DEFAULT_TRIG_LEVEL;
                        pending_trigger_hysteresis <= DEFAULT_TRIG_HYST;
                        pending_offset_a           <= DEFAULT_OFFSET;
                        pending_offset_b           <= DEFAULT_OFFSET;
                        pending_gain_a             <= DEFAULT_GAIN;
                        pending_gain_b             <= DEFAULT_GAIN;
                        v_data                     := (others => '0');

                    -- czyszczenie liczników: obsługiwane tutaj, bez cmd_valid
                    elsif request_addr = ADDR_COMMAND_CLEAR_COUNTERS then
                        counter_frames_ok       <= (others => '0');
                        counter_bad_magic       <= (others => '0');
                        counter_unknown_command <= (others => '0');
                        counter_bad_address     <= (others => '0');
                        v_data                  := (others => '0');

                    -- pozostałe komendy strefy 0x10-0x17
                    elsif v_addr >= 16 and v_addr <= 23 then
                        cmd_valid_r <= '1';
                        cmd_addr_r  <= request_addr;
                        v_data      := (others => '0');

                    else
                        v_err  := true;
                        v_code := ERROR_BAD_ADDRESS;
                    end if;

                elsif request_cmd = COMMAND_READ then

                    if request_addr = ADDR_DEVICE_ID then
                        v_data := VAL_DEVICE_ID;

                    elsif request_addr = ADDR_PROTOCOL_VERSION then
                        v_data := VAL_PROTOCOL_VERSION;

                    elsif request_addr = ADDR_ACQUISITION_RECORD_LENGTH then
                        v_data := pending_record_length;

                    elsif request_addr = ADDR_ACQUISITION_CHANNEL_MASK then
                        v_data := x"000000" & pending_channel_mask;

                    elsif request_addr = ADDR_ACQUISITION_PRETRIGGER then
                        v_data := pending_pre_length;

                    elsif request_addr = ADDR_TRIGGER_SOURCE then
                        v_data := x"000000" & pending_trigger_source;

                    elsif request_addr = ADDR_TRIGGER_EDGE then
                        v_data := x"000000" & pending_trigger_edge;

                    elsif request_addr = ADDR_TRIGGER_LEVEL then
                        v_data := x"000000" & pending_trigger_level;

                    elsif request_addr = ADDR_TRIGGER_HYSTERESIS then
                        v_data := x"000000" & pending_trigger_hysteresis;

                    elsif request_addr = ADDR_CHANNEL1_GAIN then
                        v_data := x"000000" & pending_gain_a;

                    elsif request_addr = ADDR_CHANNEL2_GAIN then
                        v_data := x"000000" & pending_gain_b;

                    elsif request_addr = ADDR_CHANNEL1_OFFSET then
                        v_data := (others => '0');
                        v_data(11 downto 0) := pending_offset_a;

                    elsif request_addr = ADDR_CHANNEL2_OFFSET then
                        v_data := (others => '0');
                        v_data(11 downto 0) := pending_offset_b;

                    elsif request_addr = ADDR_ACQUISITION_STATE then
                        v_data := x"000000" & acquisition_state;

                    elsif request_addr = ADDR_ACQUISITION_RECORD_ID then
                        v_data := acquisition_record_id;

                    elsif request_addr = ADDR_ACQUISITION_WRITE_POINTER then
                        v_data := (others => '0');
                        v_data(16 downto 0) := std_logic_vector(acquisition_write_pointer);

                    elsif request_addr = ADDR_ACQUISITION_TRIGGER_POINTER then
                        v_data := (others => '0');
                        v_data(16 downto 0) := std_logic_vector(acquisition_trigger_pointer);

                    elsif request_addr = ADDR_COUNTER_FRAMES_OK then
                        v_data := std_logic_vector(counter_frames_ok);

                    elsif request_addr = ADDR_COUNTER_BAD_MAGIC then
                        v_data := std_logic_vector(counter_bad_magic);

                    elsif request_addr = ADDR_COUNTER_UNKNOWN_COMMAND then
                        v_data := std_logic_vector(counter_unknown_command);

                    elsif request_addr = ADDR_COUNTER_BAD_ADDRESS then
                        v_data := std_logic_vector(counter_bad_address);

                    elsif request_addr = ADDR_DEBUG_SCRATCH0 then
                        v_data := debug_scratch0_r;

                    elsif request_addr = ADDR_DEBUG_SCRATCH1 then
                        v_data := debug_scratch1_r;

                    elsif request_addr = ADDR_DEBUG_LED then
                        v_data := debug_led_r;

                    elsif request_addr = ADDR_DEBUG_CONST then
                        v_data := VAL_DEBUG_CONST;

                    elsif v_addr >= 16 and v_addr <= 23 then
                        -- strefa komend: tylko zapis
                        v_err  := true;
                        v_code := ERROR_WRITE_ONLY;

                    else
                        v_err  := true;
                        v_code := ERROR_BAD_ADDRESS;
                    end if;

                else
                    v_err  := true;
                    v_code := ERROR_UNKNOWN_COMMAND;
                end if;

                -- liczniki błędów
                if v_err then
                    if v_code = ERROR_UNKNOWN_COMMAND then
                        counter_unknown_command <= counter_unknown_command + 1;
                    elsif v_code = ERROR_BAD_ADDRESS then
                        counter_bad_address <= counter_bad_address + 1;
                    end if;
                end if;

                -- zbudowanie odpowiedzi
                response_addr_r <= request_addr;
                if v_err then
                    response_cmd_r  <= RESPONSE_ERROR;
                    response_data_r <= x"000000" & v_code;
                elsif request_cmd = COMMAND_WRITE then
                    response_cmd_r  <= RESPONSE_WRITE;
                    response_data_r <= v_data;
                else
                    response_cmd_r  <= RESPONSE_READ;
                    response_data_r <= v_data;
                end if;
                response_valid_r <= '1';

            end if;
        end if;
    end process p_req;

end architecture rtl;
