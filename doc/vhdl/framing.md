# Ramkowanie łącza: `tx_framer`, `rx_deframer`

Pliki: `vhdl/sfp_bridge/src/link/tx_framer.vhd`, `rx_deframer.vhd` · testbench: `vhdl/sim/tb/tb_link_frames.vhd`

Warstwa znaków protokołu łącza zgodnie z [ADR 0005](../adr/0005-protokol-lacza.md): ramki z CRC-32, sekwencje bezczynności niosące stan XON/XOFF, odrzucanie ramek z błędem bez retransmisji.

## Strumień znaków

| Element | Znaki | Uwagi |
|---|---|---|
| bezczynność /I/ (XON) | K28.5 D16.2 | zwykła bezczynność, przywraca RD− |
| bezczynność /P/ (XOFF) | K28.5 D21.5 | „nie rozpoczynaj nowych ramek” |
| ramka | K27.7 · TYPE · LEN_H · LEN_L · treść · CRC0 · CRC1 · CRC2 · CRC3 · K29.7 | CRC-32 po TYPE, LEN, treści; CRC0 = bity 7…0 |

Format ramki w FIFO (nadawczym i odbiorczym) jest ten sam: `TYPE, LEN_H, LEN_L, treść`. Host zapisuje i odczytuje ramki w tej postaci; bajty CRC i znaki sterujące istnieją tylko na łączu.

## `tx_framer`

| Port | Opis |
|---|---|
| `char_en` | koder pobiera znak (`char_data`, `char_k`) — raz na symbol (10 okresów bitu = 5 taktów `clk_sys`) |
| `char_data`, `char_k` | znak przygotowany dla kodera; po `char_en` przygotowywany jest następny |
| `fifo_*` | port odczytu FIFO nadawczego (`async_fifo`, opóźnienie 1 takt) |
| `xoff_local` | stan własnego odbiornika: wysyłaj /P/ zamiast /I/ |
| `xoff_remote` | strona przeciwna zgłasza XOFF: nie rozpoczynaj ramek |
| `busy`, `frame_sent`, `len_err` | ramka w toku; impuls po przygotowaniu K29.7; LEN > MAX_LEN w FIFO |

**Zasady:**

- Ramka startuje tylko po pełnej parze bezczynności, gdy FIFO nie jest puste (ramki są zatwierdzane w całości, więc niepuste FIFO oznacza kompletną ramkę) i `xoff_remote = '0'`.
- Rozpoczęta ramka jest wysyłana do końca, bez przerw.
- Drugi znak każdej pary bezczynności niesie bieżący stan `xoff_local`, więc stan jest powtarzany ciągle.
- Bajt z FIFO jest pobierany z wyprzedzeniem (bufor jednego bajtu); CRC jest gotowe przed CRC0, bo znaki dzieli co najmniej kilka taktów.

**Założenia:** `char_en` nie częściej niż co 4 takty (nominalnie co 5 taktów `clk_sys` = 50 MHz). LEN = 0 jest wysyłane jako ramka bez treści; LEN > MAX_LEN jest wysyłane z pełną długością (FIFO pozostaje wyrównane) i sygnalizowane `len_err` — odbiornik odrzuca taką ramkę. Poprawność LEN należy do zapisującego (moduł hosta).

## `rx_deframer`

| Port | Opis |
|---|---|
| `sync` | wyrównanie znaków ważne (z `comma_align` / `link_ctrl`) |
| `char_*`, `code_err`, `disp_err` | znaki z dekodera `dec_8b10b` |
| `fifo_wr`, `fifo_data`, `fifo_commit`, `fifo_abort` | port zapisu FIFO odbiorczego (`async_fifo`, `COMMIT_MODE = true`) |
| `fifo_free`, `fifo_ovf` | wolne miejsce i przepełnienie FIFO odbiorczego |
| `xoff_remote` | stan XOFF odebrany od strony przeciwnej (do własnego `tx_framer`) |
| `xoff_local` | żądanie XOFF wynikające z zapełnienia własnego FIFO (do własnego `tx_framer`) |
| `ev_*` | impulsy zdarzeń dla liczników i przerwań |

**Kontrole ramki** — błąd powoduje `fifo_abort` (wszystkie bajty ramki usunięte z FIFO) i jeden impuls zdarzenia:

| Zdarzenie | Warunek |
|---|---|
| `ev_code_err` | `code_err` lub `disp_err` wewnątrz ramki |
| `ev_len_err` | LEN = 0 lub > MAX_LEN; K29.7 przed pozycją wynikającą z LEN; brak K29.7 na tej pozycji |
| `ev_framing` | nieoczekiwany znak sterujący wewnątrz ramki |
| `ev_crc_err` | niezgodne CRC-32 |
| `ev_ovf` | za mało miejsca w FIFO na ramkę (sprawdzane po odebraniu LEN) lub przepełnienie |
| `ev_frame_ok` | ramka zatwierdzona (`fifo_commit`) |

Po błędzie odbiornik pomija resztę ramki do najbliższego K28.5. Przy `sync = '0'` ramka w toku jest odrzucana bez zdarzenia, a `xoff_remote` jest ustawiane na `'1'` (stan strony przeciwnej nieznany).

## Progi XOFF i rozmiar FIFO odbiorczego

Stan XOFF dociera do strony przeciwnej tylko w przerwach między własnymi ramkami nadawanymi. W najgorszym razie po przekroczeniu progu odbiornik musi jeszcze przyjąć: ramkę w toku, ramkę, którą strona przeciwna zdąży rozpocząć, zanim zakończy się nasza ramka (do 1027 B), oraz zapas:

| Parametr | Wartość domyślna | Wyznaczenie |
|---|---|---|
| `XOFF_ON` | 3145 B wolnego miejsca | 3 × (1024 + 3) + 64 |
| `XOFF_OFF` | 4169 B wolnego miejsca | `XOFF_ON` + 1024 (histereza) |

`XOFF_OFF` musi być mniejsze od głębokości FIFO, dlatego **FIFO odbiorcze ma 8 KiB** (4 bloki BSRAM). FIFO nadawcze pozostaje 4 KiB.

## Testbench `tb_link_frames`

Pełne łącze dwukierunkowe na poziomie znaków (bez serializera i CDR), zegar 50 MHz, znak co 5 taktów: strona A — FIFO TX, `tx_framer`, `enc_8b10b`; kanał z możliwością przekłamań; strona B — `dec_8b10b`, `rx_deframer`, FIFO RX 8 KiB i czytelnik. Kierunek odwrotny przenosi pary bezczynności strony B (stan XOFF) do strony A. Treść, typ i długość ramki są funkcjami jej numeru; numery ramek, które muszą dotrzeć, są w kolejce porównywanej przez czytelnika.

| Faza | Sprawdzenie |
|---|---|
| 1 | 20 ramek 1–300 B dostarczonych w całości i kolejności |
| 2 | 6 ramek z jednym odwróconym bitem symbolu (TYPE, LEN_L, treść, CRC): każda odrzucona z dokładnie jednym zdarzeniem; sąsiednie ramki dostarczone |
| 2b | 3 ramki z błędnym bajtem w poprawnym symbolu (treść, CRC0, TYPE): każda odrzucona z `ev_crc_err` |
| 3 | LEN = 0 i LEN = 1025 od hosta: oba odrzucone z `ev_len_err`; framer zgłasza `len_err` dla 1025 |
| 4 | utrata synchronizacji znaków w środku ramki: ramka odrzucona, następna dostarczona |
| 5 | czytelnik zatrzymany, 16 ramek po 1000 B (2× FIFO RX): strona B zgłasza XOFF, strona A wstrzymuje nadawanie na co najmniej 10 000 taktów (200 µs); po wznowieniu wszystkie ramki dostarczone, brak przepełnienia, XOFF zwolniony |
| 6 | wszystkie oczekiwane ramki odebrane; zdarzenia błędów: 6 + 3 + 2 = 11 |

Odwrócenie jednego bitu symbolu 8b/10b daje prawie zawsze błąd kodu lub dysparytetu, a nie błąd CRC — dlatego faza 2b wprowadza błędny bajt przed koderem, co sprawdza ścieżkę CRC.

**Test mutacyjny:** wykryte — zatwierdzenie ramki mimo złego CRC, brak odrzucenia przy błędzie linii, framer ignorujący XOFF, zamieniona kolejność bajtów CRC, odbiornik nigdy nie zgłaszający XOFF.

## Synteza i czasy

Próbna synteza toru znakowego jednej strony (FIFO TX 4 KiB, framer, koder, dekoder, deframer, FIFO RX 8 KiB): 1104 LUT, 585 rejestrów, 7 BSRAM (6 SDPB + 1 ROM), **Fmax 70 MHz** przy wymaganych 50 MHz ([ADR 0007](../adr/0007-zegar-systemowy-50mhz.md)). Ścieżki krytyczne (13–14 ns) to logika decyzyjna deframera za dekoderem i funkcja kodera; obie działają raz na znak (co 5 taktów). Przy ograniczeniu 50 MHz PnR zamyka czasy bez naruszeń (TNS = 0) z Fmax 57,6 MHz; wartość 70 MHz uzyskano przy ograniczeniu 100 MHz — Gowin PnR optymalizuje do zadanego ograniczenia, więc w pełnym projekcie ograniczenie `clk_sys` w `.sdc` warto ustawić z zapasem (np. 60 MHz).

## Przebieg

`.\view.ps1 tb_link_frames` — czas symulacji ok. 2,8 ms.

| Czas (ok.) | Faza | Co widać |
|---|---|---|
| 0–0,1 µs | start | `a_cd` przemiennie `BC` (K28.5, `a_ck = 1`) i `50` (D16.2) — pary bezczynności |
| 1 µs – 0,35 ms | 1 | ramki: `FB` (K27.7), TYPE, LEN, treść, 4 bajty CRC, `FD` (K29.7); po stronie B `b_fw` przy każdym bajcie, `b_fc` i `ev_ok` na końcu ramki |
| 0,35–0,5 ms | 2, 2b | `corrupt_mask` lub `char_mask` ≠ 0 przez jeden takt; zaraz potem `b_dce`/`b_dde` lub (2b) `ev_crc`, `b_fa` — ramka usunięta z FIFO |
| ok. 0,55 ms | 3 | dwa impulsy `ev_len` |
| ok. 0,6 ms | 4 | `b_sync` = 0 na 25 taktów (0,5 µs) w środku ramki, `b_fa` |
| 0,7–1,4 ms | 5 | `reader_on` = 0, `b_rlevel` rośnie do ok. 5000; `b_xoff_local` = 1, chwilę później `a_xoff_remote` = 1 i `a_busy` pozostaje 0 (strona B nadaje bezczynność /P/: K28.5 D21.5); po wznowieniu czytelnika poziom spada, XOFF wraca do 0 |
