--------------------------------------------------------------------------------
-- leds
--
-- Status LEDs (active low: 3V3 -> 1k -> LED -> pin, drive '0' to light):
--   LED_LINK : link state UP -> on; SYNC (local receiver synchronized,
--              remote not ready) -> blinking, BLINK_CLKS on / BLINK_CLKS
--              off; DOWN -> off.
--   LED_ACT  : a frame sent or received (activity pulse) starts a flash of
--              ACT_CLKS on followed by ACT_CLKS off; activity during the
--              flash is absorbed, so continuous traffic gives a steady
--              blinking instead of a constantly lit LED.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.bridge_pkg.all;

entity leds is
  generic (
    ACT_CLKS   : positive := CLK_SYS_HZ / 33;     -- 30 ms
    BLINK_CLKS : positive := CLK_SYS_HZ / 4       -- 250 ms (2 Hz blinking)
  );
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;
    link_state : in  t_link_state;
    activity   : in  std_logic;                   -- pulse
    led_link_n : out std_logic;
    led_act_n  : out std_logic
  );
end entity leds;

architecture rtl of leds is

  signal blink_c : natural range 0 to BLINK_CLKS - 1 := 0;
  signal blink   : std_logic := '0';
  signal act_c   : natural range 0 to 2 * ACT_CLKS := 0;   -- 0 = idle
  signal link_q, act_q : std_logic := '1';

begin

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        blink_c <= 0;
        blink   <= '0';
        act_c   <= 0;
        link_q  <= '1';
        act_q   <= '1';
      else
        if blink_c = BLINK_CLKS - 1 then
          blink_c <= 0;
          blink   <= not blink;
        else
          blink_c <= blink_c + 1;
        end if;

        if act_c /= 0 then
          act_c <= act_c - 1;
        elsif activity = '1' then
          act_c <= 2 * ACT_CLKS;
        end if;

        if link_state = LS_UP then
          link_q <= '0';
        elsif link_state = LS_SYNC then
          link_q <= not blink;
        else
          link_q <= '1';
        end if;
        act_q <= '0' when act_c > ACT_CLKS else '1';
      end if;
    end if;
  end process;

  led_link_n <= link_q;
  led_act_n  <= act_q;

end architecture rtl;
