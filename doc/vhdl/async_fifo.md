# FIFO dwuzegarowe: `async_fifo`

Plik: `vhdl/sfp_bridge/src/fifo/async_fifo.vhd` · testbench: `vhdl/sim/tb/tb_async_fifo.vhd`

Bufor między domenami zegarowymi na bloku BSRAM, z **zatwierdzaniem i odrzucaniem ramki** po stronie zapisu. W mostku występuje dwukrotnie ([plan, rozdz. 7.2](../sfp-xspi-bridge-plan.md); [ADR 0005](../adr/0005-protokol-lacza.md)):

| Instancja | Zapis | Odczyt | Rola mechanizmu commit |
|---|---|---|---|
| FIFO nadawcze | `clk_spi` (host przez xSPI) | `clk_sys` (framer) | framer widzi tylko pełne ramki (zatwierdzane przez `xspi_slave` po ostatnim bajcie ramki) |
| FIFO odbiorcze | `clk_sys` (deframer) | `clk_spi` (host) | ramka z błędem jest odrzucana w całości (abort) |

## Interfejs

| Generyk | Domyślnie | Opis |
|---|---|---|
| `DATA_W` | 8 | szerokość słowa |
| `ADDR_W` | 12 | głębokość = 2^ADDR_W słów (4096) |
| `COMMIT_MODE` | `true` | `false`: każde słowo widoczne od razu, `wr_commit`/`wr_abort` ignorowane |
| `SYNC_STAGES` | 2 | liczba przerzutników synchronizatorów |

| Port | Domena | Opis |
|---|---|---|
| `wr_en`, `wr_data` | zapis | zapis słowa; przy `full = '1'` ignorowany i sygnalizowany `wr_ovf` |
| `wr_commit` | zapis | udostępnia czytelnikowi słowa zapisane od ostatniego zatwierdzenia (łącznie ze słowem z tego samego taktu) |
| `wr_abort` | zapis | odrzuca słowa niezatwierdzone; priorytet nad `wr_en` i `wr_commit` |
| `full` | zapis | dokładny względem własnych zapisów, ostrożny względem odczytów |
| `wr_free` | zapis | liczba wolnych słów (informacyjnie, takt opóźnienia) |
| `wr_cmt_level` | zapis | liczba słów zatwierdzonych i jeszcze nieodczytanych, widziana po stronie zapisu (takt opóźnienia; zawyżona o odczyty jeszcze niezsynchronizowane) — np. „w FIFO odbiorczym jest pełna ramka” w domenie `clk_sys`, gdy strona odczytu pracuje na nieciągłym zegarze hosta |
| `rd_en` | odczyt | odczyt słowa; przy `empty = '1'` ignorowany i sygnalizowany `rd_udf` |
| `rd_data`, `rd_valid` | odczyt | dane ważne takt po `rd_en` |
| `empty` | odczyt | dokładny względem własnych odczytów, ostrożny względem zapisów (tylko słowa zatwierdzone) |
| `rd_level` | odczyt | liczba zatwierdzonych słów (informacyjnie, takt opóźnienia) |

**Flagi i poziomy.** Sterowanie przepływem opiera się wyłącznie na `full` i `empty`. Poziomy `wr_free` i `rd_level` są rejestrowane z wartości sprzed zbocza: przez jeden takt po zapisie lub odczycie mogą zawyżać wolne miejsce lub liczbę słów o jedno słowo. Progi oparte na poziomach (np. próg XOFF) muszą mieć zapas co najmniej jednego słowa.

## Przejście między domenami

| Kierunek | Metoda | Uzasadnienie |
|---|---|---|
| wskaźnik odczytu → strona zapisu | kod Graya przez `SYNC_STAGES` przerzutników | wskaźnik zmienia się o 1 na odczyt — w kodzie Graya zmienia się jeden bit, więc próbka jest zawsze starą albo nową wartością; bezpieczne także przy zatrzymanym zegarze odczytu |
| zatwierdzony wskaźnik zapisu → strona odczytu | handshake żądanie/potwierdzenie | zatwierdzenie przesuwa wskaźnik o całą ramkę naraz — kod Graya zmieniłby wiele bitów; wartość binarna `pub_ptr` jest trzymana bez zmian, a przełączany bit `pub_req` przechodzi przez synchronizator; strona odczytu pobiera wtedy `pub_ptr` i odsyła `pub_ack` |

**Zegar xSPI nie jest ciągły** (SCLK hosta biegnie tylko w czasie transakcji). Wymaganie handshake: kolejne zatwierdzenie w odstępie krótszym niż ok. `2·SYNC_STAGES + 2` taktów zegara zapisu od poprzedniego jest publikowane dopiero po powrocie potwierdzenia, co wymaga dalszych taktów zegara zapisu. Zapis ramki przez xSPI zawsze trwa znacznie dłużej, więc warunek jest spełniony.

## Implementacja i czasy

- Pamięć: 4096 × 8 bitów → 2 bloki BSRAM w trybie SDPB (port A zapis, port B odczyt, osobne zegary), odczyt synchroniczny, bez resetu tablicy.
- Flagi `full`/`empty` na następny takt wyznaczane są wyłącznie porównaniami równości z wartościami policzonymi wcześniej w rejestrach (wskaźnik − 1, wskaźnik z odwróconym bitem zawinięcia) — w pętli sprzężenia nie ma sumatora. Cztery porównania dla `empty` liczone są równolegle, multiplekser wybiera wynik 1-bitowy.
- Konwersja Gray → binarny: zrównoważone drzewa XOR, wynik rejestrowany.

Próbna synteza (4096 × 8, oba zegary 100 MHz, GW1N-9C): 273 LUT, 190 rejestrów, 2 BSRAM; Fmax zapisu 101,3 MHz, odczytu 101,4 MHz. W mostku FIFO pracuje przy `clk_sys` = 50 MHz ([ADR 0007](../adr/0007-zegar-systemowy-50mhz.md)) i `clk_spi` ≤ 50 MHz — zapas ok. 2×. Ścieżki krytyczne (porównania i liczniki 13-bitowe, ok. 9 ns) wyznaczają granicę szybkości logiki GW1N-9.

## Testbench `tb_async_fifo`

Model odniesienia: kolejka słów zatwierdzonych (typ chroniony); słowa ramki w toku są przenoszone do kolejki przy zatwierdzeniu lub odrzucane.

| Nr | Sprawdzenie |
|---|---|
| 1 | zapełnienie przy zatrzymanym czytelniku: `full` po dokładnie 16 słowach, kolejny zapis ignorowany z `wr_ovf`, odczyt wszystkich słów w kolejności |
| 2 | 600 losowych ramek 1–10 słów, 25% odrzucanych, zatwierdzenie razem z ostatnim słowem lub osobno; każde zatwierdzone słowo odczytane raz i w kolejności, żadne odrzucone |
| 3 | proporcje zegarów: zapis 100 MHz / odczyt 37,3 MHz, potem 160 MHz, potem zegar odczytu zatrzymany na 3 µs (model SCLK) |
| 4 | w każdym takcie: `rd_level` ≤ słowa w modelu + 1; `empty` ⇒ `rd_level` ≤ 1; `full` ⇒ `wr_free` ≤ 1; `wr_free` ≤ 16; `wr_cmt_level` + `wr_free` ≤ 16 (po zapełnieniu `wr_cmt_level` = 16, po opróżnieniu 0) |
| 5 | odczyt z pustego FIFO: `rd_udf`, brak danych |
| 6 | po opróżnieniu: `empty`, `rd_level` = 0, `wr_free` = 16, liczba odczytanych = liczba zatwierdzonych |
| 7 | instancja `COMMIT_MODE = false`: 3000 słów strumieniowo, kolejność zachowana |

**Test mutacyjny:** wykryte — brak cofnięcia przy `abort`, pominięcie `full` przy zapełniającym zapisie, publikacja słów niezatwierdzonych, błędna flaga `empty` po odczycie. Niewykrywalne w symulacji RTL (z natury): zwarcie potwierdzenia handshake — błąd przejścia między domenami ujawnia się dopiero przy metastabilności, której symulator nie modeluje; poprawność tej części potwierdza przegląd kodu.

## Przebieg

`.\view.ps1 tb_async_fifo` — czas symulacji ok. 0,1 ms. Głębokość w testbenchu: 16 słów (wskaźniki 5-bitowe, wartości w formacie dziesiętnym).

| Faza (`phase`) | Czas (ok.) | Co widać |
|---|---|---|
| 1 — zapełnienie | 0,3–2 µs | `wr_data` 0x64…0x73, `wptr` rośnie 0→16 przy `wptr_cmt` = 0, ostatni zapis z `wr_commit` → `wptr_cmt` = 16, `full` = 1, impuls `wr_ovf`. Po kilku taktach `pub_req` zmienia stan, chwilę później `pub_ack` i `wcmt_r` = 16, `empty` opada; czytelnik opróżnia FIFO |
| 2 — losowe ramki | do ok. 90 µs | krótkie serie `wr_en`, impulsy `wr_commit` lub `wr_abort` (po `wr_abort` `wptr` wraca do `wptr_cmt`); każde zatwierdzenie kończy się parą zmian `pub_req` → `pub_ack`. Od ramki 200 (`frame_no`) `rd_clk` przyspiesza, od 350 zatrzymuje się na 3 µs — `full` = 1 i zapis czeka |
| 3, 4 | koniec | opróżnienie, potem strumień przez drugą instancję (`dut2`, niewidoczna w widoku) |
