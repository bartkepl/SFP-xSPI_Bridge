--------------------------------------------------------------------------------
-- tb_async_fifo_stable
--
-- tb_async_fifo with the DUT in PUB_STABLE mode (committed pointer crossing
-- without handshake, ADR 0009): the same checks; the writer keeps commits at
-- least 120 ns (>= 3 periods of the slowest read clock) apart.
--------------------------------------------------------------------------------

entity tb_async_fifo_stable is
end entity tb_async_fifo_stable;

architecture sim of tb_async_fifo_stable is
begin
  u : entity work.tb_async_fifo generic map (STABLE => true);
end architecture sim;
