# Symulacja i przebiegi

## Narzędzia

| Narzędzie | Rola | Lokalizacja |
|---|---|---|
| GHDL 5 | symulator VHDL-2008 | Linux lub WSL (`apt install ghdl`); dystrybucja WSL w zmiennej `GHDL_WSL_DISTRO` (domyślnie dystrybucja domyślna) |
| GTKWave 3.4 | podgląd przebiegów | ścieżka w zmiennej `GTKWAVE` albo `gtkwave` w `PATH` |

Uzasadnienie wyboru: [ADR 0003](../adr/0003-weryfikacja-ghdl.md).

## Uruchamianie testów

W PowerShell, w katalogu `vhdl\sim`:

```
.\run_tests.ps1              # wszystkie testbenche
.\run_tests.ps1 tb_crc32     # wybrany testbench
```

Wynik:

```
  PASS  tb_8b10b  (6454 checks)
  PASS  tb_crc32  (514 checks)
  PASS  tb_sync  (17 checks)
Result: 3 passed, 0 failed
```

Przy błędzie wypisywane są pierwsze nieudane sprawdzenia (`CHECK FAILED: ...`); pełny dziennik: `vhdl\sim\out\<tb>.log`.

Skrypt kompiluje pliki z `sources.txt` (w tej kolejności) oraz wszystkie `tb_*.vhd`. Nowy moduł dopisuje się do `sources.txt` za modułami, od których zależy.

Moduły z prymitywami Gowin (`tx_phy`, `rx_phy`) korzystają z biblioteki `gw1n`: skrypt kompiluje do niej model symulacyjny producenta `prim_sim.vhd` (encje prymitywów) i `prim_syn.vhd` (pakiet `components` z deklaracjami komponentów) z instalacji Gowin EDA — katalog `IDE/simlib/gw1n`, ścieżka w zmiennej `GOWIN_SIMLIB` (wymagana; `run_tests.ps1` przekłada ścieżkę Windows na ścieżkę WSL). Biblioteka jest kompilowana ponownie tylko wtedy, gdy jej brak lub model jest nowszy. Ten sam kod (`library gw1n; use gw1n.components.all;`) służy do syntezy i symulacji.

## Wspólne elementy testbenchy (`tb_pkg`)

| Element | Opis |
|---|---|
| `check`, `check_equal` | sprawdzenie warunku lub wartości; liczniki sprawdzeń i błędów |
| `tb_finish(nazwa)` | wiersz podsumowania `TB <nazwa> PASS (...)` lub `FAIL (...)` i koniec symulacji |
| `clk_gen` | generator zegara |
| `t_line` | model linii szeregowej: nadajnik dopisuje bity z nominalnym czasem początku (`push`), odbiornik próbkuje linię w dowolnej chwili (`sample`); każda granica bitu jest przesunięta niezależnym jitterem o rozkładzie jednostajnym ±J·UI (`configure`), odchyłkę częstotliwości wyznaczają czasy podane przez nadajnik |

## Podgląd przebiegów

```
.\view.ps1 tb_crc32
```

Otwiera `out\tb_crc32.ghw` w GTKWave z widokiem `waves\tb_crc32.gtkw` (sygnały pogrupowane i opisane). Podstawowe operacje w GTKWave:

| Operacja | Sposób |
|---|---|
| dopasowanie całego przebiegu do okna | `Ctrl+Alt+F` lub przycisk „Zoom Fit” |
| powiększenie / pomniejszenie | `Ctrl` + kółko myszy |
| kursor i odczyt wartości | kliknięcie na przebiegu; wartości w kolumnie obok nazw |
| zmiana formatu (hex, dec, bin) | prawy przycisk na nazwie sygnału → *Data Format* |
| dodanie sygnału | panel *SST* (hierarchia) po lewej → przeciągnięcie sygnału |
| zapis zmienionego widoku | *File → Write Save File* (nadpisuje `.gtkw`) |

Opis, co należy zobaczyć na przebiegu każdego testbencha, znajduje się na stronie modułu (sekcja „Przebieg”).
