--------------------------------------------------------------------------------
-- sfp_bridge_top
--
-- SFP-xSPI Bridge, GW1N-UV9QN48C6/I5 (GW1N-9C). Pins: vhdl/constraints/
-- sfp_bridge.cst; structure: doc/sfp-xspi-bridge-plan.md, section 7;
-- integration: doc/vhdl/top.md.
--
--   CLK_25M -> clk_rst (rPLL 200 MHz, CLKDIV 50 MHz, resets)
--
--   host side (clk_host = SCLK in xSPI mode, clk_sys otherwise; host_clk):
--     xspi_slave | uart_bridge | frame_echo  <->  TX FIFO 4 KiB, RX FIFO 8 KiB
--   link side (clk_sys):
--     TX FIFO -> tx_framer -> enc_8b10b -> tx_gearbox -> tx_phy -> SFP TD
--     SFP RD -> rx_phy -> link_ctrl -> cdr_os4x8 -> comma_align -> dec_8b10b
--            -> rx_deframer -> RX FIFO
--   csr_regs (registers), sfp_mgmt (I2C, DDM, SFP status), leds
--
-- Operating mode (ADR 0006, ADR 0009):
--   UART  : MODE_SEL pin low (sampled during every reset) or
--           MODE_CTRL.UART_MODE; J3: IO0 = UART_RX, IO1 = UART_TX,
--           IO2 = UART_RTS_N and IO3 = UART_CTS_N with MODE_CTRL.RTSCTS_EN,
--           other lines high impedance, HOST_IRQ_N = link up.
--   echo  : MODE_CTRL.FRAME_ECHO (not UART): received frames are sent back;
--           J3 lines high impedance, xSPI not available.
--   xSPI  : otherwise; xspi_slave on J3, HOST_IRQ_N from csr_regs.
--   A change of UART_MODE / FRAME_ECHO resets the bridge (csr_regs);
--   leaving the UART / echo mode set by MODE_CTRL needs HOST_RST_N.
--
-- Host side of the FIFOs: ports on the falling edge of clk_host, like
-- xspi_slave and frame_echo; uart_bridge is clocked by the inverted
-- clk_host (its flip-flops on the falling edge), so all host side paths
-- have a full clock period.
--
-- RD pair polarity is swapped on board rev. A (SFP_RD_N on the true pin
-- 43): rx_phy with INVERT => true, rd_p => sfp_rd_n, rd_n => sfp_rd_p.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.bridge_pkg.all;
use work.xspi_pkg.all;

entity sfp_bridge_top is
  generic (
    -- slow timers (shortened only in simulation)
    MG_TIMEOUT_CLKS : positive := CLK_SYS_HZ / 40;     -- I2C SCL low limit 25 ms
    MG_TICK_CLKS    : positive := CLK_SYS_HZ / 10;     -- 100 ms
    MG_DEB_ABS_CLKS : positive := CLK_SYS_HZ / 100;    -- MOD_ABS filter 10 ms
    MG_DEB_SIG_CLKS : positive := CLK_SYS_HZ / 20_000; -- LOS / TX_FAULT filter 50 us
    LED_ACT_CLKS    : positive := CLK_SYS_HZ / 33;
    LED_BLINK_CLKS  : positive := CLK_SYS_HZ / 4
  );
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

    -- Host xSPI (J3)
    xspi_sclk    : in    std_logic;
    xspi_cs_n    : in    std_logic;
    xspi_io      : inout std_logic_vector(7 downto 0);
    xspi_dqs     : out   std_logic;
    host_irq_n   : out   std_logic;
    host_rst_n   : in    std_logic;

    -- Mode select (ADR 0006): '1' = xSPI, '0' = transparent UART
    mode_sel     : in    std_logic;

    -- LEDs, active low (3V3 -> 1k -> LED -> pin)
    led_link     : out   std_logic;
    led_act      : out   std_logic
  );
end entity sfp_bridge_top;

architecture rtl of sfp_bridge_top is

  constant TX_AW : positive := 12;                      -- TX FIFO 4 KiB
  constant RX_AW : positive := 13;                      -- RX FIFO 8 KiB

  -- clocks, resets, mode
  signal clk_fast, clk_sys, clk_host, clk_host_n : std_logic;
  signal rst_sys, rst_hard, rst_host : std_logic;
  signal soft_rst  : std_logic;
  signal mode_sel_s, mode_sel_l : std_logic := '1';
  signal m_uart_reg, m_echo_reg, m_rtscts : std_logic;
  signal mode_u, mode_e, mode_x : std_logic;
  signal on_sclk   : std_logic;
  signal cs_x      : std_logic;                          -- CS seen by the bridge

  -- J3 pins
  signal io_in, xs_out, xs_oe : std_logic_vector(7 downto 0);
  signal u_tx, u_rts_n : std_logic;

  -- host side of the FIFOs
  signal xs_tx_wr, xs_tx_commit, xs_tx_cprev, xs_tx_abort, xs_rx_rd : std_logic;
  signal xs_tx_data : std_logic_vector(7 downto 0);
  signal ub_tx_wr, ub_tx_commit, ub_rx_rd : std_logic;
  signal ub_tx_data : std_logic_vector(7 downto 0);
  signal ec_tx_wr, ec_tx_commit, ec_rx_rd : std_logic;
  signal ec_tx_data : std_logic_vector(7 downto 0);
  signal h_tx_wr, h_tx_commit, h_tx_cprev, h_tx_abort, h_rx_rd : std_logic;
  signal h_tx_data : std_logic_vector(7 downto 0);
  signal h_tx_full : std_logic;
  signal h_tx_free : unsigned(TX_AW downto 0);
  signal h_rx_data : std_logic_vector(7 downto 0);
  signal h_rx_valid, h_rx_empty : std_logic;
  signal xs_rx_valid, ub_rx_valid, ec_rx_valid : std_logic;   -- per module
  signal ub_rst    : std_logic;
  signal ev_u_ovf, ev_u_ferr : std_logic;

  -- xspi_slave <-> csr_regs
  signal reg_addr  : unsigned(7 downto 0);
  signal reg_rdata, status_fast : std_logic_vector(7 downto 0);
  signal wr_addr   : unsigned(7 downto 0);
  signal wr_data   : t_wr_buf;
  signal wr_cnt    : natural range 0 to WR_MAX;
  signal wr_txn, ev_tx_ovf_t, wr_apply : std_logic;

  -- link side
  signal tf_rd, tf_valid, tf_empty : std_logic;
  signal tf_data   : std_logic_vector(7 downto 0);
  signal tf_level  : unsigned(TX_AW downto 0);
  signal char_en   : std_logic;
  signal cd        : std_logic_vector(7 downto 0);
  signal ck        : std_logic;
  signal code      : std_logic_vector(9 downto 0);
  signal tx_bits   : std_logic_vector(1 downto 0);
  signal phy_smp, cdr_smp : std_logic_vector(7 downto 0);
  signal bits      : std_logic_vector(2 downto 0);
  signal nb        : unsigned(1 downto 0);
  signal sym       : std_logic_vector(9 downto 0);
  signal sym_valid : std_logic;
  signal sync_i, loss_i, restart : std_logic;
  signal dv, dk, dce, dde, derr : std_logic;
  signal dd        : std_logic_vector(7 downto 0);
  signal xoff_remote, xoff_local, remote_ready, rx_ready, tx_hold : std_logic;
  signal sent      : std_logic;
  signal fw, fc, fa, fovf : std_logic;
  signal fwd       : std_logic_vector(7 downto 0);
  signal rfree     : unsigned(RX_AW downto 0);
  signal rx_cmt    : unsigned(RX_AW downto 0);
  signal e_crc, e_code, e_len, e_fr, e_ovf, e_ok : std_logic;
  signal link_st   : t_link_state;
  signal link_up, link_chg, activity : std_logic;
  signal counters  : t_cnt_arr;

  -- configuration (csr_regs)
  signal cfg_tx_en, cfg_rx_en, cfg_lb_near, cfg_tx_dis, cfg_los_ignore, cnt_clr : std_logic;
  signal uart_div  : unsigned(15 downto 0);
  signal csr_irq_n : std_logic;
  signal loopback  : std_logic_vector(1 downto 0);

  -- SFP management
  signal f_los, f_fault, f_abs : std_logic;
  signal scl_oe, sda_oe : std_logic;
  signal mg_regs   : t_mg_regs;
  signal buf_rdata : std_logic_vector(7 downto 0);
  signal ev_i2c    : std_logic;
  signal scl_in, sda_in : std_logic;
  signal tx_lvl16, rx_lvl16 : unsigned(15 downto 0);
  signal ev_lerr   : std_logic;

begin

  ------------------------------------------------------------------------------
  -- Clocks, resets, operating mode
  ------------------------------------------------------------------------------
  u_clk : entity work.clk_rst
    port map (clk_25m => clk_25m, host_rst_n => host_rst_n, soft_rst => soft_rst,
              clk_fast => clk_fast, clk_sys => clk_sys, rst_sys => rst_sys,
              rst_hard => rst_hard, arst_n => open, pll_lock => open);

  -- MODE_SEL: synchronized, sampled while the bridge is in reset
  u_msel : entity work.sync_bit generic map (STAGES => 2, INIT_VAL => '1')
    port map (clk => clk_sys, d => mode_sel, q => mode_sel_s);
  process (clk_sys)
  begin
    if rising_edge(clk_sys) then
      if rst_sys = '1' then
        mode_sel_l <= mode_sel_s;
      end if;
    end if;
  end process;

  mode_u <= '1' when mode_sel_l = '0' or m_uart_reg = '1' else '0';
  mode_e <= '1' when mode_u = '0' and m_echo_reg = '1' else '0';
  mode_x <= '1' when mode_u = '0' and m_echo_reg = '0' else '0';

  u_hclk : entity work.host_clk
    port map (clk_sys => clk_sys, sclk => xspi_sclk, rst_sys => rst_sys, xspi_mode => mode_x,
              clk_host => clk_host, rst_host => rst_host, on_sclk => on_sclk);

  ------------------------------------------------------------------------------
  -- J3: xSPI or UART
  ------------------------------------------------------------------------------
  io_in <= to_x01(xspi_io);
  cs_x  <= xspi_cs_n when mode_x = '1' else '1';

  g_io : for i in 0 to 7 generate
    xspi_io(i) <= xs_out(i) when mode_x = '1' and xs_oe(i) = '1' else
                  u_tx      when mode_u = '1' and i = 1 else
                  u_rts_n   when mode_u = '1' and i = 2 and m_rtscts = '1' else
                  'Z';
  end generate;

  xspi_dqs   <= 'Z';                                     -- not used (SDR, no DQS)
  host_irq_n <= csr_irq_n when mode_u = '0' else link_up;

  ------------------------------------------------------------------------------
  -- Host side
  ------------------------------------------------------------------------------
  u_xs : entity work.xspi_slave
    port map (clk => clk_host, rst => rst_host, cs_n => cs_x,
              io_in => io_in, io_out => xs_out, io_oe => xs_oe,
              reg_addr => reg_addr, reg_rdata => reg_rdata, status_fast => status_fast,
              wr_addr => wr_addr, wr_data => wr_data, wr_cnt => wr_cnt, wr_txn => wr_txn,
              tx_wr => xs_tx_wr, tx_data => xs_tx_data, tx_commit => xs_tx_commit,
              tx_commit_prev => xs_tx_cprev, tx_abort => xs_tx_abort, tx_full => h_tx_full,
              rx_rd => xs_rx_rd, rx_data => h_rx_data, rx_valid => xs_rx_valid, rx_empty => h_rx_empty,
              ev_tx_ovf_t => ev_tx_ovf_t);

  ub_rst     <= rst_host or not mode_u;
  clk_host_n <= not clk_host;                          -- falling edge of clk_host

  u_ub : entity work.uart_bridge
    generic map (MAX_PAY => 64, FREE_W => TX_AW + 1, RTS_FREE => 512)
    port map (clk => clk_host_n, rst => ub_rst, cfg_div => uart_div, cfg_rtscts => m_rtscts,
              uart_rx => io_in(0), uart_tx => u_tx, uart_rts_n => u_rts_n, uart_cts_n => io_in(3),
              tx_wr => ub_tx_wr, tx_data => ub_tx_data, tx_commit => ub_tx_commit, tx_free => h_tx_free,
              rx_rd => ub_rx_rd, rx_data => h_rx_data, rx_valid => ub_rx_valid, rx_empty => h_rx_empty,
              ev_rx_ovf => ev_u_ovf, ev_frame_err => ev_u_ferr, ev_frame => open, ev_skip => open);

  u_echo : entity work.frame_echo
    port map (clk => clk_host, rst => rst_host, en => mode_e,
              rx_rd => ec_rx_rd, rx_data => h_rx_data, rx_valid => ec_rx_valid, rx_empty => h_rx_empty,
              tx_wr => ec_tx_wr, tx_data => ec_tx_data, tx_commit => ec_tx_commit, tx_full => h_tx_full,
              ev_frame => open);

  -- host side FIFO ports: the module of the active mode (rx_valid only to
  -- the reader of the active mode)
  xs_rx_valid <= h_rx_valid and mode_x;
  ub_rx_valid <= h_rx_valid and mode_u;
  ec_rx_valid <= h_rx_valid and mode_e;
  h_tx_wr     <= xs_tx_wr     when mode_x = '1' else ub_tx_wr     when mode_u = '1' else ec_tx_wr;
  h_tx_data   <= xs_tx_data   when mode_x = '1' else ub_tx_data   when mode_u = '1' else ec_tx_data;
  h_tx_commit <= xs_tx_commit when mode_x = '1' else ub_tx_commit when mode_u = '1' else ec_tx_commit;
  h_tx_cprev  <= xs_tx_cprev  when mode_x = '1' else '0';
  h_tx_abort  <= xs_tx_abort  when mode_x = '1' else '0';
  h_rx_rd     <= xs_rx_rd     when mode_x = '1' else ub_rx_rd     when mode_u = '1' else ec_rx_rd;

  u_tf : entity work.async_fifo
    generic map (DATA_W => 8, ADDR_W => TX_AW, COMMIT_MODE => true, PUB_STABLE => true,
                 WR_FALLING => true)
    port map (wr_clk => clk_host, wr_rst => rst_host, wr_en => h_tx_wr, wr_data => h_tx_data,
              wr_commit => h_tx_commit, wr_commit_prev => h_tx_cprev, wr_abort => h_tx_abort,
              full => h_tx_full, wr_free => h_tx_free, wr_cmt_level => open, wr_ovf => open,
              rd_clk => clk_sys, rd_rst => rst_sys, rd_en => tf_rd, rd_data => tf_data,
              rd_valid => tf_valid, empty => tf_empty, rd_level => tf_level, rd_udf => open);

  u_rf : entity work.async_fifo
    generic map (DATA_W => 8, ADDR_W => RX_AW, COMMIT_MODE => true, RD_FALLING => true)
    port map (wr_clk => clk_sys, wr_rst => rst_sys, wr_en => fw, wr_data => fwd,
              wr_commit => fc, wr_abort => fa, full => open, wr_free => rfree,
              wr_cmt_level => rx_cmt, wr_ovf => fovf,
              rd_clk => clk_host, rd_rst => rst_host, rd_en => h_rx_rd, rd_data => h_rx_data,
              rd_valid => h_rx_valid, empty => h_rx_empty, rd_level => open, rd_udf => open);

  ------------------------------------------------------------------------------
  -- Link side
  ------------------------------------------------------------------------------
  u_fr : entity work.tx_framer
    port map (clk => clk_sys, rst => rst_sys, char_en => char_en, char_data => cd, char_k => ck,
              fifo_empty => tf_empty, fifo_rd => tf_rd, fifo_data => tf_data, fifo_valid => tf_valid,
              rx_ready => rx_ready, xoff_local => xoff_local, xoff_remote => tx_hold,
              busy => open, frame_sent => sent, len_err => open);

  u_enc : entity work.enc_8b10b
    port map (clk => clk_sys, rst => rst_sys, en => char_en, data => cd, k => ck,
              code => code, valid => open, k_err => open, rd => open);

  u_gb : entity work.tx_gearbox
    port map (clk => clk_sys, rst => rst_sys, char_en => char_en, code => code, bits => tx_bits);

  u_txphy : entity work.tx_phy
    generic map (INVERT => false)
    port map (clk_fast => clk_fast, clk_sys => clk_sys, rst => rst_sys, bits => tx_bits,
              td_p => sfp_td_p, td_n => sfp_td_n);

  -- RD pair swapped on the board (rev. A): true pin = SFP_RD_N
  u_rxphy : entity work.rx_phy
    generic map (INVERT => true)
    port map (clk_fast => clk_fast, clk_sys => clk_sys, rst => rst_sys,
              rd_p => sfp_rd_n, rd_n => sfp_rd_p, samples => phy_smp);

  u_cdr : entity work.cdr_os4x8
    port map (clk => clk_sys, rst => rst_sys, samples => cdr_smp, bits => bits, nbits => nb,
              phase => open, shift_up => open, shift_dn => open, activity => open);

  u_al : entity work.comma_align
    port map (clk => clk_sys, rst => rst_sys, restart => restart, in_bits => bits, in_n => nb,
              sym => sym, sym_valid => sym_valid, sym_comma => open,
              dec_valid => dv, dec_err => derr,
              sync => sync_i, ev_realign => open, ev_sync_loss => loss_i);

  u_dec : entity work.dec_8b10b
    port map (clk => clk_sys, rst => rst_sys, en => sym_valid, code => sym,
              data => dd, k => dk, valid => dv, code_err => dce, disp_err => dde, rd => open);
  derr <= dce or dde;

  u_df : entity work.rx_deframer
    generic map (FREE_W => RX_AW + 1)
    port map (clk => clk_sys, rst => rst_sys, sync => sync_i, char_valid => dv,
              char_data => dd, char_k => dk, code_err => dce, disp_err => dde,
              fifo_wr => fw, fifo_data => fwd, fifo_commit => fc, fifo_abort => fa,
              fifo_free => rfree, fifo_ovf => fovf,
              xoff_remote => xoff_remote, remote_ready => remote_ready, xoff_local => xoff_local,
              ev_frame_ok => e_ok, ev_crc_err => e_crc, ev_code_err => e_code,
              ev_len_err => e_len, ev_framing => e_fr, ev_ovf => e_ovf, busy => open);

  loopback <= LB_NEAR when cfg_lb_near = '1' else LB_NONE;

  u_lc : entity work.link_ctrl
    port map (clk => clk_sys, rst => rst_sys,
              cfg_tx_en => cfg_tx_en, cfg_rx_en => cfg_rx_en, cfg_los_ignore => cfg_los_ignore,
              cfg_loopback => loopback, cnt_clr => cnt_clr,
              sfp_los => f_los, sfp_mod_abs => f_abs,
              rx_sync => sync_i, remote_ready => remote_ready, xoff_remote => xoff_remote,
              dec_valid => dv, dec_code_err => dce, dec_disp_err => dde,
              ev_crc_err => e_crc, ev_len_err => e_len, ev_framing => e_fr, ev_ovf => e_ovf,
              ev_frame_ok => e_ok, ev_frame_sent => sent, ev_sync_loss => loss_i,
              phy_samples => phy_smp, tx_bits => tx_bits, cdr_samples => cdr_smp,
              align_restart => restart, rx_ready => rx_ready, tx_hold => tx_hold,
              link_state => link_st, link_up => link_up, link_chg => link_chg,
              activity => activity, counters => counters);

  ------------------------------------------------------------------------------
  -- Registers, SFP management, LEDs
  ------------------------------------------------------------------------------
  tx_lvl16 <= resize(tf_level, 16);
  rx_lvl16 <= resize(rx_cmt, 16);
  ev_lerr  <= e_crc or e_code or e_len or e_fr or e_ovf;
  scl_in   <= to_x01(sfp_scl);
  sda_in   <= to_x01(sfp_sda);

  u_csr : entity work.csr_regs
    generic map (TX_DEPTH => 2 ** TX_AW, MAX_LEN => 1024)
    port map (clk => clk_sys, rst => rst_sys, rst_hard => rst_hard,
              cs_n => cs_x, reg_addr => reg_addr, reg_rdata => reg_rdata, status_fast => status_fast,
              wr_addr => wr_addr, wr_data => wr_data, wr_cnt => wr_cnt, wr_txn => wr_txn,
              ev_tx_ovf_t => ev_tx_ovf_t,
              wr_apply => wr_apply, mg_regs => mg_regs, buf_rdata => buf_rdata,
              link_state => link_st, rx_sync => sync_i, remote_ready => remote_ready,
              xoff_local => xoff_local, xoff_remote => xoff_remote,
              sfp_los => f_los, sfp_tx_fault => f_fault, sfp_mod_abs => f_abs, mode_sel => mode_sel_l,
              tx_level => tx_lvl16, rx_level => rx_lvl16, counters => counters,
              ev_rx_frame => e_ok, ev_link_chg => link_chg, ev_i2c_done => ev_i2c,
              ev_err => ev_lerr,
              ev_uart_ovf => ev_u_ovf, ev_uart_ferr => ev_u_ferr,
              cfg_tx_en => cfg_tx_en, cfg_rx_en => cfg_rx_en, cfg_lb_near => cfg_lb_near,
              cfg_sfp_tx_dis => cfg_tx_dis, cfg_los_ignore => cfg_los_ignore, cnt_clr => cnt_clr,
              soft_rst => soft_rst, mode_uart => m_uart_reg, mode_echo => m_echo_reg,
              mode_rtscts => m_rtscts, uart_div => uart_div, irq_n => csr_irq_n);

  u_mg : entity work.sfp_mgmt
    generic map (CLK_HZ => CLK_SYS_HZ, I2C_HZ => 100_000, TIMEOUT_CLKS => MG_TIMEOUT_CLKS,
                 TICK_CLKS => MG_TICK_CLKS, INSERT_TICKS => 4,
                 DEB_ABS_CLKS => MG_DEB_ABS_CLKS, DEB_SIG_CLKS => MG_DEB_SIG_CLKS)
    port map (clk => clk_sys, rst => rst_sys,
              los_pin => sfp_los, fault_pin => sfp_tx_fault, abs_pin => sfp_mod_abs,
              tx_dis_pin => sfp_tx_dis,
              scl_i => scl_in, sda_i => sda_in, scl_oe => scl_oe, sda_oe => sda_oe,
              sfp_los => f_los, sfp_tx_fault => f_fault, sfp_mod_abs => f_abs, cfg_tx_dis => cfg_tx_dis,
              wr_apply => wr_apply, wr_addr => wr_addr, wr_data => wr_data, wr_cnt => wr_cnt,
              regs => mg_regs, buf_raddr => reg_addr(6 downto 0), buf_rdata => buf_rdata,
              ev_i2c_done => ev_i2c);

  sfp_scl <= '0' when scl_oe = '1' else 'Z';
  sfp_sda <= '0' when sda_oe = '1' else 'Z';

  u_led : entity work.leds
    generic map (ACT_CLKS => LED_ACT_CLKS, BLINK_CLKS => LED_BLINK_CLKS)
    port map (clk => clk_sys, rst => rst_sys, link_state => link_st, activity => activity,
              led_link_n => led_link, led_act_n => led_act);

end architecture rtl;
