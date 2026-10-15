library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.regmap_pkg.all;

-- =============================================================================
-- reg_access.vhd
-- Obsługa zapisu i odczytu rejestrów: sprawdzenie adresu, komendy i uprawnień,
-- wykonanie operacji, budowa odpowiedzi.
--
-- Liczniki protokołu (zapis do rejestrów tylko przez COMMAND_CLEAR_COUNTERS):
--   COUNTER_FRAMES_OK        ramki przekazane do obsługi (impuls z frame_rx)
--   COUNTER_BAD_MAGIC        bajty odrzucone przy szukaniu magic (impuls z frame_rx)
--   COUNTER_UNKNOWN_COMMAND  nieznane komendy
--   COUNTER_BAD_ADDRESS      dostępy do adresów nieistniejących lub zarezerwowanych
--
-- Strefa komend 0x10-0x17: zapis daje RESPONSE_WRITE z danymi 0 i impuls
-- cmd_valid, z wyjątkiem CLEAR_COUNTERS (obsługiwany tutaj) i READ_RECORD
-- (impuls record_req). Odczyt strefy komend daje ERROR_WRITE_ONLY.
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

        -- polecenie do logiki akwizycji
        cmd_valid       : out std_logic;
        cmd_addr        : out byte_t;

        -- żądanie wysłania rekordu (tylko READ_RECORD przy stanie READY)
        record_req      : out std_logic;

        -- stan akwizycji
        acquisition_state     : in  byte_t;
        acquisition_record_id : in  word_t;

        -- zdarzenia z parsera ramek (impulsy 1 takt)
        frame_ok_pulse  : in  std_logic;
        bad_magic_pulse : in  std_logic;

        -- wyjście debugowe
        debug_led       : out byte_t
    );
end entity reg_access;

architecture rtl of reg_access is

    -- Rejestry DEBUG_*
    signal debug_scratch0_r   : word_t := (others => '0');
    signal debug_scratch1_r   : word_t := (others => '0');
    signal debug_led_r        : word_t := (others => '0');

    -- Liczniki protokołu
    signal counter_frames_ok        : unsigned(31 downto 0) := (others => '0');
    signal counter_bad_magic        : unsigned(31 downto 0) := (others => '0');
    signal counter_unknown_command  : unsigned(31 downto 0) := (others => '0');
    signal counter_bad_address      : unsigned(31 downto 0) := (others => '0');

    -- Wyjścia
    signal response_valid_r   : std_logic := '0';
    signal response_cmd_r     : byte_t    := (others => '0');
    signal response_addr_r    : byte_t    := (others => '0');
    signal response_data_r    : word_t    := (others => '0');
    signal cmd_valid_r        : std_logic := '0';
    signal cmd_addr_r         : byte_t    := (others => '0');
    signal record_req_r       : std_logic := '0';

begin

    response_valid <= response_valid_r;
    response_cmd   <= response_cmd_r;
    response_addr  <= response_addr_r;
    response_data  <= response_data_r;
    cmd_valid      <= cmd_valid_r;
    cmd_addr       <= cmd_addr_r;
    record_req     <= record_req_r;
    debug_led      <= debug_led_r(7 downto 0);

    p_req : process (clk)
        variable v_addr : integer;
        variable v_err  : boolean;
        variable v_code : byte_t;
        variable v_data : word_t;
    begin
        if rising_edge(clk) then
            response_valid_r <= '0';
            cmd_valid_r      <= '0';
            record_req_r     <= '0';

            -- zdarzenia z parsera zwiększają liczniki niezależnie od żądania
            if frame_ok_pulse = '1' then
                counter_frames_ok <= counter_frames_ok + 1;
            end if;
            if bad_magic_pulse = '1' then
                counter_bad_magic <= counter_bad_magic + 1;
            end if;

            if rst = '1' then
                debug_scratch0_r       <= (others => '0');
                debug_scratch1_r       <= (others => '0');
                debug_led_r            <= (others => '0');
                counter_frames_ok      <= (others => '0');
                counter_bad_magic      <= (others => '0');
                counter_unknown_command <= (others => '0');
                counter_bad_address    <= (others => '0');

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

                    -- rejestry tylko do odczytu
                    elsif request_addr = ADDR_DEVICE_ID or request_addr = ADDR_PROTOCOL_VERSION
                          or request_addr = ADDR_DEBUG_CONST
                          or request_addr = ADDR_ACQUISITION_STATE
                          or request_addr = ADDR_ACQUISITION_RECORD_ID
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

                    elsif request_addr = ADDR_ACQUISITION_STATE then
                        v_data := x"000000" & acquisition_state;

                    elsif request_addr = ADDR_ACQUISITION_RECORD_ID then
                        v_data := acquisition_record_id;

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
