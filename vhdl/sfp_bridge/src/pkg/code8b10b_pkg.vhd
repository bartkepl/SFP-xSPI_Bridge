--------------------------------------------------------------------------------
-- code8b10b_pkg
--
-- 8b/10b line code (Widmer-Franaszek, as in IEEE 802.3 clause 36 / Fibre
-- Channel): code tables, encoder function and decoder lookup table.
--
-- Bit naming and order:
--   byte  : data(7 downto 0) = H G F E D C B A
--   symbol: code(9 downto 0) with code(0) = a, code(1) = b, code(2) = c,
--           code(3) = d, code(4) = e, code(5) = i, code(6) = f, code(7) = g,
--           code(8) = h, code(9) = j.
--   The symbol is transmitted code(0) first (bit 'a' first).
--
-- Running disparity (RD): '0' = RD-, '1' = RD+.
--
-- Valid control characters: K28.0 .. K28.7, K23.7, K27.7, K29.7, K30.7.
-- Comma sequences (0011111 / 1100000 in bits a..f) occur only in K28.1,
-- K28.5 and K28.7.
--
-- The decoder table is derived from the encoder function at elaboration time,
-- so encoder and decoder share a single code definition.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package code8b10b_pkg is

  subtype t_byte   is std_logic_vector(7 downto 0);
  subtype t_symbol is std_logic_vector(9 downto 0);

  type t_enc_result is record
    code   : t_symbol;    -- 10-bit symbol
    rd_out : std_logic;   -- running disparity after the symbol
    k_err  : std_logic;   -- k = '1' requested for an invalid control code
  end record;

  -- Encode one byte. rd_in = running disparity before the symbol.
  function encode_8b10b(data : t_byte; k : std_logic; rd_in : std_logic)
    return t_enc_result;

  -- True when (data, k = '1') is one of the 12 valid control characters
  function is_valid_k(data : t_byte) return boolean;

  -- Number of ones in a symbol
  function ones_count(code : t_symbol) return natural;

  -- Decoder lookup table entry
  type t_dec_entry is record
    data      : t_byte;
    k         : std_logic;
    valid_neg : std_logic;  -- symbol is valid when received with RD-
    valid_pos : std_logic;  -- symbol is valid when received with RD+
    w6        : std_logic;  -- symbol weight 6 (RD+ after the symbol)
    w4        : std_logic;  -- symbol weight 4 (RD- after the symbol)
  end record;

  type t_dec_table is array (0 to 1023) of t_dec_entry;

  function build_dec_table return t_dec_table;

end package code8b10b_pkg;

package body code8b10b_pkg is

  -- 5b/6b sub-block, RD- column, written as "abcdei" (a = leftmost)
  type t_tab6 is array (0 to 31) of std_logic_vector(5 downto 0);
  constant TAB6_NEG : t_tab6 := (
    "100111", "011101", "101101", "110001", "110101", "101001", "011001", "111000",  --  0.. 7
    "111001", "100101", "010101", "110100", "001101", "101100", "011100", "010111",  --  8..15
    "011011", "100011", "010011", "110010", "001011", "101010", "011010", "111010",  -- 16..23
    "110011", "100110", "010110", "110110", "001110", "101110", "011110", "101011"); -- 24..31
  constant K28_6_NEG : std_logic_vector(5 downto 0) := "001111";

  -- 3b/4b sub-block, RD- column, written as "fghj" (f = leftmost)
  type t_tab4 is array (0 to 7) of std_logic_vector(3 downto 0);
  constant TAB4_D_NEG : t_tab4 := (
    "1011", "1001", "0101", "1100", "1101", "1010", "0110", "1110");  -- x.7 = P7
  constant D_A7_NEG   : std_logic_vector(3 downto 0) := "0111";
  constant TAB4_K_NEG : t_tab4 := (
    "1011", "0110", "1010", "1100", "1101", "0101", "1001", "0111");

  function ones6(v : std_logic_vector(5 downto 0)) return natural is
    variable n : natural := 0;
  begin
    for i in v'range loop
      if v(i) = '1' then n := n + 1; end if;
    end loop;
    return n;
  end function;

  function ones4(v : std_logic_vector(3 downto 0)) return natural is
    variable n : natural := 0;
  begin
    for i in v'range loop
      if v(i) = '1' then n := n + 1; end if;
    end loop;
    return n;
  end function;

  function ones_count(code : t_symbol) return natural is
    variable n : natural := 0;
  begin
    for i in code'range loop
      if code(i) = '1' then n := n + 1; end if;
    end loop;
    return n;
  end function;

  function is_valid_k(data : t_byte) return boolean is
    constant x : natural := to_integer(unsigned(data(4 downto 0)));
    constant y : natural := to_integer(unsigned(data(7 downto 5)));
  begin
    return x = 28 or (y = 7 and (x = 23 or x = 27 or x = 29 or x = 30));
  end function;

  function encode_8b10b(data : t_byte; k : std_logic; rd_in : std_logic)
    return t_enc_result is
    constant x     : natural := to_integer(unsigned(data(4 downto 0)));
    constant y     : natural := to_integer(unsigned(data(7 downto 5)));
    variable kk    : boolean;
    variable six   : std_logic_vector(5 downto 0);   -- "abcdei"
    variable four  : std_logic_vector(3 downto 0);   -- "fghj"
    variable rd6   : std_logic;                      -- RD after the 6b block
    variable res   : t_enc_result;
  begin
    kk        := (k = '1') and is_valid_k(data);
    res.k_err := '1' when (k = '1' and not is_valid_k(data)) else '0';

    -- 5b/6b
    if kk and x = 28 then
      six := K28_6_NEG;
    else
      six := TAB6_NEG(x);
    end if;
    if rd_in = '1' and (ones6(six) /= 3 or (x = 7 and not kk)) then
      six := not six;                    -- RD+ form: complement
    end if;
    if ones6(six) /= 3 then
      rd6 := not rd_in;                  -- unbalanced block flips RD
    else
      rd6 := rd_in;
    end if;

    -- 3b/4b
    if kk then
      four := TAB4_K_NEG(y);
      if rd6 = '1' then
        four := not four;                -- all K 4b codes alternate
      end if;
    else
      if y = 7 and ((rd6 = '0' and (x = 17 or x = 18 or x = 20)) or
                    (rd6 = '1' and (x = 11 or x = 13 or x = 14))) then
        four := D_A7_NEG;                -- A7 avoids a run of five
      else
        four := TAB4_D_NEG(y);
      end if;
      if rd6 = '1' and (ones4(four) /= 2 or y = 3) then
        four := not four;
      end if;
    end if;
    if ones4(four) /= 2 then
      res.rd_out := not rd6;
    else
      res.rd_out := rd6;
    end if;

    -- Map to transmission order: code(0) = a ... code(5) = i, code(6) = f ... code(9) = j
    for i in 0 to 5 loop
      res.code(i) := six(5 - i);
    end loop;
    for i in 0 to 3 loop
      res.code(6 + i) := four(3 - i);
    end loop;
    return res;
  end function encode_8b10b;

  function to_sl(b : boolean) return std_logic is
  begin
    if b then return '1'; else return '0'; end if;
  end function;

  function build_dec_table return t_dec_table is
    variable tab : t_dec_table;
    variable r   : t_enc_result;
    variable idx : natural;
    variable d   : t_byte;
  begin
    for i in tab'range loop
      tab(i) := (data => (others => '0'), k => '0', valid_neg => '0', valid_pos => '0',
                 w6 => '0', w4 => '0');
      -- weight of every 10-bit pattern, valid or not
      tab(i).w6 := to_sl(ones_count(std_logic_vector(to_unsigned(i, 10))) = 6);
      tab(i).w4 := to_sl(ones_count(std_logic_vector(to_unsigned(i, 10))) = 4);
    end loop;
    for kbit in 0 to 1 loop
      for v in 0 to 255 loop
        d := std_logic_vector(to_unsigned(v, 8));
        if kbit = 0 or is_valid_k(d) then
          for rd in 0 to 1 loop
            r := encode_8b10b(d, to_sl(kbit = 1), to_sl(rd = 1));
            idx := to_integer(unsigned(r.code));
            tab(idx).data := d;
            tab(idx).k    := '1' when kbit = 1 else '0';
            if rd = 0 then
              tab(idx).valid_neg := '1';
            else
              tab(idx).valid_pos := '1';
            end if;
          end loop;
        end if;
      end loop;
    end loop;
    return tab;
  end function build_dec_table;

end package body code8b10b_pkg;
