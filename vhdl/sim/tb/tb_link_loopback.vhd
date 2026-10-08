--------------------------------------------------------------------------------
-- tb_link_loopback
--
-- Full link between two bridge ends at bit level, with the Gowin primitive
-- simulation models (library gw1n) and independent clocks:
--
--   host -> TX FIFO -> tx_framer -> enc_8b10b -> tx_gearbox -> tx_phy
--        -> line (delay + jitter) ->
--   rx_phy -> cdr_os4x8 -> comma_align -> dec_8b10b -> rx_deframer
--        -> RX FIFO -> host                      (both directions)
--
-- Each side: clk_fast from its own oscillator, clk_sys from the CLKDIV
-- model (DIV_MODE "4"). Side B runs 200 ppm faster than side A
-- (clk_fast 4.999 ns vs 5.000 ns). The line adds a 5 ns delay and an
-- independent random jitter of +/-0.2 UI (+/-2 ns) to every transition.
--
-- The host side of the FIFOs runs on clk_sys of the same end (the clock
-- domain crossing of async_fifo is verified by tb_async_fifo).
--
-- Sequence: reset; wait until both receivers are synchronized; each host
-- writes N_FR frames (id-dependent type, length 1..400, payload); each
-- reader checks the frames of the other end.
--
-- Checks:
--   1. both comma_align instances synchronized within 10 us, no loss of
--      sync afterwards;
--   2. N_FR frames received at each end, all in order and intact;
--   3. no error event at either deframer (CRC, code, length, framing,
--      overflow), no RX FIFO underflow by the readers;
--   4. CDR frequency tracking: at side A (receiving the faster stream)
--      shift_dn steps, at side B shift_up steps (more than 10 each, at most
--      2 in the opposite direction while the phase settles after sync);
--      3-bit / 1-bit clocks accordingly.
--
-- Waveform: per side clk_sys, line signals, CDR phase, sync, deframer
-- events and FIFO activity; see doc/vhdl/phy.md.
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
    sync      : out std_logic;
    sync_loss : out std_logic;
    phase     : out unsigned(1 downto 0);
    nbits     : out unsigned(1 downto 0);
    shift_up  : out std_logic;
    shift_dn  : out std_logic;
    ev_ok     : out std_logic;
    ev_err    : out std_logic           -- any deframer error event
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
  signal samples   : std_logic_vector(7 downto 0);
  signal bits      : std_logic_vector(2 downto 0);
  signal nb        : unsigned(1 downto 0);
  signal sym       : std_logic_vector(9 downto 0);
  signal sym_valid : std_logic;
  signal sync_i    : std_logic;
  signal dv, dk, dce, dde, derr : std_logic;
  signal dd        : std_logic_vector(7 downto 0);
  signal xoff_remote, xoff_local : std_logic;
  signal fw, fc, fa, fovf : std_logic;
  signal fwd       : std_logic_vector(7 downto 0);
  signal rfree     : unsigned(13 downto 0);
  signal e_crc, e_code, e_len, e_fr, e_ovf : std_logic;
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
              rx_ready => sync_i, xoff_local => xoff_local, xoff_remote => xoff_remote,
              busy => open, frame_sent => open, len_err => open);

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
              rd_p => rd_p, rd_n => rd_n, samples => samples);

  u_cdr : entity work.cdr_os4x8
    port map (clk => clk_sys, rst => rst, samples => samples, bits => bits, nbits => nb,
              phase => phase, shift_up => shift_up, shift_dn => shift_dn, activity => open);

  u_al : entity work.comma_align
    port map (clk => clk_sys, rst => rst, restart => '0', in_bits => bits, in_n => nb,
              sym => sym, sym_valid => sym_valid, sym_comma => open,
              dec_valid => dv, dec_err => derr,
              sync => sync_i, ev_realign => open, ev_sync_loss => sync_loss);

  u_dec : entity work.dec_8b10b
    port map (clk => clk_sys, rst => rst, en => sym_valid, code => sym,
              data => dd, k => dk, valid => dv, code_err => dce, disp_err => dde, rd => open);
  derr <= dce or dde;

  u_df : entity work.rx_deframer
    port map (clk => clk_sys, rst => rst, sync => sync_i, char_valid => dv,
              char_data => dd, char_k => dk, code_err => dce, disp_err => dde,
              fifo_wr => fw, fifo_data => fwd, fifo_commit => fc, fifo_abort => fa,
              fifo_free => rfree, fifo_ovf => fovf,
              xoff_remote => xoff_remote, remote_ready => open, xoff_local => xoff_local,
              ev_frame_ok => ev_ok, ev_crc_err => e_crc, ev_code_err => e_code,
              ev_len_err => e_len, ev_framing => e_fr, ev_ovf => e_ovf, busy => open);

  u_rf : entity work.async_fifo
    generic map (DATA_W => 8, ADDR_W => 13, COMMIT_MODE => true)
    port map (wr_clk => clk_sys, wr_rst => rst, wr_en => fw, wr_data => fwd,
              wr_commit => fc, wr_abort => fa, full => open, wr_free => rfree, wr_ovf => fovf,
              rd_clk => clk_sys, rd_rst => rst, rd_en => h_rd, rd_data => h_rdata,
              rd_valid => h_rvalid, empty => h_rempty, rd_level => open, rd_udf => h_rudf);

  ev_err <= e_crc or e_code or e_len or e_fr or e_ovf;
  sync   <= sync_i;
  nbits  <= nb;
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
  constant LINE_DLY : time := 5 ns;
  constant JIT_NS   : real := 2.0;           -- +/-0.2 UI
  constant T_END    : time := 6 ms;

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

  signal a_wr, a_commit, a_full, a_rd, a_rvalid, a_rempty, a_rudf : std_logic := '0';
  signal b_wr, b_commit, b_full, b_rd, b_rvalid, b_rempty, b_rudf : std_logic := '0';
  signal a_wdata, a_rdata, b_wdata, b_rdata : std_logic_vector(7 downto 0) := (others => '0');
  signal a_td_p, a_td_n, b_td_p, b_td_n : std_logic;
  signal a_rd_p, b_rd_p : std_logic := '0';
  signal a_rd_n, b_rd_n : std_logic := '1';
  signal a_sync, b_sync, a_loss, b_loss : std_logic;
  signal a_phase, b_phase, a_nbits, b_nbits : unsigned(1 downto 0);
  signal a_up, a_dn, b_up, b_dn, a_ok, b_ok, a_err, b_err : std_logic;

  signal both_sync  : boolean := false;
  signal a_frames, b_frames : natural := 0;     -- frames received correctly
  signal a_bad, b_bad       : natural := 0;     -- frames received wrong

  -- frame writer: N_FR frames with ids id0, id0 + 1, ...
  procedure write_frames(signal clk : in std_logic; signal wr, commit : out std_logic;
                         signal wdata : out std_logic_vector(7 downto 0);
                         signal full : in std_logic; id0 : natural) is
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
    for id in id0 to id0 + N_FR - 1 loop
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
    port map (clk_fast => clk_fast_a, clk_sys => clk_a, rst => rst_a,
              h_wr => a_wr, h_wdata => a_wdata, h_commit => a_commit, h_full => a_full,
              h_rd => a_rd, h_rdata => a_rdata, h_rvalid => a_rvalid, h_rempty => a_rempty, h_rudf => a_rudf,
              td_p => a_td_p, td_n => a_td_n, rd_p => a_rd_p, rd_n => a_rd_n,
              sync => a_sync, sync_loss => a_loss, phase => a_phase, nbits => a_nbits,
              shift_up => a_up, shift_dn => a_dn, ev_ok => a_ok, ev_err => a_err);

  u_b : entity work.tb_link_side
    port map (clk_fast => clk_fast_b, clk_sys => clk_b, rst => rst_b,
              h_wr => b_wr, h_wdata => b_wdata, h_commit => b_commit, h_full => b_full,
              h_rd => b_rd, h_rdata => b_rdata, h_rvalid => b_rvalid, h_rempty => b_rempty, h_rudf => b_rudf,
              td_p => b_td_p, td_n => b_td_n, rd_p => b_rd_p, rd_n => b_rd_n,
              sync => b_sync, sync_loss => b_loss, phase => b_phase, nbits => b_nbits,
              shift_up => b_up, shift_dn => b_dn, ev_ok => b_ok, ev_err => b_err);

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
  -- Resets (each side in its own domain)
  ------------------------------------------------------------------------------
  process
  begin
    for i in 1 to 6 loop
      wait until rising_edge(clk_a);
    end loop;
    rst_a <= '0';
    wait;
  end process;

  process
  begin
    for i in 1 to 9 loop
      wait until rising_edge(clk_b);
    end loop;
    rst_b <= '0';
    wait;
  end process;

  ------------------------------------------------------------------------------
  -- Writers
  ------------------------------------------------------------------------------
  writer_a : process
  begin
    wait until both_sync;
    write_frames(clk_a, a_wr, a_commit, a_wdata, a_full, 0);
    wait;
  end process;

  writer_b : process
  begin
    wait until both_sync;
    write_frames(clk_b, b_wr, b_commit, b_wdata, b_full, 1000);
    wait;
  end process;

  ------------------------------------------------------------------------------
  -- Readers: frames of the other end
  ------------------------------------------------------------------------------
  a_rd <= not a_rempty;
  b_rd <= not b_rempty;

  reader_a : process (clk_a)
    variable idx, len, id : natural := 0;
    variable ok : boolean := true;
  begin
    if rising_edge(clk_a) then
      if a_rvalid = '1' then
        id := 1000 + a_frames + a_bad;
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
          idx := 0;
        end if;
      end if;
    end if;
  end process;

  reader_b : process (clk_b)
    variable idx, len, id : natural := 0;
    variable ok : boolean := true;
  begin
    if rising_edge(clk_b) then
      if b_rvalid = '1' then
        id := b_frames + b_bad;
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
          idx := 0;
        end if;
      end if;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- Monitor and checks
  ------------------------------------------------------------------------------
  process
    variable t0 : time;
    variable n_loss, n_err, n_udf : natural := 0;
    variable a_n_up, a_n_dn, b_n_up, b_n_dn : natural := 0;
    variable a_n3, a_n1, b_n3, b_n1 : natural := 0;
  begin
    wait until rst_a = '0' and rst_b = '0';
    t0 := now;
    while (a_sync = '0' or b_sync = '0') and now - t0 < 10 us loop
      wait until rising_edge(clk_a);
    end loop;
    check(a_sync = '1' and b_sync = '1', "both receivers synchronized within 10 us");
    report "sync after " & time'image(now - t0);
    both_sync <= true;

    -- count events until all frames arrived (sampled on clk_a; B events
    -- are one-cycle pulses of clk_b, counted by the B-side process below)
    while (a_frames + a_bad < N_FR or b_frames + b_bad < N_FR) and now < T_END loop
      wait until rising_edge(clk_a);
      if a_loss = '1' then n_loss := n_loss + 1; end if;
      if a_err = '1' then n_err := n_err + 1; end if;
      if a_rudf = '1' then n_udf := n_udf + 1; end if;
      if a_up = '1' then a_n_up := a_n_up + 1; end if;
      if a_dn = '1' then a_n_dn := a_n_dn + 1; end if;
      if a_nbits = 3 then a_n3 := a_n3 + 1; end if;
      if a_nbits = 1 then a_n1 := a_n1 + 1; end if;
    end loop;
    for i in 1 to 20 loop
      wait until rising_edge(clk_a);
    end loop;

    check_equal(a_frames, N_FR, "frames received at A");
    check_equal(b_frames, N_FR, "frames received at B");
    check_equal(a_bad, 0, "wrong frames at A");
    check_equal(b_bad, 0, "wrong frames at B");
    check_equal(n_loss, 0, "loss of sync at A");
    check_equal(n_err, 0, "deframer error events at A");
    check_equal(n_udf, 0, "RX FIFO underflow at A");
    check(a_n_dn > 10 and a_n_up <= 2, "CDR steps at A (faster stream): up " &
          integer'image(a_n_up) & ", dn " & integer'image(a_n_dn));
    check(a_n3 > 2 and a_n1 <= 1, "3-bit / 1-bit clocks at A: " &
          integer'image(a_n3) & " / " & integer'image(a_n1));
    report "A: frames " & integer'image(a_frames) & ", CDR steps up/dn " &
           integer'image(a_n_up) & "/" & integer'image(a_n_dn) & ", end " & time'image(now);
    stop <= true;
    wait;
  end process;

  -- side B event counters (in its own clock domain)
  process
    variable n_loss, n_err, n_udf : natural := 0;
    variable n_up, n_dn, n1, n3 : natural := 0;
  begin
    wait until both_sync;
    while not stop loop
      wait until rising_edge(clk_b) or stop;
      exit when stop;
      if b_loss = '1' then n_loss := n_loss + 1; end if;
      if b_err = '1' then n_err := n_err + 1; end if;
      if b_rudf = '1' then n_udf := n_udf + 1; end if;
      if b_up = '1' then n_up := n_up + 1; end if;
      if b_dn = '1' then n_dn := n_dn + 1; end if;
      if b_nbits = 3 then n3 := n3 + 1; end if;
      if b_nbits = 1 then n1 := n1 + 1; end if;
    end loop;
    check_equal(n_loss, 0, "loss of sync at B");
    check_equal(n_err, 0, "deframer error events at B");
    check_equal(n_udf, 0, "RX FIFO underflow at B");
    check(n_up > 10 and n_dn <= 2, "CDR steps at B (slower stream): up " &
          integer'image(n_up) & ", dn " & integer'image(n_dn));
    check(n1 > 2 and n3 <= 1, "1-bit / 3-bit clocks at B: " &
          integer'image(n1) & " / " & integer'image(n3));
    report "B: frames " & integer'image(b_frames) & ", CDR steps up/dn " &
           integer'image(n_up) & "/" & integer'image(n_dn);
    tb_finish("tb_link_loopback");
    wait;
  end process;

end architecture sim;
