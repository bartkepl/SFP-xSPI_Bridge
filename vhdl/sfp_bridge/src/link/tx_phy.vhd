--------------------------------------------------------------------------------
-- tx_phy
--
-- Serial transmitter I/O (ADR 0007): OSER8 (FCLK = clk_fast = 200 MHz, DDR
-- -> 400 Msps; PCLK = clk_sys = clk_fast / 4 from CLKDIV) and TLVDS_OBUF to
-- the SFP TD+/TD- pair. Each of the 2 bits per clk_sys cycle is repeated on
-- 4 consecutive OSER8 inputs: 100 Mbaud line rate.
--
-- OSER8 sends D0 first (UG289; Gowin simulation model prim_sim.vhd), so
-- D0..D3 = bits(0), D4..D7 = bits(1).
--
-- INVERT swaps the polarity (TD+/TD- swapped on the board).
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

library gw1n;
use gw1n.components.all;

entity tx_phy is
  generic (
    INVERT : boolean := false
  );
  port (
    clk_fast : in  std_logic;                     -- FCLK (HCLK network)
    clk_sys  : in  std_logic;                     -- PCLK = clk_fast / 4
    rst      : in  std_logic;                     -- synchronous to clk_sys
    bits     : in  std_logic_vector(1 downto 0);  -- bits(0) sent first
    td_p     : out std_logic;
    td_n     : out std_logic
  );
end entity tx_phy;

architecture rtl of tx_phy is

  signal b0, b1 : std_logic;
  signal ser    : std_logic;

begin

  b0 <= not bits(0) when INVERT else bits(0);
  b1 <= not bits(1) when INVERT else bits(1);

  u_ser : OSER8
    generic map (GSREN => "false", LSREN => "true", HWL => "false", TXCLK_POL => '0')
    port map (D0 => b0, D1 => b0, D2 => b0, D3 => b0,
              D4 => b1, D5 => b1, D6 => b1, D7 => b1,
              TX0 => '0', TX1 => '0', TX2 => '0', TX3 => '0',
              PCLK => clk_sys, FCLK => clk_fast, RESET => rst,
              Q0 => ser, Q1 => open);

  u_obuf : TLVDS_OBUF
    port map (I => ser, O => td_p, OB => td_n);

end architecture rtl;
