--------------------------------------------------------------------------------
-- uart_tx
--
-- UART transmitter, 8N1, LSB first (ADR 0006).
--
-- Bit period: div clock cycles (UART_DIV), div >= UART_DIV_MIN (8).
-- Handshake: when ready = '1', start = '1' takes data and begins a
-- character (start bit, 8 data bits, stop bit); ready returns to '1' after
-- the stop bit, so characters can follow back to back. The line idles at
-- '1'. div is taken at the start of each bit.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_tx is
  port (
    clk   : in  std_logic;
    rst   : in  std_logic;
    div   : in  unsigned(15 downto 0);       -- clock cycles per bit
    data  : in  std_logic_vector(7 downto 0);
    start : in  std_logic;
    ready : out std_logic;
    tx    : out std_logic
  );
end entity uart_tx;

architecture rtl of uart_tx is

  signal busy_q : std_logic := '0';
  signal sh     : std_logic_vector(9 downto 0) := (others => '1');  -- stop & data & start
  signal nbit   : natural range 0 to 9 := 0;
  signal cnt    : unsigned(15 downto 0) := (others => '0');
  signal tx_q   : std_logic := '1';

begin

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        busy_q <= '0';
        tx_q   <= '1';
        cnt    <= (others => '0');
        nbit   <= 0;
      elsif busy_q = '0' then
        tx_q <= '1';
        if start = '1' then
          sh     <= '1' & data & '0';
          busy_q <= '1';
          nbit   <= 0;
          cnt    <= div - 1;
          tx_q   <= '0';                      -- start bit
        end if;
      else
        if cnt = 0 then
          if nbit = 9 then
            busy_q <= '0';                    -- stop bit completed
            tx_q   <= '1';
          else
            nbit <= nbit + 1;
            tx_q <= sh(nbit + 1);
            cnt  <= div - 1;
          end if;
        else
          cnt <= cnt - 1;
        end if;
      end if;
    end if;
  end process;

  ready <= not busy_q;
  tx    <= tx_q;

end architecture rtl;
