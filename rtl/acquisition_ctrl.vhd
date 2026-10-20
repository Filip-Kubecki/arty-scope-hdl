library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.regmap_pkg.all;

-- =============================================================================
-- acquisition_ctrl.vhd
-- Akwizycja z buforem cyklicznym i wyzwalaniem.
--
-- Stany (wartość zwracana przez ADDR_ACQUISITION_STATE):
--   0x00  IDLE     przetwornik wyłączony, czeka na ARM
--   0x01  ARMED    przetwornik włączony, próbki zapisywane w buforze cyklicznym,
--                  czeka na wyzwolenie
--   0x02  CAPTURE  po wyzwoleniu: zapis post-trigger do końca rekordu
--   0x03  READY    rekord gotowy, przetwornik wyłączony
--
-- Bufor cykliczny liczony w slotach (próbkach kanału): wr_addr_r zawija się
-- od N-1 do 0, N = record_length (do 131072 przy jednym kanale, 65536 przy dwóch).
-- record_base, trigger_pointer i write_pointer są w slotach (17 bitów).
--
-- Układ pamięci:
--   dwa kanały (channel_mask 11): słowo = ch2 & ch1, jeden slot = jedno słowo,
--     mem_addr = slot.
--   jeden kanał (01 albo 10): dwa sloty w jednym słowie, mem_addr = slot / 2.
--     Parzysty slot zapisuje młodszy bajt, nieparzysty starszy. Każdy zapis
--     dotyka jednego bajtu, więc druga próbka słowa nie jest nadpisywana.
--     Połówkę odczytu wyznacza bit 0 slotu (liczy ctrl_protocol).
--     Kanał wyłączony nie zajmuje pamięci.
--
-- Wyzwolenie: FORCE_TRIGGER, albo poziom (Schmitt) z trigger_source.
--   Krawędź narastająca (0x00): uzbrojenie, gdy próbka < level - hysteresis,
--     wyzwolenie, gdy próbka >= level.
--   Krawędź opadająca (0x01): uzbrojenie, gdy próbka > level + hysteresis,
--     wyzwolenie, gdy próbka <= level.
--   Obie (0x02): oba warunki.
--   Uzbrojenie jest czyszczone przez próbkę po drugiej stronie poziomu,
--   także przed zakończeniem pre.
--   Wyzwolenie możliwe dopiero po zebraniu pre_length próbek od ARM.
--
-- Konfiguracja (record_length, pre_length, trigger_*, channel_mask) zmienia się
-- tylko przez COMMIT w IDLE, więc w czasie akwizycji jest stała.
-- =============================================================================

entity acquisition_ctrl is
    port (
        clk                : in  std_logic;
        rst                : in  std_logic;

        -- komendy z ctrl_protocol
        cmd_valid          : in  std_logic;
        cmd_addr           : in  byte_t;

        -- próbki z przetwornika
        sample_valid       : in  std_logic;
        ch1                : in  byte_t;
        ch2                : in  byte_t;

        -- konfiguracja aktywna
        record_length      : in  word_t;   -- N, próbek na kanał
        pre_length         : in  word_t;   -- próbki przed wyzwoleniem
        channel_mask       : in  byte_t;   -- 01 ch1, 10 ch2, 11 oba
        trigger_source     : in  byte_t;   -- 0x00 ch1, 0x01 ch2
        trigger_edge       : in  byte_t;   -- 0x00 narastająca, 0x01 opadająca, 0x02 obie
        trigger_level      : in  byte_t;   -- poziom w kodach ADC
        trigger_hysteresis : in  byte_t;   -- pasmo histerezy w kodach ADC

        -- sterowanie przetwornikiem i pamięcią
        enable             : out std_logic;
        mem_we_lo          : out std_logic;
        mem_we_hi          : out std_logic;
        mem_addr           : out unsigned(15 downto 0);   -- adres słowa
        mem_data           : out std_logic_vector(15 downto 0);

        -- status dla rejestrów i odczytu (w slotach)
        record_base        : out unsigned(16 downto 0);
        trigger_pointer    : out unsigned(16 downto 0);
        write_pointer      : out unsigned(16 downto 0);
        state              : out byte_t;
        record_id          : out word_t
    );
end entity acquisition_ctrl;

architecture rtl of acquisition_ctrl is

    constant ST_IDLE    : byte_t := x"00";
    constant ST_ARMED   : byte_t := x"01";
    constant ST_CAPTURE : byte_t := x"02";
    constant ST_READY   : byte_t := x"03";

    constant EDGE_RISING  : byte_t := x"00";
    constant EDGE_FALLING : byte_t := x"01";
    constant EDGE_BOTH    : byte_t := x"02";

    constant SOURCE_CH1 : byte_t := x"00";

    signal st           : byte_t := ST_IDLE;
    signal wr_addr_r    : unsigned(16 downto 0) := (others => '0');   -- slot zapisu
    signal rec_id_r     : unsigned(31 downto 0) := (others => '0');
    signal filled_r     : unsigned(31 downto 0) := (others => '0');  -- próbki od ARM, do N
    signal post_cnt_r   : unsigned(31 downto 0) := (others => '0');  -- próbki po wyzwoleniu
    signal base_r       : unsigned(16 downto 0) := (others => '0');
    signal trig_addr_r  : unsigned(16 downto 0) := (others => '0');  -- slot próbki wyzwalającej
    signal low_armed_r  : std_logic := '0';   -- uzbrojenie krawędzi narastającej
    signal high_armed_r : std_logic := '0';   -- uzbrojenie krawędzi opadającej
    signal force_r      : std_logic := '0';   -- FORCE_TRIGGER oczekuje na pre

    -- wybrana próbka do porównania z poziomem
    signal trig_sample  : byte_t;
    -- '1' gdy oba kanały są w masce
    signal dual_mode    : std_logic;
    -- próbka zapisywana przy jednym kanale
    signal sel_sample   : byte_t;

begin

    trig_sample <= ch1 when trigger_source = SOURCE_CH1 else ch2;
    dual_mode   <= '1' when channel_mask(1 downto 0) = "11" else '0';
    sel_sample  <= ch2 when channel_mask(1 downto 0) = "10" else ch1;

    state           <= st;
    record_id       <= std_logic_vector(rec_id_r);
    record_base     <= base_r;
    trigger_pointer <= trig_addr_r;
    write_pointer   <= wr_addr_r;

    mem_addr <= wr_addr_r(15 downto 0) when dual_mode = '1' else wr_addr_r(16 downto 1);
    mem_data <= ch2 & ch1 when dual_mode = '1' else sel_sample & sel_sample;

    enable <= '1' when (st = ST_ARMED) or (st = ST_CAPTURE) else '0';

    mem_we_lo <= '1' when ((st = ST_ARMED) or (st = ST_CAPTURE)) and (sample_valid = '1')
                          and (dual_mode = '1' or wr_addr_r(0) = '0') else '0';
    mem_we_hi <= '1' when ((st = ST_ARMED) or (st = ST_CAPTURE)) and (sample_valid = '1')
                          and (dual_mode = '1' or wr_addr_r(0) = '1') else '0';

    p_fsm : process (clk)
        variable v_n      : integer;
        variable v_pre    : integer;
        variable v_post   : integer;
        variable v_sample : integer;
        variable v_level  : integer;
        variable v_hyst   : integer;
        variable v_base   : integer;
        variable v_trig   : boolean;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                st           <= ST_IDLE;
                wr_addr_r    <= (others => '0');
                rec_id_r     <= (others => '0');
                filled_r     <= (others => '0');
                post_cnt_r   <= (others => '0');
                base_r       <= (others => '0');
                trig_addr_r  <= (others => '0');
                low_armed_r  <= '0';
                high_armed_r <= '0';
                force_r      <= '0';

            else
                v_n    := to_integer(unsigned(record_length));
                v_pre  := to_integer(unsigned(pre_length));
                v_post := v_n - v_pre;

                -- komendy
                if cmd_valid = '1' then
                    if cmd_addr = ADDR_COMMAND_ARM then
                        if st = ST_IDLE or st = ST_READY then
                            st           <= ST_ARMED;
                            wr_addr_r    <= (others => '0');
                            filled_r     <= (others => '0');
                            trig_addr_r  <= (others => '0');
                            low_armed_r  <= '0';
                            high_armed_r <= '0';
                            force_r      <= '0';
                        end if;

                    elsif cmd_addr = ADDR_COMMAND_FORCE_TRIGGER then
                        if st = ST_ARMED then
                            force_r <= '1';
                        end if;

                    elsif cmd_addr = ADDR_COMMAND_STOP then
                        st      <= ST_IDLE;
                        force_r <= '0';
                    end if;
                end if;

                -- ARMED: zapis w buforze cyklicznym i sprawdzenie wyzwolenia
                if st = ST_ARMED and sample_valid = '1' then

                    if to_integer(wr_addr_r) = v_n - 1 then
                        wr_addr_r <= (others => '0');
                    else
                        wr_addr_r <= wr_addr_r + 1;
                    end if;

                    if filled_r < to_unsigned(v_n, 32) then
                        filled_r <= filled_r + 1;
                    end if;

                    -- histereza (Schmitt): uzbrojenie krawędzi
                    v_sample := to_integer(unsigned(trig_sample));
                    v_level  := to_integer(unsigned(trigger_level));
                    v_hyst   := to_integer(unsigned(trigger_hysteresis));

                    if v_sample < v_level - v_hyst then
                        low_armed_r <= '1';
                    elsif v_sample >= v_level then
                        low_armed_r <= '0';
                    end if;
                    if v_sample > v_level + v_hyst then
                        high_armed_r <= '1';
                    elsif v_sample <= v_level then
                        high_armed_r <= '0';
                    end if;

                    -- decyzja o wyzwoleniu (po zebraniu pre próbek)
                    v_trig := false;
                    if filled_r >= to_unsigned(v_pre, 32) then
                        if force_r = '1' then
                            v_trig := true;
                        elsif (trigger_edge = EDGE_RISING or trigger_edge = EDGE_BOTH)
                              and low_armed_r = '1' and v_sample >= v_level then
                            v_trig := true;
                        elsif (trigger_edge = EDGE_FALLING or trigger_edge = EDGE_BOTH)
                              and high_armed_r = '1' and v_sample <= v_level then
                            v_trig := true;
                        end if;
                    end if;

                    if v_trig then
                        -- slot próbki wyzwalającej to wr_addr_r (przed inkrementacją)
                        trig_addr_r <= wr_addr_r;

                        v_base := to_integer(wr_addr_r) - v_pre;
                        if v_base < 0 then
                            v_base := v_base + v_n;
                        end if;
                        base_r <= to_unsigned(v_base, 17);

                        if v_post <= 1 then
                            st       <= ST_READY;
                            rec_id_r <= rec_id_r + 1;
                        else
                            st         <= ST_CAPTURE;
                            post_cnt_r <= to_unsigned(1, 32);
                        end if;
                    end if;
                end if;

                -- CAPTURE: zapis post-trigger do końca rekordu
                if st = ST_CAPTURE and sample_valid = '1' then

                    if to_integer(wr_addr_r) = v_n - 1 then
                        wr_addr_r <= (others => '0');
                    else
                        wr_addr_r <= wr_addr_r + 1;
                    end if;

                    post_cnt_r <= post_cnt_r + 1;
                    if post_cnt_r + 1 = to_unsigned(v_post, 32) then
                        st       <= ST_READY;
                        rec_id_r <= rec_id_r + 1;
                    end if;
                end if;

            end if;
        end if;
    end process p_fsm;

end architecture rtl;
