library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.regmap_pkg.all;

-- =============================================================================
-- acquisition_ctrl.vhd
-- Sterowanie akwizycją rekordu: tryb pojedynczy, wyzwolenie ręczne.
--
-- Stany (wartość zwracana przez ADDR_ACQUISITION_STATE):
--   0x00  IDLE     przetwornik wyłączony, czeka na ARM
--   0x01  ARMED    przetwornik włączony, czeka na FORCE_TRIGGER
--   0x02  CAPTURE  zapis próbek do pamięci
--   0x03  READY    rekord gotowy, przetwornik wyłączony
--
-- Przejścia:
--   ARM            z IDLE lub READY do ARMED, adres zapisu zerowany
--   FORCE_TRIGGER  z ARMED do CAPTURE
--   STOP           z dowolnego stanu do IDLE
--   ostatnia próbka w CAPTURE: do READY, RECORD_ID zwiększony
--
-- Zapis do pamięci tylko w CAPTURE i tylko przy sample_valid.
-- Słowo pamięci = ch2 & ch1.
-- =============================================================================

entity acquisition_ctrl is
    generic (
        G_DEPTH : natural := 8192            -- liczba próbek w rekordzie
    );
    port (
        clk          : in  std_logic;
        rst          : in  std_logic;

        -- komendy z ctrl_protocol
        cmd_valid    : in  std_logic;
        cmd_addr     : in  byte_t;

        -- próbki z przetwornika
        sample_valid : in  std_logic;
        ch1          : in  byte_t;
        ch2          : in  byte_t;

        -- sterowanie przetwornikiem i pamięcią
        enable       : out std_logic;
        mem_we       : out std_logic;
        mem_addr     : out unsigned(12 downto 0);
        mem_data     : out std_logic_vector(15 downto 0);

        -- status dla rejestrów
        state        : out byte_t;
        record_id    : out word_t
    );
end entity acquisition_ctrl;

architecture rtl of acquisition_ctrl is

    constant ST_IDLE    : byte_t := x"00";
    constant ST_ARMED   : byte_t := x"01";
    constant ST_CAPTURE : byte_t := x"02";
    constant ST_READY   : byte_t := x"03";

    constant LAST_ADDR  : unsigned(12 downto 0) := to_unsigned(G_DEPTH - 1, 13);

    signal st        : byte_t := ST_IDLE;
    signal wr_addr_r : unsigned(12 downto 0) := (others => '0');
    signal rec_id_r  : unsigned(31 downto 0) := (others => '0');

begin

    state     <= st;
    record_id <= std_logic_vector(rec_id_r);
    mem_addr  <= wr_addr_r;
    mem_data  <= ch2 & ch1;

    enable <= '1' when (st = ST_ARMED) or (st = ST_CAPTURE) else '0';
    mem_we <= '1' when (st = ST_CAPTURE) and (sample_valid = '1') else '0';

    p_fsm : process (clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                st        <= ST_IDLE;
                wr_addr_r <= (others => '0');
                rec_id_r  <= (others => '0');

            else
                -- komendy
                if cmd_valid = '1' then
                    if cmd_addr = ADDR_COMMAND_ARM then
                        if st = ST_IDLE or st = ST_READY then
                            st        <= ST_ARMED;
                            wr_addr_r <= (others => '0');
                        end if;

                    elsif cmd_addr = ADDR_COMMAND_FORCE_TRIGGER then
                        if st = ST_ARMED then
                            st <= ST_CAPTURE;
                        end if;

                    elsif cmd_addr = ADDR_COMMAND_STOP then
                        st <= ST_IDLE;
                    end if;
                end if;

                -- zapis próbek; ostatnia próbka kończy rekord
                if st = ST_CAPTURE and sample_valid = '1' then
                    wr_addr_r <= wr_addr_r + 1;
                    if wr_addr_r = LAST_ADDR then
                        st       <= ST_READY;
                        rec_id_r <= rec_id_r + 1;
                    end if;
                end if;
            end if;
        end if;
    end process p_fsm;

end architecture rtl;
