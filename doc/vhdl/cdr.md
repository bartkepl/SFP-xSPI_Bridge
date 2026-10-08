# Odzysk danych: `cdr_os4x8`

Plik: `vhdl/sfp_bridge/src/link/cdr_os4x8.vhd` · testbench: `vhdl/sim/tb/tb_cdr_os4x8.vhd`

Programowy odzysk danych (soft-CDR) z sygnału nadpróbkowanego 4× ([plan, rozdz. 7.2](../sfp-xspi-bridge-plan.md); [ADR 0007](../adr/0007-zegar-systemowy-50mhz.md)). Deserializer `IDES8` przy FCLK = 200 MHz (DDR, 400 Msps) dostarcza 8 próbek na takt `clk_sys` = 50 MHz, czyli 2 okresy bitu przy 100 Mbaud. Moduł wybiera jedną z czterech faz próbkowania, śledzi ją na podstawie położenia zboczy i oddaje 1, 2 lub 3 bity na takt (nominalnie 2). Wydanie 1 lub 3 bitów przy zawinięciu fazy kompensuje różnicę częstotliwości generatorów obu stron łącza, więc tor odbiorczy nie wymaga bufora elastycznego.

Zasada działania jest pokrewna Xilinx XAPP224 / XAPP523 (wybór fazy próbkowania z nadpróbkowania); detektor fazy i reguła decyzji są własne.

## Interfejs

| Generyk | Domyślnie | Opis |
|---|---|---|
| `WIN_LOG2` | 5 | okno statystyki zboczy = 2^WIN_LOG2 taktów (32 takty = 64 bity) |
| `MIN_EDGES` | 8 | minimalna liczba zboczy w oknie, przy której zapada decyzja |

| Port | Kierunek | Opis |
|---|---|---|
| `clk`, `rst` | in | `clk_sys`, reset synchroniczny |
| `samples[7:0]` | in | próbki z `IDES8`, `samples(0)` najwcześniejsza |
| `bits[2:0]` | out | odzyskane bity, `bits(0)` najwcześniejszy |
| `nbits[1:0]` | out | liczba ważnych bitów: 1–3 (0 tylko w resecie) |
| `phase[1:0]` | out | bieżąca faza próbkowania (diagnostyka) |
| `shift_up`, `shift_dn` | out | impuls: faza przesunięta później / wcześniej |
| `activity` | out | ostatnie okno zawierało co najmniej `MIN_EDGES` zboczy |

**Opóźnienie:** 2 takty od `samples` do `bits`.

## Detektor fazy

Próbki są numerowane globalnie: n = 8·takt + i; klasa fazowa próbki to n mod 4. Zbocze w klasie k oznacza, że próbki k−1 i k się różnią, czyli granica bitu leży między nimi. Liczniki zboczy dla każdej z czterech klas sumują się przez okno 2^WIN_LOG2 taktów.

Przy fazie próbkowania p klasa względna zbocza r = (k − p) mod 4 mówi, że granica bitu leży w przedziale (r−1, r] okresów próbkowania po chwili próbkowania (r = 0: w okresie przed nią). Położenie idealne to 2 okresy po chwili próbkowania — próbka w środku bitu, zbocza rozłożone po równo między r = 2 i r = 3.

Średnie odchylenie granic od położenia idealnego (w połówkach okresu próbkowania):

S = 3·n0 + n3 − n2 − 3·n1

gdzie n_r to liczba zboczy klasy względnej r (klasa r = 0 liczona jako opóźnienie +1,5 okresu).

Na końcu okna, przy tot = n0 + n1 + n2 + n3 ≥ `MIN_EDGES`, obowiązuje pierwsza spełniona reguła:

| Warunek | Decyzja | Znaczenie |
|---|---|---|
| n0 + n1 > n2 + n3 | p + 1 przy n0 ≥ n1, w przeciwnym razie p − 1 | większość granic leży w odległości do jednego okresu od chwili próbkowania; S jest tu niejednoznaczne (n0 = n1 daje S = 0 w najgorszej fazie) |
| 4·S > 5·tot | p + 1 | średnie odchylenie > +0,625 okresu: próbkować później |
| 4·S < −5·tot | p − 1 | średnie odchylenie < −0,625 okresu |

Krok fazy przesuwa średnią o jeden okres. Strefa martwa ±0,625 okresu (1/2 + 1/8 histerezy) wyklucza powrót po kroku, więc losowy jitter nie przełącza fazy. Z fazy najgorszej (granice dokładnie w chwilach próbkowania) układ dochodzi do fazy właściwej w jednym–dwóch oknach.

**Zakres śledzenia:** jeden krok (1/4 UI) na okno 2·2^WIN_LOG2 bitów; przy `WIN_LOG2` = 5 to ok. 3900 ppm. Generatory ±50 ppm po obu stronach dają najwyżej 100 ppm.

## Wybór bitów

Bity są pobierane z próbek klasy p i p+4 każdego taktu. Krok fazy zmienia odstęp do następnej próbki z 4 na 5 lub 3 próbki:

| Sytuacja | Bity (od najwcześniejszego) | `nbits` |
|---|---|---|
| bez zmiany | `samples(p)`, `samples(p+4)` | 2 |
| p → p+1, p < 3 | `samples(p+1)`, `samples(p+5)` | 2 |
| p = 3 → 0 | `samples(4)` | 1 |
| p → p−1, p > 0 | `samples(p−1)`, `samples(p+3)` | 2 |
| p = 0 → 3 | `samples(7)` poprzedniego taktu, `samples(3)`, `samples(7)` | 3 |

Nadajnik szybszy od odbiornika (więcej bitów na takt) powoduje kroki p − 1 i takty z 3 bitami; wolniejszy — kroki p + 1 i takty z 1 bitem.

## Implementacja i czasy

- Stopień 0: rejestr próbek. Stopień A: wykrycie zboczy (także między taktami, przez zapamiętaną próbkę 7), akumulacja liczników klas, wybór bitów i aktualizacja fazy. Trzy stopnie decyzji raz na okno: obrót liczników do fazy p, sumy ważone, porównanie.
- Liczniki zboczy są prowadzone w klasach bezwzględnych, więc krok fazy w trakcie okna nie zaburza statystyki.

Próbna synteza (GW1N-9C, ograniczenie 12 ns): sam moduł — ok. 320 LUT/ALU, 120 rejestrów; tor odbiorczy `cdr_os4x8` + [`comma_align`](comma_align.md) + `dec_8b10b` — 436 LUT/ALU, 203 rejestry, 1 BSRAM, Fmax 83,4 MHz (zapas ok. 1,7× przy `clk_sys` = 50 MHz).

## Testbench `tb_cdr_os4x8`

Strumień 8b/10b (losowe bajty, 10% K28.5) przechodzi przez model linii `t_line` ([`tb_pkg`](symulacja.md)): okres bitu UI = 10 ns / (1 + ppm·10⁻⁶), niezależny jitter każdej granicy bitu o rozkładzie jednostajnym ±J·UI. Odbiornik próbkuje linię co 2,5 ns i podaje 8 próbek na takt 20 ns. Każdy scenariusz trwa 25 000 taktów (50 000 bitów) i zaczyna się od resetu; kontrola obejmuje bity po 400 taktach na zestrojenie.

| Nr | Odchyłka | Jitter | Uwagi |
|---|---|---|---|
| 1 | 0 ppm | 0 | losowa faza początkowa |
| 2 | 0 ppm | ±0,20 UI | |
| 3, 4 | +100 / −100 ppm | ±0,20 UI | |
| 5, 6 | +1000 / −1000 ppm | ±0,10 UI | |
| 7 | +200 ppm | ±0,25 UI | |
| 8 | −100 ppm | ±0,20 UI | sam ciąg bezczynności K28.5 D16.2 |
| 9, 10 | 0 ppm | 0 / ±0,20 UI | granice bitów dokładnie w początkowych chwilach próbkowania (najgorsza faza startowa) |
| 11 | +100 ppm | ±0,30 UI | zapas ponad wymaganie ±0,20 UI |

Sprawdzenia w każdym scenariuszu:

1. Odzyskany ciąg bitów pokrywa się z nadanym przy jednoznacznym przesunięciu (okno 64 bitów, zakres ±9 bitów — ciąg bezczynności powtarza się co 20 bitów).
2. Brak błędów bitowych po zestrojeniu.
3. (takty z 3 bitami − takty z 1 bitem) = (odzyskane bity − 2·takty).
4. Bilans kroków fazy (`shift_dn` − `shift_up`) odpowiada odchyłce: 8·takty·ppm·10⁻⁶ ± 2.
5. Bez odchyłki częstotliwości najwyżej 2 kroki fazy po zestrojeniu.

**Test mutacyjny:** wykrywane — brak reguły zboczy bliskich (scenariusze 9, 10), odwrócony kierunek kroku, błędny bit przy zawinięciu 0 → 3, pominięcie zbocza między taktami. Zamiana `samples(4)` na `samples(3)` przy zawinięciu 3 → 0 nie jest wykrywana: w chwili kroku obie próbki leżą w tym samym bicie (mutacja praktycznie równoważna).

## Przebieg

`.\view.ps1 tb_cdr_os4x8` — czas symulacji ok. 5,5 ms; scenariusz `scen_no` = k trwa od ok. (k−1)·0,5 ms do k·0,5 ms.

| Czas (ok.) | Scenariusz | Co widać |
|---|---|---|
| 0–2 µs | 1 | po zwolnieniu `rst` `nbits` = 2, `bits` zmienia się co takt; `wcnt` liczy 0…31, na końcu każdego okna `tot_q` ok. 35–45 zboczy, `late_q` i `early_q` bliskie sobie, `phase` stała |
| 1,0–1,5 ms | 3 (+100 ppm) | co ok. 1250 taktów impuls `shift_dn`, `phase` maleje; przy przejściu 0 → 3 jeden takt z `nbits` = 3 |
| 1,5–2,0 ms | 4 (−100 ppm) | impulsy `shift_up`; przy przejściu 3 → 0 takt z `nbits` = 1 |
| 2,0–3,0 ms | 5, 6 (±1000 ppm) | kroki fazy co ok. 125 taktów |
| 4,0–4,5 ms | 9 | na początku `near_q` = 1 w pierwszym oknie i krok fazy, potem faza stała |
| cały czas | — | `bit_errs` = 0 (aktualizowany na końcu scenariusza) |
