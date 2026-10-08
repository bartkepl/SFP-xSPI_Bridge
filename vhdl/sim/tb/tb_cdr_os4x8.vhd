--------------------------------------------------------------------------------
-- tb_cdr_os4x8
--
-- Testbench for cdr_os4x8. A serial 8b/10b stream is generated with a line
-- model (t_line, tb_pkg): bit period UI = 10 ns / (1 + ppm * 1e-6) (positive
-- ppm = transmitter faster than the receiver), random jitter on every bit
-- boundary, random initial phase. The receiver samples the line every
-- 2.5 ns (IDES8 at FCLK = 200 MHz DDR) and presents 8 samples per 20 ns
-- clock (clk_sys = 50 MHz, ADR 0007).
--
-- Scenarios (each after a reset; N_CLK clocks, checks after LOCK_CLKS):
--   1  0 ppm,      no jitter        5  +1000 ppm, jitter +/-0.10 UI
--   2  0 ppm,      jitter +/-0.20   6  -1000 ppm, jitter +/-0.10 UI
--   3  +100 ppm,   jitter +/-0.20   7  +200 ppm,  jitter +/-0.25 UI
--   4  -100 ppm,   jitter +/-0.20   8  idle stream only (K28.5 D16.2),
--                                      -100 ppm, jitter +/-0.20 UI
--   9, 10  0 ppm, jitter 0 / +/-0.20 UI, bit boundaries exactly at the
--          initial sampling instants (worst start phase)
--   11 +100 ppm, jitter +/-0.30 UI (margin above the +/-0.20 UI requirement)
--
-- Checks per scenario:
--   a. the recovered bit stream matches the transmitted one at a unique
--      offset (64-bit window searched within +/-9 bits;
--      the idle stream repeats every 20 bits);
--   b. no bit error from LOCK_CLKS to the end;
--   c. (3-bit clocks - 1-bit clocks) equals (recovered bits - 2 * clocks);
--   d. net phase steps after lock follow the frequency offset:
--      (shift_dn - shift_up) = 8 * clocks * ppm * 1e-6 within +/-2 steps;
--   e. without frequency offset at most 2 phase steps after lock (jitter
--      does not toggle the phase).
--
-- Waveform: samples, recovered bits / nbits, phase, shift pulses, scenario
-- number and error counter; see doc/vhdl/cdr.md.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library work;
use work.tb_pkg.all;
use work.bridge_pkg.all;
use work.code8b10b_pkg.all;

entity tb_cdr_os4x8 is
end entity tb_cdr_os4x8;

architecture sim of tb_cdr_os4x8 is

  constant T_CLK     : time := 20 ns;
  constant T_CLK_NS  : real := 20.0;
  constant T_SMP_NS  : real := 2.5;
  constant N_CLK     : natural := 25000;
  constant LOCK_CLKS : natural := 400;
  constant MAXB      : natural := 2 * N_CLK + 4096;

  type t_scen is record
    ppm    : real;
    jitter : real;
    idle   : boolean;
    phase0 : real;          -- initial line phase in ns; < 0.0: random
  end record;
  type t_scen_arr is array (1 to 11) of t_scen;
  constant SCEN : t_scen_arr := (
    (    0.0, 0.00, false, -1.0),
    (    0.0, 0.20, false, -1.0),
    (  100.0, 0.20, false, -1.0),
    ( -100.0, 0.20, false, -1.0),
    ( 1000.0, 0.10, false, -1.0),
    (-1000.0, 0.10, false, -1.0),
    (  200.0, 0.25, false, -1.0),
    ( -100.0, 0.20, true,  -1.0),
    (    0.0, 0.00, false,  0.0),   -- boundaries exactly at the initial sampling instants
    (    0.0, 0.20, false,  0.0),
    (  100.0, 0.30, false, -1.0));  -- jitter margin

  signal clk      : std_logic := '0';
  signal rst      : std_logic := '1';
  signal stop     : boolean := false;
  signal samples  : std_logic_vector(7 downto 0) := (others => '0');
  signal bits     : std_logic_vector(2 downto 0);
  signal nbits    : unsigned(1 downto 0);
  signal phase    : unsigned(1 downto 0);
  signal shift_up : std_logic;
  signal shift_dn : std_logic;
  signal activity : std_logic;

  -- for the waveform
  signal scen_no  : natural := 0;
  signal bit_errs : natural := 0;

  shared variable line : t_line;

begin

  clk_gen(clk, T_CLK, stop);

  dut : entity work.cdr_os4x8
    port map (clk => clk, rst => rst, samples => samples,
              bits => bits, nbits => nbits, phase => phase,
              shift_up => shift_up, shift_dn => shift_dn, activity => activity);

  process
    type t_bits is array (natural range <>) of std_logic;
    variable tx    : t_bits(0 to MAXB - 1);
    variable rx    : t_bits(0 to MAXB - 1);
    variable n_tx, n_rx : natural;
    variable ui, t0, t : real;
    variable s1, s2 : positive;
    variable u     : real;
    variable rd    : std_logic;
    variable enc   : t_enc_result;
    variable byte  : t_byte;
    variable kk    : std_logic;
    variable smp   : std_logic_vector(7 downto 0);
    variable ch    : natural;
    variable nb    : natural;
    variable n1b, n3b : natural;            -- clocks with 1 / 3 bits (after lock)
    variable n_up, n_dn : natural;          -- phase steps after lock
    variable rx_lock : natural;             -- rx index at LOCK_CLKS
    variable off, n_match : integer;
    variable ok    : boolean;
    variable errs  : natural;
    variable exp_steps : real;

    -- append the next character of the stream to tx and to the line
    procedure push_char is
    begin
      if SCEN(scen_no).idle then
        if ch mod 2 = 0 then byte := K28_5; kk := '1'; else byte := D16_2; kk := '0'; end if;
      else
        uniform(s1, s2, u);
        if u < 0.1 then
          byte := K28_5; kk := '1';
        else
          uniform(s1, s2, u);
          byte := std_logic_vector(to_unsigned(integer(floor(u * 256.0)) mod 256, 8));
          kk := '0';
        end if;
      end if;
      enc := encode_8b10b(byte, kk, rd);
      rd  := enc.rd_out;
      for i in 0 to 9 loop
        tx(n_tx) := enc.code(i);
        line.push(enc.code(i), t0 + real(n_tx) * ui);
        n_tx := n_tx + 1;
      end loop;
      ch := ch + 1;
    end procedure;

  begin
    for sc in SCEN'range loop
      scen_no <= sc;
      ui := 10.0 / (1.0 + SCEN(sc).ppm * 1.0e-6);
      s1 := 17 + sc; s2 := 991 * sc;
      uniform(s1, s2, u);
      if SCEN(sc).phase0 < 0.0 then
        t0 := u * 10.0;                     -- random initial phase
      else
        t0 := SCEN(sc).phase0;
      end if;
      line.configure(SCEN(sc).jitter, ui, 101 + sc);
      n_tx := 0; n_rx := 0; ch := 0; rd := '0';
      n1b := 0; n3b := 0; n_up := 0; n_dn := 0; rx_lock := 0;

      rst <= '1';
      for i in 1 to 4 loop
        wait until rising_edge(clk);
      end loop;
      rst <= '0';

      for c in 0 to N_CLK - 1 loop
        -- samples of clock c at t = c * 20 + i * 2.5 ns
        while line.pending < 40 loop
          push_char;
        end loop;
        for i in 0 to 7 loop
          t := real(c) * T_CLK_NS + real(i) * T_SMP_NS;
          smp(i) := line.sample(t);
        end loop;
        samples <= smp;
        wait until rising_edge(clk);
        -- collect the recovered bits (outputs of earlier clocks)
        nb := to_integer(nbits);
        for i in 0 to nb - 1 loop
          rx(n_rx) := bits(i);
          n_rx := n_rx + 1;
        end loop;
        if c = LOCK_CLKS then
          rx_lock := n_rx;
        end if;
        if c > LOCK_CLKS then
          if nb = 1 then n1b := n1b + 1; end if;
          if nb = 3 then n3b := n3b + 1; end if;
          if shift_up = '1' then n_up := n_up + 1; end if;
          if shift_dn = '1' then n_dn := n_dn + 1; end if;
        end if;
      end loop;

      -- a. alignment: rx(k) = tx(k + off)
      n_match := 0; off := 0;
      for o in -9 to 9 loop
        if rx_lock + o >= 0 then
          ok := true;
          for k in 0 to 63 loop
            if rx(rx_lock + k) /= tx(rx_lock + k + o) then
              ok := false;
              exit;
            end if;
          end loop;
          if ok then
            n_match := n_match + 1;
            off := o;
          end if;
        end if;
      end loop;
      check_equal(n_match, 1, "scenario " & integer'image(sc) & ": unique alignment");

      -- b. bit errors after lock
      errs := 0;
      if n_match = 1 then
        for k in rx_lock to n_rx - 1 loop
          if k + off < n_tx and rx(k) /= tx(k + off) then
            errs := errs + 1;
          end if;
        end loop;
      end if;
      bit_errs <= errs;
      check_equal(errs, 0, "scenario " & integer'image(sc) & ": bit errors after lock");

      -- c. bit count consistency
      check_equal((n_rx - rx_lock) - 2 * (N_CLK - 1 - LOCK_CLKS), n3b - n1b,
                  "scenario " & integer'image(sc) & ": 3-bit minus 1-bit clocks");

      -- d. / e. phase steps
      exp_steps := 8.0 * real(N_CLK - 1 - LOCK_CLKS) * SCEN(sc).ppm * 1.0e-6;
      check(abs (real(n_dn) - real(n_up) - exp_steps) <= 2.0,
            "scenario " & integer'image(sc) & ": net phase steps " &
            integer'image(n_dn - n_up) & ", expected " & real'image(exp_steps));
      if SCEN(sc).ppm = 0.0 then
        check(n_up + n_dn <= 2, "scenario " & integer'image(sc) & ": phase steps without offset: " &
              integer'image(n_up + n_dn));
      end if;
      report "scenario " & integer'image(sc) & ": rx bits " & integer'image(n_rx) &
             ", offset " & integer'image(off) & ", steps up/dn " &
             integer'image(n_up) & "/" & integer'image(n_dn) &
             ", 1b/3b " & integer'image(n1b) & "/" & integer'image(n3b);
    end loop;

    stop <= true;
    tb_finish("tb_cdr_os4x8");
    wait;
  end process;

end architecture sim;
