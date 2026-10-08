--------------------------------------------------------------------------------
-- rx_deframer
--
-- Link receiver, character level (ADR 0005). Consumes decoded 8b/10b
-- characters (dec_8b10b) and writes received frames into the RX FIFO
-- (async_fifo, COMMIT_MODE = true) in the host format
--   TYPE, LEN_H, LEN_L, payload(LEN)
-- committing a frame only when it is complete and correct, otherwise
-- aborting it (all its bytes are discarded from the FIFO).
--
-- Frame checks (an error aborts the frame and pulses one event output):
--   ev_code_err   code_err or disp_err from the decoder inside a frame
--   ev_len_err    LEN = 0 or LEN > MAX_LEN, or K29.7 not at the position
--                 implied by LEN (premature or missing end of frame)
--   ev_framing    unexpected control character inside a frame (other than
--                 K29.7 at the end), or K27.7 inside a frame
--   ev_crc_err    CRC-32 over TYPE, LEN_H, LEN_L, payload does not match
--   ev_ovf        not enough free space in the RX FIFO for the frame
--                 (checked when LEN is known) or FIFO overflow
--   ev_frame_ok   frame committed
--
-- Idle and flow control (ADR 0005, ADR 0008):
--   * K28.5 D16.2 (/I/) -> remote_ready <= '1', xoff_remote <= '0'
--   * K28.5 D21.5 (/P/) -> remote_ready <= '1', xoff_remote <= '1'
--   * K28.5 D5.6  (/R/) -> remote_ready <= '0', xoff_remote <= '1'
--     (the remote receiver is not synchronized: frames would be lost)
--   * While sync = '0' (no character alignment) any frame in progress is
--     aborted, remote_ready is '0' and xoff_remote is '1' (remote state
--     unknown).
--   * xoff_local (to the local transmitter) is '1' when the RX FIFO free
--     space falls below XOFF_ON and returns to '0' above XOFF_OFF.
--
-- XOFF thresholds: the XOFF state reaches the remote side only between our
-- own transmitted frames. In the worst case, after the threshold is crossed
-- the receiver must still accept the frame in progress, a frame the remote
-- may start before our current frame (up to MAX_LEN) ends, and margin:
--   XOFF_ON  >= 3 * (MAX_LEN + 3) + margin
--   XOFF_OFF  = XOFF_ON + hysteresis  (< FIFO depth)
-- With MAX_LEN = 1024 this requires an 8 KiB RX FIFO (defaults below).
--
-- Assumptions:
--   * Characters arrive at most once every 4 clock cycles (nominally every
--     5 cycles of clk_sys = 50 MHz, ADR 0007); char_valid marks a character.
--   * wr_free is the async_fifo write-side free count (one cycle behind,
--     overstates by at most one word); the space check adds one word.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.bridge_pkg.all;

entity rx_deframer is
  generic (
    MAX_LEN  : positive := 1024;
    FREE_W   : positive := 14;                -- width of wr_free (ADDR_W + 1)
    XOFF_ON  : natural  := 3 * (1024 + 3) + 64;
    XOFF_OFF : natural  := 3 * (1024 + 3) + 64 + 1024
  );
  port (
    clk         : in  std_logic;
    rst         : in  std_logic;
    sync        : in  std_logic;                     -- character alignment valid
    -- from the decoder
    char_valid  : in  std_logic;
    char_data   : in  std_logic_vector(7 downto 0);
    char_k      : in  std_logic;
    code_err    : in  std_logic;
    disp_err    : in  std_logic;
    -- RX FIFO write port
    fifo_wr     : out std_logic;
    fifo_data   : out std_logic_vector(7 downto 0);
    fifo_commit : out std_logic;
    fifo_abort  : out std_logic;
    fifo_free   : in  unsigned(FREE_W - 1 downto 0);
    fifo_ovf    : in  std_logic;
    -- flow control
    xoff_remote : out std_logic;
    remote_ready : out std_logic;                    -- remote receiver synchronized
    xoff_local  : out std_logic;
    -- events (one-cycle pulses)
    ev_frame_ok : out std_logic;
    ev_crc_err  : out std_logic;
    ev_code_err : out std_logic;
    ev_len_err  : out std_logic;
    ev_framing  : out std_logic;
    ev_ovf      : out std_logic;
    busy        : out std_logic                      -- frame in progress
  );
end entity rx_deframer;

architecture rtl of rx_deframer is

  type t_state is (S_HUNT,      -- outside a frame
                   S_IDLE2,     -- K28.5 received, expecting second idle character
                   S_TYPE, S_LENH, S_LENL,
                   S_PAY,
                   S_CRC,       -- four CRC bytes
                   S_EOF,       -- expecting K29.7
                   S_SKIP);     -- discarding the rest of a rejected frame

  signal state     : t_state := S_HUNT;
  signal len_h     : std_logic_vector(7 downto 0) := (others => '0');
  signal pay_left  : unsigned(10 downto 0) := (others => '0');
  signal crc_left  : unsigned(1 downto 0) := (others => '0');

  signal xoff_r    : std_logic := '1';
  signal rrdy_r    : std_logic := '0';
  signal xoff_l    : std_logic := '0';

  signal crc_init  : std_logic := '0';
  signal crc_en    : std_logic := '0';
  signal crc_in    : std_logic_vector(7 downto 0) := (others => '0');
  signal crc_ok    : std_logic;

  signal wr_q      : std_logic := '0';
  signal data_q    : std_logic_vector(7 downto 0) := (others => '0');
  signal commit_q  : std_logic := '0';
  signal abort_q   : std_logic := '0';
  signal eof_chk   : std_logic := '0';   -- evaluate CRC one cycle after K29.7

begin

  u_crc : entity work.crc32
    port map (clk => clk, rst => rst, init => crc_init, en => crc_en,
              data => crc_in, crc => open, crc_ok => crc_ok);

  process (clk)
    variable len_v : unsigned(15 downto 0);

    -- abort the frame in progress with one error event
    procedure drop is
    begin
      abort_q <= '1';
    end procedure;
  begin
    if rising_edge(clk) then
      wr_q        <= '0';
      commit_q    <= '0';
      abort_q     <= '0';
      crc_init    <= '0';
      crc_en      <= '0';
      eof_chk     <= '0';
      ev_frame_ok <= '0';
      ev_crc_err  <= '0';
      ev_code_err <= '0';
      ev_len_err  <= '0';
      ev_framing  <= '0';
      ev_ovf      <= '0';

      -- local XOFF with hysteresis on the RX FIFO free space
      if fifo_free < XOFF_ON then
        xoff_l <= '1';
      elsif fifo_free > XOFF_OFF then
        xoff_l <= '0';
      end if;

      if rst = '1' then
        state  <= S_HUNT;
        xoff_r <= '1';
        rrdy_r <= '0';
        xoff_l <= '0';
      elsif sync = '0' then
        if state /= S_HUNT and state /= S_IDLE2 and state /= S_SKIP then
          drop;
        end if;
        state  <= S_HUNT;
        xoff_r <= '1';
        rrdy_r <= '0';
      else
        -- CRC verdict one cycle after K29.7 (crc_ok then includes CRC3)
        if eof_chk = '1' then
          if crc_ok = '1' then
            commit_q    <= '1';
            ev_frame_ok <= '1';
          else
            abort_q    <= '1';
            ev_crc_err <= '1';
          end if;
        end if;

        -- FIFO overflow inside a frame
        if fifo_ovf = '1' and (state = S_PAY or state = S_TYPE or state = S_LENH
                               or state = S_LENL) then
          drop;
          ev_ovf <= '1';
          state  <= S_SKIP;

        elsif char_valid = '1' then
          if (code_err = '1' or disp_err = '1') then
            -- line error: abort a frame in progress, resynchronize on idle
            if state = S_TYPE or state = S_LENH or state = S_LENL or state = S_PAY
               or state = S_CRC or state = S_EOF then
              drop;
              ev_code_err <= '1';
            end if;
            state <= S_HUNT;

          else
            case state is
              when S_HUNT | S_SKIP =>
                if char_k = '1' and char_data = K28_5 then
                  state <= S_IDLE2;
                elsif char_k = '1' and char_data = K27_7 and state = S_HUNT then
                  state <= S_TYPE;
                end if;
                -- S_SKIP ends at the next K28.5 (idle after the rejected frame)

              when S_IDLE2 =>
                if char_k = '0' and char_data = D16_2 then
                  xoff_r <= '0';
                  rrdy_r <= '1';
                  state  <= S_HUNT;
                elsif char_k = '0' and char_data = D21_5 then
                  xoff_r <= '1';
                  rrdy_r <= '1';
                  state  <= S_HUNT;
                elsif char_k = '0' and char_data = D5_6 then
                  xoff_r <= '1';
                  rrdy_r <= '0';
                  state  <= S_HUNT;
                elsif char_k = '1' and char_data = K28_5 then
                  state <= S_IDLE2;
                elsif char_k = '1' and char_data = K27_7 then
                  state <= S_TYPE;
                else
                  state <= S_HUNT;
                end if;

              when S_TYPE | S_LENH | S_LENL | S_PAY | S_CRC =>
                if char_k = '1' then
                  -- control character before the end of the frame
                  drop;
                  if char_data = K29_7 then
                    ev_len_err <= '1';          -- premature end of frame
                    state <= S_HUNT;
                  else
                    ev_framing <= '1';
                    if char_data = K28_5 then
                      state <= S_IDLE2;
                    else
                      state <= S_SKIP;
                    end if;
                  end if;
                else
                  case state is
                    when S_TYPE =>
                      wr_q <= '1'; data_q <= char_data;
                      crc_init <= '1'; crc_en <= '1'; crc_in <= char_data;
                      state <= S_LENH;

                    when S_LENH =>
                      wr_q <= '1'; data_q <= char_data;
                      crc_en <= '1'; crc_in <= char_data;
                      len_h <= char_data;
                      state <= S_LENL;

                    when S_LENL =>
                      len_v := unsigned(len_h) & unsigned(char_data);
                      crc_en <= '1'; crc_in <= char_data;
                      if len_v = 0 or len_v > MAX_LEN then
                        drop;
                        ev_len_err <= '1';
                        state <= S_SKIP;
                      elsif resize(fifo_free, 17) < resize(len_v, 17) + 2 then
                        -- LEN_L + payload must fit (+1 word for the
                        -- one-cycle-behind free count)
                        drop;
                        ev_ovf <= '1';
                        state <= S_SKIP;
                      else
                        wr_q <= '1'; data_q <= char_data;
                        pay_left <= len_v(10 downto 0);
                        state <= S_PAY;
                      end if;

                    when S_PAY =>
                      wr_q <= '1'; data_q <= char_data;
                      crc_en <= '1'; crc_in <= char_data;
                      if pay_left = 1 then
                        crc_left <= "11";
                        state    <= S_CRC;
                      end if;
                      pay_left <= pay_left - 1;

                    when others =>                -- S_CRC
                      crc_en <= '1'; crc_in <= char_data;
                      if crc_left = 0 then
                        state <= S_EOF;
                      end if;
                      crc_left <= crc_left - 1;
                  end case;
                end if;

              when S_EOF =>
                if char_k = '1' and char_data = K29_7 then
                  eof_chk <= '1';               -- verdict next cycle
                  state   <= S_HUNT;
                else
                  drop;
                  ev_len_err <= '1';            -- missing end of frame
                  if char_k = '1' and char_data = K28_5 then
                    state <= S_IDLE2;
                  else
                    state <= S_SKIP;
                  end if;
                end if;
            end case;
          end if;
        end if;
      end if;
    end if;
  end process;

  fifo_wr     <= wr_q;
  fifo_data   <= data_q;
  fifo_commit <= commit_q;
  fifo_abort  <= abort_q;
  xoff_remote  <= xoff_r;
  remote_ready <= rrdy_r;
  xoff_local  <= xoff_l;
  busy        <= '0' when state = S_HUNT or state = S_IDLE2 or state = S_SKIP else '1';

end architecture rtl;
