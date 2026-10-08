--------------------------------------------------------------------------------
-- tx_gearbox
--
-- Transmit gearbox 10 -> 2 bits (ADR 0007): one 8b/10b symbol every 5
-- clk_sys cycles, 2 bits per cycle to tx_phy (OSER8, each bit repeated 4x).
--
-- Timing (ph = 0..4, cyclic):
--   ph = 0 : char_en = '1' -> tx_framer prepares the next character and
--            enc_8b10b takes the current one (code valid from ph = 1)
--   ph = 4 : the symbol is latched (code_lat <= code)
--   ph = n : bits <= code_lat(2n+1 downto 2n), i.e. code(0) (bit a) first
--
-- Latency from char_en to the first bit of that symbol on bits: 6 clocks.
-- After reset code_lat holds K28.5 (RD-), so the line never carries a
-- non-8b/10b pattern.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tx_gearbox is
  port (
    clk     : in  std_logic;
    rst     : in  std_logic;
    char_en : out std_logic;                       -- to tx_framer and enc_8b10b (en)
    code    : in  std_logic_vector(9 downto 0);    -- from enc_8b10b
    bits    : out std_logic_vector(1 downto 0)     -- to tx_phy, bits(0) first
  );
end entity tx_gearbox;

architecture rtl of tx_gearbox is

  constant K28_5_RDN : std_logic_vector(9 downto 0) := "0101111100";  -- code(9..0), a = code(0)

  signal ph       : natural range 0 to 4 := 0;
  signal code_lat : std_logic_vector(9 downto 0) := K28_5_RDN;
  signal bits_q   : std_logic_vector(1 downto 0) := (others => '0');

begin

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        ph       <= 0;
        code_lat <= K28_5_RDN;
        bits_q   <= (others => '0');
      else
        if ph = 4 then
          ph       <= 0;
          code_lat <= code;
        else
          ph <= ph + 1;
        end if;
        bits_q <= code_lat(2 * ph + 1 downto 2 * ph);
      end if;
    end if;
  end process;

  char_en <= '1' when ph = 0 and rst = '0' else '0';
  bits    <= bits_q;

end architecture rtl;
