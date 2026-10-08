--------------------------------------------------------------------------------
-- tb_comma_align
--
-- Testbench for comma_align together with dec_8b10b (decoder feedback).
--
-- Stimulus: a bit stream prepared in advance (random 8b/10b characters with
-- 10% K28.5 at random positions), fed with a random number of bits per
-- clock (1: 10%, 2: 80%, 3: 10%), as cdr_os4x8 delivers them. Events are
-- inserted at the start of segments 1..4 (in the middle of a character):
--   seg 0  237 random bits (not 8b/10b), 12 x (K28.5, 0000000000) (commas
--          at a consistent 10-bit position but invalid symbols between them:
--          no sync may be acquired), then the character stream
--   seg 1  bit slip: one bit dropped           -> sync lost, re-acquired
--   seg 2  bit slip: one bit duplicated        -> sync lost, re-acquired
--   seg 3  one bit inverted                    -> sync kept
--   seg 4  restart pulse                       -> sync lost, re-acquired
--   seg 5  6 inverted bits, 40 characters apart -> sync kept (the error
--          count decreases after GOOD_RUN correct symbols)
--
-- An "epoch" is a continuous period of sync = '1'. Characters decoded after
-- a bit slip but before the loss of sync are excluded (they are expected to
-- be wrong; rx_deframer drops such frames on the decoder errors).
--
-- Checks:
--   1. exactly 4 epochs (none on the false commas); each acquisition within MAX_ACQ characters from the
--      start of the stream or from the event;
--   2. ev_sync_loss count = 3 (segments 1, 2, 4 only: K28.5 at arbitrary
--      data positions and a single bit error do not drop sync);
--   3. in each epoch (from the 4th character on) the decoded characters
--      equal a consecutive part of the transmitted stream, without missing
--      or extra characters; at most 2 wrong characters in the epoch with
--      the inverted bit (2 per bit in the epoch with segment 5), none
--      elsewhere; at least 2000 characters compared
--      per epoch;
--   4. sym_comma = '1' exactly for the symbols decoded as K28.5 (symbols
--      with a decoder error excluded).
--
-- Waveform: input bits, alignment register and bit count, symbol output,
-- decoder output, sync and events; see doc/vhdl/comma_align.md.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library work;
use work.tb_pkg.all;
use work.bridge_pkg.all;
use work.code8b10b_pkg.all;

entity tb_comma_align is
end entity tb_comma_align;

architecture sim of tb_comma_align is

  constant T_CLK    : time := 20 ns;
  constant N_SEG    : natural := 6;
  constant SEG_CH   : natural := 3000;         -- characters per segment
  constant GARBAGE  : natural := 237;          -- random bits before the stream
  constant N_FALSE  : natural := 12;           -- false comma pairs after them
  constant MAX_ACQ  : natural := 200;          -- characters from event to sync
  constant MAX_CH   : natural := N_SEG * SEG_CH;
  constant MAX_BITS : natural := MAX_CH * 10 + GARBAGE + N_FALSE * 20 + 16;
  constant MAX_EP   : natural := 8;

  type t_ev is (EV_NONE, EV_DROP, EV_DUP, EV_FLIP, EV_RESTART, EV_FLIPS);
  type t_ev_arr is array (0 to N_SEG - 1) of t_ev;
  constant SEG_EV : t_ev_arr := (EV_NONE, EV_DROP, EV_DUP, EV_FLIP, EV_RESTART, EV_FLIPS);
  constant N_FLIPS  : natural := 6;            -- inverted bits in segment 5
  constant FLIP_GAP : natural := 40;           -- characters between them

  signal clk       : std_logic := '0';
  signal rst       : std_logic := '1';
  signal stop      : boolean := false;
  signal restart   : std_logic := '0';
  signal in_bits   : std_logic_vector(2 downto 0) := (others => '0');
  signal in_n      : unsigned(1 downto 0) := (others => '0');
  signal sym       : std_logic_vector(9 downto 0);
  signal sym_valid : std_logic;
  signal sym_comma : std_logic;
  signal sync      : std_logic;
  signal ev_realign, ev_sync_loss : std_logic;

  signal dec_data  : std_logic_vector(7 downto 0);
  signal dec_k     : std_logic;
  signal dec_valid : std_logic;
  signal dec_cerr, dec_derr, dec_err : std_logic;
  signal comma_d1, comma_d2 : std_logic := '0';   -- sym_comma aligned with the decoder output

  -- for the waveform
  signal seg       : natural := 0;
  signal epoch     : natural := 0;

begin

  clk_gen(clk, T_CLK, stop);

  dut : entity work.comma_align
    port map (clk => clk, rst => rst, restart => restart,
              in_bits => in_bits, in_n => in_n,
              sym => sym, sym_valid => sym_valid, sym_comma => sym_comma,
              dec_valid => dec_valid, dec_err => dec_err,
              sync => sync, ev_realign => ev_realign, ev_sync_loss => ev_sync_loss);

  u_dec : entity work.dec_8b10b
    port map (clk => clk, rst => rst, en => sym_valid, code => sym,
              data => dec_data, k => dec_k, valid => dec_valid,
              code_err => dec_cerr, disp_err => dec_derr, rd => open);

  dec_err <= dec_cerr or dec_derr;

  process (clk)
  begin
    if rising_edge(clk) then
      comma_d1 <= sym_comma;
      comma_d2 <= comma_d1;
    end if;
  end process;

  process
    type t_byte_arr is array (natural range <>) of std_logic_vector(7 downto 0);
    type t_sl_arr   is array (natural range <>) of std_logic;
    type t_nat_arr  is array (natural range <>) of natural;

    -- transmitted characters and line bits
    variable tx_d    : t_byte_arr(0 to MAX_CH - 1);
    variable tx_k    : t_sl_arr(0 to MAX_CH - 1);
    variable ln      : t_sl_arr(0 to MAX_BITS - 1);
    variable n_ln    : natural := 0;
    variable seg_pos : t_nat_arr(0 to N_SEG - 1);      -- line index of each segment start
    -- received characters (in sync, not tainted)
    variable rx_d    : t_byte_arr(0 to MAX_CH - 1);
    variable rx_k    : t_sl_arr(0 to MAX_CH - 1);
    variable rx_ep   : t_nat_arr(0 to MAX_CH - 1);
    variable n_rx    : natural := 0;
    variable ep_flip : t_sl_arr(0 to MAX_EP);           -- epoch contains the inverted bit
    variable n_flip_ep : t_nat_arr(0 to MAX_EP);        -- further inverted bits in the epoch

    variable s1, s2  : positive := 1;
    variable u       : real;
    variable rd      : std_logic := '0';
    variable enc     : t_enc_result;
    variable b       : std_logic_vector(7 downto 0);
    variable kk      : std_logic;
    variable bp      : natural;
    variable k       : natural;
    variable v       : std_logic_vector(2 downto 0);
    variable cur_seg : natural;
    variable ep      : natural := 0;
    variable taint   : boolean := false;
    variable sync_d  : std_logic := '0';
    variable ch_cnt  : natural := 0;       -- symbols since the last event
    variable n_loss  : natural := 0;
    variable comma_bad : natural := 0;
    variable first, j0, n_cmp, n_bad, n_match : integer;
    variable ok      : boolean;

  begin
    ----------------------------------------------------------------------------
    -- Build the line bit stream
    ----------------------------------------------------------------------------
    s1 := 7; s2 := 11;
    for i in 0 to GARBAGE - 1 loop
      uniform(s1, s2, u);
      if u < 0.5 then ln(n_ln) := '0'; else ln(n_ln) := '1'; end if;
      n_ln := n_ln + 1;
    end loop;
    -- false commas: K28.5 followed by an invalid symbol, comma every 20 bits;
    -- the decoder errors must prevent sync on this pattern
    enc := encode_8b10b(K28_5, '1', '0');
    for r in 1 to N_FALSE loop
      for i in 0 to 9 loop
        ln(n_ln) := enc.code(i);
        n_ln := n_ln + 1;
      end loop;
      for i in 0 to 9 loop
        ln(n_ln) := '0';
        n_ln := n_ln + 1;
      end loop;
    end loop;
    for sg in 0 to N_SEG - 1 loop
      for c in 0 to SEG_CH - 1 loop
        uniform(s1, s2, u);
        if u < 0.1 then
          b := K28_5; kk := '1';
        else
          uniform(s1, s2, u);
          b := std_logic_vector(to_unsigned(integer(floor(u * 256.0)) mod 256, 8)); kk := '0';
        end if;
        tx_d(sg * SEG_CH + c) := b;
        tx_k(sg * SEG_CH + c) := kk;
        enc := encode_8b10b(b, kk, rd);
        rd  := enc.rd_out;
        for i in 0 to 9 loop
          -- event in the middle of the first character of the segment
          if SEG_EV(sg) = EV_FLIPS and c > 0 and c mod FLIP_GAP = 0
             and c / FLIP_GAP < N_FLIPS and i = 5 then
            ln(n_ln) := not enc.code(i);
            n_ln := n_ln + 1;
          elsif c = 0 and i = 5 then
            seg_pos(sg) := n_ln;
            case SEG_EV(sg) is
              when EV_DROP => null;                                   -- bit not sent
              when EV_DUP  => ln(n_ln) := enc.code(i); n_ln := n_ln + 1;
                              ln(n_ln) := enc.code(i); n_ln := n_ln + 1;
              when EV_FLIP | EV_FLIPS =>
                              ln(n_ln) := not enc.code(i); n_ln := n_ln + 1;
              when others  => ln(n_ln) := enc.code(i); n_ln := n_ln + 1;
            end case;
          else
            ln(n_ln) := enc.code(i);
            n_ln := n_ln + 1;
          end if;
        end loop;
      end loop;
    end loop;
    seg_pos(0) := 0;
    for e in 0 to MAX_EP loop
      ep_flip(e) := '0';
      n_flip_ep(e) := 0;
    end loop;

    ----------------------------------------------------------------------------
    -- Feed the bits
    ----------------------------------------------------------------------------
    rst <= '1';
    for i in 1 to 4 loop
      wait until rising_edge(clk);
    end loop;
    rst <= '0';

    bp := 0;
    cur_seg := 0;
    s1 := 23; s2 := 29;
    while bp + 3 <= n_ln loop
      uniform(s1, s2, u);
      if u < 0.1 then k := 1; elsif u < 0.9 then k := 2; else k := 3; end if;
      v := (others => '0');
      for i in 0 to k - 1 loop
        v(i) := ln(bp + i);
      end loop;
      -- segment boundary inside these bits: the event takes effect now
      restart <= '0';
      if cur_seg + 1 < N_SEG and bp + k > seg_pos(cur_seg + 1) then
        cur_seg := cur_seg + 1;
        seg     <= cur_seg;
        ch_cnt  := 0;
        case SEG_EV(cur_seg) is
          when EV_DROP | EV_DUP => taint := true;
          when EV_FLIP          => ep_flip(ep) := '1';
          when EV_FLIPS         => n_flip_ep(ep) := N_FLIPS;
          when EV_RESTART       => restart <= '1';
          when others           => null;
        end case;
      end if;
      in_bits <= v;
      in_n    <= to_unsigned(k, 2);
      bp := bp + k;
      wait until rising_edge(clk);

      -- monitor (outputs of earlier clocks)
      if sym_valid = '1' then
        ch_cnt := ch_cnt + 1;
      end if;
      if ev_sync_loss = '1' then
        n_loss := n_loss + 1;
      end if;
      if sync = '1' and sync_d = '0' then
        ep    := ep + 1;
        epoch <= ep;
        taint := false;
        check(ch_cnt <= MAX_ACQ, "acquisition " & integer'image(ep) & " took " &
              integer'image(ch_cnt) & " characters");
      end if;
      sync_d := sync;
      if dec_valid = '1' and sync = '1' and not taint then
        rx_d(n_rx)  := dec_data;
        rx_k(n_rx)  := dec_k;
        rx_ep(n_rx) := ep;
        n_rx := n_rx + 1;
        if dec_err = '0' and (comma_d2 = '1') /= (dec_k = '1' and dec_data = K28_5) then
          comma_bad := comma_bad + 1;
        end if;
      end if;
    end loop;
    in_n <= (others => '0');
    for i in 1 to 4 loop
      wait until rising_edge(clk);
    end loop;

    ----------------------------------------------------------------------------
    -- Evaluation
    ----------------------------------------------------------------------------
    check_equal(ep, 4, "number of sync epochs");
    check_equal(n_loss, 3, "ev_sync_loss count");
    check_equal(comma_bad, 0, "sym_comma mismatches");

    for e in 1 to ep loop
      -- first character of the epoch, plus 4
      first := -1;
      for i in 0 to n_rx - 1 loop
        if rx_ep(i) = e then
          first := i + 4;
          exit;
        end if;
      end loop;
      -- locate in the transmitted stream by a 24-character window
      n_match := 0; j0 := 0;
      if first >= 0 and first + 24 <= n_rx then
        for j in 0 to MAX_CH - 24 loop
          ok := true;
          for m in 0 to 23 loop
            if rx_d(first + m) /= tx_d(j + m) or rx_k(first + m) /= tx_k(j + m) then
              ok := false;
              exit;
            end if;
          end loop;
          if ok then
            n_match := n_match + 1;
            j0 := j;
          end if;
        end loop;
      end if;
      check_equal(n_match, 1, "epoch " & integer'image(e) & ": unique position in the stream");
      -- compare the rest of the epoch
      n_cmp := 0; n_bad := 0;
      if n_match = 1 then
        for i in first to n_rx - 1 loop
          exit when rx_ep(i) /= e;
          exit when j0 + (i - first) >= MAX_CH;
          if rx_d(i) /= tx_d(j0 + i - first) or rx_k(i) /= tx_k(j0 + i - first) then
            n_bad := n_bad + 1;
          end if;
          n_cmp := n_cmp + 1;
        end loop;
      end if;
      if ep_flip(e) = '1' or n_flip_ep(e) > 0 then
        check(n_bad <= 2 * (n_flip_ep(e) + 1), "epoch " & integer'image(e) &
              ": wrong characters with inverted bits: " & integer'image(n_bad));
      else
        check_equal(n_bad, 0, "epoch " & integer'image(e) & ": wrong characters");
      end if;
      check(n_cmp >= 2000, "epoch " & integer'image(e) & ": characters compared: " &
            integer'image(n_cmp));
      report "epoch " & integer'image(e) & ": stream position " & integer'image(j0) &
             ", compared " & integer'image(n_cmp) & ", wrong " & integer'image(n_bad);
    end loop;

    stop <= true;
    tb_finish("tb_comma_align");
    wait;
  end process;

end architecture sim;
