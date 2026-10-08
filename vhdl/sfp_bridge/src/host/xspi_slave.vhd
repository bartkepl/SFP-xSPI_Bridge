--------------------------------------------------------------------------------
-- xspi_slave
--
-- SPI / Quad-SPI / Octal-SPI slave of the bridge (ADR 0009), SDR, mode 0:
-- inputs sampled on the rising edge of SCLK, outputs changed on the falling
-- edge, most significant bit first.
--
-- Timing structure: the pins are captured in io_q at the rising edge; all
-- logic (state machine, TX FIFO write, RX FIFO read, output units) runs on
-- the falling edge that follows, with a full SCLK period for its paths. In
-- mode 0 every rising edge is followed by a falling edge (SCLK idles low),
-- so the last byte of a transaction is processed without further SCLK
-- activity. The host side of both FIFOs must use the falling edge
-- (async_fifo WR_FALLING / RD_FALLING). Instruction and address always on one
-- line (IO0); in the 1-x-1 formats data from the host is on IO0 and data to
-- the host on IO1, in the 4- and 8-line formats on IO3..0 / IO7..0 (first
-- unit = most significant nibble).
--
-- Commands:
--   0x9F READ_ID      1-0-1, 0 dummy : 0x5B 0x5F VERSION 0x00 (then 0x00)
--   0x05 READ_STATUS  1-0-1, 0 dummy : status_fast, repeated
--   0x0B READ_REG     1-1-1, 8 dummy : reg_rdata at reg_addr, auto-increment
--   0x02 WRITE_REG    1-1-1, 0 dummy : up to WR_MAX bytes from the address
--   0x12/0x32/0x82 TX_WRITE_1/4/8, 0 dummy : frame bytes into the TX FIFO
--   0x13/0x6B/0x8B RX_READ_1/4/8,  8 dummy : frame bytes from the RX FIFO
--   0x66 TX_ABORT     1-0-0          : drop the uncommitted frame (applied at
--                                      the next falling edge, possibly in the
--                                      next transaction, before any new byte)
--   other opcodes: ignored until the end of the transaction.
--
-- Clock: clk = clk_host (SCLK in xSPI mode, clk_sys during reset, see
-- host_clk). cs_n = '1' asynchronously resets the transaction state machine.
-- Registers that must survive between transactions (TX frame parser, RX
-- prefetch queue, WRITE_REG buffer) use the synchronous reset rst only.
--
-- TX FIFO: the byte is written (and the frame committed after its last
-- byte, from the TYPE LEN_H LEN_L header) at the falling edge after the
-- rising edge that completes the byte, so a frame ending a transaction is
-- committed immediately. A frame with LEN = 0 (rejected by the receiver as
-- a length error) is committed at the next falling edge, possibly in the
-- next transaction, with tx_commit_prev (keeps the pin-to-FIFO path short).
-- A write while tx_full = '1' is lost and toggles ev_tx_ovf_t.
--
-- RX FIFO: a queue of 2 bytes is kept filled during RX_READ (dummy and data
-- phases) with a combinational read request, so a byte is available at
-- every edge in the 8-line format. A byte is removed from the queue only
-- after the host has sampled its last unit; bytes fetched but not sent stay
-- in the queue and are sent first by the next RX_READ. An empty queue sends
-- 0x00 (the host reads only what RX_LEVEL announces).
--
-- CSR (csr_regs, clk_sys domain): READ_REG / READ_STATUS read values latched
-- at the falling edge of CS (static during the transaction). WRITE_REG
-- bytes are collected in wr_addr / wr_data / wr_cnt; wr_txn toggles at the
-- start of each WRITE_REG; csr_regs applies the bytes after CS rises.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.bridge_pkg.all;

package xspi_pkg is
  constant WR_MAX : positive := 8;                       -- WRITE_REG bytes per transaction
  type t_wr_buf is array (0 to WR_MAX - 1) of std_logic_vector(7 downto 0);

  constant OP_READ_ID     : std_logic_vector(7 downto 0) := x"9F";
  constant OP_READ_STATUS : std_logic_vector(7 downto 0) := x"05";
  constant OP_READ_REG    : std_logic_vector(7 downto 0) := x"0B";
  constant OP_WRITE_REG   : std_logic_vector(7 downto 0) := x"02";
  constant OP_TX_WRITE_1  : std_logic_vector(7 downto 0) := x"12";
  constant OP_TX_WRITE_4  : std_logic_vector(7 downto 0) := x"32";
  constant OP_TX_WRITE_8  : std_logic_vector(7 downto 0) := x"82";
  constant OP_RX_READ_1   : std_logic_vector(7 downto 0) := x"13";
  constant OP_RX_READ_4   : std_logic_vector(7 downto 0) := x"6B";
  constant OP_RX_READ_8   : std_logic_vector(7 downto 0) := x"8B";
  constant OP_TX_ABORT    : std_logic_vector(7 downto 0) := x"66";
end package xspi_pkg;

--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.bridge_pkg.all;
use work.xspi_pkg.all;

entity xspi_slave is
  port (
    clk         : in  std_logic;                     -- clk_host
    rst         : in  std_logic;                     -- synchronous, host domain
    cs_n        : in  std_logic;
    io_in       : in  std_logic_vector(7 downto 0);
    io_out      : out std_logic_vector(7 downto 0);
    io_oe       : out std_logic_vector(7 downto 0);  -- '1' = drive
    -- CSR
    reg_addr    : out unsigned(7 downto 0);
    reg_rdata   : in  std_logic_vector(7 downto 0);  -- latched value at reg_addr
    status_fast : in  std_logic_vector(7 downto 0);  -- latched STATUS_FAST
    wr_addr     : out unsigned(7 downto 0);
    wr_data     : out t_wr_buf;
    wr_cnt      : out natural range 0 to WR_MAX;
    wr_txn      : out std_logic;                     -- toggles at each WRITE_REG
    -- TX FIFO write side
    tx_wr       : out std_logic;
    tx_data     : out std_logic_vector(7 downto 0);
    tx_commit   : out std_logic;
    tx_commit_prev : out std_logic;                  -- commit excluding the byte written now
    tx_abort    : out std_logic;
    tx_full     : in  std_logic;
    -- RX FIFO read side
    rx_rd       : out std_logic;
    rx_data     : in  std_logic_vector(7 downto 0);
    rx_valid    : in  std_logic;
    rx_empty    : in  std_logic;
    -- events
    ev_tx_ovf_t : out std_logic                      -- toggles at each lost TX byte
  );
end entity xspi_slave;

architecture rtl of xspi_slave is

  type t_state is (S_INSTR, S_ADDR, S_DUMMY, S_DATA, S_IGNORE);
  type t_kind  is (K_NONE, K_ID, K_STAT, K_REG, K_WREG, K_TXW, K_RXR);
  type t_id    is array (0 to 3) of std_logic_vector(7 downto 0);
  type t_dec is record
    kind  : t_kind;
    width : natural range 1 to 8;
    nst   : t_state;
    abort : boolean;
  end record;

  constant ID_BYTES : t_id := (BRIDGE_ID(7 downto 0), BRIDGE_ID(15 downto 8), BRIDGE_VERSION, x"00");

  -- transaction state (reset by cs_n)
  signal st      : t_state := S_INSTR;
  signal kind    : t_kind := K_NONE;
  signal width   : natural range 1 to 8 := 1;            -- data lines: 1, 4, 8
  signal bcnt    : natural range 0 to 7 := 0;            -- bit / cycle counter in a phase
  signal ucnt    : natural range 0 to 7 := 0;            -- unit index within a data byte
  signal sr      : std_logic_vector(7 downto 0) := (others => '0');
  signal addr    : unsigned(7 downto 0) := (others => '0');
  signal cur     : std_logic_vector(7 downto 0) := (others => '0');
  signal id_idx  : natural range 0 to 4 := 0;
  signal ounit   : std_logic_vector(7 downto 0) := (others => '0');
  signal oen     : std_logic_vector(7 downto 0) := (others => '0');
  signal cur_q   : std_logic := '0';                     -- cur is the RX queue head (not yet popped)
  -- opcode pre-decode for both values of the last instruction bit (keeps the
  -- logic between the pin sample io_q and the falling edge shallow)
  signal pre0    : t_dec := (K_NONE, 1, S_IGNORE, false);
  signal pre1    : t_dec := (K_NONE, 1, S_IGNORE, false);
  signal pre_b0, pre_b1 : std_logic_vector(7 downto 0) := (others => '0');  -- first byte (READ_ID / STATUS)
  signal pre_oe1 : std_logic_vector(7 downto 0) := (others => '0');          -- OE if bit 0 = '1' (READ_ID / STATUS)
  signal p_cmt0  : std_logic := '0';                     -- LEN = 0 frame: commit at the next edge
  signal p_abort : std_logic := '0';                     -- TX_ABORT: applied at the next edge
  signal io_q    : std_logic_vector(7 downto 0) := (others => '0');  -- pins at the rising edge

  -- persistent state (reset by rst)
  signal p_idx   : natural range 0 to 3 := 0;            -- TX parser: 0 TYPE, 1 LEN_H, 2 LEN_L, 3 payload
  signal p_lenh  : std_logic_vector(7 downto 0) := (others => '0');
  signal p_left  : unsigned(15 downto 0) := (others => '0');
  signal q0, q1  : std_logic_vector(7 downto 0) := (others => '0');
  signal qn      : natural range 0 to 2 := 0;
  signal wr_a    : unsigned(7 downto 0) := (others => '0');
  signal wr_d    : t_wr_buf := (others => (others => '0'));
  signal wr_n    : natural range 0 to WR_MAX := 0;
  signal wr_t    : std_logic := '0';
  signal ovf_t   : std_logic := '0';

  -- combinational events of the current edge
  signal op_now    : std_logic_vector(7 downto 0);        -- opcode / address byte completed now
  signal byte_now  : std_logic_vector(7 downto 0);        -- data byte completed now (writes)
  signal byte_done : std_logic;
  signal addr_done : std_logic;                           -- WRITE_REG address completed
  signal abort_now : std_logic;
  signal last_now  : std_logic;                           -- TX byte completing a frame
  signal lenl_zero : std_logic;                           -- completed byte is 0x00
  signal pop       : std_logic;                           -- RX queue head sent completely now
  signal rx_want   : std_logic;
  signal rx_rd_i   : std_logic;
  signal tx_wr_i   : std_logic;

  function decode(op : std_logic_vector(7 downto 0)) return t_dec is
  begin
    case op is
      when OP_READ_ID     => return (K_ID,   1, S_DATA,   false);
      when OP_READ_STATUS => return (K_STAT, 1, S_DATA,   false);
      when OP_READ_REG    => return (K_REG,  1, S_ADDR,   false);
      when OP_WRITE_REG   => return (K_WREG, 1, S_ADDR,   false);
      when OP_TX_WRITE_1  => return (K_TXW,  1, S_DATA,   false);
      when OP_TX_WRITE_4  => return (K_TXW,  4, S_DATA,   false);
      when OP_TX_WRITE_8  => return (K_TXW,  8, S_DATA,   false);
      when OP_RX_READ_1   => return (K_RXR,  1, S_DUMMY,  false);
      when OP_RX_READ_4   => return (K_RXR,  4, S_DUMMY,  false);
      when OP_RX_READ_8   => return (K_RXR,  8, S_DUMMY,  false);
      when OP_TX_ABORT    => return (K_NONE, 1, S_IGNORE, true);
      when others         => return (K_NONE, 1, S_IGNORE, false);
    end case;
  end function;

  function to_int(b : std_logic) return natural is
  begin
    if b = '1' then return 1; else return 0; end if;
  end function;

  function n_units(w : natural) return natural is
  begin
    return 8 / w;
  end function;

  -- unit k of byte b for width w (aligned to IO0 / IO3..0 / IO7..0)
  function unit_of(b : std_logic_vector(7 downto 0); k, w : natural) return std_logic_vector is
    variable u : std_logic_vector(7 downto 0) := (others => '0');
  begin
    case w is
      when 1      => u(1) := b(7 - k);               -- 1-line read data on IO1
      when 4      => if k = 0 then u(3 downto 0) := b(7 downto 4); else u(3 downto 0) := b(3 downto 0); end if;
      when others => u := b;
    end case;
    return u;
  end function;

  function oe_of(w : natural) return std_logic_vector is
  begin
    case w is
      when 1      => return "00000010";
      when 4      => return "00001111";
      when others => return "11111111";
    end case;
  end function;

begin

  ------------------------------------------------------------------------------
  -- Combinational events (from the transaction registers and the pins)
  ------------------------------------------------------------------------------
  op_now <= sr(6 downto 0) & io_q(0);

  with width select byte_now <=
    sr(6 downto 0) & io_q(0)            when 1,
    sr(3 downto 0) & io_q(3 downto 0)   when 4,
    io_q                                when others;

  byte_done <= '1' when st = S_DATA and (kind = K_TXW or kind = K_WREG)
                        and ucnt = n_units(width) - 1 else '0';
  addr_done <= '1' when st = S_ADDR and bcnt = 7 and kind = K_WREG else '0';
  abort_now <= '1' when st = S_INSTR and bcnt = 7
                        and ((io_q(0) = '0' and pre0.abort) or (io_q(0) = '1' and pre1.abort)) else '0';

  tx_wr_i   <= byte_done when kind = K_TXW else '0';
  lenl_zero <= '1' when (width = 1 and sr(6 downto 0) = "0000000" and io_q(0) = '0')
                     or (width = 4 and sr(3 downto 0) = "0000" and io_q(3 downto 0) = "0000")
                     or (width = 8 and io_q = x"00") else '0';
  last_now  <= '1' when p_idx = 3 and p_left = 1 else '0';

  -- The byte in cur (taken from the queue head without removing it) is
  -- removed when the host has sampled its last unit: at a data-phase edge
  -- with ucnt = 0. A byte prepared at the last edge of a transaction is not
  -- sent and stays in the queue.
  pop <= '1' when kind = K_RXR and st = S_DATA and ucnt = 0 and cur_q = '1' else '0';
  rx_want <= '1' when kind = K_RXR and (st = S_DUMMY or st = S_DATA) else '0';
  -- request while the queue (with the byte arriving now) has room after this edge
  rx_rd_i <= '1' when rx_want = '1' and rx_empty = '0'
                      and qn + to_int(rx_valid) - to_int(pop) <= 1
             else '0';

  tx_wr     <= tx_wr_i;
  tx_data   <= byte_now;
  -- commit with the last payload byte; a frame with LEN = 0 (rejected by the
  -- receiver anyway) is committed at the next falling edge, which may belong
  -- to the next transaction (keeps the pin-to-FIFO path short)
  tx_commit <= tx_wr_i and last_now;
  tx_commit_prev <= p_cmt0;
  tx_abort  <= p_abort;
  rx_rd     <= rx_rd_i;

  ------------------------------------------------------------------------------
  -- Pin capture (rising edge)
  ------------------------------------------------------------------------------
  process (clk)
  begin
    if rising_edge(clk) then
      io_q <= io_in;
    end if;
  end process;

  ------------------------------------------------------------------------------
  -- Transaction state machine (falling edge, reset by cs_n)
  ------------------------------------------------------------------------------
  process (clk, cs_n)
    variable k_v  : t_kind;
    variable w_v  : natural range 1 to 8;
    variable b    : std_logic_vector(7 downto 0);
    variable prep : boolean;                     -- prepare the next output unit now
    variable first : boolean;                    -- ... and it is the first unit of a byte
    variable d     : t_dec;
  begin
    if cs_n = '1' then
      st     <= S_INSTR;
      kind   <= K_NONE;
      width  <= 1;
      bcnt   <= 0;
      ucnt   <= 0;
      id_idx <= 0;
      oen    <= (others => '0');
      cur_q  <= '0';
    elsif falling_edge(clk) then
      k_v   := kind;
      w_v   := width;
      prep  := false;
      first := ucnt = 0;

      case st is
        when S_INSTR =>
          sr <= op_now;
          if bcnt = 6 then
            -- opcode bits 7..2 in sr(5 downto 0) (registered), bit 1 in io_q(0):
            -- decode the four completions from registers only, the pin selects
            if io_q(0) = '1' then
              pre0 <= decode(sr(5 downto 0) & "10");
              pre1 <= decode(sr(5 downto 0) & "11");
            else
              pre0 <= decode(sr(5 downto 0) & "00");
              pre1 <= decode(sr(5 downto 0) & "01");
            end if;
            -- READ_ID and READ_STATUS both end with bit 0 = '1'
            pre_b0 <= status_fast;
            if (sr(5 downto 0) = OP_READ_ID(7 downto 2) and io_q(0) = OP_READ_ID(1))
               or (sr(5 downto 0) = OP_READ_STATUS(7 downto 2) and io_q(0) = OP_READ_STATUS(1)) then
              pre_oe1 <= oe_of(1);
            else
              pre_oe1 <= (others => '0');
            end if;
            if sr(5 downto 0) = OP_READ_ID(7 downto 2) and io_q(0) = OP_READ_ID(1) then
              pre_b1 <= ID_BYTES(0);
            else
              pre_b1 <= status_fast;
            end if;
          end if;
          if bcnt = 7 then
            bcnt <= 0;
            if io_q(0) = '1' then d := pre1; b := pre_b1; else d := pre0; b := pre_b0; end if;
            k_v := d.kind;
            w_v := d.width;
            st  <= d.nst;
            -- READ_ID / READ_STATUS: first data unit right now (1 line, IO1);
            -- values precomputed, the pin only selects
            cur   <= b;
            ounit <= unit_of(b, 0, 1);
            if io_q(0) = '1' then
              oen <= pre_oe1;
            else
              oen <= (others => '0');
            end if;
            if d.kind = K_ID or d.kind = K_STAT then
              ucnt <= 1;
            else
              ucnt <= 0;
            end if;
            if d.kind = K_ID then id_idx <= 1; end if;
          else
            bcnt <= bcnt + 1;
          end if;

        when S_ADDR =>
          sr <= op_now;
          if bcnt = 7 then
            addr <= unsigned(op_now);
            bcnt <= 0;
            if kind = K_REG then
              st <= S_DUMMY;
            else
              st <= S_DATA;
            end if;
          else
            bcnt <= bcnt + 1;
          end if;

        when S_DUMMY =>
          if bcnt = 7 then
            st    <= S_DATA;
            prep  := true;
            first := true;
          else
            bcnt <= bcnt + 1;
          end if;

        when S_DATA =>
          if kind = K_TXW or kind = K_WREG then
            -- assemble input units
            if width = 1 then
              sr <= sr(6 downto 0) & io_q(0);
            elsif width = 4 then
              sr(3 downto 0) <= io_q(3 downto 0);
            end if;
            if ucnt = n_units(width) - 1 then
              ucnt <= 0;
            else
              ucnt <= ucnt + 1;
            end if;
          else
            prep := true;
          end if;

        when S_IGNORE =>
          null;
      end case;

      kind  <= k_v;
      width <= w_v;

      -- output unit sampled by the host at the next rising edge (drives the
      -- pins from this falling edge on); only in the dummy and data phases,
      -- from registered state (the first unit of READ_ID / READ_STATUS is
      -- set at the end of the instruction above)
      if prep then
        if first then
          case kind is
            when K_ID   => if id_idx < 4 then b := ID_BYTES(id_idx); else b := x"00"; end if;
            when K_STAT => b := status_fast;
            when K_REG  => b := reg_rdata;              -- value at addr
            when K_RXR  =>
              -- next byte: queue head after the pop, or the byte arriving now
              cur_q <= '1';
              if pop = '1' then
                if qn >= 2 then b := q1;
                elsif qn = 1 and rx_valid = '1' then b := rx_data;
                else b := x"00"; cur_q <= '0';
                end if;
              else
                if qn >= 1 then b := q0;
                elsif rx_valid = '1' then b := rx_data;
                else b := x"00"; cur_q <= '0';
                end if;
              end if;
            when others => b := x"00";
          end case;
          cur   <= b;
          ounit <= unit_of(b, 0, width);
          oen   <= oe_of(width);
          if n_units(width) > 1 then ucnt <= 1; else ucnt <= 0; end if;
          if kind = K_ID and id_idx < 4 then id_idx <= id_idx + 1; end if;
          if kind = K_REG then addr <= addr + 1; end if;
        else
          ounit <= unit_of(cur, ucnt, width);
          if ucnt = n_units(width) - 1 then ucnt <= 0; else ucnt <= ucnt + 1; end if;
        end if;
      end if;
    end if;
  end process;

  io_out <= ounit;
  io_oe  <= oen;

  reg_addr <= addr;

  ------------------------------------------------------------------------------
  -- Persistent state: TX parser, RX queue, WRITE_REG buffer (falling edge,
  -- reset by rst)
  ------------------------------------------------------------------------------
  process (clk)
    variable n_v   : natural range 0 to 3;
    variable pi    : natural range 0 to 3;
  begin
    if falling_edge(clk) then
      if rst = '1' then
        p_idx   <= 0;
        p_cmt0  <= '0';
        p_abort <= '0';
        qn    <= 0;
        wr_n  <= 0;
      else
        -- TX frame parser. After LEN_L the parser always enters the payload
        -- state; a LEN = 0 header is detected with a shallow zero test into
        -- p_cmt0, which at the next edge commits the header and returns the
        -- parser to TYPE (pi below), so the pins do not steer p_idx.
        p_cmt0  <= '0';
        p_abort <= abort_now;               -- FIFO abort at the next falling edge
        if tx_wr_i = '1' and p_idx = 2 and p_lenh = x"00" and lenl_zero = '1' then
          p_cmt0 <= '1';
        end if;
        if tx_wr_i = '1' and tx_full = '1' then
          ovf_t <= not ovf_t;
        end if;
        if p_cmt0 = '1' then
          pi := 0;                          -- previous header had LEN = 0
        else
          pi := p_idx;
        end if;
        if tx_wr_i = '1' and pi = 1 then
          p_lenh <= byte_now;               -- (no abort in a data phase)
        end if;
        if abort_now = '1' then
          p_idx <= 0;
        elsif tx_wr_i = '1' then
          case pi is
            when 0 => p_idx <= 1;
            when 1 => p_idx <= 2;
            when 2 =>
              p_left <= unsigned(p_lenh) & unsigned(byte_now);
              p_idx  <= 3;
            when others =>
              p_left <= p_left - 1;
              if p_left = 1 then p_idx <= 0; end if;
          end case;
        elsif p_cmt0 = '1' then
          p_idx <= 0;
        end if;

        -- RX prefetch queue: consume head, append the arriving byte
        n_v := qn;
        if pop = '1' then
          q0  <= q1;
          n_v := n_v - 1;
        end if;
        if rx_valid = '1' then
          if n_v = 0 then
            q0 <= rx_data;
          else
            q1 <= rx_data;
          end if;
          n_v := n_v + 1;
        end if;
        qn <= n_v;

        -- WRITE_REG buffer (stable after CS rises)
        if addr_done = '1' then
          wr_a <= unsigned(op_now);
          wr_n <= 0;
          wr_t <= not wr_t;
        elsif byte_done = '1' and kind = K_WREG and wr_n < WR_MAX then
          wr_d(wr_n) <= byte_now;
          wr_n <= wr_n + 1;
        end if;
      end if;
    end if;
  end process;

  wr_addr     <= wr_a;
  wr_data     <= wr_d;
  wr_cnt      <= wr_n;
  wr_txn      <= wr_t;
  ev_tx_ovf_t <= ovf_t;

end architecture rtl;
