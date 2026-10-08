--------------------------------------------------------------------------------
-- bridge_pkg
--
-- Project-wide constants of the SFP-xSPI Bridge.
-- Device: GW1N-UV9QN48C6/I5 (GW1N-9C).
-- Reference: doc/sfp-xspi-bridge-plan.md (sections 4, 7.2, 7.4).
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

package bridge_pkg is

  ------------------------------------------------------------------------------
  -- Clocks
  ------------------------------------------------------------------------------
  -- Reference oscillator Y1 on pin 35 (RPLL_T_in)
  constant CLK_REF_HZ  : natural := 25_000_000;
  -- Line rate (baud) and derived clocks (ADR 0007):
  --   clk_fast = 2 x line rate (FCLK of IDES8/OSER8, DDR -> 4 samples per bit)
  --   clk_sys  = clk_fast / 4  (PCLK; 8 samples = 2 bits per cycle)
  constant LINE_BAUD     : natural := 100_000_000;
  constant CLK_FAST_HZ   : natural := 2 * LINE_BAUD;
  constant CLK_SYS_HZ    : natural := CLK_FAST_HZ / 4;
  constant BITS_PER_CLK  : natural := 2;                  -- nominal, at clk_sys
  constant CLKS_PER_CHAR : natural := 10 / BITS_PER_CLK;  -- 5 clk_sys cycles per symbol

  ------------------------------------------------------------------------------
  -- Identification (CSR 0x00 / 0x01)
  ------------------------------------------------------------------------------
  constant BRIDGE_ID      : std_logic_vector(15 downto 0) := x"5F5B";
  constant BRIDGE_VERSION : std_logic_vector(7 downto 0)  := x"01";

  ------------------------------------------------------------------------------
  -- 8b/10b control characters (byte value, used with k = '1')
  ------------------------------------------------------------------------------
  constant K28_5 : std_logic_vector(7 downto 0) := x"BC";  -- comma, idle
  constant K27_7 : std_logic_vector(7 downto 0) := x"FB";  -- start of frame
  constant K29_7 : std_logic_vector(7 downto 0) := x"FD";  -- end of frame
  constant K30_7 : std_logic_vector(7 downto 0) := x"FE";  -- error propagation
  -- Second character of an idle pair K28.5 Dx.y (ADR 0005, ADR 0008):
  --   /I/ K28.5 D16.2  receiver ready, XON
  --   /P/ K28.5 D21.5  receiver ready, XOFF (pause)
  --   /R/ K28.5 D5.6   receiver not synchronized (not ready)
  constant D16_2 : std_logic_vector(7 downto 0) := x"50";
  constant D21_5 : std_logic_vector(7 downto 0) := x"B5";
  constant D5_6  : std_logic_vector(7 downto 0) := x"C5";

end package bridge_pkg;
