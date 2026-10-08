--------------------------------------------------------------------------------
-- i2c_master
--
-- I2C (2-wire) master for the SFP module interface (INF-8074i, SFF-8472):
-- standard mode, 100 kHz, 7-bit addresses, open-drain outputs (scl_oe /
-- sda_oe = '1' pulls the line low), clock stretching by the slave.
--
-- Commands (start pulse while busy = '0', parameters sampled with start):
--   read  (rd = '1'): S  dev+W  offset  Sr  dev+R  len bytes (ACK, last NACK)  P
--   write (rd = '0'): S  dev+W  offset  len bytes  P
-- len = 1..128. Received bytes appear on rx_data with rx_idx and a
-- one-cycle rx_valid; bytes to send are read from tx_data at tx_idx
-- (asynchronous buffer read, tx_idx is stable for the whole byte).
-- A NACK of an address or data byte ends the command with a STOP and
-- nack = '1'. done pulses once at the end; nack / timeout are valid from
-- done until the next start.
--
-- Bit timing: one SCL period = 4 quarters of CLK_HZ / (4 * I2C_HZ) cycles
-- (2.5 us at 100 kHz). SCL low 2 quarters, SDA changed after the first;
-- SCL released, high time counted from the moment SCL is seen high (clock
-- stretching, rise time), SDA sampled 1 quarter later. START / Sr hold and
-- setup 2 quarters, STOP setup 2 quarters, bus free after STOP 2 quarters
-- (all >= the standard-mode minimums of 4.0 / 4.7 us).
--
-- Bus check before START: SCL low -> wait (timeout); SDA low (a slave
-- left in the middle of a read) -> SCL pulses with SDA released until SDA
-- is high, then STOP and a new check (a slave sending a '1' bit may still
-- pull SDA low after it; the pulses continue in the next round). SCL held
-- low for longer than TIMEOUT_CLKS, or SDA still low after REC_MAX pulses
-- in total, ends the command with timeout = '1' and both lines released.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity i2c_master is
  generic (
    CLK_HZ       : positive := 50_000_000;
    I2C_HZ       : positive := 100_000;
    TIMEOUT_CLKS : positive := 1_250_000          -- 25 ms at 50 MHz
  );
  port (
    clk      : in  std_logic;
    rst      : in  std_logic;
    -- command
    start    : in  std_logic;
    rd       : in  std_logic;
    dev      : in  std_logic_vector(6 downto 0);
    offset   : in  std_logic_vector(7 downto 0);
    len      : in  unsigned(7 downto 0);          -- 1..128
    busy     : out std_logic;
    done     : out std_logic;
    nack     : out std_logic;
    timeout  : out std_logic;
    -- data
    tx_idx   : out unsigned(6 downto 0);
    tx_data  : in  std_logic_vector(7 downto 0);
    rx_idx   : out unsigned(6 downto 0);
    rx_data  : out std_logic_vector(7 downto 0);
    rx_valid : out std_logic;
    -- bus (pins: scl_i / sda_i asynchronous)
    scl_i    : in  std_logic;
    sda_i    : in  std_logic;
    scl_oe   : out std_logic;
    sda_oe   : out std_logic
  );
end entity i2c_master;

architecture rtl of i2c_master is

  constant QCLKS   : positive := CLK_HZ / (4 * I2C_HZ);
  constant REC_MAX : positive := 18;               -- recovery SCL pulses (2 bytes)

  type t_state is (ST_IDLE, ST_CHK, ST_REC, ST_START, ST_BIT, ST_RESTART, ST_STOP, ST_END);
  type t_seq is (Q_DEVW, Q_OFF, Q_DEVR, Q_WDATA, Q_RDATA);

  signal state   : t_state := ST_IDLE;
  signal seq     : t_seq := Q_DEVW;
  signal ph      : natural range 0 to 5 := 0;
  signal bitn    : natural range 0 to 8 := 0;
  signal qcnt    : natural range 0 to 2 * QCLKS - 1 := 0;
  signal hold_hi : std_logic := '0';               -- waiting for SCL high
  signal tmo_cnt : natural range 0 to TIMEOUT_CLKS - 1 := 0;
  signal rec_n   : natural range 0 to REC_MAX := 0;
  signal rec_stop : std_logic := '0';              -- STOP of a recovery round
  signal scl_drv, sda_drv : std_logic := '0';
  signal scl_s, sda_s : std_logic;

  signal rd_q    : std_logic := '0';
  signal dev_q   : std_logic_vector(6 downto 0) := (others => '0');
  signal off_q   : std_logic_vector(7 downto 0) := (others => '0');
  signal last_q  : unsigned(6 downto 0) := (others => '0');   -- len - 1
  signal cnt     : unsigned(6 downto 0) := (others => '0');
  signal txb     : std_logic_vector(7 downto 0) := (others => '0');
  signal rxsh    : std_logic_vector(7 downto 0) := (others => '0');
  signal busy_q, done_q, nack_q, tmo_q, rxv_q : std_logic := '0';

begin

  u_scl : entity work.sync_bit generic map (STAGES => 2, INIT_VAL => '1')
    port map (clk => clk, d => scl_i, q => scl_s);
  u_sda : entity work.sync_bit generic map (STAGES => 2, INIT_VAL => '1')
    port map (clk => clk, d => sda_i, q => sda_s);

  process (clk)
    variable b   : std_logic_vector(7 downto 0);
    variable nxt : std_logic_vector(7 downto 0);
  begin
    if rising_edge(clk) then
      done_q <= '0';
      rxv_q  <= '0';

      if rst = '1' then
        state   <= ST_IDLE;
        ph      <= 0;
        qcnt    <= 0;
        hold_hi <= '0';
        scl_drv <= '0';
        sda_drv <= '0';
        busy_q  <= '0';
        nack_q  <= '0';
        tmo_q   <= '0';

      elsif state = ST_IDLE then
        if start = '1' then
          rd_q    <= rd;
          dev_q   <= dev;
          off_q   <= offset;
          last_q  <= resize(len - 1, 7);
          busy_q  <= '1';
          nack_q  <= '0';
          tmo_q   <= '0';
          rec_n   <= 0;
          rec_stop <= '0';
          state   <= ST_CHK;
          ph      <= 0;
          qcnt    <= QCLKS - 1;
        end if;

      elsif hold_hi = '1' then
        -- released SCL: wait until it is high (stretching), then 1 quarter
        if scl_s = '1' then
          hold_hi <= '0';
          tmo_cnt <= 0;
          qcnt    <= QCLKS - 1;
        elsif tmo_cnt = TIMEOUT_CLKS - 1 then
          hold_hi <= '0';
          scl_drv <= '0';
          sda_drv <= '0';
          tmo_q   <= '1';
          state   <= ST_END;
          qcnt    <= 0;
        else
          tmo_cnt <= tmo_cnt + 1;
        end if;

      elsif qcnt /= 0 then
        qcnt <= qcnt - 1;

      else
        -- one step of the current state, then (usually) wait 1 quarter
        qcnt <= QCLKS - 1;
        case state is

          when ST_CHK =>                         -- bus free check
            if ph = 0 then
              ph <= 1;
            elsif scl_s = '0' then
              hold_hi <= '1';                    -- SCL held low: wait, timeout
              tmo_cnt <= 0;
            elsif sda_s = '0' then
              if rec_n = REC_MAX then            -- still stuck after recovery
                tmo_q <= '1';
                state <= ST_END;
                qcnt  <= 0;
              else
                state <= ST_REC;
                ph    <= 0;
              end if;
            else
              state <= ST_START;
              ph    <= 0;
            end if;

          when ST_REC =>                         -- SCL pulses, SDA released
            case ph is
              when 0 =>
                scl_drv <= '1';
                qcnt    <= 2 * QCLKS - 1;
                ph      <= 1;
              when 1 =>
                scl_drv <= '0';
                hold_hi <= '1';
                tmo_cnt <= 0;
                rec_n   <= rec_n + 1;
                ph      <= 2;
              when others =>
                if sda_s = '1' then
                  rec_stop <= '1';
                  state    <= ST_STOP;
                  ph       <= 0;
                elsif rec_n = REC_MAX then
                  tmo_q <= '1';
                  state <= ST_END;
                  qcnt  <= 0;
                else
                  ph <= 0;
                end if;
            end case;

          when ST_START =>                       -- SDA low while SCL high
            sda_drv <= '1';
            qcnt    <= 2 * QCLKS - 1;
            state   <= ST_BIT;
            seq     <= Q_DEVW;
            bitn    <= 0;
            ph      <= 0;

          when ST_BIT =>
            case ph is
              when 0 =>                          -- SCL low; load the byte
                scl_drv <= '1';
                if bitn = 0 then
                  case seq is
                    when Q_DEVW  => txb <= dev_q & '0';
                    when Q_OFF   => txb <= off_q;
                    when Q_DEVR  => txb <= dev_q & '1';
                    when Q_WDATA => txb <= tx_data;
                    when Q_RDATA => txb <= (others => '1');
                  end case;
                end if;
                ph <= 1;
              when 1 =>                          -- data or (N)ACK on SDA
                if bitn = 8 then
                  if seq = Q_RDATA and cnt /= last_q then
                    sda_drv <= '1';              -- ACK
                  else
                    sda_drv <= '0';              -- release: NACK / slave ACK
                  end if;
                elsif seq = Q_RDATA then
                  sda_drv <= '0';
                else
                  sda_drv <= not txb(7 - bitn);
                end if;
                ph <= 2;
              when 2 =>                          -- release SCL
                scl_drv <= '0';
                hold_hi <= '1';
                tmo_cnt <= 0;
                ph      <= 3;
              when others =>                     -- sample, next bit / byte
                ph <= 0;
                if bitn < 8 then
                  nxt := rxsh(6 downto 0) & sda_s;
                  rxsh <= nxt;
                  if bitn = 7 and seq = Q_RDATA then
                    rx_data <= nxt;
                    rxv_q   <= '1';
                  end if;
                  bitn <= bitn + 1;
                else
                  bitn <= 0;
                  if seq /= Q_RDATA and sda_s = '1' then
                    nack_q <= '1';               -- byte not acknowledged
                    state  <= ST_STOP;
                  else
                    case seq is
                      when Q_DEVW =>
                        seq <= Q_OFF;
                      when Q_OFF =>
                        cnt <= (others => '0');
                        if rd_q = '1' then
                          state <= ST_RESTART;
                        else
                          seq <= Q_WDATA;
                        end if;
                      when Q_DEVR =>
                        seq <= Q_RDATA;
                      when Q_WDATA | Q_RDATA =>
                        if cnt = last_q then
                          state <= ST_STOP;
                        else
                          cnt <= cnt + 1;
                        end if;
                    end case;
                  end if;
                end if;
            end case;

          when ST_RESTART =>                     -- entered with SCL high
            case ph is
              when 0 =>
                scl_drv <= '1';
                ph      <= 1;
              when 1 =>
                sda_drv <= '0';
                ph      <= 2;
              when 2 =>
                scl_drv <= '0';
                hold_hi <= '1';
                tmo_cnt <= 0;
                ph      <= 3;
              when 3 =>
                ph <= 4;                         -- setup: 2 quarters from SCL high
              when others =>
                sda_drv <= '1';                  -- Sr
                qcnt    <= 2 * QCLKS - 1;
                state   <= ST_BIT;
                seq     <= Q_DEVR;
                bitn    <= 0;
                ph      <= 0;
            end case;

          when ST_STOP =>                        -- entered with SCL high
            case ph is
              when 0 =>
                scl_drv <= '1';
                ph      <= 1;
              when 1 =>
                sda_drv <= '1';
                ph      <= 2;
              when 2 =>
                scl_drv <= '0';
                hold_hi <= '1';
                tmo_cnt <= 0;
                ph      <= 3;
              when 3 =>
                ph <= 4;                         -- setup: 2 quarters from SCL high
              when 4 =>
                sda_drv <= '0';                  -- P
                qcnt    <= 2 * QCLKS - 1;        -- bus free time
                ph      <= 5;
              when others =>
                ph <= 0;
                if rec_stop = '1' then
                  rec_stop <= '0';               -- recovery STOP: check the bus again
                  state    <= ST_CHK;
                else
                  state <= ST_END;
                  qcnt  <= 0;
                end if;
            end case;

          when ST_END =>
            scl_drv <= '0';
            sda_drv <= '0';
            busy_q  <= '0';
            done_q  <= '1';
            state   <= ST_IDLE;
            qcnt    <= 0;

          when ST_IDLE =>
            null;
        end case;
      end if;
    end if;
  end process;

  busy     <= busy_q;
  done     <= done_q;
  nack     <= nack_q;
  timeout  <= tmo_q;
  tx_idx   <= cnt;
  rx_idx   <= cnt;
  rx_valid <= rxv_q;
  scl_oe   <= scl_drv;
  sda_oe   <= sda_drv;

end architecture rtl;
