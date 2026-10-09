// SFP-xSPI Bridge - timing constraints (doc/vhdl/top.md, section "Ograniczenia czasowe")
//
// Clocks:
//   clk_25m  - reference oscillator (pin 35)
//   clk_fast - rPLL output, 200 MHz (FCLK of IDES8 / OSER8)
//   clk_sys  - CLKDIV /4, 50 MHz (ADR 0007)
//   clk_spi  - XSPI_SCLK pin, <= 40 MHz (ADR 0009)
//   clk_host - DCS output (host_clk): SCLK in the xSPI mode, clk_sys in the
//              UART / echo modes and during reset. Constrained as SCLK; the
//              UART / echo paths are checked by a separate build with a
//              20 ns clk_host (doc/vhdl/top.md).

create_clock -name clk_25m -period 40.000 [get_ports {clk_25m}]
create_generated_clock -name clk_fast -source [get_ports {clk_25m}] -multiply_by 8 [get_pins {u_clk/u_pll/CLKOUT}]
create_generated_clock -name clk_sys -source [get_pins {u_clk/u_pll/CLKOUT}] -divide_by 4 [get_pins {u_clk/u_div/CLKOUT}]

create_clock -name clk_spi -period 25.000 [get_ports {xspi_sclk}]
create_generated_clock -name clk_host -source [get_ports {xspi_sclk}] -divide_by 1 [get_pins {u_hclk/u_dcs/CLKOUT}]

// Host side <-> clk_sys: async_fifo (Gray / stable pointers), CSR latch and
// WRITE_REG buffer (static while used, ADR 0009)
set_clock_groups -asynchronous -group [get_clocks {clk_spi clk_host}] -group [get_clocks {clk_25m clk_fast clk_sys}]

// xSPI pins (mode 0), delays relative to the falling SCLK edge (host launches
// data at the falling edge; outputs change at the falling edge, ADR 0009)
set_input_delay -clock clk_spi -clock_fall -max 4.0 [get_ports {xspi_io[*] xspi_cs_n}]
set_input_delay -clock clk_spi -clock_fall -min 0.0 [get_ports {xspi_io[*] xspi_cs_n}]
set_output_delay -clock clk_spi -clock_fall -max 3.0 [get_ports {xspi_io[*]}]
set_output_delay -clock clk_spi -clock_fall -min -1.0 [get_ports {xspi_io[*]}]
