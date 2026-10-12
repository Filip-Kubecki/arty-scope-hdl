library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.regmap_pkg.all;

-- =============================================================================
-- measurement_data_tx.vhd
-- Nadajnik bloku danych: nagłówek 64 bajty, potem próbki wg channel_mask.
--
-- Nagłówek (bajty big-endian, pola nieaktywne zerowe):
--   0-1   magic (MAGIC_0, MAGIC_1)
--   2     typ (RECORD_TYPE_DATA)
--   3     flagi (zero)
--   4-7   PAYLOAD_LEN: długość próbek w bajtach
--   8-11  RECORD_ID
--   12    CHANNEL_MASK
--   13    SAMPLE_BITS (RECORD_SAMPLE_BITS)
--   14-15 zarezerwowane
--   16-19 SAMPLES_PER_CH
--   20-63 zarezerwowane
--
-- Próbki: słowo pamięci = ch2 & ch1.
--   mask 01: młodszy bajt każdego słowa (ch1)
--   mask 10: starszy bajt każdego słowa (ch2)
--   mask 11: dla każdego słowa najpierw ch1, potem ch2
--   mask 00: tylko nagłówek, PAYLOAD_LEN = 0
--
-- Pamięć: rd_addr jest podawany z opóźnieniem jednego taktu na rd_data
-- (zgodnie z sample_mem). Każde słowo: FETCH, LATCH, potem wysyłanie.
--
-- Rozpoczyna tylko gdy jest w IDLE. Impuls done po wysłaniu ostatniego bajtu danych.
-- =============================================================================

entity measurement_data_tx is
    port (
        -- System
        clk          : in  std_logic;
        rst          : in  std_logic;

        start        : in  std_logic;   -- impuls: rozpocznij nadawanie
        record_id    : in  word_t;
        samples      : in  word_t;
        channel_mask : in  byte_t;

        -- Odczyt pamięci rekordu
        rd_addr      : out unsigned(12 downto 0);
        rd_data      : in  std_logic_vector(15 downto 0);

        -- Strumień do tx
        tx_data      : out byte_t;
        tx_valid     : out std_logic;
        tx_ready     : in  std_logic;

        busy         : out std_logic;
        done         : out std_logic    -- impuls: blok wysłany
    );
end entity measurement_data_tx;

architecture rtl of measurement_data_tx is

    type state_t is (S_IDLE, S_HEADER, S_FETCH, S_LATCH, S_SEND, S_DONE);

    signal state               : state_t := S_IDLE;
    signal header_shift_reg    : std_logic_vector(511 downto 0) := (others => '0');
    signal header_byte_count   : unsigned(5 downto 0) := (others => '0');
    signal sample_index        : unsigned(12 downto 0) := (others => '0');
    signal last_sample_index   : unsigned(12 downto 0) := (others => '0');
    signal channel_mask_reg    : byte_t := (others => '0');
    signal channel_phase       : std_logic := '0';   -- 0: pierwszy bajt słowa, 1: drugi
    signal sample_word_reg     : std_logic_vector(15 downto 0) := (others => '0');
    signal done_reg            : std_logic := '0';

    -- Zbudowanie 64 bajtów nagłówka. n-ty bajt zajmuje bity [511-8*n : 504-8*n].
    function build_header (
        record_id_value      : word_t;
        samples_value        : word_t;
        channel_mask_value   : byte_t;
        payload_length_value : word_t
    ) return std_logic_vector is
        variable header : std_logic_vector(511 downto 0) := (others => '0');
    begin
        header(511 downto 504) := MAGIC_0;
        header(503 downto 496) := MAGIC_1;
        header(495 downto 488) := RECORD_TYPE_DATA;
        -- bajt 3: flagi = 0
        header(479 downto 448) := payload_length_value;
        header(447 downto 416) := record_id_value;
        header(415 downto 408) := channel_mask_value;
        header(407 downto 400) := std_logic_vector(to_unsigned(RECORD_SAMPLE_BITS, 8));
        -- bajty 14-15: zarezerwowane
        header(383 downto 352) := samples_value;
        -- bajty 20-63: zarezerwowane
        return header;
    end function build_header;

begin
    rd_addr <= sample_index;    -- Adres odczytu to indeks bieżącej próbki
    tx_valid <= '1' when (state = S_HEADER) or (state = S_SEND) else '0';

    -- W nagłówku: bajt z najstarszych bitów rejestru przesuwnego.
    -- W próbkach: wybór bajtu słowa wg maski i fazy.
    tx_data <= header_shift_reg(511 downto 504) when state = S_HEADER else
               sample_word_reg(15 downto 8)     when (channel_mask_reg(1) = '1' and
                                                     (channel_mask_reg(0) = '0' or channel_phase = '1')) else
               sample_word_reg(7 downto 0);

    busy <= '0' when state = S_IDLE else '1';
    done <= done_reg;

    p_fsm : process (clk)
        variable samples_count  : natural;
        variable channels_count : natural;
        variable payload_bytes  : natural;
    begin
        if rising_edge(clk) then
            done_reg <= '0';

            if rst = '1' then
                state <= S_IDLE;

            else
                case state is

                    -- Czeka na start. Liczy długość payload'u, buduje nagłówek i zapisuje parametry bloku.
                    when S_IDLE =>
                        if start = '1' then
                            samples_count := to_integer(unsigned(samples));

                            if channel_mask(1 downto 0) = "11" then
                                channels_count := 2;
                            else
                                channels_count := 1;
                            end if;

                            if channel_mask(1 downto 0) = "00" then
                                payload_bytes := 0;
                            else
                                payload_bytes := samples_count * channels_count;
                            end if;

                            header_shift_reg <= build_header(record_id, samples, channel_mask, std_logic_vector(to_unsigned(payload_bytes, 32)));
                            channel_mask_reg <= channel_mask;

                            if samples_count > 0 then
                                last_sample_index <= to_unsigned(samples_count - 1, 13);
                            else
                                last_sample_index <= (others => '0');
                            end if;

                            header_byte_count <= (others => '0');
                            sample_index      <= (others => '0');
                            channel_phase     <= '0';
                            state             <= S_HEADER;
                        end if;

                    -- Wysyła 64 bajty nagłówka, przesuwając rejestr o bajt na każdy takt tx_ready.
                    -- Przy masce 00 kończy od razu, bez próbek.
                    when S_HEADER =>
                        if tx_ready = '1' then
                            header_shift_reg <= header_shift_reg(503 downto 0) & x"00";
                            if header_byte_count = 63 then
                                if channel_mask_reg(1 downto 0) = "00" then
                                    state <= S_DONE;
                                else
                                    state <= S_FETCH;
                                end if;
                            else
                                header_byte_count <= header_byte_count + 1;
                            end if;
                        end if;

                    -- Ustawia adres odczytu (sample_index). Dane pojawią się w następnym takcie.
                    when S_FETCH =>
                        state <= S_LATCH;

                    -- Kopiuje słowo z pamięci do rejestru, bo dane są ważne dopiero w tym momencie.
                    when S_LATCH =>
                        sample_word_reg <= rd_data;
                        state           <= S_SEND;

                    -- Wysyła bajty bieżącego słowa. Przy masce 11 najpierw ch1, potem ch2.
                    -- Po ostatnim bajcie słowa przechodzi do następnej próbki lub do DONE.
                    when S_SEND =>
                        if tx_ready = '1' then
                            if channel_mask_reg(1 downto 0) = "11" and channel_phase = '0' then
                                -- drugi bajt tego samego słowa
                                channel_phase <= '1';
                            else
                                channel_phase <= '0';
                                if sample_index = last_sample_index then
                                    state <= S_DONE;
                                else
                                    sample_index <= sample_index + 1;
                                    state        <= S_FETCH;
                                end if;
                            end if;
                        end if;

                    -- Wystawia impuls done przez jeden takt i wraca do IDLE.
                    when S_DONE =>
                        done_reg <= '1';
                        state    <= S_IDLE;

                end case;
            end if;
        end if;
    end process p_fsm;

end architecture rtl;
