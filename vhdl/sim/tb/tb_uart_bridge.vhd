--------------------------------------------------------------------------------
-- tb_uart_bridge
--
-- Testbench for uart_bridge with real FIFOs (async_fifo, commit mode):
-- TX FIFO 512 B (small, to reach RTS and overflow quickly; RTS_FREE = 128),
-- RX FIFO 1 KiB. The testbench models the UART device (behavioural sender
-- on UART_RX, receiver on UART_TX) and the link (reads frames from the TX
-- FIFO, writes frames into the RX FIFO). clk = 50 MHz.
--
-- Phases:
--   0. div = 434 (115200): 10 bytes back to back -> one frame of 10 bytes,
--      written 2..2.5 character times after the stop bit of the last byte.
--   1. div = 54: 200 bytes back to back -> frames of 64, 64, 64, 8 bytes.
--   2. 5 bytes, pause 1.5 characters, 5 bytes, pause -> one frame of 10;
--      a byte with a bad stop bit -> ev_frame_err, not in any frame.
--   3. link -> UART: frames (TYPE 0x01, 10 B), (TYPE 0x10, 20 B),
--      (TYPE 0x01, 300 B): exactly the 310 bytes of the TYPE 0x01 frames on
--      UART_TX, in order; one ev_skip.
--   4. RTS/CTS on, CTS_N = 1: a frame of 5 bytes waits (nothing sent for
--      50 character times); after CTS_N = 0 the 5 bytes are sent.
--   5. RTS/CTS on, link stopped (TX FIFO not read), sender ignoring RTS,
--      div = 17: RTS_N rises before the first lost byte; bytes are then lost
--      (ev_rx_ovf); after the link resumes, RTS_N returns to 0, every frame
--      is well formed and (bytes in frames) + (lost bytes) = bytes sent.
--   In phases 0..3 every byte in the frames equals the sent bytes in order.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.tb_pkg.all;
use work.bridge_pkg.all;

entity tb_uart_bridge is
end entity tb_uart_bridge;

architecture sim of tb_uart_bridge is

  constant T_CLK : time := 20 ns;

  -- byte queue (expected bytes)
  type t_bytes is array (0 to 4095) of std_logic_vector(7 downto 0);
  type t_byte_q is protected
    procedure push(b : std_logic_vector(7 downto 0));
    impure function pop return std_logic_vector;
    impure function size return natural;
  end protected t_byte_q;
  type t_byte_q is protected body
    variable q : t_bytes;
    variable head, cnt : natural := 0;
    procedure push(b : std_logic_vector(7 downto 0)) is
    begin
      q((head + cnt) mod 4096) := b;
      cnt := cnt + 1;
    end procedure;
    impure function pop return std_logic_vector is
      variable b : std_logic_vector(7 downto 0);
    begin
      if cnt = 0 then
        return "XXXXXXXX";
      end if;
      b := q(head);
      head := (head + 1) mod 4096;
      cnt := cnt - 1;
      return b;
    end function;
    impure function size return natural is
    begin
      return cnt;
    end function;
  end protected body t_byte_q;
  shared variable q_up   : t_byte_q;      -- UART -> link: bytes sent by the device
  shared variable q_down : t_byte_q;      -- link -> UART: payload of TYPE 0x01 frames

  signal clk        : std_logic := '0';
  signal rst        : std_logic := '1';
  signal stop       : boolean := false;
  signal div        : unsigned(15 downto 0) := to_unsigned(434, 16);
  signal rtscts     : std_logic := '0';
  signal dev_tx     : std_logic := '1';   -- device -> bridge UART_RX
  signal br_tx      : std_logic;          -- bridge UART_TX -> device
  signal rts_n      : std_logic;
  signal cts_n      : std_logic := '0';

  -- TX FIFO
  signal tf_wr, tf_commit : std_logic;
  signal tf_wdata   : std_logic_vector(7 downto 0);
  signal tf_free    : unsigned(9 downto 0);
  signal tf_rd, tf_valid, tf_empty : std_logic := '0';
  signal tf_rdata   : std_logic_vector(7 downto 0);
  -- RX FIFO
  signal rf_wr, rf_commit : std_logic := '0';
  signal rf_wdata   : std_logic_vector(7 downto 0) := (others => '0');
  signal rf_rd, rf_valid, rf_empty : std_logic;
  signal rf_rdata   : std_logic_vector(7 downto 0);

  signal ev_ovf, ev_ferr, ev_frame, ev_skip : std_logic;

  -- link reader model
  signal link_run   : boolean := true;    -- read the TX FIFO
  signal strict     : boolean := true;    -- compare payload with q_up
  signal n_frames   : natural := 0;
  signal last_len   : natural := 0;
  signal t_frame    : time := 0 ns;       -- time the last frame became available
  signal n_up_bytes, n_up_bad, n_bad_hdr : natural := 0;
  -- UART receiver model
  signal n_down, n_down_bad : natural := 0;
  -- event counters
  signal n_ovf, n_ferr, n_skip : natural := 0;
  -- frame length log (phase 1)
  type t_len_arr is array (0 to 15) of natural;
  signal len_log    : t_len_arr := (others => 0);

begin

  clk_gen(clk, T_CLK, stop);

  dut : entity work.uart_bridge
    generic map (MAX_PAY => 64, FREE_W => 10, RTS_FREE => 128)
    port map (clk => clk, rst => rst, cfg_div => div, cfg_rtscts => rtscts,
              uart_rx => dev_tx, uart_tx => br_tx, uart_rts_n => rts_n, uart_cts_n => cts_n,
              tx_wr => tf_wr, tx_data => tf_wdata, tx_commit => tf_commit, tx_free => tf_free,
              rx_rd => rf_rd, rx_data => rf_rdata, rx_valid => rf_valid, rx_empty => rf_empty,
              ev_rx_ovf => ev_ovf, ev_frame_err => ev_ferr, ev_frame => ev_frame, ev_skip => ev_skip);

  u_tf : entity work.async_fifo
    generic map (DATA_W => 8, ADDR_W => 9, COMMIT_MODE => true)
    port map (wr_clk => clk, wr_rst => rst, wr_en => tf_wr, wr_data => tf_wdata,
              wr_commit => tf_commit, wr_abort => '0', full => open, wr_free => tf_free, wr_ovf => open,
              rd_clk => clk, rd_rst => rst, rd_en => tf_rd, rd_data => tf_rdata,
              rd_valid => tf_valid, empty => tf_empty, rd_level => open, rd_udf => open);

  u_rf : entity work.async_fifo
    generic map (DATA_W => 8, ADDR_W => 10, COMMIT_MODE => true)
    port map (wr_clk => clk, wr_rst => rst, wr_en => rf_wr, wr_data => rf_wdata,
              wr_commit => rf_commit, wr_abort => '0', full => open, wr_free => open, wr_ovf => open,
              rd_clk => clk, rd_rst => rst, rd_en => rf_rd, rd_data => rf_rdata,
              rd_valid => rf_valid, empty => rf_empty, rd_level => open, rd_udf => open);

  ------------------------------------------------------------------------------
  -- Link reader model: frames from the TX FIFO
  ------------------------------------------------------------------------------
  tf_rd <= '1' when link_run and tf_empty = '0' else '0';

  process (clk)
    variable idx, len : natural := 0;
    variable empty_d  : std_logic := '1';
  begin
    if rising_edge(clk) then
      if tf_empty = '0' and empty_d = '1' and idx = 0 then
        t_frame <= now;
      end if;
      empty_d := tf_empty;
      if tf_valid = '1' then
        case idx is
          when 0 =>
            if tf_rdata /= TYPE_UART then n_bad_hdr <= n_bad_hdr + 1; end if;
          when 1 =>
            len := 256 * to_integer(unsigned(tf_rdata));
          when 2 =>
            len := len + to_integer(unsigned(tf_rdata));
            if len = 0 or len > 64 then n_bad_hdr <= n_bad_hdr + 1; end if;
          when others =>
            n_up_bytes <= n_up_bytes + 1;
            if strict and tf_rdata /= q_up.pop then
              n_up_bad <= n_up_bad + 1;
            end if;
        end case;
        idx := idx + 1;
        if idx >= 3 and idx = 3 + len then
          if n_frames <= 15 then
            len_log(n_frames) <= len;
          end if;
          n_frames <= n_frames + 1;
          last_len <= len;
          idx := 0;
        end if;
      end if;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- UART receiver model on the bridge UART_TX
  ------------------------------------------------------------------------------
  process
    variable b : std_logic_vector(7 downto 0);
    variable bt : time;
  begin
    wait until br_tx = '0';
    bt := to_integer(div) * T_CLK;
    wait for bt / 2;                       -- middle of the start bit
    for i in 0 to 7 loop
      wait for bt;
      b(i) := br_tx;
    end loop;
    wait for bt;                           -- stop bit
    if br_tx /= '1' then
      n_down_bad <= n_down_bad + 1;
    elsif b /= q_down.pop then
      n_down_bad <= n_down_bad + 1;
    end if;
    n_down <= n_down + 1;
    if br_tx /= '1' then                   -- (wait until needs an event)
      wait until br_tx = '1';
    end if;
  end process;

  -- event counters
  process (clk)
  begin
    if rising_edge(clk) then
      if ev_ovf = '1' then n_ovf <= n_ovf + 1; end if;
      if ev_ferr = '1' then n_ferr <= n_ferr + 1; end if;
      if ev_skip = '1' then n_skip <= n_skip + 1; end if;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- Sequencer
  ------------------------------------------------------------------------------
  process
    variable t_stop : time;
    variable n0, f0, b0, o0, s0 : natural;
    variable n_sent : natural;
    variable rts_seen_before_ovf : boolean;

    -- device sends one byte on dev_tx (records it in q_up when 'expect')
    procedure dev_send(b : std_logic_vector(7 downto 0); expect : boolean := true;
                       stop_bit : std_logic := '1') is
      variable bt : time := to_integer(div) * T_CLK;
    begin
      if expect then
        q_up.push(b);
      end if;
      dev_tx <= '0';
      wait for bt;
      for i in 0 to 7 loop
        dev_tx <= b(i);
        wait for bt;
      end loop;
      dev_tx <= stop_bit;
      wait for bt;
      dev_tx <= '1';
    end procedure;

    function byte_of(i : natural) return std_logic_vector is
    begin
      return std_logic_vector(to_unsigned((i * 89 + 7) mod 256, 8));
    end function;

    -- link writes a frame into the RX FIFO
    procedure link_frame(ftype : std_logic_vector(7 downto 0); len, seed : natural) is
      variable b : std_logic_vector(7 downto 0);
    begin
      wait until rising_edge(clk);
      rf_wr <= '1'; rf_wdata <= ftype;
      wait until rising_edge(clk);
      rf_wdata <= std_logic_vector(to_unsigned(len / 256, 8));
      wait until rising_edge(clk);
      rf_wdata <= std_logic_vector(to_unsigned(len mod 256, 8));
      for i in 0 to len - 1 loop
        wait until rising_edge(clk);
        b := byte_of(seed + i);
        rf_wdata <= b;
        if ftype = TYPE_UART then
          q_down.push(b);
        end if;
        if i = len - 1 then
          rf_commit <= '1';
        end if;
      end loop;
      wait until rising_edge(clk);
      rf_wr <= '0'; rf_commit <= '0';
    end procedure;

    procedure wait_cond_frames(n : natural; tmax : time) is
      variable t : time := now;
    begin
      while n_frames < n and now - t < tmax loop
        wait until rising_edge(clk);
      end loop;
    end procedure;

  begin
    rst <= '1';
    wait for 200 ns;
    wait until rising_edge(clk);
    rst <= '0';
    wait for 1 us;

    ---------------------------------------------------------------- 0
    div <= to_unsigned(434, 16);
    wait for 100 ns;
    for i in 0 to 9 loop
      dev_send(byte_of(i));
    end loop;
    t_stop := now;
    wait_cond_frames(1, 1 ms);
    check_equal(n_frames, 1, "0: one frame");
    check_equal(last_len, 10, "0: frame length");
    check(t_frame - t_stop >= 20 * 434 * T_CLK and t_frame - t_stop <= 25 * 434 * T_CLK,
          "0: frame closed after " & time'image(t_frame - t_stop) & " of idle line");

    ---------------------------------------------------------------- 1
    div <= to_unsigned(54, 16);
    wait for 100 us;
    n0 := n_frames;
    for i in 0 to 199 loop
      dev_send(byte_of(100 + i));
    end loop;
    wait_cond_frames(n0 + 4, 1 ms);
    check_equal(n_frames - n0, 4, "1: four frames for 200 bytes");
    check(len_log(n0) = 64 and len_log(n0 + 1) = 64 and len_log(n0 + 2) = 64 and len_log(n0 + 3) = 8,
          "1: frame lengths 64, 64, 64, 8: " & integer'image(len_log(n0)) & " " &
          integer'image(len_log(n0 + 1)) & " " & integer'image(len_log(n0 + 2)) & " " &
          integer'image(len_log(n0 + 3)));

    ---------------------------------------------------------------- 2
    n0 := n_frames; f0 := n_ferr;
    for i in 0 to 4 loop
      dev_send(byte_of(400 + i));
    end loop;
    wait for 15 * 54 * T_CLK;               -- 1.5 characters: same frame
    for i in 5 to 9 loop
      dev_send(byte_of(400 + i));
    end loop;
    wait_cond_frames(n0 + 1, 200 us);
    check_equal(n_frames - n0, 1, "2: one frame across a short pause");
    check_equal(last_len, 10, "2: frame length 10");
    dev_send(x"55", false, '0');             -- bad stop bit
    wait for 40 * 54 * T_CLK;
    check_equal(n_ferr - f0, 1, "2: frame error reported");
    check_equal(n_frames - n0, 1, "2: no frame from the bad byte");

    ---------------------------------------------------------------- 3
    b0 := n_down; s0 := n_skip;
    link_frame(TYPE_UART, 10, 1000);
    link_frame(x"10", 20, 2000);
    link_frame(TYPE_UART, 300, 3000);
    wait for 330 * 10 * 54 * T_CLK;
    check_equal(n_down - b0, 310, "3: bytes sent on UART_TX");
    check_equal(n_skip - s0, 1, "3: one frame of another type skipped");

    ---------------------------------------------------------------- 4
    rtscts <= '1';
    cts_n  <= '1';
    b0 := n_down;
    link_frame(TYPE_UART, 5, 4000);
    wait for 50 * 10 * 54 * T_CLK;
    check_equal(n_down - b0, 0, "4: nothing sent while CTS_N = 1");
    check_equal(br_tx, '1', "4: UART_TX idle while CTS_N = 1");
    cts_n <= '0';
    wait for 8 * 10 * 54 * T_CLK;
    check_equal(n_down - b0, 5, "4: bytes sent after CTS_N = 0");

    ---------------------------------------------------------------- 5
    div      <= to_unsigned(17, 16);
    link_run <= false;
    strict   <= false;
    wait for 10 us;
    check_equal(rts_n, '0', "5: RTS_N low with an empty TX FIFO");
    b0 := n_up_bytes; o0 := n_ovf; n_sent := 0;
    rts_seen_before_ovf := false;
    for i in 0 to 699 loop
      dev_send(byte_of(5000 + i), false);
      n_sent := n_sent + 1;
      if rts_n = '1' and n_ovf = o0 then
        rts_seen_before_ovf := true;
      end if;
    end loop;
    wait for 20 us;
    check(rts_seen_before_ovf, "5: RTS_N raised before the first lost byte");
    check(n_ovf > o0, "5: bytes lost while the link is stopped");
    link_run <= true;
    wait for 500 us;
    check_equal(rts_n, '0', "5: RTS_N low again after draining");
    check_equal((n_up_bytes - b0) + (n_ovf - o0), n_sent, "5: bytes in frames + lost = sent");
    report "phase 5: lost " & integer'image(n_ovf - o0) & " of " & integer'image(n_sent);

    ---------------------------------------------------------------- final
    check_equal(n_up_bad, 0, "UART -> link bytes equal the sent bytes (phases 0..3)");
    check_equal(n_bad_hdr, 0, "frame headers (TYPE 0x01, LEN 1..64)");
    check_equal(n_down_bad, 0, "link -> UART bytes equal the frame payload");
    check_equal(q_down.size, 0, "no link -> UART byte missing");

    stop <= true;
    tb_finish("tb_uart_bridge");
    wait;
  end process;

end architecture sim;
