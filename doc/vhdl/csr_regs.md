# Rejestry sterujące i stanu: `csr_regs`

Plik: `vhdl/sfp_bridge/src/host/csr_regs.vhd` · testbench: `vhdl/sim/tb/tb_csr_regs.vhd` (razem z [`xspi_slave`](xspi_slave.md))

Rejestry mostka w domenie `clk_sys` ([ADR 0009](../adr/0009-interfejs-hosta.md); mapa: [plan, rozdz. 7.4](../sfp-xspi-bridge-plan.md)).

## Dostęp z xSPI

| Kierunek | Mechanizm |
|---|---|
| odczyt | `CS_N` przechodzi przez synchronizator 2-FF; przy jego opadnięciu cała przestrzeń odczytu 0x00–0x53 (z rejestrami [`sfp_mgmt`](sfp_mgmt.md) 0x30–0x4F) jest zatrzaskiwana w `snap`. Wyjątek: `I2C_BUF` (0x80–0xFF) jest czytany bezpośrednio z bufora `sfp_mgmt` (`buf_rdata` pod `reg_addr`), stałego przy `I2C_STATUS.BUSY` = 0. `xspi_slave` czyta wyłącznie `snap` (`reg_addr` → `reg_rdata`, `status_fast`). Wartości są niezmienne do końca transakcji: 32-bitowe liczniki i wielobajtowe poziomy są spójne, `IRQ_STAT` odczytany i skasowany zapisem W1C nie gubi zdarzeń. Zatrzask jest gotowy ok. 4 takty `clk_sys` (80 ns) po opadnięciu CS. |
| zapis | `xspi_slave` zbiera bajty `WRITE_REG` (`wr_addr`, `wr_data`, `wr_cnt`) i przełącza `wr_txn`. Po podniesieniu CS (zsynchronizowanym) bajty nowej transakcji są stosowane jednocześnie — np. dwubajtowy `UART_DIV` zmienia się atomowo. W tym samym takcie impuls `wr_apply` przekazuje transakcję do `sfp_mgmt` (rejestry 0x30–0x4F, `I2C_BUF`). Bufor jest stały, gdy CS ma stan wysoki; host utrzymuje CS w stanie wysokim ≥ 100 ns. |

Ścieżki z `snap` do `xspi_slave` i z bufora zapisu do `csr_regs` są statyczne w czasie użycia — w ograniczeniach czasowych są wyłączone grupami zegarów asynchronicznych.

## Interfejs (skrót)

| Grupa | Porty |
|---|---|
| zegar, reset | `clk` (`clk_sys`), `rst` (`rst_sys`, z resetem programowym), `rst_hard` (bez resetu programowego — dla `MODE_CTRL`) |
| xSPI | `cs_n`, `reg_addr`, `reg_rdata`, `status_fast`, `wr_addr`, `wr_data`, `wr_cnt`, `wr_txn`, `ev_tx_ovf_t` |
| `sfp_mgmt` | `wr_apply` (wyjście), `mg_regs` (0x30–0x4F), `buf_rdata` (`I2C_BUF` pod `reg_addr`) |
| stan | `link_state`, `rx_sync`, `remote_ready`, `xoff_local`, `xoff_remote`, `sfp_los`, `sfp_tx_fault`, `sfp_mod_abs`, `mode_sel`, `tx_level`, `rx_level`, `counters` |
| zdarzenia | `ev_rx_frame`, `ev_link_chg`, `ev_i2c_done`, `ev_err`, `ev_uart_ovf`, `ev_uart_ferr` |
| konfiguracja | `cfg_tx_en`, `cfg_rx_en`, `cfg_lb_near`, `cfg_sfp_tx_dis`, `cfg_los_ignore`, `cnt_clr` (impuls), `soft_rst`, `mode_uart`, `mode_echo`, `mode_rtscts`, `uart_div`, `irq_n` |

## Zachowanie rejestrów

- `CTRL` po resecie `0x03`. Bit `CNT_CLR` daje jednotaktowy impuls `cnt_clr`, `SOFT_RST` ustawia `soft_rst`; oba są czytane jako 0.
- `STATUS_FAST`: `LINK_UP`, `RX_AVAIL` (`RX_LEVEL` ≠ 0), `TX_READY` (`TX_SPACE` ≥ `MAX_LEN` + 3), `TX_EMPTY`, `IRQ`, `MODE_SEL`.
- `TX_SPACE` = `TX_DEPTH` − liczba zatwierdzonych słów w FIFO TX (strona odczytu), `RX_LEVEL` = liczba zatwierdzonych słów w FIFO RX (strona zapisu, `wr_cmt_level`).
- `IRQ_STAT`: zdarzenia `RX_FRAME`, `TX_EMPTY` (FIFO TX opróżnione), `LINK_CHG`, `SFP_CHG` (zmiana LOS / TX_FAULT / MOD_ABS), `I2C_DONE`, `ERR` (zdarzenie błędu łącza lub bajt utracony na pełnym FIFO TX). Kasowanie zapisem 1 (W1C); zdarzenie w takcie kasowania wygrywa. `irq_n` = 0, gdy (`IRQ_STAT` ∧ `IRQ_EN`) ≠ 0 (rejestrowane).
- `MODE_CTRL` (`UART_MODE`, `FRAME_ECHO`, `RTSCTS_EN`) jest kasowany tylko przez `rst_hard`. Zapis zmieniający `UART_MODE` lub `FRAME_ECHO` ustawia `soft_rst` — reset mostka z zachowanym nowym trybem.
- `UART_DIV` po resecie 434 (115 200 baud), kasowany tylko przez `rst_hard` (jak `MODE_CTRL`): prędkość ustawiona przed przejściem w tryb UART przez `MODE_CTRL` pozostaje po resecie, który to przejście wywołuje. `UART_STATUS`: `RX_OVF`, `FRAME_ERR`, W1C.
- Bajty `WRITE_REG` są dekodowane w każdym takcie do rejestrów pomocniczych; takt zastosowania zapisu wypada co najmniej 2 takty po podniesieniu CS, gdy zdekodowane wartości są stabilne. Dekodowanie nie leży więc na ścieżce od synchronizatora CS (wymaganie czasowe pełnego układu).

Pętla resetu programowego: `soft_rst` → `clk_rst` (`arst_n`) → `rst_sys` → kasowanie `soft_rst` → zwolnienie po `STAGES` taktach.

## Synteza

Próbna synteza `csr_regs` + `xspi_slave` (GW1N-9C, `clk_sys` 50 MHz, SCLK 40 MHz z ograniczeniami wejść i wyjść, liczniki testowe w otoczce): 1079 LUT/ALU, 856 rejestrów; `clk_sys` Fmax 81,9 MHz, SCLK 45,3 MHz — wszystkie ścieżki spełnione.

## Testbench `tb_csr_regs`

`csr_regs` z rzeczywistym `xspi_slave`, transakcje behawioralnego mastera (SCLK 40 MHz), `clk_sys` 50 MHz; pętla resetu programowego `clk_rst` zamodelowana (`soft_rst` → `rst` na 4 takty).

| Nr | Sprawdzenie |
|---|---|
| 1 | `READ_REG` 0x00–0x04: `5B 5F` wersja, `CTRL` = 0x03 po resecie |
| 2 | zapis `CTRL` przy CS trzymanym 400 ns po danych: wyjścia zmieniają się dopiero po podniesieniu CS; odczyt zwrotny |
| 3 | licznik zmieniony 300 ns po opadnięciu CS: odczyt zwraca wartość z chwili opadnięcia (4 bajty spójne), następna transakcja — nową |
| 4 | `STATUS`, `TX_SPACE`, `RX_LEVEL`, `STATUS_FAST` (komenda `READ_STATUS`) |
| 5 | przerwanie: zdarzenie włączone → `HOST_IRQ_N` = 0; `IRQ_STAT`; W1C kasuje tylko zapisany bit |
| 6 | `CNT_CLR`: jeden impuls `cnt_clr`, bit czytany jako 0 |
| 7 | `SOFT_RST`: reset mostka, `CTRL` = 0x03, `MODE_CTRL` zachowany |
| 8 | `RTSCTS_EN` bez resetu; zmiana `UART_MODE` → reset, tryb zachowany; `rst_hard` kasuje `MODE_CTRL` |
| 9 | `UART_DIV` (2 bajty, little-endian, zachowany po resecie programowym), `UART_STATUS` W1C |
| 10 | z `sfp_mgmt` (magistrala I2C bez urządzeń): rejestry skrzynki i `DDM_PERIOD` — odczyt zwrotny; `I2C_BUF` 8 B zapis / odczyt; polecenie bez modułu → `BAD_CMD`, `I2C_DONE`; z modułem → `BUSY` w transakcji bezpośrednio po poleceniu, potem `NACK` — zob. [Zarządzanie SFP](sfp_mgmt.md) |

**Test mutacyjny:** wykrywane — brak zatrzasku (odczyt wartości bieżących), stosowanie zapisu przed podniesieniem CS, kasowanie `MODE_CTRL` resetem programowym, W1C ustawiające zamiast kasować, brak resetu przy zmianie trybu.

## Przebieg

`.\view.ps1 tb_csr_regs` — czas symulacji ok. 160 µs (faza 10 z poleceniem I2C ok. 130 µs). Każda transakcja: `cs_n` = 0; po ok. 3 taktach `clk_sys` `cs_s` = 0 (zatrzask), po podniesieniu CS i synchronizacji `txn_done` dogania `wr_txn` i rejestry (`ctrl`, `irq_en`, `mode`) przyjmują nowe wartości. W fazie 5 `irq_n` opada po zdarzeniu i wraca po zapisie W1C; w fazach 7–8 impulsy `soft_rst` z krótkim `rst`.
