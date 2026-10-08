--------------------------------------------------------------------------------
-- tb_csr_regs
--
-- Testbench for csr_regs together with xspi_slave (register access through
-- real SPI transactions, SCLK 40 MHz, clk_sys 50 MHz). The FIFO ports of
-- xspi_slave are idle; the status inputs of csr_regs are driven by the
-- testbench; the soft reset loop of clk_rst is modelled (soft_rst ->
-- rst for 4 cycles).
--
-- Checks:
--   1. READ_REG 0x00..0x02: 5B 5F VERSION; CTRL after reset 0x03.
--   2. WRITE_REG CTRL: the outputs change only after CS rises; read back.
--   3. Latch: a counter changing during a READ_REG transaction is read with
--      its value at the falling edge of CS (all 4 bytes consistent); the
--      next transaction reads the new value.
--   4. TX_SPACE, RX_LEVEL, STATUS, STATUS_FAST (READ_STATUS command).
--   5. IRQ: enabled event -> HOST_IRQ_N = 0, IRQ_STAT read, W1C clears it.
--   6. CTRL.CNT_CLR -> one cnt_clr pulse; reads back as 0.
--   7. CTRL.SOFT_RST -> soft reset: CTRL back to 0x03, MODE_CTRL kept.
--   8. MODE_CTRL: RTSCTS_EN alone without reset; UART_MODE change -> soft
--      reset, mode kept; rst_hard clears MODE_CTRL.
--   9. UART_DIV (2 bytes, little-endian), UART_STATUS W1C.
--  10. sfp_mgmt registers (no module on the bus: pull-ups only): I2C_DEV /
--      OFFSET / LEN and DDM_PERIOD read back; I2C_BUF written with WRITE_REG
--      (8 bytes) and read back with READ_REG; command with the module
--      absent -> BAD_CMD and IRQ I2C_DONE; module present -> BUSY read in
--      the transaction that directly follows the command (CS high 120 ns),
--      then NACK.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.tb_pkg.all;
use work.bridge_pkg.all;
use work.xspi_pkg.all;

entity tb_csr_regs is
end entity tb_csr_regs;

architecture sim of tb_csr_regs is

  constant T_SCK : time := 25 ns;           -- 40 MHz
  constant T_SYS : time := 20 ns;
  constant T_CSH : time := 120 ns;

  type t_bytes is array (natural range <>) of std_logic_vector(7 downto 0);
  subtype t_buf is t_bytes(0 to 15);

  signal clk_sys   : std_logic := '0';
  signal stop      : boolean := false;
  signal rst, rst_hard : std_logic := '1';
  signal rst_tb    : std_logic := '1';       -- testbench part of rst
  signal soft_cnt  : natural := 0;
  signal sclk      : std_logic := '0';
  signal cs_n      : std_logic := '1';
  signal io_bus    : std_logic_vector(7 downto 0);
  signal m_drv     : std_logic_vector(7 downto 0) := (others => 'Z');
  signal io_in, io_out, io_oe : std_logic_vector(7 downto 0);

  signal reg_addr  : unsigned(7 downto 0);
  signal reg_rdata, status_fast : std_logic_vector(7 downto 0);
  signal wr_addr   : unsigned(7 downto 0);
  signal wr_data   : t_wr_buf;
  signal wr_cnt    : natural range 0 to WR_MAX;
  signal wr_txn, ovf_t : std_logic;
  signal rx_data   : std_logic_vector(7 downto 0) := (others => '0');

  -- status inputs
  signal link_state : t_link_state := LS_UP;
  signal st_bits   : std_logic_vector(6 downto 0) := (others => '0');  -- sync, rr, xl, xr, los, fault, abs
  signal mode_sel  : std_logic := '1';
  signal tx_level, rx_level : unsigned(15 downto 0) := (others => '0');
  signal counters  : t_cnt_arr := (others => (others => '0'));
  signal ev        : std_logic_vector(5 downto 0) := (others => '0');  -- rx_frame, link_chg, i2c, err, u_ovf, u_ferr

  -- outputs
  signal tx_en, rx_en, lb_near, sfp_tx_dis, los_ignore, cnt_clr, soft_rst : std_logic;
  signal m_uart, m_echo, m_rtscts, irq_n : std_logic;
  signal uart_div  : unsigned(15 downto 0);
  signal n_clr     : natural := 0;
  signal t_cs_rise, t_cfg : time := 0 ns;   -- last CS rise, last change of rx_en
  signal p3_go     : boolean := false;      -- change a counter inside the next transaction
  signal n_soft    : natural := 0;

  -- sfp_mgmt
  signal wr_apply  : std_logic;
  signal mg_regs   : t_mg_regs;
  signal buf_rdata : std_logic_vector(7 downto 0);
  signal mg_abs    : std_logic := '1';
  signal mg_done   : std_logic;
  signal scl, sda  : std_logic;
  signal scl_oe, sda_oe : std_logic;

begin

  clk_gen(clk_sys, T_SYS, stop);

  io_bus <= m_drv;
  g_io : for i in 0 to 7 generate
    io_bus(i) <= io_out(i) when io_oe(i) = '1' else 'Z';
    io_bus(i) <= 'H';
  end generate;
  io_in <= to_x01(io_bus);

  u_xs : entity work.xspi_slave
    port map (clk => sclk, rst => rst, cs_n => cs_n, io_in => io_in, io_out => io_out, io_oe => io_oe,
              reg_addr => reg_addr, reg_rdata => reg_rdata, status_fast => status_fast,
              wr_addr => wr_addr, wr_data => wr_data, wr_cnt => wr_cnt, wr_txn => wr_txn,
              tx_wr => open, tx_data => open, tx_commit => open, tx_commit_prev => open,
              tx_abort => open, tx_full => '0',
              rx_rd => open, rx_data => rx_data, rx_valid => '0', rx_empty => '1',
              ev_tx_ovf_t => ovf_t);

  dut : entity work.csr_regs
    port map (clk => clk_sys, rst => rst, rst_hard => rst_hard,
              cs_n => cs_n, reg_addr => reg_addr, reg_rdata => reg_rdata, status_fast => status_fast,
              wr_addr => wr_addr, wr_data => wr_data, wr_cnt => wr_cnt, wr_txn => wr_txn,
              ev_tx_ovf_t => ovf_t,
              wr_apply => wr_apply, mg_regs => mg_regs, buf_rdata => buf_rdata,
              link_state => link_state, rx_sync => st_bits(0), remote_ready => st_bits(1),
              xoff_local => st_bits(2), xoff_remote => st_bits(3), sfp_los => st_bits(4),
              sfp_tx_fault => st_bits(5), sfp_mod_abs => st_bits(6), mode_sel => mode_sel,
              tx_level => tx_level, rx_level => rx_level, counters => counters,
              ev_rx_frame => ev(0), ev_link_chg => ev(1), ev_i2c_done => mg_done, ev_err => ev(3),
              ev_uart_ovf => ev(4), ev_uart_ferr => ev(5),
              cfg_tx_en => tx_en, cfg_rx_en => rx_en, cfg_lb_near => lb_near,
              cfg_sfp_tx_dis => sfp_tx_dis, cfg_los_ignore => los_ignore, cnt_clr => cnt_clr,
              soft_rst => soft_rst, mode_uart => m_uart, mode_echo => m_echo, mode_rtscts => m_rtscts,
              uart_div => uart_div, irq_n => irq_n);

  scl <= 'H';
  sda <= 'H';
  scl <= '0' when scl_oe = '1' else 'Z';
  sda <= '0' when sda_oe = '1' else 'Z';

  u_mg : entity work.sfp_mgmt
    generic map (TIMEOUT_CLKS => 25_000, TICK_CLKS => 1000, INSERT_TICKS => 1000,
                 DEB_ABS_CLKS => 20, DEB_SIG_CLKS => 5)
    port map (clk => clk_sys, rst => rst,
              los_pin => '0', fault_pin => '0', abs_pin => mg_abs, tx_dis_pin => open,
              scl_i => to_x01(scl), sda_i => to_x01(sda), scl_oe => scl_oe, sda_oe => sda_oe,
              sfp_los => open, sfp_tx_fault => open, sfp_mod_abs => open, cfg_tx_dis => sfp_tx_dis,
              wr_apply => wr_apply, wr_addr => wr_addr, wr_data => wr_data, wr_cnt => wr_cnt,
              regs => mg_regs, buf_raddr => reg_addr(6 downto 0), buf_rdata => buf_rdata,
              ev_i2c_done => mg_done);

  -- clk_rst model: soft_rst asserts rst for 4 cycles; the host side (here
  -- xspi_slave) also sees rst
  process (clk_sys)
  begin
    if rising_edge(clk_sys) then
      if soft_rst = '1' and soft_cnt = 0 then
        soft_cnt <= 4;
        n_soft   <= n_soft + 1;
      elsif soft_cnt > 0 then
        soft_cnt <= soft_cnt - 1;
      end if;
      if cnt_clr = '1' then n_clr <= n_clr + 1; end if;
    end if;
  end process;
  rst <= '1' when rst_tb = '1' or rst_hard = '1' or soft_cnt > 0 or soft_rst = '1' else '0';

  process (cs_n, rx_en)
  begin
    if rising_edge(cs_n) then t_cs_rise <= now; end if;
    if rx_en'event then t_cfg <= now; end if;
  end process;

  -- phase 3: change FRAMES_TX 300 ns after CS falls (inside the transaction)
  process
  begin
    counters(CNT_FRAMES_TX) <= x"11223344";
    wait until p3_go;
    wait until falling_edge(cs_n);
    wait for 300 ns;
    counters(CNT_FRAMES_TX) <= x"55667788";
    wait;
  end process;

  process
    variable rd, wd : t_buf;
    variable v      : std_logic_vector(31 downto 0);

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

    -- 1-1-1 / 1-0-1 transaction; hold: extra time with CS low after the data
    procedure xfer(op : std_logic_vector(7 downto 0); use_addr : boolean; a : natural;
                   dummy : natural; is_read : boolean; nbytes : natural;
                   wdat : t_buf; rdat : out t_buf; hold : time := 0 ns) is
      variable smp : std_logic_vector(7 downto 0);
      variable b   : std_logic_vector(7 downto 0);
    begin
      cs_n <= '0';
      wait for T_SCK / 2;
      for i in 7 downto 0 loop cycle((0 => op(i), others => '0'), x"01", smp); end loop;
      if use_addr then
        b := std_logic_vector(to_unsigned(a, 8));
        for i in 7 downto 0 loop cycle((0 => b(i), others => '0'), x"01", smp); end loop;
      end if;
      for i in 1 to dummy loop cycle(x"00", x"00", smp); end loop;
      for k in 0 to nbytes - 1 loop
        b := wdat(k);
        for i in 7 downto 0 loop
          if is_read then
            cycle(x"00", x"00", smp); rdat(k)(i) := smp(1);
          else
            cycle((0 => b(i), others => '0'), x"01", smp);
          end if;
        end loop;
      end loop;
      wait for T_SCK / 2 + hold;
      m_drv <= (others => 'Z');
      cs_n <= '1';
      wait for T_CSH;
    end procedure;

    procedure rreg(a, n : natural) is
    begin
      xfer(OP_READ_REG, true, a, 8, true, n, wd, rd);
    end procedure;

    procedure wreg(a : natural; d : std_logic_vector(7 downto 0)) is
    begin
      wd(0) := d;
      xfer(OP_WRITE_REG, true, a, 0, false, 1, wd, rd);
    end procedure;

    procedure sys_cycles(n : natural) is
    begin
      for i in 1 to n loop wait until rising_edge(clk_sys); end loop;
      wait for 1 ns;
    end procedure;

  begin
    -- reset: the slave gets clock edges (host_clk = clk_sys in reset)
    rst_hard <= '1'; rst_tb <= '1';
    for i in 1 to 8 loop sclk <= '1'; wait for 10 ns; sclk <= '0'; wait for 10 ns; end loop;
    rst_hard <= '0'; rst_tb <= '0';
    for i in 1 to 4 loop sclk <= '1'; wait for 10 ns; sclk <= '0'; wait for 10 ns; end loop;
    wait for 200 ns;

    ---------------------------------------------------------------- 1
    rreg(16#00#, 5);
    check(rd(0) = x"5B" and rd(1) = x"5F" and rd(2) = BRIDGE_VERSION, "1: ID and VERSION");
    check_equal(rd(4), x"03", "1: CTRL after reset");

    ---------------------------------------------------------------- 2
    wd(0) := x"15";
    xfer(OP_WRITE_REG, true, 16#04#, 0, false, 1, wd, rd, 400 ns);   -- CS held low 400 ns
    sys_cycles(5);
    check(t_cfg > t_cs_rise - 1 ns and t_cfg < t_cs_rise + 200 ns,
          "2: CTRL applied after CS rises (rx_en changed " & time'image(t_cfg - t_cs_rise) & " after)");
    check(tx_en = '1' and rx_en = '0' and lb_near = '1' and sfp_tx_dis = '0' and los_ignore = '1',
          "2: CTRL outputs after the write");
    rreg(16#04#, 1);
    check_equal(rd(0), x"15", "2: CTRL read back");
    wreg(16#04#, x"03");

    ---------------------------------------------------------------- 3
    p3_go <= true;
    wait for 1 ns;
    rreg(16#24#, 4);
    v := rd(3) & rd(2) & rd(1) & rd(0);
    check_equal(v, x"11223344", "3: counter value latched at the falling edge of CS");
    rreg(16#24#, 4);
    v := rd(3) & rd(2) & rd(1) & rd(0);
    check_equal(v, x"55667788", "3: new value in the next transaction");

    ---------------------------------------------------------------- 4
    tx_level <= to_unsigned(1000, 16);
    rx_level <= to_unsigned(300, 16);
    st_bits  <= "1010101";
    sys_cycles(2);
    rreg(16#05#, 1);
    check_equal(rd(0), "1010101" & '1', "4: STATUS");
    rreg(16#0A#, 4);
    v(15 downto 0) := rd(1) & rd(0);
    check_equal(to_integer(unsigned(v(15 downto 0))), 4096 - 1000, "4: TX_SPACE");
    v(15 downto 0) := rd(3) & rd(2);
    check_equal(to_integer(unsigned(v(15 downto 0))), 300, "4: RX_LEVEL");
    xfer(OP_READ_STATUS, false, 0, 0, true, 1, wd, rd);
    -- LINK_UP 1, RX_AVAIL 1, TX_READY 1 (3096 >= 1027), TX_EMPTY 0, IRQ 0, MODE_SEL 1
    check_equal(rd(0), "00100111", "4: STATUS_FAST");

    ---------------------------------------------------------------- 5
    wreg(16#08#, x"FF");                      -- clear IRQ_STAT (SFP_CHG from phase 4)
    wreg(16#07#, x"01");                      -- IRQ_EN: RX_FRAME
    check_equal(irq_n, '1', "5: no IRQ yet");
    wait until rising_edge(clk_sys); ev(0) <= '1';
    wait until rising_edge(clk_sys); ev(0) <= '0';
    ev(1) <= '1';                             -- LINK_CHG (not enabled)
    wait until rising_edge(clk_sys); ev(1) <= '0';
    sys_cycles(3);
    check_equal(irq_n, '0', "5: HOST_IRQ_N low");
    rreg(16#08#, 1);
    check_equal(rd(0), x"05", "5: IRQ_STAT = RX_FRAME | LINK_CHG");
    wreg(16#08#, x"01");                      -- W1C RX_FRAME
    sys_cycles(3);
    check_equal(irq_n, '1', "5: HOST_IRQ_N released after W1C");
    rreg(16#08#, 1);
    check_equal(rd(0), x"04", "5: LINK_CHG still set");

    ---------------------------------------------------------------- 6
    wreg(16#04#, x"43");
    sys_cycles(3);
    check_equal(n_clr, 1, "6: one cnt_clr pulse");
    rreg(16#04#, 1);
    check_equal(rd(0), x"03", "6: CNT_CLR reads as 0");

    ---------------------------------------------------------------- 7
    wreg(16#50#, x"04");                      -- RTSCTS only
    sys_cycles(10);
    check_equal(n_soft, 0, "8: RTSCTS_EN alone does not reset");
    check_equal(m_rtscts, '1', "8: RTSCTS_EN set");
    wreg(16#04#, x"17");
    wreg(16#04#, x"97");                      -- SOFT_RST
    sys_cycles(10);
    check_equal(n_soft, 1, "7: soft reset");
    rreg(16#04#, 1);
    check_equal(rd(0), x"03", "7: CTRL back to 0x03");
    check_equal(m_rtscts, '1', "7: MODE_CTRL kept over the soft reset");

    ---------------------------------------------------------------- 8
    wreg(16#50#, x"05");                      -- UART_MODE change
    sys_cycles(10);
    check_equal(n_soft, 2, "8: UART_MODE change resets the bridge");
    check_equal(m_uart, '1', "8: UART_MODE kept after its reset");
    rst_hard <= '1';
    sys_cycles(3);
    rst_hard <= '0';
    sys_cycles(3);
    check(m_uart = '0' and m_rtscts = '0', "8: rst_hard clears MODE_CTRL");

    ---------------------------------------------------------------- 9
    wd(0) := x"36"; wd(1) := x"01";
    xfer(OP_WRITE_REG, true, 16#51#, 0, false, 2, wd, rd);
    sys_cycles(3);
    check_equal(to_integer(uart_div), 16#0136#, "9: UART_DIV");
    wait until rising_edge(clk_sys); ev(5) <= '1';
    wait until rising_edge(clk_sys); ev(5) <= '0';
    sys_cycles(2);
    rreg(16#53#, 1);
    check_equal(rd(0), x"02", "9: UART_STATUS FRAME_ERR");
    wreg(16#53#, x"02");
    rreg(16#53#, 1);
    check_equal(rd(0), x"00", "9: UART_STATUS cleared");

    ---------------------------------------------------------------- 10
    wd(0) := x"50"; wd(1) := x"10"; wd(2) := x"04";
    xfer(OP_WRITE_REG, true, 16#30#, 0, false, 3, wd, rd);
    rreg(16#30#, 3);
    check(rd(0) = x"50" and rd(1) = x"10" and rd(2) = x"04", "10: I2C_DEV / OFFSET / LEN read back");
    for i in 0 to 7 loop
      wd(i) := std_logic_vector(to_unsigned(16#A0# + 3 * i, 8));
    end loop;
    xfer(OP_WRITE_REG, true, 16#80#, 0, false, 8, wd, rd);
    rreg(16#80#, 8);
    for i in 0 to 7 loop
      check_equal(rd(i), wd(i), "10: I2C_BUF byte " & integer'image(i));
    end loop;
    wreg(16#4F#, x"05");
    rreg(16#4F#, 1);
    check_equal(rd(0), x"05", "10: DDM_PERIOD read back");
    wreg(16#08#, x"FF");
    wreg(16#07#, x"10");                      -- IRQ_EN: I2C_DONE
    wreg(16#33#, x"01");                      -- READ, module absent
    rreg(16#34#, 1);
    check_equal(rd(0), x"08", "10: BAD_CMD with the module absent");
    check_equal(irq_n, '0', "10: IRQ I2C_DONE");
    wreg(16#08#, x"10");
    mg_abs <= '0';
    sys_cycles(50);
    wreg(16#33#, x"01");                      -- READ, no slave answers
    rreg(16#34#, 1);
    check_equal(rd(0), x"01", "10: BUSY in the next transaction");
    if mg_done /= '1' then
      wait until mg_done = '1' for 2 ms;
    end if;
    sys_cycles(3);
    rreg(16#34#, 1);
    check_equal(rd(0), x"02", "10: NACK without a module answer");
    check_equal(irq_n, '0', "10: IRQ I2C_DONE after the command");

    stop <= true;
    tb_finish("tb_csr_regs");
    wait;
  end process;

end architecture sim;
