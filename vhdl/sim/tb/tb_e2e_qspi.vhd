--------------------------------------------------------------------------------
-- tb_e2e_qspi
--
-- End-to-end test QSPI <-> QSPI: two complete bridges connected by the SFP line
-- (e2e_bench, LINES = 4). Results for the documentation: doc/e2e/.
--------------------------------------------------------------------------------

entity tb_e2e_qspi is
end entity tb_e2e_qspi;

architecture sim of tb_e2e_qspi is
begin
  bench : entity work.e2e_bench
    generic map (LINES => 4, NAME => "tb_e2e_qspi");
end architecture sim;
