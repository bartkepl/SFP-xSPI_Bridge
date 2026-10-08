--------------------------------------------------------------------------------
-- sync_bit
--
-- Multi-flop synchronizer for a single, slowly changing level signal crossing
-- into the clk domain (status bits, enables, pins such as LOS or MOD_ABS).
--
-- Assumptions:
--   * d is a level, stable for at least STAGES + 1 cycles of clk; pulses
--     shorter than one clk period may be lost. Use a handshake or an
--     asynchronous FIFO for multi-bit values and pulses.
--   * The first stage may go metastable; STAGES >= 2 gives it one full clock
--     period to resolve before q is used.
--
-- Latency: STAGES clock cycles from a stable change of d to q.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity sync_bit is
  generic (
    STAGES   : positive  := 2;    -- number of flip-flops, >= 2
    INIT_VAL : std_logic := '0'   -- power-up value of the chain
  );
  port (
    clk : in  std_logic;
    d   : in  std_logic;          -- asynchronous input
    q   : out std_logic           -- synchronized output
  );
end entity sync_bit;

architecture rtl of sync_bit is

  signal chain : std_logic_vector(STAGES - 1 downto 0) := (others => INIT_VAL);

  -- Keep the chain as discrete flip-flops (no merging or retiming)
  attribute syn_preserve : boolean;
  attribute syn_preserve of chain : signal is true;

begin

  assert STAGES >= 2
    report "sync_bit: STAGES must be at least 2"
    severity failure;

  process (clk)
  begin
    if rising_edge(clk) then
      chain <= chain(STAGES - 2 downto 0) & d;
    end if;
  end process;

  q <= chain(STAGES - 1);

end architecture rtl;
