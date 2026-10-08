--------------------------------------------------------------------------------
-- crc32
--
-- CRC-32 as used by IEEE 802.3 (Ethernet FCS), one byte per clock cycle.
--
--   polynomial  0x04C11DB7 (reflected form 0xEDB88320)
--   init        0xFFFFFFFF
--   reflection  input and output reflected (bytes processed LSB first)
--   final XOR   0xFFFFFFFF
--   check value CRC("123456789") = 0xCBF43926
--
-- Transmitter: feed the payload, then send crc(7:0), crc(15:8), crc(23:16),
-- crc(31:24) in this order.
-- Receiver: feed the payload followed by the four received CRC bytes in the
-- same order; crc_ok = '1' when the register holds the residue 0xDEBB20E3,
-- i.e. the frame is intact.
--
-- Control (all synchronous to clk):
--   init = '1'             : register loaded with 0xFFFFFFFF
--   init = '1', en = '1'   : register loaded with CRC of data starting from
--                            0xFFFFFFFF (first byte of a frame in the same cycle)
--   en = '1'               : data processed
-- Outputs reflect the register after the last clock edge (no extra latency
-- beyond the register itself).
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity crc32 is
  port (
    clk    : in  std_logic;
    rst    : in  std_logic;                      -- synchronous, active high
    init   : in  std_logic;                      -- start of a new frame
    en     : in  std_logic;                      -- data byte valid
    data   : in  std_logic_vector(7 downto 0);
    crc    : out std_logic_vector(31 downto 0);  -- CRC to transmit
    crc_ok : out std_logic                       -- residue match (receiver)
  );
end entity crc32;

architecture rtl of crc32 is

  constant POLY_REFL : std_logic_vector(31 downto 0) := x"EDB88320";
  constant INIT_VAL  : std_logic_vector(31 downto 0) := x"FFFFFFFF";
  constant RESIDUE   : std_logic_vector(31 downto 0) := x"DEBB20E3";

  -- One byte of the reflected CRC, bit 0 of the byte first (behavioural
  -- definition; used only to derive the XOR masks below)
  function crc32_byte(c : std_logic_vector(31 downto 0);
                      d : std_logic_vector(7 downto 0))
    return std_logic_vector is
    variable r : std_logic_vector(31 downto 0) := c;
  begin
    for i in 0 to 7 loop
      if (r(0) xor d(i)) = '1' then
        r := ('0' & r(31 downto 1)) xor POLY_REFL;
      else
        r := '0' & r(31 downto 1);
      end if;
    end loop;
    return r;
  end function crc32_byte;

  -- The byte update is linear over GF(2): next(j) = XOR of the register bits
  -- selected by MASK_C(j) and of the data bits selected by MASK_D(j).
  -- The masks are computed at elaboration time from crc32_byte, so the
  -- synthesizer sees one flat XOR per output bit (shallow, balanced logic).
  type t_mask_c is array (0 to 31) of std_logic_vector(31 downto 0);
  type t_mask_d is array (0 to 31) of std_logic_vector(7 downto 0);

  function build_mask_c return t_mask_c is
    variable m : t_mask_c;
    variable e : std_logic_vector(31 downto 0);
    variable r : std_logic_vector(31 downto 0);
  begin
    for i in 0 to 31 loop
      e := (others => '0'); e(i) := '1';
      r := crc32_byte(e, x"00");
      for j in 0 to 31 loop
        m(j)(i) := r(j);
      end loop;
    end loop;
    return m;
  end function;

  function build_mask_d return t_mask_d is
    variable m : t_mask_d;
    variable e : std_logic_vector(7 downto 0);
    variable r : std_logic_vector(31 downto 0);
  begin
    for i in 0 to 7 loop
      e := (others => '0'); e(i) := '1';
      r := crc32_byte((others => '0'), e);
      for j in 0 to 31 loop
        m(j)(i) := r(j);
      end loop;
    end loop;
    return m;
  end function;

  constant MASK_C : t_mask_c := build_mask_c;
  constant MASK_D : t_mask_d := build_mask_d;

  function crc32_next(c : std_logic_vector(31 downto 0);
                      d : std_logic_vector(7 downto 0))
    return std_logic_vector is
    variable r : std_logic_vector(31 downto 0);
  begin
    for j in 0 to 31 loop
      r(j) := (xor (c and MASK_C(j))) xor (xor (d and MASK_D(j)));
    end loop;
    return r;
  end function crc32_next;

  signal reg : std_logic_vector(31 downto 0) := INIT_VAL;

begin

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        reg <= INIT_VAL;
      elsif init = '1' then
        if en = '1' then
          reg <= crc32_next(INIT_VAL, data);
        else
          reg <= INIT_VAL;
        end if;
      elsif en = '1' then
        reg <= crc32_next(reg, data);
      end if;
    end if;
  end process;

  crc    <= not reg;
  crc_ok <= '1' when reg = RESIDUE else '0';

end architecture rtl;
