--------------------------------------------------------------------------------
-- tb_uart
--
-- Testbench for uart_rx and uart_tx (8N1). clk = 50 MHz.
--
-- Phases:
--   1. uart_tx -> uart_rx loop, 200 random bytes back to back, at
--      div = 434 (115200 baud), 17 (2.94 Mbaud) and 8 (minimum): all bytes
--      received in order, no frame error; the bit time on the line measured
--      by the line monitor equals div cycles.
--   2. Behavioural sender -> uart_rx (div = 434) with the bit time off by
--      +3.5 % and -3.5 %: 50 bytes each received correctly.
--   3. Frame error: byte with stop bit '0' -> frame_err pulse, no data;
--      line then held low for 3 character times (break): no further
--      character or error; the next byte is received correctly.
--   4. Glitch: low pulse of div/4 cycles -> nothing received, no error.
--
-- Waveform: tx line, receiver state, data / valid / frame_err; see
-- doc/vhdl/uart.md.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library work;
use work.tb_pkg.all;
use work.bridge_pkg.all;

entity tb_uart is
end entity tb_uart;

architecture sim of tb_uart is

  constant T_CLK : time := 20 ns;

  signal clk      : std_logic := '0';
  signal rst      : std_logic := '1';
  signal stop     : boolean := false;
  signal div      : unsigned(15 downto 0) := to_unsigned(UART_DIV_DEFAULT, 16);
  signal tx_data  : std_logic_vector(7 downto 0) := (others => '0');
  signal tx_start : std_logic := '0';
  signal tx_ready : std_logic;
  signal tx_line  : std_logic;
  signal tb_line  : std_logic := '1';       -- behavioural sender
  signal use_tb   : boolean := false;
  signal rx_line  : std_logic;
  signal rx_data  : std_logic_vector(7 downto 0);
  signal rx_valid, rx_ferr, rx_busy : std_logic;

  type t_bytes is array (0 to 1023) of std_logic_vector(7 downto 0);

  -- expected bytes: pushed by the sequencer, compared by the monitor
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
      q((head + cnt) mod 1024) := b;
      cnt := cnt + 1;
    end procedure;
    impure function pop return std_logic_vector is
      variable b : std_logic_vector(7 downto 0);
    begin
      if cnt = 0 then
        return "XXXXXXXX";
      end if;
      b := q(head);
      head := (head + 1) mod 1024;
      cnt := cnt - 1;
      return b;
    end function;
    impure function size return natural is
    begin
      return cnt;
    end function;
  end protected body t_byte_q;
  shared variable expq : t_byte_q;

  signal n_rx, n_ferr, n_bad : natural := 0;
  signal min_bit      : time := 1 sec;      -- shortest high/low interval on tx_line
  signal min_clr      : boolean := false;   -- toggled by the sequencer: restart the measurement

begin

  clk_gen(clk, T_CLK, stop);

  u_tx : entity work.uart_tx
    port map (clk => clk, rst => rst, div => div, data => tx_data, start => tx_start,
              ready => tx_ready, tx => tx_line);

  rx_line <= tb_line when use_tb else tx_line;

  u_rx : entity work.uart_rx
    port map (clk => clk, rst => rst, div => div, rx => rx_line,
              data => rx_data, valid => rx_valid, frame_err => rx_ferr, busy => rx_busy);

  -- shortest interval between transitions of tx_line (= one bit time)
  process (tx_line, min_clr)
    variable t_last : time := 0 ns;
    variable m      : time := 1 sec;
  begin
    if min_clr'event then
      m := 1 sec;
    elsif tx_line'event then
      if t_last > 0 ns and now - t_last < m then
        m := now - t_last;
      end if;
      t_last := now;
    end if;
    min_bit <= m;
  end process;

  process
    variable exp    : t_bytes;
    variable s1, s2 : positive := 7;
    variable u      : real;
    variable n0, f0 : natural;
    variable ok     : boolean;

    -- behavioural UART sender on tb_line
    procedure send_tb(b : std_logic_vector(7 downto 0); bit_t : time; stop_bit : std_logic := '1') is
    begin
      tb_line <= '0';
      wait for bit_t;
      for i in 0 to 7 loop
        tb_line <= b(i);
        wait for bit_t;
      end loop;
      tb_line <= stop_bit;
      wait for bit_t;
      tb_line <= '1';
    end procedure;

    procedure collect_until(n : natural; tmax : time) is
      variable t : time := now;
    begin
      while n_rx < n and now - t < tmax loop
        wait until rising_edge(clk);
      end loop;
    end procedure;

  begin
    rst <= '1';
    wait for 100 ns;
    wait until rising_edge(clk);
    rst <= '0';

    ---------------------------------------------------------------- 1
    for d in 0 to 2 loop
      case d is
        when 0 => div <= to_unsigned(434, 16);
        when 1 => div <= to_unsigned(17, 16);
        when others => div <= to_unsigned(8, 16);
      end case;
      wait until rising_edge(clk);
      n0 := n_rx; f0 := n_ferr;
      min_clr <= not min_clr;
      for i in 0 to 199 loop
        uniform(s1, s2, u);
        exp(i) := std_logic_vector(to_unsigned(integer(floor(u * 256.0)) mod 256, 8));
        expq.push(exp(i));
        if tx_ready = '0' then
          wait until tx_ready = '1';
        end if;
        wait until rising_edge(clk);
        tx_data  <= exp(i);
        tx_start <= '1';
        wait until rising_edge(clk);
        tx_start <= '0';
        wait for 1 ns;
      end loop;
      collect_until(n0 + 200, 200 * 12 * to_integer(div) * T_CLK);
      check_equal(n_rx - n0, 200, "1: bytes received at div " & integer'image(to_integer(div)));
      check_equal(n_ferr - f0, 0, "1: frame errors at div " & integer'image(to_integer(div)));
      check(min_bit = to_integer(div) * T_CLK, "1: bit time " & time'image(min_bit) &
            " at div " & integer'image(to_integer(div)));
      wait for 1 ns;
    end loop;

    ---------------------------------------------------------------- 2
    div    <= to_unsigned(434, 16);
    use_tb <= true;
    wait for 1 us;
    for d in 0 to 1 loop
      n0 := n_rx; f0 := n_ferr;
      for i in 0 to 49 loop
        exp(i) := std_logic_vector(to_unsigned((i * 37 + d * 11) mod 256, 8));
        expq.push(exp(i));
        if d = 0 then
          send_tb(exp(i), 434 * T_CLK * 1.035);
        else
          send_tb(exp(i), 434 * T_CLK * 0.965);
        end if;
      end loop;
      collect_until(n0 + 50, 100 us);
      check_equal(n_rx - n0, 50, "2: bytes received with bit time error " & integer'image(d));
      check_equal(n_ferr - f0, 0, "2: frame errors with bit time error " & integer'image(d));
    end loop;

    ---------------------------------------------------------------- 3
    n0 := n_rx; f0 := n_ferr;
    send_tb(x"A5", 434 * T_CLK, '0');           -- stop bit '0'
    tb_line <= '0';                              -- break: 3 character times
    wait for 30 * 434 * T_CLK;
    tb_line <= '1';
    wait for 2 * 434 * T_CLK;
    check_equal(n_ferr - f0, 1, "3: one frame error");
    check_equal(n_rx - n0, 0, "3: no data from the bad frame or the break");
    expq.push(x"3C");
    send_tb(x"3C", 434 * T_CLK);
    collect_until(n0 + 1, 50 us);
    check_equal(n_rx - n0, 1, "3: next byte received");

    ---------------------------------------------------------------- 4
    n0 := n_rx; f0 := n_ferr;
    tb_line <= '0';
    wait for 434 / 4 * T_CLK;
    tb_line <= '1';
    wait for 20 * 434 * T_CLK;
    check_equal(n_rx - n0, 0, "4: glitch ignored (no data)");
    check_equal(n_ferr - f0, 0, "4: glitch ignored (no error)");

    check_equal(n_bad, 0, "received bytes equal the bytes sent");
    check_equal(expq.size, 0, "no expected byte left");
    stop <= true;
    tb_finish("tb_uart");
    wait;
  end process;

  -- monitor: every received byte is compared with the next expected byte
  process (clk)
  begin
    if rising_edge(clk) then
      if rx_valid = '1' then
        n_rx <= n_rx + 1;
        if rx_data /= expq.pop then
          n_bad <= n_bad + 1;
        end if;
      end if;
      if rx_ferr = '1' then n_ferr <= n_ferr + 1; end if;
    end if;
  end process;

end architecture sim;
