# Warstwa fizyczna: `tx_gearbox`, `tx_phy`, `rx_phy`

Pliki: `vhdl/sfp_bridge/src/link/tx_gearbox.vhd`, `tx_phy.vhd`, `rx_phy.vhd` · testbench: `vhdl/sim/tb/tb_phy_loopback.vhd`

Styk toru łącza z parami LVDS modułu SFP ([plan, rozdz. 7.2](../sfp-xspi-bridge-plan.md); [ADR 0007](../adr/0007-zegar-systemowy-50mhz.md)). Serializery pracują przy FCLK = `clk_fast` = 200 MHz w trybie DDR (400 Msps), PCLK = `clk_sys` = FCLK/4 = 50 MHz z `CLKDIV`; przy 100 Mbaud na bit przypadają 4 próbki, na takt `clk_sys` — 2 bity.

```
tx_framer ─char─> enc_8b10b ─code[9:0]─> tx_gearbox ─bits[1:0]─> tx_phy ─> SFP TD±
                 ^ en                       │ char_en (co 5 taktów)
                 └──────────────────────────┘
SFP RD± ─> rx_phy ─samples[7:0]─> cdr_os4x8 ─bits/nbits─> comma_align ─sym─> dec_8b10b
```

## `tx_gearbox`

Zamienia symbol 10-bitowy (jeden na 5 taktów `clk_sys`) na 2 bity na takt.

| Port | Kierunek | Opis |
|---|---|---|
| `clk`, `rst` | in | `clk_sys`, reset synchroniczny |
| `char_en` | out | impuls co 5 taktów: `tx_framer` przygotowuje kolejny znak, `enc_8b10b` (`en`) koduje bieżący |
| `code[9:0]` | in | symbol z `enc_8b10b` (ważny od taktu po `char_en`) |
| `bits[1:0]` | out | do `tx_phy`, `bits(0)` nadawany pierwszy |

Licznik fazy ph = 0…4: przy ph = 0 impuls `char_en`; przy ph = 4 zatrzaśnięcie symbolu; w fazie n na wyjściu `code(2n+1 downto 2n)`, czyli bit a (`code(0)`) pierwszy. Opóźnienie od `char_en` do pierwszego bitu symbolu na `bits`: 6 taktów. Po resecie rejestr symbolu zawiera K28.5 (RD−), więc na linii nie pojawia się wzorzec spoza kodu 8b/10b.

## `tx_phy`

`OSER8` + `TLVDS_OBUF` (para TD±, `IO_TYPE=LVDS25`). Każdy z 2 bitów taktu podawany jest na 4 kolejne wejścia serializera: D0…D3 = `bits(0)`, D4…D7 = `bits(1)`. `OSER8` nadaje D0 jako pierwszy (UG289; model symulacyjny Gowin `prim_sim.vhd`).

## `rx_phy`

`TLVDS_IBUF` (para RD±, terminacja zewnętrzna — [ADR 0002](../adr/0002-terminacja-rx-zewnetrzna.md)) + `IDES8`. Wyjście `samples(i)` = Qi; `IDES8` oddaje najwcześniejszą próbkę na Q0. Wejście `CALIB` (przesuwanie granicy słowa w deserializerze) nie jest używane — fazę i granicę symbolu wyznaczają [`cdr_os4x8`](cdr.md) i [`comma_align`](comma_align.md).

**Generyk `INVERT`** (`tx_phy`, `rx_phy`, domyślnie `false`): odwrócenie polaryzacji na wypadek zamiany przewodów P/N pary na płytce. Porty `rd_p`/`td_p` modułów oznaczają nóżkę bufora na pinie A pary (true), `rd_n`/`td_n` — na pinie B.

W rev. A płytki para RD jest odwrócona (`SFP_RD_N` na pinie A 43, `SFP_RD_P` na pinie B 42 — plan, 3.2, reguła 9), więc w top-level obowiązuje:

```vhdl
u_rx_phy : entity work.rx_phy
  generic map (INVERT => true)
  port map (..., rd_p => sfp_rd_n, rd_n => sfp_rd_p, ...);
```

Para TD nie jest odwrócona (`tx_phy` z `INVERT => false`, `td_p => sfp_td_p`).

**Reset:** `RESET` prymitywów jest podłączony do resetu domeny `clk_sys` ([ADR 0004](../adr/0004-strategia-resetu.md)).

## Synteza

Próbna synteza (GW1N-9C) projektu z rPLL (25 → 200 MHz), `CLKDIV` /4, `tx_gearbox`, `tx_phy`, `rx_phy`, `cdr_os4x8`, `comma_align`, koderem i dekoderem, na pinach z `sfp_bridge.cst`: 504 LUT/ALU, 236 rejestrów, 1 BSRAM, 1 rPLL, IOLOGIC: 1 `IDES8`, 1 `OSER8`. `clk_sys` przy ograniczeniu 50 MHz: Fmax 74,7 MHz, TNS = 0. Zegar `clk_sys` należy zadeklarować jawnie w `.sdc` (ostrzeżenie TA1132) — przy module `clk_rst`.

## Testbench `tb_phy_loopback`

Tor szeregowy z modelami symulacyjnymi prymitywów Gowin (biblioteka `gw1n` kompilowana przez `run_tests.sh` z `prim_sim.vhd`, [symulacja](symulacja.md)):

źródło znaków → `enc_8b10b` → `tx_gearbox` → `tx_phy` → przewód (opóźnienie transportowe) → `rx_phy` → `cdr_os4x8` → `comma_align` → `dec_8b10b`

`clk_fast` = 200 MHz, `clk_sys` z modelu `CLKDIV` (`DIV_MODE` = "4"); oba końce na jednym zegarze — testbench weryfikuje kolejność bitów i taktowanie prymitywów oraz toru, a nie śledzenie częstotliwości (to zadanie [`tb_cdr_os4x8`](cdr.md) i testu pętli łącza).

Źródło znaków: znak i = K28.5 dla i mod 8 = 0, D16.2 dla i mod 8 = 1, w pozostałych pozycjach bajt danych (13·⌊i/8⌋ + i mod 8) mod 256.

Fazy: opóźnienie przewodu 0,3; 2,9; 5,5; 8,1 ns (fazy próbkowania w obrębie okresu bitu 10 ns); po każdej zmianie `restart` modułu `comma_align`. Sprawdzenia w każdej fazie:

1. Synchronizacja w ciągu 5 µs (4 comma co 8 znaków: 3,2 µs).
2. 1000 kolejnych zdekodowanych znaków zgodnych z sekwencją źródła (pozycja wyznaczona z pierwszych 16), bez błędów dekodera.
3. `cdr_os4x8` oddaje 2 bity w każdym takcie (jeden zegar, brak zawinięć fazy).

Wynik: faza CDR podąża za opóźnieniem (0,3 ns → 0, 2,9 ns → 1, 5,5 ns → 2, 8,1 ns → 3 — krok co 2,5 ns, okres próbkowania).

**Test mutacyjny:** wykrywane — odwrócona kolejność bitów na wejściach `OSER8`, odwrócona kolejność próbek z `IDES8`, zamiana bitów w parze w `tx_gearbox`, zatrzaśnięcie symbolu przed jego zakodowaniem.

## Test pętli łącza `tb_link_loopback`

Pełne łącze między dwoma końcami mostka na poziomie bitów, z modelami prymitywów Gowin i niezależnymi zegarami — test integracyjny etapów 1–5:

host → FIFO TX → `tx_framer` → `enc_8b10b` → `tx_gearbox` → `tx_phy` → linia → `rx_phy` → [`link_ctrl`](link_ctrl.md) (multiplekser pętli) → `cdr_os4x8` → `comma_align` → `dec_8b10b` → `rx_deframer` → FIFO RX → host (w obu kierunkach); `link_ctrl` steruje każdym końcem (stan łącza, bezczynność /R/, bramkowanie nadawania, liczniki — [ADR 0008](../adr/0008-stan-lacza.md)).

| Parametr | Wartość |
|---|---|
| zegary | każdy koniec: własny `clk_fast`, `clk_sys` z modelu `CLKDIV`; strona B szybsza o 200 ppm (`clk_fast` 4,999 ns wobec 5,000 ns) |
| linia | opóźnienie 5 ns + niezależny jitter ±0,2 UI (±2 ns) każdego zbocza |
| strona hosta FIFO | `clk_sys` tego samego końca (przejście między domenami weryfikuje [`tb_async_fifo`](async_fifo.md)) |

| Faza | Przebieg |
|---|---|
| 1 | hosty zapisują po 32 ramki zaraz po własnym resecie, przed zestawieniem łącza (typ zależny od numeru, długość 1–400 B, treść zależna od numeru i pozycji); przez pierwsze 20 µs strona B ma aktywny LOS — jej odbiornik pozostaje w stanie DOWN i nadaje /R/, strona A osiąga tylko stan SYNC |
| 2 | strona A w pętli near-end (`LB_NEAR`), zapisuje 4 ramki: wracają do jej własnego odbiornika i równocześnie docierają linią do strony B |
| 3 | strona A wraca do pracy normalnej, strona B zapisuje 4 ramki |

Sprawdzenia:

1. W czasie LOS po stronie B: A w stanie SYNC, B w stanie DOWN, żadna ramka nie została nadana; po zwolnieniu LOS oba końce w stanie UP (wynik: 1,4 µs), bez późniejszej utraty synchronizacji w fazie 1.
2. Każdy czytelnik odbiera dokładnie oczekiwane ramki, w kolejności i bez przekłamań (A: 32 od B, 4 własne, 4 od B; B: 36 od A).
3. Brak zdarzeń błędu w obu `rx_deframer` (CRC, kod, długość, ramkowanie, przepełnienie), brak odczytu z pustego FIFO RX.
4. Śledzenie częstotliwości w fazie 1: po stronie A (strumień szybszy) kroki `shift_dn`, po stronie B kroki `shift_up` — po ponad 10, najwyżej 2 w kierunku przeciwnym (dostrajanie fazy tuż po synchronizacji); takty z 3 / 1 bitem odpowiednio. Wynik: 55 kroków w ciągu ok. 675 µs — zgodnie z oczekiwanym 200 ppm × 8 próbek × 34 000 taktów ≈ 54.
5. Liczniki `link_ctrl` na końcu: `FRAMES_TX` A 36 / B 36, `FRAMES_RX` A 40 / B 36, liczniki błędów CRC, długości, ramkowania i przepełnienia równe 0, `SYNC_LOSS` po stronie B równy 0 (po stronie A 2 — przełączenia trybu pętli).

**Test mutacyjny (integracja):** wykrywane — `tx_framer` nienadający /R/ (strona A zaczyna nadawać, zanim odbiornik B jest gotowy, i ramki giną), pominięcie LOS w `link_ctrl`. Usunięcie warunku stanu UP z `tx_hold` nie jest wykrywalne: `xoff_remote` pozostaje 1, dopóki strona przeciwna nie nada /I/, co obejmuje ten sam przypadek (zabezpieczenie nadmiarowe).

Strona łącza w testbenchu (`tb_link_side`) składa te same moduły co docelowy top-level.

**Przebieg** (`.\view.ps1 tb_link_loopback`, ok. 0,88 ms):

| Czas (ok.) | Co widać |
|---|---|
| 0–20 µs | `b_los` = 1: `b_st` = 00 (DOWN), `a_st` = 01 (SYNC); `a_wr`/`b_wr` zapisują ramki do FIFO, ale `a_ok`/`b_ok` milczą |
| ok. 21,5 µs | `b_los` = 0, po 1,4 µs `a_st` = `b_st` = 10 (UP) |
| 21,5–695 µs | impulsy `a_ok`/`b_ok` po każdej ramce, `a_frames`/`b_frames` rośnie do 32; `a_dn` i `b_up` co ok. 625 taktów, przy zawinięciu fazy `a_nbits` = 3 i `b_nbits` = 1 |
| ok. 695 µs | `a_lb` = 01: krótko `a_st` = 00, potem 10; 4 ramki — impulsy `a_ok` i `b_ok` |
| do końca | `a_lb` = 00, 4 ramki od B; `a_err` i `b_err` stale 0 |

## Przebieg

`.\view.ps1 tb_phy_loopback` — czas symulacji ok. 420 µs; faza `ph_no` = p trwa ok. 105 µs.

| Czas (ok.) | Co widać |
|---|---|
| 0–1 µs | po resecie `char_en` co 5 taktów `clk_sys` (5 × 20 ns = 100 ns na znak); `code` zmienia się takt po `char_en`; `tx_bits` co takt kolejna para bitów |
| od ok. 0,5 µs | `td_p` — przebieg szeregowy 100 Mbaud (bit = 10 ns, najkrótszy impuls 10 ns, najdłuższy 50 ns); `rd_p` przesunięty o opóźnienie przewodu |
| od ok. 0,5 µs | `samples` — w każdym takcie 8 próbek; zbocze linii widoczne jako zmiana wartości w obrębie słowa |
| ok. 0,2–3,7 µs | `sync` = 0, potem 1; od tej chwili `dec_valid` co 5 taktów, `dec_data`: BC (`dec_k` = 1), 50, dalej bajty danych |
| ok. 105, 210, 315 µs | zmiana opóźnienia: `restart`, `sync` = 0 przez ok. 3,2 µs, `phase` zmienia wartość o 1 |
