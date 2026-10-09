library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.regmap_pkg.all;

-- =============================================================================
-- frame_rx.vhd
-- Parser ramek sterowania, bajt po bajcie
--
-- Zachowanie:
--   * Szuka magic number C7 E2. Bajty nie będące magic są odrzucane i liczone
--     w bad_magic. Bajt C7 po C7 zostaje traktowany jako możliwy początek magic.
--   * Zbiera komendę, adres i 4 bajty danych (big-endian), czyli 6 bajtów
--     po magic, w jednym rejestrze przesuwnym.
--   * Po kompletnej ramce wystawia impuls req_valid i wstrzymuje odbiór
--     (rx_ready = '0') do impulsu resp_done z ctrl_protocol. Dzięki temu w toku
--     jest co najwyżej jedno zapytanie, a odpowiedzi nie przeplatają się.
--   * Rozłączenie klienta (link_up = '0') natychmiast wraca do szukania magic.
--   * Walidacji komendy i adresu tu nie ma. Robi to ctrl_protocol.
--
-- Konwencja bajtowego interfejsu: bajt jest przyjęty, gdy rx_valid = '1'
-- i rx_ready = '1' na narastającym zboczu clk.
-- =============================================================================

entity frame_rx is
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;
        link_up    : in  std_logic;                 -- '0' = klient rozłączony

        -- bajtowy interfejs odbiorczy rdzenia TCP
        rx_data    : in  byte_t;
        rx_valid   : in  std_logic;                 -- bajt czeka na wejściu
        rx_ready   : out std_logic;                 -- '0' = nie przyjmuj bajtów

        -- do ctrl_protocol
        req_valid  : out std_logic;                 -- impuls 1 takt: ramka kompletna
        req_cmd    : out byte_t;
        req_addr   : out byte_t;
        req_data   : out word_t;
        resp_done  : in  std_logic;                 -- impuls: odpowiedź wysłana

        -- liczniki (impulsy 1 takt)
        frame_ok   : out std_logic;                 -- ramka przekazana do obsługi
        bad_magic  : out std_logic                  -- bajt odrzucony przy szukaniu magic
    );
end entity frame_rx;

architecture rtl of frame_rx is

    type state_t is (S_MAGIC0, S_MAGIC1, S_DATA, S_WAIT_RESP);

    signal state       : state_t := S_MAGIC0;
    signal shift_r     : std_logic_vector(47 downto 0) := (others => '0');
    signal byte_cnt    : unsigned(2 downto 0) := (others => '0');
    signal req_valid_r : std_logic := '0';
    signal frame_ok_r  : std_logic := '0';
    signal bad_magic_r : std_logic := '0';

begin

    -- wyjścia z rejestru przesuwnego (stabilne podczas S_WAIT_RESP)
    req_cmd  <= shift_r(47 downto 40);
    req_addr <= shift_r(39 downto 32);
    req_data <= shift_r(31 downto 0);

    -- impulsy z rejestrów na porty modułu
    req_valid <= req_valid_r;
    frame_ok  <= frame_ok_r;
    bad_magic <= bad_magic_r;

    -- odbiór wstrzymany tylko na czas odpowiedzi
    rx_ready <= '0' when state = S_WAIT_RESP else '1';

    p_fsm : process (clk)
    begin
        if rising_edge(clk) then
            req_valid_r <= '0';
            frame_ok_r  <= '0';
            bad_magic_r <= '0';

            if rst = '1' or link_up = '0' then
                state <= S_MAGIC0;

            else
                case state is

                    when S_MAGIC0 =>
                        if rx_valid = '1' then
                            if rx_data = MAGIC_0 then
                                state <= S_MAGIC1;
                            else
                                bad_magic_r <= '1';
                            end if;
                        end if;

                    when S_MAGIC1 =>
                        if rx_valid = '1' then
                            if rx_data = MAGIC_1 then
                                byte_cnt <= (others => '0');
                                state    <= S_DATA;
                            else
                                -- Odrzucony bajt. Jeśli to C7, może być początkiem
                                -- magic number, więc zostajemy w S_MAGIC1.
                                bad_magic_r <= '1';
                                if rx_data /= MAGIC_0 then
                                    state <= S_MAGIC0;
                                end if;
                            end if;
                        end if;

                    -- komenda, adres i 4 bajty danych w rejestrze przesuwnym (big-endian)
                    when S_DATA =>
                        if rx_valid = '1' then
                            shift_r <= shift_r(39 downto 0) & rx_data;
                            if byte_cnt = 5 then
                                req_valid_r <= '1';
                                frame_ok_r  <= '1';
                                state       <= S_WAIT_RESP;
                            else
                                byte_cnt <= byte_cnt + 1;
                            end if;
                        end if;

                    when S_WAIT_RESP =>
                        if resp_done = '1' then
                            state <= S_MAGIC0;
                        end if;

                end case;
            end if;
        end if;
    end process p_fsm;

end architecture rtl;
