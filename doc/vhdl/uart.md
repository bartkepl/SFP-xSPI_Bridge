# Tryb przezroczysty UART: `uart_rx`, `uart_tx`

Pliki: `vhdl/sfp_bridge/src/uart/uart_rx.vhd`, `uart_tx.vhd` · testbench: `vhdl/sim/tb/tb_uart.vhd`

Odbiornik i nadajnik UART trybu przezroczystego ([ADR 0006](../adr/0006-tryb-uart-przezroczysty.md); [plan, rozdz. 7.7](../sfp-xspi-bridge-plan.md)). Format 8N1, najmłodszy bit pierwszy, linia w spoczynku w stanie wysokim.

## Prędkość

Dzielnik `div` (rejestr `UART_DIV`) to liczba taktów zegara na bit. Przy `clk_sys` = 50 MHz:

| Prędkość | `div` | Błąd |
|---|---|---|
| 115 200 (domyślna, `UART_DIV_DEFAULT`) | 434 | +0,01 % |
| 921 600 | 54 | +0,5 % |
| 3 000 000 | 17 | −2,0 % |
| 6 250 000 (minimum dzielnika, `UART_DIV_MIN` = 8) | 8 | 0 |

Stałe `UART_DIV_DEFAULT` i `UART_DIV_MIN` są w `bridge_pkg`.

## `uart_rx`

| Port | Kierunek | Opis |
|---|---|---|
| `clk`, `rst` | in | zegar, reset synchroniczny |
| `div[15:0]` | in | takty na bit |
| `rx` | in | wejście asynchroniczne (pin) |
| `data[7:0]` | out | odebrany bajt |
| `valid` | out | impuls: bajt odebrany |
| `frame_err` | out | impuls: bit stopu równy 0 (bajt odrzucony) |
| `busy` | out | trwa odbiór znaku |

Działanie:

1. `rx` przechodzi przez synchronizator 2-FF (`sync_bit`, stan początkowy 1).
2. Zbocze opadające rozpoczyna znak; po `div/2` taktach (środek bitu startu) linia musi nadal mieć stan 0 — w przeciwnym razie zbocze było zakłóceniem i odbiornik wraca do spoczynku.
3. 8 bitów danych próbkowanych co `div` taktów w środku bitu, od najmłodszego.
4. Bit stopu: 1 → impuls `valid`; 0 → impuls `frame_err` bez danych, a odbiornik czeka na powrót linii do stanu 1 (linia trzymana w stanie niskim — break — nie generuje znaków).

Jedna próbka na bit; tolerancja różnicy prędkości ok. ±4 % (bit stopu próbkowany w chwili 9,5 okresu bitu musi leżeć wewnątrz bitu).

## `uart_tx`

| Port | Kierunek | Opis |
|---|---|---|
| `clk`, `rst` | in | zegar, reset synchroniczny |
| `div[15:0]` | in | takty na bit |
| `data[7:0]`, `start` | in | przy `ready` = 1 impuls `start` pobiera bajt i rozpoczyna znak |
| `ready` | out | nadajnik wolny |
| `tx` | out | linia nadawcza (spoczynek: 1) |

Znaki mogą następować bezpośrednio po sobie; między bitem stopu a kolejnym bitem startu wypada jeden dodatkowy takt zegara (wydłużenie bitu stopu o 1/`div`).

## Synteza

Próbna synteza `uart_rx` + `uart_tx` (GW1N-9C, ograniczenie 12 ns): 179 LUT, 83 rejestry, Fmax 97,8 MHz.

## Testbench `tb_uart`

Zegar 50 MHz. Każdy odebrany bajt jest porównywany z kolejnym bajtem z kolejki oczekiwanych.

| Faza | Sprawdzenie |
|---|---|
| 1 | pętla `uart_tx` → `uart_rx`, 200 losowych bajtów bez przerw przy `div` = 434, 17 i 8: wszystkie odebrane, bez błędów ramki; najkrótszy odcinek stałego stanu na linii równy `div` taktom |
| 2 | nadajnik behawioralny → `uart_rx` (`div` = 434), czas bitu +3,5 % i −3,5 %: po 50 bajtów odebranych poprawnie |
| 3 | bajt z bitem stopu 0: jeden impuls `frame_err`, brak danych; linia w stanie niskim przez 3 czasy znaku (break): brak znaków i błędów; następny bajt odebrany |
| 4 | impuls niski o długości `div`/4: nic nie odebrano, brak błędu |

**Test mutacyjny:** wykrywane — próbkowanie przy zboczu bitu, odwrócona kolejność bitów, brak kontroli bitu stopu, brak odrzucania fałszywego startu, zbyt długi bit nadajnika, brak oczekiwania na koniec stanu break.

## Przebieg

`.\view.ps1 tb_uart` — czas symulacji ok. 27,7 ms.

| Czas (ok.) | Co widać |
|---|---|
| 0–17,4 ms | faza 1 przy 115 200: `tx_line` — znaki 8N1 bez przerw (bit = 8,68 µs); `rx_valid` po każdym bicie stopu, `rx_data` równe `tx_data` sprzed ok. 1 znaku |
| 17,4–18,4 ms | faza 1 przy `div` = 17 i 8 — te same zdarzenia w skali 25 i 54 razy krótszej |
| 18,4–27,1 ms | faza 2: `use_tb` = 1, linia `tb_line` z nadajnika behawioralnego (czas bitu +3,5 %, potem −3,5 %) |
| ok. 27,1–27,5 ms | faza 3: impuls `rx_ferr`, długi stan niski linii (break), potem bajt 3C |
| koniec | faza 4: krótki impuls niski, `rx_busy` na chwilę 1, brak `rx_valid` |
