--------------------------------------------------------------------------------
-- clk_rst
--
-- Clock generation and reset of the clk_sys domain (ADR 0004, ADR 0007):
--
--   CLK_25M --> rPLL --> clk_fast (2 x line rate, FCLK of IDES8/OSER8)
--                          |
--                          +--> CLKDIV /4 --> clk_sys (PCLK, logic clock)
--
-- CLKDIV (instead of a second PLL output) keeps clk_sys phase-locked to
-- clk_fast, as required by the IDES8/OSER8 gearboxes. CLKDIV is held in
-- reset until the PLL locks.
--
-- Reset request (arst_n, active low, asynchronous):
--   arst_n = pll_lock and (host reset not active) and not soft_rst
--   * HOST_RST_N (pin, pull-up) is synchronized and filtered in the clk_sys
--     domain: it changes state only after HOST_FILT consecutive equal
--     samples (32 -> 640 ns), so glitches do not reset the bridge. Before
--     the PLL locks the filter does not run, but the reset is then held by
--     the lock condition anyway. CLK_25M drives only the PLL (pin 35 is the
--     dedicated PLL input, not a global clock pin).
--   * soft_rst (CTRL.SOFT_RST) must come directly from a flip-flop of the
--     clk_sys domain that is cleared by rst_sys: the reset clears the bit,
--     which releases the request (self-terminating soft reset).
--   rst_hard is the same reset without soft_rst (for registers kept over a
--   soft reset: MODE_CTRL, ADR 0009).
--   rst_sys (clk_sys domain, active high) is asserted immediately and
--   released synchronously after STAGES clk_sys edges (reset_sync). Other
--   clock domains (clk_spi) use arst_n with their own reset_sync.
--
-- PLL parameters: bridge_pkg (PLL_*), derived from LINE_BAUD.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library gw1n;
use gw1n.components.all;

library work;
use work.bridge_pkg.all;

entity clk_rst is
  generic (
    HOST_FILT : positive := 32;  -- HOST_RST_N filter length in clk_sys cycles
    STAGES    : positive := 3    -- reset release delay in clk_sys cycles
  );
  port (
    clk_25m    : in  std_logic;  -- reference oscillator (pin 35, RPLL_T_in)
    host_rst_n : in  std_logic;  -- pin HOST_RST_N
    soft_rst   : in  std_logic;  -- CTRL.SOFT_RST (clk_sys flip-flop)
    clk_fast   : out std_logic;
    clk_sys    : out std_logic;
    rst_sys    : out std_logic;  -- clk_sys domain reset, active high
    rst_hard   : out std_logic;  -- clk_sys reset without SOFT_RST (MODE_CTRL, ADR 0009)
    arst_n     : out std_logic;  -- asynchronous reset request for other domains
    pll_lock   : out std_logic   -- PLL lock (not synchronized)
  );
end entity clk_rst;

architecture rtl of clk_rst is

  signal clk_fast_i : std_logic;
  signal clk_sys_i  : std_logic;
  signal lock       : std_logic;

  -- HOST_RST_N synchronizer and filter (clk_sys domain, no reset: initial values)
  signal host_s     : std_logic;
  signal host_flt   : std_logic := '1';                         -- filtered, active low
  signal flt_cnt    : natural range 0 to HOST_FILT - 1 := 0;

  signal arst_n_i   : std_logic;
  signal arst_h_n   : std_logic;

begin

  u_pll : rPLL
    generic map (
      FCLKIN    => PLL_FCLKIN,
      DEVICE    => "GW1N-9C",
      IDIV_SEL  => PLL_IDIV_SEL,
      FBDIV_SEL => PLL_FBDIV_SEL,
      ODIV_SEL  => PLL_ODIV_SEL)
    port map (
      CLKIN => clk_25m, CLKFB => '0', RESET => '0', RESET_P => '0',
      IDSEL => "000000", FBDSEL => "000000", ODSEL => "000000",
      PSDA => "0000", FDLY => "0000", DUTYDA => "0000",
      LOCK => lock, CLKOUT => clk_fast_i, CLKOUTD => open, CLKOUTP => open, CLKOUTD3 => open);

  u_div : CLKDIV
    generic map (DIV_MODE => "4", GSREN => "false")
    port map (HCLKIN => clk_fast_i, RESETN => lock, CALIB => '0', CLKOUT => clk_sys_i);

  ------------------------------------------------------------------------------
  -- HOST_RST_N: synchronizer + filter
  ------------------------------------------------------------------------------
  u_host_sync : entity work.sync_bit
    generic map (STAGES => 2, INIT_VAL => '1')
    port map (clk => clk_sys_i, d => host_rst_n, q => host_s);

  process (clk_sys_i)
  begin
    if rising_edge(clk_sys_i) then
      if host_s = host_flt then
        flt_cnt <= 0;
      elsif flt_cnt = HOST_FILT - 1 then
        host_flt <= host_s;
        flt_cnt  <= 0;
      else
        flt_cnt <= flt_cnt + 1;
      end if;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- Reset request and clk_sys domain reset
  ------------------------------------------------------------------------------
  arst_n_i <= lock and host_flt and not soft_rst;

  u_rst_sys : entity work.reset_sync
    generic map (STAGES => STAGES)
    port map (clk => clk_sys_i, arst_n => arst_n_i, rst => rst_sys);

  -- hard reset: PLL lock and HOST_RST_N only (keeps MODE_CTRL over a soft reset)
  arst_h_n <= lock and host_flt;

  u_rst_hard : entity work.reset_sync
    generic map (STAGES => STAGES)
    port map (clk => clk_sys_i, arst_n => arst_h_n, rst => rst_hard);

  clk_fast <= clk_fast_i;
  clk_sys  <= clk_sys_i;
  arst_n   <= arst_n_i;
  pll_lock <= lock;

end architecture rtl;
