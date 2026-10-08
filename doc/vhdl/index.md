# Projekt FPGA (VHDL)

Kod FPGA jest pisany w VHDL-2008 dla układu GW1N-UV9QN48C6/I5 (GW1N-9C) i syntezowany w Gowin EDA (GowinSynthesis). Każdy moduł ma samosprawdzający testbench uruchamiany w GHDL ([ADR 0003](../adr/0003-weryfikacja-ghdl.md)) oraz opis na osobnej stronie.

## Struktura katalogów

```
vhdl/
  constraints/            sfp_bridge.cst (piny), sfp_bridge.sdc (zegary) — wspólne
  sfp_bridge/             projekt docelowy Gowin EDA
    src/pkg/              pakiety: bridge_pkg (stałe), code8b10b_pkg (kod 8b/10b)
    src/common/           elementy ogólne: sync_bit, reset_sync
    src/fifo/             async_fifo
    src/link/             tor łącza: crc32, 8b/10b, ramkowanie, CDR, wyrównanie, PHY
    src/top/              sfp_bridge_top
  sfp_bridge_testled/     projekt testowy: miganie LED
  sim/
    tb/                   testbenche (tb_<moduł>.vhd) i tb_pkg
    waves/                widoki GTKWave (.gtkw)
    sources.txt           kolejność kompilacji do symulacji
    run_tests.ps1 / .sh   uruchamianie testów
    view.ps1              podgląd przebiegu w GTKWave
```

## Stan modułów

| Moduł | Plik | Testbench | Wynik | Synteza (próbna) | Opis |
|---|---|---|---|---|---|
| `bridge_pkg` | `src/pkg/bridge_pkg.vhd` | — | — | tak | stałe projektu |
| `code8b10b_pkg` | `src/pkg/code8b10b_pkg.vhd` | `tb_8b10b` | PASS | tak | [8b/10b](8b10b.md) |
| `sync_bit` | `src/common/sync_bit.vhd` | `tb_sync` | PASS | tak | [Synchronizatory](sync.md) |
| `reset_sync` | `src/common/reset_sync.vhd` | `tb_sync` | PASS | tak | [Synchronizatory](sync.md) |
| `crc32` | `src/link/crc32.vhd` | `tb_crc32` | PASS | tak | [CRC-32](crc32.md) |
| `enc_8b10b` | `src/link/enc_8b10b.vhd` | `tb_8b10b` | PASS | tak | [8b/10b](8b10b.md) |
| `dec_8b10b` | `src/link/dec_8b10b.vhd` | `tb_8b10b` | PASS | tak | [8b/10b](8b10b.md) |
| `async_fifo` | `src/fifo/async_fifo.vhd` | `tb_async_fifo` | PASS | tak (101 MHz, 2 BSRAM) | [FIFO](async_fifo.md) |
| `tx_framer`, `rx_deframer` | `src/link/tx_framer.vhd`, `rx_deframer.vhd` | `tb_link_frames` | PASS | tak (70 MHz) | [Ramkowanie](framing.md) |
| `cdr_os4x8` | `src/link/cdr_os4x8.vhd` | `tb_cdr_os4x8` | PASS | tak (74 MHz) | [Odzysk danych](cdr.md) |
| `comma_align` | `src/link/comma_align.vhd` | `tb_comma_align` | PASS | tak (tor RX 83 MHz) | [Wyrównanie symboli](comma_align.md) |
| `tx_gearbox`, `tx_phy`, `rx_phy` | `src/link/tx_gearbox.vhd`, `tx_phy.vhd`, `rx_phy.vhd` | `tb_phy_loopback`, `tb_link_loopback` | PASS | tak (z PLL i IDES8/OSER8, 75 MHz) | [Warstwa fizyczna](phy.md) |
| `clk_rst` | — | — | — | — | planowany (rPLL, CLKDIV) |
| `link_ctrl` | `src/link/link_ctrl.vhd` | `tb_link_ctrl`, `tb_link_loopback` | PASS | tak (113 MHz) | [Sterowanie łączem](link_ctrl.md) |
| `uart_rx`, `uart_tx`, `uart_bridge` | — | — | — | — | planowany ([ADR 0006](../adr/0006-tryb-uart-przezroczysty.md)) |
| `i2c_master`, `sfp_mgmt` | — | — | — | — | planowany |
| `xspi_slave`, `csr_regs` | — | — | — | — | planowany |
| `leds` | — | — | — | — | planowany |

**Zegary** ([ADR 0007](../adr/0007-zegar-systemowy-50mhz.md)): `clk_sys` = 50 MHz (PCLK serializerów IDES8/OSER8), `clk_fast` = 200 MHz tylko w blokach I/O. Kryterium dla modułów domeny `clk_sys`: Fmax ≥ 50 MHz z zapasem (cel ≥ 60 MHz). Symbol 8b/10b = 5 taktów `clk_sys`.

Próbne syntezy (GW1N-9C, Gowin EDA 1.9.11.03): synchronizatory + CRC + 8b/10b — 174 LUT, 1 BSRAM, 125,7 MHz; FIFO 4096 × 8 — 101 MHz; tor znakowy jednej strony łącza (FIFO TX 4 KiB, framer, koder, dekoder, deframer, FIFO RX 8 KiB) — 1104 LUT, 7 BSRAM, 70 MHz; tor odbiorczy bitowy (`cdr_os4x8`, `comma_align`, `dec_8b10b`) — 436 LUT/ALU, 1 BSRAM, 83 MHz.
