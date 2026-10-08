--------------------------------------------------------------------------------
-- frame_echo
--
-- Far-end loopback of whole frames (MODE_CTRL.FRAME_ECHO, ADR 0008 / 0009):
-- every frame received into the RX FIFO is copied unchanged into the TX
-- FIFO, so the remote end receives its own frames back. Works on the host
-- side of both FIFOs (clk_host = clk_sys in this mode), on the falling edge
-- like the FIFO host ports (async_fifo WR_FALLING / RD_FALLING).
--
-- Copy: one byte at a time - read from the RX FIFO when it is not empty and
-- the TX FIFO is not full, write the byte when it arrives; the frame is
-- committed with its last byte (length from the TYPE LEN_H LEN_L header).
-- The RX FIFO holds complete frames only, so a started frame is always
-- available; the TX side stalls while full (no data loss). The TX FIFO must
-- hold the largest frame (MAX_LEN + 3), otherwise a frame can never be
-- committed. 4 clock cycles
-- per byte (12.5 MB/s at 50 MHz), more than the link rate (10 MB/s).
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity frame_echo is
  port (
    clk       : in  std_logic;                     -- clk_host (falling edge)
    rst       : in  std_logic;
    en        : in  std_logic;                     -- echo mode
    -- RX FIFO read side
    rx_rd     : out std_logic;
    rx_data   : in  std_logic_vector(7 downto 0);
    rx_valid  : in  std_logic;
    rx_empty  : in  std_logic;
    -- TX FIFO write side
    tx_wr     : out std_logic;
    tx_data   : out std_logic_vector(7 downto 0);
    tx_commit : out std_logic;
    tx_full   : in  std_logic;
    ev_frame  : out std_logic                      -- pulse: frame copied
  );
end entity frame_echo;

architecture rtl of frame_echo is

  signal idx     : natural range 0 to 3 := 0;     -- 0 TYPE, 1 LEN_H, 2 LEN_L, 3 payload
  signal len_h   : std_logic_vector(7 downto 0) := (others => '0');
  signal left    : unsigned(15 downto 0) := (others => '0');
  signal pend    : std_logic := '0';               -- read issued, byte arrives next cycle
  signal rd_q    : std_logic := '0';
  signal wr_q    : std_logic := '0';
  signal cm_q    : std_logic := '0';
  signal d_q     : std_logic_vector(7 downto 0) := (others => '0');
  signal fr_q    : std_logic := '0';

begin

  process (clk)
    variable last : boolean;
    variable len  : unsigned(15 downto 0);
  begin
    if falling_edge(clk) then
      rd_q <= '0';
      wr_q <= '0';
      cm_q <= '0';
      fr_q <= '0';
      if rst = '1' then
        idx  <= 0;
        pend <= '0';
      else
        -- write the byte read in the previous cycle
        if rx_valid = '1' then
          last := false;
          case idx is
            when 0 => idx <= 1;
            when 1 => len_h <= rx_data; idx <= 2;
            when 2 =>
              len := unsigned(len_h) & unsigned(rx_data);
              left <= len;
              if len = 0 then last := true; idx <= 0; else idx <= 3; end if;
            when others =>
              left <= left - 1;
              if left = 1 then last := true; idx <= 0; end if;
          end case;
          wr_q <= '1';
          d_q  <= rx_data;
          if last then
            cm_q <= '1';
            fr_q <= '1';
          end if;
        end if;

        -- read the next byte (one in flight; the write of the previous
        -- byte is accounted for by tx_full one cycle later, so read only
        -- when no write is pending either)
        pend <= '0';
        if en = '1' and pend = '0' and rx_valid = '0' and wr_q = '0'
           and rx_empty = '0' and tx_full = '0' then
          rd_q <= '1';
          pend <= '1';
        end if;
      end if;
    end if;
  end process;

  rx_rd     <= rd_q;
  tx_wr     <= wr_q;
  tx_data   <= d_q;
  tx_commit <= cm_q;
  ev_frame  <= fr_q;

end architecture rtl;
