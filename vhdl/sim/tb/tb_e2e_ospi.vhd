--------------------------------------------------------------------------------
-- tb_e2e_ospi
--
-- End-to-end test OSPI <-> OSPI: two complete bridges connected by the SFP line
-- (e2e_bench, LINES = 8). Results for the documentation: doc/e2e/.
--------------------------------------------------------------------------------

entity tb_e2e_ospi is
end entity tb_e2e_ospi;

architecture sim of tb_e2e_ospi is
begin
  bench : entity work.e2e_bench
    generic map (LINES => 8, NAME => "tb_e2e_ospi");
end architecture sim;
