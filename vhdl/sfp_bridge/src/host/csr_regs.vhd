--------------------------------------------------------------------------------
-- csr_regs
--
-- Control and status registers of the bridge in the clk_sys domain
-- (ADR 0009; map: doc/sfp-xspi-bridge-plan.md, section 7.4).
--
-- Access from xspi_slave (clock domain of SCLK):
--   * CS_N is synchronized (2 flip-flops). At its falling edge the whole
--     readable space is latched into snap; xspi_slave reads snap through
--     reg_addr / reg_rdata and status_fast. snap is static while CS is low
--     (multi-byte values and IRQ_STAT are consistent within a transaction).
--     The latch is ready about 4 clk_sys cycles (80 ns) after CS falls.
--   * WRITE_REG: xspi_slave collects the bytes (wr_addr, wr_data, wr_cnt)
--     and toggles wr_txn; after CS rises (synchronized) the bytes of a new
--     transaction (wr_txn changed) are applied together. The buffer is
--     static while CS is high; the host keeps CS high >= 100 ns.
--   The paths from snap to xspi_slave and from the write buffer to this
--   module are static during use (timing exception between the domains).
--
-- Registers (byte addresses, multi-byte values little-endian):
--   0x00-01 ID, 0x02 VERSION, 0x04 CTRL, 0x05 STATUS, 0x06 STATUS_FAST,
--   0x07 IRQ_EN, 0x08 IRQ_STAT (W1C), 0x0A-0B TX_SPACE, 0x0C-0D RX_LEVEL,
--   0x10-2F counters, 0x50 MODE_CTRL, 0x51-52 UART_DIV, 0x53 UART_STATUS (W1C).
--   I2C / DDM 0x30-0x4F: registers of sfp_mgmt (mg_regs, latched with the
--   rest); the WRITE_REG bytes reach sfp_mgmt through wr_apply (one pulse in
--   the cycle the CSR writes are applied, wr_addr / wr_data / wr_cnt static).
--   I2C_BUF 0x80-0xFF: read directly from the sfp_mgmt buffer (buf_rdata at
--   reg_addr, not latched; static while I2C_STATUS.BUSY = 0).
--
-- Resets: rst (rst_sys, includes the soft reset) for all registers except
-- MODE_CTRL, which uses rst_hard (PLL lock, HOST_RST_N): a soft reset keeps
-- the mode. Writing MODE_CTRL with a changed UART_MODE or FRAME_ECHO, or
-- CTRL.SOFT_RST = 1, sets soft_rst; the resulting rst clears it.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.bridge_pkg.all;
use work.xspi_pkg.all;

entity csr_regs is
  generic (
    TX_DEPTH : positive := 4096;                 -- TX FIFO size (TX_SPACE = TX_DEPTH - level)
    MAX_LEN  : positive := 1024                  -- TX_READY: room for a frame of MAX_LEN
  );
  port (
    clk          : in  std_logic;                -- clk_sys
    rst          : in  std_logic;                -- rst_sys
    rst_hard     : in  std_logic;                -- reset without SOFT_RST
    -- xspi_slave interface
    cs_n         : in  std_logic;                -- pin (asynchronous)
    reg_addr     : in  unsigned(7 downto 0);
    reg_rdata    : out std_logic_vector(7 downto 0);
    status_fast  : out std_logic_vector(7 downto 0);
    wr_addr      : in  unsigned(7 downto 0);
    wr_data      : in  t_wr_buf;
    wr_cnt       : in  natural range 0 to WR_MAX;
    wr_txn       : in  std_logic;
    ev_tx_ovf_t  : in  std_logic;                -- toggle from xspi_slave
    -- sfp_mgmt
    wr_apply     : out std_logic;                -- WRITE_REG bytes applied now
    mg_regs      : in  t_mg_regs;                -- 0x30-0x4F
    buf_rdata    : in  std_logic_vector(7 downto 0);  -- I2C_BUF at reg_addr
    -- status (clk_sys domain, SFP signals synchronized)
    link_state   : in  t_link_state;
    rx_sync      : in  std_logic;
    remote_ready : in  std_logic;
    xoff_local   : in  std_logic;
    xoff_remote  : in  std_logic;
    sfp_los      : in  std_logic;
    sfp_tx_fault : in  std_logic;
    sfp_mod_abs  : in  std_logic;
    mode_sel     : in  std_logic;                -- jumper: '1' xSPI, '0' UART
    tx_level     : in  unsigned(15 downto 0);    -- TX FIFO committed words (read side)
    rx_level     : in  unsigned(15 downto 0);    -- RX FIFO committed words (write side)
    counters     : in  t_cnt_arr;
    -- events (one-cycle pulses)
    ev_rx_frame  : in  std_logic;
    ev_link_chg  : in  std_logic;
    ev_i2c_done  : in  std_logic;
    ev_err       : in  std_logic;                -- link error event
    ev_uart_ovf  : in  std_logic;
    ev_uart_ferr : in  std_logic;
    -- configuration outputs
    cfg_tx_en      : out std_logic;
    cfg_rx_en      : out std_logic;
    cfg_lb_near    : out std_logic;
    cfg_sfp_tx_dis : out std_logic;
    cfg_los_ignore : out std_logic;
    cnt_clr        : out std_logic;              -- one-cycle pulse
    soft_rst       : out std_logic;              -- to clk_rst (flip-flop, cleared by rst)
    mode_uart      : out std_logic;              -- MODE_CTRL.UART_MODE
    mode_echo      : out std_logic;              -- MODE_CTRL.FRAME_ECHO
    mode_rtscts    : out std_logic;              -- MODE_CTRL.RTSCTS_EN
    uart_div       : out unsigned(15 downto 0);
    irq_n          : out std_logic               -- HOST_IRQ_N (xSPI mode)
  );
end entity csr_regs;

architecture rtl of csr_regs is

  constant N_SNAP : positive := 16#54#;          -- latched addresses 0x00 .. 0x53
  type t_space is array (0 to N_SNAP - 1) of std_logic_vector(7 downto 0);

  -- IRQ bits
  constant IRQ_RX_FRAME : natural := 0;
  constant IRQ_TX_EMPTY : natural := 1;
  constant IRQ_LINK_CHG : natural := 2;
  constant IRQ_SFP_CHG  : natural := 3;
  constant IRQ_I2C_DONE : natural := 4;
  constant IRQ_ERR      : natural := 5;

  signal cs_s, cs_d    : std_logic := '1';
  signal txn_s, ovf_s  : std_logic := '0';
  signal txn_done      : std_logic := '0';   -- last applied wr_txn
  signal ovf_d         : std_logic := '0';

  signal ctrl          : std_logic_vector(7 downto 0) := x"03";
  signal irq_en        : std_logic_vector(7 downto 0) := (others => '0');
  signal irq_stat      : std_logic_vector(7 downto 0) := (others => '0');
  signal mode          : std_logic_vector(2 downto 0) := (others => '0');
  signal div_q         : unsigned(15 downto 0) := to_unsigned(UART_DIV_DEFAULT, 16);
  signal uart_st       : std_logic_vector(1 downto 0) := (others => '0');
  signal soft_q        : std_logic := '0';
  signal clr_q         : std_logic := '0';
  signal tx_empty_d    : std_logic := '1';
  signal sfp_d         : std_logic_vector(2 downto 0) := (others => '0');
  signal irq_q         : std_logic := '0';

  signal live, snap    : t_space := (others => (others => '0'));

  signal tx_space      : unsigned(15 downto 0);
  signal tx_empty      : std_logic;
  signal sfast         : std_logic_vector(7 downto 0);
  signal apply         : std_logic;

  function to_sl(b : boolean) return std_logic is
  begin
    if b then return '1'; else return '0'; end if;
  end function;

begin

  u_cs  : entity work.sync_bit generic map (STAGES => 2, INIT_VAL => '1')
    port map (clk => clk, d => cs_n, q => cs_s);
  u_txn : entity work.sync_bit generic map (STAGES => 2, INIT_VAL => '0')
    port map (clk => clk, d => wr_txn, q => txn_s);
  u_ovf : entity work.sync_bit generic map (STAGES => 2, INIT_VAL => '0')
    port map (clk => clk, d => ev_tx_ovf_t, q => ovf_s);

  -- new WRITE_REG transaction completed (CS rose)
  apply <= '1' when rst = '0' and cs_d = '0' and cs_s = '1' and txn_s /= txn_done else '0';

  tx_space <= to_unsigned(TX_DEPTH, 16) - tx_level;
  tx_empty <= '1' when tx_level = 0 else '0';

  sfast <= "00" & mode_sel & irq_q & tx_empty
           & to_sl(tx_space >= MAX_LEN + 3)
           & to_sl(rx_level /= 0)
           & to_sl(link_state = LS_UP);

  ------------------------------------------------------------------------------
  -- Live view of the readable space
  ------------------------------------------------------------------------------
  process (all)
    variable v : t_space;
  begin
    v := (others => (others => '0'));
    v(16#00#) := BRIDGE_ID(7 downto 0);
    v(16#01#) := BRIDGE_ID(15 downto 8);
    v(16#02#) := BRIDGE_VERSION;
    v(16#04#) := "00" & ctrl(5 downto 0);
    v(16#05#) := sfp_mod_abs & sfp_tx_fault & sfp_los & xoff_remote & xoff_local
                 & remote_ready & rx_sync & to_sl(link_state = LS_UP);
    v(16#06#) := sfast;
    v(16#07#) := irq_en;
    v(16#08#) := irq_stat;
    v(16#0A#) := std_logic_vector(tx_space(7 downto 0));
    v(16#0B#) := std_logic_vector(tx_space(15 downto 8));
    v(16#0C#) := std_logic_vector(rx_level(7 downto 0));
    v(16#0D#) := std_logic_vector(rx_level(15 downto 8));
    for i in 0 to N_CNT - 1 loop
      for b in 0 to 3 loop
        v(16#10# + 4 * i + b) := std_logic_vector(counters(i)(8 * b + 7 downto 8 * b));
      end loop;
    end loop;
    for i in 0 to MG_SIZE - 1 loop
      v(MG_BASE + i) := mg_regs(i);
    end loop;
    v(16#50#) := "00000" & mode;
    v(16#51#) := std_logic_vector(div_q(7 downto 0));
    v(16#52#) := std_logic_vector(div_q(15 downto 8));
    v(16#53#) := "000000" & uart_st;
    live <= v;
  end process;

  ------------------------------------------------------------------------------
  -- Latch, writes, interrupts
  ------------------------------------------------------------------------------
  process (clk)
    variable a      : natural range 0 to 255;
    variable d      : std_logic_vector(7 downto 0);
    variable set    : std_logic_vector(7 downto 0);
    variable w1c    : std_logic_vector(7 downto 0);
    variable u_w1c  : std_logic_vector(1 downto 0);
    variable new_mode : std_logic_vector(2 downto 0);
  begin
    if rising_edge(clk) then
      cs_d  <= cs_s;
      clr_q <= '0';

      -- latch the readable space at the falling edge of CS
      if cs_d = '1' and cs_s = '0' then
        snap <= live;
      end if;

      if rst = '1' then
        ctrl       <= x"03";
        irq_en     <= (others => '0');
        irq_stat   <= (others => '0');
        div_q      <= to_unsigned(UART_DIV_DEFAULT, 16);
        uart_st    <= (others => '0');
        soft_q     <= '0';
        txn_done   <= txn_s;
        ovf_d      <= ovf_s;
        tx_empty_d <= '1';
        sfp_d      <= sfp_mod_abs & sfp_tx_fault & sfp_los;
        irq_q      <= '0';
      else
        -- interrupt sources
        set := (others => '0');
        set(IRQ_RX_FRAME) := ev_rx_frame;
        set(IRQ_TX_EMPTY) := tx_empty and not tx_empty_d;
        set(IRQ_LINK_CHG) := ev_link_chg;
        if (sfp_mod_abs & sfp_tx_fault & sfp_los) /= sfp_d then
          set(IRQ_SFP_CHG) := '1';
        end if;
        set(IRQ_I2C_DONE) := ev_i2c_done;
        set(IRQ_ERR) := ev_err or (ovf_s xor ovf_d);
        tx_empty_d <= tx_empty;
        sfp_d      <= sfp_mod_abs & sfp_tx_fault & sfp_los;
        ovf_d      <= ovf_s;

        -- register writes after CS rises (new WRITE_REG transaction)
        w1c   := (others => '0');
        u_w1c := (others => '0');
        new_mode := mode;
        if apply = '1' then
          txn_done <= txn_s;
          for i in 0 to WR_MAX - 1 loop
            if i < wr_cnt then
              a := to_integer(wr_addr + i);
              d := wr_data(i);
              case a is
                when 16#04# =>
                  ctrl(5 downto 0) <= d(5 downto 0);
                  if d(6) = '1' then clr_q <= '1'; end if;
                  if d(7) = '1' then soft_q <= '1'; end if;
                when 16#07# => irq_en <= d;
                when 16#08# => w1c := d;
                when 16#50# => new_mode := d(2 downto 0);
                when 16#51# => div_q(7 downto 0) <= unsigned(d);
                when 16#52# => div_q(15 downto 8) <= unsigned(d);
                when 16#53# => u_w1c := d(1 downto 0);
                when others => null;
              end case;
            end if;
          end loop;
          -- a change of UART_MODE or FRAME_ECHO resets the bridge
          if new_mode(1 downto 0) /= mode(1 downto 0) then
            soft_q <= '1';
          end if;
        end if;

        irq_stat <= (irq_stat and not w1c) or set;
        uart_st  <= (uart_st and not u_w1c) or (ev_uart_ferr & ev_uart_ovf);
        irq_q    <= '1' when ((irq_stat and irq_en) /= x"00") else '0';
      end if;

      -- MODE_CTRL: kept over a soft reset
      if rst_hard = '1' then
        mode <= (others => '0');
      elsif apply = '1' then
        mode <= new_mode;
      end if;
    end if;
  end process;

  reg_rdata   <= snap(to_integer(reg_addr)) when reg_addr < N_SNAP else
                 buf_rdata when reg_addr >= I2C_BUF_BASE else x"00";
  status_fast <= snap(16#06#);

  cfg_tx_en      <= ctrl(0);
  cfg_rx_en      <= ctrl(1);
  cfg_lb_near    <= ctrl(2);
  cfg_sfp_tx_dis <= ctrl(3);
  cfg_los_ignore <= ctrl(4);
  cnt_clr        <= clr_q;
  soft_rst       <= soft_q;
  mode_uart      <= mode(0);
  mode_echo      <= mode(1);
  mode_rtscts    <= mode(2);
  uart_div       <= div_q;
  irq_n          <= not irq_q;
  wr_apply       <= apply;

end architecture rtl;
