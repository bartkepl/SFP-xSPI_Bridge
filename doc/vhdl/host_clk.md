# Zegar strony hosta i echo ramek: `host_clk`, `frame_echo`

Pliki: `vhdl/sfp_bridge/src/clk/host_clk.vhd`, `vhdl/sfp_bridge/src/host/frame_echo.vhd` · testbench: `vhdl/sim/tb/tb_host_clk.vhd`

Decyzje: [ADR 0009](../adr/0009-interfejs-hosta.md) (zegar strony hosta przez DCS, zmiana trybu = reset), [ADR 0008](../adr/0008-stan-lacza.md) (echo ramek).

## `host_clk`

Prymityw `DCS` wybiera zegar strony hosta FIFO (`clk_host`):

| Stan | `clk_host` |
|---|---|
| reset mostka | `clk_sys` |
| tryb xSPI, po resecie i `SWITCH_DELAY` (8) taktach | SCLK |
| tryby UART i echa ramek | `clk_sys` |

- Strona hosta zawsze dostaje takty w czasie resetu (reset synchroniczny); `rst_host` = `rst_sys`.
- `SELFORCE` = 1: zwykły multiplekser, bez oczekiwania na zbocza nowego zegara (SCLK między transakcjami stoi).
- Rejestr wyboru zmienia się na zboczu opadającym `clk_sys` — wtedy `clk_sys` i spoczynkowy SCLK mają stan niski, więc wyjście nie daje impulsu. Wejście w reset przełącza z powrotem na `clk_sys`; ewentualny niepełny impuls wypada w resecie strony hosta.
- Wyjście `on_sclk` informuje, że `clk_hosta` = SCLK.

Synteza DCS z SCLK (pin GCLKT_4) i `clk_sys` (z `CLKDIV`) jest sprawdzona w pełnym układzie: `clk_host` jest ograniczony jako zegar generowany na wyjściu DCS ([integracja](top.md#ograniczenia-czasowe)).

## `frame_echo`

Echo ramek (`MODE_CTRL.FRAME_ECHO`): każda ramka z FIFO RX jest kopiowana bez zmian do FIFO TX, więc strona przeciwna otrzymuje własne ramki. Moduł pracuje po stronie hosta (`clk_host` = `clk_sys` w tym trybie), na zboczu opadającym jak porty FIFO po tej stronie.

- Kopiowanie bajt po bajcie: odczyt z FIFO RX, gdy nie jest puste, a FIFO TX nie jest pełne; zapis odebranego bajtu; zatwierdzenie z ostatnim bajtem (długość z nagłówka `TYPE LEN_H LEN_L`).
- 4 takty na bajt (12,5 MB/s przy 50 MHz) — więcej niż przepustowość łącza (10 MB/s).
- FIFO TX musi pomieścić największą ramkę (`MAX_LEN` + 3); w mostku ma 4 KiB.

## Testbench `tb_host_clk`

| Nr | Sprawdzenie |
|---|---|
| 1 | w resecie `clk_host` = `clk_sys` (wspólne zbocza) |
| 2 | tryb xSPI: po resecie i opóźnieniu `clk_host` = SCLK (paczki po 16 taktów 40 MHz); żaden impuls przy przełączeniu nie jest krótszy niż 10 ns |
| 3 | nowy reset przełącza z powrotem na `clk_sys` |
| 4 | tryb UART / echa: `clk_host` pozostaje na `clk_sys` |
| 5 | echo: 40 ramek (1–300 B) zapisanych przez stronę łącza do FIFO RX wraca przez FIFO TX bez zmian i w kolejności (czytelnik co drugi takt) |
| 6 | `en` = 0: nic nie jest kopiowane |

**Test mutacyjny:** wykrywane — przełączanie na zboczu narastającym (krótki impuls), pominięcie trybu, zatwierdzenie ramki o bajt za wcześnie. Pominięcie `tx_full` nie jest wykrywane: czytelnik w teście jest szybszy niż echo, więc FIFO TX się nie zapełnia.

## Przebieg

`.\view.ps1 tb_host_clk`: w resecie `clk_host` powtarza `clk_sys`; po zwolnieniu resetu i 8 taktach `on_sclk` = 1, a `clk_host` ma zbocza tylko w paczkach SCLK; po ponownym resecie wraca do `clk_sys`. Dalej (tryb echa) zapisy ramek do FIFO RX i ich kopie odczytywane z FIFO TX.
