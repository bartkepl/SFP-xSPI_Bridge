--------------------------------------------------------------------------------
-- comma_align
--
-- Symbol alignment of the recovered bit stream (from cdr_os4x8: 1..3 bits
-- per clock) and character synchronization, after the 1000BASE-X PCS
-- synchronization process (IEEE 802.3 clause 36), simplified.
--
-- Comma: bits a..g of a symbol equal 0011111 or 1100000 (code(0) = a). In
-- valid 8b/10b data a comma occurs only in K28.1, K28.5 and K28.7, aligned to
-- the symbol start; the link uses K28.5 (idle). A comma sets the symbol
-- boundary: after its 7 bits, 3 bits complete the symbol.
--
-- Synchronization (sync output):
--   LOSS (sync = '0'):
--     * a comma at any position realigns the symbol boundary (ev_realign)
--       unless it is already at the expected position; good := 1
--     * a comma at the expected position: good := good + 1
--     * a decoder error (dec_valid and dec_err): good := 0 (alignment kept)
--     * good = N_SYNC -> SYNC
--   SYNC (sync = '1'): the boundary is not moved.
--     * error event: decoder error or a comma at an unexpected position;
--       err := err + 1, run := 0
--     * a correct decoded symbol: run := run + 1; GOOD_RUN correct symbols
--       in a row decrement err (if > 0)
--     * err = N_LOSS -> LOSS (ev_sync_loss)
--   restart = '1' forces LOSS (e.g. loss of signal reported by the SFP).
--
-- Decoder feedback: dec_8b10b decodes sym (en = sym_valid) and returns
-- dec_valid / dec_err (code_err or disp_err) two clocks later.
--
-- Pipeline:
--   stage 1: the new bits are shifted into a 12-bit register (newest bit at
--            the top, so sr(11 downto 2) holds the last 10 bits with the
--            oldest one at sr(2)).
--   stage 2: comma search at the up to 3 positions ending at the new bits,
--            bit count of the current symbol, symbol output.
--   stage 3: synchronization state machine (comma result of stage 2 and
--            decoder feedback). The realignment in stage 2 uses the sync
--            state of stage 3; one clock of delay is harmless (an expected
--            comma never realigns).
-- Latency: 2 clocks from the last bit of a symbol to sym_valid.
--
-- Assumption: in_n is 1..3 (0: no bits, ignored).
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity comma_align is
  generic (
    N_SYNC   : positive := 4;    -- commas at the expected position to acquire sync
    N_LOSS   : positive := 4;    -- error count that drops sync
    GOOD_RUN : positive := 4     -- correct symbols in a row that decrement the error count
  );
  port (
    clk          : in  std_logic;
    rst          : in  std_logic;
    restart      : in  std_logic;
    -- from cdr_os4x8
    in_bits      : in  std_logic_vector(2 downto 0);   -- (0) earliest
    in_n         : in  unsigned(1 downto 0);           -- number of valid bits
    -- aligned symbols to dec_8b10b
    sym          : out std_logic_vector(9 downto 0);   -- sym(0) = bit a (received first)
    sym_valid    : out std_logic;
    sym_comma    : out std_logic;                      -- symbol starts with a comma
    -- decoder feedback
    dec_valid    : in  std_logic;
    dec_err      : in  std_logic;
    -- status
    sync         : out std_logic;
    ev_realign   : out std_logic;                      -- pulse: boundary moved (LOSS state)
    ev_sync_loss : out std_logic                       -- pulse: SYNC -> LOSS
  );
end entity comma_align;

architecture rtl of comma_align is

  constant COMMA_P : std_logic_vector(6 downto 0) := "1111100";  -- g..a = 1111100: a..g = 0011111
  constant COMMA_N : std_logic_vector(6 downto 0) := "0000011";  -- a..g = 1100000

  signal sr       : std_logic_vector(11 downto 0) := (others => '0');
  signal k_q      : unsigned(1 downto 0) := (others => '0');

  signal cnt      : unsigned(3 downto 0) := (others => '0');  -- bits of the current symbol (0..9)
  signal sync_q   : std_logic := '0';
  signal good     : natural range 0 to N_SYNC := 0;
  signal err      : natural range 0 to N_LOSS := 0;
  signal run      : natural range 0 to GOOD_RUN := 0;

  signal found_q  : std_logic := '0';   -- stage 3: comma found in stage 2
  signal aln_q    : std_logic := '0';   -- stage 3: ... at the expected position

  signal sym_q    : std_logic_vector(9 downto 0) := (others => '0');
  signal valid_q  : std_logic := '0';
  signal comma_q  : std_logic := '0';
  signal realn_q  : std_logic := '0';
  signal loss_q   : std_logic := '0';

  function is_comma(w : std_logic_vector(6 downto 0)) return boolean is
  begin
    return w = COMMA_P or w = COMMA_N;
  end function;

  function to_sl(b : boolean) return std_logic is
  begin
    if b then return '1'; else return '0'; end if;
  end function;

begin

  process (clk)
    variable k      : natural range 0 to 3;
    variable c2     : natural range 0 to 12;
    variable found  : boolean;
    variable c_off  : natural range 0 to 2;
    variable o      : natural range 0 to 2;
    variable w      : std_logic_vector(6 downto 0);
    variable s      : std_logic_vector(9 downto 0);
    variable aligned : boolean;
    variable n_err  : natural range 0 to 2;
    variable err_v  : natural range 0 to N_LOSS + 2;
  begin
    if rising_edge(clk) then
      valid_q <= '0';
      comma_q <= '0';
      realn_q <= '0';
      loss_q  <= '0';

      if rst = '1' then
        sr     <= (others => '0');
        k_q    <= (others => '0');
        cnt    <= (others => '0');
        sync_q <= '0';
        good   <= 0;
        err    <= 0;
        run    <= 0;
        found_q <= '0';
        aln_q   <= '0';
      else
        ------------------------------------------------------------------------
        -- Stage 1: shift in the new bits (newest at the top)
        ------------------------------------------------------------------------
        case to_integer(in_n) is
          when 1      => sr <= in_bits(0) & sr(11 downto 1);
          when 2      => sr <= in_bits(1) & in_bits(0) & sr(11 downto 2);
          when 3      => sr <= in_bits(2) & in_bits(1) & in_bits(0) & sr(11 downto 3);
          when others => null;
        end case;
        k_q <= in_n;

        ------------------------------------------------------------------------
        -- Stage 2: comma search, symbol boundary, symbol output
        ------------------------------------------------------------------------
        k  := to_integer(k_q);
        c2 := to_integer(cnt) + k;

        -- comma whose bit g is the off-th newest bit (off < k)
        found := false;
        c_off := 0;
        for off in 2 downto 0 loop
          w := sr(11 - off downto 5 - off);
          if off < k and is_comma(w) then
            found := true;
            c_off := off;
          end if;
        end loop;
        aligned := found and c2 = 7 + c_off;
        found_q <= to_sl(found);
        aln_q   <= to_sl(aligned);

        n_err := 0;
        if found and not aligned and sync_q = '0' then
          -- realign: 7 + c_off bits of the new symbol received
          cnt     <= to_unsigned(7 + c_off, 4);
          realn_q <= '1';
        elsif c2 >= 10 then
          o := c2 - 10;                                 -- newer bits of the next symbol
          s := sr(11 - o downto 2 - o);
          sym_q   <= s;
          valid_q <= '1';
          if is_comma(s(6 downto 0)) then
            comma_q <= '1';
          end if;
          cnt <= to_unsigned(o, 4);
        else
          cnt <= to_unsigned(c2, 4);
        end if;

        ------------------------------------------------------------------------
        -- Stage 3: synchronization state (comma result of stage 2, registered)
        ------------------------------------------------------------------------
        if sync_q = '0' then
          if found_q = '1' then
            if aln_q = '1' and good < N_SYNC then
              good <= good + 1;
              if good + 1 = N_SYNC then
                sync_q <= '1';
                err    <= 0;
                run    <= 0;
              end if;
            elsif aln_q = '0' then
              good <= 1;
            end if;
          elsif dec_valid = '1' and dec_err = '1' then
            good <= 0;
          end if;
        else
          if found_q = '1' and aln_q = '0' then
            n_err := n_err + 1;
          end if;
          if dec_valid = '1' and dec_err = '1' then
            n_err := n_err + 1;
          end if;
          err_v := err + n_err;
          if n_err > 0 then
            run <= 0;
          elsif dec_valid = '1' then
            if run = GOOD_RUN - 1 then
              run <= 0;
              if err_v > 0 then
                err_v := err_v - 1;
              end if;
            else
              run <= run + 1;
            end if;
          end if;
          if err_v >= N_LOSS then
            sync_q <= '0';
            good   <= 0;
            err    <= 0;
            loss_q <= '1';
          else
            err <= err_v;
          end if;
        end if;

        if restart = '1' then
          if sync_q = '1' then
            loss_q <= '1';
          end if;
          sync_q <= '0';
          good   <= 0;
          err    <= 0;
        end if;
      end if;
    end if;
  end process;

  sym          <= sym_q;
  sym_valid    <= valid_q;
  sym_comma    <= comma_q;
  sync         <= sync_q;
  ev_realign   <= realn_q;
  ev_sync_loss <= loss_q;

end architecture rtl;
