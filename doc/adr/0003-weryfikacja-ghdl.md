# 0003. Weryfikacja VHDL: GHDL, samosprawdzające testbenche VHDL-2008, przebiegi GTKWave

**Stan:** przyjęta · **Data:** 2026-10-08
**Dotyczy:** vhdl, doc

## Kontekst

Gowin EDA nie zawiera symulatora HDL. Dostarcza wyłącznie modele symulacyjne prymitywów (`IDE\simlib\gw1n\prim_sim.vhd`) do symulatorów zewnętrznych; wymieniane w dokumentacji symulatory komercyjne (ModelSim/Questa, Active-HDL, VCS) są płatne.

Wymagania wobec weryfikacji:

- automatyczna ocena wyniku (PASS/FAIL) dla każdego modułu, możliwa do uruchomienia jednym poleceniem,
- przebiegi czasowe do ręcznej oceny przez osobę bez specjalistycznego przygotowania w weryfikacji,
- obsługa VHDL-2008 i modeli prymitywów Gowin (serializery IDES/OSER, rPLL, CLKDIV, DCS) w testach toru fizycznego,
- praca na stacji Windows (symulator w WSL) i na Linuksie.

## Rozważane warianty

1. **GHDL + czysty VHDL-2008** — symulator open source, testbenche samosprawdzające bez bibliotek zewnętrznych, przebiegi `.ghw`.
2. **GHDL + VUnit** — runner w Pythonie, raporty, uruchamianie równoległe; dodatkowa zależność.
3. **GHDL + OSVVM** — scoreboardy, pokrycie funkcjonalne, losowanie ograniczone; wyższy próg wejścia.
4. **Symulator komercyjny** — koszt licencji.

## Decyzja

- Symulator: **GHDL 5** (`apt install ghdl`; na Windows w WSL).
- Testbenche: **czysty VHDL-2008**, samosprawdzające, wspólny pakiet `vhdl/sim/tb/tb_pkg.vhd` (licznik błędów, procedury `check*`, jedna linia wyniku `TB <nazwa> PASS|FAIL`).
- Uruchamianie: `vhdl/sim/run_tests.ps1` (Windows) → `run_tests.sh` (WSL); kolejność kompilacji w `vhdl/sim/sources.txt`.
- Przebiegi: każdy testbench zapisuje `vhdl/sim/out/<tb>.ghw`; podgląd **GTKWave 3.4** z gotowym widokiem `vhdl/sim/waves/<tb>.gtkw` (`view.ps1 <tb>`).
- Skuteczność testbenchy potwierdza się **testem mutacyjnym**: celowo wprowadzony błąd w module musi dać FAIL.

## Konsekwencje

- Brak kosztów licencji i zależności poza GHDL; pakiet `tb_pkg` pozostaje mały i czytelny.
- Losowanie i pokrycie realizuje się ręcznie (`ieee.math_real.uniform`, liczniki w testbenchu); przy rozbudowie testów integracyjnych dopuszczalne jest późniejsze dołączenie OSVVM bez zmiany modułów.
- Moduły z prymitywami Gowin wymagają skompilowania `prim_sim.vhd` do biblioteki `gw1n` w skrypcie uruchomieniowym.
- Kod syntezowalny musi spełniać jednocześnie VHDL-2008 w GHDL i podzbiór obsługiwany przez GowinSynthesis; każdy nowy moduł przechodzi również próbną syntezę.
