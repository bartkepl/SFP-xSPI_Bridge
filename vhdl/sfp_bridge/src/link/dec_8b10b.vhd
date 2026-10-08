--------------------------------------------------------------------------------
-- dec_8b10b
--
-- 8b/10b decoder with running-disparity tracking and error flags.
-- Code definition: code8b10b_pkg (lookup table derived from the encoder).
--
-- Assumptions:
--   * code is word-aligned (comma alignment is done upstream) and en marks
--     a new symbol.
--   * Reset sets the expected running disparity to RD-. After a disparity
--     error the decoder adopts the disparity implied by the received symbol,
--     so a single error does not cause a burst of follow-up errors.
--
-- Outputs (registered, valid together with valid):
--   data, k    decoded character (meaningful only when code_err = '0')
--   code_err   symbol is not a valid 8b/10b code word in either disparity
--   disp_err   symbol is valid, but not for the current running disparity
--
-- Pipeline (timing at 100 MHz on GW1N-9):
--   stage 1: synchronous read of the lookup table (1024 x 13 bits, mapped to
--            one block RAM as ROM); the table also holds the symbol weight
--   stage 2: disparity check and running-disparity update from the table
--            output, output registers
--
-- Latency: 2 clock cycles from en to valid.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.code8b10b_pkg.all;

entity dec_8b10b is
  port (
    clk      : in  std_logic;
    rst      : in  std_logic;                     -- synchronous, active high
    en       : in  std_logic;                     -- symbol valid
    code     : in  std_logic_vector(9 downto 0);  -- code(0) = bit 'a'
    data     : out std_logic_vector(7 downto 0);
    k        : out std_logic;
    valid    : out std_logic;
    code_err : out std_logic;
    disp_err : out std_logic;
    rd       : out std_logic                      -- running disparity after symbol
  );
end entity dec_8b10b;

architecture rtl of dec_8b10b is

  constant DEC_TABLE : t_dec_table := build_dec_table;

  -- stage 1
  signal rom_q     : t_dec_entry := (data => (others => '0'), k => '0',
                                     valid_neg => '0', valid_pos => '0',
                                     w6 => '0', w4 => '0');
  signal en_q      : std_logic := '0';

  -- stage 2
  signal rd_reg    : std_logic := '0';
  signal data_reg  : t_byte    := (others => '0');
  signal k_reg     : std_logic := '0';
  signal valid_reg : std_logic := '0';
  signal cerr_reg  : std_logic := '0';
  signal derr_reg  : std_logic := '0';

begin

  -- Stage 1: table lookup (block RAM, synchronous read)
  process (clk)
  begin
    if rising_edge(clk) then
      rom_q <= DEC_TABLE(to_integer(unsigned(code)));
      if rst = '1' then
        en_q <= '0';
      else
        en_q <= en;
      end if;
    end if;
  end process;

  -- Stage 2: error flags and running disparity
  process (clk)
    variable ok : std_logic;
  begin
    if rising_edge(clk) then
      valid_reg <= '0';
      if rst = '1' then
        rd_reg   <= '0';
        data_reg <= (others => '0');
        k_reg    <= '0';
        cerr_reg <= '0';
        derr_reg <= '0';
      elsif en_q = '1' then
        data_reg  <= rom_q.data;
        k_reg     <= rom_q.k;
        valid_reg <= '1';

        if rom_q.valid_neg = '0' and rom_q.valid_pos = '0' then
          cerr_reg <= '1';
          derr_reg <= '0';
        else
          cerr_reg <= '0';
          ok       := rom_q.valid_pos when rd_reg = '1' else rom_q.valid_neg;
          derr_reg <= not ok;
        end if;

        -- Running disparity from the symbol weight: 6 ones -> RD+,
        -- 4 ones -> RD-, otherwise unchanged (weight 5, or a code error).
        if rom_q.w6 = '1' then
          rd_reg <= '1';
        elsif rom_q.w4 = '1' then
          rd_reg <= '0';
        end if;
      end if;
    end if;
  end process;

  data     <= data_reg;
  k        <= k_reg;
  valid    <= valid_reg;
  code_err <= cerr_reg;
  disp_err <= derr_reg;
  rd       <= rd_reg;

end architecture rtl;
