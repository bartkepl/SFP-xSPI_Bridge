--------------------------------------------------------------------------------
-- tb_pkg
--
-- Common testbench support: error counter, check procedures, end-of-test
-- summary. Simulation only (not synthesizable).
--
-- Every testbench ends with tb_finish(...), which prints exactly one line
--   "TB <name> PASS (<n> checks)"   or   "TB <name> FAIL (<e> of <n> checks)"
-- and stops the simulation; the run script evaluates this line.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library std;
use std.env.all;

package tb_pkg is

  type t_checker is protected
    procedure pass;
    procedure fail(msg : string);
    impure function errors return natural;
    impure function checks return natural;
  end protected t_checker;

  -- Generic checks; msg identifies the check in the log
  procedure check(cond : boolean; msg : string);
  procedure check_equal(got, exp : std_logic_vector; msg : string);
  procedure check_equal(got, exp : std_logic; msg : string);
  procedure check_equal(got, exp : integer; msg : string);

  -- Print the summary line and stop the simulation
  procedure tb_finish(name : string);

  -- Clock generator helper: period in time units, stops when stop = true
  procedure clk_gen(signal clk : out std_logic; constant period : time;
                    signal stop : in boolean);

  function hex(v : std_logic_vector) return string;

  -- boolean -> std_logic
  function to_sl(b : boolean) return std_logic;

  -- Serial line model (simulation of the optical link at bit level).
  -- The transmitter pushes bits with their nominal start time; the receiver
  -- samples the line at arbitrary times. Every bit boundary is moved by an
  -- independent random jitter, uniform in +/- jitter_ui * ui_ns.
  -- Requires jitter_ui < 0.5 (boundaries keep their order).
  type t_line is protected
    procedure configure(jitter_ui, ui_ns : real; seed : positive);
    procedure push(b : std_logic; t_ns : real);   -- t_ns non-decreasing
    impure function sample(t_ns : real) return std_logic;
    impure function pending return natural;       -- bits pushed, not yet passed
  end protected t_line;

end package tb_pkg;

package body tb_pkg is

  type t_checker is protected body
    variable n_err : natural := 0;
    variable n_chk : natural := 0;

    procedure pass is
    begin
      n_chk := n_chk + 1;
    end procedure;

    procedure fail(msg : string) is
    begin
      n_chk := n_chk + 1;
      n_err := n_err + 1;
      report "CHECK FAILED: " & msg severity error;
    end procedure;

    impure function errors return natural is
    begin
      return n_err;
    end function;

    impure function checks return natural is
    begin
      return n_chk;
    end function;
  end protected body t_checker;

  shared variable chk : t_checker;

  function hex(v : std_logic_vector) return string is
  begin
    return to_hstring(v);
  end function;

  function to_sl(b : boolean) return std_logic is
  begin
    if b then return '1'; else return '0'; end if;
  end function;

  procedure check(cond : boolean; msg : string) is
  begin
    if cond then
      chk.pass;
    else
      chk.fail(msg);
    end if;
  end procedure;

  procedure check_equal(got, exp : std_logic_vector; msg : string) is
  begin
    if got = exp then
      chk.pass;
    else
      chk.fail(msg & ": got 0x" & to_hstring(got) & ", expected 0x" & to_hstring(exp));
    end if;
  end procedure;

  procedure check_equal(got, exp : std_logic; msg : string) is
  begin
    if got = exp then
      chk.pass;
    else
      chk.fail(msg & ": got " & std_logic'image(got) & ", expected " & std_logic'image(exp));
    end if;
  end procedure;

  procedure check_equal(got, exp : integer; msg : string) is
  begin
    if got = exp then
      chk.pass;
    else
      chk.fail(msg & ": got " & integer'image(got) & ", expected " & integer'image(exp));
    end if;
  end procedure;

  procedure tb_finish(name : string) is
  begin
    if chk.errors = 0 then
      report "TB " & name & " PASS (" & integer'image(chk.checks) & " checks)" severity note;
    else
      report "TB " & name & " FAIL (" & integer'image(chk.errors) & " of "
             & integer'image(chk.checks) & " checks)" severity note;
    end if;
    finish;
  end procedure;

  type t_line is protected body
    constant QN : positive := 8192;
    type t_bitq is array (0 to QN - 1) of std_logic;
    type t_timq is array (0 to QN - 1) of real;
    variable q_bit  : t_bitq;
    variable q_time : t_timq;
    variable n_wr   : natural := 0;       -- bits pushed
    variable cur    : integer := -1;      -- index of the bit on the line
    variable nb     : real := 0.0;        -- jittered start of bit cur + 1
    variable nb_ok  : boolean := false;
    variable jit    : real := 0.0;        -- jitter amplitude in ns
    variable s1, s2 : positive := 1;

    procedure configure(jitter_ui, ui_ns : real; seed : positive) is
    begin
      jit   := jitter_ui * ui_ns;
      s1    := seed;
      s2    := seed + 7919;
      n_wr  := 0;
      cur   := -1;
      nb_ok := false;
    end procedure;

    procedure push(b : std_logic; t_ns : real) is
    begin
      assert n_wr - cur < QN - 1 report "t_line: queue overflow" severity failure;
      q_bit(n_wr mod QN)  := b;
      q_time(n_wr mod QN) := t_ns;
      n_wr := n_wr + 1;
    end procedure;

    impure function sample(t_ns : real) return std_logic is
      variable u : real;
    begin
      loop
        if not nb_ok and cur + 1 < n_wr then
          uniform(s1, s2, u);
          nb    := q_time((cur + 1) mod QN) + jit * (2.0 * u - 1.0);
          nb_ok := true;
        end if;
        exit when not nb_ok or t_ns < nb;
        cur   := cur + 1;
        nb_ok := false;
      end loop;
      if cur < 0 then
        return '0';
      end if;
      return q_bit(cur mod QN);
    end function;

    impure function pending return natural is
    begin
      return n_wr - (cur + 1);
    end function;
  end protected body t_line;

  procedure clk_gen(signal clk : out std_logic; constant period : time;
                    signal stop : in boolean) is
  begin
    clk <= '0';
    while not stop loop
      wait for period / 2;
      clk <= '1';
      wait for period / 2;
      clk <= '0';
    end loop;
    wait;
  end procedure;

end package body tb_pkg;
