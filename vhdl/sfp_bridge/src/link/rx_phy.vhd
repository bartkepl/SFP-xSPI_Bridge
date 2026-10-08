--------------------------------------------------------------------------------
-- rx_phy
--
-- Serial receiver I/O (ADR 0007): TLVDS_IBUF from the SFP RD+/RD- pair and
-- IDES8 (FCLK = clk_fast = 200 MHz, DDR -> 400 Msps = 4 samples per bit at
-- 100 Mbaud; PCLK = clk_sys = clk_fast / 4). 8 samples per clk_sys cycle
-- to cdr_os4x8.
--
-- IDES8 delivers the earliest sample on Q0 (UG289; Gowin simulation model
-- prim_sim.vhd), so samples(i) = Qi. CALIB is not used (word alignment is
-- done by cdr_os4x8 / comma_align).
--
-- INVERT swaps the polarity (RD+/RD- swapped on the board).
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

library gw1n;
use gw1n.components.all;

entity rx_phy is
  generic (
    INVERT : boolean := false
  );
  port (
    clk_fast : in  std_logic;                     -- FCLK (HCLK network)
    clk_sys  : in  std_logic;                     -- PCLK = clk_fast / 4
    rst      : in  std_logic;                     -- synchronous to clk_sys
    rd_p     : in  std_logic;
    rd_n     : in  std_logic;
    samples  : out std_logic_vector(7 downto 0)   -- samples(0) earliest
  );
end entity rx_phy;

architecture rtl of rx_phy is

  signal rd : std_logic;
  signal q  : std_logic_vector(7 downto 0);

begin

  u_ibuf : TLVDS_IBUF
    port map (I => rd_p, IB => rd_n, O => rd);

  u_des : IDES8
    generic map (GSREN => "false", LSREN => "true")
    port map (D => rd, RESET => rst, CALIB => '0',
              FCLK => clk_fast, PCLK => clk_sys,
              Q0 => q(0), Q1 => q(1), Q2 => q(2), Q3 => q(3),
              Q4 => q(4), Q5 => q(5), Q6 => q(6), Q7 => q(7));

  samples <= not q when INVERT else q;

end architecture rtl;
