# Synchronizatory: `sync_bit`, `reset_sync`

Pliki: `vhdl/sfp_bridge/src/common/sync_bit.vhd`, `reset_sync.vhd` · testbench: `vhdl/sim/tb/tb_sync.vhd`

## `sync_bit`

Przenosi pojedynczy sygnał poziomowy do domeny zegara `clk` przez łańcuch `STAGES` przerzutników. Pierwszy przerzutnik może wejść w stan metastabilny; kolejne dają mu pełny takt na ustalenie się.

| Port | Kierunek | Opis |
|---|---|---|
| `clk` | in | zegar domeny docelowej |
| `d` | in | sygnał asynchroniczny |
| `q` | out | sygnał zsynchronizowany |

| Generyk | Domyślnie | Opis |
|---|---|---|
| `STAGES` | 2 | liczba przerzutników, ≥ 2 |
| `INIT_VAL` | `'0'` | stan łańcucha po konfiguracji |

**Założenia:** `d` jest poziomem stabilnym przez co najmniej `STAGES + 1` taktów `clk`. Impulsy krótsze od okresu `clk` mogą zostać zgubione. Wartości wielobitowe i impulsy przenosi się przez handshake lub asynchroniczne FIFO, nie przez równoległe `sync_bit`.

**Opóźnienie:** `STAGES` taktów od pierwszego zbocza, które próbkuje nową wartość.

Zastosowanie: sygnały `SFP_LOS`, `SFP_MOD_ABS`, `SFP_TX_FAULT`, bity statusu przekazywane między `clk_spi` i `clk_sys`.

## `reset_sync`

Mostek resetu domeny zgodny z [ADR 0004](../adr/0004-strategia-resetu.md): załączenie asynchroniczne, zwolnienie synchroniczne.

| Port | Kierunek | Opis |
|---|---|---|
| `clk` | in | zegar domeny |
| `arst_n` | in | asynchroniczne żądanie resetu, aktywne niskim |
| `rst` | out | reset domeny, aktywny wysokim, synchroniczny |

| Generyk | Domyślnie | Opis |
|---|---|---|
| `STAGES` | 3 | liczba zboczy do zwolnienia resetu, ≥ 2 |

**Działanie:**

- `arst_n = '0'` → `rst = '1'` natychmiast, także przy zatrzymanym zegarze.
- Po `arst_n = '1'` reset trwa jeszcze `STAGES` zboczy `clk` i zwalnia się tuż po zboczu, jednocześnie dla wszystkich przerzutników domeny.

## Testbench `tb_sync`

| Nr | Sprawdzenie |
|---|---|
| 1, 2 | `sync_bit` z `STAGES` = 2 i 3: opóźnienie dokładnie 2 i 3 zbocza, dla zmian `d` w różnych chwilach względem zegara |
| 3 | `reset_sync`: załączenie bez zegara |
| 4 | `reset_sync`: zwolnienie po dokładnie 3 zboczach, brak zmian między zboczami |
| 5 | `reset_sync`: krótki impuls `arst_n` między zboczami natychmiast załącza reset |

Test mutacyjny: przyspieszenie zwolnienia resetu o jeden takt daje FAIL.

## Przebieg

`.\view.ps1 tb_sync` — czas symulacji ok. 0,4 µs.

- **Grupa `sync_bit`:** każda zmiana `d` pojawia się na `q2` po 2 zboczach `clk`, a na `q3` po 3. Zmiany `d` są celowo przesunięte względem zegara (0; 1,7; 3,4; 5,1 ns po zboczu opadającym) — opóźnienie liczone w zboczach pozostaje takie samo.
- **Grupa `reset_sync`:** gdy `arst_n` spada, `rst` rośnie w tej samej chwili, nawet gdy `clk_run = false` (zegar zatrzymany, linia `clk` stała). Po powrocie `arst_n` do `'1'` wartość `chain` przesuwa się `111 → 110 → 100 → 000`, a `rst` opada po trzecim zboczu.
