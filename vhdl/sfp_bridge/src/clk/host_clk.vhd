--------------------------------------------------------------------------------
-- host_clk
--
-- Clock of the host side of the link FIFOs (ADR 0009): the DCS primitive
-- selects
--   * clk_sys while the bridge is in reset and in the UART and frame echo
--     modes (host side served by uart_bridge / frame_echo),
--   * SCLK of the xSPI host in the xSPI mode, SWITCH_DELAY clk_sys cycles
--     after the reset is released.
-- The host side therefore always receives clock edges during reset (its
-- reset is synchronous) and the xSPI slave runs on SCLK afterwards.
--
-- Switching: DCS with SELFORCE = '1' (plain multiplexer, no wait for the
-- edges of the new clock, which SCLK does not provide between transactions).
-- The select register changes on the falling edge of clk_sys: at that
-- moment clk_sys is low, and SCLK idles low (mode 0, CS high after reset),
-- so the output does not glitch. Entering a reset switches back to clk_sys
-- at the next falling edge of clk_sys; a partial pulse at that moment falls
-- into the reset of the host side.
--
-- rst_host = rst_sys: synchronous to clk_sys, which clocks the host side
-- during the whole reset.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

library gw1n;
use gw1n.components.all;

entity host_clk is
  generic (
    SWITCH_DELAY : positive := 8                -- clk_sys cycles after reset before SCLK
  );
  port (
    clk_sys   : in  std_logic;
    sclk      : in  std_logic;                  -- pin XSPI_SCLK (global clock input)
    rst_sys   : in  std_logic;
    xspi_mode : in  std_logic;                  -- '1': host side served by xspi_slave
    clk_host  : out std_logic;
    rst_host  : out std_logic;
    on_sclk   : out std_logic                   -- '1': clk_host = SCLK
  );
end entity host_clk;

architecture rtl of host_clk is

  signal sel    : std_logic := '0';
  signal cnt    : natural range 0 to SWITCH_DELAY := 0;
  signal clksel : std_logic_vector(3 downto 0);

begin

  process (clk_sys)
  begin
    if falling_edge(clk_sys) then
      if rst_sys = '1' or xspi_mode = '0' then
        sel <= '0';
        cnt <= 0;
      elsif cnt < SWITCH_DELAY then
        cnt <= cnt + 1;
      else
        sel <= '1';
      end if;
    end if;
  end process;

  clksel <= "0010" when sel = '1' else "0001";

  u_dcs : DCS
    generic map (DCS_MODE => "RISING")
    port map (CLK0 => clk_sys, CLK1 => sclk, CLK2 => '0', CLK3 => '0',
              CLKSEL => clksel, SELFORCE => '1', CLKOUT => clk_host);

  rst_host <= rst_sys;
  on_sclk  <= sel;

end architecture rtl;
