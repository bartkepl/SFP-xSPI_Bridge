-- SFP-xSPI Bridge - common constants
-- Device: GW1N-UV9QN48C6/I5 (GW1N-9C)

library ieee;
use ieee.std_logic_1164.all;

package bridge_pkg is

  -- Reference oscillator Y1 on pin 35 (RPLL_T_in)
  constant CLK_REF_HZ : natural := 25_000_000;

  -- Bitstream identification (CSR 0x00 / 0x01, doc/sfp-xspi-bridge-plan.md 7.4)
  constant BRIDGE_ID      : std_logic_vector(15 downto 0) := x"5F5B";
  constant BRIDGE_VERSION : std_logic_vector(7 downto 0)  := x"01";

end package bridge_pkg;
