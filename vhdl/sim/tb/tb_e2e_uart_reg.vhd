--------------------------------------------------------------------------------
-- tb_e2e_uart_reg
--
-- End-to-end test UART <-> UART with the UART mode selected by register
-- (MODE_CTRL, UART_DIV = 50, 1 Mbit/s) and UART_STATUS read back after the
-- return to the xSPI mode; two complete bridges connected by the SFP line
-- (e2e_bench, LINES = 9). Results for the documentation: doc/e2e/.
--------------------------------------------------------------------------------

entity tb_e2e_uart_reg is
end entity tb_e2e_uart_reg;

architecture sim of tb_e2e_uart_reg is
begin
  bench : entity work.e2e_bench
    generic map (LINES => 9, NAME => "tb_e2e_uart_reg");
end architecture sim;
