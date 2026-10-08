--------------------------------------------------------------------------------
-- bridge_pkg
--
-- Project-wide constants of the SFP-xSPI Bridge.
-- Device: GW1N-UV9QN48C6/I5 (GW1N-9C).
-- Reference: doc/sfp-xspi-bridge-plan.md (sections 4, 7.2, 7.4).
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

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


  ------------------------------------------------------------------------------
  -- Link control (ADR 0008)
  ------------------------------------------------------------------------------
  -- Link state
  subtype t_link_state is std_logic_vector(1 downto 0);
  constant LS_DOWN : t_link_state := "00";
  constant LS_SYNC : t_link_state := "01";   -- local receiver synchronized, remote not ready
  constant LS_UP   : t_link_state := "10";

  -- CTRL.LOOPBACK
  constant LB_NONE : std_logic_vector(1 downto 0) := "00";
  constant LB_NEAR : std_logic_vector(1 downto 0) := "01";   -- tx_gearbox bits -> cdr_os4x8
  constant LB_FAR  : std_logic_vector(1 downto 0) := "10";   -- frame echo (top-level)

  -- Event counters, CSR 0x10 + 4 * index (32 bit, wrap-around, CTRL.CNT_CLR)
  constant N_CNT           : natural := 8;
  constant CNT_CODE_ERR    : natural := 0;   -- decoder code / disparity errors while in sync
  constant CNT_CRC_ERR     : natural := 1;
  constant CNT_LEN_ERR     : natural := 2;
  constant CNT_FRAMING_ERR : natural := 3;
  constant CNT_RX_OVF      : natural := 4;
  constant CNT_FRAMES_TX   : natural := 5;
  constant CNT_FRAMES_RX   : natural := 6;
  constant CNT_SYNC_LOSS   : natural := 7;
  type t_cnt_arr is array (0 to N_CNT - 1) of unsigned(31 downto 0);

end package bridge_pkg;
