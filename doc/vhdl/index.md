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
    src/link/             tor łącza: crc32, enc_8b10b, dec_8b10b, ...
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
| `tx_framer`, `rx_deframer` | — | — | — | — | planowany |
| `cdr_os4`, `comma_align` | — | — | — | — | planowany |
| `tx_phy`, `rx_phy`, `clk_rst` | — | — | — | — | planowany (prymitywy Gowin) |
| `link_ctrl` | — | — | — | — | planowany |
| `uart_rx`, `uart_tx`, `uart_bridge` | — | — | — | — | planowany ([ADR 0006](../adr/0006-tryb-uart-przezroczysty.md)) |
| `i2c_master`, `sfp_mgmt` | — | — | — | — | planowany |
| `xspi_slave`, `csr_regs` | — | — | — | — | planowany |
| `leds` | — | — | — | — | planowany |

Próbna synteza modułów z tabeli (wszystkie razem, GW1N-9C, Gowin EDA 1.9.11.03): 174 LUT, 63 rejestry, 1 BSRAM (tablica dekodera 8b/10b), Fmax 125,7 MHz przy docelowym `clk_sys` = 100 MHz.
