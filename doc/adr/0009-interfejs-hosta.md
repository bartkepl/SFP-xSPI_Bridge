# 0009. Interfejs hosta: ramki w formacie surowym, rejestry zatrzaskiwane przy CS, zegar strony hosta przez DCS

**Stan:** przyjęta · **Data:** 2026-10-08
**Dotyczy:** vhdl, firmware, doc (zmienia mapę rejestrów z planu, uzupełnia [ADR 0006](0006-tryb-uart-przezroczysty.md) i [ADR 0008](0008-stan-lacza.md))

## Kontekst

Slave xSPI pracuje w domenie zegara hosta (SCLK, ≤ 50 MHz), bo przy tej częstotliwości SCLK nie da się nadpróbkować zegarem `clk_sys` (plan, rozdz. 3). SCLK biegnie wyłącznie w czasie transakcji. Strona hosta FIFO (zapis FIFO TX, odczyt FIFO RX) pracuje na tym samym zegarze, aby przepustowość OCTOSPI (do 50 MB/s) nie wymagała dodatkowego bufora.

Szkic mapy rejestrów zakładał rejestry ramek: `TX_TYPE`, `TX_LEN`, `TX_COMMIT`, `RX_TYPE`, `RX_LEN`, `RX_POP`. Wymagają one operacji na FIFO pomiędzy transakcjami, gdy zegar strony hosta stoi (np. `RX_LEN` wymaga wcześniejszego wyjęcia nagłówka z FIFO). Rejestry sterujące i stanu są natomiast potrzebne w domenie `clk_sys` (`link_ctrl`, UART, I2C), a odczyt rejestru przez xSPI ma tylko kilka taktów SCLK na przejście między domenami. Liczniki 32-bitowe wymagają spójnego odczytu wielobajtowego.

Tryb UART ([ADR 0006](0006-tryb-uart-przezroczysty.md)) i echo ramek ([ADR 0008](0008-stan-lacza.md)) obsługują stronę hosta FIFO z logiki w domenie `clk_sys` — zegar strony hosta zależy więc od trybu.

## Decyzja

**1. Ramki w formacie surowym FIFO.** `TX_WRITE_x` przesyła bajty `TYPE, LEN_H, LEN_L, treść`; slave liczy bajty z nagłówka i zatwierdza ramkę z ostatnim bajtem treści. Ramka może być podzielona na kilka transakcji. `RX_READ_x` zwraca bajty `TYPE, LEN_H, LEN_L, treść` kolejnych ramek. Rejestry `TX_TYPE`, `TX_LEN`, `TX_COMMIT`, `RX_TYPE`, `RX_LEN`, `RX_POP` nie występują; komenda `TX_ABORT` porzuca niedokończoną ramkę.

**2. Komendy** (instrukcja zawsze na 1 linii, adres 8-bit na 1 linii, SDR, tryb 0, najstarszy bit pierwszy; w formacie 1-x-1 dane od hosta na IO0, do hosta na IO1):

| Opkod | Nazwa | Format | Dummy | Dane |
|---|---|---|---|---|
| `0x9F` | READ_ID | 1-0-1 | 0 | 4 B: `0x5B`, `0x5F` (ID), wersja, `0x00` |
| `0x05` | READ_STATUS | 1-0-1 | 0 | rejestr `STATUS_FAST` (powtarzany) |
| `0x0B` | READ_REG | 1-1-1 | 8 | rejestry od adresu, auto-inkrementacja |
| `0x02` | WRITE_REG | 1-1-1 | 0 | do 8 bajtów od adresu, auto-inkrementacja |
| `0x12` / `0x32` / `0x82` | TX_WRITE_1 / _4 / _8 | 1-0-1 / 1-0-4 / 1-0-8 | 0 | bajty ramki do FIFO TX |
| `0x13` / `0x6B` / `0x8B` | RX_READ_1 / _4 / _8 | 1-0-1 / 1-0-4 / 1-0-8 | 8 | bajty ramek z FIFO RX |
| `0x66` | TX_ABORT | 1-0-0 | — | porzucenie niezatwierdzonej ramki |

Inne opkody są ignorowane do końca transakcji.

**3. Rejestry w domenie `clk_sys`, zatrzaskiwane przy CS.** Opadnięcie CS (zsynchronizowane do `clk_sys`) zatrzaskuje całą przestrzeń rejestrów do odczytu; slave czyta wyłącznie zatrzaśnięte wartości, niezmienne do końca transakcji (spójny odczyt liczników 32-bit, `IRQ_STAT` odczytany i kasowany bez wyścigu). Bajty `WRITE_REG` są zbierane w transakcji i stosowane atomowo po podniesieniu CS. Wymagania dla hosta: SCLK ≤ 50 MHz, CS w stanie wysokim ≥ 100 ns między transakcjami (STM32 OCTOSPI: `CSHT`), czyli ≥ 5 taktów `clk_sys`. Zatrzaśnięcie jest gotowe ok. 80 ns po opadnięciu CS, przed pierwszym bitem danych każdej komendy (najwcześniej po 8 taktach SCLK = 160 ns).

**4. Stan FIFO liczony w `clk_sys`.** `RX_AVAIL` i `RX_LEVEL` — z liczby zatwierdzonych, nieodczytanych słów po stronie zapisu FIFO RX (`wr_cmt_level`); `TX_SPACE` — z wolnego miejsca FIFO TX widzianego po stronie odczytu. Flagi strony hosta nie są używane do stanu, bo między transakcjami nie są aktualizowane.

**5. Odczyt z wyprzedzeniem.** `RX_READ_x` pobiera z FIFO bajt następny przed jego wysłaniem; bajt pobrany, a niewysłany do końca transakcji, pozostaje w rejestrze slave'a i jest wysyłany jako pierwszy w kolejnej transakcji `RX_READ_x` — strumień bajtów nie traci danych.

**6. Zegar strony hosta — DCS.** `clk_host` = prymityw `DCS` (wymuszone przełączanie, `SELFORCE`) między `clk_sys` a SCLK:

- w resecie mostka i w trybach UART oraz echa ramek — `clk_sys`;
- w trybie xSPI — SCLK, przełączenie kilka taktów po zwolnieniu resetu, przy CS w stanie wysokim.

Reset strony hosta (synchroniczny) odbywa się zawsze na `clk_sys`, więc nie wymaga taktów SCLK. Maszyna stanów transakcji xSPI jest resetowana asynchronicznie przez CS = 1.

**7. Tryby i reset.** Rejestr `MODE_CTRL` (bity `UART_MODE`, `FRAME_ECHO`, `RTSCTS_EN`) jest zachowywany przy resecie programowym, kasowany przez `HOST_RST_N` i przy włączeniu zasilania. Zmiana bitu `UART_MODE` lub `FRAME_ECHO` wywołuje reset mostka (jak `SOFT_RST`); zawartość FIFO jest tracona. W trybach UART i echa ramek interfejs xSPI jest niedostępny (piny J3 obsługuje UART albo strona hosta FIFO pracuje na `clk_sys`); powrót do trybu xSPI — `HOST_RST_N` lub ponowne włączenie zasilania. Echo ramek przechodzi z pola `CTRL.LOOPBACK` ([ADR 0008](0008-stan-lacza.md)) do `MODE_CTRL.FRAME_ECHO`; w `CTRL` pozostaje bit pętli near-end.

**8. Mapa rejestrów** (adresy bajtowe, wartości wielobajtowe little-endian):

| Adres | Nazwa | R/W | Zawartość |
|---|---|---|---|
| 0x00–0x01 | ID | R | `0x5F5B` |
| 0x02 | VERSION | R | wersja bitstreamu |
| 0x04 | CTRL | R/W | b0 `TX_EN`, b1 `RX_EN`, b2 `LB_NEAR`, b3 `SFP_TX_DIS`, b4 `LOS_IGNORE`, b6 `CNT_CLR` (zapis 1: kasowanie liczników), b7 `SOFT_RST` (zapis 1: reset mostka); po resecie `0x03` |
| 0x05 | STATUS | R | b0 `LINK_UP`, b1 `SYNC`, b2 `REMOTE_READY`, b3 `XOFF_LOCAL`, b4 `XOFF_REMOTE`, b5 `LOS`, b6 `TX_FAULT`, b7 `MOD_ABS` |
| 0x06 | STATUS_FAST | R | b0 `LINK_UP`, b1 `RX_AVAIL`, b2 `TX_READY` (miejsce na ramkę 1024 B), b3 `TX_EMPTY`, b4 `IRQ`, b5 `MODE_SEL` (stan zworki) |
| 0x07 | IRQ_EN | R/W | maska przerwań (bity jak `IRQ_STAT`) |
| 0x08 | IRQ_STAT | R/W1C | b0 `RX_FRAME`, b1 `TX_EMPTY`, b2 `LINK_CHG`, b3 `SFP_CHG`, b4 `I2C_DONE`, b5 `ERR` (zdarzenie błędu łącza lub zapis do pełnego FIFO TX) |
| 0x0A–0x0B | TX_SPACE | R | wolne bajty w FIFO TX |
| 0x0C–0x0D | RX_LEVEL | R | bajty zatwierdzonych ramek w FIFO RX |
| 0x10–0x2F | CNT_* | R | 8 liczników 32-bit ([ADR 0008](0008-stan-lacza.md)) |
| 0x30–0x4F | I2C, DDM | — | etap 8 (I2C i zarządzanie SFP) |
| 0x50 | MODE_CTRL | R/W | b0 `UART_MODE`, b1 `FRAME_ECHO`, b2 `RTSCTS_EN` (zachowywany przy resecie programowym) |
| 0x51–0x52 | UART_DIV | R/W | takty `clk_sys` na bit UART, po resecie 434 |
| 0x53 | UART_STATUS | R/W1C | b0 `RX_OVF`, b1 `FRAME_ERR` |
| 0x80–0xFF | I2C_BUF | — | etap 8 |

Nieopisane adresy: odczyt 0, zapis ignorowany. `HOST_IRQ_N` = 0, gdy (`IRQ_STAT` ∧ `IRQ_EN`) ≠ 0.

## Konsekwencje

- Biblioteka STM32 składa nagłówek ramki (3 bajty) i analizuje nagłówek odebranej ramki; jedna transakcja `RX_READ` może odczytać nagłówek i treść, jeśli host zna maksymalną długość (lub dwie transakcje: nagłówek, potem treść).
- Dummy cycles `READ_REG` i `RX_READ_x` pozostają: dają czas na publikację wskaźnika FIFO w domenie SCLK (uzgadnianie wymaga kilku taktów zegara odczytu).
- Zatrzask całej przestrzeni odczytu zajmuje ok. 70 bajtów rejestrów; multiplekser odczytu jest w domenie SCLK (ścieżki z zatrzasku są statyczne w czasie transakcji — wyjątek czasowy między domenami).
- Domena SCLK stosuje reset asynchroniczny (CS) dla maszyny stanów transakcji — odstępstwo od [ADR 0004](0004-strategia-resetu.md) wynikające z nieciągłego zegara.
- Przełączanie zegara przez DCS z `SELFORCE` może dać impuls niepełny; odbywa się wyłącznie w resecie strony hosta albo przy CS = 1 i zatrzymanym SCLK, gdy żaden rejestr strony hosta nie zmienia stanu.
