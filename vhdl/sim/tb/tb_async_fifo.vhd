--------------------------------------------------------------------------------
-- tb_async_fifo
--
-- Testbench for async_fifo (COMMIT_MODE = true, depth 16, and a second
-- instance with COMMIT_MODE = false).
--
-- Model: a queue of committed words (protected type). The writer keeps the
-- words of the frame in progress separately and moves them to the queue on
-- commit, or drops them on abort. The reader compares every rd_valid word
-- with the head of the queue.
--
-- Checks:
--   1. Fill test (reader stopped): full after exactly DEPTH words; a further
--      write is ignored and pulses wr_ovf; rd_level reaches DEPTH; all words
--      read back in order.
--   2. Random frames 1..10 words, 25% aborted, commit with or without the
--      last write, random wr_en/rd_en duty: every committed word read once,
--      in order; no aborted word ever read.
--   3. Clock ratios: write 100 MHz / read 37.3 MHz, then write 100 MHz /
--      read 160 MHz, and read clock stopped for a while (host SCLK model).
--   4. Status at every clock edge: rd_level <= words in model queue + 1
--      (level one cycle behind); empty => rd_level <= 1;
--      full => wr_free <= 1.
--   5. Read while empty pulses rd_udf and returns no data.
--   6. Quiescent state after draining: empty, rd_level = 0, wr_free = DEPTH.
--   7. COMMIT_MODE = false instance: 3000 words streamed, order kept.
--
-- Waveform: write side (wr_clk, wr_en, wr_data, wr_commit, wr_abort, full,
-- wr_free), handshake (pub_req, pub_ack), read side (rd_clk, rd_en, rd_data,
-- rd_valid, empty, rd_level); see doc/vhdl/async_fifo.md.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library work;
use work.tb_pkg.all;

entity tb_async_fifo is
  generic (
    -- true: DUT with PUB_STABLE (commits kept >= 3 read clock periods apart)
    STABLE : boolean := false
  );
end entity tb_async_fifo;

architecture sim of tb_async_fifo is

  constant ADDR_W : positive := 4;
  constant DEPTH  : positive := 2 ** ADDR_W;

  -- queue model ---------------------------------------------------------------
  type t_queue is protected
    procedure push(v : natural);
    impure function pop return natural;
    impure function size return natural;
  end protected t_queue;

  type t_queue is protected body
    type t_arr is array (0 to 4095) of natural;
    variable arr       : t_arr;
    variable head, cnt : natural := 0;
    procedure push(v : natural) is
    begin
      assert cnt < 4096 report "queue model overflow" severity failure;
      arr((head + cnt) mod 4096) := v;
      cnt := cnt + 1;
    end procedure;
    impure function pop return natural is
      variable v : natural;
    begin
      assert cnt > 0 report "queue model underflow" severity failure;
      v := arr(head);
      head := (head + 1) mod 4096;
      cnt := cnt - 1;
      return v;
    end function;
    impure function size return natural is
    begin
      return cnt;
    end function;
  end protected body t_queue;

  shared variable model : t_queue;
  shared variable model2 : t_queue;

  -- clocks --------------------------------------------------------------------
  signal stop      : boolean := false;
  signal wr_clk    : std_logic := '0';
  signal rd_clk    : std_logic := '0';
  signal rd_period : time := 26.8 ns;
  signal rd_run    : boolean := true;

  -- DUT (commit mode)
  signal rst       : std_logic := '1';
  signal wr_en, wr_commit, wr_abort : std_logic := '0';
  signal wr_data   : std_logic_vector(7 downto 0) := (others => '0');
  signal full      : std_logic;
  signal wr_free   : unsigned(ADDR_W downto 0);
  signal wr_cl     : unsigned(ADDR_W downto 0);
  signal wr_ovf    : std_logic;
  signal rd_en     : std_logic := '0';
  signal rd_data   : std_logic_vector(7 downto 0);
  signal rd_valid  : std_logic;
  signal empty     : std_logic;
  signal rd_level  : unsigned(ADDR_W downto 0);
  signal rd_udf    : std_logic;

  -- DUT 2 (no commit)
  signal w2_en, r2_en : std_logic := '0';
  signal w2_data   : std_logic_vector(7 downto 0) := (others => '0');
  signal full2, empty2, r2_valid : std_logic;
  signal r2_data   : std_logic_vector(7 downto 0);

  -- test phase control
  signal phase      : natural := 0;    -- 1 fill, 2 random, 3 drain, 4 stream2
  signal reader_on  : boolean := false;
  signal rd_prob    : real := 0.5;
  signal writer_done, reader_idle : boolean := false;
  signal n_read     : natural := 0;
  signal n_commit   : natural := 0;
  signal frame_no   : natural := 0;

begin

  -- write clock 100 MHz
  process
  begin
    while not stop loop
      wr_clk <= '1'; wait for 5 ns;
      wr_clk <= '0'; wait for 5 ns;
    end loop;
    wait;
  end process;

  -- read clock: variable period, can be stopped
  process
  begin
    while not stop loop
      if rd_run then
        rd_clk <= '1'; wait for rd_period / 2;
        rd_clk <= '0'; wait for rd_period / 2;
      else
        rd_clk <= '0'; wait for 5 ns;
      end if;
    end loop;
    wait;
  end process;

  dut : entity work.async_fifo
    generic map (DATA_W => 8, ADDR_W => ADDR_W, COMMIT_MODE => true, PUB_STABLE => STABLE)
    port map (
      wr_clk => wr_clk, wr_rst => rst, wr_en => wr_en, wr_data => wr_data,
      wr_commit => wr_commit, wr_abort => wr_abort, full => full,
      wr_free => wr_free, wr_cmt_level => wr_cl, wr_ovf => wr_ovf,
      rd_clk => rd_clk, rd_rst => rst, rd_en => rd_en, rd_data => rd_data,
      rd_valid => rd_valid, empty => empty, rd_level => rd_level, rd_udf => rd_udf);

  dut2 : entity work.async_fifo
    generic map (DATA_W => 8, ADDR_W => ADDR_W, COMMIT_MODE => false)
    port map (
      wr_clk => wr_clk, wr_rst => rst, wr_en => w2_en, wr_data => w2_data,
      wr_commit => '0', wr_abort => '0', full => full2,
      wr_free => open, wr_ovf => open,
      rd_clk => rd_clk, rd_rst => rst, rd_en => r2_en, rd_data => r2_data,
      rd_valid => r2_valid, empty => empty2, rd_level => open, rd_udf => open);

  ------------------------------------------------------------------------------
  -- Writer (also sequencer)
  ------------------------------------------------------------------------------
  writer : process
    variable seed1, seed2 : positive := 11;
    variable rnd   : real;
    variable len   : natural;
    variable val   : natural := 0;
    type t_pend is array (0 to 15) of natural;
    variable pend  : t_pend;
    variable npend : natural;
    variable abort_frame : boolean;

    procedure wait_drained is
    begin
      for i in 1 to 100000 loop
        wait until rising_edge(wr_clk);
        exit when reader_idle and model.size = 0;
      end loop;
      check(model.size = 0, "FIFO drained within timeout (model holds "
            & integer'image(model.size) & " words)");
    end procedure;

    procedure wr_cycle(en, cm, ab : std_logic; d : natural) is
    begin
      if STABLE and cm = '1' then
        wait for 120 ns;                  -- PUB_STABLE: commits >= 3 read clock periods apart
      end if;
      wr_en <= en; wr_commit <= cm; wr_abort <= ab;
      wr_data <= std_logic_vector(to_unsigned(d mod 256, 8));
      wait until rising_edge(wr_clk);
      wr_en <= '0'; wr_commit <= '0'; wr_abort <= '0';
      wait for 1 ns;                  -- let full / wr_free settle after the edge
    end procedure;
  begin
    rst <= '1';
    for i in 1 to 10 loop wait until rising_edge(rd_clk); end loop;
    wait until rising_edge(wr_clk);
    rst <= '0';
    for i in 1 to 5 loop wait until rising_edge(wr_clk); end loop;

    -------------------------------------------------------------- 1. fill test
    phase <= 1;
    for i in 0 to DEPTH - 1 loop
      check_equal(full, '0', "not full before word " & integer'image(i));
      wr_cycle('1', to_sl(i = DEPTH - 1), '0', 100 + i);
      model.push(100 + i);
    end loop;
    wait for 1 ns;
    check_equal(full, '1', "full after DEPTH words");
    wait until rising_edge(wr_clk);          -- wr_free is one cycle behind
    wait for 1 ns;
    check_equal(to_integer(wr_free), 0, "wr_free = 0 one cycle after full");
    check_equal(to_integer(wr_cl), DEPTH, "wr_cmt_level = DEPTH with all words committed, none read");
    wr_cycle('1', '0', '0', 255);              -- write while full
    wait for 1 ns;
    check_equal(wr_ovf, '1', "wr_ovf on write while full");
    n_commit <= DEPTH;
    -- wait for publication and check the reader sees all words
    for i in 1 to 30 loop wait until rising_edge(wr_clk); end loop;
    reader_on <= true;
    wait_drained;
    reader_on <= false;

    -------------------------------------------------------------- 2./3. random
    phase <= 2;
    for f in 1 to 600 loop
      frame_no <= f;
      reader_on <= true;
      uniform(seed1, seed2, rnd);
      len := 1 + integer(trunc(rnd * 9.999));
      uniform(seed1, seed2, rnd);
      abort_frame := rnd < 0.25;
      npend := 0;
      for i in 1 to len loop
        -- random idle cycles
        loop
          uniform(seed1, seed2, rnd);
          exit when rnd < 0.7;
          wait until rising_edge(wr_clk);
          wait for 1 ns;
        end loop;
        -- wait for space
        while full = '1' loop
          wait until rising_edge(wr_clk);
          wait for 1 ns;
        end loop;
        uniform(seed1, seed2, rnd);
        if i = len and not abort_frame and rnd < 0.5 then
          wr_cycle('1', '1', '0', val);                   -- commit with last word
          pend(npend) := val; npend := npend + 1;
          for k in 0 to npend - 1 loop model.push(pend(k)); end loop;
          n_commit <= n_commit + npend;
          npend := 0;
        else
          wr_cycle('1', '0', '0', val);
          pend(npend) := val; npend := npend + 1;
        end if;
        val := val + 1;
      end loop;
      if npend > 0 then
        -- separate commit or abort cycle
        if abort_frame then
          wr_cycle('0', '0', '1', 0);
        else
          wr_cycle('0', '1', '0', 0);
          for k in 0 to npend - 1 loop model.push(pend(k)); end loop;
          n_commit <= n_commit + npend;
        end if;
      end if;
    end loop;

    -------------------------------------------------------------- 6. drain
    phase <= 3;
    writer_done <= true;
    wait_drained;
    for i in 1 to 30 loop wait until rising_edge(wr_clk); end loop;
    wait for 1 ns;
    check_equal(empty, '1', "empty after drain");
    check_equal(to_integer(rd_level), 0, "rd_level = 0 after drain");
    check_equal(to_integer(wr_free), DEPTH, "wr_free = DEPTH after drain");
    check_equal(to_integer(wr_cl), 0, "wr_cmt_level = 0 after drain");
    check_equal(n_read, n_commit, "words read = words committed");
    reader_on <= false;

    -------------------------------------------------------------- 7. no-commit
    phase <= 4;
    for i in 0 to 2999 loop
      while full2 = '1' loop
        wait until rising_edge(wr_clk);
        wait for 1 ns;
      end loop;
      w2_en <= '1'; w2_data <= std_logic_vector(to_unsigned(i mod 256, 8));
      model2.push(i mod 256);
      wait until rising_edge(wr_clk);
      w2_en <= '0';
      wait for 1 ns;
      uniform(seed1, seed2, rnd);
      if rnd < 0.3 then wait until rising_edge(wr_clk); wait for 1 ns; end if;
    end loop;
    for i in 1 to 20000 loop
      wait until rising_edge(wr_clk);
      exit when model2.size = 0;
    end loop;
    check_equal(model2.size, 0, "no-commit FIFO drained");

    stop <= true;
    if STABLE then
      tb_finish("tb_async_fifo_stable");
    else
      tb_finish("tb_async_fifo");
    end if;
    wait;
  end process;

  -- Read clock profile during the random phase: 37.3 MHz, from frame 200
  -- 160 MHz, from frame 350 stopped for 3 us (host SCLK model; the writer
  -- fills the FIFO and waits on full), then 37.3 MHz again.
  rd_stop : process
  begin
    wait until frame_no = 200;
    rd_period <= 6.25 ns;                         -- reader faster than writer
    wait until frame_no = 350;
    rd_run <= false;
    wait for 3 us;
    rd_run    <= true;
    rd_period <= 26.8 ns;
    wait;
  end process;

  ------------------------------------------------------------------------------
  -- Reader (commit-mode DUT)
  ------------------------------------------------------------------------------
  reader : process (rd_clk)
    variable seed1, seed2 : positive := 23;
    variable rnd  : real;
    variable expv : natural;
    variable idle_cnt : natural := 0;
  begin
    if rising_edge(rd_clk) then
      rd_en <= '0';
      -- data from the previous read
      if rd_valid = '1' then
        if model.size = 0 then
          check(false, "read data with empty model");
        else
          expv := model.pop;
          check_equal(rd_data, std_logic_vector(to_unsigned(expv mod 256, 8)),
                      "read data order");
          n_read <= n_read + 1;
        end if;
      end if;
      -- 4. pessimistic status
      if rst = '0' then
        check(to_integer(rd_level) <= model.size + 1, "rd_level <= committed words in model + 1");
        if empty = '1' then
          check(to_integer(rd_level) <= 1, "rd_level <= 1 when empty");
        end if;
      end if;
      -- 5. udf from a previous read-while-empty
      if reader_on then
        uniform(seed1, seed2, rnd);
        if empty = '0' and rnd < 0.6 then
          rd_en <= '1';
          idle_cnt := 0;
        elsif empty = '1' and rnd < 0.02 then
          rd_en <= '1';                          -- read while empty
        else
          idle_cnt := idle_cnt + 1;
        end if;
      else
        idle_cnt := idle_cnt + 1;
      end if;
      reader_idle <= idle_cnt > 40;
    end if;
  end process;

  -- rd_udf must accompany every read while empty, and never a valid word
  udf_check : process (rd_clk)
    variable prev_rd_empty : boolean := false;
  begin
    if rising_edge(rd_clk) then
      if rst = '0' then
        check_equal(rd_udf, to_sl(prev_rd_empty), "rd_udf after read while empty");
        if rd_udf = '1' then
          check_equal(rd_valid, '0', "no data on underflow");
        end if;
      end if;
      prev_rd_empty := rd_en = '1' and empty = '1';
    end if;
  end process;

  -- full / wr_free consistency (write side)
  wr_check : process (wr_clk)
  begin
    if rising_edge(wr_clk) then
      if rst = '0' then
        if full = '1' then
          check(to_integer(wr_free) <= 1, "wr_free <= 1 when full");
        end if;
        check(to_integer(wr_free) <= DEPTH, "wr_free <= DEPTH");
        check(to_integer(wr_cl) + to_integer(wr_free) <= DEPTH, "wr_cmt_level + wr_free <= DEPTH");
      end if;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- Reader for the no-commit instance
  ------------------------------------------------------------------------------
  reader2 : process (rd_clk)
    variable seed1, seed2 : positive := 31;
    variable rnd : real;
  begin
    if rising_edge(rd_clk) then
      r2_en <= '0';
      if r2_valid = '1' then
        check_equal(r2_data, std_logic_vector(to_unsigned(model2.pop, 8)), "no-commit FIFO order");
      end if;
      if phase = 4 then
        uniform(seed1, seed2, rnd);
        if empty2 = '0' and rnd < 0.5 then
          r2_en <= '1';
        end if;
      end if;
    end if;
  end process;

end architecture sim;
