# Tryb przezroczysty UART: `uart_rx`, `uart_tx`, `uart_bridge`

Pliki: `vhdl/sfp_bridge/src/uart/uart_rx.vhd`, `uart_tx.vhd`, `uart_bridge.vhd` · testbenche: `vhdl/sim/tb/tb_uart.vhd`, `tb_uart_bridge.vhd`

Odbiornik, nadajnik i pakietyzator UART trybu przezroczystego ([ADR 0006](../adr/0006-tryb-uart-przezroczysty.md); [plan, rozdz. 7.7](../sfp-xspi-bridge-plan.md)). Format 8N1, najmłodszy bit pierwszy, linia w spoczynku w stanie wysokim.

```
UART_RX ─> uart_rx ─> bufor 64 B ─> ramka TYPE 0x01 ─> FIFO TX ─> łącze
UART_TX <─ uart_tx <─ treść ramek TYPE 0x01 <─ FIFO RX <─ łącze   (inne TYPE: odrzucane)
```

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

## `uart_bridge`

Łączy UART ze stroną hosta FIFO łącza (w miejsce `xspi_slave`), w domenie zegara tej strony (`clk_sys` w trybie UART).

| Generyk | Domyślnie | Opis |
|---|---|---|
| `MAX_PAY` | 64 | bajty treści w ramce |
| `FREE_W` | 13 | szerokość `tx_free` (ADDR_W FIFO TX + 1) |
| `RTS_FREE` | 512 | wolne miejsce w FIFO TX, poniżej którego RTS zatrzymuje nadawcę |

| Port | Kierunek | Opis |
|---|---|---|
| `clk`, `rst` | in | zegar, reset synchroniczny |
| `cfg_div[15:0]`, `cfg_rtscts` | in | `UART_DIV`, bit `RTSCTS_EN` rejestru `MODE_CTRL` |
| `uart_rx`, `uart_cts_n` | in | piny (asynchroniczne) |
| `uart_tx`, `uart_rts_n` | out | piny |
| `tx_wr`, `tx_data`, `tx_commit` / `tx_free` | out / in | strona zapisu FIFO TX (tryb commit) |
| `rx_rd` / `rx_data`, `rx_valid`, `rx_empty` | out / in | strona odczytu FIFO RX |
| `ev_rx_ovf` | out | impuls: bajt UART utracony (bufor i FIFO pełne) |
| `ev_frame_err` | out | impuls: błąd ramki UART (bajt odrzucony) |
| `ev_frame` | out | impuls: ramka zapisana do FIFO TX |
| `ev_skip` | out | impuls: odebrana ramka innego typu odrzucona |

**UART → łącze:**

- Odebrane bajty trafiają do bufora 64 B (pamięć rozproszona, RAM16).
- Ramka TYPE 0x01 (`TYPE`, `LEN_H` = 0, `LEN_L`, treść) jest zapisywana do FIFO TX, gdy bufor jest pełny albo gdy linia RX jest bezczynna przez 2 czasy znaku (20 okresów bitu) po bicie stopu ostatniego bajtu.
- Zapis zaczyna się dopiero przy miejscu na całą ramkę (`tx_free` ≥ LEN + 4); ostatni bajt zatwierdza ramkę. Zapis trwa LEN + 3 takty.
- Bajt odebrany w czasie zapisu ramki lub oczekiwania na miejsce trafia do rejestru `hold`; kolejny jest tracony (`ev_rx_ovf`).
- Przy włączonym RTS/CTS `uart_rts_n` = 1 (wstrzymanie nadawcy), gdy w FIFO TX jest mniej niż `RTS_FREE` wolnych bajtów. Bez RTS/CTS dane przychodzące przy zatrzymanym łączu (stan inny niż UP, XOFF) są tracone po zapełnieniu FIFO TX i zliczane.

**Łącze → UART:**

- Ramki w FIFO RX są kompletne (zatwierdzone przez `rx_deframer`). Treść ramek TYPE 0x01 jest nadawana na `uart_tx` w kolejności odbioru; ramki innych typów są czytane i odrzucane (`ev_skip`).
- Bajty są czytane z FIFO tylko w tempie nadawania UART (jeden bajt w przód), więc wolny UART zatrzymuje stronę przeciwną przez XOFF łącza — po tej stronie dane nie giną.
- Przy włączonym RTS/CTS kolejny bajt startuje tylko przy `uart_cts_n` = 0.

Próbna synteza (GW1N-9C, ograniczenie 12 ns): 496 LUT/ALU, 8 × RAM16, 268 rejestrów, Fmax 84,9 MHz.

### Testbench `tb_uart_bridge`

Bridge z rzeczywistymi FIFO (TX 512 B — małe, aby szybko osiągnąć próg RTS i przepełnienie, `RTS_FREE` = 128; RX 1 KiB). Testbench modeluje urządzenie UART (nadajnik behawioralny na `UART_RX`, odbiornik na `UART_TX`) i łącze (czyta ramki z FIFO TX, zapisuje ramki do FIFO RX).

| Faza | Sprawdzenie |
|---|---|
| 0 | `div` = 434: 10 bajtów bez przerw → jedna ramka 10 B, zapisana 2–2,5 czasu znaku po bicie stopu ostatniego bajtu |
| 1 | `div` = 54: 200 bajtów bez przerw → ramki 64, 64, 64, 8 B |
| 2 | 5 bajtów, przerwa 1,5 znaku, 5 bajtów → jedna ramka 10 B; bajt z błędnym bitem stopu → `ev_frame_err`, poza ramkami |
| 3 | ramki (TYPE 0x01, 10 B), (TYPE 0x10, 20 B), (TYPE 0x01, 300 B) → na `UART_TX` dokładnie 310 bajtów ramek TYPE 0x01, w kolejności; jeden `ev_skip` |
| 4 | RTS/CTS, `CTS_N` = 1: ramka 5 B czeka (nic nie nadano przez 50 czasów znaku); po `CTS_N` = 0 nadane 5 bajtów |
| 5 | RTS/CTS, łącze zatrzymane, nadawca ignorujący RTS, `div` = 17: `RTS_N` = 1 przed pierwszym utraconym bajtem; potem straty (`ev_rx_ovf`); po wznowieniu łącza `RTS_N` = 0, ramki poprawne, bajty w ramkach + utracone = wysłane (wynik: 187 z 700 utraconych) |

W fazach 0–3 każdy bajt w ramkach jest porównywany z bajtami wysłanymi, w fazach 3–4 każdy bajt na `UART_TX` — z treścią ramek.

**Test mutacyjny:** wykrywane — brak filtrowania typu ramki, brak RTS, pominięcie CTS, ramka 63 B zamiast 64, brak sprawdzenia miejsca w FIFO. Usunięcie rejestru `hold` nie jest wykrywane: zapis ramki trwa ok. 70 taktów, a przy testowanych prędkościach bajt przychodzi najwyżej co 170 taktów; `hold` ma znaczenie przy dzielniku bliskim minimum i w czasie oczekiwania na miejsce (straty są wtedy i tak zliczane).

**Przebieg** (`.\view.ps1 tb_uart_bridge`, ok. 10,6 ms): w fazie 0 (ok. 1–1,3 ms) `dev_tx` niesie 10 znaków, po przerwie `pk` przechodzi P_WAIT → P_PAY, seria `tf_wr` z `tf_commit` na końcu, `last_len` = 10; w fazie 1 serie zapisów co 64 bajty; w fazie 3 `br_tx` nadaje ciągle, `ev_skip` przy ramce TYPE 0x10; w fazie 4 `br_tx` stoi przy `cts_n` = 1; w fazie 5 `tf_free` spada, `rts_n` = 1, potem impulsy `ev_ovf`.

## Przebieg

`.\view.ps1 tb_uart` — czas symulacji ok. 27,7 ms.

| Czas (ok.) | Co widać |
|---|---|
| 0–17,4 ms | faza 1 przy 115 200: `tx_line` — znaki 8N1 bez przerw (bit = 8,68 µs); `rx_valid` po każdym bicie stopu, `rx_data` równe `tx_data` sprzed ok. 1 znaku |
| 17,4–18,4 ms | faza 1 przy `div` = 17 i 8 — te same zdarzenia w skali 25 i 54 razy krótszej |
| 18,4–27,1 ms | faza 2: `use_tb` = 1, linia `tb_line` z nadajnika behawioralnego (czas bitu +3,5 %, potem −3,5 %) |
| ok. 27,1–27,5 ms | faza 3: impuls `rx_ferr`, długi stan niski linii (break), potem bajt 3C |
| koniec | faza 4: krótki impuls niski, `rx_busy` na chwilę 1, brak `rx_valid` |
