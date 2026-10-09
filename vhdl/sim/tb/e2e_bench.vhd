--------------------------------------------------------------------------------
-- e2e_bench
--
-- End-to-end test of two complete bridges (sfp_bridge_top, Gowin primitive
-- models) - a "virtual converter pair":
--
--   host A --(xSPI / UART pins)--> bridge A --SFP TD/RD line--> bridge B
--          --(xSPI / UART pins)--> host B
--
-- Only the pins of the bridges are used: J3 of A (input), the line between
-- the SFP pairs (A TD -> B RD and back, 5 ns delay, both directions), J3 of
-- B (output). Board rev. A wiring: the line connects TD_P -> RD_P, the RD
-- polarity swap at the FPGA pins is compensated inside the bridge.
-- Oscillators: A 25 MHz, B 25 MHz + 100 ppm. SFP module pins: present, no
-- LOS, no TX_FAULT, I2C lines with pull-ups only.
--
-- LINES = 1 / 4 / 8 (SPI / QSPI / OSPI): both bridges in the xSPI mode
-- (MODE_SEL high), SCLK 40 MHz.
--   1. Hosts release HOST_RST_N; host A polls READ_STATUS until LINK_UP.
--   2. Host A writes 2 frames with TX_WRITE (1-0-LINES): F1 = TYPE 0x00
--      "Hello, SFP!" (11 B), F2 = TYPE 0x00, 64 B counting pattern.
--   3. Host B polls READ_STATUS until RX_AVAIL, reads RX_LEVEL (READ_REG)
--      and the frames with RX_READ (1-0-LINES), until both are received.
--   Checks: both frames received intact and in order; counters
--   FRAMES_TX(A) = 2, FRAMES_RX(B) = 2, CODE_ERR(B) = CRC_ERR(B) = 0.
-- LINES = 0 (UART): both bridges in the UART mode (MODE_SEL low, jumper),
-- 115200 8N1.
--   1. Hosts release HOST_RST_N; wait for HOST_IRQ_N = 1 (link up) at A.
--   2. A UART device sends "Hello, SFP!" on UART_RX of A (J3 IO0).
--   3. A UART receiver on UART_TX of B (J3 IO1) collects the bytes.
--   4. HOST_RST_N of B low for 5 us after the link is lost at A.
--   Checks: the 11 bytes received in order without framing errors;
--   HOST_IRQ_N of A follows the link state (low after B's reset, high
--   again when the link is back).
--
-- Trace for the documentation (sim/out/<name>_trace.txt, sim/wave_svg.py):
--   S <id> <name> <width>          signal declaration
--   V <t_fs> <id> <value>          signal change
--   A <t0_fs> <t1_fs> <row> <text> annotation (byte, command, character)
--   M <t_fs> <marker>              time marker
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library std;
use std.textio.all;

library work;
use work.tb_pkg.all;
use work.bridge_pkg.all;
use work.xspi_pkg.all;

entity e2e_bench is
  generic (
    LINES : natural := 1;                            -- 1, 4, 8; 0 = UART
    NAME  : string  := "tb_e2e_spi"
  );
end entity e2e_bench;

architecture sim of e2e_bench is

  constant T_OSC_A  : time := 40 ns;
  constant T_OSC_B  : time := 39996 ps;              -- +100 ppm
  constant T_SCK    : time := 25 ns;                 -- 40 MHz
  constant T_CSH    : time := 120 ns;
  constant LINE_DLY : time := 5 ns;
  constant T_BIT    : time := 8680 ns;               -- 115200 baud (UART_DIV 434)

  type t_bytes is array (0 to 2047) of std_logic_vector(7 downto 0);

  signal stop : boolean := false;
  signal osc_a, osc_b : std_logic := '0';
  signal rst_n_a, rst_n_b : std_logic := '0';
  signal msel : std_logic;

  -- J3
  signal a_sclk, b_sclk : std_logic := '0';
  signal a_cs_n, b_cs_n : std_logic := '1';
  signal a_io, b_io     : std_logic_vector(7 downto 0);
  signal a_drv, b_drv   : std_logic_vector(7 downto 0) := (others => 'Z');
  signal a_irq_n, b_irq_n : std_logic;

  -- SFP pins
  signal a_td_p, a_td_n, b_td_p, b_td_n : std_logic;
  signal a_rd_p, b_rd_p : std_logic := '0';
  signal a_rd_n, b_rd_n : std_logic := '1';
  signal a_scl, a_sda, b_scl, b_sda : std_logic;
  signal a_led_l, a_led_a, b_led_l, b_led_a : std_logic;

  -- trace file (shared by the trace and annotation processes)
  file trace : text open write_mode is "sim/out/" & NAME & "_trace.txt";

  function sl_str(v : std_logic_vector) return string is
    variable s : string(1 to v'length);
    variable k : natural := 1;
  begin
    for i in v'range loop
      s(k) := std_logic'image(v(i))(2);
      k := k + 1;
    end loop;
    return s;
  end function;

  function hex2(b : std_logic_vector(7 downto 0)) return string is
  begin
    return to_hstring(b);
  end function;

  -- printable form of a data byte for the annotations
  function chr(b : std_logic_vector(7 downto 0)) return string is
    variable n : natural := to_integer(unsigned(b));
  begin
    if n >= 33 and n <= 126 then
      return "'" & character'val(n) & "'";
    elsif n = 32 then
      return "' '";
    end if;
    return hex2(b);
  end function;

  -- time in fs without the unit (time'image is 64 bit; GHDL prints fs)
  function tstr(t : time) return string is
    constant s : string := time'image(t);
  begin
    for i in s'range loop
      if s(i) = ' ' then
        return s(s'left to i - 1);
      end if;
    end loop;
    return s;
  end function;

  procedure annot(t0, t1 : time; row : string; txt : string) is
    variable l : line;
  begin
    write(l, "A " & tstr(t0) & " " & tstr(t1) & " " & row & " " & txt);
    writeline(trace, l);
  end procedure;

  procedure marker(m : string) is
    variable l : line;
  begin
    write(l, "M " & tstr(now) & " " & m);
    writeline(trace, l);
  end procedure;

  -- expected frames
  constant HELLO : string := "Hello, SFP!";
  function f_len(f : natural) return natural is
  begin
    if f = 0 then return HELLO'length; else return 64; end if;
  end function;
  function f_byte(f, i : natural) return std_logic_vector is
  begin
    if f = 0 then
      return std_logic_vector(to_unsigned(character'pos(HELLO(i + 1)), 8));
    end if;
    return std_logic_vector(to_unsigned((i * 3 + 1) mod 256, 8));
  end function;

  signal uart_rx_q  : t_bytes;                       -- bytes received on B UART_TX
  signal uart_rx_n  : natural := 0;
  signal uart_ferr  : natural := 0;

begin

  osc_a <= not osc_a after T_OSC_A / 2 when not stop;
  osc_b <= not osc_b after T_OSC_B / 2 when not stop;
  msel  <= '0' when LINES = 0 else '1';

  -- J3 buses: pull-ups, host drivers
  a_io <= (others => 'H');
  b_io <= (others => 'H');
  a_io <= a_drv;
  b_io <= b_drv;

  -- I2C: pull-ups only
  a_scl <= 'H'; a_sda <= 'H'; b_scl <= 'H'; b_sda <= 'H';

  -- line: TD of one end -> RD of the other (both directions)
  b_rd_p <= transport a_td_p after LINE_DLY;
  b_rd_n <= transport a_td_n after LINE_DLY;
  a_rd_p <= transport b_td_p after LINE_DLY;
  a_rd_n <= transport b_td_n after LINE_DLY;

  ua : entity work.sfp_bridge_top
    generic map (MG_DEB_ABS_CLKS => 50, MG_DEB_SIG_CLKS => 10,
                 LED_ACT_CLKS => 500, LED_BLINK_CLKS => 5000)
    port map (clk_25m => osc_a,
              sfp_td_p => a_td_p, sfp_td_n => a_td_n, sfp_rd_p => a_rd_p, sfp_rd_n => a_rd_n,
              sfp_tx_dis => open, sfp_tx_fault => '0', sfp_los => '0', sfp_mod_abs => '0',
              sfp_scl => a_scl, sfp_sda => a_sda,
              xspi_sclk => a_sclk, xspi_cs_n => a_cs_n, xspi_io => a_io, xspi_dqs => open,
              host_irq_n => a_irq_n, host_rst_n => rst_n_a, mode_sel => msel,
              led_link => a_led_l, led_act => a_led_a);

  ub : entity work.sfp_bridge_top
    generic map (MG_DEB_ABS_CLKS => 50, MG_DEB_SIG_CLKS => 10,
                 LED_ACT_CLKS => 500, LED_BLINK_CLKS => 5000)
    port map (clk_25m => osc_b,
              sfp_td_p => b_td_p, sfp_td_n => b_td_n, sfp_rd_p => b_rd_p, sfp_rd_n => b_rd_n,
              sfp_tx_dis => open, sfp_tx_fault => '0', sfp_los => '0', sfp_mod_abs => '0',
              sfp_scl => b_scl, sfp_sda => b_sda,
              xspi_sclk => b_sclk, xspi_cs_n => b_cs_n, xspi_io => b_io, xspi_dqs => open,
              host_irq_n => b_irq_n, host_rst_n => rst_n_b, mode_sel => msel,
              led_link => b_led_l, led_act => b_led_a);

  ------------------------------------------------------------------------------
  -- Trace: pins of both bridges and the line A -> B
  ------------------------------------------------------------------------------
  tr_sig : process
    variable l : line;
    procedure decl(id : natural; nm : string; w : natural) is
    begin
      write(l, "S " & integer'image(id) & " " & nm & " " & integer'image(w));
      writeline(trace, l);
    end procedure;
    procedure val(id : natural; v : string) is
    begin
      write(l, "V " & tstr(now) & " " & integer'image(id) & " " & v);
      writeline(trace, l);
    end procedure;
  begin
    decl(0, "A.SCLK", 1);  decl(1, "A.CS_N", 1);  decl(2, "A.IO", 8);
    decl(3, "LINE_A_B", 1);
    decl(4, "B.SCLK", 1);  decl(5, "B.CS_N", 1);  decl(6, "B.IO", 8);
    decl(7, "A.HOST_IRQ_N", 1); decl(8, "B.HOST_IRQ_N", 1);
    decl(9, "A.LED_LINK", 1); decl(10, "B.LED_LINK", 1);
    loop
      if a_sclk'event or now = 0 ns then val(0, sl_str((0 => a_sclk))); end if;
      if a_cs_n'event or now = 0 ns then val(1, sl_str((0 => a_cs_n))); end if;
      if a_io'event or now = 0 ns then val(2, sl_str(a_io)); end if;
      if a_td_p'event or now = 0 ns then val(3, sl_str((0 => a_td_p))); end if;
      if b_sclk'event or now = 0 ns then val(4, sl_str((0 => b_sclk))); end if;
      if b_cs_n'event or now = 0 ns then val(5, sl_str((0 => b_cs_n))); end if;
      if b_io'event or now = 0 ns then val(6, sl_str(b_io)); end if;
      if a_irq_n'event or now = 0 ns then val(7, sl_str((0 => a_irq_n))); end if;
      if b_irq_n'event or now = 0 ns then val(8, sl_str((0 => b_irq_n))); end if;
      if a_led_l'event or now = 0 ns then val(9, sl_str((0 => a_led_l))); end if;
      if b_led_l'event or now = 0 ns then val(10, sl_str((0 => b_led_l))); end if;
      wait on a_sclk, a_cs_n, a_io, a_td_p, b_sclk, b_cs_n, b_io, a_irq_n, b_irq_n, a_led_l, b_led_l;
    end loop;
  end process;

  -- Characters of the link: sent by A (encoder input) and received by B
  -- (decoder output); internal signals reached through external names.
  tr_chars : process
    alias a_cd  is << signal ua.cd      : std_logic_vector(7 downto 0) >>;
    alias a_ck  is << signal ua.ck      : std_logic >>;
    alias a_en  is << signal ua.char_en : std_logic >>;
    alias a_clk is << signal ua.clk_sys : std_logic >>;
    alias b_dd  is << signal ub.dd      : std_logic_vector(7 downto 0) >>;
    alias b_dk  is << signal ub.dk      : std_logic >>;
    alias b_dv  is << signal ub.dv      : std_logic >>;
    alias b_clk is << signal ub.clk_sys : std_logic >>;
    constant T_CHAR : time := 100 ns;
    function kname(d : std_logic_vector(7 downto 0)) return string is
    begin
      case d is
        when x"BC"  => return "K28.5";
        when x"FB"  => return "SOF";
        when x"FD"  => return "EOF";
        when x"FE"  => return "ERR";
        when others => return "K" & hex2(d);
      end case;
    end function;
  begin
    wait until rising_edge(a_clk) or rising_edge(b_clk);
    if rising_edge(a_clk) and a_en = '1' then
      if a_ck = '1' then
        annot(now, now + T_CHAR, "A_TX", kname(a_cd));
      else
        annot(now, now + T_CHAR, "A_TX", hex2(a_cd));
      end if;
    end if;
    if rising_edge(b_clk) and b_dv = '1' then
      if b_dk = '1' then
        annot(now - T_CHAR, now, "B_RX", kname(b_dd));
      else
        annot(now - T_CHAR, now, "B_RX", hex2(b_dd));
      end if;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- UART device at B (receiver on UART_TX = J3 IO1 of B)
  ------------------------------------------------------------------------------
  uart_mon : process
    variable b  : std_logic_vector(7 downto 0);
    variable t0 : time;
  begin
    if LINES /= 0 then
      wait;
    end if;
    wait until to_x01(b_io(1)) = '0';
    t0 := now;
    wait for T_BIT / 2;
    if to_x01(b_io(1)) = '0' then                    -- start bit confirmed
      for i in 0 to 7 loop
        wait for T_BIT;
        b(i) := to_x01(b_io(1));
      end loop;
      wait for T_BIT;
      if to_x01(b_io(1)) /= '1' then
        uart_ferr <= uart_ferr + 1;
      end if;
      uart_rx_q(uart_rx_n) <= b;
      uart_rx_n <= uart_rx_n + 1;
      annot(t0, now + T_BIT / 2, "B_IO", chr(b));
      if to_x01(b_io(1)) /= '1' then
        wait until to_x01(b_io(1)) = '1';
      end if;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- Hosts
  ------------------------------------------------------------------------------
  hosts : process
    variable wd, rd : t_bytes;
    variable n, lvl : natural;
    variable st     : std_logic_vector(7 downto 0);
    variable got    : t_bytes;                       -- bytes read by host B
    variable n_got  : natural := 0;
    variable p, f, ln : natural;
    variable bad    : natural;
    variable v      : std_logic_vector(31 downto 0);

    -- one SCLK cycle on side s (0 = A, 1 = B): drive unit u on the lines of
    -- mask, sample at the rising edge
    procedure cycle(s : natural; u, mask : std_logic_vector(7 downto 0);
                    smp : out std_logic_vector(7 downto 0)) is
      variable dv : std_logic_vector(7 downto 0);
    begin
      for i in 0 to 7 loop
        if mask(i) = '1' then dv(i) := u(i); else dv(i) := 'Z'; end if;
      end loop;
      if s = 0 then a_drv <= dv; else b_drv <= dv; end if;
      wait for T_SCK / 2;
      if s = 0 then a_sclk <= '1'; smp := to_x01(a_io);
      else          b_sclk <= '1'; smp := to_x01(b_io); end if;
      wait for T_SCK / 2;
      if s = 0 then a_sclk <= '0'; else b_sclk <= '0'; end if;
    end procedure;

    -- transaction: opcode (1 line), optional address (1 line), dummy
    -- cycles, nbytes data on w lines (w = 1: host -> IO0, bridge -> IO1)
    procedure xfer(s : natural; op : std_logic_vector(7 downto 0); opname : string;
                   use_addr : boolean; adr : natural; dummy : natural; w : natural;
                   is_read : boolean; nbytes : natural; wdat : t_bytes; rdat : out t_bytes;
                   show : boolean := true) is
      variable smp  : std_logic_vector(7 downto 0);
      variable b    : std_logic_vector(7 downto 0);
      variable mask : std_logic_vector(7 downto 0);
      variable t0   : time;
      variable row  : string(1 to 4);
    begin
      if s = 0 then row := "A_IO"; else row := "B_IO"; end if;
      if s = 0 then a_cs_n <= '0'; else b_cs_n <= '0'; end if;
      wait for T_SCK / 2;
      t0 := now;
      for i in 7 downto 0 loop
        cycle(s, (0 => op(i), others => '0'), x"01", smp);
      end loop;
      if show then annot(t0, now, row, opname); end if;
      if use_addr then
        t0 := now;
        b := std_logic_vector(to_unsigned(adr, 8));
        for i in 7 downto 0 loop
          cycle(s, (0 => b(i), others => '0'), x"01", smp);
        end loop;
        if show then annot(t0, now, row, "adr " & hex2(b)); end if;
      end if;
      if dummy > 0 then
        t0 := now;
        for i in 1 to dummy loop
          cycle(s, x"00", x"00", smp);
        end loop;
        if show then annot(t0, now, row, "dummy"); end if;
      end if;
      case w is
        when 1      => mask := x"01";
        when 4      => mask := x"0F";
        when others => mask := x"FF";
      end case;
      for k in 0 to nbytes - 1 loop
        t0 := now;
        b  := wdat(k);
        case w is
          when 1 =>
            for i in 7 downto 0 loop
              if is_read then
                cycle(s, x"00", x"00", smp); rdat(k)(i) := smp(1);
              else
                cycle(s, (0 => b(i), others => '0'), mask, smp);
              end if;
            end loop;
          when 4 =>
            if is_read then
              cycle(s, x"00", x"00", smp); rdat(k)(7 downto 4) := smp(3 downto 0);
              cycle(s, x"00", x"00", smp); rdat(k)(3 downto 0) := smp(3 downto 0);
            else
              cycle(s, x"0" & b(7 downto 4), mask, smp);
              cycle(s, x"0" & b(3 downto 0), mask, smp);
            end if;
          when others =>
            if is_read then
              cycle(s, x"00", x"00", smp); rdat(k) := smp;
            else
              cycle(s, b, mask, smp);
            end if;
        end case;
        if show then
          if is_read then annot(t0, now, row, chr(rdat(k)));
          else annot(t0, now, row, chr(b)); end if;
        end if;
      end loop;
      wait for T_SCK / 2;
      if s = 0 then a_drv <= (others => 'Z'); a_cs_n <= '1';
      else          b_drv <= (others => 'Z'); b_cs_n <= '1'; end if;
      wait for T_CSH;
    end procedure;

    procedure read_status(s : natural; sv : out std_logic_vector(7 downto 0)) is
      variable r : t_bytes;
    begin
      xfer(s, OP_READ_STATUS, "READ_STATUS", false, 0, 0, 1, true, 1, wd, r, false);
      sv := r(0);
    end procedure;

    procedure read_reg(s, adr, nb : natural; r : out t_bytes) is
    begin
      xfer(s, OP_READ_REG, "READ_REG", true, adr, 8, 1, true, nb, wd, r);
    end procedure;

    impure function cnt(r : t_bytes) return natural is
    begin
      return to_integer(unsigned(std_logic_vector'(r(3) & r(2) & r(1) & r(0))));
    end function;

    -- UART device at A: one byte on UART_RX (J3 IO0 of A)
    procedure uart_send(b : std_logic_vector(7 downto 0)) is
      variable t0 : time;
    begin
      t0 := now;
      a_drv(0) <= '0';
      wait for T_BIT;
      for i in 0 to 7 loop
        a_drv(0) <= b(i);
        wait for T_BIT;
      end loop;
      a_drv(0) <= '1';
      wait for T_BIT;
      annot(t0, now, "A_IO", chr(b));
    end procedure;

    variable op_w, op_r : std_logic_vector(7 downto 0);
    variable nm_w, nm_r : string(1 to 10);

  begin
    case LINES is
      when 1      => op_w := OP_TX_WRITE_1; op_r := OP_RX_READ_1; nm_w := "TX_WRITE_1"; nm_r := "RX_READ_1 ";
      when 4      => op_w := OP_TX_WRITE_4; op_r := OP_RX_READ_4; nm_w := "TX_WRITE_4"; nm_r := "RX_READ_4 ";
      when others => op_w := OP_TX_WRITE_8; op_r := OP_RX_READ_8; nm_w := "TX_WRITE_8"; nm_r := "RX_READ_8 ";
    end case;
    if LINES = 0 then
      a_drv(0) <= '1';                               -- UART line idle
    end if;

    -- 1. reset, link up
    wait for 1 us;
    rst_n_a <= '1';
    rst_n_b <= '1';
    marker("reset_released");
    if LINES = 0 then
      wait for 100 us;                               -- PLL lock (model: 50 us), reset
      if a_irq_n /= '1' then
        wait until a_irq_n = '1' for 2 ms;
      end if;
      check_equal(a_irq_n, '1', "1: link up at A (HOST_IRQ_N = 1 in the UART mode)");
      check_equal(b_irq_n, '1', "1: link up at B");
    else
      -- bridges answer READ_ID after the PLL locks and the reset ends
      -- (undriven lines read as 1 through the pull-ups)
      for s in 0 to 1 loop
        for i in 1 to 200 loop
          xfer(s, OP_READ_ID, "READ_ID", false, 0, 0, 1, true, 2, wd, rd, false);
          exit when rd(0) = x"5B" and rd(1) = x"5F";
          wait for 1 us;
        end loop;
        check(rd(0) = x"5B" and rd(1) = x"5F", "1: READ_ID of bridge " & integer'image(s));
      end loop;
      marker("bridges_ready");
      for i in 1 to 2000 loop
        read_status(0, st);
        exit when st(0) = '1';
        wait for 1 us;
      end loop;
      check_equal(st(0), '1', "1: LINK_UP at A");
      read_status(1, st);
      check_equal(st(0), '1', "1: LINK_UP at B");
    end if;
    marker("link_up");
    wait for 2 us;

    if LINES = 0 then
      ----------------------------------------------------------- UART
      marker("a_in_start");
      for i in 1 to HELLO'length loop
        uart_send(std_logic_vector(to_unsigned(character'pos(HELLO(i)), 8)));
      end loop;
      marker("a_in_end");
      if uart_rx_n < HELLO'length then
        wait until uart_rx_n = HELLO'length for 5 ms;
      end if;
      marker("b_out_end");
      wait for 50 us;
      check_equal(uart_rx_n, HELLO'length, "3: number of bytes on UART_TX of B");
      bad := 0;
      for i in 0 to HELLO'length - 1 loop
        if uart_rx_q(i) /= f_byte(0, i) then bad := bad + 1; end if;
      end loop;
      check_equal(bad, 0, "3: bytes on UART_TX of B equal to UART_RX of A");
      check_equal(uart_ferr, 0, "3: no framing errors");
      -- 4. HOST_IRQ_N = link state: reset of B drops the link at A
      marker("b_reset");
      rst_n_b <= '0';
      wait until a_irq_n = '0' for 20 us;
      check_equal(a_irq_n, '0', "4: HOST_IRQ_N of A low after the link is lost");
      wait for 5 us;
      rst_n_b <= '1';
      marker("b_reset_end");
      wait until a_irq_n = '1' for 200 us;
      check_equal(a_irq_n, '1', "4: HOST_IRQ_N of A high after the link is back");
      wait for 10 us;
    else
      ----------------------------------------------------------- xSPI
      -- 2. host A: two frames
      for fr in 0 to 1 loop
        n := f_len(fr);
        wd(0) := x"00";
        wd(1) := std_logic_vector(to_unsigned(n / 256, 8));
        wd(2) := std_logic_vector(to_unsigned(n mod 256, 8));
        for i in 0 to n - 1 loop
          wd(3 + i) := f_byte(fr, i);
        end loop;
        read_status(0, st);
        check_equal(st(2), '1', "2: TX_READY at A before frame " & integer'image(fr));
        marker("a_in_start_f" & integer'image(fr));
        xfer(0, op_w, nm_w, false, 0, 0, LINES, false, n + 3, wd, rd);
        marker("a_in_end_f" & integer'image(fr));
      end loop;

      -- 3. host B: poll, RX_LEVEL, RX_READ until both frames are in
      for k in 1 to 200 loop
        read_status(1, st);
        if st(1) = '1' then
          read_reg(1, 16#0C#, 2, rd);
          lvl := to_integer(unsigned(std_logic_vector'(rd(1) & rd(0))));
          marker("b_out_start");
          xfer(1, op_r, nm_r, false, 0, 8, LINES, true, lvl, wd, rd);
          marker("b_out_end");
          for i in 0 to lvl - 1 loop
            got(n_got + i) := rd(i);
          end loop;
          n_got := n_got + lvl;
        end if;
        exit when n_got >= f_len(0) + f_len(1) + 6;
        wait for 2 us;
      end loop;

      check_equal(n_got, f_len(0) + f_len(1) + 6, "3: bytes read by host B");
      p := 0;
      for fr in 0 to 1 loop
        ln := to_integer(unsigned(std_logic_vector'(got(p + 1) & got(p + 2))));
        check_equal(got(p), x"00", "3: TYPE of frame " & integer'image(fr));
        check_equal(ln, f_len(fr), "3: LEN of frame " & integer'image(fr));
        bad := 0;
        for i in 0 to f_len(fr) - 1 loop
          if got(p + 3 + i) /= f_byte(fr, i) then bad := bad + 1; end if;
        end loop;
        check_equal(bad, 0, "3: payload of frame " & integer'image(fr));
        p := p + 3 + f_len(fr);
      end loop;

      -- counters (CSR 0x10 + 4 * index)
      read_reg(0, 16#10# + 4 * CNT_FRAMES_TX, 4, rd);
      check_equal(cnt(rd), 2, "4: FRAMES_TX at A");
      read_reg(1, 16#10# + 4 * CNT_FRAMES_RX, 4, rd);
      check_equal(cnt(rd), 2, "4: FRAMES_RX at B");
      read_reg(1, 16#10# + 4 * CNT_CODE_ERR, 4, rd);
      check_equal(cnt(rd), 0, "4: CODE_ERR at B");
      read_reg(1, 16#10# + 4 * CNT_CRC_ERR, 4, rd);
      check_equal(cnt(rd), 0, "4: CRC_ERR at B");
    end if;

    marker("end");
    stop <= true;
    tb_finish(NAME);
    wait;
  end process;

end architecture sim;
