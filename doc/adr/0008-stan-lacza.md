# 0008. Stan łącza: gotowość odbiornika w sekwencji bezczynności, LOS, liczniki, pętle zwrotne

**Stan:** przyjęta · **Data:** 2026-10-08
**Dotyczy:** vhdl, doc, firmware (uzupełnia [ADR 0005](0005-protokol-lacza.md))

## Kontekst

Protokół z [ADR 0005](0005-protokol-lacza.md) przenosi w sekwencji bezczynności stan XON/XOFF odbiornika. Nadajnik nie ma jednak informacji, czy odbiornik strony przeciwnej uzyskał synchronizację znakową: strona, której odbiornik jest już zsynchronizowany, może rozpocząć nadawanie ramek, zanim zsynchronizuje się druga strona — takie ramki są tracone bez zgłoszenia błędu u nadawcy. Test pełnej pętli łącza (`tb_link_loopback`) wymagał z tego powodu oczekiwania na synchronizację obu końców po stronie hosta.

Moduł sterowania łączem (`link_ctrl`) wymaga ponadto ustaleń: kryterium stanu łącza, obsługa sygnału LOS modułu SFP, zachowanie liczników błędów i ramek (rejestry `CNT_*`) oraz rodzaje pętli zwrotnych do testów.

## Rozważane warianty

Sygnalizacja gotowości odbiornika:

1. **Trzeci wariant pary bezczynności** — osobny znak „odbiornik niezsynchronizowany”; XOFF pozostaje wyłącznie sterowaniem przepływem.
2. **XOFF jako brak gotowości** — strona bez synchronizacji nadaje /P/; bez nowego znaku, ale XOFF z zapełnienia FIFO i z braku synchronizacji są nierozróżnialne, więc stan łącza nie obejmuje strony przeciwnej.

Pętla zwrotna strony przeciwnej (far-end):

1. **Echo ramek** — ramki odebrane są nadawane z powrotem bez zmian (FIFO RX → FIFO TX).
2. **Echo znaków** — odebrane znaki nadawane z powrotem; wymaga bufora elastycznego z wstawianiem i usuwaniem par bezczynności (różnica częstotliwości generatorów).
3. Brak pętli far-end — echo realizuje oprogramowanie hosta.

Liczniki: zawijanie modulo 2³² z kasowaniem bitem sterującym albo nasycanie z kasowaniem odczytem. LOS: wymuszenie stanu DOWN z możliwością wyłączenia albo wyłącznie informacja w rejestrze stanu.

## Decyzja

**Gotowość odbiornika — wariant 1.** Para bezczynności przyjmuje trzy postacie:

| Nazwa | Znaki | Znaczenie |
|---|---|---|
| /I/ | K28.5 D16.2 | odbiornik zsynchronizowany, nadawanie dozwolone (XON) |
| /P/ | K28.5 D21.5 | odbiornik zsynchronizowany, wstrzymanie nowych ramek (XOFF) |
| /R/ | K28.5 D5.6 | odbiornik niezsynchronizowany lub wyłączony — wstrzymanie nowych ramek |

- Nadajnik wysyła /R/, dopóki własny odbiornik nie jest zsynchronizowany (`comma_align`) i włączony (bit `RX_EN`).
- Odbiornik po /R/, a także przy braku własnej synchronizacji, uznaje stronę przeciwną za niegotową i wstrzymuje własne nadawanie ramek (jak przy XOFF).
- D5.6 jest znakiem zrównoważonym — para /R/ nie zmienia dysparytetu bieżącego, co jest bez znaczenia dla odbiornika (dekoder śledzi dysparytet symbol po symbolu).

**Stan łącza** (`link_ctrl`):

| Stan | Warunek |
|---|---|
| DOWN | LOS (gdy nie jest ignorowany), brak modułu (`MOD_ABS`) lub brak synchronizacji znakowej |
| SYNC | własny odbiornik zsynchronizowany, strona przeciwna nadaje /R/ |
| UP | własny odbiornik zsynchronizowany, strona przeciwna nadaje /I/ lub /P/ |

Ramki są rozpoczynane wyłącznie w stanie UP, przy XON i przy `TX_EN` = 1. Ramki zapisane przez hosta w stanie DOWN lub SYNC pozostają w FIFO nadawczym.

**LOS — wymuszenie stanu DOWN z bitem `LOS_IGNORE`.** LOS = 1 wymusza stan DOWN i ponowne wyrównanie symboli (restart `comma_align`); bit `LOS_IGNORE` rejestru `CTRL` wyłącza to zachowanie dla modułów z nietypowym lub niepodłączonym wyjściem LOS. Stan LOS jest zawsze widoczny w rejestrze `STATUS`.

**Liczniki — 32 bity, zawijanie modulo 2³², kasowanie bitem `CNT_CLR`** (jak liczniki MIB Ethernetu). Osiem liczników w obszarze `0x10–0x2F`: `CODE_ERR` (błędy kodu i dysparytetu w stanie synchronizacji), `CRC_ERR`, `LEN_ERR`, `FRAMING_ERR`, `RX_OVF`, `FRAMES_TX`, `FRAMES_RX`, `SYNC_LOSS`. Odczyt wielobajtowy jest spójny dzięki zatrzaśnięciu wartości przy odczycie najmłodszego bajtu (moduł `csr_regs`).

**Pętle zwrotne — near-end i echo ramek.** Pole `LOOPBACK[1:0]` rejestru `CTRL`:

| Wartość | Tryb |
|---|---|
| 00 | praca normalna |
| 01 | near-end: bity z `tx_gearbox` kierowane na wejście `cdr_os4x8` zamiast próbek z `rx_phy` (każdy bit powielony 4×) — test toru cyfrowego bez modułu SFP; nadajnik SFP pracuje dalej (wyłączenie bitem `SFP_TX_DIS`) |
| 10 | far-end: echo ramek — ramki odebrane są nadawane z powrotem bez zmian (FIFO RX → FIFO TX); host nie odbiera ramek |
| 11 | zarezerwowane (jak 00) |

## Konsekwencje

- Ramki nie są tracone na starcie łącza ani po utracie synchronizacji przez jedną stronę; host nie musi znać stanu strony przeciwnej przed zapisem ramki.
- Stan łącza UP potwierdza dwukierunkową synchronizację; `LINK_UP` w rejestrze `STATUS` i dioda LINK odpowiadają rzeczywistej zdolności przesyłania ramek.
- Zmiana kodowania sekwencji bezczynności: nowy znak D5.6 w `tx_framer` (wejście `rx_ready`) i `rx_deframer` (wyjście `remote_ready`). Starsze implementacje nie występują — protokół nie był wdrożony.
- Echo ramek wymaga modułu kopiującego między stroną hosta FIFO RX i FIFO TX (top-level, etap integracji); pętla near-end — multipleksera próbek w `link_ctrl`.
- Mapa rejestrów: `CTRL` otrzymuje bity `LOS_IGNORE` i `CNT_CLR`, `STATUS` — `REMOTE_READY` i stan łącza; licznik `SYNC_LOSS` uzupełnia obszar `CNT_*` do ośmiu pozycji.
