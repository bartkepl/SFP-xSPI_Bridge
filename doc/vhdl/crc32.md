# CRC-32: `crc32`

Plik: `vhdl/sfp_bridge/src/link/crc32.vhd` · testbench: `vhdl/sim/tb/tb_crc32.vhd`

Suma kontrolna ramek łącza ([plan, rozdz. 7.2](../sfp-xspi-bridge-plan.md)): CRC-32 w wariancie IEEE 802.3 (FCS Ethernetu), jeden bajt na takt zegara.

## Parametry CRC

| Parametr | Wartość |
|---|---|
| Wielomian | `0x04C11DB7` (postać odbita `0xEDB88320`) |
| Wartość początkowa | `0xFFFFFFFF` |
| Odbicie wejścia i wyjścia | tak (bajt przetwarzany od bitu 0) |
| XOR końcowy | `0xFFFFFFFF` |
| Wartość kontrolna `CRC("123456789")` | `0xCBF43926` |
| Reszta po dołączeniu poprawnego CRC | `0xDEBB20E3` (rejestr przed negacją) |

## Interfejs

| Port | Kierunek | Opis |
|---|---|---|
| `clk`, `rst` | in | zegar, reset synchroniczny |
| `init` | in | początek nowej ramki: rejestr ← `0xFFFFFFFF` |
| `en` | in | bajt `data` ważny |
| `data[7:0]` | in | bajt danych |
| `crc[31:0]` | out | CRC do wysłania (`not` rejestru) |
| `crc_ok` | out | `'1'`, gdy rejestr zawiera resztę `0xDEBB20E3` (odbiornik: ramka poprawna) |

`init` i `en` w tym samym takcie: pierwszy bajt ramki jest przetwarzany od wartości początkowej, bez taktu przerwy.

## Użycie

- **Nadajnik:** `init`, bajty treści z `en`, następnie wysyłka `crc(7:0)`, `crc(15:8)`, `crc(23:16)`, `crc(31:24)` w tej kolejności.
- **Odbiornik:** `init`, bajty treści **i cztery odebrane bajty CRC** z `en`; po ostatnim bajcie `crc_ok = '1'` oznacza ramkę bez błędu. Nie trzeba porównywać CRC jawnie.

## Implementacja

Aktualizacja o bajt jest liniowa w GF(2): każdy bit nowego rejestru to XOR wybranych bitów starego rejestru i bajtu. Maski wyboru są wyliczane w czasie elaboracji z behawioralnej definicji (pętla 8 kroków), a synteza otrzymuje płaskie, zrównoważone drzewa XOR. Ta postać skróciła ścieżkę krytyczną z 9,0 ns do 7,6 ns (próbna synteza GW1N-9C).

**Opóźnienie:** wynik w rejestrze po zboczu, w którym `en = '1'`; wyjścia są kombinacyjne z rejestru.

**Zapas czasowy:** ścieżka krytyczna 7,6 ns (ok. 130 MHz) przy `clk_sys` = 50 MHz ([ADR 0007](../adr/0007-zegar-systemowy-50mhz.md)) — także przy 125 Mbaud (`clk_sys` = 62,5 MHz).

## Testbench `tb_crc32`

Model odniesienia w testbenchu liczy CRC inną metodą (bez odbicia, od najstarszego bitu, z jawnym odwracaniem bitów), więc błąd nie może być wspólny dla modelu i modułu.

| Nr | Sprawdzenie |
|---|---|
| 1 | wartości znane: `""` → `0x00000000`, `"a"` → `0xE8B7BE43`, `"123456789"` → `0xCBF43926`, `"The quick brown fox jumps over the lazy dog"` → `0x414FA339` |
| 2 | reszta: treść + CRC → `crc_ok = '1'` |
| 3 | każdy pojedynczy przekłamany bit (13 bajtów × 8 bitów) → `crc_ok = '0'` |
| 4 | `init` i `en` w tym samym takcie |
| 5 | 200 losowych ramek 1–64 B, porównanie z modelem odniesienia |
| 6 | takty bez `en` (ze śmieciowymi danymi) wewnątrz ramki nie zmieniają wyniku |

Test mutacyjny: zmiana jednego bitu wielomianu daje FAIL w 405 z 514 sprawdzeń.

## Przebieg

`.\view.ps1 tb_crc32` — czas symulacji ok. 0,2 ms; wartości znane na początku:

| Czas (ok.) | Zdarzenie | Co widać |
|---|---|---|
| 25–45 ns | ramka `"a"` | po bajcie `0x61` na `crc` pojawia się `E8B7BE43` |
| 55–145 ns | ramka `"123456789"` | bajty `0x31`…`0x39`; po ostatnim `crc = CBF43926` |
| 155–585 ns | ramka „The quick brown fox…” | `crc = 414FA339` |
| ok. 0,6–0,75 µs | `"123456789"` + 4 bajty CRC (`26 39 F4 CB`) | rejestr wewnętrzny `dut.reg` kończy na `DEBB20E3`, `crc_ok = 1` |
| dalej | ramki z przekłamanym bitem | `crc_ok` pozostaje `0` po każdej z nich |

Kolejność bajtów CRC na linii jest od najmłodszego: dla `0xCBF43926` wysyłane są `26`, `39`, `F4`, `CB`.
