--------------------------------------------------------------------------------
-- tb_xspi_slave
--
-- Testbench for xspi_slave with a behavioural SPI / QSPI / OSPI master
-- (SDR, mode 0, SCLK 50 MHz, tri-state bus with pull-ups), real FIFOs
-- (TX FIFO 64 B: write side on SCLK, read side on clk_sys; RX FIFO 1 KiB:
-- write side on clk_sys, read side on SCLK) and a model of the latched CSR
-- space (snap array, status_fast). clk_sys = 47 MHz (asynchronous to SCLK).
-- During reset the DUT clock runs continuously (as from host_clk), then
-- SCLK only during transactions.
--
-- Checks:
--   1. READ_ID: 5B 5F VERSION 00; only IO1 driven during the data phase.
--   2. READ_STATUS: status_fast, twice.
--   3. READ_REG at 0x10, 6 bytes: snap(0x10..0x15) (auto-increment).
--   4. WRITE_REG at 0x04 with 3 bytes and at 0x50 with 10 bytes: after CS
--      rises wr_txn has toggled, wr_addr, wr_cnt (3; capped at 8) and the
--      data are correct; no line driven by the slave.
--   5. TX_WRITE_1 / _4 / _8: one frame each (header + payload in one
--      transaction); one frame split over three transactions; every frame
--      reaches the link side intact and is committed without further SCLK
--      edges (checked before the next transaction).
--   6. TX_ABORT after a partial frame: only the following complete frame
--      arrives. A LEN = 0 header directly followed by a frame in the same
--      transaction: both reach the link side, in order. A lone LEN = 0 header
--      is committed at the first edge of the next transaction.
--   7. RX_READ_8 of a whole frame; RX_READ_1 of a header (3 bytes) and
--      RX_READ_4 of its payload; RX_READ_8 of a frame in two parts: all bytes
--      equal the frames written by the link side (prefetched bytes kept
--      between transactions).
--   8. Unknown opcode: nothing driven, nothing written.
--   9. TX FIFO overflow (link side not reading): ev_tx_ovf_t toggles.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.tb_pkg.all;
use work.bridge_pkg.all;
use work.xspi_pkg.all;

entity tb_xspi_slave is
end entity tb_xspi_slave;

architecture sim of tb_xspi_slave is

  constant T_SCK  : time := 20 ns;            -- 50 MHz
  constant T_SYS  : time := 21.3 ns;          -- 47 MHz
  constant T_CSH  : time := 120 ns;           -- CS high between transactions

  type t_bytes is array (natural range <>) of std_logic_vector(7 downto 0);
  subtype t_buf is t_bytes(0 to 511);

  -- expected frames (bytes) for the link reader
  type t_byte_q is protected
    procedure push(b : std_logic_vector(7 downto 0));
    impure function pop return std_logic_vector;
    impure function size return natural;
  end protected t_byte_q;
  type t_byte_q is protected body
    variable q : t_bytes(0 to 4095);
    variable head, cnt : natural := 0;
    procedure push(b : std_logic_vector(7 downto 0)) is
    begin
      q((head + cnt) mod 4096) := b;
      cnt := cnt + 1;
    end procedure;
    impure function pop return std_logic_vector is
      variable b : std_logic_vector(7 downto 0);
    begin
      if cnt = 0 then return "XXXXXXXX"; end if;
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
  shared variable q_tx : t_byte_q;            -- bytes expected at the TX FIFO read side
  shared variable q_rx : t_byte_q;            -- bytes written into the RX FIFO

  signal clk_sys   : std_logic := '0';
  signal stop      : boolean := false;
  signal rst       : std_logic := '1';
  signal sclk      : std_logic := '0';
  signal cs_n      : std_logic := '1';
  signal io_bus    : std_logic_vector(7 downto 0);
  signal m_drv     : std_logic_vector(7 downto 0) := (others => 'Z');
  signal io_in, io_out, io_oe : std_logic_vector(7 downto 0);

  -- CSR model
  type t_snap is array (0 to 255) of std_logic_vector(7 downto 0);
  signal snap        : t_snap;
  signal reg_addr    : unsigned(7 downto 0);
  signal reg_rdata   : std_logic_vector(7 downto 0);
  signal status_fast : std_logic_vector(7 downto 0) := x"A6";
  signal wr_addr     : unsigned(7 downto 0);
  signal wr_data     : t_wr_buf;
  signal wr_cnt      : natural range 0 to WR_MAX;
  signal wr_txn      : std_logic;

  -- FIFOs
  signal tx_wr, tx_commit, tx_commit_prev, tx_abort, tx_full : std_logic;
  signal tx_data     : std_logic_vector(7 downto 0);
  signal tf_rd, tf_valid, tf_empty : std_logic := '0';
  signal tf_rdata    : std_logic_vector(7 downto 0);
  signal rx_rd, rx_valid, rx_empty : std_logic;
  signal rx_data     : std_logic_vector(7 downto 0);
  signal rf_wr, rf_commit : std_logic := '0';
  signal rf_wdata    : std_logic_vector(7 downto 0) := (others => '0');
  signal ovf_t       : std_logic;

  -- link reader
  signal link_run    : boolean := true;
  signal n_tx_bytes, n_tx_bad : natural := 0;
  signal oe_violation : natural := 0;         -- slave drove a line it must not drive
  signal oe_allowed   : std_logic_vector(7 downto 0) := (others => '0');

begin

  clk_gen(clk_sys, T_SYS, stop);

  -- bus: master drivers, slave drivers, pull-ups
  io_bus <= m_drv;
  g_io : for i in 0 to 7 generate
    io_bus(i) <= io_out(i) when io_oe(i) = '1' else 'Z';
    io_bus(i) <= 'H';
  end generate;
  io_in <= to_x01(io_bus);

  -- latched CSR space model
  g_snap : for i in 0 to 255 generate
    snap(i) <= std_logic_vector(to_unsigned((i * 37 + 5) mod 256, 8));
  end generate;
  reg_rdata <= snap(to_integer(reg_addr));

  dut : entity work.xspi_slave
    port map (clk => sclk, rst => rst, cs_n => cs_n, io_in => io_in, io_out => io_out, io_oe => io_oe,
              reg_addr => reg_addr, reg_rdata => reg_rdata, status_fast => status_fast,
              wr_addr => wr_addr, wr_data => wr_data, wr_cnt => wr_cnt, wr_txn => wr_txn,
              tx_wr => tx_wr, tx_data => tx_data, tx_commit => tx_commit, tx_commit_prev => tx_commit_prev,
              tx_abort => tx_abort,
              tx_full => tx_full,
              rx_rd => rx_rd, rx_data => rx_data, rx_valid => rx_valid, rx_empty => rx_empty,
              ev_tx_ovf_t => ovf_t);

  u_tf : entity work.async_fifo
    generic map (DATA_W => 8, ADDR_W => 6, COMMIT_MODE => true, PUB_STABLE => true, WR_FALLING => true)
    port map (wr_clk => sclk, wr_rst => rst, wr_en => tx_wr, wr_data => tx_data,
              wr_commit => tx_commit, wr_commit_prev => tx_commit_prev, wr_abort => tx_abort, full => tx_full, wr_free => open, wr_ovf => open,
              rd_clk => clk_sys, rd_rst => rst, rd_en => tf_rd, rd_data => tf_rdata,
              rd_valid => tf_valid, empty => tf_empty, rd_level => open, rd_udf => open);

  u_rf : entity work.async_fifo
    generic map (DATA_W => 8, ADDR_W => 10, COMMIT_MODE => true, RD_FALLING => true)
    port map (wr_clk => clk_sys, wr_rst => rst, wr_en => rf_wr, wr_data => rf_wdata,
              wr_commit => rf_commit, wr_abort => '0', full => open, wr_free => open, wr_ovf => open,
              rd_clk => sclk, rd_rst => rst, rd_en => rx_rd, rd_data => rx_data,
              rd_valid => rx_valid, empty => rx_empty, rd_level => open, rd_udf => open);

  -- link reader: every byte at the TX FIFO read side is compared
  tf_rd <= '1' when link_run and tf_empty = '0' else '0';
  process (clk_sys)
  begin
    if rising_edge(clk_sys) then
      if tf_valid = '1' then
        n_tx_bytes <= n_tx_bytes + 1;
        if tf_rdata /= q_tx.pop then
          n_tx_bad <= n_tx_bad + 1;
        end if;
      end if;
    end if;
  end process;

  -- the slave may drive only the lines allowed by the current command phase
  process (io_oe)
  begin
    if not is_x(io_oe) and (io_oe and not oe_allowed) /= x"00" then
      oe_violation <= oe_violation + 1;
    end if;
  end process;

  ------------------------------------------------------------------------------
  process
    variable rd  : t_buf;
    variable wd  : t_buf;
    variable n   : natural;
    variable t0  : std_logic;
    variable ok  : boolean;
    variable nb0 : natural;

    -- one SCLK cycle: master outputs unit u (on the lines of mask), samples
    -- at the rising edge
    procedure cycle(u : std_logic_vector(7 downto 0); drive : std_logic_vector(7 downto 0);
                    smp : out std_logic_vector(7 downto 0)) is
    begin
      for i in 0 to 7 loop
        if drive(i) = '1' then m_drv(i) <= u(i); else m_drv(i) <= 'Z'; end if;
      end loop;
      wait for T_SCK / 2;
      sclk <= '1';
      smp := to_x01(io_bus);
      wait for T_SCK / 2;
      sclk <= '0';
    end procedure;

    -- complete transaction
    procedure xfer(op : std_logic_vector(7 downto 0); use_addr : boolean; a : natural;
                   dummy : natural; w : natural; is_read : boolean; nbytes : natural;
                   wdat : t_buf; rdat : out t_buf) is
      variable smp  : std_logic_vector(7 downto 0);
      variable b    : std_logic_vector(7 downto 0);
      variable mask : std_logic_vector(7 downto 0);
    begin
      cs_n <= '0';
      wait for T_SCK / 2;
      for i in 7 downto 0 loop
        cycle((0 => op(i), others => '0'), x"01", smp);
      end loop;
      if use_addr then
        b := std_logic_vector(to_unsigned(a, 8));
        for i in 7 downto 0 loop
          cycle((0 => b(i), others => '0'), x"01", smp);
        end loop;
      end if;
      for i in 1 to dummy loop
        cycle(x"00", x"00", smp);
      end loop;
      case w is
        when 1 => mask := x"01";
        when 4 => mask := x"0F";
        when others => mask := x"FF";
      end case;
      if is_read then
        case w is
          when 1 => oe_allowed <= x"02";
          when 4 => oe_allowed <= x"0F";
          when others => oe_allowed <= x"FF";
        end case;
      end if;
      for k in 0 to nbytes - 1 loop
        b := wdat(k);
        case w is
          when 1 =>
            for i in 7 downto 0 loop
              if is_read then
                cycle(x"00", x"00", smp);
                rdat(k)(i) := smp(1);
              else
                cycle((0 => b(i), others => '0'), mask, smp);
              end if;
            end loop;
          when 4 =>
            if is_read then
              cycle(x"00", x"00", smp); rdat(k)(7 downto 4) := smp(3 downto 0);
              cycle(x"00", x"00", smp); rdat(k)(3 downto 0) := smp(3 downto 0);
            else
              cycle(x"0" & b(7 downto 4), mask, smp);
              cycle(x"0" & b(3 downto 0), mask, smp);
            end if;
          when others =>
            if is_read then
              cycle(x"00", x"00", smp); rdat(k) := smp;
            else
              cycle(b, mask, smp);
            end if;
        end case;
      end loop;
      wait for T_SCK / 2;
      m_drv <= (others => 'Z');
      cs_n <= '1';
      oe_allowed <= x"00";
      wait for T_CSH;
    end procedure;

    -- frame bytes into wd(0..) for id with payload length len; expected at the link
    procedure make_frame(id, len : natural; expect : boolean) is
    begin
      wd(0) := std_logic_vector(to_unsigned(16 + id, 8));
      wd(1) := std_logic_vector(to_unsigned(len / 256, 8));
      wd(2) := std_logic_vector(to_unsigned(len mod 256, 8));
      for i in 0 to len - 1 loop
        wd(3 + i) := std_logic_vector(to_unsigned((id * 31 + i * 7) mod 256, 8));
      end loop;
      if expect then
        for i in 0 to len + 2 loop
          q_tx.push(wd(i));
        end loop;
      end if;
    end procedure;

    -- link side writes a frame into the RX FIFO (clk_sys)
    procedure link_frame(id, len : natural) is
      variable b : std_logic_vector(7 downto 0);
    begin
      for i in 0 to len + 2 loop
        if i = 0 then b := std_logic_vector(to_unsigned(64 + id, 8));
        elsif i = 1 then b := std_logic_vector(to_unsigned(len / 256, 8));
        elsif i = 2 then b := std_logic_vector(to_unsigned(len mod 256, 8));
        else b := std_logic_vector(to_unsigned((id * 13 + i * 3) mod 256, 8));
        end if;
        q_rx.push(b);
        wait until rising_edge(clk_sys);
        rf_wr <= '1'; rf_wdata <= b;
        if i = len + 2 then rf_commit <= '1'; end if;
      end loop;
      wait until rising_edge(clk_sys);
      rf_wr <= '0'; rf_commit <= '0';
    end procedure;

    procedure wait_tx(nbytes : natural) is
    begin
      for i in 1 to 200 loop
        exit when n_tx_bytes >= nbytes;
        wait until rising_edge(clk_sys);
      end loop;
    end procedure;

    procedure check_rx(nbytes : natural; msg : string) is
      variable e : std_logic_vector(7 downto 0);
      variable bad : natural := 0;
    begin
      for i in 0 to nbytes - 1 loop
        e := q_rx.pop;
        if rd(i) /= e then bad := bad + 1; end if;
      end loop;
      check_equal(bad, 0, msg);
    end procedure;

  begin
    -- reset with a running clock (host_clk selects clk_sys in reset)
    rst <= '1';
    for i in 1 to 10 loop
      sclk <= '1'; wait for 10 ns; sclk <= '0'; wait for 10 ns;
    end loop;
    rst <= '0';
    for i in 1 to 4 loop
      sclk <= '1'; wait for 10 ns; sclk <= '0'; wait for 10 ns;
    end loop;
    wait for 200 ns;

    ---------------------------------------------------------------- 1
    xfer(OP_READ_ID, false, 0, 0, 1, true, 4, wd, rd);
    check(rd(0) = x"5B" and rd(1) = x"5F" and rd(2) = BRIDGE_VERSION and rd(3) = x"00",
          "1: READ_ID " & to_hstring(rd(0)) & to_hstring(rd(1)) & to_hstring(rd(2)) & to_hstring(rd(3)));

    ---------------------------------------------------------------- 2
    xfer(OP_READ_STATUS, false, 0, 0, 1, true, 2, wd, rd);
    check(rd(0) = x"A6" and rd(1) = x"A6", "2: READ_STATUS twice");

    ---------------------------------------------------------------- 3
    xfer(OP_READ_REG, true, 16#10#, 8, 1, true, 6, wd, rd);
    ok := true;
    for i in 0 to 5 loop
      if rd(i) /= snap(16#10# + i) then ok := false; end if;
    end loop;
    check(ok, "3: READ_REG 0x10..0x15");

    ---------------------------------------------------------------- 4
    t0 := wr_txn;
    wd(0) := x"11"; wd(1) := x"22"; wd(2) := x"33";
    xfer(OP_WRITE_REG, true, 16#04#, 0, 1, false, 3, wd, rd);
    check(wr_txn /= t0, "4: wr_txn toggled");
    check_equal(to_integer(wr_addr), 4, "4: wr_addr");
    check_equal(wr_cnt, 3, "4: wr_cnt");
    check(wr_data(0) = x"11" and wr_data(1) = x"22" and wr_data(2) = x"33", "4: wr_data");
    t0 := wr_txn;
    for i in 0 to 9 loop wd(i) := std_logic_vector(to_unsigned(i + 1, 8)); end loop;
    xfer(OP_WRITE_REG, true, 16#50#, 0, 1, false, 10, wd, rd);
    check(wr_txn /= t0, "4: wr_txn toggled again");
    check_equal(to_integer(wr_addr), 16#50#, "4: wr_addr 0x50");
    check_equal(wr_cnt, WR_MAX, "4: wr_cnt capped at WR_MAX");
    check(wr_data(7) = x"08", "4: last buffered byte");

    ---------------------------------------------------------------- 5
    nb0 := n_tx_bytes;
    make_frame(1, 20, true);
    xfer(OP_TX_WRITE_1, false, 0, 0, 1, false, 23, wd, rd);
    wait_tx(nb0 + 23);
    check_equal(n_tx_bytes - nb0, 23, "5: TX_WRITE_1 frame committed without further SCLK");
    nb0 := n_tx_bytes;
    make_frame(2, 33, true);
    xfer(OP_TX_WRITE_4, false, 0, 0, 4, false, 36, wd, rd);
    wait_tx(nb0 + 36);
    check_equal(n_tx_bytes - nb0, 36, "5: TX_WRITE_4 frame");
    nb0 := n_tx_bytes;
    make_frame(3, 50, true);
    xfer(OP_TX_WRITE_8, false, 0, 0, 8, false, 53, wd, rd);
    wait_tx(nb0 + 53);
    check_equal(n_tx_bytes - nb0, 53, "5: TX_WRITE_8 frame");
    -- frame split over three transactions: header, 10 bytes, 15 bytes
    nb0 := n_tx_bytes;
    make_frame(4, 25, true);
    xfer(OP_TX_WRITE_8, false, 0, 0, 8, false, 3, wd, rd);
    xfer(OP_TX_WRITE_8, false, 0, 0, 8, false, 10, wd(3 to 12) & wd(0 to 501), rd);
    wait for 1 us;
    check_equal(n_tx_bytes - nb0, 0, "5: split frame not committed before its end");
    xfer(OP_TX_WRITE_1, false, 0, 0, 1, false, 15, wd(13 to 27) & wd(0 to 496), rd);
    wait_tx(nb0 + 28);
    check_equal(n_tx_bytes - nb0, 28, "5: split frame committed");

    ---------------------------------------------------------------- 6
    nb0 := n_tx_bytes;
    make_frame(5, 30, false);
    xfer(OP_TX_WRITE_8, false, 0, 0, 8, false, 12, wd, rd);       -- partial
    xfer(OP_TX_ABORT, false, 0, 0, 1, false, 0, wd, rd);
    make_frame(6, 8, true);
    xfer(OP_TX_WRITE_8, false, 0, 0, 8, false, 11, wd, rd);
    wait_tx(nb0 + 11);
    wait for 1 us;
    check_equal(n_tx_bytes - nb0, 11, "6: only the frame after TX_ABORT");

    -- LEN = 0 frame followed directly by a frame in the same transaction:
    -- both arrive (the LEN = 0 header is committed one edge later, without
    -- the first byte of the next frame)
    nb0 := n_tx_bytes;
    wd(0) := x"77"; wd(1) := x"00"; wd(2) := x"00";
    for i in 0 to 2 loop q_tx.push(wd(i)); end loop;
    make_frame(8, 5, true);
    xfer(OP_TX_WRITE_8, false, 0, 0, 8, false, 11, t_bytes'(x"77", x"00", x"00") & wd(0 to 7) & wd(0 to 500), rd);
    wait_tx(nb0 + 11);
    wait for 1 us;
    check_equal(n_tx_bytes - nb0, 11, "6: LEN = 0 header and the next frame");

    -- LEN = 0 frame alone: committed at the first edge of the next
    -- transaction (here READ_STATUS)
    nb0 := n_tx_bytes;
    wd(0) := x"78"; wd(1) := x"00"; wd(2) := x"00";
    for i in 0 to 2 loop q_tx.push(wd(i)); end loop;
    xfer(OP_TX_WRITE_1, false, 0, 0, 1, false, 3, wd, rd);
    wait for 1 us;
    check_equal(n_tx_bytes - nb0, 0, "6: lone LEN = 0 header not yet committed");
    xfer(OP_READ_STATUS, false, 0, 0, 1, true, 1, wd, rd);
    wait_tx(nb0 + 3);
    check_equal(n_tx_bytes - nb0, 3, "6: lone LEN = 0 header committed by the next transaction");

    ---------------------------------------------------------------- 7
    link_frame(1, 40);
    link_frame(2, 17);
    link_frame(3, 60);
    wait for 1 us;
    xfer(OP_RX_READ_8, false, 0, 8, 8, true, 43, wd, rd);
    check_rx(43, "7: RX_READ_8 whole frame");
    xfer(OP_RX_READ_1, false, 0, 8, 1, true, 3, wd, rd);
    check_rx(3, "7: RX_READ_1 header");
    xfer(OP_RX_READ_4, false, 0, 8, 4, true, 17, wd, rd);
    check_rx(17, "7: RX_READ_4 payload");
    xfer(OP_RX_READ_8, false, 0, 8, 8, true, 30, wd, rd);
    check_rx(30, "7: RX_READ_8 first part");
    xfer(OP_RX_READ_8, false, 0, 8, 8, true, 33, wd, rd);
    check_rx(33, "7: RX_READ_8 second part");
    check_equal(q_rx.size, 0, "7: all RX bytes read");

    ---------------------------------------------------------------- 8
    nb0 := n_tx_bytes;
    t0 := wr_txn;
    for i in 0 to 3 loop wd(i) := x"FF"; end loop;
    xfer(x"A5", false, 0, 0, 8, false, 4, wd, rd);
    wait for 1 us;
    check_equal(n_tx_bytes - nb0, 0, "8: unknown opcode writes nothing");
    check(wr_txn = t0, "8: unknown opcode is not a register write");

    ---------------------------------------------------------------- 9
    link_run <= false;
    t0 := ovf_t;
    make_frame(7, 70, false);                                       -- 73 B > 64 B FIFO
    xfer(OP_TX_WRITE_8, false, 0, 0, 8, false, 73, wd, rd);
    check(ovf_t /= t0, "9: overflow reported");

    check_equal(n_tx_bad, 0, "TX bytes at the link side equal the written frames");
    check_equal(oe_violation, 0, "slave drove only the allowed lines");

    stop <= true;
    tb_finish("tb_xspi_slave");
    wait;
  end process;

end architecture sim;
