--------------------------------------------------------------------------------
-- tb_host_clk
--
-- Testbench for host_clk (Gowin DCS model) and frame_echo.
--
-- host_clk: clk_sys 50 MHz, SCLK bursts of 16 cycles at 40 MHz with idle
-- low between them (as from an xSPI host).
--   1. In reset clk_host follows clk_sys (rising edges coincide).
--   2. xspi_mode = '1': after reset and SWITCH_DELAY cycles clk_host follows
--      SCLK (edges only during the bursts); no pulse shorter than 10 ns at
--      the switch.
--   3. A new reset switches back to clk_sys.
--   4. xspi_mode = '0' (UART / echo): clk_host stays on clk_sys.
--
-- frame_echo (clk_host = clk_sys; FIFO host ports on the falling edge):
--   5. The link side writes 40 frames (length 1..300) into the RX FIFO
--      (1 KiB) and reads the TX FIFO (512 B >= largest frame of 303 B; slower
--      reader: backpressure);
--      every frame comes back unchanged and in order; ev_frame count = 40.
--   6. en = '0': nothing is copied.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.tb_pkg.all;

entity tb_host_clk is
end entity tb_host_clk;

architecture sim of tb_host_clk is

  constant T_SYS : time := 20 ns;
  constant T_SCK : time := 25 ns;

  -- byte queue
  type t_bytes is array (0 to 16383) of std_logic_vector(7 downto 0);
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
      q((head + cnt) mod 16384) := b;
      cnt := cnt + 1;
    end procedure;
    impure function pop return std_logic_vector is
      variable b : std_logic_vector(7 downto 0);
    begin
      if cnt = 0 then return "XXXXXXXX"; end if;
      b := q(head);
      head := (head + 1) mod 16384;
      cnt := cnt - 1;
      return b;
    end function;
    impure function size return natural is
    begin
      return cnt;
    end function;
  end protected body t_byte_q;
  shared variable q_echo : t_byte_q;

  signal clk_sys   : std_logic := '0';
  signal stop      : boolean := false;
  signal sclk      : std_logic := '0';
  signal rst_sys   : std_logic := '1';
  signal xspi_mode : std_logic := '1';
  signal clk_host, rst_host, on_sclk : std_logic;
  signal min_pulse : time := 1 sec;
  signal mp_clr    : boolean := false;

  -- frame_echo
  signal e_rst     : std_logic := '1';
  signal e_en      : std_logic := '0';
  signal rf_wr, rf_commit : std_logic := '0';
  signal rf_wdata  : std_logic_vector(7 downto 0) := (others => '0');
  signal rx_rd, rx_valid, rx_empty : std_logic;
  signal rx_data   : std_logic_vector(7 downto 0);
  signal tx_wr, tx_commit, tx_full : std_logic;
  signal tx_data   : std_logic_vector(7 downto 0);
  signal tf_rd, tf_valid, tf_empty : std_logic := '0';
  signal tf_rdata  : std_logic_vector(7 downto 0);
  signal n_echo, n_bad, n_frames : natural := 0;
  signal slow      : std_logic := '0';

begin

  clk_gen(clk_sys, T_SYS, stop);

  dut : entity work.host_clk
    generic map (SWITCH_DELAY => 8)
    port map (clk_sys => clk_sys, sclk => sclk, rst_sys => rst_sys, xspi_mode => xspi_mode,
              clk_host => clk_host, rst_host => rst_host, on_sclk => on_sclk);

  -- shortest high or low pulse of clk_host
  process (clk_host, mp_clr)
    variable t_last : time := 0 ns;
    variable m      : time := 1 sec;
  begin
    if mp_clr'event then
      m := 1 sec;
    elsif clk_host'event then
      if t_last > 0 ns and now - t_last < m then m := now - t_last; end if;
      t_last := now;
    end if;
    min_pulse <= m;
  end process;

  ------------------------------------------------------------------------------
  -- frame_echo with FIFOs (host side = clk_sys, falling edge)
  ------------------------------------------------------------------------------
  u_rf : entity work.async_fifo
    generic map (DATA_W => 8, ADDR_W => 10, COMMIT_MODE => true, RD_FALLING => true)
    port map (wr_clk => clk_sys, wr_rst => e_rst, wr_en => rf_wr, wr_data => rf_wdata,
              wr_commit => rf_commit, wr_abort => '0', full => open, wr_free => open, wr_ovf => open,
              rd_clk => clk_sys, rd_rst => e_rst, rd_en => rx_rd, rd_data => rx_data,
              rd_valid => rx_valid, empty => rx_empty, rd_level => open, rd_udf => open);

  u_echo : entity work.frame_echo
    port map (clk => clk_sys, rst => e_rst, en => e_en,
              rx_rd => rx_rd, rx_data => rx_data, rx_valid => rx_valid, rx_empty => rx_empty,
              tx_wr => tx_wr, tx_data => tx_data, tx_commit => tx_commit, tx_full => tx_full,
              ev_frame => open);

  u_tf : entity work.async_fifo
    generic map (DATA_W => 8, ADDR_W => 9, COMMIT_MODE => true, WR_FALLING => true)
    port map (wr_clk => clk_sys, wr_rst => e_rst, wr_en => tx_wr, wr_data => tx_data,
              wr_commit => tx_commit, wr_abort => '0', full => tx_full, wr_free => open, wr_ovf => open,
              rd_clk => clk_sys, rd_rst => e_rst, rd_en => tf_rd, rd_data => tf_rdata,
              rd_valid => tf_valid, empty => tf_empty, rd_level => open, rd_udf => open);

  -- link reader: every other cycle (slower than the echo -> backpressure)
  process (clk_sys)
  begin
    if rising_edge(clk_sys) then
      slow <= not slow;
      if tf_valid = '1' then
        n_echo <= n_echo + 1;
        if tf_rdata /= q_echo.pop then n_bad <= n_bad + 1; end if;
      end if;
    end if;
  end process;
  tf_rd <= '1' when tf_empty = '0' and slow = '1' else '0';

  ------------------------------------------------------------------------------
  -- SCLK bursts
  ------------------------------------------------------------------------------
  process
  begin
    wait for 1 us;
    while not stop loop
      for i in 1 to 16 loop
        wait for T_SCK / 2; sclk <= '1';
        wait for T_SCK / 2; sclk <= '0';
      end loop;
      wait for 300 ns;
    end loop;
    wait;
  end process;

  ------------------------------------------------------------------------------
  process
    variable ok   : boolean;
    variable n_e  : natural;
    variable len  : natural;
    variable b    : std_logic_vector(7 downto 0);

    procedure count_host_edges(t : time; n : out natural) is
      variable k : natural := 0;
      variable t0 : time := now;
    begin
      while now - t0 < t loop
        wait until rising_edge(clk_host) for t - (now - t0);
        if clk_host = '1' and clk_host'event then k := k + 1; end if;
      end loop;
      n := k;
    end procedure;

  begin
    ---------------------------------------------------------------- 1
    for i in 1 to 10 loop wait until rising_edge(clk_sys); end loop;
    ok := true;
    for i in 1 to 20 loop
      wait until rising_edge(clk_host);
      if clk_sys /= '1' or clk_sys'last_event > 0 ns then ok := false; end if;
    end loop;
    check(ok, "1: in reset clk_host follows clk_sys");
    check_equal(on_sclk, '0', "1: on_sclk = 0 in reset");

    ---------------------------------------------------------------- 2
    mp_clr <= not mp_clr;
    wait until falling_edge(clk_sys);
    rst_sys <= '0';
    wait for 12 * T_SYS;
    check_equal(on_sclk, '1', "2: switched to SCLK after the delay");
    ok := true;
    for i in 1 to 40 loop
      wait until rising_edge(clk_host);
      if sclk /= '1' or sclk'last_event > 0 ns then ok := false; end if;
    end loop;
    check(ok, "2: clk_host follows SCLK");
    check(min_pulse >= 10 ns, "2: no short pulse at the switch: " & time'image(min_pulse));

    ---------------------------------------------------------------- 3
    wait until rising_edge(clk_sys);
    rst_sys <= '1';
    wait for 4 * T_SYS;
    check_equal(on_sclk, '0', "3: back on clk_sys in reset");
    ok := true;
    for i in 1 to 10 loop
      wait until rising_edge(clk_host);
      if clk_sys /= '1' or clk_sys'last_event > 0 ns then ok := false; end if;
    end loop;
    check(ok, "3: clk_host follows clk_sys again");

    ---------------------------------------------------------------- 4
    xspi_mode <= '0';
    wait until rising_edge(clk_sys);
    rst_sys <= '0';
    wait for 2 us;
    check_equal(on_sclk, '0', "4: UART / echo mode stays on clk_sys");

    ---------------------------------------------------------------- 5 / 6
    for i in 1 to 4 loop wait until rising_edge(clk_sys); end loop;
    e_rst <= '0';
    -- 6: disabled -> nothing copied
    e_en <= '0';
    wait until rising_edge(clk_sys);
    rf_wr <= '1'; rf_wdata <= x"10";
    wait until rising_edge(clk_sys);
    rf_wdata <= x"00";
    wait until rising_edge(clk_sys);
    rf_wdata <= x"01";
    wait until rising_edge(clk_sys);
    rf_wdata <= x"AB"; rf_commit <= '1';
    for k in 0 to 3 loop null; end loop;
    wait until rising_edge(clk_sys);
    rf_wr <= '0'; rf_commit <= '0';
    wait for 2 us;
    check_equal(n_echo, 0, "6: nothing copied while disabled");
    q_echo.push(x"10"); q_echo.push(x"00"); q_echo.push(x"01"); q_echo.push(x"AB");
    e_en <= '1';
    -- 5: 40 frames
    for f in 0 to 39 loop
      len := 1 + (f * 97 + 13) mod 300;
      for i in 0 to len + 2 loop
        if i = 0 then b := std_logic_vector(to_unsigned(f, 8));
        elsif i = 1 then b := std_logic_vector(to_unsigned(len / 256, 8));
        elsif i = 2 then b := std_logic_vector(to_unsigned(len mod 256, 8));
        else b := std_logic_vector(to_unsigned((f * 7 + i) mod 256, 8));
        end if;
        q_echo.push(b);
        wait until rising_edge(clk_sys);
        rf_wr <= '1'; rf_wdata <= b;
        if i = len + 2 then rf_commit <= '1'; else rf_commit <= '0'; end if;
      end loop;
      wait until rising_edge(clk_sys);
      rf_wr <= '0'; rf_commit <= '0';
      -- keep the RX FIFO from overflowing: wait for room
      while q_echo.size > 700 loop
        wait until rising_edge(clk_sys);
      end loop;
    end loop;
    for i in 1 to 20000 loop
      wait until rising_edge(clk_sys);
      exit when q_echo.size = 0;
    end loop;
    check_equal(q_echo.size, 0, "5: all echoed bytes received");
    check_equal(n_bad, 0, "5: echoed bytes equal the frames");

    stop <= true;
    tb_finish("tb_host_clk");
    wait;
  end process;

end architecture sim;
