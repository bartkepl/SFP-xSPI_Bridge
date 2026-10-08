# Zarządzanie modułem SFP: `i2c_master`, `sfp_mgmt`

Pliki: `vhdl/sfp_bridge/src/mgmt/i2c_master.vhd`, `vhdl/sfp_bridge/src/mgmt/sfp_mgmt.vhd` · testbench: `vhdl/sim/tb/tb_i2c_sfp.vhd`; ścieżka rejestrów przez xSPI: `tb_csr_regs` (faza 10)

Mapa rejestrów: [plan, rozdz. 7.4](../sfp-xspi-bridge-plan.md). Rejestry są czytane i zapisywane przez [`csr_regs`](csr_regs.md) ([ADR 0009](../adr/0009-interfejs-hosta.md)).

## Zakres

| Funkcja | Realizacja |
|---|---|
| sygnały stanu modułu | `MOD_ABS`, `LOS`, `TX_FAULT`: synchronizator 2-FF i filtr; wyjścia filtrów zasilają `STATUS`, przerwanie `SFP_CHG` i [`link_ctrl`](link_ctrl.md) |
| `SFP_TX_DIS` | `1` w czasie resetu, poza resetem `CTRL.SFP_TX_DIS` |
| interfejs 2-wire | `i2c_master`: 100 kHz, open-drain, wydłużanie SCL przez moduł, odblokowanie magistrali |
| polecenia hosta | skrzynka: `I2C_DEV`, `I2C_OFFSET`, `I2C_LEN`, `I2C_CMD`, `I2C_STATUS`, bufor `I2C_BUF` 128 B |
| DDM | cykliczny odczyt A2h, bajty 96–110, kopia w `DDM_*` |

## `i2c_master`

Master I2C w trybie standardowym (INF-8074i: maks. 100 kHz), adresy 7-bitowe. Wyjścia `scl_oe` / `sda_oe` = 1 ściągają linię do masy; linie podciągają rezystory na płytce. Wejścia przechodzą przez synchronizator 2-FF.

| Polecenie | Sekwencja na magistrali |
|---|---|
| odczyt (`rd` = 1) | S, `dev`+W, `offset`, Sr, `dev`+R, `len` bajtów (ACK po każdym, NACK po ostatnim), P |
| zapis (`rd` = 0) | S, `dev`+W, `offset`, `len` bajtów, P |

- `len` = 1…128. Bajty odebrane: `rx_data`, `rx_idx`, impuls `rx_valid`. Bajty do wysłania: `tx_data` czytane z bufora pod `tx_idx` (odczyt asynchroniczny, `tx_idx` stały przez cały bajt).
- Brak potwierdzenia adresu lub bajtu danych kończy polecenie warunkiem STOP i `nack` = 1.
- Impuls `done` kończy każde polecenie; `nack` i `timeout` są ważne od `done` do następnego `start`.

**Taktowanie.** Okres SCL = 4 ćwiartki po `CLK_HZ / (4 · I2C_HZ)` taktów (2,5 µs przy 100 kHz):

| Parametr | Realizacja | Minimum (tryb standardowy) |
|---|---|---|
| SCL niski | 2 ćwiartki (5 µs) | 4,7 µs |
| SCL wysoki | 2 ćwiartki od chwili wykrycia stanu wysokiego | 4,0 µs |
| zmiana SDA | 1 ćwiartka po opadnięciu SCL | — |
| próbkowanie SDA | 1 ćwiartka po wykryciu SCL wysokiego | — |
| START / Sr: utrzymanie | 2 ćwiartki | 4,0 µs |
| Sr: przygotowanie | 2 ćwiartki od wykrycia SCL wysokiego | 4,7 µs |
| STOP: przygotowanie | 2 ćwiartki od wykrycia SCL wysokiego | 4,0 µs |
| wolna magistrala po STOP | ≥ 2 ćwiartki | 4,7 µs |

Czas stanu wysokiego SCL jest liczony od chwili, w której wejście SCL ma stan wysoki. Uwzględnia to wydłużanie SCL przez moduł i czas narastania zbocza na rezystorze podciągającym.

**Kontrola magistrali przed START.**
- SCL w stanie niskim: oczekiwanie z limitem `TIMEOUT_CLKS` (25 ms).
- SDA w stanie niskim (moduł przerwany w trakcie odczytu): impulsy SCL przy zwolnionej SDA, aż SDA będzie w stanie wysokim przy wysokim SCL, potem STOP i ponowna kontrola. Moduł nadający bit 1 może po STOP dalej trzymać SDA, dlatego impulsy są kontynuowane w kolejnej rundzie; łączny limit to 18 impulsów (2 bajty).
- Przekroczenie limitu SCL lub brak zwolnienia SDA kończy polecenie z `timeout` = 1 i obiema liniami zwolnionymi.

## `sfp_mgmt`

### Sygnały stanu modułu

| Sygnał | Filtr | Uzasadnienie |
|---|---|---|
| `MOD_ABS` | 10 ms (`DEB_ABS_CLKS`) | drgania styków przy wkładaniu modułu |
| `LOS`, `TX_FAULT` | 50 µs (`DEB_SIG_CLKS`) | zakłócenia; czasy reakcji modułu (INF-8074i) są rzędu 100 µs |

Wyjście filtra przyjmuje wartość wejścia, gdy ta jest stała przez czas filtra. W czasie resetu wyjścia powtarzają zsynchronizowane wejścia, więc po resecie odzwierciedlają rzeczywisty stan bez opóźnienia.

### Skrzynka poleceń I2C

| Adres | Rejestr | Opis |
|---|---|---|
| 0x30 | `I2C_DEV` | adres 7-bit, po resecie 0x50 |
| 0x31 | `I2C_OFFSET` | offset w urządzeniu |
| 0x32 | `I2C_LEN` | 1–128 |
| 0x33 | `I2C_CMD` | zapis 0x01 = READ, 0x02 = WRITE; odczyt 0 |
| 0x34 | `I2C_STATUS` | b0 `BUSY`, b1 `NACK`, b2 `TIMEOUT`, b3 `BAD_CMD` |
| 0x80–0xFF | `I2C_BUF` | dane: wynik READ albo dane do WRITE, od 0x80 |

- **Przyjęcie polecenia.** `BUSY` ustawia się w tym samym takcie, w którym `csr_regs` stosuje zapis transakcji `WRITE_REG` (po podniesieniu CS), więc transakcja odczytu następująca bezpośrednio po poleceniu (CS w stanie wysokim ≥ 100 ns) widzi już `BUSY` = 1. Bajty zapisu dla 0x30–0x4F są dekodowane w każdym takcie do rejestrów pomocniczych. Bufor zapisu jest stały przy wysokim CS, a `wr_apply` pojawia się co najmniej 2 takty po podniesieniu CS (synchronizator), więc zdekodowane wartości są wtedy stabilne.
- **Odrzucenie.** `LEN` spoza 1–128 albo brak modułu: `BAD_CMD` = 1, `NACK` = `TIMEOUT` = 0, przerwanie `I2C_DONE`. Polecenie zapisane w czasie `BUSY`: tylko `BAD_CMD` = 1, bieżące polecenie trwa dalej. `BAD_CMD` pozostaje ustawiony do następnego przyjętego polecenia.
- **Zakończenie.** `BUSY` = 0, `NACK` / `TIMEOUT` z mastera, przerwanie `I2C_DONE` (`IRQ_STAT` b4).
- **Bufor.** 128 B w pamięci rozproszonej (SSRAM, dwa porty odczytu asynchronicznego: host i master I2C). Host czyta go przez `READ_REG` w domenie SCLK bez zatrzasku. Zawartość jest stała, gdy `BUSY` = 0; w czasie `BUSY` odczyt bufora nie daje określonych danych. Bajty zapisane przez `WRITE_REG` (do 8 na transakcję) trafiają do bufora po jednym na takt przez rejestr potokowy; bajt czekający w rejestrze ustępuje zapisowi danych z mastera I2C.
- Limity stron i czas zapisu pamięci EEPROM modułu obsługuje host: po zapisie EEPROM nie potwierdza adresu, dopóki zapis wewnętrzny trwa (polecenie kończy się `NACK`).

### Odczyt DDM

| Adres | Rejestr | Źródło (A2h) |
|---|---|---|
| 0x40–0x41 | `DDM_TEMP` | bajty 96–97 |
| 0x42–0x43 | `DDM_VCC` | 98–99 |
| 0x44–0x45 | `DDM_TXBIAS` | 100–101 |
| 0x46–0x47 | `DDM_TXPWR` | 102–103 |
| 0x48–0x49 | `DDM_RXPWR` | 104–105 |
| 0x4A | `DDM_FLAGS` | 110 (stan TX_DISABLE, LOS, gotowość danych) |
| 0x4B | `DDM_STAT` | b0 `VALID`, b1 `NACK`, b2 `TIMEOUT` (ostatni odczyt) |
| 0x4C | `DDM_SEQ` | licznik udanych odczytów (zawijanie) |
| 0x4F | `DDM_PERIOD` | okres × 100 ms; 0 = wyłączony; po resecie 10 |

- Wartości 16-bitowe są w rejestrach little-endian, jak pozostałe rejestry mostka. W module (SFF-8472) mają kolejność big-endian i są zamieniane sprzętowo. Przeliczenie na jednostki (kalibracja wewnętrzna lub zewnętrzna, A0h bajt 92) wykonuje host.
- Odczyt: jedno polecenie I2C, 15 bajtów od 96. Bajty trafiają do rejestru pośredniego, a kopia `DDM_*` jest aktualizowana w całości po udanym odczycie. W połączeniu z zatrzaskiem rejestrów przy opadnięciu CS host nie odczyta wartości złożonej z dwóch odczytów.
- Pierwszy odczyt następuje `INSERT_TICKS` × 100 ms (300–400 ms) po włożeniu modułu. Interfejs 2-wire modułu jest gotowy 300 ms po włożeniu (INF-8074i, t_serial). Kolejne odczyty następują co `DDM_PERIOD` × 100 ms.
- Polecenie hosta i odczyt DDM nie przerywają się wzajemnie: oczekujące zadanie startuje, gdy master I2C jest wolny, z pierwszeństwem polecenia hosta.
- Wyjęcie modułu kasuje `VALID` i wstrzymuje odczyty. Moduły bez DDM odpowiadają `NACK` pod 0x51, co ustawia `DDM_STAT.NACK` przy każdym odczycie.

### Generyki

| Generyk | Domyślnie | Znaczenie |
|---|---|---|
| `CLK_HZ` | 50 MHz | `clk_sys` |
| `I2C_HZ` | 100 kHz | częstotliwość SCL |
| `TIMEOUT_CLKS` | 25 ms | limit SCL w stanie niskim |
| `TICK_CLKS` | 100 ms | jednostka okresu DDM |
| `INSERT_TICKS` | 4 | opóźnienie po włożeniu (300–400 ms) |
| `DEB_ABS_CLKS` / `DEB_SIG_CLKS` | 10 ms / 50 µs | filtry sygnałów stanu |

## Synteza

Próbna synteza `xspi_slave` + `csr_regs` + `sfp_mgmt` (GW1N-9C, ograniczenie `clk_sys` 12 ns, SCLK 25 ns): 2091 LUT/ALU, 1517 rejestrów, 32 × SSRAM (RAM16: bufor 128 B w dwóch kopiach, po jednej na port odczytu), 0 BSRAM; `clk_sys` Fmax 83,7 MHz, SCLK 43,0 MHz. Względem samego `xspi_slave` + `csr_regs` (1079 LUT/ALU, 848 rejestrów) zarządzanie SFP dodaje ok. 1000 LUT/ALU i 670 rejestrów; około 130 rejestrów to zatrzask CSR dla obszaru 0x30–0x4F (bity stale zerowe są usuwane przez syntezę).

## Testbench `tb_i2c_sfp`

`clk_sys` 50 MHz, I2C 100 kHz; wolne liczniki skrócone (100 ms → 0,5 ms, opóźnienie po włożeniu 4 jednostki, limit SCL 500 µs, filtry 10 µs / 1 µs). Model modułu SFP: urządzenia 0x50 (A0h) i 0x51 (A2h) po 256 B, zapis offsetu, odczyt sekwencyjny po Sr, zapis sekwencyjny, opcjonalne wydłużanie SCL po każdym potwierdzeniu, brak odpowiedzi przy wyjętym module. Magistrala z rezystorami podciągającymi (`'H'`) i wyjściami open-drain.

| Nr | Sprawdzenie |
|---|---|
| 1 | `SFP_TX_DIS` = 1 w resecie, potem `CTRL.SFP_TX_DIS`; filtry `MOD_ABS` / `LOS` zgodne z pinami zaraz po resecie; wartości domyślne `I2C_DEV`, `DDM_PERIOD` |
| 2 | polecenie bez modułu: `BAD_CMD`, `I2C_DONE`, brak ruchu na magistrali |
| 3 | włożenie z drganiami styków: jedna zmiana `MOD_ABS` po czasie filtra; impuls `LOS` krótszy od filtra pominięty, dłuższy przepuszczony; brak ruchu na magistrali przed upływem opóźnienia po włożeniu |
| 4 | READ A0h 16 B i 128 B: `BUSY` w takcie po `wr_apply`, bufor zgodny z pamięcią modułu, jedno `I2C_DONE` |
| 5 | WRITE A2h 8 B (bufor zapisany dwiema transakcjami): pamięć modułu zmieniona, następny bajt bez zmian |
| 6 | `NACK` (urządzenie 0x52); `BAD_CMD` dla `LEN` = 0 i 129 (z `I2C_DONE`) oraz dla polecenia w czasie `BUSY` — bieżące polecenie kończy się poprawnie |
| 7 | DDM: wartości little-endian w 0x40–0x49, `DDM_FLAGS`, `VALID`, rosnący `DDM_SEQ`, nowe wartości modułu po kolejnym odczycie; `DDM_PERIOD` = 0 wstrzymuje odczyty |
| 8 | wydłużanie SCL o 30 µs po każdym potwierdzeniu: READ poprawny |
| 9 | moduł trzyma SDA do 3 impulsów SCL: odblokowanie magistrali, polecenie poprawne |
| 10 | SCL trzymany w stanie niskim: `TIMEOUT`, linie zwolnione |
| 11 | wyjęcie modułu: `DDM_STAT.VALID` = 0 |
| 12 | monitor parametrów czasowych I2C przez cały test (SCL niski ≥ 4,7 µs, wysoki ≥ 4,0 µs, utrzymanie START ≥ 4,0 µs, przygotowanie Sr ≥ 4,7 µs, przygotowanie STOP ≥ 4,0 µs, wolna magistrala ≥ 4,7 µs): brak naruszeń |

W `tb_csr_regs` (faza 10) `sfp_mgmt` pracuje z rzeczywistymi `xspi_slave` i `csr_regs`: odczyt zwrotny rejestrów skrzynki i `DDM_PERIOD`, zapis 8 bajtów `I2C_BUF` przez `WRITE_REG` i ich odczyt przez `READ_REG`, `BAD_CMD` z przerwaniem `I2C_DONE` przy braku modułu, `BUSY` widoczny w transakcji bezpośrednio po poleceniu (CS w stanie wysokim 120 ns), `NACK` przy magistrali bez urządzeń.

**Test mutacyjny** (18 wariantów, `tb_i2c_sfp` + `tb_csr_regs`): wykrywane:
- master I2C: SCL niski 1 ćwiartka, utrzymanie START 1 ćwiartka, przygotowanie STOP 1 ćwiartka (monitor czasów), brak obsługi wydłużania SCL, ignorowanie NACK, ACK po ostatnim bajcie odczytu, brak odblokowania magistrali;
- `sfp_mgmt`: `BUSY` nieustawiany przy przyjęciu polecenia, polecenie przyjmowane w czasie `BUSY`, brak `I2C_DONE` dla polecenia odrzuconego, odwrócona kolejność bajtów DDM, brak filtra `MOD_ABS`, odczyt DDM bez opóźnienia po włożeniu, `VALID` niekasowany po wyjęciu, `SFP_TX_DIS` niewymuszany w resecie, utrata bajtów `I2C_BUF` zapisanych przez hosta, dane odczytu DDM zapisywane do bufora hosta.

Niewykrywane: brak kasowania oczekującego żądania przy zapisie `DDM_PERIOD` = 0. Ma ono znaczenie tylko wtedy, gdy zapis trafia między wyznaczenie odczytu a jego start; bez kasowania odbywa się wtedy jeszcze jeden odczyt.

Opóźnienie po włożeniu modułu jest pilnowane w jednym miejscu (wyznaczanie pierwszego odczytu). Druga, nadmiarowa blokada w arbitrze maskowała mutację pierwszej i została usunięta.

## Przebieg

`.\view.ps1 tb_i2c_sfp` — czas symulacji ok. 77 ms. Grupy sygnałów:
- stan modułu: `abs_pin` z drganiami i `sfp_mod_abs` zmieniający się raz, po czasie filtra;
- polecenie hosta: `wr_apply`, `busy_q`, `nack_q`, `tmo_q`, `bad_q`, `ev_done`;
- odczyt DDM: `due`, `owner`, `d_valid`, `d_seq` rosnący co 5 ms (okres 10 × 0,5 ms);
- master I2C: `state`, `seq` (DEVW → OFF → DEVR → RDATA), `cnt`, `rx_data` / `rx_valid`;
- magistrala: `scl_x`, `sda_x`. Wydłużanie SCL w fazie 8 widać jako wydłużone stany niskie (`scl_sl`). W fazie 9 `sda_stuck` trzyma SDA, master daje impulsy SCL i STOP przed właściwym poleceniem. W fazie 10 `scl_tb` trzyma SCL, master kończy po 500 µs.
