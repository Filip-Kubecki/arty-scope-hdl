library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.regmap_pkg.all;

-- =============================================================================
-- frame_tx.vhd
-- Nadajnik odpowiedzi: wysyła 8-bajtową ramkę.
--
-- Zachowanie:
--   * Trigger (impuls, tylko w stanie bezczynności) zatrzaskuje resp_cmd,
--     resp_addr i resp_data, po czym nadaje: MAGIC_0, MAGIC_1, resp_cmd,
--     resp_addr, 4 bajty resp_data (big-endian).
--   * resp_cmd to pełny bajt odpowiedzi (np. RESPONSE_WRITE, RESPONSE_ERROR),
--     a nie komenda zapytania. Dobiera go ctrl_protocol.
--   * Zgodność z tx_ready: bajt przechodzi, gdy tx_valid i tx_ready są '1'.
--     Brak tx_ready tylko wstrzymuje nadawanie, nie gubi bajtów.
--   * done wystawia impuls 1 takt po wysłaniu ostatniego bajtu. Ten impuls
--     idzie do resp_done w frame_rx.
--   * trigger podany w trakcie nadawania jest ignorowany.
-- =============================================================================

entity frame_tx is
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;

        -- żądanie nadania odpowiedzi
        trigger     : in  std_logic;                -- impuls: rozpocznij nadawanie
        resp_cmd  : in  byte_t;                     -- pełny bajt odpowiedzi
        resp_addr : in  byte_t;
        resp_data : in  word_t;

        -- status
        busy      : out std_logic;
        done      : out std_logic;                  -- impuls: wysłano ostatni bajt

        -- strumień do fc1002_mii_tcp_link
        tx_data   : out byte_t;
        tx_valid  : out std_logic;
        tx_ready  : in  std_logic
    );
end entity frame_tx;

architecture rtl of frame_tx is

    type state_t is (S_IDLE, S_SEND);

    signal state    : state_t := S_IDLE;
    signal buf      : std_logic_vector(63 downto 0) := (others => '0');  -- ramka, bajt do wysłania na górze (big-endian)
    signal byte_cnt : unsigned(2 downto 0) := (others => '0');
    signal done_r   : std_logic := '0';

begin

    busy     <= '1' when state = S_SEND else '0';
    tx_valid <= '1' when state = S_SEND else '0';
    tx_data  <= buf(63 downto 56);
    done     <= done_r;

    p_fsm : process (clk)
    begin
        if rising_edge(clk) then
            done_r <= '0';

            if rst = '1' then
                state    <= S_IDLE;
                byte_cnt <= (others => '0');

            else
                case state is

                    when S_IDLE =>
                        if trigger = '1' then
                            buf      <= MAGIC_0 & MAGIC_1 & resp_cmd & resp_addr & resp_data;
                            byte_cnt <= (others => '0');
                            state    <= S_SEND;
                        end if;

                    when S_SEND =>
                        if tx_ready = '1' then
                            -- przesunięcie o bajt
                            buf <= buf(55 downto 0) & x"00";
                            if byte_cnt = 7 then
                                done_r <= '1';
                                state  <= S_IDLE;
                            else
                                byte_cnt <= byte_cnt + 1;
                            end if;
                        end if;

                end case;
            end if;
        end if;
    end process p_fsm;

end architecture rtl;
