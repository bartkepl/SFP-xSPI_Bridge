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
