--------------------------------------------------------------------------------
-- enc_8b10b
--
-- 8b/10b encoder with running disparity, one symbol per en strobe.
-- Code definition: code8b10b_pkg.
--
-- Assumptions:
--   * en marks a new byte; between strobes the outputs hold the last symbol
--     (the serializer takes one symbol every 10 bit periods).
--   * k = '1' with a byte that is not a valid control character is encoded
--     as the data character of the same value and flagged on k_err.
--   * Reset sets the running disparity to RD-.
--
-- Latency: 1 clock cycle from en to code/valid.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

library work;
use work.code8b10b_pkg.all;

entity enc_8b10b is
  port (
    clk   : in  std_logic;
    rst   : in  std_logic;                     -- synchronous, active high
    en    : in  std_logic;                     -- byte valid
    data  : in  std_logic_vector(7 downto 0);
    k     : in  std_logic;                     -- control character
    code  : out std_logic_vector(9 downto 0);  -- code(0) = bit 'a', sent first
    valid : out std_logic;                     -- new symbol on code
    k_err : out std_logic;                     -- invalid control code requested
    rd    : out std_logic                      -- running disparity after code
  );
end entity enc_8b10b;

architecture rtl of enc_8b10b is

  signal rd_reg    : std_logic := '0';
  signal code_reg  : t_symbol  := (others => '0');
  signal valid_reg : std_logic := '0';
  signal kerr_reg  : std_logic := '0';

begin

  process (clk)
    variable r : t_enc_result;
  begin
    if rising_edge(clk) then
      valid_reg <= '0';
      if rst = '1' then
        rd_reg   <= '0';
        code_reg <= (others => '0');
        kerr_reg <= '0';
      elsif en = '1' then
        r         := encode_8b10b(data, k, rd_reg);
        code_reg  <= r.code;
        rd_reg    <= r.rd_out;
        kerr_reg  <= r.k_err;
        valid_reg <= '1';
      end if;
    end if;
  end process;

  code  <= code_reg;
  valid <= valid_reg;
  k_err <= kerr_reg;
  rd    <= rd_reg;

end architecture rtl;
