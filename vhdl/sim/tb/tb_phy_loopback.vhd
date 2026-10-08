--------------------------------------------------------------------------------
-- tb_phy_loopback
--
-- Testbench of the serial path with the Gowin primitive simulation models
-- (library gw1n, compiled from prim_sim.vhd by run_tests.sh):
--
--   char source -> enc_8b10b -> tx_gearbox -> tx_phy (OSER8, TLVDS_OBUF)
--     -> wire (transport delay) -> rx_phy (TLVDS_IBUF, IDES8)
--     -> cdr_os4x8 -> comma_align -> dec_8b10b
--
-- clk_fast = 200 MHz, clk_sys from the Gowin CLKDIV model (DIV_MODE "4"),
-- one clock for both ends: verifies the bit order and timing of the
-- primitives, the gearbox and the receive chain, not the frequency
-- tracking (tb_cdr_os4x8, tb_link_loopback).
--
-- Character source: char(i) = K28.5 for i mod 8 = 0, D16.2 for i mod 8 = 1,
-- otherwise the data byte (13 * (i / 8) + i mod 8) mod 256.
--
-- Phases: wire delay 0.3, 2.9, 5.5, 8.1 ns (sampling phases across one bit
-- period of 10 ns); after each change comma_align is restarted.
-- Checks per phase:
--   1. sync within 5 us (4 commas 8 characters apart: 3.2 us);
--   2. 1000 consecutive decoded characters equal the source sequence
--      (position found from the first 16), no decoder error;
--   3. cdr_os4x8 delivers 2 bits in every clock (equal clocks, no phase
--      wrap) after lock.
--
-- Waveform: line signal, IDES8 samples, recovered bits, symbols, decoded
-- characters; see doc/vhdl/phy.md.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library gw1n;
use gw1n.components.all;

library work;
use work.tb_pkg.all;
use work.bridge_pkg.all;

entity tb_phy_loopback is
end entity tb_phy_loopback;

architecture sim of tb_phy_loopback is

  constant T_FAST  : time := 5 ns;
  constant N_CHK   : natural := 1000;
  type t_dly_arr is array (0 to 3) of time;
  constant WIRE_DLY : t_dly_arr := (0.3 ns, 2.9 ns, 5.5 ns, 8.1 ns);

  signal clk_fast  : std_logic := '0';
  signal clk_sys   : std_logic;
  signal rst       : std_logic := '1';
  signal stop      : boolean := false;

  -- transmit side
  signal char_en   : std_logic;
  signal ch_idx    : natural := 0;
  signal ch_data   : std_logic_vector(7 downto 0) := K28_5;
  signal ch_k      : std_logic := '1';
  signal code      : std_logic_vector(9 downto 0);
  signal tx_bits   : std_logic_vector(1 downto 0);
  signal td_p, td_n : std_logic;

  -- wire
  signal dly       : time := WIRE_DLY(0);
  signal rd_p, rd_n : std_logic := '0';

  -- receive side
  signal samples   : std_logic_vector(7 downto 0);
  signal bits      : std_logic_vector(2 downto 0);
  signal nbits     : unsigned(1 downto 0);
  signal phase     : unsigned(1 downto 0);
  signal restart   : std_logic := '0';
  signal sym       : std_logic_vector(9 downto 0);
  signal sym_valid, sym_comma, sync : std_logic;
  signal dec_data  : std_logic_vector(7 downto 0);
  signal dec_k, dec_valid, dec_cerr, dec_derr, dec_err : std_logic;

  signal ph_no     : natural := 0;

  function src_data(i : natural) return std_logic_vector is
  begin
    if i mod 8 = 0 then return K28_5;
    elsif i mod 8 = 1 then return D16_2;
    else return std_logic_vector(to_unsigned((13 * (i / 8) + i mod 8) mod 256, 8));
    end if;
  end function;

  function src_k(i : natural) return std_logic is
  begin
    if i mod 8 = 0 then return '1'; else return '0'; end if;
  end function;

begin

  clk_gen(clk_fast, T_FAST, stop);

  u_div : CLKDIV
    generic map (DIV_MODE => "4", GSREN => "false")
    port map (HCLKIN => clk_fast, RESETN => '1', CALIB => '0', CLKOUT => clk_sys);

  ------------------------------------------------------------------------------
  -- Transmit side
  ------------------------------------------------------------------------------
  -- character source, same handshake as tx_framer
  process (clk_sys)
  begin
    if rising_edge(clk_sys) then
      if rst = '1' then
        ch_idx  <= 0;
        ch_data <= src_data(0);
        ch_k    <= src_k(0);
      elsif char_en = '1' then
        ch_idx  <= ch_idx + 1;
        ch_data <= src_data(ch_idx + 1);
        ch_k    <= src_k(ch_idx + 1);
      end if;
    end if;
  end process;

  u_enc : entity work.enc_8b10b
    port map (clk => clk_sys, rst => rst, en => char_en, data => ch_data, k => ch_k,
              code => code, valid => open, k_err => open, rd => open);

  u_gb : entity work.tx_gearbox
    port map (clk => clk_sys, rst => rst, char_en => char_en, code => code, bits => tx_bits);

  u_txphy : entity work.tx_phy
    port map (clk_fast => clk_fast, clk_sys => clk_sys, rst => rst, bits => tx_bits,
              td_p => td_p, td_n => td_n);

  ------------------------------------------------------------------------------
  -- Wire
  ------------------------------------------------------------------------------
  rd_p <= transport td_p after dly;
  rd_n <= transport td_n after dly;

  ------------------------------------------------------------------------------
  -- Receive side
  ------------------------------------------------------------------------------
  u_rxphy : entity work.rx_phy
    port map (clk_fast => clk_fast, clk_sys => clk_sys, rst => rst,
              rd_p => rd_p, rd_n => rd_n, samples => samples);

  u_cdr : entity work.cdr_os4x8
    port map (clk => clk_sys, rst => rst, samples => samples, bits => bits, nbits => nbits,
              phase => phase, shift_up => open, shift_dn => open, activity => open);

  u_al : entity work.comma_align
    port map (clk => clk_sys, rst => rst, restart => restart, in_bits => bits, in_n => nbits,
              sym => sym, sym_valid => sym_valid, sym_comma => sym_comma,
              dec_valid => dec_valid, dec_err => dec_err,
              sync => sync, ev_realign => open, ev_sync_loss => open);

  u_dec : entity work.dec_8b10b
    port map (clk => clk_sys, rst => rst, en => sym_valid, code => sym,
              data => dec_data, k => dec_k, valid => dec_valid,
              code_err => dec_cerr, disp_err => dec_derr, rd => open);

  dec_err <= dec_cerr or dec_derr;

  ------------------------------------------------------------------------------
  -- Stimulus and checks
  ------------------------------------------------------------------------------
  process
    type t_byte_arr is array (0 to 15) of std_logic_vector(7 downto 0);
    type t_sl_arr   is array (0 to 15) of std_logic;
    variable first_d : t_byte_arr;
    variable first_k : t_sl_arr;
    variable n, pos, errs, n_bad2, n_match : natural;
    variable ok      : boolean;
    variable t_start : time;
    variable locked  : boolean;
  begin
    rst <= '1';
    for i in 1 to 8 loop
      wait until rising_edge(clk_sys);
    end loop;
    rst <= '0';

    for p in WIRE_DLY'range loop
      ph_no <= p;
      dly   <= WIRE_DLY(p);
      wait until rising_edge(clk_sys);
      restart <= '1';
      wait until rising_edge(clk_sys);
      restart <= '0';
      wait for 1 ns;                        -- sync updated after the edge

      -- 1. sync
      t_start := now;
      while sync = '0' and now - t_start < 5 us loop
        wait until rising_edge(clk_sys);
      end loop;
      check(sync = '1', "phase " & integer'image(p) & ": sync acquired");
      report "phase " & integer'image(p) & ": sync after " & time'image(now - t_start);

      -- 2. character sequence, 3. two bits per clock
      n := 0; errs := 0; n_bad2 := 0; locked := false; pos := 0;
      while n < 16 + N_CHK and now - t_start < 150 us loop
        wait until rising_edge(clk_sys);
        if nbits /= 2 then
          n_bad2 := n_bad2 + 1;
        end if;
        if dec_valid = '1' then
          if dec_err = '1' then
            errs := errs + 1;
          end if;
          if n < 16 then
            first_d(n) := dec_data;
            first_k(n) := dec_k;
            if n = 15 then
              -- locate the 16 characters in the source sequence
              n_match := 0;
              for i in 0 to 8 * 256 - 1 loop
                ok := true;
                for m in 0 to 15 loop
                  if first_d(m) /= src_data(i + m) or first_k(m) /= src_k(i + m) then
                    ok := false;
                    exit;
                  end if;
                end loop;
                if ok then
                  n_match := n_match + 1;
                  pos := i + 16;
                end if;
              end loop;
              check_equal(n_match, 1, "phase " & integer'image(p) & ": position in the source sequence");
              locked := n_match = 1;
            end if;
          elsif locked then
            if dec_data /= src_data(pos) or dec_k /= src_k(pos) then
              errs := errs + 1;
            end if;
            pos := pos + 1;
          end if;
          n := n + 1;
        end if;
      end loop;
      check_equal(n, 16 + N_CHK, "phase " & integer'image(p) & ": characters received");
      check_equal(errs, 0, "phase " & integer'image(p) & ": character errors");
      check_equal(n_bad2, 0, "phase " & integer'image(p) & ": clocks with nbits /= 2");
      report "phase " & integer'image(p) & ": wire delay " & time'image(WIRE_DLY(p)) &
             ", CDR phase " & integer'image(to_integer(phase));
    end loop;

    stop <= true;
    tb_finish("tb_phy_loopback");
    wait;
  end process;

end architecture sim;
