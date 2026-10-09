--------------------------------------------------------------------------------
-- tb_e2e_uart
--
-- End-to-end test UART <-> UART: two complete bridges connected by the SFP line
-- (e2e_bench, LINES = 0). Results for the documentation: doc/e2e/.
--------------------------------------------------------------------------------

entity tb_e2e_uart is
end entity tb_e2e_uart;

architecture sim of tb_e2e_uart is
begin
  bench : entity work.e2e_bench
    generic map (LINES => 0, NAME => "tb_e2e_uart");
end architecture sim;
