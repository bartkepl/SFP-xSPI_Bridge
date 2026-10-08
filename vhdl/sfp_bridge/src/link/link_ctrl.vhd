--------------------------------------------------------------------------------
-- link_ctrl
--
-- Link control (ADR 0008): link state, SFP loss of signal, transmit gating,
-- event counters and the near-end loopback, in the clk_sys domain.
--
-- Link state (registered):
--   DOWN : LOS (unless cfg_los_ignore) or module absent (sfp_mod_abs), or no
--          character synchronization (rx_sync = '0')
--   SYNC : rx_sync = '1', the remote sends idle /R/ (remote_ready = '0')
--   UP   : rx_sync = '1', remote_ready = '1'
--   In the near-end loopback the SFP signals are ignored (test without a
--   module).
--
-- Control outputs:
--   align_restart : comma_align restart while LOS / module absent (unless
--                   ignored) and for one clock when the loopback mode changes
--   rx_ready      : to tx_framer: our receiver is synchronized and enabled
--                   ('0' -> idle /R/ to the remote side)
--   tx_hold       : to tx_framer (xoff_remote input): no new frame unless the
--                   link is UP, the remote sends XON and cfg_tx_en = '1'
--
-- Counters (index constants CNT_* in bridge_pkg): CNT_W bits, wrap-around,
-- cleared while cnt_clr = '1'; events are registered once before counting.
--   CODE_ERR    dec_valid and (code_err or disp_err) while rx_sync = '1'
--   CRC_ERR, LEN_ERR, FRAMING_ERR, RX_OVF, FRAMES_RX : rx_deframer events
--   FRAMES_TX   tx_framer frame_sent
--   SYNC_LOSS   comma_align ev_sync_loss
--
-- Near-end loopback (cfg_loopback = LB_NEAR): the bits of tx_gearbox replace
-- the IDES8 samples at the input of cdr_os4x8, each bit repeated 4 times.
-- Both paths have one register stage. LB_FAR (frame echo) is implemented at
-- the host side of the FIFOs (top-level); here it behaves as LB_NONE.
--
-- Inputs from the SFP pins must be synchronized to clk_sys (sync_bit).
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.bridge_pkg.all;

entity link_ctrl is
  generic (
    CNT_W : positive range 2 to 32 := 32       -- counter width (reduced only for tests)
  );
  port (
    clk            : in  std_logic;
    rst            : in  std_logic;
    -- configuration (CSR CTRL, clk_sys domain)
    cfg_tx_en      : in  std_logic;
    cfg_rx_en      : in  std_logic;
    cfg_los_ignore : in  std_logic;
    cfg_loopback   : in  std_logic_vector(1 downto 0);
    cnt_clr        : in  std_logic;
    -- SFP status (synchronized)
    sfp_los        : in  std_logic;
    sfp_mod_abs    : in  std_logic;
    -- receive chain
    rx_sync        : in  std_logic;            -- comma_align sync
    remote_ready   : in  std_logic;            -- rx_deframer
    xoff_remote    : in  std_logic;            -- rx_deframer
    dec_valid      : in  std_logic;            -- dec_8b10b
    dec_code_err   : in  std_logic;
    dec_disp_err   : in  std_logic;
    -- events (one-cycle pulses)
    ev_crc_err     : in  std_logic;
    ev_len_err     : in  std_logic;
    ev_framing     : in  std_logic;
    ev_ovf         : in  std_logic;
    ev_frame_ok    : in  std_logic;
    ev_frame_sent  : in  std_logic;            -- tx_framer frame_sent
    ev_sync_loss   : in  std_logic;            -- comma_align
    -- near-end loopback data path
    phy_samples    : in  std_logic_vector(7 downto 0);   -- from rx_phy
    tx_bits        : in  std_logic_vector(1 downto 0);   -- from tx_gearbox
    cdr_samples    : out std_logic_vector(7 downto 0);   -- to cdr_os4x8
    -- control
    align_restart  : out std_logic;
    rx_ready       : out std_logic;
    tx_hold        : out std_logic;
    -- status
    link_state     : out t_link_state;
    link_up        : out std_logic;
    link_chg       : out std_logic;            -- pulse: link_state changed
    activity       : out std_logic;            -- pulse: frame sent or received
    counters       : out t_cnt_arr
  );
end entity link_ctrl;

architecture rtl of link_ctrl is

  type t_cnt_int is array (0 to N_CNT - 1) of unsigned(CNT_W - 1 downto 0);

  signal state    : t_link_state := LS_DOWN;
  signal lb_q     : std_logic_vector(1 downto 0) := LB_NONE;
  signal restart  : std_logic := '1';
  signal chg_q    : std_logic := '0';
  signal act_q    : std_logic := '0';
  signal smp_q    : std_logic_vector(7 downto 0) := (others => '0');
  signal inc      : std_logic_vector(N_CNT - 1 downto 0) := (others => '0');
  signal cnt      : t_cnt_int := (others => (others => '0'));

begin

  process (clk)
    variable near    : boolean;
    variable sfp_bad : boolean;
    variable nxt     : t_link_state;
  begin
    if rising_edge(clk) then
      chg_q <= '0';
      act_q <= '0';

      if rst = '1' then
        state   <= LS_DOWN;
        lb_q    <= LB_NONE;
        restart <= '1';
        smp_q   <= (others => '0');
        inc     <= (others => '0');
        cnt     <= (others => (others => '0'));
      else
        near    := cfg_loopback = LB_NEAR;
        sfp_bad := not near and ((sfp_los = '1' and cfg_los_ignore = '0') or sfp_mod_abs = '1');

        ------------------------------------------------------------------------
        -- Link state
        ------------------------------------------------------------------------
        if sfp_bad or rx_sync = '0' then
          nxt := LS_DOWN;
        elsif remote_ready = '0' then
          nxt := LS_SYNC;
        else
          nxt := LS_UP;
        end if;
        state <= nxt;
        if nxt /= state then
          chg_q <= '1';
        end if;

        -- comma_align restart: SFP signal lost, or loopback mode changed
        lb_q    <= cfg_loopback;
        restart <= '0';
        if sfp_bad or cfg_loopback /= lb_q then
          restart <= '1';
        end if;

        ------------------------------------------------------------------------
        -- Near-end loopback multiplexer
        ------------------------------------------------------------------------
        if near then
          smp_q <= (7 downto 4 => tx_bits(1), 3 downto 0 => tx_bits(0));
        else
          smp_q <= phy_samples;
        end if;

        ------------------------------------------------------------------------
        -- Counters
        ------------------------------------------------------------------------
        inc(CNT_CODE_ERR)    <= dec_valid and (dec_code_err or dec_disp_err) and rx_sync;
        inc(CNT_CRC_ERR)     <= ev_crc_err;
        inc(CNT_LEN_ERR)     <= ev_len_err;
        inc(CNT_FRAMING_ERR) <= ev_framing;
        inc(CNT_RX_OVF)      <= ev_ovf;
        inc(CNT_FRAMES_TX)   <= ev_frame_sent;
        inc(CNT_FRAMES_RX)   <= ev_frame_ok;
        inc(CNT_SYNC_LOSS)   <= ev_sync_loss;
        for i in 0 to N_CNT - 1 loop
          if cnt_clr = '1' then
            cnt(i) <= (others => '0');
          elsif inc(i) = '1' then
            cnt(i) <= cnt(i) + 1;
          end if;
        end loop;

        act_q <= ev_frame_sent or ev_frame_ok;
      end if;
    end if;
  end process;

  cdr_samples   <= smp_q;
  align_restart <= restart;
  rx_ready      <= '1' when rx_sync = '1' and cfg_rx_en = '1' else '0';
  tx_hold       <= '0' when state = LS_UP and xoff_remote = '0' and cfg_tx_en = '1' else '1';
  link_state    <= state;
  link_up       <= '1' when state = LS_UP else '0';
  link_chg      <= chg_q;
  activity      <= act_q;

  g_cnt : for i in 0 to N_CNT - 1 generate
    counters(i) <= resize(cnt(i), 32);
  end generate;

end architecture rtl;
