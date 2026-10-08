# Wyrównanie symboli: `comma_align`

Plik: `vhdl/sfp_bridge/src/link/comma_align.vhd` · testbench: `vhdl/sim/tb/tb_comma_align.vhd`

Wyznacza granice 10-bitowych symboli w strumieniu bitów z [`cdr_os4x8`](cdr.md) (1–3 bity na takt) i prowadzi synchronizację znakową łącza ([plan, rozdz. 7.2](../sfp-xspi-bridge-plan.md)). Proces synchronizacji jest uproszczoną wersją procesu z 1000BASE-X PCS (IEEE 802.3, rozdz. 36). Wyjście `sync` steruje wejściem `sync` modułu [`rx_deframer`](framing.md).

## Interfejs

| Generyk | Domyślnie | Opis |
|---|---|---|
| `N_SYNC` | 4 | liczba comma w oczekiwanej pozycji potrzebna do synchronizacji |
| `N_LOSS` | 4 | stan licznika błędów, przy którym synchronizacja jest tracona |
| `GOOD_RUN` | 4 | liczba kolejnych poprawnych symboli zmniejszająca licznik błędów o 1 |

| Port | Kierunek | Opis |
|---|---|---|
| `clk`, `rst` | in | `clk_sys`, reset synchroniczny |
| `restart` | in | wymuszenie utraty synchronizacji (np. LOS modułu SFP) |
| `in_bits[2:0]`, `in_n[1:0]` | in | bity z `cdr_os4x8`, `in_bits(0)` najwcześniejszy, `in_n` = 1…3 |
| `sym[9:0]` | out | wyrównany symbol, `sym(0)` = bit a (odebrany pierwszy) — do `dec_8b10b` |
| `sym_valid` | out | nowy symbol (co 5 taktów nominalnie) |
| `sym_comma` | out | symbol zaczyna się od comma |
| `dec_valid`, `dec_err` | in | sprzężenie z `dec_8b10b`: wynik dekodowania i błąd (`code_err` lub `disp_err`) |
| `sync` | out | synchronizacja znakowa |
| `ev_realign` | out | impuls: przesunięcie granicy symbolu (tylko w stanie LOSS) |
| `ev_sync_loss` | out | impuls: przejście SYNC → LOSS |

## Comma i granica symbolu

Comma to bity a…g symbolu równe `0011111` lub `1100000`. W poprawnym strumieniu 8b/10b występuje wyłącznie w K28.1, K28.5 i K28.7, na początku symbolu; łącze używa K28.5 w sekwencji bezczynności ([ADR 0005](../adr/0005-protokol-lacza.md)). Wykryty comma wyznacza granicę: po jego 7 bitach 3 kolejne bity kończą symbol.

Moduł sprawdza w każdym takcie do trzech położeń comma — kończących się na każdym z nowych bitów. Comma jest „w oczekiwanej pozycji”, gdy licznik bitów bieżącego symbolu wskazuje w tym miejscu 7 bitów.

## Synchronizacja

| Stan | Zdarzenie | Działanie |
|---|---|---|
| LOSS (`sync` = 0) | comma w innej pozycji | przesunięcie granicy (`ev_realign`), good := 1 |
| | comma w oczekiwanej pozycji | good := good + 1; przy good = `N_SYNC` → SYNC |
| | błąd dekodera | good := 0 (granica bez zmian) |
| SYNC (`sync` = 1) | błąd dekodera lub comma w innej pozycji | err := err + 1; granica **nie** jest przesuwana |
| | `GOOD_RUN` kolejnych poprawnych symboli | err := err − 1 (gdy > 0) |
| | err = `N_LOSS` | → LOSS (`ev_sync_loss`) |
| dowolny | `restart` = 1 | → LOSS |

Wymaganie poprawnego dekodowania między comma (good := 0 przy błędzie) zapobiega synchronizacji na przypadkowych wzorcach comma w szumie. Licznik błędów z ubywaniem po serii poprawnych symboli sprawia, że pojedyncze przekłamania bitów nie zrywają synchronizacji; poślizg bitu (zgubiony lub powielony bit) daje ciąg błędów i utratę synchronizacji po kilku symbolach, a następnie ponowne wyrównanie na najbliższych comma.

Znaki odebrane po poślizgu bitu, a przed utratą synchronizacji, są błędne; dekoder zgłasza dla nich błędy, a `rx_deframer` odrzuca ramkę w toku.

## Implementacja i czasy

| Stopień | Działanie |
|---|---|
| 1 | wsunięcie nowych bitów do rejestru 12-bitowego (najnowszy bit na górze; `sr(11 downto 2)` to ostatnie 10 bitów) |
| 2 | wyszukiwanie comma w 3 położeniach, licznik bitów symbolu, wyprowadzenie symbolu (multiplekser przesunięcia 0–2 bitów) |
| 3 | maszyna stanów synchronizacji (wynik comma ze stopnia 2 w rejestrze, sprzężenie z dekodera) |

**Opóźnienie:** 2 takty od ostatniego bitu symbolu do `sym_valid`; dekoder dodaje 2 takty. Przesunięcie granicy w stopniu 2 korzysta ze stanu synchronizacji ze stopnia 3; takt różnicy jest bez znaczenia, bo comma w oczekiwanej pozycji nigdy nie przesuwa granicy.

Próbna synteza toru odbiorczego `cdr_os4x8` + `comma_align` + `dec_8b10b` (GW1N-9C, ograniczenie 12 ns): 436 LUT/ALU, 203 rejestry, 1 BSRAM, Fmax 83,4 MHz. Wydzielenie maszyny stanów do stopnia 3 skróciło ścieżkę krytyczną z 15,8 ns (63 MHz).

## Testbench `tb_comma_align`

Moduł pracuje razem z `dec_8b10b` (sprzężenie zwrotne). Strumień bitów jest przygotowany z góry: losowe znaki 8b/10b, w tym 10% K28.5 w dowolnych miejscach danych. Bity są podawane po 1, 2 lub 3 na takt (10% / 80% / 10%), jak z CDR. Zdarzenia rozpoczynają segmenty (po 3000 znaków):

| Segment | Zdarzenie | Oczekiwane zachowanie |
|---|---|---|
| 0 | 237 losowych bitów, 12 × (K28.5, `0000000000`), potem strumień znaków | brak synchronizacji na fałszywych comma (comma co 20 bitów, ale niepoprawne symbole między nimi); synchronizacja na strumieniu |
| 1 | zgubiony bit | utrata i ponowne uzyskanie synchronizacji |
| 2 | powielony bit | utrata i ponowne uzyskanie synchronizacji |
| 3 | odwrócony bit | synchronizacja utrzymana |
| 4 | impuls `restart` | utrata i ponowne uzyskanie synchronizacji |
| 5 | 6 odwróconych bitów co 40 znaków | synchronizacja utrzymana (licznik błędów maleje) |

Okres ciągłego `sync` = 1 to epoka. Sprawdzenia:

1. Dokładnie 4 epoki; każda synchronizacja w ciągu 200 znaków od początku strumienia lub od zdarzenia.
2. Liczba `ev_sync_loss` = 3 (segmenty 1, 2, 4).
3. W każdej epoce (od 4. znaku) znaki zdekodowane są kolejnym fragmentem nadanego strumienia — bez braków i nadmiarowych znaków; najwyżej 2 błędne znaki na odwrócony bit, poza tym żadnych; co najmniej 2000 porównanych znaków na epokę.
4. `sym_comma` = 1 dokładnie dla symboli zdekodowanych jako K28.5 (bez symboli z błędem dekodera).

**Test mutacyjny:** wykrywane — przesuwanie granicy w stanie SYNC, brak zmniejszania licznika błędów, przesunięcie okna wyprowadzania symbolu o 1 bit, błędna oczekiwana pozycja comma, ignorowanie błędów dekodera w stanie LOSS (segment 0, fałszywe comma) i w stanie SYNC.

## Przebieg

`.\view.ps1 tb_comma_align` — czas symulacji ok. 1,8 ms; segment trwa ok. 0,3 ms (`seg`).

| Czas (ok.) | Co widać |
|---|---|
| 0–5 µs | losowe bity i fałszywe comma: impulsy `ev_realign`, `good` rośnie do 1–2 i wraca do 0 po `dec_err`; `sync` = 0 |
| ok. 5–6 µs | strumień znaków: comma w oczekiwanej pozycji (`aln_q` = 1), `good` rośnie do 4, `sync` = 1, `epoch` = 1 |
| w synchronizacji | `sym_valid` co ok. 5 taktów, `cnt` liczy bity symbolu; przy K28.5 `sym_comma` = 1, a 2 takty później `dec_data` = BC, `dec_k` = 1 |
| ok. 0,3 ms (`seg` = 1) | po zgubionym bicie seria `dec_err`, `err` rośnie do 4, `ev_sync_loss`, następnie `ev_realign` i ponowna synchronizacja (`epoch` = 2) |
| ok. 0,6 ms (`seg` = 2) | to samo dla powielonego bitu |
| ok. 0,9 ms (`seg` = 3) | jeden lub dwa `dec_err` (błędny symbol, ewentualnie dysparytet następnego), `err` wraca do 0 po serii poprawnych symboli, `sync` bez zmian |
| ok. 1,2 ms (`seg` = 4) | impuls `restart`: `sync` = 0 i ponowna synchronizacja |
| ok. 1,5 ms (`seg` = 5) | sześć pojedynczych zdarzeń błędu w odstępach, `err` nie przekracza 2, `sync` bez zmian |
