--------------------------------------------------------------------------------
-- uart_rx
--
-- UART receiver, 8N1, LSB first (ADR 0006).
--
-- Bit period: div clock cycles (UART_DIV; 434 = 115200 baud at 50 MHz),
-- div >= UART_DIV_MIN (8).
--
-- Reception:
--   * rx is synchronized (2 flip-flops, idle level '1').
--   * IDLE: a falling edge (rx = '0') starts a character.
--   * START: after div/2 cycles (middle of the start bit) rx must still be
--     '0', otherwise the edge was a glitch (false start) and the receiver
--     returns to IDLE.
--   * DATA: 8 bits sampled every div cycles (middle of each bit), LSB first.
--   * STOP: sampled after div cycles: '1' -> valid pulse with data;
--     '0' -> frame_err pulse, no data; the receiver then waits until rx is
--     '1' again (a line held low, break, does not produce characters).
--   One sample per bit; tolerance to the baud rate difference about +/-4 %
--   (the stop bit sampled at 9.5 bit periods must stay inside the bit).
--
-- busy = '1' while a character is being received (used for idle-gap timing).
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_rx is
  port (
    clk       : in  std_logic;
    rst       : in  std_logic;
    div       : in  unsigned(15 downto 0);       -- clock cycles per bit
    rx        : in  std_logic;                   -- asynchronous input
    data      : out std_logic_vector(7 downto 0);
    valid     : out std_logic;                   -- pulse: data received
    frame_err : out std_logic;                   -- pulse: stop bit = '0'
    busy      : out std_logic
  );
end entity uart_rx;

architecture rtl of uart_rx is

  type t_state is (S_IDLE, S_START, S_DATA, S_STOP, S_WAIT_HIGH);

  signal rx_s    : std_logic;
  signal state   : t_state := S_IDLE;
  signal cnt     : unsigned(15 downto 0) := (others => '0');
  signal nbit    : natural range 0 to 7 := 0;
  signal sh      : std_logic_vector(7 downto 0) := (others => '0');
  signal valid_q : std_logic := '0';
  signal ferr_q  : std_logic := '0';

begin

  u_sync : entity work.sync_bit
    generic map (STAGES => 2, INIT_VAL => '1')
    port map (clk => clk, d => rx, q => rx_s);

  process (clk)
  begin
    if rising_edge(clk) then
      valid_q <= '0';
      ferr_q  <= '0';

      if rst = '1' then
        state <= S_IDLE;
        cnt   <= (others => '0');
        nbit  <= 0;
      else
        case state is
          when S_IDLE =>
            if rx_s = '0' then
              state <= S_START;
              cnt   <= shift_right(div, 1) - 1;   -- to the middle of the start bit
            end if;

          when S_START =>
            if cnt = 0 then
              if rx_s = '0' then
                state <= S_DATA;
                nbit  <= 0;
                cnt   <= div - 1;
              else
                state <= S_IDLE;                  -- glitch
              end if;
            else
              cnt <= cnt - 1;
            end if;

          when S_DATA =>
            if cnt = 0 then
              sh  <= rx_s & sh(7 downto 1);       -- LSB first
              cnt <= div - 1;
              if nbit = 7 then
                state <= S_STOP;
              else
                nbit <= nbit + 1;
              end if;
            else
              cnt <= cnt - 1;
            end if;

          when S_STOP =>
            if cnt = 0 then
              if rx_s = '1' then
                valid_q <= '1';
                state   <= S_IDLE;
              else
                ferr_q <= '1';
                state  <= S_WAIT_HIGH;
              end if;
            else
              cnt <= cnt - 1;
            end if;

          when S_WAIT_HIGH =>
            if rx_s = '1' then
              state <= S_IDLE;
            end if;
        end case;
      end if;
    end if;
  end process;

  data      <= sh;
  valid     <= valid_q;
  frame_err <= ferr_q;
  busy      <= '0' when state = S_IDLE else '1';

end architecture rtl;
