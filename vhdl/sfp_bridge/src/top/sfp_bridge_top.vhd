-- SFP-xSPI Bridge - top level
-- Device: GW1N-UV9QN48C6/I5 (GW1N-9C), pin assignment: vhdl/constraints/sfp_bridge.cst
-- Module structure: doc/sfp-xspi-bridge-plan.md, section 7.
--
-- Skeleton: no functional blocks yet. All outputs are held in a safe state:
--   * SFP laser disabled (TX_DISABLE high), TD pair driven to a constant level
--   * xSPI data, DQS and SFP I2C released (high impedance)
--   * HOST_IRQ_N inactive (high), LEDs off

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library gw1n;
use gw1n.components.all;

library work;
use work.bridge_pkg.all;

entity sfp_bridge_top is
  port (
    -- Clock
    clk_25m      : in    std_logic;

    -- SFP high-speed pairs
    sfp_td_p     : out   std_logic;
    sfp_td_n     : out   std_logic;
    sfp_rd_p     : in    std_logic;
    sfp_rd_n     : in    std_logic;

    -- SFP management
    sfp_tx_dis   : out   std_logic;
    sfp_tx_fault : in    std_logic;
    sfp_los      : in    std_logic;
    sfp_mod_abs  : in    std_logic;
    sfp_scl      : inout std_logic;
    sfp_sda      : inout std_logic;

    -- Host xSPI
    xspi_sclk    : in    std_logic;
    xspi_cs_n    : in    std_logic;
    xspi_io      : inout std_logic_vector(7 downto 0);
    xspi_dqs     : out   std_logic;
    host_irq_n   : out   std_logic;
    host_rst_n   : in    std_logic;

    -- LEDs, active low (3V3 -> 1k -> LED -> pin)
    led_link     : out   std_logic;
    led_act      : out   std_logic
  );
end entity sfp_bridge_top;

architecture rtl of sfp_bridge_top is

  signal rd_se : std_logic;

begin

  -- SFP: laser off, TD pair at a constant level, RD received but unused
  sfp_tx_dis <= '1';

  u_td_buf : TLVDS_OBUF
    port map (I => '0', O => sfp_td_p, OB => sfp_td_n);

  u_rd_buf : TLVDS_IBUF
    port map (I => sfp_rd_p, IB => sfp_rd_n, O => rd_se);

  -- SFP I2C released
  sfp_scl <= 'Z';
  sfp_sda <= 'Z';

  -- Host interface idle
  xspi_io    <= (others => 'Z');
  xspi_dqs   <= 'Z';
  host_irq_n <= '1';

  -- LEDs off
  led_link <= '1';
  led_act  <= '1';

end architecture rtl;
