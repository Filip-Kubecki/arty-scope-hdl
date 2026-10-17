library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- =============================================================================
-- sample_mem.vhd
-- Pamięć rekordu: 2**G_ADDR_BITS słów po 16 bitów (słowo = ch2 & ch1).
-- Zapis i odczyt synchroniczne. Odczyt daje dane po jednym takcie.
-- =============================================================================

entity sample_mem is
    generic (
        G_ADDR_BITS : natural := 16
    );
    port (
        clk   : in  std_logic;
        we    : in  std_logic;
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
            if we = '1' then
                mem(to_integer(waddr)) <= wdata;
            end if;
            rdata <= mem(to_integer(raddr));
        end if;
    end process p_mem;

end architecture rtl;
