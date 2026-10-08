--------------------------------------------------------------------------------
-- tb_link_frames
--
-- Testbench for tx_framer and rx_deframer: full-duplex link at character
-- level (no serializer / CDR), with real FIFOs and 8b/10b coding:
--
--   side A: TX FIFO -> tx_framer -> enc_8b10b --(channel A->B)--> side B
--   side B: dec_8b10b -> rx_deframer -> RX FIFO (8 KiB) -> reader
--   reverse direction carries B's idle pairs (XON/XOFF) back to side A.
--
-- One character per 5 clock cycles (100 Mbaud at clk_sys = 50 MHz, ADR 0007).
--
-- Model: payload, type and length of frame <id> are pure functions of id;
-- ids of frames that must arrive are queued, the reader compares every
-- received frame with the head of the queue.
--
-- Phases and checks:
--   1. 20 frames, length 1..300: all delivered intact and in order.
--   2. 6 frames with one bit flipped in one symbol of the frame: each is
--      dropped with exactly one error event (code/disparity, CRC, length or
--      framing); the frames around them are delivered.
--   2b. 3 frames with a wrong byte carried by a valid symbol (payload, CRC0,
--      TYPE): each dropped with ev_crc_err.
--   3. LEN = 0 and LEN = 1025 written by the host: both rejected with
--      ev_len_err (framer flags len_err for 1025); the next frame delivered.
--   4. Character sync lost on side B in the middle of a frame: the frame is
--      dropped, later frames delivered.
--   4b. Side B receiver not ready (idle /R/, ADR 0008): side A sees
--      remote_ready = '0' and XOFF and does not start a frame for 2000
--      cycles; after B becomes ready the frame is delivered.
--   5. Flow control: reader on side B stopped while 16 frames of 1000 bytes
--      are sent (twice the RX FIFO size). Side B must send XOFF, side A must
--      pause for at least 10000 cycles; no overflow (ev_ovf = 0); after the reader resumes all frames
--      are delivered and XOFF is released.
--   6. Final: every expected frame received, event counters as expected,
--      no frame delivered twice or out of order.
--
-- Waveform: char stream A (char_en, a_cd, a_ck), channel symbols, B deframer
-- state and events, B RX FIFO level, XOFF signals; see doc/vhdl/framing.md.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library work;
use work.tb_pkg.all;
use work.bridge_pkg.all;

entity tb_link_frames is
end entity tb_link_frames;

architecture sim of tb_link_frames is

  constant T_CLK   : time := 20 ns;          -- clk_sys = 50 MHz (ADR 0007)
  constant MAX_LEN : positive := 1024;

  -- frame content as functions of the frame id
  function f_type(id : natural) return natural is
  begin
    return (id * 29 + 16) mod 256;
  end function;
  function f_byte(id, i : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned((id * 7 + i * 13 + i / 256) mod 256, 8));
  end function;

  -- expected frames: queue of (id, len)
  type t_q is protected
    procedure push(id, len : natural);
    procedure pop(id, len : out natural);
    impure function size return natural;
  end protected t_q;
  type t_q is protected body
    type t_arr is array (0 to 255) of natural;
    variable ids, lens : t_arr;
    variable head, cnt : natural := 0;
    procedure push(id, len : natural) is
    begin
      assert cnt < 256 report "expected-frame queue overflow" severity failure;
      ids((head + cnt) mod 256) := id;
      lens((head + cnt) mod 256) := len;
      cnt := cnt + 1;
    end procedure;
    procedure pop(id, len : out natural) is
    begin
      assert cnt > 0 report "expected-frame queue underflow" severity failure;
      id := ids(head); len := lens(head);
      head := (head + 1) mod 256;
      cnt := cnt - 1;
    end procedure;
    impure function size return natural is
    begin
      return cnt;
    end function;
  end protected body t_q;
  shared variable expq : t_q;

  signal clk     : std_logic := '0';
  signal stop    : boolean := false;
  signal rst     : std_logic := '1';
  signal char_en : std_logic := '0';

  -- side A transmit path
  signal a_tw, a_tc    : std_logic := '0';
  signal a_twd         : std_logic_vector(7 downto 0) := (others => '0');
  signal a_tfull       : std_logic;
  signal a_tf_rd, a_tf_valid, a_tf_empty : std_logic;
  signal a_tf_data     : std_logic_vector(7 downto 0);
  signal a_cd          : std_logic_vector(7 downto 0);
  signal a_ck          : std_logic;
  signal a_code        : std_logic_vector(9 downto 0);
  signal a_cvalid      : std_logic;
  signal a_busy, a_sent, a_lenerr : std_logic;

  -- side A receive path (reverse direction, idles from B)
  signal a_dcode       : std_logic_vector(9 downto 0);
  signal a_dv, a_dk, a_dce, a_dde : std_logic;
  signal a_dd          : std_logic_vector(7 downto 0);
  signal a_xoff_remote, a_xoff_local : std_logic;
  signal a_rfree       : unsigned(13 downto 0);

  -- side B transmit path (idles only)
  signal b_cd          : std_logic_vector(7 downto 0);
  signal b_ck          : std_logic;
  signal b_code        : std_logic_vector(9 downto 0);
  signal b_cvalid      : std_logic;
  signal b_tf_rd, b_tf_valid, b_tf_empty : std_logic;
  signal b_tf_data     : std_logic_vector(7 downto 0);

  -- side B receive path
  signal b_dcode       : std_logic_vector(9 downto 0);
  signal b_dv, b_dk, b_dce, b_dde : std_logic;
  signal b_dd          : std_logic_vector(7 downto 0);
  signal b_sync        : std_logic := '1';
  signal b_rx_ready    : std_logic := '1';      -- B receiver enabled (tx_framer rx_ready)
  signal b_rdy_eff     : std_logic;
  signal a_remote_ready : std_logic;
  signal b_fw, b_fc, b_fa, b_fovf : std_logic;
  signal b_fwd         : std_logic_vector(7 downto 0);
  signal b_rfree       : unsigned(13 downto 0);
  signal b_xoff_remote, b_xoff_local : std_logic;
  signal b_rd, b_rvalid, b_rempty : std_logic;
  signal b_rdata       : std_logic_vector(7 downto 0);
  signal b_rlevel      : unsigned(13 downto 0);
  signal ev_ok, ev_crc, ev_code, ev_len, ev_frm, ev_ovf, b_busy : std_logic;

  -- channel corruption A->B
  signal corrupt_arm   : boolean := false;
  signal corrupt_pos   : natural := 0;         -- symbol index after K27.7
  signal corrupt_bit   : natural := 0;
  signal corrupt_mask  : std_logic_vector(9 downto 0) := (others => '0');
  -- character-level corruption (before the encoder): valid symbol, wrong byte
  signal cc_arm        : boolean := false;
  signal cc_pos        : natural := 0;
  signal char_mask     : std_logic_vector(7 downto 0) := (others => '0');
  signal a_cd_enc      : std_logic_vector(7 downto 0);

  -- reader control and statistics
  type t_pos is array (0 to 5) of natural;
  constant CORRUPT_AT : t_pos := (1, 3, 10, 30, 44, 46);  -- TYPE, LEN_L, payload x2, CRC0, CRC2
  type t_pos3 is array (0 to 2) of natural;
  constant CORRUPT_CHR : t_pos3 := (20, 44, 1);            -- payload, CRC0, TYPE
  signal reader_on     : boolean := true;
  signal p5_start      : boolean := false;     -- phase 5: hold the reader
  signal p5_resumed    : boolean := false;
  signal n_rx_frames   : natural := 0;
  signal cnt_ok, cnt_crc, cnt_code, cnt_len, cnt_frm, cnt_ovf, cnt_lenerr_tx : natural := 0;
  signal xoff_seen_b, xoff_seen_a : boolean := false;

begin

  clk_gen(clk, T_CLK, stop);

  -- one character every 5 cycles (10 bits at 2 bits per clk_sys cycle)
  process (clk)
    variable n : natural range 0 to 4 := 0;
  begin
    if rising_edge(clk) then
      char_en <= '0';
      if n = 4 then
        n := 0;
        char_en <= '1';
      else
        n := n + 1;
      end if;
    end if;
  end process;

  ------------------------------------------------------------------ side A TX
  a_txfifo : entity work.async_fifo
    generic map (DATA_W => 8, ADDR_W => 12, COMMIT_MODE => true)
    port map (wr_clk => clk, wr_rst => rst, wr_en => a_tw, wr_data => a_twd,
              wr_commit => a_tc, wr_abort => '0', full => a_tfull, wr_free => open,
              wr_ovf => open, rd_clk => clk, rd_rst => rst, rd_en => a_tf_rd,
              rd_data => a_tf_data, rd_valid => a_tf_valid, empty => a_tf_empty,
              rd_level => open, rd_udf => open);

  a_framer : entity work.tx_framer
    generic map (MAX_LEN => MAX_LEN)
    port map (clk => clk, rst => rst, char_en => char_en, char_data => a_cd, char_k => a_ck,
              fifo_empty => a_tf_empty, fifo_rd => a_tf_rd, fifo_data => a_tf_data,
              fifo_valid => a_tf_valid, rx_ready => '1', xoff_local => a_xoff_local,
              xoff_remote => a_xoff_remote, busy => a_busy, frame_sent => a_sent,
              len_err => a_lenerr);

  a_cd_enc <= a_cd xor char_mask;

  a_enc : entity work.enc_8b10b
    port map (clk => clk, rst => rst, en => char_en, data => a_cd_enc, k => a_ck,
              code => a_code, valid => a_cvalid, k_err => open, rd => open);

  ------------------------------------------------------------------ side B TX (idles)
  b_tf_empty <= '1';
  b_tf_valid <= '0';
  b_tf_data  <= (others => '0');

  b_rdy_eff <= b_rx_ready and b_sync;

  b_framer : entity work.tx_framer
    generic map (MAX_LEN => MAX_LEN)
    port map (clk => clk, rst => rst, char_en => char_en, char_data => b_cd, char_k => b_ck,
              fifo_empty => b_tf_empty, fifo_rd => b_tf_rd, fifo_data => b_tf_data,
              fifo_valid => b_tf_valid, rx_ready => b_rdy_eff, xoff_local => b_xoff_local,
              xoff_remote => b_xoff_remote, busy => open, frame_sent => open,
              len_err => open);

  b_enc : entity work.enc_8b10b
    port map (clk => clk, rst => rst, en => char_en, data => b_cd, k => b_ck,
              code => b_code, valid => b_cvalid, k_err => open, rd => open);

  ------------------------------------------------------------------ channels
  b_dcode <= a_code xor corrupt_mask;
  a_dcode <= b_code;

  ------------------------------------------------------------------ side B RX
  b_dec : entity work.dec_8b10b
    port map (clk => clk, rst => rst, en => a_cvalid, code => b_dcode,
              data => b_dd, k => b_dk, valid => b_dv, code_err => b_dce,
              disp_err => b_dde, rd => open);

  b_deframer : entity work.rx_deframer
    generic map (MAX_LEN => MAX_LEN, FREE_W => 14)
    port map (clk => clk, rst => rst, sync => b_sync, char_valid => b_dv,
              char_data => b_dd, char_k => b_dk, code_err => b_dce, disp_err => b_dde,
              fifo_wr => b_fw, fifo_data => b_fwd, fifo_commit => b_fc, fifo_abort => b_fa,
              fifo_free => b_rfree, fifo_ovf => b_fovf, xoff_remote => b_xoff_remote,
              remote_ready => open, xoff_local => b_xoff_local, ev_frame_ok => ev_ok, ev_crc_err => ev_crc,
              ev_code_err => ev_code, ev_len_err => ev_len, ev_framing => ev_frm,
              ev_ovf => ev_ovf, busy => b_busy);

  b_rxfifo : entity work.async_fifo
    generic map (DATA_W => 8, ADDR_W => 13, COMMIT_MODE => true)
    port map (wr_clk => clk, wr_rst => rst, wr_en => b_fw, wr_data => b_fwd,
              wr_commit => b_fc, wr_abort => b_fa, full => open, wr_free => b_rfree,
              wr_ovf => b_fovf, rd_clk => clk, rd_rst => rst, rd_en => b_rd,
              rd_data => b_rdata, rd_valid => b_rvalid, empty => b_rempty,
              rd_level => b_rlevel, rd_udf => open);

  ------------------------------------------------------------------ side A RX (reverse)
  a_dec : entity work.dec_8b10b
    port map (clk => clk, rst => rst, en => b_cvalid, code => a_dcode,
              data => a_dd, k => a_dk, valid => a_dv, code_err => a_dce,
              disp_err => a_dde, rd => open);

  a_rfree <= to_unsigned(8192, 14);   -- side A receives no frames in this test

  a_deframer : entity work.rx_deframer
    generic map (MAX_LEN => MAX_LEN, FREE_W => 14)
    port map (clk => clk, rst => rst, sync => '1', char_valid => a_dv,
              char_data => a_dd, char_k => a_dk, code_err => a_dce, disp_err => a_dde,
              fifo_wr => open, fifo_data => open, fifo_commit => open, fifo_abort => open,
              fifo_free => a_rfree, fifo_ovf => '0', xoff_remote => a_xoff_remote,
              remote_ready => a_remote_ready, xoff_local => a_xoff_local, ev_frame_ok => open, ev_crc_err => open,
              ev_code_err => open, ev_len_err => open, ev_framing => open,
              ev_ovf => open, busy => open);

  ------------------------------------------------------------------ corruption
  -- Flip bit corrupt_bit of the symbol corrupt_pos characters after K27.7
  -- (1 = TYPE, 2 = LEN_H, ...), once per arming.
  process (clk)
    variable counting : boolean := false;
    variable cnt      : natural := 0;
    variable hit      : boolean := false;
  begin
    if rising_edge(clk) then
      corrupt_mask <= (others => '0');
      if hit and a_cvalid = '0' then
        null;
      end if;
      if char_en = '1' then
        if corrupt_arm and not counting and a_ck = '1' and a_cd = K27_7 then
          counting := true;
          cnt := 0;
        elsif counting then
          cnt := cnt + 1;
          if cnt = corrupt_pos then
            -- the encoder outputs this character's symbol in the next cycle
            corrupt_mask(corrupt_bit) <= '1';
            counting := false;
          end if;
        end if;
      end if;
      if not corrupt_arm then
        counting := false;
      end if;
    end if;
  end process;

  -- XOR the byte of the character cc_pos positions after K27.7 with 0x5A,
  -- once per arming (the encoder takes it at that char_en)
  process (clk)
    variable counting : boolean := false;
    variable cnt      : natural := 0;
  begin
    if rising_edge(clk) then
      if char_en = '1' then
        if char_mask /= x"00" then
          char_mask <= x"00";               -- consumed at this edge
        end if;
        if cc_arm and not counting and a_ck = '1' and a_cd = K27_7 then
          counting := true;
          cnt := 0;
          if cc_pos = 1 then
            char_mask <= x"5A"; counting := false;
          end if;
        elsif counting then
          cnt := cnt + 1;
          if cnt = cc_pos - 1 then
            char_mask <= x"5A"; counting := false;
          end if;
        end if;
      end if;
      if not cc_arm then
        counting := false;
      end if;
    end if;
  end process;

  ------------------------------------------------------------------ statistics
  process (clk)
  begin
    if rising_edge(clk) then
      if ev_ok = '1' then cnt_ok <= cnt_ok + 1; end if;
      if ev_crc = '1' then cnt_crc <= cnt_crc + 1; end if;
      if ev_code = '1' then cnt_code <= cnt_code + 1; end if;
      if ev_len = '1' then cnt_len <= cnt_len + 1; end if;
      if ev_frm = '1' then cnt_frm <= cnt_frm + 1; end if;
      if ev_ovf = '1' then cnt_ovf <= cnt_ovf + 1; end if;
      if a_lenerr = '1' then cnt_lenerr_tx <= cnt_lenerr_tx + 1; end if;
      if b_xoff_local = '1' then xoff_seen_b <= true; end if;
      if a_xoff_remote = '1' and rst = '0' and n_rx_frames > 0 then xoff_seen_a <= true; end if;
    end if;
  end process;

  ------------------------------------------------------------------ reader B
  reader : process (clk)
    type t_rs is (R_TYPE, R_LENH, R_LENL, R_PAY);
    variable rs      : t_rs := R_TYPE;
    variable id, len : natural;
    variable rlen    : natural;
    variable idx     : natural;
    variable typ     : std_logic_vector(7 downto 0);
    variable lenh    : std_logic_vector(7 downto 0);
    variable bad     : boolean;
  begin
    if rising_edge(clk) then
      b_rd <= '0';
      if b_rvalid = '1' then
        case rs is
          when R_TYPE =>
            typ := b_rdata; rs := R_LENH; bad := false;
          when R_LENH =>
            lenh := b_rdata; rs := R_LENL;
          when R_LENL =>
            rlen := to_integer(unsigned(lenh) & unsigned(b_rdata));
            if expq.size = 0 then
              check(false, "frame received but none expected");
              id := 0; len := rlen;
            else
              expq.pop(id, len);
            end if;
            check_equal(rlen, len, "frame " & integer'image(id) & " length");
            check_equal(to_integer(unsigned(typ)), f_type(id), "frame " & integer'image(id) & " type");
            idx := 0;
            rs := R_PAY;
          when R_PAY =>
            if b_rdata /= f_byte(id, idx) then
              bad := true;
            end if;
            idx := idx + 1;
            if idx = rlen then
              check(not bad, "frame " & integer'image(id) & " payload");
              n_rx_frames <= n_rx_frames + 1;
              rs := R_TYPE;
            end if;
        end case;
      end if;
      if reader_on and b_rempty = '0' then
        b_rd <= '1';
      end if;
    end if;
  end process;

  ------------------------------------------------------------------ reader control (phase 5)
  -- Holds the reader while side B's RX FIFO fills, verifies that side A is
  -- paused by XOFF for 10000 cycles (200 us), then resumes the reader.
  reader_ctl : process
  begin
    reader_on <= true;
    wait until p5_start;
    reader_on <= false;
    for i in 1 to 300000 loop
      wait until rising_edge(clk);
      exit when a_xoff_remote = '1' and a_busy = '0' and a_tf_empty = '0';
    end loop;
    check_equal(b_xoff_local, '1', "phase 5: side B requests XOFF");
    check_equal(a_xoff_remote, '1', "phase 5: side A sees XOFF");
    check(a_tf_empty = '0', "phase 5: side A holds frames back");
    for i in 1 to 10000 loop
      wait until rising_edge(clk);
      if a_busy = '1' then
        check(false, "phase 5: side A started a frame during XOFF");
        exit;
      end if;
    end loop;
    reader_on  <= true;
    p5_resumed <= true;
    wait;
  end process;

  ------------------------------------------------------------------ writer A / sequencer
  writer : process
    variable seed1, seed2 : positive := 5;
    variable rnd  : real;
    variable id   : natural := 0;
    variable len  : natural;
    variable ok_before : natural;
    variable err_before : natural;

    procedure put(b : std_logic_vector(7 downto 0); commit : boolean) is
    begin
      while a_tfull = '1' loop
        wait until rising_edge(clk);
        wait for 1 ns;
      end loop;
      a_tw <= '1'; a_twd <= b; a_tc <= to_sl(commit);
      wait until rising_edge(clk);
      a_tw <= '0'; a_tc <= '0';
      wait for 1 ns;
    end procedure;

    -- write frame <fid> with header length hdr_len and n_bytes payload bytes
    procedure send_frame(fid, hdr_len, n_bytes : natural; expect : boolean) is
      variable lv : unsigned(15 downto 0) := to_unsigned(hdr_len, 16);
    begin
      if expect then
        expq.push(fid, hdr_len);
      end if;
      put(std_logic_vector(to_unsigned(f_type(fid), 8)), false);
      put(std_logic_vector(lv(15 downto 8)), false);
      put(std_logic_vector(lv(7 downto 0)), n_bytes = 0);
      for i in 0 to n_bytes - 1 loop
        put(f_byte(fid, i), i = n_bytes - 1);
      end loop;
    end procedure;

    procedure wait_frames_done(timeout_us : natural) is
    begin
      for i in 1 to timeout_us * 50 loop
        wait until rising_edge(clk);
        exit when expq.size = 0 and a_tf_empty = '1' and a_busy = '0' and b_busy = '0'
                  and b_rempty = '1';
      end loop;
      for i in 1 to 200 loop wait until rising_edge(clk); end loop;
    end procedure;

    function err_sum(a, b, c, d, e : natural) return natural is
    begin
      return a + b + c + d + e;
    end function;
  begin
    rst <= '1';
    for i in 1 to 10 loop wait until rising_edge(clk); end loop;
    rst <= '0';
    -- let both sides exchange idle pairs (XON) first
    for i in 1 to 100 loop wait until rising_edge(clk); end loop;
    check_equal(a_xoff_remote, '0', "side A sees XON after start-up");
    check_equal(a_remote_ready, '1', "side A sees the remote receiver ready");

    ------------------------------------------------------------ 1
    for f in 1 to 20 loop
      uniform(seed1, seed2, rnd);
      len := 1 + integer(trunc(rnd * 299.99));
      send_frame(id, len, len, true); id := id + 1;
    end loop;
    wait_frames_done(2000);
    check_equal(n_rx_frames, 20, "phase 1: frames delivered");
    check_equal(cnt_ok, 20, "phase 1: ev_frame_ok count");

    ------------------------------------------------------------ 2
    ok_before := cnt_ok;
    for f in 0 to 5 loop
      -- good frame, corrupted frame, good frame
      send_frame(id, 40, 40, true); id := id + 1;
      wait_frames_done(500);
      err_before := err_sum(cnt_crc, cnt_code, cnt_len, cnt_frm, cnt_ovf);
      corrupt_pos <= CORRUPT_AT(f);
      corrupt_bit <= (f * 3 + 1) mod 10;
      corrupt_arm <= true;
      send_frame(id, 40, 40, false); id := id + 1;
      wait until a_sent = '1';
      for i in 1 to 300 loop wait until rising_edge(clk); end loop;
      corrupt_arm <= false;
      wait_frames_done(500);
      check_equal(err_sum(cnt_crc, cnt_code, cnt_len, cnt_frm, cnt_ovf) - err_before, 1,
                  "phase 2: one error event for corrupted frame " & integer'image(f));
      send_frame(id, 40, 40, true); id := id + 1;
      wait_frames_done(500);
    end loop;
    check_equal(cnt_ok - ok_before, 12, "phase 2: good frames delivered");

    ------------------------------------------------------------ 2b
    -- character-level corruption: valid symbols carrying a wrong byte in the
    -- payload, in CRC0 and in TYPE -> each must be caught by the CRC
    err_before := cnt_crc;
    for f in 0 to 2 loop
      cc_pos <= CORRUPT_CHR(f);
      cc_arm <= true;
      send_frame(id, 40, 40, false); id := id + 1;
      wait until a_sent = '1';
      for i in 1 to 300 loop wait until rising_edge(clk); end loop;
      cc_arm <= false;
      wait_frames_done(500);
      send_frame(id, 40, 40, true); id := id + 1;
      wait_frames_done(500);
    end loop;
    check_equal(cnt_crc - err_before, 3, "phase 2b: three CRC errors for wrong bytes");

    ------------------------------------------------------------ 3
    err_before := cnt_len;
    send_frame(id, 0, 0, false); id := id + 1;              -- LEN = 0
    send_frame(id, 1025, 1025, false); id := id + 1;        -- LEN > MAX_LEN
    send_frame(id, 10, 10, true); id := id + 1;
    wait_frames_done(1000);
    check_equal(cnt_len - err_before, 2, "phase 3: two length errors at the receiver");
    check_equal(cnt_lenerr_tx, 1, "phase 3: framer flags LEN > MAX_LEN");

    ------------------------------------------------------------ 4
    ok_before := cnt_ok;
    send_frame(id, 200, 200, false); id := id + 1;
    wait until a_busy = '1';
    for i in 1 to 300 loop wait until rising_edge(clk); end loop;   -- inside the payload
    b_sync <= '0';
    for i in 1 to 25 loop wait until rising_edge(clk); end loop;
    b_sync <= '1';
    send_frame(id, 30, 30, true); id := id + 1;
    wait_frames_done(1000);
    check_equal(cnt_ok - ok_before, 1, "phase 4: only the frame after the sync loss delivered");

    ------------------------------------------------------------ 4b
    ok_before := cnt_ok;
    b_rx_ready <= '0';
    for i in 1 to 100 loop wait until rising_edge(clk); end loop;   -- 20 characters
    check_equal(a_remote_ready, '0', "phase 4b: side A sees /R/ (remote not ready)");
    check_equal(a_xoff_remote, '1', "phase 4b: side A holds transmission");
    send_frame(id, 50, 50, true); id := id + 1;
    for i in 1 to 2000 loop
      wait until rising_edge(clk);
      if a_busy = '1' then
        check(false, "phase 4b: side A started a frame while the remote was not ready");
        exit;
      end if;
    end loop;
    check(a_tf_empty = '0', "phase 4b: frame kept in the TX FIFO");
    b_rx_ready <= '1';
    wait_frames_done(1000);
    check_equal(a_remote_ready, '1', "phase 4b: remote ready again");
    check_equal(cnt_ok - ok_before, 1, "phase 4b: frame delivered after the remote became ready");

    ------------------------------------------------------------ 5
    ok_before := cnt_ok;
    p5_start <= true;                       -- reader_ctl holds the reader
    for f in 1 to 16 loop
      send_frame(id, 1000, 1000, true); id := id + 1;
    end loop;
    -- (put blocks on the full TX FIFO until reader_ctl resumes the reader)
    if not p5_resumed then          -- may already be set while put was blocked
      wait until p5_resumed;
    end if;
    wait_frames_done(5000);
    check_equal(cnt_ok - ok_before, 16, "phase 5: all frames delivered after XOFF");
    check_equal(cnt_ovf, 0, "phase 5: no RX FIFO overflow");
    check_equal(b_xoff_local, '0', "phase 5: XOFF released after draining");

    ------------------------------------------------------------ 6
    check_equal(expq.size, 0, "all expected frames received");
    check_equal(cnt_frm + cnt_code + cnt_crc + cnt_len, 11,
                "error events: 6 (phase 2) + 3 CRC (phase 2b) + 2 length (phase 3)");

    stop <= true;
    tb_finish("tb_link_frames");
    wait;
  end process;

end architecture sim;
