--------------------------------------------------------------------------------
-- tb_crc32
--
-- Testbench for crc32.
--
-- Reference model: non-reflected, MSB-first CRC-32 with explicit bit reversal
-- of input bytes and of the result. It is algorithmically different from the
-- reflected implementation in the DUT, so both cannot share the same mistake.
--
-- Checks:
--   1. Known values: ""        -> 0x00000000
--                    "a"       -> 0xE8B7BE43
--                    "123456789" -> 0xCBF43926 (standard check value)
--                    "The quick brown fox jumps over the lazy dog" -> 0x414FA339
--   2. Receiver residue: payload + CRC bytes (LSB first) -> crc_ok = '1'.
--   3. Single bit error anywhere in payload or CRC -> crc_ok = '0'.
--   4. init and en in the same cycle (first byte of a frame without gap).
--   5. 200 random frames, 1..64 bytes, DUT vs reference model.
--   6. en = '0' cycles inside a frame do not change the result.
--
-- Waveform: clk, init, en, data, crc, crc_ok; see doc/vhdl/crc32.md.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library work;
use work.tb_pkg.all;

entity tb_crc32 is
end entity tb_crc32;

architecture sim of tb_crc32 is

  constant T_CLK : time := 10 ns;

  signal clk    : std_logic := '0';
  signal stop   : boolean   := false;
  signal rst    : std_logic := '1';
  signal init   : std_logic := '0';
  signal en     : std_logic := '0';
  signal data   : std_logic_vector(7 downto 0) := (others => '0');
  signal crc    : std_logic_vector(31 downto 0);
  signal crc_ok : std_logic;

  type t_bytes is array (natural range <>) of std_logic_vector(7 downto 0);

  function reverse(v : std_logic_vector) return std_logic_vector is
    variable r : std_logic_vector(v'range);
  begin
    for i in v'range loop
      r(i) := v(v'left + v'right - i);
    end loop;
    return r;
  end function;

  -- Reference: MSB-first CRC-32 (poly 0x04C11DB7) with reflected I/O
  function ref_crc(msg : t_bytes) return std_logic_vector is
    variable reg : std_logic_vector(31 downto 0) := x"FFFFFFFF";
    variable b   : std_logic_vector(7 downto 0);
  begin
    for n in msg'range loop
      b := reverse(msg(n));
      reg(31 downto 24) := reg(31 downto 24) xor b;
      for i in 0 to 7 loop
        if reg(31) = '1' then
          reg := (reg(30 downto 0) & '0') xor x"04C11DB7";
        else
          reg := reg(30 downto 0) & '0';
        end if;
      end loop;
    end loop;
    return reverse(reg) xor x"FFFFFFFF";
  end function;

  function str_bytes(s : string) return t_bytes is
    variable r : t_bytes(0 to s'length - 1);
  begin
    for i in 0 to s'length - 1 loop
      r(i) := std_logic_vector(to_unsigned(character'pos(s(s'low + i)), 8));
    end loop;
    return r;
  end function;

begin

  clk_gen(clk, T_CLK, stop);

  dut : entity work.crc32
    port map (clk => clk, rst => rst, init => init, en => en, data => data,
              crc => crc, crc_ok => crc_ok);

  process
    variable seed1, seed2 : positive := 42;
    variable rnd          : real;
    variable len          : natural;
    variable frame        : t_bytes(0 to 63);
    variable c            : std_logic_vector(31 downto 0);

    -- Feed bytes; first byte together with init when combined = true
    procedure feed(msg : t_bytes; combined : boolean; gaps : boolean) is
    begin
      if msg'length = 0 then
        init <= '1'; en <= '0';
        wait until rising_edge(clk);
        init <= '0';
        return;
      end if;
      if not combined then
        init <= '1'; en <= '0';
        wait until rising_edge(clk);
        init <= '0';
      end if;
      for i in msg'range loop
        if gaps and (i mod 3 = 1) then
          en <= '0'; data <= x"A5";            -- idle cycle with junk data
          wait until rising_edge(clk);
        end if;
        if combined and i = msg'low then
          init <= '1';
        end if;
        en <= '1'; data <= msg(i);
        wait until rising_edge(clk);
        init <= '0';
      end loop;
      en <= '0';
      wait for 1 ns;
    end procedure;

    procedure check_known(s : string; exp : std_logic_vector(31 downto 0)) is
    begin
      feed(str_bytes(s), false, false);
      check_equal(crc, exp, "CRC of """ & s & """");
      check_equal(ref_crc(str_bytes(s)), exp, "reference model of """ & s & """");
    end procedure;

    -- Payload followed by its CRC, LSB byte first
    function with_crc(msg : t_bytes) return t_bytes is
      variable r  : t_bytes(0 to msg'length + 3);
      variable cr : std_logic_vector(31 downto 0) := ref_crc(msg);
    begin
      r(0 to msg'length - 1) := msg;
      for i in 0 to 3 loop
        r(msg'length + i) := cr(8 * i + 7 downto 8 * i);
      end loop;
      return r;
    end function;

    variable rx  : t_bytes(0 to 67);
    variable pl  : t_bytes(0 to 8);
  begin
    rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';

    -- 1. Known values
    check_known("", x"00000000");
    check_known("a", x"E8B7BE43");
    check_known("123456789", x"CBF43926");
    check_known("The quick brown fox jumps over the lazy dog", x"414FA339");

    -- 2. Residue
    pl := str_bytes("123456789");
    feed(with_crc(pl), false, false);
    check_equal(crc_ok, '1', "residue after payload + CRC");

    -- 3. Single bit errors (payload and CRC bytes)
    for byte in 0 to 12 loop
      for bitn in 0 to 7 loop
        rx(0 to 12) := with_crc(pl);
        rx(byte)(bitn) := not rx(byte)(bitn);
        feed(rx(0 to 12), false, false);
        check_equal(crc_ok, '0', "bit error byte " & integer'image(byte)
                    & " bit " & integer'image(bitn) & " detected");
      end loop;
    end loop;

    -- 4. init together with the first byte
    feed(str_bytes("123456789"), true, false);
    check_equal(crc, x"CBF43926", "init and en in the same cycle");

    -- 5 and 6. Random frames, with and without idle cycles
    for f in 1 to 200 loop
      uniform(seed1, seed2, rnd);
      len := 1 + integer(trunc(rnd * 63.999));
      for i in 0 to len - 1 loop
        uniform(seed1, seed2, rnd);
        frame(i) := std_logic_vector(to_unsigned(integer(trunc(rnd * 255.999)), 8));
      end loop;
      c := ref_crc(frame(0 to len - 1));
      feed(frame(0 to len - 1), (f mod 2) = 0, (f mod 4) = 1);
      check_equal(crc, c, "random frame " & integer'image(f) & " length " & integer'image(len));
      rx(0 to len + 3) := with_crc(frame(0 to len - 1));
      feed(rx(0 to len + 3), false, (f mod 3) = 0);
      check_equal(crc_ok, '1', "random frame " & integer'image(f) & " residue");
    end loop;

    stop <= true;
    tb_finish("tb_crc32");
    wait;
  end process;

end architecture sim;
