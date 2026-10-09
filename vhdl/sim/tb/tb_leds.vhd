--------------------------------------------------------------------------------
-- tb_leds
--
-- Testbench for leds (ACT_CLKS = 10, BLINK_CLKS = 20, clk 50 MHz).
--
-- Checks:
--   1. Reset and link DOWN: both LEDs off ('1').
--   2. Link UP: LED_LINK on ('0') steadily.
--   3. Link SYNC: LED_LINK blinks, BLINK_CLKS on / BLINK_CLKS off.
--   4. Activity pulse: LED_ACT on for ACT_CLKS cycles, then off for at
--      least ACT_CLKS cycles even with further activity (flash, not a
--      steady light); continuous activity gives a 2 x ACT_CLKS period.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.tb_pkg.all;
use work.bridge_pkg.all;

entity tb_leds is
end entity tb_leds;

architecture sim of tb_leds is

  constant T_CLK : time := 20 ns;
  constant N_ACT   : positive := 10;
  constant N_BLINK : positive := 20;

  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal stop : boolean := false;
  signal ls   : t_link_state := LS_DOWN;
  signal act  : std_logic := '0';
  signal led_link, led_act : std_logic;

begin

  clk_gen(clk, T_CLK, stop);

  dut : entity work.leds
    generic map (ACT_CLKS => N_ACT, BLINK_CLKS => N_BLINK)
    port map (clk => clk, rst => rst, link_state => ls, activity => act,
              led_link_n => led_link, led_act_n => led_act);

  process
    variable n_on, n_edges : natural;
    variable t_a, t_b : time;
  begin
    -- 1
    for i in 1 to 5 loop wait until rising_edge(clk); end loop;
    wait for 1 ns;
    check(led_link = '1' and led_act = '1', "1: LEDs off in reset");
    rst <= '0';
    for i in 1 to 50 loop wait until rising_edge(clk); end loop;
    wait for 1 ns;
    check(led_link = '1' and led_act = '1', "1: LEDs off with link DOWN");

    -- 2
    ls <= LS_UP;
    n_on := 0;
    for i in 1 to 100 loop
      wait until rising_edge(clk);
      wait for 1 ns;
      if led_link = '0' then n_on := n_on + 1; end if;
    end loop;
    check(n_on >= 99, "2: LED_LINK on with link UP (" & integer'image(n_on) & ")");

    -- 3
    ls <= LS_SYNC;
    wait until falling_edge(led_link) for 2 us;
    t_a := now;
    wait until rising_edge(led_link) for 2 us;
    t_b := now;
    check_equal((t_b - t_a) / T_CLK, N_BLINK, "3: blink on time in clk cycles");
    wait until falling_edge(led_link) for 2 us;
    check_equal((now - t_b) / T_CLK, N_BLINK, "3: blink off time in clk cycles");
    ls <= LS_DOWN;
    for i in 1 to 3 loop wait until rising_edge(clk); end loop;
    wait for 1 ns;
    check_equal(led_link, '1', "3: LED_LINK off with link DOWN again");

    -- 4
    wait until rising_edge(clk);
    act <= '1';
    wait until rising_edge(clk);
    act <= '0';
    wait until falling_edge(led_act) for 1 us;
    t_a := now;
    -- further activity during the whole flash and afterwards
    act <= '1';
    wait until rising_edge(led_act) for 1 us;
    check_equal((now - t_a) / T_CLK, N_ACT, "4: flash on time with activity during the flash");
    t_b := now;
    wait until falling_edge(led_act) for 2 us;
    check((now - t_b) / T_CLK >= N_ACT, "4: off time before the next flash");
    n_edges := 0;
    t_a := now;
    for i in 1 to 3 loop
      wait until falling_edge(led_act) for 2 us;
      n_edges := n_edges + 1;
    end loop;
    check_equal((now - t_a) / T_CLK, 3 * 2 * (N_ACT + 1) - 3, "4: flash period with continuous activity");
    act <= '0';

    stop <= true;
    tb_finish("tb_leds");
    wait;
  end process;

end architecture sim;
