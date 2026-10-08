--------------------------------------------------------------------------------
-- tb_8b10b
--
-- Testbench for code8b10b_pkg, enc_8b10b and dec_8b10b.
--
-- Part A - encoder function against published code words (independent
--          reference, written as "abcdei fghj" strings).
-- Part B - exhaustive properties over all 256 data + 12 control characters in
--          both running disparities:
--            * run of 5 identical bits inside a symbol only in K28.1/5/7,
--              otherwise <= 4 (guards the D.x.A7 rule)
--            * symbol weight 4/5/6, sub-block weights 2..4 (6b) and 1..3 (4b)
--            * RD- start never yields weight 4, RD+ never weight 6
--            * rd_out consistent with the weight
--            * every (character, RD) maps to a distinct symbol, except that a
--              neutral symbol may be shared by both RD of the same character
--            * comma 0011111 / 1100000 (bits a..f) only in K28.1, K28.5, K28.7
-- Part C - stream through enc_8b10b -> dec_8b10b (20000 random characters with
--          K28.5 idles): no errors, data/k reproduced, run length <= 5,
--          running digital sum bounded, comma only at symbol boundaries of
--          K28.1/K28.5/K28.7 (singular comma).
-- Part D - error injection on the decoder input:
--            * invalid symbol 0000000000 -> code_err
--            * K28.5 RD+ form received while RD- expected -> disp_err, and the
--              character is still decoded as K28.5
--
-- Waveform: enc (data, k, code, rd) and dec (code, data, k, code_err,
-- disp_err, rd); see doc/vhdl/8b10b.md.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library work;
use work.tb_pkg.all;
use work.code8b10b_pkg.all;
use work.bridge_pkg.all;

entity tb_8b10b is
end entity tb_8b10b;

architecture sim of tb_8b10b is

  constant T_CLK : time := 10 ns;

  signal clk  : std_logic := '0';
  signal stop : boolean   := false;
  signal rst  : std_logic := '1';

  -- encoder
  signal enc_en    : std_logic := '0';
  signal enc_data  : std_logic_vector(7 downto 0) := (others => '0');
  signal enc_k     : std_logic := '0';
  signal enc_code  : std_logic_vector(9 downto 0);
  signal enc_valid : std_logic;
  signal enc_kerr  : std_logic;
  signal enc_rd    : std_logic;

  -- decoder (input either from encoder or forced for error injection)
  signal dec_en    : std_logic := '0';
  signal dec_code  : std_logic_vector(9 downto 0) := (others => '0');
  signal dec_data  : std_logic_vector(7 downto 0);
  signal dec_k     : std_logic;
  signal dec_valid : std_logic;
  signal dec_cerr  : std_logic;
  signal dec_derr  : std_logic;
  signal dec_rd    : std_logic;
  signal inject    : boolean := false;
  signal inj_code  : std_logic_vector(9 downto 0) := (others => '0');
  signal inj_en    : std_logic := '0';

  -- "abcdei fghj" (spaces ignored) -> code(0) = a ... code(9) = j
  function sym(s : string) return t_symbol is
    variable r : t_symbol;
    variable n : natural := 0;
  begin
    for i in s'range loop
      if s(i) = '0' or s(i) = '1' then
        r(n) := '1' when s(i) = '1' else '0';
        n := n + 1;
      end if;
    end loop;
    assert n = 10 report "sym: string must contain 10 bits" severity failure;
    return r;
  end function;

  function byte_of(x, y : natural) return t_byte is
  begin
    return std_logic_vector(to_unsigned(y, 3)) & std_logic_vector(to_unsigned(x, 5));
  end function;

  function ones_n(v : std_logic_vector) return natural is
    variable n : natural := 0;
  begin
    for i in v'range loop
      if v(i) = '1' then n := n + 1; end if;
    end loop;
    return n;
  end function;

begin

  clk_gen(clk, T_CLK, stop);

  u_enc : entity work.enc_8b10b
    port map (clk => clk, rst => rst, en => enc_en, data => enc_data, k => enc_k,
              code => enc_code, valid => enc_valid, k_err => enc_kerr, rd => enc_rd);

  dec_en   <= inj_en   when inject else enc_valid;
  dec_code <= inj_code when inject else enc_code;

  u_dec : entity work.dec_8b10b
    port map (clk => clk, rst => rst, en => dec_en, code => dec_code,
              data => dec_data, k => dec_k, valid => dec_valid,
              code_err => dec_cerr, disp_err => dec_derr, rd => dec_rd);

  process
    --------------------------------------------------------------------------
    procedure golden(x, y : natural; k : std_logic; neg, pos : string; name : string) is
      variable r : t_enc_result;
    begin
      r := encode_8b10b(byte_of(x, y), k, '0');
      check_equal(r.code, sym(neg), name & " RD-");
      r := encode_8b10b(byte_of(x, y), k, '1');
      check_equal(r.code, sym(pos), name & " RD+");
    end procedure;

    procedure send_sym(s : t_symbol) is
    begin
      inj_code <= s;
      inj_en   <= '1';
      wait until rising_edge(clk);
      inj_en <= '0';
      loop
        wait until rising_edge(clk);
        wait for 1 ns;
        exit when dec_valid = '1';
      end loop;
    end procedure;

    type t_owner is array (0 to 1023) of integer;   -- -1 = unused, else 512*k + 256*? + byte
    variable owner : t_owner := (others => -1);
    variable r     : t_enc_result;
    variable d     : t_byte;
    variable id    : integer;
    variable w, w6, w4 : natural;
    variable comma     : boolean;
    variable a_f       : std_logic_vector(6 downto 0);
    variable is_comma_char : boolean;
    variable run, max_in    : natural;

    -- stream checks
    variable seed1, seed2 : positive := 7;
    variable rnd          : real;
    type t_char is record
      data : t_byte;
      k    : std_logic;
    end record;
    type t_fifo is array (0 to 31) of t_char;
    variable sent       : t_fifo;
    variable wr, rd_i   : natural := 0;
    variable bits       : std_logic_vector(29 downto 0) := (others => '0');  -- sliding window
    variable run_len    : natural := 0;
    variable last_bit   : std_logic := 'X';
    variable max_run    : natural := 0;
    variable rds        : integer := -1;      -- RD- = -1 at symbol boundary
    variable rds_min, rds_max : integer := -1;
    variable nbits      : natural := 0;
    variable prev_comma_char : boolean := false;
    variable cur_comma_char  : boolean := false;
    variable n_dec      : natural := 0;
    variable n_err      : natural := 0;
    variable c          : t_char;
    variable sym_count  : natural := 0;
  begin
    ------------------------------------------------------------------ Part A
    golden( 0, 0, '0', "100111 0100", "011000 1011", "D0.0");
    golden(21, 5, '0', "101010 1010", "101010 1010", "D21.5");
    golden(10, 2, '0', "010101 0101", "010101 0101", "D10.2");
    golden(16, 2, '0', "011011 0101", "100100 0101", "D16.2");
    golden( 7, 0, '0', "111000 1011", "000111 0100", "D7.0");
    golden( 3, 3, '0', "110001 1100", "110001 0011", "D3.3");
    golden(17, 7, '0', "100011 0111", "100011 0001", "D17.7");
    golden(11, 7, '0', "110100 1110", "110100 1000", "D11.7");
    golden(31, 7, '0', "101011 0001", "010100 1110", "D31.7");
    golden(23, 7, '0', "111010 0001", "000101 1110", "D23.7");
    golden(20, 7, '0', "001011 0111", "001011 0001", "D20.7");    -- A7 at RD-
    golden(18, 7, '0', "010011 0111", "010011 0001", "D18.7");    -- A7 at RD-
    golden(13, 7, '0', "101100 1110", "101100 1000", "D13.7");    -- A7 at RD+
    golden(14, 7, '0', "011100 1110", "011100 1000", "D14.7");    -- A7 at RD+
    golden(28, 5, '1', "001111 1010", "110000 0101", "K28.5");
    golden(28, 1, '1', "001111 1001", "110000 0110", "K28.1");
    golden(28, 7, '1', "001111 1000", "110000 0111", "K28.7");
    golden(28, 0, '1', "001111 0100", "110000 1011", "K28.0");
    golden(23, 7, '1', "111010 1000", "000101 0111", "K23.7");
    golden(27, 7, '1', "110110 1000", "001001 0111", "K27.7");
    golden(29, 7, '1', "101110 1000", "010001 0111", "K29.7");
    golden(30, 7, '1', "011110 1000", "100001 0111", "K30.7");

    ------------------------------------------------------------------ Part B
    for kbit in 0 to 1 loop
      for v in 0 to 255 loop
        d := std_logic_vector(to_unsigned(v, 8));
        next when kbit = 1 and not is_valid_k(d);
        id := 256 * kbit + v;
        is_comma_char := kbit = 1 and (d = x"3C" or d = x"BC" or d = x"FC");
        for rdi in 0 to 1 loop
          r  := encode_8b10b(d, to_sl(kbit = 1), to_sl(rdi = 1));
          w  := ones_n(r.code);
          w6 := ones_n(r.code(5 downto 0));
          w4 := ones_n(r.code(9 downto 6));
          check(w >= 4 and w <= 6, "weight 4..6 for id " & integer'image(id));
          check(w6 >= 2 and w6 <= 4, "6b weight for id " & integer'image(id));
          check(w4 >= 1 and w4 <= 3, "4b weight for id " & integer'image(id));
          if rdi = 0 then
            check(w /= 4, "RD- start gives weight 4, id " & integer'image(id));
          else
            check(w /= 6, "RD+ start gives weight 6, id " & integer'image(id));
          end if;
          if w = 6 then
            check_equal(r.rd_out, '1', "rd_out after weight 6, id " & integer'image(id));
          elsif w = 4 then
            check_equal(r.rd_out, '0', "rd_out after weight 4, id " & integer'image(id));
          else
            check_equal(r.rd_out, to_sl(rdi = 1), "rd_out after weight 5, id " & integer'image(id));
          end if;
          check_equal(r.k_err, '0', "k_err for valid character, id " & integer'image(id));
          -- uniqueness
          if owner(to_integer(unsigned(r.code))) = -1 then
            owner(to_integer(unsigned(r.code))) := id;
          else
            check_equal(owner(to_integer(unsigned(r.code))), id,
                        "symbol shared by two characters, id " & integer'image(id));
          end if;
          -- comma in bits a..f (code(0..6) = a b c d e i f)
          a_f   := r.code(6 downto 0);
          comma := a_f = "1111100" or a_f = "0000011";   -- a..f = 0011111 / 1100000
          check(comma = is_comma_char, "comma only in K28.1/5/7, id " & integer'image(id));
          -- run length inside the symbol: 5 only in comma characters, else <= 4
          run := 1; max_in := 1;
          for b in 1 to 9 loop
            if r.code(b) = r.code(b - 1) then run := run + 1; else run := 1; end if;
            if run > max_in then max_in := run; end if;
          end loop;
          if is_comma_char then
            check_equal(max_in, 5, "internal run of comma character, id " & integer'image(id));
          else
            check(max_in <= 4, "internal run <= 4 (got " & integer'image(max_in) & "), id " & integer'image(id));
          end if;
        end loop;
      end loop;
    end loop;
    -- invalid control code request
    r := encode_8b10b(x"00", '1', '0');
    check_equal(r.k_err, '1', "k_err for K0.0");

    ------------------------------------------------------------------ Part C
    rst <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    rst <= '0';

    -- receiver side checks run in parallel with the transmitter loop
    for n in 0 to 20000 + 2 loop
      -- transmit one character every cycle (stress, no idle gaps)
      if n < 20000 then
        uniform(seed1, seed2, rnd);
        if rnd < 0.10 then
          c := (data => K28_5, k => '1');
        elsif rnd < 0.13 then
          -- other control characters, but not K28.7 (it may form a comma
          -- across the following boundary) and not K28.1/K28.5 twice in a row
          uniform(seed1, seed2, rnd);
          case integer(trunc(rnd * 5.999)) is
            when 0 => c := (data => K27_7, k => '1');
            when 1 => c := (data => K29_7, k => '1');
            when 2 => c := (data => K30_7, k => '1');
            when 3 => c := (data => x"F7", k => '1');    -- K23.7
            when 4 => c := (data => x"1C", k => '1');    -- K28.0
            when others => c := (data => x"3C", k => '1'); -- K28.1
          end case;
        else
          uniform(seed1, seed2, rnd);
          c := (data => std_logic_vector(to_unsigned(integer(trunc(rnd * 255.999)), 8)), k => '0');
        end if;
        enc_en <= '1'; enc_data <= c.data; enc_k <= c.k;
        sent(wr) := c; wr := (wr + 1) mod 32;
      else
        enc_en <= '0';
      end if;
      wait until rising_edge(clk);
      wait for 1 ns;

      -- encoder output: line-level checks on the serial bit stream
      if enc_valid = '1' then
        sym_count := sym_count + 1;
        for b in 0 to 9 loop
          if enc_code(b) = last_bit then
            run_len := run_len + 1;
          else
            run_len := 1;
            last_bit := enc_code(b);
          end if;
          if run_len > max_run then max_run := run_len; end if;
          if enc_code(b) = '1' then rds := rds + 1; else rds := rds - 1; end if;
          if rds < rds_min then rds_min := rds; end if;
          if rds > rds_max then rds_max := rds; end if;
          bits := bits(28 downto 0) & enc_code(b);  -- newest bit at bits(0)
          nbits := nbits + 1;
          -- comma ending at this bit: newest 7 bits, oldest first = a..f
          if nbits >= 7 and (bits(6 downto 0) = "0011111" or bits(6 downto 0) = "1100000") then
            -- the comma must start at bit a of the current symbol (b = 6)
            check(b = 6, "comma at symbol boundary only (symbol " & integer'image(sym_count) & ")");
          end if;
        end loop;
      end if;

      -- decoder output
      if dec_valid = '1' then
        c := sent(rd_i); rd_i := (rd_i + 1) mod 32;
        n_dec := n_dec + 1;
        if dec_cerr = '1' or dec_derr = '1' or dec_data /= c.data or dec_k /= c.k then
          n_err := n_err + 1;
        end if;
      end if;
    end loop;
    check_equal(n_dec, 20000, "decoded character count");
    check_equal(n_err, 0, "decoded characters with errors or mismatch");
    check(max_run <= 5, "run length <= 5 (max " & integer'image(max_run) & ")");
    check(rds_min >= -3 and rds_max <= 3,
          "running digital sum bounded (" & integer'image(rds_min) & ".." & integer'image(rds_max) & ")");
    check_equal(enc_kerr, '0', "encoder k_err in stream");

    ------------------------------------------------------------------ Part D
    -- Drive the decoder input directly; each symbol is checked when the
    -- decoder reports valid (independent of the pipeline latency).
    inject <= true;
    wait until rising_edge(clk);

    send_sym("0000000000");
    check_equal(dec_cerr, '1', "code_err for 0000000000");

    -- bring the decoder to RD- with a properly signed K28.5
    if dec_rd = '1' then
      send_sym(sym("110000 0101"));       -- K28.5 RD+ form -> RD-
    else
      send_sym(sym("001111 1010"));       -- K28.5 RD- form -> RD+
      send_sym(sym("110000 0101"));       -- K28.5 RD+ form -> RD-
    end if;
    check_equal(dec_rd, '0', "decoder at RD- before disparity test");
    check_equal(dec_derr, '0', "no disparity error on proper K28.5");

    send_sym(sym("110000 0101"));         -- RD+ form while RD- expected
    check_equal(dec_derr, '1', "disp_err for wrong-disparity K28.5");
    check_equal(dec_cerr, '0', "no code_err for wrong-disparity K28.5");
    check_equal(dec_k, '1', "wrong-disparity K28.5 still decoded as control");
    check_equal(dec_data, K28_5, "wrong-disparity K28.5 still decoded as K28.5");

    stop <= true;
    tb_finish("tb_8b10b");
    wait;
  end process;

end architecture sim;
