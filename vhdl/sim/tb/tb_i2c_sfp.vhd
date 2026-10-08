--------------------------------------------------------------------------------
-- tb_i2c_sfp
--
-- Testbench for sfp_mgmt with i2c_master. clk = 50 MHz, I2C 100 kHz; the
-- slow timers are shortened (100 ms tick = 0.5 ms, insertion delay 4 ticks,
-- SCL timeout 500 us, filters 10 us / 1 us).
--
-- SFP module model: 2-wire slave at 0x50 (A0h) and 0x51 (A2h), 256 B each,
-- offset write, sequential read with a repeated START, sequential write;
-- optional clock stretching after every acknowledge; no response when the
-- module is absent. Bus with pull-ups ('H'), open-drain drivers.
--
-- Checks:
--   1. Reset: TX_DIS pin '1' during reset, then CTRL.SFP_TX_DIS; filtered
--      MOD_ABS / LOS follow the pins immediately after reset.
--   2. Command with the module absent -> BAD_CMD, I2C_DONE, no bus activity.
--   3. Insertion with contact bounce: MOD_ABS changes once, after the
--      filter time; LOS pulse shorter than the filter ignored, longer passed;
--      no bus activity during the insertion delay.
--   4. Host READ A0h (16 B and 128 B): BUSY visible in the cycle after
--      wr_apply, buffer equals the module memory, I2C_DONE once.
--   5. Host WRITE A2h 8 B (buffer bytes written through wr_apply, 2
--      transactions): module memory updated.
--   6. NACK (device 0x52); BAD_CMD for LEN = 0, LEN = 129 and a command
--      while BUSY (the running command completes correctly).
--   7. DDM polling: values little-endian in 0x40-0x49, DDM_FLAGS, VALID,
--      DDM_SEQ increasing; new module values after the next poll; period 0
--      stops polling.
--   8. Clock stretching (30 us after every ACK): READ correct.
--   9. Bus recovery: SDA held low by the module until 3 SCL pulses -> the
--      command completes correctly.
--  10. SCL held low -> TIMEOUT, lines released.
--  11. Removal -> DDM VALID = 0.
--  12. Bus timing monitor over the whole test: SCL low >= 4.7 us, high >=
--      4.0 us, START hold >= 4.0 us, repeated START setup >= 4.7 us, STOP
--      setup >= 4.0 us, bus free >= 4.7 us.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.tb_pkg.all;
use work.bridge_pkg.all;
use work.xspi_pkg.all;

entity tb_i2c_sfp is
end entity tb_i2c_sfp;

architecture sim of tb_i2c_sfp is

  constant T_CLK : time := 20 ns;
  constant TICK  : natural := 25_000;               -- "100 ms" = 0.5 ms

  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal stop : boolean := false;

  -- pins and bus
  signal los_pin, abs_pin : std_logic := '1';
  signal fault_pin  : std_logic := '0';
  signal tx_dis_pin : std_logic;
  signal scl, sda   : std_logic;
  signal scl_x, sda_x : std_logic;
  signal scl_oe, sda_oe : std_logic;
  signal scl_sl, sda_sl : std_logic := 'Z';         -- module model
  signal sda_stuck  : std_logic := 'Z';
  signal scl_tb     : std_logic := 'Z';

  -- DUT
  signal sfp_los, sfp_tx_fault, sfp_mod_abs : std_logic;
  signal cfg_tx_dis : std_logic := '0';
  signal wr_apply   : std_logic := '0';
  signal wr_addr    : unsigned(7 downto 0) := (others => '0');
  signal wr_data    : t_wr_buf := (others => (others => '0'));
  signal wr_cnt     : natural range 0 to WR_MAX := 0;
  signal regs       : t_mg_regs;
  signal buf_raddr  : unsigned(6 downto 0) := (others => '0');
  signal buf_rdata  : std_logic_vector(7 downto 0);
  signal ev_done    : std_logic;
  signal n_done     : natural := 0;

  -- module model control
  signal present    : boolean := false;
  signal stretch    : time := 0 ns;
  signal stuck_go   : boolean := false;

  -- monitors
  signal n_abs_chg  : natural := 0;
  signal n_viol     : natural := 0;
  signal n_start    : natural := 0;

  type t_mem is protected
    procedure wr(sel : natural; a : natural; v : std_logic_vector(7 downto 0));
    impure function rd(sel : natural; a : natural) return std_logic_vector;
  end protected t_mem;
  type t_mem is protected body
    type t_arr is array (0 to 511) of std_logic_vector(7 downto 0);
    variable m : t_arr := (others => x"00");
    procedure wr(sel : natural; a : natural; v : std_logic_vector(7 downto 0)) is
    begin
      m(sel * 256 + a) := v;
    end procedure;
    impure function rd(sel : natural; a : natural) return std_logic_vector is
    begin
      return m(sel * 256 + a);
    end function;
  end protected body t_mem;
  shared variable mem : t_mem;

begin

  clk_gen(clk, T_CLK, stop);

  -- bus: pull-ups and open-drain drivers
  scl <= 'H';
  sda <= 'H';
  scl <= '0' when scl_oe = '1' else 'Z';
  sda <= '0' when sda_oe = '1' else 'Z';
  scl <= scl_sl;
  sda <= sda_sl;
  sda <= sda_stuck;
  scl <= scl_tb;
  scl_x <= to_x01(scl);
  sda_x <= to_x01(sda);

  dut : entity work.sfp_mgmt
    generic map (
      CLK_HZ => 50_000_000, I2C_HZ => 100_000, TIMEOUT_CLKS => 25_000,
      TICK_CLKS => TICK, INSERT_TICKS => 4, DEB_ABS_CLKS => 500, DEB_SIG_CLKS => 50)
    port map (
      clk => clk, rst => rst,
      los_pin => los_pin, fault_pin => fault_pin, abs_pin => abs_pin,
      tx_dis_pin => tx_dis_pin,
      scl_i => scl_x, sda_i => sda_x, scl_oe => scl_oe, sda_oe => sda_oe,
      sfp_los => sfp_los, sfp_tx_fault => sfp_tx_fault, sfp_mod_abs => sfp_mod_abs,
      cfg_tx_dis => cfg_tx_dis,
      wr_apply => wr_apply, wr_addr => wr_addr, wr_data => wr_data, wr_cnt => wr_cnt,
      regs => regs, buf_raddr => buf_raddr, buf_rdata => buf_rdata,
      ev_i2c_done => ev_done);

  ------------------------------------------------------------------------------
  -- Monitors
  ------------------------------------------------------------------------------
  process (clk)
  begin
    if rising_edge(clk) and ev_done = '1' then
      n_done <= n_done + 1;
    end if;
  end process;

  process (sfp_mod_abs)
  begin
    if sfp_mod_abs'event and now > 0 ns then
      n_abs_chg <= n_abs_chg + 1;
    end if;
  end process;

  -- I2C timing (standard mode)
  timing : process
    variable t_fall, t_rise, t_start, t_stop : time := -1 sec;
    procedure viol(msg : string) is
    begin
      report "I2C timing: " & msg severity error;
      n_viol <= n_viol + 1;
    end procedure;
  begin
    wait on scl_x, sda_x;
    if scl_x'event and scl_x = '1' then
      if t_fall >= 0 ns and now - t_fall < 4.7 us then
        viol("SCL low " & time'image(now - t_fall));
      end if;
      t_rise := now;
    elsif scl_x'event and scl_x = '0' then
      if t_rise >= 0 ns and t_rise > t_start and now - t_rise < 4.0 us then
        viol("SCL high " & time'image(now - t_rise));
      end if;
      if t_start > t_rise and now - t_start < 4.0 us then
        viol("START hold " & time'image(now - t_start));
      end if;
      t_fall := now;
    elsif sda_x'event and scl_x = '1' and not scl_x'event then
      if sda_x = '0' then                         -- START / repeated START
        if t_stop > t_rise and now - t_stop < 4.7 us then
          viol("bus free " & time'image(now - t_stop));
        elsif t_stop < t_rise and now - t_rise < 4.7 us then
          viol("Sr setup " & time'image(now - t_rise));
        end if;
        t_start := now;
        n_start <= n_start + 1;
      else                                        -- STOP
        if now - t_rise < 4.0 us then
          viol("STOP setup " & time'image(now - t_rise));
        end if;
        t_stop := now;
      end if;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- SFP module model (2-wire slave, A0h / A2h)
  ------------------------------------------------------------------------------
  slave : process
    constant C_OK    : natural := 0;
    constant C_START : natural := 1;
    constant C_STOP  : natural := 2;
    variable byte    : std_logic_vector(7 downto 0);
    variable cond    : natural;
    variable got_st  : boolean := false;
    variable sel     : natural := 0;
    variable ptr     : natural := 0;
    variable ack     : std_logic;
    variable b       : std_logic;
    variable adr     : natural;

    -- 8 bits from the master; SCL low at entry and exit
    procedure rx_byte(variable v : out std_logic_vector(7 downto 0); variable c : out natural) is
    begin
      c := C_OK;
      for i in 7 downto 0 loop
        if scl_x /= '1' then
          wait until scl_x = '1';
        end if;
        b := sda_x;
        loop
          wait until scl_x = '0' or sda_x'event;
          if scl_x = '0' then
            exit;
          elsif sda_x = '0' then
            c := C_START;
            return;
          else
            c := C_STOP;
            return;
          end if;
        end loop;
        v(i) := b;
      end loop;
    end procedure;

    -- acknowledge clock; st: clock stretching afterwards (receiving)
    procedure send_ack(st : boolean) is
    begin
      wait for 300 ns;
      sda_sl <= '0';
      wait until scl_x = '1';
      wait until scl_x = '0';
      if st and stretch > 0 ns then
        scl_sl <= '0';
      end if;
      wait for 300 ns;
      sda_sl <= 'Z';
      if st and stretch > 0 ns then
        wait for stretch;
        scl_sl <= 'Z';
      end if;
    end procedure;

    -- 8 bits to the master, then its (N)ACK; clock stretching before the
    -- first bit (SDA is set before SCL is released)
    procedure tx_byte(v : std_logic_vector(7 downto 0); variable a : out std_logic) is
    begin
      if stretch > 0 ns then
        scl_sl <= '0';
      end if;
      for i in 7 downto 0 loop
        wait for 300 ns;
        sda_sl <= '0' when v(i) = '0' else 'Z';
        if i = 7 and stretch > 0 ns then
          wait for stretch;
          scl_sl <= 'Z';
        end if;
        wait until scl_x = '1';
        wait until scl_x = '0';
      end loop;
      wait for 300 ns;
      sda_sl <= 'Z';
      wait until scl_x = '1';
      a := sda_x;
      wait until scl_x = '0';
    end procedure;

  begin
    loop
      sda_sl <= 'Z';
      scl_sl <= 'Z';
      if not got_st then
        wait until falling_edge(sda_x) and scl_x = '1';
      end if;
      got_st := false;
      wait until scl_x = '0';
      rx_byte(byte, cond);
      if cond = C_START then
        got_st := true;
        next;
      elsif cond = C_STOP then
        next;
      end if;
      adr := to_integer(unsigned(byte(7 downto 1)));
      if not present or (adr /= 16#50# and adr /= 16#51#) then
        next;                                     -- no acknowledge
      end if;
      sel := adr - 16#50#;
      send_ack(byte(0) = '0');
      if byte(0) = '0' then                       -- write: offset, data
        rx_byte(byte, cond);
        if cond = C_START then
          got_st := true;
          next;
        elsif cond = C_STOP then
          next;
        end if;
        ptr := to_integer(unsigned(byte));
        send_ack(true);
        loop
          rx_byte(byte, cond);
          if cond = C_START then
            got_st := true;
            exit;
          elsif cond = C_STOP then
            exit;
          end if;
          mem.wr(sel, ptr, byte);
          ptr := (ptr + 1) mod 256;
          send_ack(true);
        end loop;
      else                                        -- read from ptr
        loop
          tx_byte(mem.rd(sel, ptr), ack);
          ptr := (ptr + 1) mod 256;
          exit when ack = '1';
        end loop;
      end if;
    end loop;
  end process;

  -- module holding SDA low until 3 SCL pulses (interrupted read)
  stuck : process
  begin
    wait until stuck_go;
    sda_stuck <= '0';
    for i in 1 to 3 loop
      wait until rising_edge(scl_x);
    end loop;
    wait until falling_edge(scl_x);
    wait for 300 ns;
    sda_stuck <= 'Z';
    wait;
  end process;

  ------------------------------------------------------------------------------
  -- Sequencer
  ------------------------------------------------------------------------------
  seq : process
    variable n0, s0 : natural;
    variable ok     : boolean;

    -- WRITE_REG transaction of csr_regs: bytes from addr
    procedure wreg(a : natural; d : t_byte_arr) is
    begin
      wait until rising_edge(clk);
      wr_addr <= to_unsigned(a, 8);
      for i in 0 to WR_MAX - 1 loop
        if i <= d'length - 1 then
          wr_data(i) <= d(d'low + i);
        end if;
      end loop;
      wr_cnt <= d'length;
      wait until rising_edge(clk);
      wr_apply <= '1';
      wait until rising_edge(clk);
      wr_apply <= '0';
      for i in 1 to 12 loop                       -- sequential buffer writes
        wait until rising_edge(clk);
      end loop;
    end procedure;

    procedure wreg1(a : natural; d : std_logic_vector(7 downto 0)) is
    begin
      wreg(a, (0 => d));
    end procedure;

    impure function reg(a : natural) return std_logic_vector is
    begin
      return regs(a - MG_BASE);
    end function;

    procedure wait_idle(tmo : time) is
    begin
      if regs(4)(0) = '1' then
        wait until regs(4)(0) = '0' for tmo;
      end if;
      wait until rising_edge(clk);
      wait for 1 ns;                              -- n_done updated
    end procedure;

    -- command; BUSY is checked in the cycle after wr_apply
    procedure cmd(c : std_logic_vector(7 downto 0); dev, off, len : natural; msg : string;
                  busy_exp : std_logic := '1') is
    begin
      wait until rising_edge(clk);
      wr_addr    <= to_unsigned(16#30#, 8);
      wr_data(0) <= std_logic_vector(to_unsigned(dev, 8));
      wr_data(1) <= std_logic_vector(to_unsigned(off, 8));
      wr_data(2) <= std_logic_vector(to_unsigned(len mod 256, 8));
      wr_data(3) <= c;
      wr_cnt     <= 4;
      wait until rising_edge(clk);
      wr_apply <= '1';
      wait until rising_edge(clk);
      wr_apply <= '0';
      wait for 1 ns;
      check_equal(reg(16#34#)(0), busy_exp, msg & ": BUSY after the command");
    end procedure;

    procedure check_buf(sel, off, len : natural; msg : string) is
      variable bad : natural := 0;
    begin
      for i in 0 to len - 1 loop
        buf_raddr <= to_unsigned(i, 7);
        wait for 1 ns;
        if buf_rdata /= mem.rd(sel, (off + i) mod 256) then
          bad := bad + 1;
        end if;
      end loop;
      check_equal(bad, 0, msg & ": buffer bytes different from the module");
    end procedure;

  begin
    -- module memory: A0h pattern, A2h DDM values
    for i in 0 to 255 loop
      mem.wr(0, i, std_logic_vector(to_unsigned((i * 37 + 11) mod 256, 8)));
      mem.wr(1, i, std_logic_vector(to_unsigned((i * 13 + 200) mod 256, 8)));
    end loop;

    -- 1. reset
    wait for 200 ns;
    check_equal(tx_dis_pin, '1', "1: TX_DIS during reset");
    wait until rising_edge(clk);
    rst <= '0';
    wait for 100 ns;
    check_equal(tx_dis_pin, '0', "1: TX_DIS = CTRL.SFP_TX_DIS");
    check_equal(sfp_mod_abs, '1', "1: MOD_ABS after reset");
    check_equal(sfp_los, '1', "1: LOS after reset");
    check_equal(reg(16#30#), x"50", "1: I2C_DEV default");
    check_equal(reg(16#4F#), x"0A", "1: DDM_PERIOD default");
    cfg_tx_dis <= '1';
    wait for 100 ns;
    check_equal(tx_dis_pin, '1', "1: TX_DIS follows CTRL");
    cfg_tx_dis <= '0';

    -- 2. command without a module
    n0 := n_done;
    s0 := n_start;
    cmd(I2C_CMD_READ, 16#50#, 0, 4, "2", '0');   -- rejected in the same cycle
    wait for 1 us;
    check_equal(reg(16#34#), x"08", "2: BAD_CMD with the module absent");
    check_equal(n_done - n0, 1, "2: I2C_DONE");
    wait for 50 us;
    check_equal(n_start - s0, 0, "2: no bus activity");

    -- 3. insertion with bounce, LOS filter
    n0 := n_abs_chg;
    for i in 1 to 5 loop
      abs_pin <= '0'; wait for 3 us;
      abs_pin <= '1'; wait for 2 us;
    end loop;
    abs_pin <= '0';
    present <= true;
    wait for 8 us;
    check_equal(sfp_mod_abs, '1', "3: MOD_ABS before the filter time");
    wait for 4 us;
    check_equal(sfp_mod_abs, '0', "3: MOD_ABS after the filter time");
    check_equal(n_abs_chg - n0, 1, "3: one MOD_ABS change");
    los_pin <= '0';
    wait for 2 us;
    check_equal(sfp_los, '0', "3: LOS cleared");
    los_pin <= '1'; wait for 600 ns; los_pin <= '0';
    wait for 2 us;
    check_equal(sfp_los, '0', "3: short LOS pulse ignored");
    fault_pin <= '1';
    wait for 2 us;
    check_equal(sfp_tx_fault, '1', "3: TX_FAULT passed");
    fault_pin <= '0';
    s0 := n_start;
    wait for 1 ms;
    check_equal(n_start - s0, 0, "3: no DDM poll before the insertion delay");

    -- 4. host READ (the first DDM poll may run; the command waits for it)
    n0 := n_done;
    cmd(I2C_CMD_READ, 16#50#, 16#14#, 16, "4a");
    wait_idle(10 ms);
    check_equal(reg(16#34#), x"00", "4a: status OK");
    check_equal(n_done - n0, 1, "4a: one I2C_DONE");
    check_buf(0, 16#14#, 16, "4a");
    cmd(I2C_CMD_READ, 16#50#, 16#80#, 128, "4b");
    wait_idle(20 ms);
    check_equal(reg(16#34#), x"00", "4b: status OK");
    check_buf(0, 16#80#, 128, "4b");

    -- 5. host WRITE A2h 0x80, 8 bytes (buffer in 2 transactions)
    wreg(16#80#, t_byte_arr'(x"11", x"22", x"33", x"44", x"55"));
    wreg(16#85#, t_byte_arr'(x"66", x"77", x"88"));
    cmd(I2C_CMD_WRITE, 16#51#, 16#80#, 8, "5");
    wait_idle(10 ms);
    check_equal(reg(16#34#), x"00", "5: status OK");
    ok := mem.rd(1, 16#80#) = x"11" and mem.rd(1, 16#83#) = x"44"
          and mem.rd(1, 16#85#) = x"66" and mem.rd(1, 16#87#) = x"88";
    check(ok, "5: module memory written");
    check_equal(mem.rd(1, 16#88#), std_logic_vector(to_unsigned((16#88# * 13 + 200) mod 256, 8)),
                "5: byte after the written block unchanged");

    -- 6. NACK, BAD_CMD
    cmd(I2C_CMD_READ, 16#52#, 0, 4, "6a");
    wait_idle(10 ms);
    check_equal(reg(16#34#), x"02", "6a: NACK");
    n0 := n_done;
    wreg(16#32#, t_byte_arr'(x"00", I2C_CMD_READ));
    check_equal(reg(16#34#), x"08", "6b: BAD_CMD for LEN = 0");
    wreg(16#32#, t_byte_arr'(x"81", I2C_CMD_READ));
    check_equal(reg(16#34#), x"08", "6b: BAD_CMD for LEN = 129");
    check_equal(n_done - n0, 2, "6b: I2C_DONE for rejected commands");
    cmd(I2C_CMD_READ, 16#50#, 16#40#, 32, "6c");
    wreg1(16#33#, I2C_CMD_READ);
    check_equal(reg(16#34#), x"09", "6c: BAD_CMD while BUSY, BUSY kept");
    wait_idle(10 ms);
    -- BAD_CMD stays set until the next accepted command
    check_equal(reg(16#34#), x"08", "6c: running command completed, BAD_CMD kept");
    check_buf(0, 16#40#, 32, "6c");

    -- 7. DDM polling
    wait until regs(16#1B#)(0) = '1' for 20 ms;
    check_equal(regs(16#1B#), x"01", "7: DDM VALID");
    for i in 0 to 4 loop
      check_equal(reg(16#40# + 2 * i), mem.rd(1, 96 + 2 * i + 1), "7: DDM LSB " & integer'image(i));
      check_equal(reg(16#41# + 2 * i), mem.rd(1, 96 + 2 * i), "7: DDM MSB " & integer'image(i));
    end loop;
    check_equal(reg(16#4A#), mem.rd(1, 110), "7: DDM_FLAGS");
    s0 := to_integer(unsigned(reg(16#4C#)));
    mem.wr(1, 96, x"7F");
    mem.wr(1, 97, x"A5");
    mem.wr(1, 110, x"42");
    wait for 12 ms;                               -- period 10 x 0.5 ms
    check(to_integer(unsigned(reg(16#4C#))) - s0 >= 2, "7: DDM_SEQ increases");
    check_equal(reg(16#40#), x"A5", "7: new DDM_TEMP LSB");
    check_equal(reg(16#41#), x"7F", "7: new DDM_TEMP MSB");
    check_equal(reg(16#4A#), x"42", "7: new DDM_FLAGS");
    wreg1(16#4F#, x"00");
    wait_idle(10 ms);
    wait for 3 ms;                                -- a running poll ends
    s0 := to_integer(unsigned(reg(16#4C#)));
    wait for 15 ms;
    check_equal(to_integer(unsigned(reg(16#4C#))), s0, "7: period 0 stops polling");
    -- polling stays off for the bus tests 8-10

    -- 8. clock stretching
    stretch <= 30 us;
    cmd(I2C_CMD_READ, 16#50#, 16#60#, 8, "8");
    wait_idle(20 ms);
    check_equal(reg(16#34#), x"00", "8: status OK with stretching");
    check_buf(0, 16#60#, 8, "8");
    stretch <= 0 ns;

    -- 9. bus recovery
    wait_idle(10 ms);
    wait for 100 us;
    stuck_go <= true;
    wait for 5 us;
    cmd(I2C_CMD_READ, 16#50#, 16#00#, 8, "9");
    wait_idle(10 ms);
    check_equal(reg(16#34#), x"00", "9: status OK after bus recovery");
    check_buf(0, 16#00#, 8, "9");
    check_equal(sda_stuck, 'Z', "9: module released SDA");

    -- 10. SCL held low
    wait for 100 us;
    scl_tb <= '0';
    cmd(I2C_CMD_READ, 16#50#, 16#00#, 4, "10");
    wait_idle(5 ms);
    check_equal(reg(16#34#), x"04", "10: TIMEOUT");
    check_equal(scl_oe, '0', "10: SCL released");
    check_equal(sda_oe, '0', "10: SDA released");
    scl_tb <= 'Z';

    -- 11. removal
    wait for 100 us;
    abs_pin <= '1';
    present <= false;
    wait for 20 us;
    check_equal(regs(16#1B#)(0), '0', "11: DDM VALID cleared on removal");

    -- 12. timing
    wait for 100 us;
    check_equal(n_viol, 0, "12: I2C timing violations");
    check(n_start > 20, "12: bus activity seen (" & integer'image(n_start) & " START)");

    tb_finish("tb_i2c_sfp");
  end process;

end architecture sim;
