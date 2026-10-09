# vhdl

Projekt FPGA mostka SFP-xSPI w Gowin EDA: VHDL-2008, synteza GowinSynthesis, układ GW1N-UV9QN48C6/I5 (GW1N-9C, `gw1n9c-003`).

```
constraints/
  sfp_bridge.cst           przydział pinów i standardy I/O
  sfp_bridge.sdc           ograniczenia czasowe (zegary, grupy asynchroniczne, opóźnienia xSPI)
sfp_bridge/
  sfp_bridge.gprj          projekt Gowin EDA
  build.tcl                budowa wsadowa (gw_sh)
  impl/                    wyniki syntezy i PnR (ignorowane), poza sfp_bridge_process_config.json
  src/pkg/                 bridge_pkg (stałe), code8b10b_pkg (kod 8b/10b)
  src/common/              sync_bit, reset_sync
  src/clk/                 clk_rst (rPLL, CLKDIV, resety), host_clk (DCS)
  src/fifo/                async_fifo
  src/link/                crc32, 8b/10b, tx_framer, rx_deframer, tx_gearbox, tx_phy, rx_phy,
                           cdr_os4x8, comma_align, link_ctrl
  src/uart/                uart_rx, uart_tx, uart_bridge
  src/host/                xspi_slave, csr_regs, frame_echo
  src/mgmt/                i2c_master, sfp_mgmt, leds
  src/top/                 sfp_bridge_top
sim/
  tb/                      testbenche tb_<moduł>.vhd, tb_pkg, e2e_bench (testy end-to-end)
  waves/                   widoki GTKWave (.gtkw)
  sources.txt              kolejność kompilacji do symulacji
  run_tests.ps1 / .sh      uruchamianie testów (GHDL)
  view.ps1                 podgląd przebiegu w GTKWave
  wave_svg.py              rysunki przebiegów testów end-to-end (doc/e2e/img)
  datasheet_svg.py         diagramy datasheetu (doc/datasheet/img)
```

Ustawienia projektu (`impl/sfp_bridge_process_config.json`): VHDL-2008, top `sfp_bridge_top`, piny MSPI jako GPIO (`-use_mspi_as_gpio 1`), konfiguracja AUTOBOOT.

## Budowa

```
cd sfp_bridge
gw_sh build.tcl
```

Bitstream: `sfp_bridge/impl/pnr/sfp_bridge.fs`.

## Symulacja

GHDL 5 (VHDL-2008); na Windows `run_tests.ps1` uruchamia `run_tests.sh` w WSL. Moduły z prymitywami Gowin korzystają z modeli producenta kompilowanych do biblioteki `gw1n`.

| Zmienna | Znaczenie |
|---|---|
| `GOWIN_SIMLIB` | katalog modeli symulacyjnych Gowin EDA: `<Gowin EDA>/IDE/simlib/gw1n` (wymagana) |
| `GHDL_WSL_DISTRO` | dystrybucja WSL z GHDL (domyślnie dystrybucja domyślna) |
| `GTKWAVE` | ścieżka do `gtkwave.exe` dla `view.ps1` (domyślnie `gtkwave` z `PATH`) |

```
cd sim
.\run_tests.ps1               # wszystkie testbenche
.\run_tests.ps1 tb_crc32      # wybrany testbench
.\view.ps1 tb_crc32           # przebieg w GTKWave
```

Opis modułów, wyniki testów i syntezy: [`../doc/vhdl/index.md`](../doc/vhdl/index.md); testy end-to-end: [`../doc/e2e/index.md`](../doc/e2e/index.md).
