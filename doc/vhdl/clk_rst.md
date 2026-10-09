# Zegary i reset: `clk_rst`

Plik: `vhdl/sfp_bridge/src/clk/clk_rst.vhd` · testbench: `vhdl/sim/tb/tb_clk_rst.vhd`

Generacja zegarów i reset domeny `clk_sys` ([ADR 0004](../adr/0004-strategia-resetu.md), [ADR 0007](../adr/0007-zegar-systemowy-50mhz.md); [plan, rozdz. 4 i 7.2](../sfp-xspi-bridge-plan.md)).

```
CLK_25M ──> rPLL ──> clk_fast (200 MHz, FCLK IDES8/OSER8)
                        │
                        └──> CLKDIV /4 ──> clk_sys (50 MHz)

lock ─────────────┐
HOST_RST_N ─> sync + filtr (clk_sys) ─┼─> arst_n ──> reset_sync (clk_sys) ──> rst_sys
SOFT_RST (CTRL) ──┘                    └─> do mostków resetu innych domen (clk_spi)
```

## Interfejs

| Generyk | Domyślnie | Opis |
|---|---|---|
| `HOST_FILT` | 32 | długość filtra `HOST_RST_N` w taktach `clk_sys` (640 ns) |
| `STAGES` | 3 | opóźnienie zwolnienia resetu w taktach `clk_sys` |

| Port | Kierunek | Opis |
|---|---|---|
| `clk_25m` | in | generator odniesienia (pin 35, `RPLL_T_in`) |
| `host_rst_n` | in | pin `HOST_RST_N` (pull-up) — reset logiki przez hosta |
| `soft_rst` | in | bit `CTRL.SOFT_RST` — wprost z przerzutnika domeny `clk_sys` kasowanego przez `rst_sys` |
| `clk_fast` | out | 200 MHz, tylko FCLK serializerów |
| `clk_sys` | out | 50 MHz, zegar logiki |
| `rst_sys` | out | reset domeny `clk_sys`, aktywny wysokim |
| `rst_hard` | out | reset domeny `clk_sys` bez resetu programowego (blokada PLL, `HOST_RST_N`) — dla `MODE_CTRL` ([ADR 0009](../adr/0009-interfejs-hosta.md)) |
| `rst_por` | out | reset domeny `clk_sys` od włączenia zasilania (tylko blokada PLL; bez `HOST_RST_N` i resetu programowego) — dla `UART_STATUS` |
| `arst_n` | out | asynchroniczne żądanie resetu dla mostków innych domen |
| `pll_lock` | out | blokada PLL (bez synchronizacji, do rejestru stanu przez `sync_bit`) |

## Zegary

Parametry PLL są wyliczane w `bridge_pkg` z prędkości linii `LINE_BAUD`:

| Stała | 100 Mbaud | 125 Mbaud |
|---|---|---|
| `PLL_IDIV_SEL` | 0 (÷1) | 0 |
| `PLL_FBDIV_SEL` | 7 (×8) → 200 MHz | 9 (×10) → 250 MHz |
| `PLL_ODIV_SEL` | 4 → VCO 800 MHz | 4 → VCO 1000 MHz |

Zakres VCO GW1N-9 (C6/I5): 400–1200 MHz (DS100). `clk_sys` pochodzi z `CLKDIV` (`DIV_MODE` = "4"), a nie z drugiego wyjścia PLL — zachowuje stałą fazę względem `clk_fast`, czego wymagają serializery IDES8/OSER8 (UG289). `CLKDIV` jest trzymany w resecie do blokady PLL.

`CLK_25M` steruje wyłącznie PLL: pin 35 jest dedykowanym wejściem PLL, a nie pinem zegara globalnego, więc użycie go jako zegara logiki wymagałoby ogólnych zasobów routingu (ostrzeżenie PR1014).

## Reset

`arst_n` = `lock` ∧ (`HOST_RST_N` nieaktywny po filtrze) ∧ ¬`soft_rst`.

- **Blokada PLL:** do uzyskania `LOCK` (i po jego utracie) reset jest aktywny.
- **`HOST_RST_N`:** synchronizacja 2-FF i filtr w domenie `clk_sys` — stan zmienia się po `HOST_FILT` kolejnych jednakowych próbkach (640 ns); krótsze zakłócenia nie resetują mostka. Przed blokadą PLL filtr nie pracuje, ale reset jest wtedy wymuszony warunkiem blokady.
- **`SOFT_RST`:** bit musi pochodzić bezpośrednio z przerzutnika domeny `clk_sys` kasowanego przez `rst_sys` — reset kasuje bit, co zwalnia żądanie (reset programowy kończy się samoczynnie po `STAGES` + 1 taktach).
- `rst_sys` załącza się natychmiast (asynchronicznie) i zwalnia synchronicznie po `STAGES` zboczach `clk_sys` (`reset_sync`). Domena `clk_spi` korzysta z `arst_n` przez własny `reset_sync`.

## Ograniczenia czasowe (`.sdc`)

Zegary wyjściowe PLL i `CLKDIV` są zadeklarowane jawnie jako zegary generowane (bez tego Gowin zgłasza ostrzeżenie TA1132 i nadaje im nazwy domyślne). Wpisy w `vhdl/constraints/sfp_bridge.sdc` odwołują się do instancji `u_clk` w top-level:

```
create_clock -name clk_25m -period 40.000 [get_ports {clk_25m}]
create_generated_clock -name clk_fast -source [get_ports {clk_25m}] -multiply_by 8 [get_pins {u_clk/u_pll/CLKOUT}]
create_generated_clock -name clk_sys -source [get_pins {u_clk/u_pll/CLKOUT}] -divide_by 4 [get_pins {u_clk/u_div/CLKOUT}]
```

Pełny zestaw ograniczeń (zegar hosta, grupy asynchroniczne, opóźnienia pinów xSPI): [integracja](top.md#ograniczenia-czasowe).

## Synteza

Próbna synteza projektu `clk_rst` + `tx_gearbox` + `tx_phy` + `rx_phy` + `cdr_os4x8` + `comma_align` + koder i dekoder na pinach z `sfp_bridge.cst`: 515 LUT/ALU, 246 rejestrów, 1 rPLL, `clk_sys` Fmax 85 MHz przy ograniczeniu 50 MHz, bez ostrzeżeń.

## Testbench `tb_clk_rst`

Modele symulacyjne Gowin `rPLL` i `CLKDIV` (biblioteka `gw1n`); `CLK_25M` = 25 MHz. Model rPLL sygnalizuje blokadę po ok. 50 µs.

| Nr | Sprawdzenie |
|---|---|
| 1 | przed blokadą `rst_sys` = 1, `arst_n` = 0; `rst_sys` zwolniony najwyżej `STAGES` + 3 takty po blokadzie |
| 2 | okres `clk_fast` 5 ns, `clk_sys` 20 ns (średnia z 200 okresów, ±1 ps); każde zbocze narastające `clk_sys` w tej samej chwili co zbocze `clk_fast` |
| 3 | `HOST_RST_N` = 0 przez 400 ns (krócej niż filtr): brak resetu |
| 4 | `HOST_RST_N` = 0 przez 2 µs: `arst_n` = 0 w ciągu 20 taktów `CLK_25M`, `rst_sys` aktywny przez cały czas; po zwolnieniu `arst_n` = 1 w ciągu 20 taktów, `rst_sys` zwolniony po `STAGES` taktach `clk_sys` |
| 5 | reset programowy: model przerzutnika `CTRL.SOFT_RST` ustawiony zapisem — impuls `rst_sys` o długości `STAGES` … `STAGES` + 2 taktów, bit skasowany, brak kolejnego resetu; `rst_hard` nieaktywny |
| 6 | `rst_por` = 1 do blokady PLL, zwalniany jak `rst_sys`, potem ani razu aktywny (ani przez `HOST_RST_N` w testach 3 i 4, ani przez reset programowy) |

**Test mutacyjny:** wykrywane — brak filtra `HOST_RST_N`, pominięcie `SOFT_RST`, pominięcie blokady PLL, natychmiastowe zwolnienie filtra, `rst_por` zależny od `HOST_RST_N`.

## Przebieg

`.\view.ps1 tb_clk_rst` — czas symulacji ok. 61 µs.

| Czas (ok.) | Co widać |
|---|---|
| 0–50 µs | `clk_25m` pracuje, `pll_lock` = 0, `arst_n` = 0, `rst_sys` = 1 |
| ok. 50,3 µs | `pll_lock` = 1, `clk_fast` 200 MHz i `clk_sys` 50 MHz (zbocza narastające wspólne co 4 okresy `clk_fast`), po 3 taktach `rst_sys` = 0 |
| 50,4–55,5 µs | pomiar okresów, stan bez zmian |
| ok. 55,5 µs | krótki impuls `host_rst_n` = 0 (400 ns): `flt_cnt` liczy do ok. 20 i wraca do 0, `host_flt` bez zmian |
| ok. 57,5–60,3 µs | długi impuls `host_rst_n` = 0: `host_flt` = 0 po 640 ns, `arst_n` = 0, `rst_sys` = 1; po zwolnieniu odwrotnie |
| ok. 60,5 µs | `soft_set` → `soft_q` = 1 → `rst_sys` = 1 → `soft_q` = 0 → po 3 taktach `rst_sys` = 0 |
