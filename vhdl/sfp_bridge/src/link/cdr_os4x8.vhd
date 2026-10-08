--------------------------------------------------------------------------------
-- cdr_os4x8
--
-- Data recovery from 4x oversampled serial data, 8 samples per clock
-- (ADR 0007): IDES8 at FCLK = 2 x line rate (DDR) delivers 8 samples = 2 bit
-- periods per clk_sys cycle. The module selects one of the 4 sampling
-- phases, tracks the phase from the observed transitions and outputs 1, 2 or
-- 3 bits per clock (nominally 2; 1 or 3 when the phase wraps, which absorbs
-- the frequency difference between the two link ends). No elastic buffer is
-- needed downstream.
--
-- Sample numbering: samples(0) is the earliest sample of the clock cycle.
-- Global sample index n = 8 * cycle + i; phase class of a sample = n mod 4.
--
-- Phase detector:
--   * An edge at class k means samples k-1 and k differ (the bit boundary
--     lies between them). Edges are counted per class over a window of
--     2**WIN_LOG2 clocks.
--   * With sampling phase p, the class of an edge relative to p is
--     r = (k - p) mod 4, i.e. the boundary lies in (r-1, r] sample periods
--     after the sampling instant (r = 0: within one period before it).
--     The ideal boundary position is 2 sample periods after the sampling
--     instant (sample in the middle of the bit): edges split between r = 2
--     and r = 3.
--   * Mean boundary offset from the ideal position, in half sample periods:
--       S = 3*n0 + n3 - n2 - 3*n1      (n_r = edge count of relative class r;
--                                       r = 0 is taken as late, +1.5 periods)
--     At the end of each window, with tot = n0 + n1 + n2 + n3 (decision only
--     when tot >= MIN_EDGES), first matching rule:
--       n0 + n1 > n2 + n3  -> p + 1 if n0 >= n1, else p - 1
--                             (boundaries mostly within one period of the
--                             sampling instant; S is ambiguous there, e.g.
--                             n0 = n1 gives S = 0 at the worst phase)
--       4 * S >  5 * tot   -> p + 1  (mean offset > +0.625 period: sample later)
--       4 * S < -5 * tot   -> p - 1  (mean offset < -0.625 period)
--     A step moves the mean by one period; the dead band of +/-0.625 period
--     (1/2 + 1/8 hysteresis) prevents a step back, so random jitter does not
--     toggle the phase. Far off (all edges at r = 0 or r = 1) the phase
--     converges in one or two windows.
--   * Maximum tracked frequency offset: one phase step (1/4 UI) per window
--     of 2 * 2**WIN_LOG2 bits; WIN_LOG2 = 5 -> about 3900 ppm.
--
-- Bit selection (sampling instants at classes p and p+4 of each cycle):
--   no change        : samples(p), samples(p+4)                      2 bits
--   p -> p+1, p < 3  : samples(p+1), samples(p+5)                    2 bits
--   p = 3 -> 0       : samples(4)                                    1 bit
--   p -> p-1, p > 0  : samples(p-1), samples(p+3)                    2 bits
--   p = 0 -> 3       : previous samples(7), samples(3), samples(7)   3 bits
--
-- Outputs: bits(0) is the earliest recovered bit; bits(nbits-1 downto 0) are
-- valid (nbits = 1..3, 0 only during reset). Latency: 2 clocks from samples
-- to bits.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cdr_os4x8 is
  generic (
    WIN_LOG2  : positive := 5;   -- phase decision window = 2**WIN_LOG2 clocks
    MIN_EDGES : positive := 8    -- minimum edges in a window for a decision
  );
  port (
    clk       : in  std_logic;
    rst       : in  std_logic;
    samples   : in  std_logic_vector(7 downto 0);  -- from IDES8, (0) earliest
    -- recovered bits
    bits      : out std_logic_vector(2 downto 0);  -- (0) earliest
    nbits     : out unsigned(1 downto 0);          -- valid bits: 1..3
    -- status
    phase     : out unsigned(1 downto 0);          -- current sampling phase
    shift_up  : out std_logic;                     -- pulse: phase moved later
    shift_dn  : out std_logic;                     -- pulse: phase moved earlier
    activity  : out std_logic                      -- last window had >= MIN_EDGES edges
  );
end entity cdr_os4x8;

architecture rtl of cdr_os4x8 is

  constant ACC_W : positive := WIN_LOG2 + 2;      -- up to 2 edges per class per clock
  constant TOT_W : positive := ACC_W + 3;         -- sum of 4 classes, weighted sums

  type t_acc is array (0 to 3) of unsigned(ACC_W - 1 downto 0);
  type t_act is (A_NONE, A_UP, A_DN);

  signal s1       : std_logic_vector(7 downto 0) := (others => '0');  -- registered samples
  signal p7       : std_logic := '0';                                 -- previous s1(7)

  signal acc      : t_acc := (others => (others => '0'));
  signal lat      : t_acc := (others => (others => '0'));
  signal wcnt     : unsigned(WIN_LOG2 - 1 downto 0) := (others => '0');
  signal dec_go   : std_logic := '0';

  -- decision stage 0: counts rotated to the current phase
  signal d0_go    : std_logic := '0';
  signal rel      : t_acc := (others => (others => '0'));   -- rel(r) = n_r
  -- decision stage 1 results
  signal d1_go    : std_logic := '0';
  signal late_q   : unsigned(TOT_W - 1 downto 0) := (others => '0');  -- 3*n0 + n3
  signal early_q  : unsigned(TOT_W - 1 downto 0) := (others => '0');  -- 3*n1 + n2
  signal tot_q    : unsigned(TOT_W - 1 downto 0) := (others => '0');
  signal near_q   : std_logic := '0';   -- n0 + n1 > n2 + n3
  signal n0ge_q   : std_logic := '0';   -- n0 >= n1

  signal p        : unsigned(1 downto 0) := (others => '0');
  signal act      : t_act := A_NONE;

  signal bits_q   : std_logic_vector(2 downto 0) := (others => '0');
  signal nbits_q  : unsigned(1 downto 0) := (others => '0');
  signal up_q     : std_logic := '0';
  signal dn_q     : std_logic := '0';
  signal act_q    : std_logic := '0';

begin

  process (clk)
    variable e    : std_logic_vector(7 downto 0);      -- edge before sample i
    variable cnt  : unsigned(ACC_W - 1 downto 0);
    variable pi   : natural range 0 to 3;
    variable r    : natural range 0 to 3;
    variable n0, n1, n2, n3 : unsigned(ACC_W - 1 downto 0);
    variable lhs, rhs5 : unsigned(TOT_W + 2 downto 0);
    variable n0w, n1w  : unsigned(TOT_W - 1 downto 0);
  begin
    if rising_edge(clk) then
      up_q <= '0';
      dn_q <= '0';

      if rst = '1' then
        s1      <= (others => '0');
        p7      <= '0';
        acc     <= (others => (others => '0'));
        lat     <= (others => (others => '0'));
        wcnt    <= (others => '0');
        dec_go  <= '0';
        d0_go   <= '0';
        d1_go   <= '0';
        p       <= (others => '0');
        act     <= A_NONE;
        bits_q  <= (others => '0');
        nbits_q <= (others => '0');
        act_q   <= '0';
      else
        ------------------------------------------------------------------------
        -- Stage 0: register the samples
        ------------------------------------------------------------------------
        s1 <= samples;
        p7 <= s1(7);

        ------------------------------------------------------------------------
        -- Stage A: edge statistics per absolute class
        ------------------------------------------------------------------------
        e(0) := s1(0) xor p7;
        for i in 1 to 7 loop
          e(i) := s1(i) xor s1(i - 1);
        end loop;

        wcnt   <= wcnt + 1;
        dec_go <= '0';
        for k in 0 to 3 loop
          cnt := (others => '0');
          if e(k) = '1' then cnt := cnt + 1; end if;
          if e(k + 4) = '1' then cnt := cnt + 1; end if;
          if wcnt = 2 ** WIN_LOG2 - 1 then
            lat(k) <= acc(k) + cnt;
            acc(k) <= (others => '0');
          else
            acc(k) <= acc(k) + cnt;
          end if;
        end loop;
        if wcnt = 2 ** WIN_LOG2 - 1 then
          dec_go <= '1';
        end if;

        ------------------------------------------------------------------------
        -- Stage A: bit selection and phase update
        ------------------------------------------------------------------------
        pi := to_integer(p);
        bits_q <= (others => '0');
        case act is
          when A_NONE =>
            bits_q(1 downto 0) <= s1(pi + 4) & s1(pi);
            nbits_q <= to_unsigned(2, 2);
          when A_UP =>
            if pi = 3 then
              bits_q(0) <= s1(4);
              nbits_q   <= to_unsigned(1, 2);
            else
              bits_q(1 downto 0) <= s1(pi + 5) & s1(pi + 1);
              nbits_q <= to_unsigned(2, 2);
            end if;
            p    <= p + 1;
            up_q <= '1';
          when A_DN =>
            if pi = 0 then
              bits_q  <= s1(7) & s1(3) & p7;
              nbits_q <= to_unsigned(3, 2);
            else
              bits_q(1 downto 0) <= s1(pi + 3) & s1(pi - 1);
              nbits_q <= to_unsigned(2, 2);
            end if;
            p    <= p - 1;
            dn_q <= '1';
        end case;
        act <= A_NONE;

        ------------------------------------------------------------------------
        -- Decision stage 0: counts relative to the current phase
        ------------------------------------------------------------------------
        d0_go <= dec_go;
        if dec_go = '1' then
          r := to_integer(p);
          for i in 0 to 3 loop
            rel(i) <= lat((r + i) mod 4);
          end loop;
        end if;

        ------------------------------------------------------------------------
        -- Decision stage 1: weighted sums
        ------------------------------------------------------------------------
        d1_go <= d0_go;
        if d0_go = '1' then
          n0 := rel(0);
          n1 := rel(1);
          n2 := rel(2);
          n3 := rel(3);
          n0w := resize(n0, TOT_W);
          n1w := resize(n1, TOT_W);
          late_q  <= n0w + shift_left(n0w, 1) + resize(n3, TOT_W);
          early_q <= n1w + shift_left(n1w, 1) + resize(n2, TOT_W);
          tot_q   <= resize(n0, TOT_W) + resize(n1, TOT_W)
                     + resize(n2, TOT_W) + resize(n3, TOT_W);
          near_q  <= '0';
          if resize(n0, TOT_W) + resize(n1, TOT_W) > resize(n2, TOT_W) + resize(n3, TOT_W) then
            near_q <= '1';
          end if;
          n0ge_q  <= '0';
          if n0 >= n1 then
            n0ge_q <= '1';
          end if;
        end if;

        ------------------------------------------------------------------------
        -- Decision stage 2: compare and request a phase step
        ------------------------------------------------------------------------
        if d1_go = '1' then
          if tot_q >= MIN_EDGES then
            act_q <= '1';
            rhs5  := resize(tot_q, TOT_W + 3) + shift_left(resize(tot_q, TOT_W + 3), 2);
            if near_q = '1' then
              if n0ge_q = '1' then
                act <= A_UP;
              else
                act <= A_DN;
              end if;
            elsif late_q > early_q then
              lhs := shift_left(resize(late_q - early_q, TOT_W + 3), 2);
              if lhs > rhs5 then
                act <= A_UP;
              end if;
            elsif early_q > late_q then
              lhs := shift_left(resize(early_q - late_q, TOT_W + 3), 2);
              if lhs > rhs5 then
                act <= A_DN;
              end if;
            end if;
          else
            act_q <= '0';
          end if;
        end if;
      end if;
    end if;
  end process;

  bits     <= bits_q;
  nbits    <= nbits_q;
  phase    <= p;
  shift_up <= up_q;
  shift_dn <= dn_q;
  activity <= act_q;

end architecture rtl;
