library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.regmap_pkg.all;

-- =============================================================================
-- reg_access.vhd
-- Obsługa zapisu i odczytu rejestrów sterujących: sprawdzenie adresu,
-- komendy i uprawnień, wykonanie operacji, budowa odpowiedzi.
--
-- Rejestry:
--   DEVICE_ID, PROTOCOL_VERSION, DEBUG_CONST   tylko odczyt
--   DEBUG_SCRATCH0, DEBUG_SCRATCH1             odczyt i zapis
--   DEBUG_LED                                  odczyt i zapis, bity [7:0] na debug_led
--
-- Strefa komend 0x10-0x17: zapis daje RESPONSE_WRITE z danymi 0 i impuls
-- cmd_valid; odczyt daje ERROR_WRITE_ONLY. Adresy 0x18-0x1F są niewspierane.
--
-- Pozostałe adresy zwracają ERROR_BAD_ADDRESS. Komenda inna niż WRITE i READ
-- zwraca ERROR_UNKNOWN_COMMAND.
--
-- Czas: odpowiedź i cmd_valid pojawiają się takt po request_start.
-- request_* muszą być stabilne do response_valid.
--
-- Dane błędu: kod w najmłodszym bajcie, reszta zerowa.
-- =============================================================================

entity reg_access is
    port (
        clk             : in  std_logic;
        rst             : in  std_logic;

        -- żądanie z ctrl_protocol
        request_start   : in  std_logic;                  -- impuls
        request_cmd     : in  byte_t;
        request_addr    : in  byte_t;
        request_data    : in  word_t;

        -- odpowiedź (1 takt po request_start)
        response_valid  : out std_logic;
        response_cmd    : out byte_t;                     -- pełny bajt odpowiedzi
        response_addr   : out byte_t;                     -- echo adresu
        response_data   : out word_t;

        -- polecenie do logiki akwizycji (impuls, tylko zapisy do strefy komend)
        cmd_valid       : out std_logic;
        cmd_addr        : out byte_t;

        -- wyjście debugowe
        debug_led       : out byte_t
    );
end entity reg_access;

architecture rtl of reg_access is

    -- Rejestry DEBUG_*: odczyt i zapis, bez wpływu na resztę układu
    -- (służą do sprawdzenia toru komunikacji od komputera do FPGA i z powrotem)
    signal debug_scratch0_r  : word_t := (others => '0');
    signal debug_scratch1_r  : word_t := (others => '0');
    signal debug_led_r       : word_t := (others => '0');

    signal response_valid_r  : std_logic := '0';
    signal response_cmd_r    : byte_t    := (others => '0');
    signal response_addr_r   : byte_t    := (others => '0');
    signal response_data_r   : word_t    := (others => '0');
    signal cmd_valid_r       : std_logic := '0';
    signal cmd_addr_r        : byte_t    := (others => '0');

begin

    response_valid <= response_valid_r;
    response_cmd   <= response_cmd_r;
    response_addr  <= response_addr_r;
    response_data  <= response_data_r;
    cmd_valid      <= cmd_valid_r;
    cmd_addr       <= cmd_addr_r;
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

            if rst = '1' then
                debug_scratch0_r <= (others => '0');
                debug_scratch1_r <= (others => '0');
                debug_led_r      <= (others => '0');

            elsif request_start = '1' then
                v_addr := to_integer(unsigned(request_addr));
                v_err  := false;
                v_code := ERROR_BAD_ADDRESS;
                v_data := (others => '0');

                if request_cmd = COMMAND_WRITE then

                    if request_addr = ADDR_DEBUG_SCRATCH0 then
                        debug_scratch0_r <= request_data;
                        v_data           := request_data;

                    elsif request_addr = ADDR_DEBUG_SCRATCH1 then
                        debug_scratch1_r <= request_data;
                        v_data           := request_data;

                    elsif request_addr = ADDR_DEBUG_LED then
                        debug_led_r <= request_data;
                        v_data      := request_data;

                    elsif request_addr = ADDR_DEVICE_ID or request_addr = ADDR_PROTOCOL_VERSION
                          or request_addr = ADDR_DEBUG_CONST then
                        v_err  := true;
                        v_code := ERROR_READ_ONLY;

                    elsif v_addr >= 16 and v_addr <= 23 then
                        -- strefa komend 0x10-0x17
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
