--------------------------------------------------------------------------------
-- tb_sync
--
-- Testbench for sync_bit and reset_sync.
--
-- Checks:
--   sync_bit (STAGES = 2 and 3)
--     1. q follows a change of d after exactly STAGES rising edges, counted
--        from the first edge that samples the new value.
--     2. d changing asynchronously (not aligned to clk) is handled the same.
--   reset_sync (STAGES = 3)
--     3. rst asserts immediately when arst_n goes low, without a clock edge
--        (clock stopped).
--     4. After arst_n is released, rst stays high for exactly STAGES rising
--        edges and changes only right after a rising edge.
--     5. A short arst_n pulse between edges re-asserts rst at once.
--
-- Waveform: clk, d, q2, q3 (sync_bit), arst_n, rst (reset_sync), clk_run.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

library work;
use work.tb_pkg.all;

entity tb_sync is
end entity tb_sync;

architecture sim of tb_sync is

  constant T_CLK : time := 10 ns;

  signal clk     : std_logic := '0';
  signal clk_run : boolean   := true;   -- gate for "clock stopped" test
  signal stop    : boolean   := false;

  signal d       : std_logic := '0';
  signal q2, q3  : std_logic;
  signal arst_n  : std_logic := '0';
  signal rst     : std_logic;

begin

  -- Gated clock: stops (low) while clk_run = false
  process
  begin
    while not stop loop
      if clk_run then
        clk <= '1'; wait for T_CLK / 2;
        clk <= '0'; wait for T_CLK / 2;
      else
        clk <= '0'; wait for T_CLK / 2;
      end if;
    end loop;
    wait;
  end process;

  dut_s2 : entity work.sync_bit
    generic map (STAGES => 2) port map (clk => clk, d => d, q => q2);

  dut_s3 : entity work.sync_bit
    generic map (STAGES => 3) port map (clk => clk, d => d, q => q3);

  dut_rs : entity work.reset_sync
    generic map (STAGES => 3) port map (clk => clk, arst_n => arst_n, rst => rst);

  process
    variable edges : natural;
  begin
    -- Let the chains settle
    arst_n <= '0';
    for i in 1 to 5 loop wait until rising_edge(clk); end loop;

    ---------------------------------------------------------------- 1, 2
    for trial in 0 to 3 loop
      -- change d at different offsets from the clock edge (asynchronous)
      wait until falling_edge(clk);
      wait for (trial * 1.7 ns);
      d <= not d;
      -- first edge after the change samples the new value
      edges := 0;
      loop
        wait until rising_edge(clk);
        edges := edges + 1;
        wait for 1 ns;
        exit when q2 = d;
        exit when edges > 10;
      end loop;
      check_equal(edges, 2, "sync_bit STAGES=2 latency, trial " & integer'image(trial));
      loop
        exit when q3 = d;
        wait until rising_edge(clk);
        edges := edges + 1;
        wait for 1 ns;
        exit when edges > 10;
      end loop;
      check_equal(edges, 3, "sync_bit STAGES=3 latency, trial " & integer'image(trial));
    end loop;

    ---------------------------------------------------------------- 4
    arst_n <= '0';
    wait until rising_edge(clk);
    check_equal(rst, '1', "reset_sync asserted while arst_n low");
    wait until falling_edge(clk);
    arst_n <= '1';
    edges := 0;
    loop
      wait until rising_edge(clk);
      edges := edges + 1;
      wait for 1 ns;
      exit when rst = '0' or edges > 10;
      -- rst must not change between edges
      wait for T_CLK / 2 - 2 ns;
      check_equal(rst, '1', "reset_sync stable between edges");
    end loop;
    check_equal(edges, 3, "reset_sync release after STAGES edges");

    ---------------------------------------------------------------- 3
    clk_run <= false;
    wait for 3 * T_CLK;
    arst_n <= '0';
    wait for 1 ns;
    check_equal(rst, '1', "reset_sync asserts without clock");
    wait for 2 * T_CLK;
    arst_n <= '1';
    wait for 2 * T_CLK;
    check_equal(rst, '1', "reset_sync held while clock stopped");
    clk_run <= true;
    for i in 1 to 4 loop wait until rising_edge(clk); end loop;
    wait for 1 ns;
    check_equal(rst, '0', "reset_sync released after clock restart");

    ---------------------------------------------------------------- 5
    wait until rising_edge(clk);
    wait for 2 ns;
    arst_n <= '0';
    wait for 1 ns;
    check_equal(rst, '1', "reset_sync short pulse asserts immediately");
    arst_n <= '1';
    for i in 1 to 4 loop wait until rising_edge(clk); end loop;
    wait for 1 ns;
    check_equal(rst, '0', "reset_sync released after short pulse");

    stop <= true;
    tb_finish("tb_sync");
    wait;
  end process;

end architecture sim;
