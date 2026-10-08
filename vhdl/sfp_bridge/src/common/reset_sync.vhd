--------------------------------------------------------------------------------
-- reset_sync
--
-- Reset bridge for one clock domain: asynchronous assertion, synchronous
-- deassertion (ADR 0004).
--
-- Assumptions:
--   * arst_n is an asynchronous, active-low reset request (PLL lock, external
--     reset pin, soft reset). It may change at any time.
--   * The clock may be absent while arst_n is low (e.g. PLL not locked); rst
--     is asserted immediately without a clock edge.
--   * After arst_n goes high, rst stays high for STAGES rising edges of clk and
--     is released synchronously, so all flip-flops of the domain leave reset
--     on the same edge.
--
-- Output rst is active-high and is used as a synchronous reset inside the
-- domain.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity reset_sync is
  generic (
    STAGES : positive := 3        -- release delay in clk cycles, >= 2
  );
  port (
    clk    : in  std_logic;
    arst_n : in  std_logic;       -- asynchronous reset request, active low
    rst    : out std_logic        -- domain reset, active high
  );
end entity reset_sync;

architecture rtl of reset_sync is

  signal chain : std_logic_vector(STAGES - 1 downto 0) := (others => '1');

  attribute syn_preserve : boolean;
  attribute syn_preserve of chain : signal is true;

begin

  assert STAGES >= 2
    report "reset_sync: STAGES must be at least 2"
    severity failure;

  process (clk, arst_n)
  begin
    if arst_n = '0' then
      chain <= (others => '1');
    elsif rising_edge(clk) then
      chain <= chain(STAGES - 2 downto 0) & '0';
    end if;
  end process;

  rst <= chain(STAGES - 1);

end architecture rtl;
