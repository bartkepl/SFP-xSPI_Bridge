--------------------------------------------------------------------------------
-- tx_framer
--
-- Link transmitter, character level (ADR 0005).
--
-- Character stream:
--   idle  : K28.5 D16.2 (/I/, XON)   or   K28.5 D21.5 (/P/, XOFF)
--   frame : K27.7 TYPE LEN_H LEN_L payload(LEN) CRC0 CRC1 CRC2 CRC3 K29.7
--           CRC-32 (crc32) over TYPE, LEN_H, LEN_L and payload, CRC0 = bits 7..0
--
-- Frame source: TX FIFO (async_fifo read side) holding complete, committed
-- frames as  TYPE, LEN_H, LEN_L, payload(LEN).  Because frames are committed
-- whole, fifo_empty = '0' means a complete frame is available.
--
-- Rules:
--   * A frame starts only after a complete idle pair, when the FIFO is not
--     empty and the remote side does not request XOFF (xoff_remote = '0').
--   * A started frame is always sent to the end (no gaps inside a frame).
--   * The second character of each idle pair carries the local XOFF state
--     (xoff_local), so the state is repeated continuously.
--
-- Handshake with the encoder:
--   char_data / char_k always hold the character the encoder takes at the
--   next char_en pulse. On char_en the framer prepares the following
--   character (registered), so char_data/char_k change one cycle after
--   char_en. After reset the prepared character is K28.5.
--
-- Assumptions:
--   * char_en pulses at most once every 4 clock cycles (nominally every 5
--     cycles of clk_sys = 50 MHz: one symbol per 10 bit periods, ADR 0007);
--     the FIFO has a 1-cycle read latency.
--     This leaves time to prefetch the next byte and to finish the CRC.
--   * LEN = 0 is sent as a frame without payload; LEN > MAX_LEN is sent with
--     its full length (keeps the FIFO aligned) and flagged on len_err; the
--     receiver rejects such frames. Validity is the writer's responsibility.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.bridge_pkg.all;

entity tx_framer is
  generic (
    MAX_LEN : positive := 1024
  );
  port (
    clk         : in  std_logic;
    rst         : in  std_logic;
    -- to the encoder
    char_en     : in  std_logic;                     -- encoder takes char_data/char_k
    char_data   : out std_logic_vector(7 downto 0);
    char_k      : out std_logic;
    -- TX FIFO read port (1-cycle latency)
    fifo_empty  : in  std_logic;
    fifo_rd     : out std_logic;
    fifo_data   : in  std_logic_vector(7 downto 0);
    fifo_valid  : in  std_logic;
    -- flow control
    xoff_local  : in  std_logic;   -- our receiver asks the remote to pause
    xoff_remote : in  std_logic;   -- remote asks us to pause (from rx_deframer)
    -- status
    busy        : out std_logic;   -- frame in progress
    frame_sent  : out std_logic;   -- pulse when K29.7 is prepared
    len_err     : out std_logic    -- pulse: LEN > MAX_LEN read from the FIFO
  );
end entity tx_framer;

architecture rtl of tx_framer is

  -- Kind of the character currently prepared in nxt_data / nxt_k
  type t_state is (S_IDLE_K, S_IDLE_D, S_SOF, S_TYPE, S_LENH, S_LENL,
                   S_PAY, S_CRC0, S_CRC1, S_CRC2, S_CRC3, S_EOF);

  constant D21_5 : std_logic_vector(7 downto 0) := x"B5";

  signal state      : t_state := S_IDLE_K;
  signal nxt_data   : std_logic_vector(7 downto 0) := K28_5;
  signal nxt_k      : std_logic := '1';

  signal len_h      : std_logic_vector(7 downto 0) := (others => '0');
  signal pay_left   : unsigned(15 downto 0) := (others => '0');   -- payload bytes still to send

  -- one-byte prefetch from the FIFO
  signal pf_data    : std_logic_vector(7 downto 0) := (others => '0');
  signal pf_full    : std_logic := '0';
  signal rd_pend    : std_logic := '0';
  signal fetch_left : unsigned(16 downto 0) := (others => '0');   -- bytes of this frame still to read

  signal fifo_rd_i  : std_logic;

  -- CRC
  signal crc_init   : std_logic := '0';
  signal crc_en     : std_logic := '0';
  signal crc_in     : std_logic_vector(7 downto 0) := (others => '0');
  signal crc_val    : std_logic_vector(31 downto 0);

begin

  u_crc : entity work.crc32
    port map (clk => clk, rst => rst, init => crc_init, en => crc_en,
              data => crc_in, crc => crc_val, crc_ok => open);

  -- Read the next byte of the current frame whenever the prefetch is empty
  fifo_rd_i <= '1' when fetch_left /= 0 and pf_full = '0' and rd_pend = '0'
                        and fifo_empty = '0' else '0';
  fifo_rd   <= fifo_rd_i;

  process (clk)
    variable take  : boolean;                -- pf_data consumed this cycle
    variable fl    : unsigned(16 downto 0);  -- next fetch_left
    variable len_v : unsigned(15 downto 0);

    procedure send_byte(signal d : out std_logic_vector(7 downto 0);
                        signal k : out std_logic;
                        b : std_logic_vector(7 downto 0)) is
    begin
      d <= b;
      k <= '0';
    end procedure;
  begin
    if rising_edge(clk) then
      crc_init   <= '0';
      crc_en     <= '0';
      frame_sent <= '0';
      len_err    <= '0';

      if rst = '1' then
        state      <= S_IDLE_K;
        nxt_data   <= K28_5;
        nxt_k      <= '1';
        pf_full    <= '0';
        rd_pend    <= '0';
        fetch_left <= (others => '0');
        pay_left   <= (others => '0');
      else
        take := false;
        fl   := fetch_left;

        -- prefetch
        if fifo_rd_i = '1' then
          rd_pend <= '1';
          fl := fl - 1;
        end if;
        if rd_pend = '1' and fifo_valid = '1' then
          rd_pend <= '0';
          pf_data <= fifo_data;
          pf_full <= '1';
        end if;

        -- character sequencing
        if char_en = '1' then
          case state is
            when S_IDLE_K =>
              nxt_data <= D21_5 when xoff_local = '1' else D16_2;
              nxt_k    <= '0';
              state    <= S_IDLE_D;

            when S_IDLE_D =>
              if fifo_empty = '0' and xoff_remote = '0' then
                nxt_data <= K27_7;
                nxt_k    <= '1';
                fl       := to_unsigned(3, fl'length);   -- TYPE, LEN_H, LEN_L
                state    <= S_SOF;
              else
                nxt_data <= K28_5;
                nxt_k    <= '1';
                state    <= S_IDLE_K;
              end if;

            when S_SOF =>                                 -- TYPE
              send_byte(nxt_data, nxt_k, pf_data);
              take := true;
              crc_init <= '1'; crc_en <= '1'; crc_in <= pf_data;
              state <= S_TYPE;

            when S_TYPE =>                                -- LEN_H
              send_byte(nxt_data, nxt_k, pf_data);
              take := true;
              len_h  <= pf_data;
              crc_en <= '1'; crc_in <= pf_data;
              state  <= S_LENH;

            when S_LENH =>                                -- LEN_L
              send_byte(nxt_data, nxt_k, pf_data);
              take := true;
              crc_en <= '1'; crc_in <= pf_data;
              len_v := unsigned(len_h) & unsigned(pf_data);
              if len_v > MAX_LEN then
                len_err <= '1';
              end if;
              pay_left <= len_v;
              fl       := fl + resize(len_v, fl'length);
              state    <= S_LENL;

            when S_LENL | S_PAY =>                        -- payload or CRC0
              if pay_left /= 0 then
                send_byte(nxt_data, nxt_k, pf_data);
                take := true;
                crc_en   <= '1'; crc_in <= pf_data;
                pay_left <= pay_left - 1;
                state    <= S_PAY;
              else
                send_byte(nxt_data, nxt_k, crc_val(7 downto 0));
                state <= S_CRC0;
              end if;

            when S_CRC0 =>
              send_byte(nxt_data, nxt_k, crc_val(15 downto 8));
              state <= S_CRC1;

            when S_CRC1 =>
              send_byte(nxt_data, nxt_k, crc_val(23 downto 16));
              state <= S_CRC2;

            when S_CRC2 =>
              send_byte(nxt_data, nxt_k, crc_val(31 downto 24));
              state <= S_CRC3;

            when S_CRC3 =>
              nxt_data   <= K29_7;
              nxt_k      <= '1';
              frame_sent <= '1';
              state      <= S_EOF;

            when S_EOF =>
              nxt_data <= K28_5;
              nxt_k    <= '1';
              state    <= S_IDLE_K;
          end case;
        end if;

        if take then
          pf_full <= '0';
        end if;
        fetch_left <= fl;
      end if;
    end if;
  end process;

  busy      <= '0' when state = S_IDLE_K or state = S_IDLE_D else '1';
  char_data <= nxt_data;
  char_k    <= nxt_k;

end architecture rtl;
