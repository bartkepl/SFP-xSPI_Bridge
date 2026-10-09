# Integracja: `sfp_bridge_top`, `leds`

Pliki: `vhdl/sfp_bridge/src/top/sfp_bridge_top.vhd`, `vhdl/sfp_bridge/src/mgmt/leds.vhd` · ograniczenia: `vhdl/constraints/sfp_bridge.cst`, `vhdl/constraints/sfp_bridge.sdc` · testy: `tb_leds`, testy end-to-end `tb_e2e_spi`, `tb_e2e_qspi`, `tb_e2e_ospi`, `tb_e2e_uart`, `tb_e2e_uart_reg` ([wyniki](../e2e/index.md))

## Struktura

```
CLK_25M ─> clk_rst (rPLL 200 MHz, CLKDIV 50 MHz, resety) ─> clk_fast, clk_sys, rst_sys, rst_hard, rst_por
XSPI_SCLK, clk_sys ─> host_clk (DCS) ─> clk_host

strona hosta (clk_host, zbocze opadające):
  xspi_slave | uart_bridge | frame_echo  <─>  FIFO TX 4 KiB, FIFO RX 8 KiB
strona łącza (clk_sys):
  FIFO TX ─> tx_framer ─> enc_8b10b ─> tx_gearbox ─> tx_phy ─> SFP_TD±
  SFP_RD± ─> rx_phy ─> link_ctrl ─> cdr_os4x8 ─> comma_align ─> dec_8b10b ─> rx_deframer ─> FIFO RX
csr_regs (rejestry), sfp_mgmt (I2C, DDM, sygnały SFP), leds
```

## Tryby pracy

| Tryb | Warunek | Piny J3 | `HOST_IRQ_N` | `clk_host` |
|---|---|---|---|---|
| UART | `MODE_SEL` = 0 (zworka) lub `MODE_CTRL.UART_MODE` | IO0 = `UART_RX`, IO1 = `UART_TX`; IO2 = `UART_RTS_N` i IO3 = `UART_CTS_N` przy `MODE_CTRL.RTSCTS_EN`; pozostałe w stanie wysokiej impedancji | stan łącza (1 = UP) | `clk_sys` |
| echo ramek | `MODE_CTRL.FRAME_ECHO`, poza trybem UART | wszystkie w stanie wysokiej impedancji | z `csr_regs` | `clk_sys` |
| xSPI | pozostałe przypadki | `xspi_slave` | z `csr_regs` | SCLK |

- `MODE_SEL` jest synchronizowany i próbkowany w czasie każdego resetu mostka (`rst_sys`), także programowego. Wartość odczytu `STATUS_FAST.MODE_SEL` to stan zatrzaśnięty.
- `XSPI_DQS` nie jest używany (SDR bez DQS) i pozostaje w stanie wysokiej impedancji.
- `CS_N` widziany przez `xspi_slave` i `csr_regs` jest w trybach UART i echa wymuszony na 1, a sygnał `rx_valid` z FIFO RX trafia tylko do modułu aktywnego trybu. Nieaktywne moduły strony hosta nie zmieniają przez to stanu.
- `uart_bridge` jest w resecie poza trybem UART; `frame_echo` jest wyłączony (`en` = 0) poza trybem echa.

## Strona hosta FIFO

Porty FIFO po stronie hosta pracują na zboczu opadającym `clk_host` (`WR_FALLING` / `RD_FALLING`), jak `xspi_slave` i `frame_echo` ([ADR 0009](../adr/0009-interfejs-hosta.md)). `uart_bridge` jest taktowany zanegowanym `clk_host`, więc jego przerzutniki również działają na zboczu opadającym. Wszystkie ścieżki strony hosta mają pełny okres zegara. Opóźnienia odczytu FIFO widziane przez `uart_bridge` są takie same jak w teście modułu ([UART](uart.md)).

FIFO TX: `PUB_STABLE` (publikacja wskaźnika bez uzgadniania, SCLK zatrzymuje się między transakcjami), `wr_commit_prev` i `wr_abort` tylko z `xspi_slave`. `TX_SPACE` = 4096 − poziom po stronie odczytu; `RX_LEVEL` = zatwierdzone słowa po stronie zapisu FIFO RX.

## Łącze i SFP

- Para RD jest na płytce rev. A odwrócona (plan, 3.2, reguła 9): `rx_phy` z `INVERT => true`, `rd_p => sfp_rd_n`, `rd_n => sfp_rd_p`. Para TD bez zmian.
- `CTRL.LB_NEAR` → `link_ctrl` w pętli near-end; `CTRL.TX_EN`, `RX_EN`, `LOS_IGNORE` bez pośrednictwa.
- `link_ctrl` dostaje przefiltrowane `LOS` i `MOD_ABS` z [`sfp_mgmt`](sfp_mgmt.md). Linie I2C SFP są open-drain (`'0'` lub stan wysokiej impedancji).
- Zdarzenia dla `IRQ_STAT`: `RX_FRAME` = poprawna ramka odebrana przez `rx_deframer`, `LINK_CHG` z `link_ctrl`, `ERR` = dowolny błąd deframera (lub bajt utracony na pełnym FIFO TX), `I2C_DONE` z `sfp_mgmt`.

## `leds`

| Dioda | Zachowanie |
|---|---|
| `LED_LINK` | łącze UP — świeci; SYNC (własny odbiornik zsynchronizowany, strona przeciwna niegotowa) — miga 2 Hz (250 ms / 250 ms); DOWN — zgaszona |
| `LED_ACT` | ramka nadana lub odebrana — błysk 30 ms, potem co najmniej 30 ms przerwy; ciągły ruch daje miganie zamiast stałego światła |

Diody są aktywne stanem niskim (3V3 → 1 kΩ → LED → pin).

## Generyki topu

Wolne liczniki są generykami tylko po to, żeby skrócić symulację; wartości domyślne obowiązują w syntezie.

| Generyk | Domyślnie | W testach end-to-end |
|---|---|---|
| `MG_TIMEOUT_CLKS`, `MG_TICK_CLKS` | 25 ms, 100 ms | bez zmian |
| `MG_DEB_ABS_CLKS`, `MG_DEB_SIG_CLKS` | 10 ms, 50 µs | 1 µs, 200 ns |
| `LED_ACT_CLKS`, `LED_BLINK_CLKS` | 30 ms, 250 ms | 10 µs, 100 µs |

## Ograniczenia czasowe

`sfp_bridge.sdc`:

| Zegar | Definicja |
|---|---|
| `clk_25m` | port, 40 ns |
| `clk_fast` | zegar generowany na wyjściu rPLL (×8), 5 ns |
| `clk_sys` | zegar generowany na wyjściu CLKDIV (÷4), 20 ns |
| `clk_spi` | port `XSPI_SCLK`, 25 ns (≤ 40 MHz, ADR 0009) |
| `clk_host` | zegar generowany z `clk_spi` na wyjściu DCS (`u_hclk/u_dcs/CLKOUT`) |

- Grupy `{clk_spi, clk_host}` i `{clk_25m, clk_fast, clk_sys}` są asynchroniczne. Przejścia między nimi to FIFO (wskaźniki Graya lub stabilne), zatrzask CSR i bufor zapisu `WRITE_REG`, statyczne w czasie użycia.
- Piny xSPI: opóźnienia wejść 0–4 ns i wyjść −1–3 ns względem zbocza opadającego SCLK.
- W trybach UART i echa `clk_host` = `clk_sys` (50 MHz). Ścieżki tych trybów sprawdza osobna kompilacja z okresem `clk_spi` 20 ns (`clk_host` 50 MHz).

## Synteza

Pełny układ (GW1N-UV9QN48C6/I5, Gowin EDA 1.9.11.03), kompilacja z `sfp_bridge.sdc`:

| Zasób | Użycie |
|---|---|
| logika (LUT, ALU) | 4483 (3481 LUT, 1002 ALU) z 8640 — 52% |
| pamięć rozproszona SSRAM (RAM16) | 40 (bufor I2C 128 B w dwóch kopiach, bufor `uart_bridge`) |
| rejestry | 2833 z 6480 — 44% (+ 13 w blokach I/O) |
| BSRAM | 7 z 26 (FIFO TX 2, FIFO RX 4, tablica dekodera 8b/10b 1) |
| piny I/O | 27 z 41 |
| rPLL / CLKDIV / DCS | 1 / 1 / 1 |

| Zegar | Wymaganie | Fmax |
|---|---|---|
| `clk_sys` | 50 MHz | 56,3 MHz |
| `clk_host` (tryb xSPI, SCLK) | 40 MHz | 44,2 MHz |
| `clk_host` (tryby UART i echa; kompilacja kontrolna z `clk_spi` 20 ns) | 50 MHz | 50,4 MHz |

Wszystkie ścieżki spełniają wymagania (brak ujemnego zapasu dla ustawień i podtrzymania). Fmax `clk_sys` w pełnym układzie ma mniejszy zapas niż w próbnych syntezach modułów (cel ≥ 60 MHz z ADR 0007 nie jest osiągnięty; najdłuższe ścieżki: automat stanów `i2c_master` w `sfp_mgmt`; w innych kompilacjach licznik `fetch_left` w `tx_framer`). PnR optymalizuje do zadanego ograniczenia, więc wartości Fmax pokazują zapas przy 50 MHz, a nie granicę układu.

Kolejne poprawki przy integracji (ścieżki, które nie mieściły się w czasie w pełnym układzie):
- `csr_regs` i `sfp_mgmt`: wstępne dekodowanie bajtów `WRITE_REG` (rejestry pomocnicze) zamiast dekodowania w takcie zastosowania zapisu;
- `uart_bridge` na zanegowanym `clk_host` (zamiast ścieżek półokresowych do portów FIFO na zboczu opadającym).

## Testy

- `tb_leds` — zachowanie diod: zgaszone w resecie i przy DOWN, stałe przy UP, miganie przy SYNC (czasy w taktach), błysk ACT z przerwą także przy ciągłej aktywności.
- Testy end-to-end — dwa kompletne mostki (`sfp_bridge_top` z modelami prymitywów Gowin) połączone linią: SPI ↔ SPI, QSPI ↔ QSPI, OSPI ↔ OSPI, UART ↔ UART. Opis, wyniki i przebiegi: [Testy end-to-end](../e2e/index.md).

**Test mutacyjny** (15 wariantów; `tb_leds`, testy end-to-end, `tb_csr_regs`): wykrywane — `LED_LINK` stale włączona przy SYNC lub włączona przy DOWN, `LED_ACT` bez przerwy po błysku, brak odwrócenia polaryzacji RD (`INVERT` lub zamiana pinów), odwrócona polaryzacja TD, pominięcie `MODE_SEL`, `rx_valid` niebramkowany dla `xspi_slave`, `HOST_IRQ_N` w trybie UART z rejestrów zamiast stanu łącza, `UART_TX` na złej linii J3, `UART_DIV` kasowany resetem programowym, `UART_STATUS` kasowany przez `HOST_RST_N` lub bez połączenia `FRAME_ERR` (`tb_e2e_uart_reg`).

Niewykrywane:
- taktowanie `uart_bridge` zboczem narastającym — zmienia wyłącznie zapas czasowy (ścieżki półokresowe), co wykazuje analiza czasowa, a nie symulacja;
- brak `wr_commit_prev` z `xspi_slave` do FIFO TX — dotyczy tylko ramek z `LEN` = 0, których testy end-to-end nie wysyłają (mechanizm sprawdza `tb_xspi_slave`).
