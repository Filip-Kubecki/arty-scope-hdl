library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- sample_mem.vhd
-- Pamięć rekordu: 2**G_ADDR_BITS słów po 16 bitów (domyślnie 2**15 = 32768).
-- Zapis z osobnymi zezwoleniami na bajty:
--   we_lo -> bity 7..0,  we_hi -> bity 15..8.
-- Dwa kanały: słowo = ch2 & ch1, oba zezwolenia razem.
-- Jeden kanał: dwie próbki w słowie, każda zapisuje tylko swój bajt.
-- Zapis i odczyt synchroniczne. Odczyt daje dane po jednym takcie.
--
-- 15 bitów adresu zamiast 16: przy 65536 słowach Vivado kaskadował RAMB36
-- z niespójnym bitem 15 (DRC REQP-1962). Musi zgadzać się z RECORD_MAX_SAMPLES
-- w regmap.yaml.
-- =============================================================================

entity sample_mem is
    generic (
        G_ADDR_BITS : natural := 15
    );
    port (
        clk   : in  std_logic;
        we_lo : in  std_logic;
        we_hi : in  std_logic;
        waddr : in  unsigned(G_ADDR_BITS - 1 downto 0);
        wdata : in  std_logic_vector(15 downto 0);
        raddr : in  unsigned(G_ADDR_BITS - 1 downto 0);
        rdata : out std_logic_vector(15 downto 0)
    );
end entity sample_mem;

architecture rtl of sample_mem is

    type mem_t is array (0 to 2**G_ADDR_BITS - 1) of std_logic_vector(15 downto 0);
    signal mem : mem_t := (others => (others => '0'));

begin

    p_mem : process (clk)
    begin
        if rising_edge(clk) then
            if we_lo = '1' then
                mem(to_integer(waddr))(7 downto 0) <= wdata(7 downto 0);
            end if;
            if we_hi = '1' then
                mem(to_integer(waddr))(15 downto 8) <= wdata(15 downto 8);
            end if;
            rdata <= mem(to_integer(raddr));
        end if;
    end process p_mem;

end architecture rtl;