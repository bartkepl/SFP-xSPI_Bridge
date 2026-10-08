--------------------------------------------------------------------------------
-- sfp_mgmt
--
-- SFP module management in the clk_sys domain (map: doc/sfp-xspi-bridge-
-- plan.md, section 7.4):
--   * SFP status inputs: 2-flip-flop synchronizer and a filter (the output
--     follows the input after it has been stable for DEB_ABS_CLKS (MOD_ABS,
--     contact bounce at insertion) or DEB_SIG_CLKS (LOS, TX_FAULT) cycles).
--     During reset the outputs follow the synchronized inputs directly.
--   * SFP_TX_DIS pin: '1' during reset, otherwise CTRL.SFP_TX_DIS.
--   * I2C mailbox for the host: I2C_DEV, I2C_OFFSET, I2C_LEN, I2C_CMD,
--     I2C_STATUS, buffer I2C_BUF (128 B, distributed RAM).
--   * DDM polling: every DDM_PERIOD x 100 ms, while the module is present
--     and INSERT_TICKS x 100 ms after its insertion (the 2-wire interface
--     is ready 300 ms after insertion), bytes 96..110 of A2h are read; the
--     shadow registers DDM_* are updated together after a successful read.
--
-- Register writes come from the WRITE_REG transaction of csr_regs
-- (wr_apply pulse, wr_addr / wr_data / wr_cnt static while CS is high).
-- The bytes for 0x30-0x4F are decoded every cycle into registers (pd_*):
-- wr_apply comes at least 2 cycles after CS rises (synchronizer in
-- csr_regs), so the decoded values are stable by then and the registers
-- are applied in the wr_apply cycle together (a command written there is
-- accepted, and BUSY set, in the same cycle as the CSR registers). The
-- I2C_BUF bytes follow one per cycle through a pipeline register (at most
-- WR_MAX + 1 cycles; the next transaction cannot deliver new bytes
-- earlier).
--
-- I2C_CMD (READ / WRITE) is rejected with BAD_CMD (and I2C_DONE) when LEN
-- is outside 1..128 or the module is absent; a command written while BUSY
-- only sets BAD_CMD. A command and the DDM polling never interrupt each
-- other: whichever is pending starts when the I2C master is idle (host
-- command first).
--
-- I2C_BUF is read asynchronously at buf_raddr (READ_REG in the SCLK
-- domain of xspi_slave, through csr_regs): its contents are static while
-- BUSY = '0' (timing exception between the domains, like the CSR latch).
--
-- Read view (regs, index = address - 0x30):
--   0x30 I2C_DEV (7 bit)     0x31 I2C_OFFSET   0x32 I2C_LEN   0x33 I2C_CMD = 0
--   0x34 I2C_STATUS: b0 BUSY, b1 NACK, b2 TIMEOUT, b3 BAD_CMD
--   0x40-0x49 DDM_TEMP, DDM_VCC, DDM_TXBIAS, DDM_TXPWR, DDM_RXPWR
--             (16 bit little-endian, from A2h 96..105 big-endian)
--   0x4A DDM_FLAGS (A2h byte 110)
--   0x4B DDM_STAT: b0 VALID, b1 NACK, b2 TIMEOUT (last poll)
--   0x4C DDM_SEQ (successful polls, wraps)     0x4F DDM_PERIOD
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.bridge_pkg.all;
use work.xspi_pkg.all;

entity sfp_mgmt is
  generic (
    CLK_HZ       : positive := CLK_SYS_HZ;
    I2C_HZ       : positive := 100_000;
    TIMEOUT_CLKS : positive := CLK_SYS_HZ / 40;      -- 25 ms SCL held low
    TICK_CLKS    : positive := CLK_SYS_HZ / 10;      -- 100 ms
    INSERT_TICKS : positive := 4;                    -- 300..400 ms after insertion
    DEB_ABS_CLKS : positive := CLK_SYS_HZ / 100;     -- 10 ms
    DEB_SIG_CLKS : positive := CLK_SYS_HZ / 20_000   -- 50 us
  );
  port (
    clk          : in  std_logic;                    -- clk_sys
    rst          : in  std_logic;                    -- rst_sys
    -- SFP pins
    los_pin      : in  std_logic;
    fault_pin    : in  std_logic;
    abs_pin      : in  std_logic;
    tx_dis_pin   : out std_logic;
    scl_i        : in  std_logic;
    sda_i        : in  std_logic;
    scl_oe       : out std_logic;                    -- '1': pull SCL low
    sda_oe       : out std_logic;                    -- '1': pull SDA low
    -- filtered status
    sfp_los      : out std_logic;
    sfp_tx_fault : out std_logic;
    sfp_mod_abs  : out std_logic;
    cfg_tx_dis   : in  std_logic;                    -- CTRL.SFP_TX_DIS
    -- CSR access
    wr_apply     : in  std_logic;
    wr_addr      : in  unsigned(7 downto 0);
    wr_data      : in  t_wr_buf;
    wr_cnt       : in  natural range 0 to WR_MAX;
    regs         : out t_mg_regs;
    buf_raddr    : in  unsigned(6 downto 0);
    buf_rdata    : out std_logic_vector(7 downto 0);
    ev_i2c_done  : out std_logic                     -- host command finished
  );
end entity sfp_mgmt;

architecture rtl of sfp_mgmt is

  -- status inputs
  signal los_s, fault_s, abs_s : std_logic;
  signal los_f   : std_logic := '1';
  signal fault_f : std_logic := '0';
  signal abs_f   : std_logic := '1';
  signal los_c, fault_c : natural range 0 to DEB_SIG_CLKS - 1 := 0;
  signal abs_c   : natural range 0 to DEB_ABS_CLKS - 1 := 0;
  signal tx_dis_q : std_logic := '1';

  -- buffer
  signal ibuf : t_byte_arr(0 to I2C_BUF_SIZE - 1) := (others => (others => '0'));
  attribute syn_ramstyle : string;
  attribute syn_ramstyle of ibuf : signal is "distributed_ram";
  signal hw_run  : std_logic := '0';                 -- host bytes being written
  signal hw_i    : natural range 0 to WR_MAX := 0;
  signal hw_a    : unsigned(7 downto 0) := (others => '0');
  signal bw_we   : std_logic := '0';                 -- pipeline: host byte to write
  signal bw_a    : unsigned(6 downto 0) := (others => '0');
  signal bw_d    : std_logic_vector(7 downto 0) := (others => '0');
  signal mwr     : boolean;                          -- I2C read byte to the buffer

  -- decoded WRITE_REG bytes (0x30-0x4F)
  signal pd_dev_v, pd_off_v, pd_len_v, pd_per_v : boolean := false;
  signal pd_dev  : std_logic_vector(6 downto 0) := (others => '0');
  signal pd_off, pd_len, pd_per : std_logic_vector(7 downto 0) := (others => '0');
  signal pd_go   : boolean := false;                 -- READ / WRITE written to I2C_CMD
  signal pd_rd   : std_logic := '0';
  signal pd_bad  : boolean := false;                 -- resulting LEN outside 1..128

  -- mailbox registers
  signal dev_q   : std_logic_vector(6 downto 0) := I2C_DEV_DEFAULT;
  signal off_q   : std_logic_vector(7 downto 0) := (others => '0');
  signal len_q   : std_logic_vector(7 downto 0) := (others => '0');
  signal period_q : unsigned(7 downto 0) := to_unsigned(DDM_PERIOD_DEFAULT, 8);
  signal busy_q, nack_q, tmo_q, bad_q : std_logic := '0';
  signal pend    : std_logic := '0';                 -- host command waiting
  signal rd_q    : std_logic := '0';
  signal done_q  : std_logic := '0';

  -- DDM
  signal stage   : t_byte_arr(0 to 10) := (others => (others => '0'));
  signal ddm     : t_byte_arr(0 to 10) := (others => (others => '0'));
  signal d_valid, d_nack, d_tmo : std_logic := '0';
  signal d_seq   : unsigned(7 downto 0) := (others => '0');
  signal tick_c  : natural range 0 to TICK_CLKS - 1 := 0;
  signal tick    : std_logic := '0';
  signal ins_c   : natural range 0 to INSERT_TICKS := 0;
  signal per_c   : unsigned(7 downto 0) := (others => '0');
  signal due     : std_logic := '0';                 -- DDM poll waiting

  -- I2C master
  type t_owner is (OWN_HOST, OWN_POLL);
  signal owner   : t_owner := OWN_HOST;
  signal m_start, m_rd, m_busy, m_done, m_nack, m_tmo, m_rxv : std_logic := '0';
  signal m_dev   : std_logic_vector(6 downto 0) := (others => '0');
  signal m_off   : std_logic_vector(7 downto 0) := (others => '0');
  signal m_len   : unsigned(7 downto 0) := (others => '0');
  signal m_txi, m_rxi : unsigned(6 downto 0);
  signal m_txd, m_rxd : std_logic_vector(7 downto 0);

begin

  ------------------------------------------------------------------------------
  -- Status inputs
  ------------------------------------------------------------------------------
  u_los   : entity work.sync_bit generic map (STAGES => 2, INIT_VAL => '1')
    port map (clk => clk, d => los_pin, q => los_s);
  u_fault : entity work.sync_bit generic map (STAGES => 2, INIT_VAL => '0')
    port map (clk => clk, d => fault_pin, q => fault_s);
  u_abs   : entity work.sync_bit generic map (STAGES => 2, INIT_VAL => '1')
    port map (clk => clk, d => abs_pin, q => abs_s);

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        los_f   <= los_s;
        fault_f <= fault_s;
        abs_f   <= abs_s;
        los_c   <= 0;
        fault_c <= 0;
        abs_c   <= 0;
        tx_dis_q <= '1';
      else
        if los_s = los_f then
          los_c <= 0;
        elsif los_c = DEB_SIG_CLKS - 1 then
          los_f <= los_s;
          los_c <= 0;
        else
          los_c <= los_c + 1;
        end if;
        if fault_s = fault_f then
          fault_c <= 0;
        elsif fault_c = DEB_SIG_CLKS - 1 then
          fault_f <= fault_s;
          fault_c <= 0;
        else
          fault_c <= fault_c + 1;
        end if;
        if abs_s = abs_f then
          abs_c <= 0;
        elsif abs_c = DEB_ABS_CLKS - 1 then
          abs_f <= abs_s;
          abs_c <= 0;
        else
          abs_c <= abs_c + 1;
        end if;
        tx_dis_q <= cfg_tx_dis;
      end if;
    end if;
  end process;

  sfp_los      <= los_f;
  sfp_tx_fault <= fault_f;
  sfp_mod_abs  <= abs_f;
  tx_dis_pin   <= tx_dis_q;

  ------------------------------------------------------------------------------
  -- I2C buffer: one write port (I2C master read data, host bytes),
  -- asynchronous reads for the host and for the I2C master
  ------------------------------------------------------------------------------
  mwr <= owner = OWN_HOST and m_rxv = '1';

  process (clk)
  begin
    if rising_edge(clk) then
      if mwr then
        ibuf(to_integer(m_rxi)) <= m_rxd;
      elsif bw_we = '1' then
        ibuf(to_integer(bw_a)) <= bw_d;
      end if;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- Decoding of the WRITE_REG bytes for 0x30-0x4F (inputs static while CS
  -- is high; used only in the wr_apply cycle)
  ------------------------------------------------------------------------------
  process (clk)
    variable a     : natural range 0 to 255;
    variable d     : std_logic_vector(7 downto 0);
    variable cmd_v : boolean;
    variable cmd   : std_logic_vector(7 downto 0);
    variable len_v : boolean;
    variable len   : std_logic_vector(7 downto 0);
  begin
    if rising_edge(clk) then
      pd_dev_v <= false;
      pd_off_v <= false;
      pd_per_v <= false;
      cmd_v    := false;
      cmd      := (others => '0');
      len_v    := false;
      len      := len_q;
      for i in 0 to WR_MAX - 1 loop
        if i < wr_cnt then
          a := to_integer(wr_addr + i);
          d := wr_data(i);
          case a is
            when 16#30# => pd_dev_v <= true; pd_dev <= d(6 downto 0);
            when 16#31# => pd_off_v <= true; pd_off <= d;
            when 16#32# => len_v := true; len := d;
            when 16#33# => cmd_v := true; cmd := d;
            when 16#4F# => pd_per_v <= true; pd_per <= d;
            when others => null;
          end case;
        end if;
      end loop;
      pd_len_v <= len_v;
      pd_len   <= len;
      pd_go    <= cmd_v and (cmd = I2C_CMD_READ or cmd = I2C_CMD_WRITE);
      pd_rd    <= '1' when cmd = I2C_CMD_READ else '0';
      pd_bad   <= unsigned(len) = 0 or unsigned(len) > I2C_BUF_SIZE;
    end if;
  end process;

  buf_rdata <= ibuf(to_integer(buf_raddr));
  m_txd     <= ibuf(to_integer(m_txi));

  ------------------------------------------------------------------------------
  -- Mailbox, DDM polling, arbitration
  ------------------------------------------------------------------------------
  process (clk)
    variable n      : natural;
  begin
    if rising_edge(clk) then
      done_q  <= '0';
      m_start <= '0';

      -- 100 ms tick
      tick <= '0';
      if tick_c = TICK_CLKS - 1 then
        tick_c <= 0;
        tick   <= '1';
      else
        tick_c <= tick_c + 1;
      end if;

      if rst = '1' then
        hw_run   <= '0';
        hw_i     <= 0;
        bw_we    <= '0';
        dev_q    <= I2C_DEV_DEFAULT;
        off_q    <= (others => '0');
        len_q    <= (others => '0');
        period_q <= to_unsigned(DDM_PERIOD_DEFAULT, 8);
        busy_q   <= '0';
        nack_q   <= '0';
        tmo_q    <= '0';
        bad_q    <= '0';
        pend     <= '0';
        owner    <= OWN_HOST;
        d_valid  <= '0';
        d_nack   <= '0';
        d_tmo    <= '0';
        d_seq    <= (others => '0');
        ins_c    <= 0;
        per_c    <= (others => '0');
        due      <= '0';
      else
        -- host buffer bytes: one per cycle into the pipeline register; a
        -- byte waiting there is kept while the I2C master writes the buffer
        if bw_we = '0' or not mwr then
          bw_we <= '0';
          if hw_run = '1' then
            if hw_i < wr_cnt then
              bw_we <= hw_a(7);                  -- I2C_BUF: 0x80-0xFF
              bw_a  <= hw_a(6 downto 0);
              bw_d  <= wr_data(hw_i);
              hw_i  <= hw_i + 1;
              hw_a  <= hw_a + 1;
            else
              hw_run <= '0';
            end if;
          end if;
        end if;

        -- registers 0x30-0x4F
        if wr_apply = '1' then
          hw_run <= '1';
          hw_i   <= 0;
          hw_a   <= wr_addr;
          if pd_dev_v then dev_q <= pd_dev; end if;
          if pd_off_v then off_q <= pd_off; end if;
          if pd_len_v then len_q <= pd_len; end if;
          if pd_per_v then period_q <= unsigned(pd_per); end if;
        end if;

        if wr_apply = '1' and pd_go then
          if busy_q = '1' then
            bad_q <= '1';
          elsif pd_bad or abs_f = '1' then
            bad_q  <= '1';
            nack_q <= '0';
            tmo_q  <= '0';
            done_q <= '1';
          else
            busy_q <= '1';
            pend   <= '1';
            bad_q  <= '0';
            nack_q <= '0';
            tmo_q  <= '0';
            rd_q   <= pd_rd;
          end if;
        end if;

        -- module presence and polling period
        if abs_f = '1' then
          ins_c   <= 0;
          per_c   <= (others => '0');
          due     <= '0';
          d_valid <= '0';
        elsif tick = '1' then
          if ins_c < INSERT_TICKS then
            ins_c <= ins_c + 1;
            if ins_c = INSERT_TICKS - 1 and period_q /= 0 then
              due <= '1';                        -- first poll after insertion
            end if;
          elsif period_q /= 0 then
            if per_c + 1 >= period_q then
              per_c <= (others => '0');
              due   <= '1';
            else
              per_c <= per_c + 1;
            end if;
          end if;
        end if;
        if period_q = 0 then
          due   <= '0';
          per_c <= (others => '0');
        end if;

        -- start a command / poll when the master is idle
        if m_busy = '0' and m_start = '0' then
          if pend = '1' then
            pend    <= '0';
            owner   <= OWN_HOST;
            m_start <= '1';
            m_rd    <= rd_q;
            m_dev   <= dev_q;
            m_off   <= off_q;
            m_len   <= unsigned(len_q);
          elsif due = '1' and abs_f = '0' then
            due     <= '0';
            owner   <= OWN_POLL;
            m_start <= '1';
            m_rd    <= '1';
            m_dev   <= DDM_DEV;
            m_off   <= std_logic_vector(to_unsigned(DDM_OFFSET, 8));
            m_len   <= to_unsigned(DDM_LEN, 8);
          end if;
        end if;

        -- received DDM bytes: 96..105 -> stage 0..9, 110 -> stage 10
        if owner = OWN_POLL and m_rxv = '1' then
          n := to_integer(m_rxi);
          if n <= 9 then
            stage(n) <= m_rxd;
          elsif n = 14 then
            stage(10) <= m_rxd;
          end if;
        end if;

        -- end of a command / poll
        if m_done = '1' then
          if owner = OWN_HOST then
            busy_q <= '0';
            nack_q <= m_nack;
            tmo_q  <= m_tmo;
            done_q <= '1';
          else
            d_nack <= m_nack;
            d_tmo  <= m_tmo;
            if m_nack = '0' and m_tmo = '0' and abs_f = '0' then
              ddm     <= stage;
              d_valid <= '1';
              d_seq   <= d_seq + 1;
            end if;
          end if;
        end if;
      end if;
    end if;
  end process;

  u_i2c : entity work.i2c_master
    generic map (CLK_HZ => CLK_HZ, I2C_HZ => I2C_HZ, TIMEOUT_CLKS => TIMEOUT_CLKS)
    port map (
      clk => clk, rst => rst,
      start => m_start, rd => m_rd, dev => m_dev, offset => m_off, len => m_len,
      busy => m_busy, done => m_done, nack => m_nack, timeout => m_tmo,
      tx_idx => m_txi, tx_data => m_txd,
      rx_idx => m_rxi, rx_data => m_rxd, rx_valid => m_rxv,
      scl_i => scl_i, sda_i => sda_i, scl_oe => scl_oe, sda_oe => sda_oe);

  ------------------------------------------------------------------------------
  -- Read view 0x30-0x4F
  ------------------------------------------------------------------------------
  process (all)
    variable v : t_mg_regs;
  begin
    v := (others => (others => '0'));
    v(16#00#) := '0' & dev_q;
    v(16#01#) := off_q;
    v(16#02#) := len_q;
    v(16#04#) := "0000" & bad_q & tmo_q & nack_q & busy_q;
    for i in 0 to 4 loop                         -- big-endian pairs -> little-endian
      v(16#10# + 2 * i)     := ddm(2 * i + 1);
      v(16#10# + 2 * i + 1) := ddm(2 * i);
    end loop;
    v(16#1A#) := ddm(10);
    v(16#1B#) := "00000" & d_tmo & d_nack & d_valid;
    v(16#1C#) := std_logic_vector(d_seq);
    v(16#1F#) := std_logic_vector(period_q);
    regs <= v;
  end process;

  ev_i2c_done <= done_q;

end architecture rtl;
