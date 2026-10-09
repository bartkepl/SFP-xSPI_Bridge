--------------------------------------------------------------------------------
-- tb_e2e_spi
--
-- End-to-end test SPI <-> SPI: two complete bridges connected by the SFP line
-- (e2e_bench, LINES = 1). Results for the documentation: doc/e2e/.
--------------------------------------------------------------------------------

entity tb_e2e_spi is
end entity tb_e2e_spi;

architecture sim of tb_e2e_spi is
begin
  bench : entity work.e2e_bench
    generic map (LINES => 1, NAME => "tb_e2e_spi");
end architecture sim;
