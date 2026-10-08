--------------------------------------------------------------------------------
-- tb_link_ctrl
--
-- Unit testbench for link_ctrl (inputs driven directly). The integration
-- with the real link is covered by tb_link_loopback.
--
-- Checks:
--   1. after reset: DOWN, rx_ready = 0, tx_hold = 1, align_restart = 1
--   2. rx_sync = 1, remote not ready: SYNC, rx_ready = 1, tx_hold = 1,
--      one link_chg pulse
--   3. remote_ready = 1: UP, link_up = 1, tx_hold = 0
--   4. XOFF from the remote, cfg_tx_en = 0: tx_hold = 1, state stays UP
--   5. cfg_rx_en = 0: rx_ready = 0
--   6. LOS: DOWN and align_restart while LOS; with cfg_los_ignore = 1 no
--      effect; module absent: DOWN
--   7. counters: each event pulsed a different number of times (index + 3);
--      CODE_ERR counts decoder errors only while rx_sync = 1; cnt_clr clears
--      all; a 4-bit instance wraps from 15 to 0
--   8. near-end loopback: cdr_samples = tx_bits repeated 4x (one clock of
--      latency), LOS ignored, one-clock align_restart at the mode change;
--      normal mode: cdr_samples = phy_samples (one clock of latency)
--   9. activity pulses for frame_sent and frame_ok
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.tb_pkg.all;
use work.bridge_pkg.all;

entity tb_link_ctrl is
end entity tb_link_ctrl;

architecture sim of tb_link_ctrl is

  constant T_CLK : time := 20 ns;

  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';
  signal stop  : boolean := false;

  signal cfg_tx_en, cfg_rx_en : std_logic := '1';
  signal cfg_los_ignore       : std_logic := '0';
  signal cfg_loopback         : std_logic_vector(1 downto 0) := LB_NONE;
  signal cnt_clr              : std_logic := '0';
  signal sfp_los, sfp_mod_abs : std_logic := '0';
  signal rx_sync, remote_ready : std_logic := '0';
  signal xoff_remote          : std_logic := '1';
  signal dec_valid, dec_code_err, dec_disp_err : std_logic := '0';
  signal ev                   : std_logic_vector(6 downto 0) := (others => '0');
  -- ev: 0 crc, 1 len, 2 framing, 3 ovf, 4 frame_ok, 5 frame_sent, 6 sync_loss
  signal phy_samples          : std_logic_vector(7 downto 0) := (others => '0');
  signal tx_bits              : std_logic_vector(1 downto 0) := (others => '0');
  signal cdr_samples          : std_logic_vector(7 downto 0);
  signal align_restart, rx_ready, tx_hold : std_logic;
  signal link_state           : t_link_state;
  signal link_up, link_chg, activity : std_logic;
  signal counters, counters4  : t_cnt_arr;

  signal n_chg, n_act         : natural := 0;

begin

  clk_gen(clk, T_CLK, stop);

  dut : entity work.link_ctrl
    port map (clk => clk, rst => rst,
              cfg_tx_en => cfg_tx_en, cfg_rx_en => cfg_rx_en, cfg_los_ignore => cfg_los_ignore,
              cfg_loopback => cfg_loopback, cnt_clr => cnt_clr,
              sfp_los => sfp_los, sfp_mod_abs => sfp_mod_abs,
              rx_sync => rx_sync, remote_ready => remote_ready, xoff_remote => xoff_remote,
              dec_valid => dec_valid, dec_code_err => dec_code_err, dec_disp_err => dec_disp_err,
              ev_crc_err => ev(0), ev_len_err => ev(1), ev_framing => ev(2), ev_ovf => ev(3),
              ev_frame_ok => ev(4), ev_frame_sent => ev(5), ev_sync_loss => ev(6),
              phy_samples => phy_samples, tx_bits => tx_bits, cdr_samples => cdr_samples,
              align_restart => align_restart, rx_ready => rx_ready, tx_hold => tx_hold,
              link_state => link_state, link_up => link_up, link_chg => link_chg,
              activity => activity, counters => counters);

  -- 4-bit counters for the wrap-around check
  dut4 : entity work.link_ctrl
    generic map (CNT_W => 4)
    port map (clk => clk, rst => rst,
              cfg_tx_en => cfg_tx_en, cfg_rx_en => cfg_rx_en, cfg_los_ignore => cfg_los_ignore,
              cfg_loopback => cfg_loopback, cnt_clr => cnt_clr,
              sfp_los => sfp_los, sfp_mod_abs => sfp_mod_abs,
              rx_sync => rx_sync, remote_ready => remote_ready, xoff_remote => xoff_remote,
              dec_valid => dec_valid, dec_code_err => dec_code_err, dec_disp_err => dec_disp_err,
              ev_crc_err => ev(0), ev_len_err => ev(1), ev_framing => ev(2), ev_ovf => ev(3),
              ev_frame_ok => ev(4), ev_frame_sent => ev(5), ev_sync_loss => ev(6),
              phy_samples => phy_samples, tx_bits => tx_bits, cdr_samples => open,
              align_restart => open, rx_ready => open, tx_hold => open,
              link_state => open, link_up => open, link_chg => open,
              activity => open, counters => counters4);

  -- pulse counters
  process (clk)
  begin
    if rising_edge(clk) then
      if link_chg = '1' then n_chg <= n_chg + 1; end if;
      if activity = '1' then n_act <= n_act + 1; end if;
    end if;
  end process;

  process
    procedure tick(n : positive := 1) is
    begin
      for i in 1 to n loop
        wait until rising_edge(clk);
      end loop;
      wait for 1 ns;
    end procedure;

    -- one-cycle pulse on ev(i)
    procedure pulse(i : natural) is
    begin
      ev(i) <= '1';
      tick;
      ev(i) <= '0';
      tick;
    end procedure;

    procedure dec_error(code, disp : std_logic) is
    begin
      dec_valid <= '1'; dec_code_err <= code; dec_disp_err <= disp;
      tick;
      dec_valid <= '0'; dec_code_err <= '0'; dec_disp_err <= '0';
      tick;
    end procedure;

    variable chg0 : natural;
  begin
    rst <= '1';
    tick(4);
    rst <= '0';
    tick(3);

    -- 1
    check(link_state = LS_DOWN, "1: DOWN after reset");
    check_equal(rx_ready, '0', "1: rx_ready");
    check_equal(tx_hold, '1', "1: tx_hold");
    check_equal(n_chg, 0, "1: no link_chg");

    -- 2
    rx_sync <= '1';
    tick(2);
    check(link_state = LS_SYNC, "2: SYNC");
    check_equal(rx_ready, '1', "2: rx_ready");
    check_equal(tx_hold, '1', "2: tx_hold");
    check_equal(n_chg, 1, "2: one link_chg pulse");

    -- 3
    remote_ready <= '1';
    xoff_remote  <= '0';
    tick(2);
    check(link_state = LS_UP, "3: UP");
    check_equal(link_up, '1', "3: link_up");
    check_equal(tx_hold, '0', "3: tx_hold released");
    check_equal(n_chg, 2, "3: second link_chg pulse");

    -- 4
    xoff_remote <= '1';
    tick;
    check_equal(tx_hold, '1', "4: tx_hold on XOFF");
    xoff_remote <= '0';
    cfg_tx_en   <= '0';
    tick;
    check_equal(tx_hold, '1', "4: tx_hold with TX_EN = 0");
    check(link_state = LS_UP, "4: still UP");
    cfg_tx_en <= '1';
    tick;
    check_equal(tx_hold, '0', "4: tx_hold released again");

    -- 5
    cfg_rx_en <= '0';
    tick;
    check_equal(rx_ready, '0', "5: rx_ready with RX_EN = 0");
    cfg_rx_en <= '1';
    tick;
    check_equal(rx_ready, '1', "5: rx_ready restored");

    -- 6
    chg0 := n_chg;
    sfp_los <= '1';
    tick(2);
    check(link_state = LS_DOWN, "6: DOWN on LOS");
    check_equal(align_restart, '1', "6: align_restart while LOS");
    check_equal(tx_hold, '1', "6: tx_hold while LOS");
    tick(5);
    check_equal(align_restart, '1', "6: align_restart held");
    sfp_los <= '0';
    tick(2);
    check_equal(align_restart, '0', "6: align_restart released");
    check(link_state = LS_UP, "6: UP after LOS");
    cfg_los_ignore <= '1';
    sfp_los <= '1';
    tick(2);
    check(link_state = LS_UP, "6: LOS ignored");
    check_equal(align_restart, '0', "6: no restart with LOS ignored");
    sfp_los <= '0';
    cfg_los_ignore <= '0';
    sfp_mod_abs <= '1';
    tick(2);
    check(link_state = LS_DOWN, "6: DOWN when the module is absent");
    sfp_mod_abs <= '0';
    tick(2);
    check(link_state = LS_UP, "6: UP again");
    check_equal(n_chg - chg0, 4, "6: link_chg pulses");

    -- 7
    for i in 0 to 6 loop
      for n in 1 to i + 3 loop
        pulse(i);
      end loop;
    end loop;
    for n in 1 to 5 loop
      dec_error('1', '0');
    end loop;
    dec_error('0', '1');
    dec_valid <= '1';                     -- valid without error: not counted
    tick;
    dec_valid <= '0';
    rx_sync <= '0';                       -- errors without sync: not counted
    tick;
    dec_error('1', '1');
    dec_error('1', '0');
    rx_sync <= '1';
    tick(3);
    check_equal(to_integer(counters(CNT_CODE_ERR)), 6, "7: CODE_ERR");
    check_equal(to_integer(counters(CNT_CRC_ERR)), 3, "7: CRC_ERR");
    check_equal(to_integer(counters(CNT_LEN_ERR)), 4, "7: LEN_ERR");
    check_equal(to_integer(counters(CNT_FRAMING_ERR)), 5, "7: FRAMING_ERR");
    check_equal(to_integer(counters(CNT_RX_OVF)), 6, "7: RX_OVF");
    check_equal(to_integer(counters(CNT_FRAMES_RX)), 7, "7: FRAMES_RX");
    check_equal(to_integer(counters(CNT_FRAMES_TX)), 8, "7: FRAMES_TX");
    check_equal(to_integer(counters(CNT_SYNC_LOSS)), 9, "7: SYNC_LOSS");
    -- 4-bit instance: SYNC_LOSS 9, plus 10 more -> 19 mod 16 = 3
    for n in 1 to 10 loop
      pulse(6);
    end loop;
    tick(2);
    check_equal(to_integer(counters4(CNT_SYNC_LOSS)), 3, "7: 4-bit counter wraps");
    check_equal(to_integer(counters(CNT_SYNC_LOSS)), 19, "7: 32-bit counter");
    cnt_clr <= '1';
    tick;
    cnt_clr <= '0';
    tick;
    for i in 0 to N_CNT - 1 loop
      check_equal(to_integer(counters(i)), 0, "7: counter " & integer'image(i) & " cleared");
    end loop;

    -- 8
    phy_samples <= x"A5";
    tick(2);
    check_equal(cdr_samples, x"A5", "8: normal mode passes phy_samples");
    cfg_loopback <= LB_NEAR;
    tx_bits <= "10";
    tick;
    check_equal(align_restart, '1', "8: restart pulse at the mode change");
    check_equal(cdr_samples, x"F0", "8: near-end loopback, bits 10");
    tick;
    check_equal(align_restart, '0', "8: restart pulse is one clock");
    tx_bits <= "01";
    tick;
    check_equal(cdr_samples, x"0F", "8: near-end loopback, bits 01");
    sfp_los <= '1';
    sfp_mod_abs <= '1';
    tick(2);
    check(link_state = LS_UP, "8: SFP signals ignored in near-end loopback");
    check_equal(align_restart, '0', "8: no restart from LOS in near-end loopback");
    sfp_los <= '0';
    sfp_mod_abs <= '0';
    cfg_loopback <= LB_FAR;
    tick(2);
    check_equal(cdr_samples, x"A5", "8: far-end mode passes phy_samples");
    cfg_loopback <= LB_NONE;
    tick(2);

    -- 9
    chg0 := n_act;
    pulse(4);
    pulse(5);
    tick(2);
    check_equal(n_act - chg0, 2, "9: activity pulses");

    stop <= true;
    tb_finish("tb_link_ctrl");
    wait;
  end process;

end architecture sim;
