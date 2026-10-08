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

  -- rPLL (clk_rst): clk_fast = CLK_REF_HZ * (FBDIV_SEL + 1) / (IDIV_SEL + 1),
  -- VCO = clk_fast * ODIV_SEL must lie in 400..1200 MHz (GW1N-9 C6/I5, DS100).
  --   100 Mbaud: 25 * 8 = 200 MHz, VCO 800 MHz;  125 Mbaud: 25 * 10 = 250 MHz, VCO 1000 MHz
  constant PLL_FCLKIN    : string  := "25";
  constant PLL_IDIV_SEL  : natural := 0;
  constant PLL_FBDIV_SEL : natural := CLK_FAST_HZ / CLK_REF_HZ - 1;
  constant PLL_ODIV_SEL  : natural := 4;

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
  -- Frame types (ADR 0005, ADR 0006)
  ------------------------------------------------------------------------------
  constant TYPE_DATA : std_logic_vector(7 downto 0) := x"00";
  constant TYPE_UART : std_logic_vector(7 downto 0) := x"01";   -- transparent UART stream

  ------------------------------------------------------------------------------
  -- Transparent UART (ADR 0006): UART_DIV = clk_sys cycles per bit
  ------------------------------------------------------------------------------
  constant UART_BAUD_DEFAULT : natural := 115_200;
  constant UART_DIV_DEFAULT  : natural := (CLK_SYS_HZ + UART_BAUD_DEFAULT / 2) / UART_BAUD_DEFAULT;  -- 434
  constant UART_DIV_MIN      : natural := 8;

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

  ------------------------------------------------------------------------------
  -- SFP management (sfp_mgmt): CSR 0x30-0x4F, I2C_BUF 0x80-0xFF
  ------------------------------------------------------------------------------
  type t_byte_arr is array (natural range <>) of std_logic_vector(7 downto 0);
  constant MG_BASE      : natural := 16#30#;
  constant MG_SIZE      : natural := 32;
  subtype t_mg_regs is t_byte_arr(0 to MG_SIZE - 1);
  constant I2C_BUF_BASE : natural := 16#80#;
  constant I2C_BUF_SIZE : natural := 128;

  constant I2C_CMD_READ  : std_logic_vector(7 downto 0) := x"01";
  constant I2C_CMD_WRITE : std_logic_vector(7 downto 0) := x"02";
  constant I2C_DEV_DEFAULT : std_logic_vector(6 downto 0) := "1010000";  -- 0x50 (A0h)

  -- DDM polling (SFF-8472, A2h): bytes 96..110 read in one transaction;
  -- 96..105 (temperature, Vcc, TX bias, TX power, RX power) and 110 kept
  constant DDM_DEV            : std_logic_vector(6 downto 0) := "1010001";  -- 0x51 (A2h)
  constant DDM_OFFSET         : natural := 96;
  constant DDM_LEN            : natural := 15;
  constant DDM_PERIOD_DEFAULT : natural := 10;                     -- x 100 ms

end package bridge_pkg;
