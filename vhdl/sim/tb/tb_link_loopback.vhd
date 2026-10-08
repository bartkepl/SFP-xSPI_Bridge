--------------------------------------------------------------------------------
-- tb_link_loopback
--
-- Full link between two bridge ends at bit level, with the Gowin primitive
-- simulation models (library gw1n) and independent clocks:
--
--   host -> TX FIFO -> tx_framer -> enc_8b10b -> tx_gearbox -> tx_phy
--        -> line (delay + jitter) ->
--   rx_phy -> link_ctrl (loopback mux) -> cdr_os4x8 -> comma_align
--        -> dec_8b10b -> rx_deframer -> RX FIFO -> host       (both directions)
--
-- link_ctrl controls each end (link state, idle /R/, transmit gating,
-- counters; ADR 0008).
--
-- Each side: clk_fast from its own oscillator, clk_sys from the CLKDIV
-- model (DIV_MODE "4"). Side B runs 200 ppm faster than side A
-- (clk_fast 4.999 ns vs 5.000 ns). The line adds a 5 ns delay and an
-- independent random jitter of +/-0.2 UI (+/-2 ns) to every transition.
-- The host side of the FIFOs runs on clk_sys of the same end (the clock
-- domain crossing of async_fifo is verified by tb_async_fifo).
--
-- Phases:
--   1. Both hosts write 32 frames right after their reset, before the link is up
--      (id-dependent type, length 1..400, payload); A ids 0..31, B ids
--      1000..1031. LOS is active at B for the first 20 us: B stays DOWN
--      and sends idle /R/, A reaches SYNC only; no frame may be sent until
--      both ends are UP (frames would be lost at B).
--   2. Side A in near-end loopback (LB_NEAR); A writes ids 32..35: they
--      return to A's own receiver and also reach B over the line.
--   3. Side A back to normal operation; B writes ids 1032..1035.
--
-- Checks:
--   1. during LOS at B: A in SYNC, B in DOWN, no frame sent; afterwards both
--      ends reach link state UP; in phase 1 no loss of sync after UP;
--   2. every reader receives exactly the expected frames, in order and
--      intact (A: 32 from B, 4 own, 4 from B; B: 36 from A);
--   3. no deframer error event and no RX FIFO underflow at either end;
--   4. CDR frequency tracking in phase 1: at side A (receiving the faster
--      stream) shift_dn steps, at side B shift_up steps (more than 10 each,
--      at most 2 in the opposite direction while the phase settles);
--      3-bit / 1-bit clocks accordingly;
--   5. link_ctrl counters at the end: FRAMES_TX A 36 / B 36, FRAMES_RX
--      A 40 / B 36, CRC, LEN, FRAMING, RX_OVF errors 0, SYNC_LOSS at B 0.
--
-- Waveform: per side clk_sys, line signals, CDR phase, link state,
-- deframer events and FIFO activity; see doc/vhdl/phy.md.
--------------------------------------------------------------------------------

-- One end of the link (test model; the synthesizable top-level composes
-- the same modules).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.bridge_pkg.all;

entity tb_link_side is
  port (
    clk_fast  : in  std_logic;
    clk_sys   : in  std_logic;
    rst       : in  std_logic;
    loopback  : in  std_logic_vector(1 downto 0);
    los       : in  std_logic;          -- SFP loss of signal (synchronized)
    -- host write (TX FIFO, commit mode)
    h_wr      : in  std_logic;
    h_wdata   : in  std_logic_vector(7 downto 0);
    h_commit  : in  std_logic;
    h_full    : out std_logic;
    -- host read (RX FIFO)
    h_rd      : in  std_logic;
    h_rdata   : out std_logic_vector(7 downto 0);
    h_rvalid  : out std_logic;
    h_rempty  : out std_logic;
    h_rudf    : out std_logic;
    -- line
    td_p      : out std_logic;
    td_n      : out std_logic;
    rd_p      : in  std_logic;
    rd_n      : in  std_logic;
    -- status
    link_st   : out t_link_state;
    sync_loss : out std_logic;
    phase     : out unsigned(1 downto 0);
    nbits     : out unsigned(1 downto 0);
    shift_up  : out std_logic;
    shift_dn  : out std_logic;
    ev_ok     : out std_logic;
    ev_err    : out std_logic;          -- any deframer error event
    counters  : out t_cnt_arr
  );
end entity tb_link_side;

architecture sim of tb_link_side is
  signal tf_rd, tf_valid, tf_empty : std_logic;
  signal tf_data   : std_logic_vector(7 downto 0);
  signal char_en   : std_logic;
  signal cd        : std_logic_vector(7 downto 0);
  signal ck        : std_logic;
  signal code      : std_logic_vector(9 downto 0);
  signal tx_bits   : std_logic_vector(1 downto 0);
  signal phy_smp   : std_logic_vector(7 downto 0);
  signal cdr_smp   : std_logic_vector(7 downto 0);
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
  signal rfree     : unsigned(13 downto 0);
  signal e_crc, e_code, e_len, e_fr, e_ovf, e_ok : std_logic;
begin
  u_tf : entity work.async_fifo
    generic map (DATA_W => 8, ADDR_W => 12, COMMIT_MODE => true)
    port map (wr_clk => clk_sys, wr_rst => rst, wr_en => h_wr, wr_data => h_wdata,
              wr_commit => h_commit, wr_abort => '0', full => h_full, wr_free => open, wr_ovf => open,
              rd_clk => clk_sys, rd_rst => rst, rd_en => tf_rd, rd_data => tf_data,
              rd_valid => tf_valid, empty => tf_empty, rd_level => open, rd_udf => open);

  u_fr : entity work.tx_framer
    port map (clk => clk_sys, rst => rst, char_en => char_en, char_data => cd, char_k => ck,
              fifo_empty => tf_empty, fifo_rd => tf_rd, fifo_data => tf_data, fifo_valid => tf_valid,
              rx_ready => rx_ready, xoff_local => xoff_local, xoff_remote => tx_hold,
              busy => open, frame_sent => sent, len_err => open);

  u_enc : entity work.enc_8b10b
    port map (clk => clk_sys, rst => rst, en => char_en, data => cd, k => ck,
              code => code, valid => open, k_err => open, rd => open);

  u_gb : entity work.tx_gearbox
    port map (clk => clk_sys, rst => rst, char_en => char_en, code => code, bits => tx_bits);

  u_txphy : entity work.tx_phy
    port map (clk_fast => clk_fast, clk_sys => clk_sys, rst => rst, bits => tx_bits,
              td_p => td_p, td_n => td_n);

  u_rxphy : entity work.rx_phy
    port map (clk_fast => clk_fast, clk_sys => clk_sys, rst => rst,
              rd_p => rd_p, rd_n => rd_n, samples => phy_smp);

  u_cdr : entity work.cdr_os4x8
    port map (clk => clk_sys, rst => rst, samples => cdr_smp, bits => bits, nbits => nb,
              phase => phase, shift_up => shift_up, shift_dn => shift_dn, activity => open);

  u_al : entity work.comma_align
    port map (clk => clk_sys, rst => rst, restart => restart, in_bits => bits, in_n => nb,
              sym => sym, sym_valid => sym_valid, sym_comma => open,
              dec_valid => dv, dec_err => derr,
              sync => sync_i, ev_realign => open, ev_sync_loss => loss_i);

  u_dec : entity work.dec_8b10b
    port map (clk => clk_sys, rst => rst, en => sym_valid, code => sym,
              data => dd, k => dk, valid => dv, code_err => dce, disp_err => dde, rd => open);
  derr <= dce or dde;

  u_df : entity work.rx_deframer
    port map (clk => clk_sys, rst => rst, sync => sync_i, char_valid => dv,
              char_data => dd, char_k => dk, code_err => dce, disp_err => dde,
              fifo_wr => fw, fifo_data => fwd, fifo_commit => fc, fifo_abort => fa,
              fifo_free => rfree, fifo_ovf => fovf,
              xoff_remote => xoff_remote, remote_ready => remote_ready, xoff_local => xoff_local,
              ev_frame_ok => e_ok, ev_crc_err => e_crc, ev_code_err => e_code,
              ev_len_err => e_len, ev_framing => e_fr, ev_ovf => e_ovf, busy => open);

  u_rf : entity work.async_fifo
    generic map (DATA_W => 8, ADDR_W => 13, COMMIT_MODE => true)
    port map (wr_clk => clk_sys, wr_rst => rst, wr_en => fw, wr_data => fwd,
              wr_commit => fc, wr_abort => fa, full => open, wr_free => rfree, wr_ovf => fovf,
              rd_clk => clk_sys, rd_rst => rst, rd_en => h_rd, rd_data => h_rdata,
              rd_valid => h_rvalid, empty => h_rempty, rd_level => open, rd_udf => h_rudf);

  u_lc : entity work.link_ctrl
    port map (clk => clk_sys, rst => rst,
              cfg_tx_en => '1', cfg_rx_en => '1', cfg_los_ignore => '0',
              cfg_loopback => loopback, cnt_clr => '0',
              sfp_los => los, sfp_mod_abs => '0',
              rx_sync => sync_i, remote_ready => remote_ready, xoff_remote => xoff_remote,
              dec_valid => dv, dec_code_err => dce, dec_disp_err => dde,
              ev_crc_err => e_crc, ev_len_err => e_len, ev_framing => e_fr, ev_ovf => e_ovf,
              ev_frame_ok => e_ok, ev_frame_sent => sent, ev_sync_loss => loss_i,
              phy_samples => phy_smp, tx_bits => tx_bits, cdr_samples => cdr_smp,
              align_restart => restart, rx_ready => rx_ready, tx_hold => tx_hold,
              link_state => link_st, link_up => open, link_chg => open, activity => open,
              counters => counters);

  ev_ok     <= e_ok;
  ev_err    <= e_crc or e_code or e_len or e_fr or e_ovf;
  sync_loss <= loss_i;
  nbits     <= nb;
end architecture sim;

--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library gw1n;
use gw1n.components.all;

library work;
use work.tb_pkg.all;
use work.bridge_pkg.all;

entity tb_link_loopback is
end entity tb_link_loopback;

architecture sim of tb_link_loopback is

  constant T_FAST_A : time := 5000 ps;
  constant T_FAST_B : time := 4999 ps;       -- +200 ppm
  constant N_FR     : natural := 32;
  constant N_LB     : natural := 4;          -- frames in phases 2 and 3
  constant LINE_DLY : time := 5 ns;
  constant JIT_NS   : real := 2.0;           -- +/-0.2 UI
  constant LOS_TIME : time := 20 us;

  function f_type(id : natural) return natural is
  begin
    return (id * 29 + 16) mod 256;
  end function;
  function f_len(id : natural) return natural is
  begin
    return 1 + (id * 97 + 31) mod 400;
  end function;
  function f_byte(id, i : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned((id * 7 + i * 13 + i / 256) mod 256, 8));
  end function;

  signal clk_fast_a, clk_fast_b : std_logic := '0';
  signal clk_a, clk_b : std_logic;
  signal rst_a, rst_b : std_logic := '1';
  signal stop       : boolean := false;
  signal phase_no   : natural := 0;

  signal a_lb, b_lb : std_logic_vector(1 downto 0) := LB_NONE;
  signal b_los      : std_logic := '1';     -- B: LOS during the first LOS_TIME
  signal a_wr, a_commit, a_full, a_rd, a_rvalid, a_rempty, a_rudf : std_logic := '0';
  signal b_wr, b_commit, b_full, b_rd, b_rvalid, b_rempty, b_rudf : std_logic := '0';
  signal a_wdata, a_rdata, b_wdata, b_rdata : std_logic_vector(7 downto 0) := (others => '0');
  signal a_td_p, a_td_n, b_td_p, b_td_n : std_logic;
  signal a_rd_p, b_rd_p : std_logic := '0';
  signal a_rd_n, b_rd_n : std_logic := '1';
  signal a_st, b_st : t_link_state;
  signal a_loss, b_loss : std_logic;
  signal a_phase, b_phase, a_nbits, b_nbits : unsigned(1 downto 0);
  signal a_up, a_dn, b_up, b_dn, a_ok, b_ok, a_err, b_err : std_logic;
  signal a_cnt, b_cnt : t_cnt_arr;

  -- writers: request (id0, n) and done flag per side
  signal a_go, b_go : boolean := false;
  signal a_id0, b_id0, a_n, b_n : natural := 0;
  signal a_busy, b_busy : boolean := false;

  -- readers: expected id = base + frames since the last base change
  signal a_base, b_base     : natural := 0;
  signal a_frames, b_frames : natural := 0;     -- frames received correctly (total)
  signal a_bad, b_bad       : natural := 0;     -- frames received wrong (total)

  -- error monitors
  signal a_errs, b_errs, a_udf, b_udf, b_losses : natural := 0;

  -- frame writer: n frames with ids id0, id0 + 1, ...
  procedure write_frames(signal clk : in std_logic; signal wr, commit : out std_logic;
                         signal wdata : out std_logic_vector(7 downto 0);
                         signal full : in std_logic; id0, n : natural) is
    variable len : natural;
    procedure put(b : std_logic_vector(7 downto 0); last : boolean) is
    begin
      loop
        wait until rising_edge(clk);
        exit when full = '0';
        wr <= '0'; commit <= '0';
      end loop;
      wr     <= '1';
      wdata  <= b;
      commit <= to_sl(last);
      wait until rising_edge(clk);
      wr <= '0'; commit <= '0';
    end procedure;
  begin
    for id in id0 to id0 + n - 1 loop
      len := f_len(id);
      put(std_logic_vector(to_unsigned(f_type(id), 8)), false);
      put(std_logic_vector(to_unsigned(len / 256, 8)), false);
      put(std_logic_vector(to_unsigned(len mod 256, 8)), false);
      for i in 0 to len - 1 loop
        put(f_byte(id, i), i = len - 1);
      end loop;
    end loop;
  end procedure;

begin

  clk_gen(clk_fast_a, T_FAST_A, stop);
  clk_gen(clk_fast_b, T_FAST_B, stop);

  u_div_a : CLKDIV generic map (DIV_MODE => "4", GSREN => "false")
    port map (HCLKIN => clk_fast_a, RESETN => '1', CALIB => '0', CLKOUT => clk_a);
  u_div_b : CLKDIV generic map (DIV_MODE => "4", GSREN => "false")
    port map (HCLKIN => clk_fast_b, RESETN => '1', CALIB => '0', CLKOUT => clk_b);

  u_a : entity work.tb_link_side
    port map (clk_fast => clk_fast_a, clk_sys => clk_a, rst => rst_a, loopback => a_lb, los => '0',
              h_wr => a_wr, h_wdata => a_wdata, h_commit => a_commit, h_full => a_full,
              h_rd => a_rd, h_rdata => a_rdata, h_rvalid => a_rvalid, h_rempty => a_rempty, h_rudf => a_rudf,
              td_p => a_td_p, td_n => a_td_n, rd_p => a_rd_p, rd_n => a_rd_n,
              link_st => a_st, sync_loss => a_loss, phase => a_phase, nbits => a_nbits,
              shift_up => a_up, shift_dn => a_dn, ev_ok => a_ok, ev_err => a_err, counters => a_cnt);

  u_b : entity work.tb_link_side
    port map (clk_fast => clk_fast_b, clk_sys => clk_b, rst => rst_b, loopback => b_lb, los => b_los,
              h_wr => b_wr, h_wdata => b_wdata, h_commit => b_commit, h_full => b_full,
              h_rd => b_rd, h_rdata => b_rdata, h_rvalid => b_rvalid, h_rempty => b_rempty, h_rudf => b_rudf,
              td_p => b_td_p, td_n => b_td_n, rd_p => b_rd_p, rd_n => b_rd_n,
              link_st => b_st, sync_loss => b_loss, phase => b_phase, nbits => b_nbits,
              shift_up => b_up, shift_dn => b_dn, ev_ok => b_ok, ev_err => b_err, counters => b_cnt);

  ------------------------------------------------------------------------------
  -- Line: delay + jitter per transition, both directions
  ------------------------------------------------------------------------------
  line_ab : process
    variable s1, s2 : positive := 3;
    variable u : real;
  begin
    wait on a_td_p;
    uniform(s1, s2, u);
    b_rd_p <= transport a_td_p after LINE_DLY + (2.0 * u - 1.0) * JIT_NS * 1 ns;
    b_rd_n <= transport not a_td_p after LINE_DLY + (2.0 * u - 1.0) * JIT_NS * 1 ns;
  end process;

  line_ba : process
    variable s1, s2 : positive := 5;
    variable u : real;
  begin
    wait on b_td_p;
    uniform(s1, s2, u);
    a_rd_p <= transport b_td_p after LINE_DLY + (2.0 * u - 1.0) * JIT_NS * 1 ns;
    a_rd_n <= transport not b_td_p after LINE_DLY + (2.0 * u - 1.0) * JIT_NS * 1 ns;
  end process;

  ------------------------------------------------------------------------------
  -- Writers
  ------------------------------------------------------------------------------
  writer_a : process
  begin
    wait until a_go;
    if rst_a = '1' then           -- the host writes only after its reset
      wait until rst_a = '0';
    end if;
    a_busy <= true;
    write_frames(clk_a, a_wr, a_commit, a_wdata, a_full, a_id0, a_n);
    a_busy <= false;
    wait until not a_go;
  end process;

  writer_b : process
  begin
    wait until b_go;
    if rst_b = '1' then           -- the host writes only after its reset
      wait until rst_b = '0';
    end if;
    b_busy <= true;
    write_frames(clk_b, b_wr, b_commit, b_wdata, b_full, b_id0, b_n);
    b_busy <= false;
    wait until not b_go;
  end process;

  ------------------------------------------------------------------------------
  -- Readers
  ------------------------------------------------------------------------------
  a_rd <= not a_rempty;
  b_rd <= not b_rempty;

  reader_a : process (clk_a)
    variable idx, len, id, n, base : natural := 0;
    variable ok : boolean := true;
  begin
    if rising_edge(clk_a) then
      if a_base /= base then
        base := a_base;
        n    := 0;
      end if;
      if a_rvalid = '1' then
        id := base + n;
        case idx is
          when 0 => ok := to_integer(unsigned(a_rdata)) = f_type(id);
          when 1 => len := 256 * to_integer(unsigned(a_rdata));
          when 2 => len := len + to_integer(unsigned(a_rdata));
                    ok := ok and len = f_len(id);
          when others =>
            ok := ok and a_rdata = f_byte(id, idx - 3);
        end case;
        idx := idx + 1;
        if idx >= 3 and idx = 3 + len then
          if ok then a_frames <= a_frames + 1; else a_bad <= a_bad + 1; end if;
          n   := n + 1;
          idx := 0;
        end if;
      end if;
      if a_err = '1' then a_errs <= a_errs + 1; end if;
      if a_rudf = '1' then a_udf <= a_udf + 1; end if;
    end if;
  end process;

  reader_b : process (clk_b)
    variable idx, len, id, n, base : natural := 0;
    variable ok : boolean := true;
  begin
    if rising_edge(clk_b) then
      if b_base /= base then
        base := b_base;
        n    := 0;
      end if;
      if b_rvalid = '1' then
        id := base + n;
        case idx is
          when 0 => ok := to_integer(unsigned(b_rdata)) = f_type(id);
          when 1 => len := 256 * to_integer(unsigned(b_rdata));
          when 2 => len := len + to_integer(unsigned(b_rdata));
                    ok := ok and len = f_len(id);
          when others =>
            ok := ok and b_rdata = f_byte(id, idx - 3);
        end case;
        idx := idx + 1;
        if idx >= 3 and idx = 3 + len then
          if ok then b_frames <= b_frames + 1; else b_bad <= b_bad + 1; end if;
          n   := n + 1;
          idx := 0;
        end if;
      end if;
      if b_err = '1' then b_errs <= b_errs + 1; end if;
      if b_rudf = '1' then b_udf <= b_udf + 1; end if;
      if b_loss = '1' then b_losses <= b_losses + 1; end if;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- Side B CDR statistics in phase 1 (own clock domain)
  ------------------------------------------------------------------------------
  b_stats : process
    variable n_up, n_dn, n1, n3 : natural := 0;
  begin
    wait until b_st = LS_UP;
    while phase_no = 1 loop
      wait until rising_edge(clk_b) or phase_no /= 1;
      exit when phase_no /= 1;
      if b_up = '1' then n_up := n_up + 1; end if;
      if b_dn = '1' then n_dn := n_dn + 1; end if;
      if b_nbits = 3 then n3 := n3 + 1; end if;
      if b_nbits = 1 then n1 := n1 + 1; end if;
    end loop;
    check(n_up > 10 and n_dn <= 2, "phase 1: CDR steps at B (slower stream): up " &
          integer'image(n_up) & ", dn " & integer'image(n_dn));
    check(n1 > 2 and n3 <= 1, "phase 1: 1-bit / 3-bit clocks at B: " &
          integer'image(n1) & " / " & integer'image(n3));
    wait;
  end process;

  ------------------------------------------------------------------------------
  -- Sequencer and checks (on clk_a)
  ------------------------------------------------------------------------------
  process
    variable t0 : time;
    variable a_n_up, a_n_dn, a_n3, a_n1 : natural := 0;
    variable a_losses : natural := 0;

    procedure wait_frames(fa, fb : natural; tmax : time; msg : string) is
      variable t : time := now;
    begin
      while (a_frames + a_bad < fa or b_frames + b_bad < fb) and now - t < tmax loop
        wait until rising_edge(clk_a);
      end loop;
      check(a_frames + a_bad >= fa and b_frames + b_bad >= fb, msg & ": frames arrived in time");
    end procedure;

    procedure wait_up(tmax : time; msg : string) is
      variable t : time := now;
    begin
      while (a_st /= LS_UP or b_st /= LS_UP) and now - t < tmax loop
        wait until rising_edge(clk_a);
      end loop;
      check(a_st = LS_UP and b_st = LS_UP, msg & ": both ends UP");
    end procedure;

  begin
    ---------------------------------------------------------------- phase 1
    phase_no <= 1;
    a_base <= 1000;                    -- A receives B's frames
    b_base <= 0;
    a_id0 <= 0;    a_n <= N_FR;
    b_id0 <= 1000; b_n <= N_FR;
    a_go  <= true; b_go <= true;       -- written before the link is up
    wait until rising_edge(clk_a);
    rst_a <= '0';
    for i in 1 to 3 loop
      wait until rising_edge(clk_b);
    end loop;
    rst_b <= '0';

    t0 := now;
    -- B receiver held in DOWN by LOS: B transmits idle /R/, A reaches only
    -- SYNC and must not start frames (they would be lost)
    wait for LOS_TIME - 2 us;
    check(a_st = LS_SYNC, "phase 1: A in SYNC while the B receiver is down");
    check(b_st = LS_DOWN, "phase 1: B DOWN during LOS");
    check_equal(to_integer(a_cnt(CNT_FRAMES_TX)) + to_integer(b_cnt(CNT_FRAMES_TX)), 0,
                "phase 1: no frame sent before UP");
    wait for 2 us;
    b_los <= '0';
    wait_up(20 us, "phase 1");
    report "link UP after " & time'image(now - t0);

    while a_frames + a_bad < N_FR or b_frames + b_bad < N_FR loop
      wait until rising_edge(clk_a);
      exit when now - t0 > 6 ms;
      if a_loss = '1' then a_losses := a_losses + 1; end if;
      if a_up = '1' then a_n_up := a_n_up + 1; end if;
      if a_dn = '1' then a_n_dn := a_n_dn + 1; end if;
      if a_nbits = 3 then a_n3 := a_n3 + 1; end if;
      if a_nbits = 1 then a_n1 := a_n1 + 1; end if;
    end loop;
    check_equal(a_frames, N_FR, "phase 1: frames received at A");
    check_equal(b_frames, N_FR, "phase 1: frames received at B");
    check_equal(a_losses, 0, "phase 1: loss of sync at A after UP");
    check(a_n_dn > 10 and a_n_up <= 2, "phase 1: CDR steps at A (faster stream): up " &
          integer'image(a_n_up) & ", dn " & integer'image(a_n_dn));
    check(a_n3 > 2 and a_n1 <= 1, "phase 1: 3-bit / 1-bit clocks at A: " &
          integer'image(a_n3) & " / " & integer'image(a_n1));
    report "phase 1 done at " & time'image(now) & ", CDR steps at A " &
           integer'image(a_n_dn);
    a_go <= false; b_go <= false;

    ---------------------------------------------------------------- phase 2
    phase_no <= 2;
    a_lb   <= LB_NEAR;
    a_base <= N_FR;                    -- A receives its own frames 32..35
    -- B keeps expecting A's ids: 32.. follow its first 32 frames
    for i in 1 to 10 loop
      wait until rising_edge(clk_a);
    end loop;
    wait_up(20 us, "phase 2 (near-end loopback at A)");
    a_id0 <= N_FR; a_n <= N_LB;
    a_go  <= true;
    wait_frames(N_FR + N_LB, N_FR + N_LB, 1 ms, "phase 2");
    check_equal(a_frames, N_FR + N_LB, "phase 2: own frames received at A");
    check_equal(b_frames, N_FR + N_LB, "phase 2: frames received at B");
    a_go <= false;

    ---------------------------------------------------------------- phase 3
    phase_no <= 3;
    a_lb   <= LB_NONE;
    a_base <= 1000 + N_FR;             -- A receives B's frames again
    for i in 1 to 10 loop
      wait until rising_edge(clk_a);
    end loop;
    wait_up(20 us, "phase 3 (normal operation)");
    b_id0 <= 1000 + N_FR; b_n <= N_LB;
    b_go  <= true;
    wait_frames(N_FR + 2 * N_LB, N_FR + N_LB, 1 ms, "phase 3");
    check_equal(a_frames, N_FR + 2 * N_LB, "phase 3: frames received at A");
    b_go <= false;
    for i in 1 to 50 loop
      wait until rising_edge(clk_a);
    end loop;

    ---------------------------------------------------------------- final
    check_equal(a_bad, 0, "wrong frames at A");
    check_equal(b_bad, 0, "wrong frames at B");
    check_equal(a_errs, 0, "deframer error events at A");
    check_equal(b_errs, 0, "deframer error events at B");
    check_equal(a_udf + b_udf, 0, "RX FIFO underflow");
    check_equal(b_losses, 0, "loss of sync at B");
    check_equal(to_integer(a_cnt(CNT_FRAMES_TX)), N_FR + N_LB, "counter FRAMES_TX at A");
    check_equal(to_integer(b_cnt(CNT_FRAMES_TX)), N_FR + N_LB, "counter FRAMES_TX at B");
    check_equal(to_integer(a_cnt(CNT_FRAMES_RX)), N_FR + 2 * N_LB, "counter FRAMES_RX at A");
    check_equal(to_integer(b_cnt(CNT_FRAMES_RX)), N_FR + N_LB, "counter FRAMES_RX at B");
    for i in CNT_CRC_ERR to CNT_RX_OVF loop
      check_equal(to_integer(a_cnt(i)) + to_integer(b_cnt(i)), 0,
                  "error counter " & integer'image(i));
    end loop;
    check_equal(to_integer(b_cnt(CNT_SYNC_LOSS)), 0, "counter SYNC_LOSS at B");
    report "A: frames " & integer'image(a_frames) & ", B: frames " & integer'image(b_frames) &
           ", A SYNC_LOSS " & integer'image(to_integer(a_cnt(CNT_SYNC_LOSS))) &
           ", A CODE_ERR " & integer'image(to_integer(a_cnt(CNT_CODE_ERR))) &
           ", end " & time'image(now);
    stop <= true;
    tb_finish("tb_link_loopback");
    wait;
  end process;

end architecture sim;
