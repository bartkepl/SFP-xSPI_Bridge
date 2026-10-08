--------------------------------------------------------------------------------
-- tb_clk_rst
--
-- Testbench for clk_rst with the Gowin rPLL and CLKDIV simulation models
-- (library gw1n). CLK_25M = 25 MHz.
--
-- Checks:
--   1. rst_sys = 1 and arst_n = 0 until the PLL locks; rst_sys released at
--      most STAGES + 3 clk_sys cycles after lock;
--   2. clk_fast period 5 ns, clk_sys period 20 ns (mean over 200 periods,
--      +/-1 ps); every clk_sys rising edge coincides with a clk_fast rising
--      edge (same simulation time);
--   3. HOST_RST_N low for 10 CLK_25M cycles (400 ns, below the 640 ns
--      filter = 32 clk_sys cycles): no reset;
--   4. HOST_RST_N low for 2 us: arst_n = 0 within 20 CLK_25M cycles of the
--      falling edge, rst_sys = 1 while active; after the rising edge arst_n
--      returns within 20 cycles and rst_sys is released after the filter
--      and STAGES clk_sys cycles;
--   5. soft reset: a clk_sys flip-flop (model of CTRL.SOFT_RST, cleared by
--      rst_sys) set for one write: rst_sys pulse of STAGES .. STAGES + 2
--      cycles, the bit cleared, arst_n high again.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.tb_pkg.all;
use work.bridge_pkg.all;

entity tb_clk_rst is
end entity tb_clk_rst;

architecture sim of tb_clk_rst is

  constant T_REF  : time := 40 ns;
  constant STAGES : positive := 3;

  signal clk_25m    : std_logic := '0';
  signal stop       : boolean := false;
  signal host_rst_n : std_logic := '1';
  signal soft_set   : std_logic := '0';     -- TB "CSR write" of SOFT_RST
  signal soft_q     : std_logic := '0';     -- CTRL.SOFT_RST flip-flop model
  signal n_hard_soft : natural := 0;        -- rst_hard cycles while soft_q was set
  signal clk_fast, clk_sys, rst_sys, rst_hard, arst_n, pll_lock : std_logic;

begin

  clk_gen(clk_25m, T_REF, stop);

  dut : entity work.clk_rst
    generic map (HOST_FILT => 32, STAGES => STAGES)
    port map (clk_25m => clk_25m, host_rst_n => host_rst_n, soft_rst => soft_q,
              clk_fast => clk_fast, clk_sys => clk_sys, rst_sys => rst_sys, rst_hard => rst_hard,
              arst_n => arst_n, pll_lock => pll_lock);

  -- CTRL.SOFT_RST model: set by a write, cleared by the domain reset
  process (clk_sys)
  begin
    if rising_edge(clk_sys) then
      if rst_hard = '1' and soft_q = '1' then
        n_hard_soft <= n_hard_soft + 1;
      end if;
      if rst_sys = '1' then
        soft_q <= '0';
      elsif soft_set = '1' then
        soft_q <= '1';
      end if;
    end if;
  end process;

  process
    variable t0, t1   : time;
    variable n        : natural;
    variable t_lock   : time;
    variable ok       : boolean;
    variable cyc      : natural;

    procedure ref_cycles(k : positive) is
    begin
      for i in 1 to k loop
        wait until rising_edge(clk_25m);
      end loop;
    end procedure;
  begin
    -- 1. before lock
    ref_cycles(20);
    check_equal(pll_lock, '0', "1: PLL not locked yet");
    check_equal(rst_sys, '1', "1: rst_sys before lock");
    check_equal(arst_n, '0', "1: arst_n before lock");
    wait until pll_lock = '1';
    t_lock := now;
    report "PLL locked at " & time'image(now);
    if rst_sys = '1' then
      wait until rst_sys = '0' for 1 us;
    end if;
    check_equal(rst_sys, '0', "1: rst_sys released after lock");
    check(now - t_lock <= (STAGES + 3) * 20 ns, "1: rst_sys release delay " &
          time'image(now - t_lock));
    check_equal(arst_n, '1', "1: arst_n after lock");

    -- 2. periods and alignment
    wait until rising_edge(clk_fast);
    t0 := now;
    for i in 1 to 200 loop
      wait until rising_edge(clk_fast);
    end loop;
    t1 := now;
    check(abs ((t1 - t0) / 200 - 5 ns) <= 1 ps, "2: clk_fast period " & time'image((t1 - t0) / 200));
    wait until rising_edge(clk_sys);
    t0 := now;
    ok := true;
    for i in 1 to 200 loop
      wait until rising_edge(clk_sys);
      -- a clk_fast rising edge at the same simulation time
      if clk_fast /= '1' or clk_fast'last_event > 0 ns then
        ok := false;
      end if;
    end loop;
    t1 := now;
    check(abs ((t1 - t0) / 200 - 20 ns) <= 1 ps, "2: clk_sys period " & time'image((t1 - t0) / 200));
    check(ok, "2: clk_sys rising edges coincide with clk_fast rising edges");

    -- 3. short HOST_RST_N pulse (filtered)
    wait until rising_edge(clk_25m);
    host_rst_n <= '0';
    ref_cycles(10);
    host_rst_n <= '1';
    ok := true;
    for i in 1 to 40 loop
      wait until rising_edge(clk_25m);
      if arst_n = '0' or rst_sys = '1' then ok := false; end if;
    end loop;
    check(ok, "3: 400 ns HOST_RST_N pulse filtered");

    -- 4. long HOST_RST_N pulse
    host_rst_n <= '0';
    n := 0;
    while arst_n = '1' and n < 40 loop
      wait until rising_edge(clk_25m);
      n := n + 1;
    end loop;
    check(arst_n = '0' and n <= 20, "4: arst_n after " & integer'image(n) & " reference cycles");
    wait for 1 ns;
    check_equal(rst_sys, '1', "4: rst_sys asserted");
    wait for 2 us - n * T_REF;
    check_equal(rst_sys, '1', "4: rst_sys held");
    host_rst_n <= '1';
    n := 0;
    while arst_n = '0' and n < 40 loop
      wait until rising_edge(clk_25m);
      n := n + 1;
    end loop;
    check(arst_n = '1' and n <= 20, "4: arst_n released after " & integer'image(n) & " reference cycles");
    cyc := 0;
    while rst_sys = '1' and cyc < 20 loop
      wait until rising_edge(clk_sys);
      cyc := cyc + 1;
    end loop;
    wait for 1 ns;
    check(rst_sys = '0' and cyc >= STAGES - 1 and cyc <= STAGES + 2,
          "4: rst_sys released after " & integer'image(cyc) & " clk_sys cycles");

    -- 5. soft reset
    check_equal(rst_hard, '0', "5: rst_hard released");
    for i in 1 to 10 loop
      wait until rising_edge(clk_sys);
    end loop;
    soft_set <= '1';
    wait until rising_edge(clk_sys);
    soft_set <= '0';
    cyc := 0;
    wait until rst_sys = '1' for 100 ns;
    check_equal(rst_sys, '1', "5: soft reset asserts rst_sys");
    while rst_sys = '1' and cyc < 20 loop
      wait until rising_edge(clk_sys);
      cyc := cyc + 1;
    end loop;
    wait for 1 ns;
    check(cyc >= STAGES and cyc <= STAGES + 2, "5: soft reset pulse " & integer'image(cyc) & " cycles");
    check_equal(soft_q, '0', "5: SOFT_RST bit cleared by the reset");
    check_equal(n_hard_soft, 0, "5: rst_hard not asserted by the soft reset");
    check_equal(arst_n, '1', "5: arst_n high after the soft reset");
    for i in 1 to 10 loop
      wait until rising_edge(clk_sys);
    end loop;
    check_equal(rst_sys, '0', "5: no further reset");

    stop <= true;
    tb_finish("tb_clk_rst");
    wait;
  end process;

end architecture sim;
