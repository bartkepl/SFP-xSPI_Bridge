--------------------------------------------------------------------------------
-- uart_bridge
--
-- Transparent UART mode (ADR 0006): packs the bytes received on UART_RX into
-- link frames of TYPE 0x01 and sends the payload of received TYPE 0x01
-- frames on UART_TX. Connects to the host side of the link FIFOs (instead
-- of xspi_slave), in the clock domain of that side (clk_sys in UART mode).
--
-- UART -> link (TX FIFO, commit mode, frame format TYPE LEN_H LEN_L payload):
--   * Received bytes are collected in a buffer of MAX_PAY bytes (64).
--   * The frame is written when the buffer is full or when the receive
--     line has been idle for 2 character times (20 bit periods) after the
--     stop bit of the last byte.
--   * Writing starts only when the TX FIFO has room for the whole frame
--     (tx_free >= LEN + 4); the frame is committed with its last byte.
--   * One byte arriving while a frame is being written (or waiting for
--     room) is held; a further byte is lost (ev_rx_ovf).
--   * RTS/CTS enabled (cfg_rtscts): rts_n = '1' (stop) while the TX FIFO
--     has less than RTS_FREE bytes free.
--
-- link -> UART (RX FIFO with complete, committed frames):
--   * TYPE 0x01: the payload bytes are sent on UART_TX in order; with
--     RTS/CTS enabled a byte is started only while cts_n = '0'.
--   * other TYPE: the frame is read and discarded (ev_skip).
--   Bytes are read from the RX FIFO only as fast as UART_TX sends them, so
--   a slow UART stops the link by XOFF (no data loss on this side).
--
-- UART framing errors are reported by ev_frame_err (the byte is dropped).
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.bridge_pkg.all;

entity uart_bridge is
  generic (
    MAX_PAY   : positive range 1 to 255 := 64;    -- payload bytes per frame
    FREE_W    : positive := 13;                   -- width of tx_free (TX FIFO ADDR_W + 1)
    RTS_FREE  : positive := 512                   -- TX FIFO free space below which RTS stops the sender
  );
  port (
    clk          : in  std_logic;
    rst          : in  std_logic;
    -- configuration (MODE_CTRL, UART_DIV)
    cfg_div      : in  unsigned(15 downto 0);
    cfg_rtscts   : in  std_logic;
    -- UART pins
    uart_rx      : in  std_logic;                 -- asynchronous
    uart_tx      : out std_logic;
    uart_rts_n   : out std_logic;
    uart_cts_n   : in  std_logic;                 -- asynchronous
    -- TX FIFO write side (to the link)
    tx_wr        : out std_logic;
    tx_data      : out std_logic_vector(7 downto 0);
    tx_commit    : out std_logic;
    tx_free      : in  unsigned(FREE_W - 1 downto 0);
    -- RX FIFO read side (from the link)
    rx_rd        : out std_logic;
    rx_data      : in  std_logic_vector(7 downto 0);
    rx_valid     : in  std_logic;
    rx_empty     : in  std_logic;
    -- events (one-cycle pulses)
    ev_rx_ovf    : out std_logic;                 -- UART byte lost (buffer / FIFO full)
    ev_frame_err : out std_logic;                 -- UART framing error
    ev_frame     : out std_logic;                 -- frame written to the TX FIFO
    ev_skip      : out std_logic                  -- received frame of another TYPE discarded
  );
end entity uart_bridge;

architecture rtl of uart_bridge is

  ------------------------------------------------------------------------------
  -- UART -> link
  ------------------------------------------------------------------------------
  type t_buf is array (0 to MAX_PAY - 1) of std_logic_vector(7 downto 0);
  type t_pk_state is (P_COLLECT, P_WAIT, P_TYPE, P_LENH, P_LENL, P_PAY);

  signal rxb       : std_logic_vector(7 downto 0);
  signal rxb_valid : std_logic;
  signal rx_ferr   : std_logic;
  signal rx_busy   : std_logic;

  signal buf       : t_buf;
  signal buf_q     : std_logic_vector(7 downto 0) := (others => '0');
  signal rd_idx    : natural range 0 to MAX_PAY - 1 := 0;
  signal n         : natural range 0 to MAX_PAY := 0;       -- bytes in the buffer
  signal pk_left   : natural range 0 to MAX_PAY := 0;       -- payload bytes still to write
  signal pk        : t_pk_state := P_COLLECT;
  signal hold      : std_logic_vector(7 downto 0) := (others => '0');
  signal hold_v    : std_logic := '0';
  signal gap_cnt   : unsigned(21 downto 0) := (others => '0');
  signal gap_thr   : unsigned(21 downto 0) := (others => '0');
  signal ovf_q     : std_logic := '0';
  signal frame_q   : std_logic := '0';

  ------------------------------------------------------------------------------
  -- link -> UART
  ------------------------------------------------------------------------------
  type t_up_state is (U_IDLE, U_HDR, U_PAY, U_SKIP);

  signal up        : t_up_state := U_IDLE;
  signal hdr_idx   : natural range 0 to 2 := 0;
  signal f_type    : std_logic_vector(7 downto 0) := (others => '0');
  signal len_h     : std_logic_vector(7 downto 0) := (others => '0');
  signal req_left  : unsigned(15 downto 0) := (others => '0');  -- payload reads still to issue
  signal dat_left  : unsigned(15 downto 0) := (others => '0');  -- payload bytes still to receive
  signal rd_q      : std_logic := '0';                          -- rd_en to the RX FIFO (registered)
  signal pend      : std_logic := '0';                          -- = rd_q: read in flight, data next cycle
  signal tb_byte   : std_logic_vector(7 downto 0) := (others => '0');
  signal tb_v      : std_logic := '0';                          -- byte staged for uart_tx
  signal tx_start  : std_logic;
  signal tx_ready  : std_logic;
  signal cts_s     : std_logic;
  signal skip_q    : std_logic := '0';

begin

  ------------------------------------------------------------------------------
  -- UART receiver and transmitter
  ------------------------------------------------------------------------------
  u_rx : entity work.uart_rx
    port map (clk => clk, rst => rst, div => cfg_div, rx => uart_rx,
              data => rxb, valid => rxb_valid, frame_err => rx_ferr, busy => rx_busy);

  u_tx : entity work.uart_tx
    port map (clk => clk, rst => rst, div => cfg_div, data => tb_byte, start => tx_start,
              ready => tx_ready, tx => uart_tx);

  u_cts : entity work.sync_bit
    generic map (STAGES => 2, INIT_VAL => '0')
    port map (clk => clk, d => uart_cts_n, q => cts_s);

  ------------------------------------------------------------------------------
  -- UART -> link: buffer and frame writer
  ------------------------------------------------------------------------------
  -- buffer read port (registered)
  process (clk)
  begin
    if rising_edge(clk) then
      buf_q <= buf(rd_idx);
    end if;
  end process;

  process (clk)
    variable put   : boolean;                    -- write byte b into buf(n)
    variable b     : std_logic_vector(7 downto 0);
    variable n_v   : natural range 0 to MAX_PAY;
  begin
    if rising_edge(clk) then
      tx_wr     <= '0';
      tx_commit <= '0';
      ovf_q     <= '0';
      frame_q   <= '0';
      -- idle gap: 20.5 bit periods from the middle of the stop bit (where
      -- uart_rx ends busy) = 2 character times after the end of the stop bit
      gap_thr   <= shift_left(resize(cfg_div, 22), 4) + shift_left(resize(cfg_div, 22), 2)
                   + shift_right(resize(cfg_div, 22), 1);

      if rst = '1' then
        pk      <= P_COLLECT;
        n       <= 0;
        hold_v  <= '0';
        gap_cnt <= (others => '0');
        rd_idx  <= 0;
      else
        -- idle gap after the last byte
        if rxb_valid = '1' or rx_busy = '1' then
          gap_cnt <= (others => '0');
        elsif gap_cnt /= (gap_cnt'range => '1') then
          gap_cnt <= gap_cnt + 1;
        end if;

        put := false;
        b   := rxb;
        n_v := n;

        case pk is
          when P_COLLECT =>
            if hold_v = '1' then
              put := true;
              b   := hold;
              if rxb_valid = '1' then
                hold <= rxb;                      -- hold stays occupied
              else
                hold_v <= '0';
              end if;
            elsif rxb_valid = '1' then
              put := true;
            end if;
            if put then
              buf(n) <= b;
              n_v := n + 1;
            end if;
            n <= n_v;
            if n_v = MAX_PAY or (n_v > 0 and not put and gap_cnt >= gap_thr) then
              pk <= P_WAIT;
            end if;

          when others =>
            -- frame being written: hold one byte, lose further ones
            if rxb_valid = '1' then
              if hold_v = '0' then
                hold   <= rxb;
                hold_v <= '1';
              else
                ovf_q <= '1';
              end if;
            end if;

            case pk is
              when P_WAIT =>
                if tx_free >= n + 4 then
                  pk <= P_TYPE;
                end if;
              when P_TYPE =>
                tx_wr   <= '1';
                tx_data <= TYPE_UART;
                pk      <= P_LENH;
              when P_LENH =>
                tx_wr   <= '1';
                tx_data <= x"00";
                rd_idx  <= 0;
                pk      <= P_LENL;
              when P_LENL =>
                tx_wr   <= '1';
                tx_data <= std_logic_vector(to_unsigned(n, 8));
                pk_left <= n;
                if n > 1 then
                  rd_idx <= 1;
                end if;
                pk      <= P_PAY;
              when P_PAY =>
                tx_wr   <= '1';
                tx_data <= buf_q;
                if rd_idx < MAX_PAY - 1 then
                  rd_idx <= rd_idx + 1;
                end if;
                pk_left <= pk_left - 1;
                if pk_left = 1 then
                  tx_commit <= '1';
                  frame_q   <= '1';
                  n         <= 0;
                  pk        <= P_COLLECT;
                end if;
              when others =>
                null;
            end case;
        end case;

      end if;
    end if;
  end process;

  uart_rts_n <= '1' when cfg_rtscts = '1' and tx_free < RTS_FREE else '0';

  ------------------------------------------------------------------------------
  -- link -> UART: frame reader
  ------------------------------------------------------------------------------
  process (clk)
    variable len_v : unsigned(15 downto 0);
    variable rd_v  : std_logic;
  begin
    if rising_edge(clk) then
      rd_v   := '0';
      skip_q <= '0';

      if rst = '1' then
        up       <= U_IDLE;
        pend     <= '0';
        tb_v     <= '0';
        req_left <= (others => '0');
        dat_left <= (others => '0');
      else
        -- byte handed to uart_tx
        if tx_start = '1' then
          tb_v <= '0';
        end if;

        case up is
          when U_IDLE =>
            if rx_empty = '0' and pend = '0' then
              rd_v    := '1';
              hdr_idx <= 0;
              up      <= U_HDR;
            end if;

          when U_HDR =>
            if rx_valid = '1' then
              case hdr_idx is
                when 0 =>
                  f_type  <= rx_data;
                  hdr_idx <= 1;
                  rd_v    := '1';
                when 1 =>
                  len_h   <= rx_data;
                  hdr_idx <= 2;
                  rd_v    := '1';
                when others =>
                  len_v    := unsigned(len_h) & unsigned(rx_data);
                  req_left <= len_v;
                  dat_left <= len_v;
                  if len_v = 0 then
                    up <= U_IDLE;
                  elsif f_type = TYPE_UART then
                    up <= U_PAY;
                  else
                    skip_q <= '1';
                    up     <= U_SKIP;
                  end if;
              end case;
            end if;

          when U_PAY =>
            -- one byte at a time: read when nothing is staged or pending
            if rx_valid = '1' then
              tb_byte  <= rx_data;
              tb_v     <= '1';
              dat_left <= dat_left - 1;
            end if;
            if req_left /= 0 and pend = '0' and rx_valid = '0' and tb_v = '0'
               and rx_empty = '0' then
              rd_v     := '1';
              req_left <= req_left - 1;
            end if;
            if dat_left = 0 and tb_v = '0' and pend = '0' then
              up <= U_IDLE;
            end if;

          when U_SKIP =>
            -- discard the payload at full speed
            if rx_valid = '1' then
              dat_left <= dat_left - 1;
            end if;
            if req_left /= 0 and rx_empty = '0' then
              rd_v     := '1';
              req_left <= req_left - 1;
            end if;
            if dat_left = 0 then                  -- reads never exceed LEN: none in flight
              up <= U_IDLE;
            end if;
        end case;

        pend <= rd_v;
      end if;
      rd_q <= rd_v and not rst;
    end if;
  end process;

  rx_rd    <= rd_q;
  tx_start <= '1' when tb_v = '1' and tx_ready = '1' and (cfg_rtscts = '0' or cts_s = '0') else '0';

  ev_rx_ovf    <= ovf_q;
  ev_frame_err <= rx_ferr;
  ev_frame     <= frame_q;
  ev_skip      <= skip_q;

end architecture rtl;
