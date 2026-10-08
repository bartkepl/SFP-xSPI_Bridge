# Konwencje kodu VHDL

Zasady obowiązują we wszystkich plikach w `vhdl/`. Komentarze i identyfikatory w kodzie są w języku angielskim; dokumentacja jest w języku polskim.

## Standard i biblioteki

- VHDL-2008 (`--std=08` w GHDL, `VHDL_Std_2008` w Gowin EDA).
- Arytmetyka wyłącznie przez `ieee.numeric_std` (`unsigned`, `signed`); pakiety `std_logic_arith` i `std_logic_unsigned` są zabronione.
- Prymitywy Gowin: `library gw1n; use gw1n.components.all;` — tylko w modułach warstwy fizycznej i zegarów.
- Konstrukcje VHDL-2008 dopuszczalne są tylko w zakresie obsługiwanym przez GowinSynthesis; każdy moduł przechodzi próbną syntezę. Wyrażenia warunkowe `a when c else b` stosuje się wyłącznie w przypisaniach (sygnałów lub zmiennych), nie wewnątrz wyrażeń ani argumentów wywołań.

## Pliki i nazwy

- Jeden moduł (entity + architecture) lub jeden pakiet na plik; nazwa pliku = nazwa jednostki.
- Nazwy `snake_case`; stałe i generyki `UPPER_CASE`; typy z prefiksem `t_`.
- Sygnały aktywne niskim stanem mają sufiks `_n` (`xspi_cs_n`, `arst_n`).
- Architektura syntezowalna: `rtl`; architektura testbencha: `sim`.
- Porty top-level odpowiadają nazwom w `vhdl/constraints/sfp_bridge.cst` (małe litery).

## Nagłówek modułu

Każdy plik zaczyna się blokiem komentarza zawierającym: nazwę, funkcję modułu, **założenia** (warunki pracy, ograniczenia wejść), opis sterowania i **opóźnienie** (latency) w taktach.

## Logika synchroniczna

- Jeden zegar na proces; wyłącznie `rising_edge(clk)`.
- Reset zgodnie z [ADR 0004](../adr/0004-strategia-resetu.md): synchroniczny, aktywny wysokim (`rst`) wewnątrz domeny; mostek `reset_sync` na wejściu domeny.
- Wyjścia modułów są rejestrowane, o ile opis modułu nie stanowi inaczej.
- Przejścia między domenami zegarowymi tylko przez `sync_bit` (pojedyncze bity poziomowe), handshake lub asynchroniczne FIFO.
- Tablice stałe (np. ROM dekodera) mogą być wyliczane funkcją w czasie elaboracji, jeżeli zapewnia to jedno źródło definicji (koder i dekoder 8b/10b).

## Testbenche

- Plik `vhdl/sim/tb/tb_<moduł>.vhd`, jednostka `tb_<moduł>`, architektura `sim`.
- Nagłówek wymienia sprawdzane własności i sygnały istotne na przebiegu.
- Sprawdzenia przez procedury `check`, `check_equal` z `tb_pkg`; koniec testu przez `tb_finish("<nazwa>")`.
- Model odniesienia w testbenchu jest niezależny algorytmicznie od implementacji (np. CRC liczone inną metodą, wzorcowe słowa 8b/10b z tabeli standardu).
- Skuteczność nowego testbencha sprawdza się testem mutacyjnym: celowo wprowadzony błąd musi dać wynik FAIL.
- Każdy testbench ma widok `vhdl/sim/waves/<tb>.gtkw` z pogrupowanymi sygnałami.
