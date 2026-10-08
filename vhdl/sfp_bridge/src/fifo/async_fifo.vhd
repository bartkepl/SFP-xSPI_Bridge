--------------------------------------------------------------------------------
-- async_fifo
--
-- Dual-clock FIFO on block RAM (semi-dual port: write port A, read port B)
-- with Gray-coded pointers and frame commit / abort on the write side.
--
-- Write side (wr_clk):
--   * wr_en writes wr_data at the write pointer; ignored when full
--     (wr_ovf pulses for one cycle).
--   * Written words become visible to the reader only after wr_commit = '1'
--     (in the same cycle as the last wr_en, or later). With COMMIT_MODE =
--     false every word is visible immediately and wr_commit/wr_abort are
--     ignored.
--   * wr_abort = '1' discards all words written since the last commit (the
--     write pointer returns to the committed pointer). wr_abort has priority
--     over wr_en and wr_commit in the same cycle.
--   * full and wr_free refer to the write pointer including uncommitted
--     words; wr_free = DEPTH - (words committed and not yet read, as seen
--     after synchronization) - uncommitted words. The read pointer reaches
--     the write side with SYNC_STAGES + 2 cycles of delay (synchronizer and
--     a register after the Gray-to-binary conversion), so wr_free is
--     pessimistic (never larger than the true free space).
--
-- Clock domain crossing:
--   * read pointer -> write side: Gray code through SYNC_STAGES flip-flops
--     (the pointer changes by one per read, so one bit changes at a time;
--     safe also when rd_clk stops, e.g. host SCLK).
--   * committed write pointer -> read side: request/acknowledge handshake.
--     A commit moves the pointer by a whole frame, so Gray coding would not
--     be safe. The binary pointer is held stable in pub_ptr while a toggle
--     (pub_req) crosses to the read side, which then samples pub_ptr and
--     returns the toggle (ack). A new publication starts only after the
--     acknowledge arrives; a commit made meanwhile is published right
--     after it. The write clock must therefore run for about
--     2 * SYNC_STAGES + 2 cycles after a commit that follows another commit
--     closely (always true for frame writes, which take many cycles).
--
-- Status flags full and empty are registered and computed from the pointers
-- after the current clock edge: exact with respect to the own side's
-- operations and pessimistic with respect to the other side.
-- Levels wr_free and rd_level are informational: registered from the
-- pointers before the edge, i.e. one cycle behind the own side's operations
-- (may overstate free space / stored words by one word for one cycle).
-- Flow control must use full / empty; thresholds based on the levels need a
-- margin of at least one word.
--
-- Read side (rd_clk):
--   * rd_en reads one word; rd_data is valid one rd_clk cycle later
--     (rd_valid = '1'). rd_en while empty is ignored (rd_udf pulses).
--   * empty and rd_level refer to committed words, seen with the delay of
--     the pointer synchronizer (pessimistic: never more than really present).
--
-- Assumptions:
--   * wr_rst and rd_rst are asserted together (same reset source, one
--     reset_sync per domain) and long enough for both domains to see them.
--   * Depth is a power of two, DEPTH = 2**ADDR_W.
--
-- Memory: DEPTH x DATA_W bits, inferred as BSRAM (synchronous read, no
-- reset on the array or the read register).
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity async_fifo is
  generic (
    DATA_W      : positive := 8;
    ADDR_W      : positive := 12;     -- depth = 2**ADDR_W words
    COMMIT_MODE : boolean  := true;
    SYNC_STAGES : positive := 2
  );
  port (
    -- write side
    wr_clk    : in  std_logic;
    wr_rst    : in  std_logic;                          -- synchronous to wr_clk
    wr_en     : in  std_logic;
    wr_data   : in  std_logic_vector(DATA_W - 1 downto 0);
    wr_commit : in  std_logic;
    wr_abort  : in  std_logic;
    full      : out std_logic;
    wr_free   : out unsigned(ADDR_W downto 0);          -- free words
    wr_cmt_level : out unsigned(ADDR_W downto 0);       -- committed words not yet read
    wr_ovf    : out std_logic;                          -- write while full

    -- read side
    rd_clk    : in  std_logic;
    rd_rst    : in  std_logic;                          -- synchronous to rd_clk
    rd_en     : in  std_logic;
    rd_data   : out std_logic_vector(DATA_W - 1 downto 0);
    rd_valid  : out std_logic;
    empty     : out std_logic;
    rd_level  : out unsigned(ADDR_W downto 0);          -- committed words
    rd_udf    : out std_logic                           -- read while empty
  );
end entity async_fifo;

architecture rtl of async_fifo is

  constant DEPTH : natural := 2 ** ADDR_W;

  subtype t_ptr is unsigned(ADDR_W downto 0);           -- one extra wrap bit
  type t_mem is array (0 to DEPTH - 1) of std_logic_vector(DATA_W - 1 downto 0);

  function bin2gray(b : t_ptr) return std_logic_vector is
  begin
    return std_logic_vector(b xor ('0' & b(b'left downto 1)));
  end function;

  -- b(i) = XOR of g(left downto i); written per bit so that synthesis builds
  -- balanced XOR trees instead of a ripple chain
  function gray2bin(g : std_logic_vector) return t_ptr is
    variable b : t_ptr;
    variable gg : std_logic_vector(ADDR_W downto 0) := g;
  begin
    for i in b'range loop
      b(i) := xor gg(ADDR_W downto i);
    end loop;
    return b;
  end function;

  signal mem : t_mem;

  -- write domain
  signal wptr      : t_ptr := (others => '0');          -- next write position
  signal wptr_cmt  : t_ptr := (others => '0');          -- committed pointer
  signal pub_ptr   : t_ptr := (others => '0');          -- published to read side
  signal pub_ptr_m1 : t_ptr := (others => '1');         -- pub_ptr - 1
  signal pub_req   : std_logic := '0';                  -- publication toggle
  type t_sync is array (0 to SYNC_STAGES - 1) of std_logic_vector(ADDR_W downto 0);
  signal rptr_sync : t_sync := (others => (others => '0'));
  signal ack_sync  : std_logic_vector(SYNC_STAGES - 1 downto 0) := (others => '0');
  signal rptr_w    : t_ptr := (others => '0');          -- read pointer, write domain (registered)
  signal rfull_m1  : t_ptr := to_unsigned(2 ** ADDR_W - 1, ADDR_W + 1);  -- (rptr_w xor wrap) - 1
  signal full_i    : std_logic := '0';                  -- registered
  signal wr_free_i : t_ptr := to_unsigned(2 ** ADDR_W, ADDR_W + 1);
  signal wr_cl_i   : t_ptr := (others => '0');

  -- read domain
  signal rptr      : t_ptr := (others => '0');
  signal rptr_gray : std_logic_vector(ADDR_W downto 0) := (others => '0');
  signal req_sync  : std_logic_vector(SYNC_STAGES - 1 downto 0) := (others => '0');
  signal pub_ack   : std_logic := '0';
  signal wcmt_r    : t_ptr := (others => '0');          -- committed write ptr, read domain
  signal wcmt_r_m1 : t_ptr := (others => '1');          -- wcmt_r - 1
  signal empty_i   : std_logic := '1';                  -- registered
  signal rd_level_i : t_ptr := (others => '0');
  signal rd_q      : std_logic_vector(DATA_W - 1 downto 0);
  signal rd_valid_q : std_logic := '0';

  attribute syn_preserve : boolean;
  attribute syn_preserve of rptr_sync : signal is true;
  attribute syn_preserve of ack_sync  : signal is true;
  attribute syn_preserve of req_sync  : signal is true;

begin

  assert SYNC_STAGES >= 2 report "async_fifo: SYNC_STAGES must be >= 2" severity failure;

  ------------------------------------------------------------------------------
  -- Write domain
  ------------------------------------------------------------------------------

  process (wr_clk)
  begin
    if rising_edge(wr_clk) then
      if wr_en = '1' and full_i = '0' then
        mem(to_integer(wptr(ADDR_W - 1 downto 0))) <= wr_data;
      end if;
    end if;
  end process;

  -- Write pointer and flags. The full flag for the next cycle is decided
  -- by equality comparisons against registered values only (no adder in
  -- the feedback loop):
  --   full after the edge  <=>  w_new = rptr_w xor WRAP
  --   w_new = wptr + 1     ->   wptr = (rptr_w xor WRAP) - 1 = rfull_m1
  --   w_new = wptr         ->   wptr = rptr_w xor WRAP
  --   w_new = wptr_cmt     ->   wptr_cmt = rptr_w xor WRAP
  -- rptr_w is the registered (older) read pointer, so full is pessimistic.
  process (wr_clk)
    variable rp_bin : t_ptr;
    variable r_wrap : t_ptr;
    variable acc    : boolean;      -- write accepted this cycle
    variable v      : t_ptr;
  begin
    if rising_edge(wr_clk) then
      rptr_sync <= rptr_gray & rptr_sync(0 to SYNC_STAGES - 2);
      ack_sync  <= ack_sync(SYNC_STAGES - 2 downto 0) & pub_ack;
      wr_ovf    <= '0';
      if wr_rst = '1' then
        wptr       <= (others => '0');
        wptr_cmt   <= (others => '0');
        pub_ptr    <= (others => '0');
        pub_ptr_m1 <= (others => '1');
        pub_req    <= '0';
        rptr_sync  <= (others => (others => '0'));
        rptr_w     <= (others => '0');
        rfull_m1   <= to_unsigned(DEPTH - 1, ADDR_W + 1);
        ack_sync   <= (others => '0');
        full_i     <= '0';
        wr_free_i  <= to_unsigned(DEPTH, ADDR_W + 1);
        wr_cl_i    <= (others => '0');
      else
        -- registered Gray-to-binary conversion and precomputed compare value
        rp_bin   := gray2bin(rptr_sync(SYNC_STAGES - 1));
        rptr_w   <= rp_bin;
        rp_bin(ADDR_W) := not rp_bin(ADDR_W);
        rfull_m1 <= rp_bin - 1;

        r_wrap := rptr_w;
        r_wrap(ADDR_W) := not r_wrap(ADDR_W);

        acc := wr_en = '1' and full_i = '0';
        if wr_en = '1' and full_i = '1' then
          wr_ovf <= '1';
        end if;

        if COMMIT_MODE and wr_abort = '1' then
          wptr   <= wptr_cmt;
          full_i <= '1' when wptr_cmt = r_wrap else '0';
        else
          if acc then
            wptr   <= wptr + 1;
            full_i <= '1' when wptr = rfull_m1 else '0';
          else
            full_i <= '1' when wptr = r_wrap else '0';
          end if;
          if (not COMMIT_MODE) or wr_commit = '1' then
            if acc then
              wptr_cmt <= wptr + 1;
            else
              wptr_cmt <= wptr;
            end if;
          end if;
        end if;

        -- Free space from the current registers (one cycle behind):
        -- DEPTH - (w - r) = (r - w) with the wrap bit inverted, one subtractor
        v := rptr_w - wptr;
        v(ADDR_W) := not v(ADDR_W);
        wr_free_i <= v;
        -- committed words not yet read (write-side view, one cycle behind;
        -- may overstate by the reads not yet synchronized)
        wr_cl_i <= wptr_cmt - rptr_w;

        -- Publish the committed pointer when the previous publication has
        -- been acknowledged (handshake idle) and there is something new
        if pub_req = ack_sync(SYNC_STAGES - 1) and pub_ptr /= wptr_cmt then
          pub_ptr    <= wptr_cmt;
          pub_ptr_m1 <= wptr_cmt - 1;
          pub_req    <= not pub_req;
        end if;
      end if;
    end if;
  end process;

  full    <= full_i;
  wr_free <= wr_free_i;
  wr_cmt_level <= wr_cl_i;

  ------------------------------------------------------------------------------
  -- Read domain
  ------------------------------------------------------------------------------

  -- Block RAM read port: registered output, no reset
  process (rd_clk)
  begin
    if rising_edge(rd_clk) then
      if rd_en = '1' and empty_i = '0' then
        rd_q <= mem(to_integer(rptr(ADDR_W - 1 downto 0)));
      end if;
    end if;
  end process;

  -- Read pointer and flags. empty for the next cycle by equality only:
  --   empty after the edge <=> r_new = wc_new
  --   r_new = rptr + 1  ->  rptr = wc_new - 1  (wcmt_r_m1 or pub_ptr_m1)
  process (rd_clk)
    variable pub : boolean;         -- publication accepted this cycle
    variable acc : boolean;         -- read accepted this cycle
    variable e_pub_acc, e_pub, e_acc, e_none : boolean;
  begin
    if rising_edge(rd_clk) then
      req_sync   <= req_sync(SYNC_STAGES - 2 downto 0) & pub_req;
      rd_valid_q <= '0';
      rd_udf     <= '0';
      if rd_rst = '1' then
        rptr       <= (others => '0');
        rptr_gray  <= (others => '0');
        req_sync   <= (others => '0');
        pub_ack    <= '0';
        wcmt_r     <= (others => '0');
        wcmt_r_m1  <= (others => '1');
        empty_i    <= '1';
        rd_level_i <= (others => '0');
      else
        -- New publication: pub_ptr has been stable since pub_req toggled
        pub := req_sync(SYNC_STAGES - 1) /= pub_ack;
        if pub then
          wcmt_r    <= pub_ptr;
          wcmt_r_m1 <= pub_ptr_m1;
          pub_ack   <= req_sync(SYNC_STAGES - 1);
        end if;

        acc := rd_en = '1' and empty_i = '0';
        if rd_en = '1' and empty_i = '1' then
          rd_udf <= '1';
        end if;
        if acc then
          rptr       <= rptr + 1;
          rptr_gray  <= bin2gray(rptr + 1);
          rd_valid_q <= '1';
        end if;

        -- four comparisons in parallel, then a 1-bit selection
        e_pub_acc := rptr = pub_ptr_m1;
        e_pub     := rptr = pub_ptr;
        e_acc     := rptr = wcmt_r_m1;
        e_none    := rptr = wcmt_r;
        if pub and acc then
          empty_i <= '1' when e_pub_acc else '0';
        elsif pub then
          empty_i <= '1' when e_pub else '0';
        elsif acc then
          empty_i <= '1' when e_acc else '0';
        else
          empty_i <= '1' when e_none else '0';
        end if;

        rd_level_i <= wcmt_r - rptr;      -- from current registers (one cycle behind)
      end if;
    end if;
  end process;

  rd_data  <= rd_q;
  rd_valid <= rd_valid_q;
  empty    <= empty_i;
  rd_level <= rd_level_i;

end architecture rtl;
