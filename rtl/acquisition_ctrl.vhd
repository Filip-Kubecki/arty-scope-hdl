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
-- Bufor cykliczny: adres zapisu zawija się od record_length-1 do 0.
-- Rekord ma N = record_length próbek: pre_length przed punktem wyzwolenia,
-- próbka wyzwalająca ma indeks pre_length, potem post = N - pre_length próbek.
-- record_base wskazuje adres pamięci próbki o indeksie 0 rekordu.
--
-- trigger_pointer: adres próbki wyzwalającej, zapamiętany w chwili wyzwolenia,
-- zerowany przy ARM. Używany do diagnostyki (ADDR_ACQUISITION_TRIGGER_POINTER).
--
-- Wyzwolenie:
--   FORCE_TRIGGER: zwiększa flagę, wyzwala przy pierwszej próbce po spełnieniu pre.
--   Poziom (Schmitt): trigger_source wybiera ch1 (0x00) albo ch2 (0x01).
--     Krawędź narastająca (0x00): uzbrojenie, gdy próbka < level - hysteresis,
--       wyzwolenie, gdy próbka >= level.
--     Krawędź opadająca (0x01): uzbrojenie, gdy próbka > level + hysteresis,
--       wyzwolenie, gdy próbka <= level.
--     Obie (0x02): oba warunki.
--   Wyzwolenie możliwe dopiero po zebraniu pre_length próbek od ARM.
--
-- Konfiguracja (record_length, pre_length, trigger_*) zmienia się tylko przez
-- COMMIT w IDLE, więc w czasie akwizycji jest stała.
-- Słowo pamięci = ch2 & ch1.
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
        trigger_source     : in  byte_t;   -- 0x00 ch1, 0x01 ch2
        trigger_edge       : in  byte_t;   -- 0x00 narastająca, 0x01 opadająca, 0x02 obie
        trigger_level      : in  byte_t;   -- poziom w kodach ADC
        trigger_hysteresis : in  byte_t;   -- pasmo histerezy w kodach ADC

        -- sterowanie przetwornikiem i pamięcią
        enable             : out std_logic;
        mem_we             : out std_logic;
        mem_addr           : out unsigned(12 downto 0);
        mem_data           : out std_logic_vector(15 downto 0);

        -- status dla rejestrów i odczytu
        record_base        : out unsigned(12 downto 0);
        trigger_pointer    : out unsigned(12 downto 0);
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
    signal wr_addr_r    : unsigned(12 downto 0) := (others => '0');
    signal rec_id_r     : unsigned(31 downto 0) := (others => '0');
    signal filled_r     : unsigned(31 downto 0) := (others => '0');  -- próbki od ARM, do N
    signal post_cnt_r   : unsigned(31 downto 0) := (others => '0');  -- próbki po wyzwoleniu
    signal base_r       : unsigned(12 downto 0) := (others => '0');
    signal trig_addr_r  : unsigned(12 downto 0) := (others => '0');  -- adres próbki wyzwalającej
    signal low_armed_r  : std_logic := '0';   -- uzbrojenie krawędzi narastającej
    signal high_armed_r : std_logic := '0';   -- uzbrojenie krawędzi opadającej
    signal force_r      : std_logic := '0';   -- FORCE_TRIGGER oczekuje na pre

    -- wybrana próbka do porównania z poziomem
    signal trig_sample  : byte_t;

begin

    trig_sample <= ch1 when trigger_source = SOURCE_CH1 else ch2;

    state           <= st;
    record_id       <= std_logic_vector(rec_id_r);
    record_base     <= base_r;
    trigger_pointer <= trig_addr_r;
    mem_addr        <= wr_addr_r;
    mem_data        <= ch2 & ch1;

    enable <= '1' when (st = ST_ARMED) or (st = ST_CAPTURE) else '0';
    mem_we <= '1' when ((st = ST_ARMED) or (st = ST_CAPTURE)) and (sample_valid = '1') else '0';

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
                        -- adres próbki wyzwalającej to wr_addr_r (przed inkrementacją)
                        trig_addr_r <= wr_addr_r;

                        v_base := to_integer(wr_addr_r) - v_pre;
                        if v_base < 0 then
                            v_base := v_base + v_n;
                        end if;
                        base_r <= to_unsigned(v_base, 13);

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
