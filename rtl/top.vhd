library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity top is
    port (
        CLK100MHZ : in  std_logic;
        led    : out std_logic_vector(3 downto 0)
    );
end entity top;

architecture rtl of top is
    signal counter : unsigned(26 downto 0) := (others => '0');
begin

    process (CLK100MHZ)
    begin
        if rising_edge(CLK100MHZ) then
            counter <= counter + 1;
        end if;
    end process;

    led(0) <= counter(26);
    led(3 downto 1) <= (others => '0');

end architecture rtl;
