# Sterowanie łączem: `link_ctrl`

Plik: `vhdl/sfp_bridge/src/link/link_ctrl.vhd` · testbench: `vhdl/sim/tb/tb_link_ctrl.vhd` (integracja: `tb_link_loopback`)

Stan łącza, obsługa LOS modułu SFP, bramkowanie nadawania ramek, liczniki zdarzeń i pętla zwrotna near-end w domenie `clk_sys` ([ADR 0008](../adr/0008-stan-lacza.md); [plan, rozdz. 7.2](../sfp-xspi-bridge-plan.md)).

## Interfejs

| Generyk | Domyślnie | Opis |
|---|---|---|
| `CNT_W` | 32 | szerokość liczników (zmniejszana tylko w testach zawijania) |

| Port | Kierunek | Opis |
|---|---|---|
| `clk`, `rst` | in | `clk_sys`, reset synchroniczny |
| `cfg_tx_en`, `cfg_rx_en` | in | bity `TX_EN`, `RX_EN` rejestru `CTRL` |
| `cfg_los_ignore` | in | bit `LOS_IGNORE`: LOS nie wymusza stanu DOWN |
| `cfg_loopback[1:0]` | in | tryb pętli (`LB_NONE`, `LB_NEAR` z bitu `CTRL.LB_NEAR`; `LB_FAR` — echo ramek, `MODE_CTRL.FRAME_ECHO`, [ADR 0009](../adr/0009-interfejs-hosta.md)) |
| `cnt_clr` | in | bit `CNT_CLR`: kasowanie liczników (dopóki `'1'`) |
| `sfp_los`, `sfp_mod_abs` | in | sygnały modułu SFP, zsynchronizowane do `clk_sys` |
| `rx_sync` | in | synchronizacja znakowa (`comma_align`) |
| `remote_ready`, `xoff_remote` | in | stan strony przeciwnej (`rx_deframer`) |
| `dec_valid`, `dec_code_err`, `dec_disp_err` | in | wynik `dec_8b10b` (licznik `CODE_ERR`) |
| `ev_crc_err`, `ev_len_err`, `ev_framing`, `ev_ovf`, `ev_frame_ok` | in | zdarzenia `rx_deframer` |
| `ev_frame_sent` | in | `frame_sent` z `tx_framer` |
| `ev_sync_loss` | in | `ev_sync_loss` z `comma_align` |
| `phy_samples[7:0]` | in | próbki z `rx_phy` |
| `tx_bits[1:0]` | in | bity z `tx_gearbox` (pętla near-end) |
| `cdr_samples[7:0]` | out | do `cdr_os4x8` |
| `align_restart` | out | do `comma_align` (`restart`) |
| `rx_ready` | out | do `tx_framer`: odbiornik zsynchronizowany i włączony (`'0'` → bezczynność /R/) |
| `tx_hold` | out | do `tx_framer` (wejście `xoff_remote`): wstrzymanie nowych ramek |
| `link_state[1:0]` | out | `LS_DOWN`, `LS_SYNC`, `LS_UP` (`bridge_pkg`) |
| `link_up` | out | stan UP (rejestr `STATUS`, dioda LINK) |
| `link_chg` | out | impuls: zmiana stanu łącza (przerwanie `LINK_CHG`) |
| `activity` | out | impuls: ramka nadana lub odebrana (dioda ACT) |
| `counters` | out | 8 liczników 32-bit (`t_cnt_arr`, indeksy `CNT_*`) |

## Stan łącza

| Stan | Warunek |
|---|---|
| DOWN | LOS (gdy `cfg_los_ignore` = 0) lub brak modułu (`sfp_mod_abs`), lub brak synchronizacji znakowej |
| SYNC | `rx_sync` = 1, strona przeciwna nadaje /R/ (`remote_ready` = 0) |
| UP | `rx_sync` = 1, `remote_ready` = 1 |

W pętli near-end sygnały SFP są pomijane (test bez modułu).

**Sygnały sterujące:**

- `tx_hold` = 0 wyłącznie w stanie UP, przy XON strony przeciwnej i `cfg_tx_en` = 1. Ramki zapisane w innych stanach czekają w FIFO nadawczym.
- `rx_ready` = `rx_sync` ∧ `cfg_rx_en` — gdy 0, `tx_framer` nadaje /R/ i strona przeciwna nie rozpoczyna ramek.
- `align_restart` = 1 przez cały czas trwania LOS / braku modułu (o ile nie są pomijane) oraz przez jeden takt po zmianie trybu pętli zwrotnej.

## Liczniki

Liczniki zawijają się modulo 2^`CNT_W` i są kasowane, dopóki `cnt_clr` = 1. Zdarzenia są rejestrowane raz przed zliczeniem (takt opóźnienia).

| Indeks | Nazwa | Zdarzenie | Adres CSR |
|---|---|---|---|
| 0 | `CODE_ERR` | `dec_valid` ∧ (`code_err` ∨ `disp_err`) przy `rx_sync` = 1 | 0x10 |
| 1 | `CRC_ERR` | `ev_crc_err` | 0x14 |
| 2 | `LEN_ERR` | `ev_len_err` | 0x18 |
| 3 | `FRAMING_ERR` | `ev_framing` | 0x1C |
| 4 | `RX_OVF` | `ev_ovf` | 0x20 |
| 5 | `FRAMES_TX` | `ev_frame_sent` | 0x24 |
| 6 | `FRAMES_RX` | `ev_frame_ok` | 0x28 |
| 7 | `SYNC_LOSS` | `ev_sync_loss` | 0x2C |

Licznik `CODE_ERR` obejmuje błędy dekodera także poza ramkami (w sekwencji bezczynności), więc jest miarą jakości łącza niezależną od ruchu; błędy kodu wewnątrz ramek dodatkowo odrzucają ramkę (`rx_deframer`). Spójny odczyt 32-bitowej wartości przez xSPI zapewnia `csr_regs` (zatrzaśnięcie przy odczycie najmłodszego bajtu).

## Pętla zwrotna near-end

Przy `cfg_loopback` = `LB_NEAR` próbki wejściowe `cdr_os4x8` pochodzą z `tx_gearbox`: `cdr_samples(3 downto 0)` = `tx_bits(0)`, `cdr_samples(7 downto 4)` = `tx_bits(1)` — każdy bit powielony 4×, jak z deserializera przy idealnej linii. Oba źródła mają jeden stopień rejestru. Własne ramki wracają do własnego odbiornika; nadajnik SFP pracuje dalej (wyłączenie bitem `SFP_TX_DIS`).

Tryb `LB_FAR` (echo ramek) jest realizowany po stronie hosta FIFO (top-level); dla `link_ctrl` jest równoważny pracy normalnej.

## Synteza

Próbna synteza (GW1N-9C, ograniczenie 12 ns): 422 LUT/ALU (w tym 256 ALU liczników), ok. 280 rejestrów modułu, Fmax 112,8 MHz.

## Testbench `tb_link_ctrl`

Wejścia sterowane bezpośrednio; druga instancja z `CNT_W` = 4 sprawdza zawijanie liczników.

| Nr | Sprawdzenie |
|---|---|
| 1 | po resecie: DOWN, `rx_ready` = 0, `tx_hold` = 1 |
| 2 | `rx_sync` = 1, strona przeciwna niegotowa: SYNC, `rx_ready` = 1, `tx_hold` = 1, jeden impuls `link_chg` |
| 3 | `remote_ready` = 1: UP, `link_up` = 1, `tx_hold` = 0 |
| 4 | XOFF strony przeciwnej lub `cfg_tx_en` = 0: `tx_hold` = 1, stan UP bez zmian |
| 5 | `cfg_rx_en` = 0: `rx_ready` = 0 |
| 6 | LOS: DOWN i `align_restart` przez czas trwania LOS; przy `cfg_los_ignore` = 1 bez skutku; brak modułu: DOWN |
| 7 | każde zdarzenie (indeks + 3) razy; `CODE_ERR` tylko przy `rx_sync` = 1; `cnt_clr` kasuje wszystkie; licznik 4-bitowy zawija się z 15 do 0 |
| 8 | pętla near-end: `cdr_samples` = `tx_bits` powielone 4× (takt opóźnienia), SFP pomijane, jednotaktowy `align_restart` przy zmianie trybu; praca normalna i `LB_FAR`: `cdr_samples` = `phy_samples` |
| 9 | impulsy `activity` dla ramki nadanej i odebranej |

Integrację z pełnym łączem (wstrzymanie ramek do stanu UP, LOS po jednej stronie, pętla near-end, liczniki) sprawdza [`tb_link_loopback`](phy.md).

**Test mutacyjny:** wykrywane — pominięcie `LOS_IGNORE`, zliczanie `CODE_ERR` bez synchronizacji, brak pętli near-end, pominięcie `TX_EN`, brak stanu SYNC, brak kasowania liczników.

## Przebieg

`.\view.ps1 tb_link_ctrl` — czas symulacji ok. 3,5 µs.

| Czas (ok.) | Co widać |
|---|---|
| 0,1–0,3 µs | `rx_sync` = 1 → `link_state` = 01 (SYNC), `rx_ready` = 1, impuls `link_chg`; potem `remote_ready` = 1 → 10 (UP), `tx_hold` = 0 |
| 0,3–0,4 µs | `xoff_remote` i `cfg_tx_en` podnoszą `tx_hold`; `cfg_rx_en` = 0 zeruje `rx_ready` |
| 0,4–0,7 µs | `sfp_los` = 1: stan 00, `align_restart` = 1 przez cały impuls LOS; przy `cfg_los_ignore` = 1 brak reakcji; `sfp_mod_abs` = 1: stan 00 |
| 0,7–3,3 µs | serie impulsów `ev` i `dec_valid` (liczniki), na końcu impuls `cnt_clr` |
| 3,3–3,5 µs | `cfg_loopback` = 01: `cdr_samples` = F0 / 0F zgodnie z `tx_bits`, jednotaktowy `align_restart`; LOS i MOD_ABS bez wpływu na stan |
