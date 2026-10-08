# SFP-xSPI Bridge — plan konstrukcji

Moduł mostka **OCTOSPI / QUADSPI / SPI ↔ SFP (światłowód)** do łączenia dwóch mikrokontrolerów (STM32) łączem optycznym punkt–punkt, bez stosu IP. Własny, lekki protokół ramkowy z kodowaniem 8b/10b i programowym odzyskiem zegara (soft-CDR) w małym FPGA Gowin.

| Element | Wybór |
|---|---|
| FPGA | Gowin **GW1N-UV9QN48C6/I5** (GW1N-9, wersja C) — wybór uzasadnia [ADR 0001](adr/0001-fpga-gw1n-9.md) |
| Narzędzia | KiCad (PCB), Gowin EDA (VHDL), biblioteka C dla STM32 |
| Prędkość linii | **100 Mbaud** (8b/10b → 80 Mbit/s → ok. 9 MB/s danych użytecznych) |
| Interfejs hosta | SPI (1-1-1), QSPI (1-1-4 / 1-4-4), OCTOSPI (1-1-8 / 1-8-8), SDR |
| Strona optyczna | Dowolny moduł SFP 1.25G (MM/SM, duplex lub BiDi) |
| Zasilanie | jedno **3,3 V** (wersja UV FPGA, moduł SFP) |

> Status dokumentu: plan wstępny. Pozycje oznaczone **[DO WERYFIKACJI]** wymagają sprawdzenia w dokumentacji Gowin (UG114, UG289, UG290, UG286) przed rysowaniem schematu. Kopie dokumentacji: [`datasheets/`](datasheets/).

---

## 1. Architektura

```
            OCTOSPI/QSPI/SPI                       LVDS 100 Mbaud
  STM32  <=====================>  GW1N-9    <=====================>  SFP  ~~~ światłowód ~~~  SFP <=> GW1N <=> STM32
  (master)   CLK, CS, IO0..7,      (FPGA)     TD±  -> moduł SFP
             DQS, IRQ, RST                   RD±  <- moduł SFP
                                   I2C master ---> SFP EEPROM/DDM (0x50/0x51)
                                   GPIO ---------> TX_DISABLE, TX_FAULT, LOS, MOD_ABS
```

Wewnątrz FPGA:

```
 xSPI slave ─> rejestry/CSR ─┬─> TX FIFO ─> framer ─> CRC32 ─> enc 8b/10b ─> serializer ─> TLVDS_OBUF ─> SFP TD±
  (domena SCLK)              │
                             ├─< RX FIFO <─ deframer <─ CRC check <─ dec 8b/10b <─ comma align <─ soft-CDR <─ IDES4 <─ TLVDS_IBUF <─ SFP RD±
                             │
                             ├─> I2C master + mailbox + autopolling DDM ─> SFP SCL/SDA
                             └─> GPIO SFP, LED, IRQ
```

Domeny zegarowe:

| Domena | Źródło | Częstotliwość | Co pracuje |
|---|---|---|---|
| `clk_spi` | pin SCLK od MCU | do 50 MHz (cel: 25–50 MHz) | slave xSPI, strona zapisu/odczytu FIFO od hosta |
| `clk_fast` | PLL | 200 MHz | FCLK gearboxa IDES4 (i opcjonalnie OSER4) |
| `clk_sys` | CLKDIV(/2) z `clk_fast` | 100 MHz | całe łącze: CDR, 8b/10b, framer, CRC, I2C, CSR |

Przejścia między domenami: asynchroniczne FIFO (BSRAM w trybie semi-dual port, liczniki w kodzie Graya) oraz synchronizatory 2-FF dla pojedynczych bitów.

---

## 2. Kluczowe parametry układu (z DS100, wersja 3.3.3E)

Kolumna GW1N-4 pozostaje dla porównania; układem docelowym jest GW1N-9 ([ADR 0001](adr/0001-fpga-gw1n-9.md)).

| Parametr | GW1N-4 | GW1N-9 | Uwagi |
|---|---|---|---|
| LUT4 / FF | 4608 / 3456 | 8640 / 6480 | |
| BSRAM | 10 × 18 kbit (180 kbit) | 26 × 18 kbit (468 kbit) | |
| PLL | 2 | 2 | |
| User Flash | 256 kbit | 608 kbit | wewnętrzny Flash konfiguracji + user Flash |
| QN48: I/O użytkownika (pary true LVDS) | **40 (9)** | **40 (12)** | QN48F dla GW1N-9: 40 (11) |
| IDES4, max szybkość szeregowa (C6/I5) | 750 Mbps | 750 Mbps | wykorzystujemy 400 Msps |
| IDES8/10, max (C6/I5) | 1000 Mbps | 1000 Mbps | rezerwa na wyższe prędkości |
| PLL FIN | 3–400 MHz | 3–400 MHz | |
| PLL VCO (C6/I5) | 400–1000 MHz | 400–1200 MHz | |
| PLL FOUT max (C6/I5) | 500 MHz | 600 MHz | |
| LVDS wyjście VOD / VOS | 250–450 mV / 1,125–1,375 V | jw. | przy RT = 100 Ω |
| LVDS wejście VCM / VTHD | 0,05–2,1 V / ±100 mV | jw. | |
| Oscylator wewnętrzny | 105 MHz (ok. ±7%) | 125 MHz (±5%) | **nie** do łącza |

Ważne ograniczenia z DS100:

- **GW1N-9 wersja C** (GW1N-UV9QN48C6/I5): BSRAM obsługuje tryb dual-port, lecz nie obsługuje szerokości danych 1 i 2 bit. FIFO pozostaje w trybie **semi-dual port** (zapis port A, odczyt port B, osobne zegary).
- **GW1N-9 wersja C:** ograniczenia VCCIO dla Bank0/1/3 nie obowiązują. Wszystkie banki pracują przy 3,3 V.
- Ograniczenie GW1N-4 (piny `IOL10x`/`IOR10x` bez IO logic) nie dotyczy GW1N-9 (UG289, rozdz. 4).
- **UV:** jeżeli w obudowie VCC i VCCX dzielą pin, VCC musi wynosić 2,5–3,3 V. Przy jednym 3,3 V spełnione.
- **True LVDS input** wymaga terminacji 100 Ω. W GW1N-9 wewnętrzna programowalna terminacja 100 Ω jest dostępna **wyłącznie w banku 0** (UG289, rozdz. 3.3.2; atrybut `.cst`: `DIFF_RESISTOR=ON`). Na PCB przewidziany jest także footprint terminacji zewnętrznej.
- Wejście różnicowe (`TLVDS_IBUF`) obsługują wszystkie banki. Wyjście true LVDS (`TLVDS_OBUF`) wyłącznie pary oznaczone w UG114 jako *TRUE*. Prąd wyjścia LVDS25 w GW1N-9: 1,25 / 2 / 2,5 / 3,5 mA (DS100, tab. 2-1).
- Podczas konfiguracji wszystkie GPIO są w stanie wysokiej impedancji ze słabym pull-upem. Uwzględnić w sterowaniu `TX_DISABLE` (pull-up = laser wyłączony, to dobrze).
- **QN48, tryb konfiguracji:** MODE0 jest wewnętrznie zwarty do masy, MODE1 i MODE2 są połączone na pinie 48. Pin 48 w stanie niskim daje `000` = AUTOBOOT, w stanie wysokim `110` = DUAL BOOT (UG290, tab. 5-1). Ze względu na wewnętrzny pull-up pin 48 wymaga **zewnętrznego rezystora do masy**.

---

## 3. Przydział pinów (logiczny)

QN48 ma 40 I/O użytkownika. Projekt wymaga 26 I/O (z DQS i diodami LED), więc zostaje 14 zapasu.

**Fizyczne numery pinów:** z UG114 (GW1N-9 Pinout), kolumna QN48. Poniżej reguły wyboru dla każdego sygnału.

### 3.1 Tabela sygnałów

| # | Sygnał | Kier. | Standard I/O | Reguła wyboru pinu | Pin QN48 |
|---|---|---|---|---|---|
| 1 | `SFP_TD_P` | out | LVDS25 (TLVDS) | para oznaczona *True LVDS* z obsługą wyjścia, pin „True/A” pary, IO logic dostępna | TBD |
| 2 | `SFP_TD_N` | out | LVDS25 (TLVDS) | „Comp/B” tej samej pary | TBD |
| 3 | `SFP_RD_P` | in | LVDS25 (TLVDS) | para *True LVDS*, IO logic (IDES4), najlepiej bank z wewnętrzną terminacją 100 Ω | TBD |
| 4 | `SFP_RD_N` | in | LVDS25 (TLVDS) | „Comp/B” tej samej pary | TBD |
| 5 | `CLK_25M` | in | LVCMOS33 | **pin GCLKT_x** będący dedykowanym wejściem PLL (PLL_CLKIN), blisko PLL obsługującego bank RX | TBD |
| 6 | `XSPI_SCLK` | in | LVCMOS33 | **pin GCLKT_x** (inny niż `CLK_25M`) — SCLK taktuje slave bezpośrednio | TBD |
| 7 | `XSPI_CS_N` | in | LVCMOS33, pull-up | dowolny GPIO, ten sam bank co IO0..7 | TBD |
| 8–15 | `XSPI_IO0..IO7` | inout | LVCMOS33 | jeden bank, krótkie i równe ścieżki do złącza | TBD |
| 16 | `XSPI_DQS` | out | LVCMOS33 | opcjonalny (tylko OCTOSPI DDR w przyszłości), ten sam bank | TBD |
| 17 | `HOST_IRQ_N` | out | LVCMOS33, open-drain lub push-pull | dowolny GPIO | TBD |
| 18 | `HOST_RST_N` | in | LVCMOS33, pull-up | dowolny GPIO (reset logiki, nie rekonfiguracja) | TBD |
| 19 | `SFP_TX_DIS` | out | LVCMOS33 | dowolny GPIO; zewnętrzny pull-up 4,7 kΩ (laser off domyślnie) | TBD |
| 20 | `SFP_TX_FAULT` | in | LVCMOS33 | dowolny GPIO; pull-up 4,7–10 kΩ | TBD |
| 21 | `SFP_LOS` | in | LVCMOS33 | dowolny GPIO; pull-up 4,7–10 kΩ | TBD |
| 22 | `SFP_MOD_ABS` | in | LVCMOS33 | MOD_DEF0; pull-up 4,7–10 kΩ | TBD |
| 23 | `SFP_SCL` | inout (OD) | LVCMOS33, open-drain | MOD_DEF1; pull-up 4,7 kΩ | TBD |
| 24 | `SFP_SDA` | inout (OD) | LVCMOS33, open-drain | MOD_DEF2; pull-up 4,7 kΩ | TBD |
| 25 | `LED_LINK` | out | LVCMOS33 | dowolny GPIO | TBD |
| 26 | `LED_ACT` | out | LVCMOS33 | dowolny GPIO | TBD |

Piny dedykowane, **nieużywane jako GPIO**:

| Sygnał | Funkcja | Połączenie |
|---|---|---|
| `TCK`, `TMS`, `TDI`, `TDO` | JTAG | złącze JTAG + opcjonalnie do MCU (aktualizacja w polu) |
| `JTAGSEL_N` | wybór JTAG | pull-up; nie zaznaczać „Use JTAG as regular IO” |
| `RECONFIG_N` | rekonfiguracja | pull-up 10 kΩ + opcjonalny przycisk / GPIO MCU (open-drain) |
| `READY`, `DONE` | status konfiguracji | pull-up 4,7–10 kΩ; LED na DONE |
| `MODE` (pin 48 = MODE2 + MODE1; MODE0 wewnętrznie do masy) | tryb konfiguracji | rezystor do masy (np. 1 kΩ) → `000` = AUTOBOOT; stan wysoki dałby DUAL BOOT |

### 3.2 Reguły przydziału (do sprawdzenia w pinoucie)

1. **Wszystkie banki VCCIO = 3,3 V.** LVDS25 (TLVDS) działa przy VCCIO 2,5/3,3 V, więc jedno napięcie wystarczy.
2. Para TD na parze z wyjściem true LVDS (kolumna „LVDS” = TRUE w UG114). Para RD w banku 0 (wewnętrzna terminacja 100 Ω). Pary LVDS wybiera się najpierw, resztę sygnałów potem.
3. RD w banku obsługiwanym przez HCLK, który może taktować IDES4. W GW1N-9C HCLKMUX przenosi HCLK między bankami (UG286, rozdz. 2.2).
4. `XSPI_SCLK` musi być pinem GCLK. Przy 25–50 MHz SCLK nie da się go nadpróbkować zegarem 100 MHz.
5. Magistrala xSPI w jednym banku, po jednej stronie układu, z krótkimi i równymi ścieżkami.
6. `CLK_25M` na dedykowanym wejściu PLL. Inaczej PLL dostaje zegar przez sieć globalną z dodatkowym jitterem.

---

## 4. Zegary i PLL

```
CLK_25M (25 MHz, ±25 ppm, CMOS 3,3 V)
   └─> rPLL: IDIV=1, FBDIV=8, ODIV=4  → VCO = 800 MHz, CLKOUT = 200 MHz  (clk_fast, HCLK)
          └─> CLKDIV (DIV_MODE="2")   → 100 MHz                           (clk_sys)
```

- 200 MHz FCLK × DDR daje **400 Msps**, czyli dokładnie **4× nadpróbkowanie przy 100 Mbaud**. IDES4 oddaje 4 próbki co takt `clk_sys` (100 MHz).
- VCO 800 MHz mieści się w zakresie 400–1200 MHz (GW1N-9 C6/I5).
- `CLKDIV` zamiast drugiego wyjścia PLL, żeby `clk_sys` był fazowo powiązany z FCLK gearboxa (wymagane przez IDES/OSER).
- Oba końce łącza pracują na niezależnych generatorach. Różnicę ppm absorbuje sam CDR z nadpróbkowaniem (wydaje 0, 1 lub 2 bity na takt), więc **bufor elastyczny nie jest potrzebny**.
- Docelowo wyższe prędkości: 125 Mbaud → `clk_fast` = 250 MHz, `clk_sys` = 125 MHz (VCO 1000 MHz, w zakresie GW1N-9 do 1200 MHz). Prędkość linii parametryzowana stałymi w pakiecie VHDL.

---

## 5. Warstwa fizyczna (PCB)

### 5.1 SFP

| Pin SFP | Połączenie |
|---|---|
| VccT, VccR | osobne filtry wg SFF-8431: 1 µH (≥0,5 A, niski DCR) + 22 µF + 0,1 µF każdy |
| VeeT, VeeR | masa |
| TD+ / TD− | z `SFP_TD_P/N` przez 2 × 100 nF 0402 (moduł zwykle ma też sprzężenie wewnętrzne — zostawić footprinty, ewentualnie 0 Ω) |
| RD+ / RD− | przez 2 × 100 nF 0402 → terminacja 100 Ω (wewn. FPGA lub zewn.) → bias trybu wspólnego ok. 1,2 V → `SFP_RD_P/N` |
| TX_DISABLE | `SFP_TX_DIS`, pull-up 4,7 kΩ do 3,3 V |
| TX_FAULT, LOS, MOD_DEF0 | pull-upy 4,7–10 kΩ do 3,3 V → GPIO |
| MOD_DEF1/2 | `SFP_SCL/SDA`, pull-upy 4,7 kΩ |
| RS0, RS1 (RATE_SELECT) | 10 kΩ do masy |
| Klatka (cage) | masa obudowy (chassis), zgodnie z wytycznymi producenta klatki |

**Poziomy sygnałów:**

- TX: GW1N-9 daje VOD 250–450 mV, czyli **500–900 mVppd**. Wejście SFP 1G (MSA) wymaga zwykle 500–2400 mVppd. Margines przy dolnej granicy jest minimalny, więc ustawić **drive 3,5 mA** w constraints i sprawdzić w datasheecie wybranego modułu **[DO WERYFIKACJI]**.
- RX: wyjście SFP to zwykle 370–2000 mVppd (CML, sprzężone AC). VTHD FPGA ±100 mV daje duży zapas. Bias około 1,2 V mieści się w VCM 0,05–2,1 V.

### 5.2 Bias toru RX (wariant z zewnętrzną terminacją)

```
RD+ ──||── ┬──────────────── FPGA RD_P
          50 Ω
           ├── Vbias 1,2 V (dzielnik 3,3 V: np. 2,1 kΩ / 1,2 kΩ + 100 nF do masy)
          50 Ω
RD− ──||── ┴──────────────── FPGA RD_N
```

Przy wewnętrznej terminacji FPGA: AC + rezystory biasu ok. 10 kΩ z każdej linii do Vbias, bez 2 × 50 Ω.

### 5.3 Reguły layoutu (100 Mbaud, zbocza SFP ok. 100–200 ps)

| Reguła | Wartość |
|---|---|
| Impedancja par TD/RD | 100 Ω różnicowo, ciągła płaszczyzna odniesienia |
| Dopasowanie w parze | ≤ 0,5 mm |
| Przelotki w parze | minimum, symetrycznie |
| Kondensatory AC | 0402, przy odbiorniku |
| xSPI | wspólna długość ±5 mm, rezystory szeregowe 22–33 Ω przy źródle (MCU dla CLK/CS, przy FPGA dla IO w kierunku odczytu — footprinty z obu stron) |
| Stack-up | min. 4 warstwy (sygnał / GND / 3V3 / sygnał) |

### 5.4 Zasilanie

| Odbiornik | Prąd (szac.) |
|---|---|
| Moduł SFP 1.25G | do ok. 300 mA |
| GW1N-UV9 (VCC=VCCX=VCCIO=3,3 V) | ok. 50–100 mA |
| Generator, LED, reszta | ok. 20 mA |
| **Razem** | **ok. 0,5 A → projektować na 0,6–0,8 A** |

Odsprzęganie: 100 nF przy każdym pinie zasilania FPGA, 4,7–10 µF na bank, bulk 47 µF na wejściu. Opcjonalnie TVS na wejściu 3,3 V.

### 5.5 Złącze hosta (propozycja: 2 × 10, raster 1,27 mm)

| Pin | Sygnał | Pin | Sygnał |
|---|---|---|---|
| 1 | 3V3 | 2 | 3V3 |
| 3 | GND | 4 | XSPI_SCLK |
| 5 | GND | 6 | XSPI_CS_N |
| 7 | XSPI_IO0 | 8 | XSPI_IO1 |
| 9 | XSPI_IO2 | 10 | XSPI_IO3 |
| 11 | XSPI_IO4 | 12 | XSPI_IO5 |
| 13 | XSPI_IO6 | 14 | XSPI_IO7 |
| 15 | GND | 16 | XSPI_DQS |
| 17 | HOST_IRQ_N | 18 | HOST_RST_N |
| 19 | GND | 20 | GND |

Osobne złącze JTAG (1 × 6: 3V3, GND, TCK, TMS, TDI, TDO) dla programatora FT2232H/FT232H (openFPGALoader) albo oficjalnego kabla Gowin.

### 5.6 Lista elementów (BOM, główne pozycje)

| Pozycja | Uwagi |
|---|---|
| GW1N-UV9QN48C6/I5 | Mouser (jedyne źródło, stan 2026-10-08: ok. 90 szt.) |
| Klatka SFP + złącze 20-pin | press-fit lub SMT |
| Generator 25 MHz, ±25 ppm, CMOS 3,3 V | |
| Dławiki 1 µH × 2 (filtr SFF-8431) | ≥ 0,5 A |
| Rezystory, kondensatory 0402 | pull-upy, bias, terminacja, AC |
| Złącze hosta 2 × 10 / 1,27 mm | |
| Złącze JTAG 1 × 6 | |
| LED × 3 (DONE, LINK, ACT) | |
| Opcjonalnie: TVS 3,3 V, przycisk RECONFIG | |

---

## 6. Konfiguracja FPGA (Gowin EDA)

| Ustawienie | Wartość |
|---|---|
| Urządzenie | GW1N-UV9QN48C6/I5 (Device: GW1N-9C, `set_device GW1N-UV9QN48C6/I5 -device_version C`) |
| Język | VHDL-2008 (synteza GowinSynthesis); prymitywy Gowin z biblioteki dostarczanej z Gowin EDA |
| Tryb konfiguracji | **AUTOBOOT** z wewnętrznego Flash; programowanie przez JTAG (Gowin Programmer lub openFPGALoader) |
| Dual-purpose pins | JTAG, JTAGSEL_N, RECONFIG_N, DONE, MODE: dedykowane; MSPI jako GPIO (`-use_mspi_as_gpio 1`) |
| Background upgrade | aktualizacja Flash przez JTAG bez przerywania pracy, aktywacja przez `RECONFIG_N` **[DO WERYFIKACJI w UG290 dla GW1N-9C]** |
| Bitstream | kompresja wł., security bit wg potrzeb |
| Constraints (.cst) | IO_TYPE: `LVDS25` dla par TD/RD, `LVCMOS33` dla reszty; DRIVE=3.5 dla TD; DIFF_RESISTOR=ON dla RD; PULL_MODE=UP dla CS_N, RST_N; OPEN_DRAIN=ON dla SCL/SDA |
| Timing (.sdc) | `create_clock` 25 MHz (`CLK_25M`), 50 MHz (`XSPI_SCLK`); clock groups asynchroniczne między `clk_spi` a `clk_sys`; set_input/output_delay dla xSPI wg timingu STM32 |

Przykładowe constraints (do uzupełnienia numerami pinów):

```text
// sfp_bridge.cst
IO_LOC  "SFP_TD_P"   <pin>;  IO_PORT "SFP_TD_P"  IO_TYPE=LVDS25 DRIVE=3.5;
IO_LOC  "SFP_RD_P"   <pin>;  IO_PORT "SFP_RD_P"  IO_TYPE=LVDS25 DIFF_RESISTOR=ON;
IO_LOC  "CLK_25M"    <pin>;  IO_PORT "CLK_25M"   IO_TYPE=LVCMOS33;
IO_LOC  "XSPI_SCLK"  <pin>;  IO_PORT "XSPI_SCLK" IO_TYPE=LVCMOS33;
IO_LOC  "XSPI_CS_N"  <pin>;  IO_PORT "XSPI_CS_N" IO_TYPE=LVCMOS33 PULL_MODE=UP;
IO_LOC  "SFP_SCL"    <pin>;  IO_PORT "SFP_SCL"   IO_TYPE=LVCMOS33 OPEN_DRAIN=ON;
IO_LOC  "SFP_SDA"    <pin>;  IO_PORT "SFP_SDA"   IO_TYPE=LVCMOS33 OPEN_DRAIN=ON;
```

```text
// sfp_bridge.sdc
create_clock -name clk_25m  -period 40.000 [get_ports {CLK_25M}]
create_clock -name clk_spi  -period 20.000 [get_ports {XSPI_SCLK}]
set_clock_groups -asynchronous -group [get_clocks {clk_spi}] -group [get_clocks {clk_25m}]
```

Składnia atrybutów `DRIVE=3.5` (LVDS25) i `DIFF_RESISTOR=ON` została potwierdzona przebiegiem syntezy i PnR w Gowin EDA 1.9.11.03.

---

## 7. Projekt FPGA (VHDL)

### 7.1 Struktura katalogów

```
vhdl/
  sfp_bridge.gprj
  constraints/
    sfp_bridge.cst
    sfp_bridge.sdc
  src/
    pkg/
      bridge_pkg.vhd          -- stałe: prędkość linii, rozmiary FIFO, adresy rejestrów, kody K
    top/
      sfp_bridge_top.vhd
    clk/
      clk_rst.vhd             -- rPLL + CLKDIV + synchronizacja resetów
    host/
      xspi_slave.vhd          -- SPI/QSPI/OCTOSPI slave, dekoder komend
      csr_regs.vhd            -- rejestry kontrolne/statusowe, IRQ
    fifo/
      async_fifo.vhd          -- FIFO na BSRAM semi-dual port, liczniki Graya
    link/
      tx_framer.vhd           -- SOF/EOF, długość, idle
      crc32.vhd               -- CRC-32 (bajtowo)
      enc_8b10b.vhd
      tx_phy.vhd              -- rejestr wyjściowy / OSER4 + TLVDS_OBUF
      rx_phy.vhd              -- TLVDS_IBUF + IDES4
      cdr_os4.vhd             -- odzysk danych z 4× nadpróbkowania
      comma_align.vhd         -- wyrównanie do K28.5
      dec_8b10b.vhd           -- dekoder + błędy kodu/dysparytetu
      rx_deframer.vhd         -- SOF/EOF, długość, sprawdzenie CRC
      link_ctrl.vhd           -- stan łącza, LOS, liczniki błędów
    mgmt/
      i2c_master.vhd
      sfp_mgmt.vhd            -- mailbox I2C, autopolling DDM, GPIO SFP
      leds.vhd
  sim/
    tb_enc_dec_8b10b.vhd
    tb_cdr_os4.vhd            -- z modelowanym odchyleniem ±100 ppm i jitterem
    tb_link_loopback.vhd      -- TX → (model kanału) → RX
    tb_xspi_slave.vhd         -- model STM32 OCTOSPI w trybach 1-1-1/1-1-4/1-1-8
```

### 7.2 Moduły — co powinny zawierać

**`clk_rst`**
- `rPLL` (25 → 200 MHz), `CLKDIV` (/2 → 100 MHz).
- Reset globalny trzymany do `LOCK` PLL. Osobne synchronizatory resetu dla `clk_sys` i `clk_spi` (reset asynchroniczny, zwalnianie synchroniczne).

**`xspi_slave`** (domena `clk_spi`, CS_N jako asynchroniczny reset maszyny stanów)
- Fazy: instrukcja (zawsze 1 linia) → opcjonalny adres → dummy → dane, szerokość fazy danych wynika z opkodu (tabela 7.3).
- Próbkowanie na zboczu narastającym SCLK, wystawianie na opadającym (tryb 0).
- Kierunek IO0..7 przełączany po fazie dummy przy odczycie.
- Interfejs do FIFO: zapis bajtów do TX FIFO / odczyt z RX FIFO bez udziału `clk_sys`. Rejestry CSR przez prosty handshake CDC.

**`csr_regs`** — mapa rejestrów w rozdziale 7.4.

**`async_fifo`**
- BSRAM w trybie semi-dual port (zapis port A, odczyt port B, różne zegary), liczniki wskaźników w kodzie Graya, synchronizatory 2-FF.
- Flagi: pusty, pełny, poziom zapełnienia (do IRQ).
- Rozmiary minimalne: TX 4 kB (2 bloki), RX 4 kB (2 bloki), bufor I2C 256 B (1 blok). Razem 5 z 26 bloków; zapas pozwala zwiększyć FIFO.
- Alternatywnie FIFO IP z Gowin EDA, o ile generuje VHDL. Własna implementacja daje przenośność.

**`tx_framer`**
- Ramka: `K27.7 (SOF) | TYPE | LEN_H | LEN_L | payload (1..1024 B) | CRC32 (4 B) | K29.7 (EOF)`.
- Poza ramką ciągły idle: para `K28.5 + D16.2` (jak /I2/ w 1000BASE-X), utrzymuje dysparytet i synchronizację CDR.
- Ramkę zaczyna dopiero wtedy, gdy w TX FIFO jest cała ramka (licznik ramek), więc w środku ramki nie ma przerw.

**`crc32`** — CRC-32 IEEE 802.3, przetwarzanie bajtowe, jeden bajt na takt.

**`enc_8b10b` / `dec_8b10b`**
- Standardowa tabela 5b/6b + 3b/4b z bieżącym dysparytetem.
- Dekoder zgłasza flagi `code_err` i `disp_err`.

**`tx_phy`**
- Wariant A (prostszy): serializacja 10 → 1 w `clk_sys` (100 MHz = 100 Mbaud), rejestr wyjściowy w IOB → `TLVDS_OBUF`.
- Wariant B: `OSER4` taktowany `clk_fast`/`clk_sys`, każdy bit powielony 4×. Daje identyczne opóźnienia jak tor RX i łatwe przejście na wyższe prędkości.

**`rx_phy`** — `TLVDS_IBUF` → `IDES4` (FCLK = 200 MHz, PCLK = 100 MHz) → 4 próbki na takt `clk_sys`.

**`cdr_os4`** (serce odbiornika, wzorowany na XAPP224 / XAPP523)
- Wejście: 4 próbki na takt. Wykrywanie zboczy między kolejnymi próbkami (także między taktami).
- Statystyka zboczy w oknie kilkunastu taktów → wybór fazy próbkowania najdalej od zboczy.
- Śledzenie dryfu: przy zawinięciu fazy wydanie **0 albo 2 bitów** zamiast 1, co kompensuje różnicę ppm.
- Wyjście: `bit_valid(1:0)` + `bits(1:0)` do rejestru przesuwnego.
- Filtr histerezy, żeby jitter nie przełączał fazy co takt.

**`comma_align`**
- Rejestr przesuwny ≥ 20 bitów, wykrywanie wzorca comma (`0011111` / `1100000`) i ustalenie granicy słowa 10-bit.
- Synchronizacja po N poprawnych K28.5, utrata po M błędach kodu (maszyna stanów jak w 1000BASE-X PCS).

**`rx_deframer`**
- Oczekiwanie na SOF, odczyt typu i długości, zapis do RX FIFO, liczenie CRC.
- Przy złym CRC: odrzucenie ramki (cofnięcie wskaźnika zapisu FIFO) i inkrementacja licznika.

**`link_ctrl`**
- Stany: `DOWN` (LOS lub brak sync) → `SYNC` → `UP`.
- Liczniki: błędy kodu, dysparytetu, CRC, ramki TX/RX.
- Tryby pętli zwrotnej dla testów: near-end (TX 8b/10b → RX wewnątrz FPGA) i far-end.

**`i2c_master` + `sfp_mgmt`**
- I2C 100 kHz (opcjonalnie 400 kHz), open-drain przez trójstanowe wyjście.
- Mailbox: rejestry `I2C_DEV` (0x50/0x51), `I2C_OFFSET`, `I2C_LEN`, `I2C_CMD` (READ/WRITE), `I2C_STATUS` (BUSY/DONE/NACK), bufor 256 B w BSRAM.
- Autopolling DDM co np. 1 s (bajty 96–105 z A2h: temperatura, Vcc, prąd lasera, Tx power, Rx power) → rejestry cienia.
- Debounce i rejestry statusu `TX_FAULT`, `LOS`, `MOD_ABS`. Zmiana stanu generuje przerwanie.

**`leds`** — LINK (stan `UP`), ACT (rozciągnięty impuls przy ramce TX/RX).

### 7.3 Zestaw komend xSPI (wzorowany na SPI NOR)

| Opkod | Nazwa | Format (instr-adres-dane) | Dummy | Opis |
|---|---|---|---|---|
| `0x9F` | READ_ID | 1-0-1 | 0 | ID modułu (4 B) |
| `0x05` | READ_STATUS | 1-0-1 | 0 | szybki status (1 B): LINK, RX_AVAIL, TX_SPACE, IRQ |
| `0x0B` | READ_REG | 1-1-1 | 8 cykli | odczyt rejestru CSR (adres 8-bit, auto-inkrementacja) |
| `0x02` | WRITE_REG | 1-1-1 | 0 | zapis rejestru CSR |
| `0x12` | TX_WRITE_1 | 1-0-1 | 0 | zapis payloadu ramki do TX FIFO |
| `0x32` | TX_WRITE_4 | 1-0-4 | 0 | jw., 4 linie |
| `0x82` | TX_WRITE_8 | 1-0-8 | 0 | jw., 8 linii |
| `0x13` | RX_READ_1 | 1-0-1 | 8 cykli | odczyt z RX FIFO |
| `0x6B` | RX_READ_4 | 1-0-4 | 8 cykli | jw., 4 linie |
| `0x8B` | RX_READ_8 | 1-0-8 | 8 cykli | jw., 8 linii |

Zasady:
- Zapis ramki: `WRITE_REG TX_LEN` → `TX_WRITE_x` (LEN bajtów) → `WRITE_REG TX_COMMIT` (lub automatycznie po LEN bajtach).
- Odczyt ramki: `READ_REG RX_LEN` (długość następnej ramki) → `RX_READ_x` → `WRITE_REG RX_POP`.
- Opkody `0x8x` są własne (nie z JEDEC), a STM32 OCTOSPI w trybie indirect przyjmie dowolny opkod.
- Dummy cykle dają FPGA czas na pobranie pierwszego bajtu z FIFO przez CDC.

### 7.4 Mapa rejestrów CSR (szkic)

| Adres | Nazwa | R/W | Opis |
|---|---|---|---|
| 0x00 | ID | R | stała `0x5F5B` |
| 0x01 | VERSION | R | wersja bitstreamu |
| 0x02 | CTRL | R/W | TX_EN, RX_EN, LOOPBACK[1:0], SFP_TX_DIS, SOFT_RST |
| 0x03 | STATUS | R | LINK_UP, SYNC, LOS, TX_FAULT, MOD_ABS, RX_AVAIL, TX_FULL |
| 0x04 | IRQ_EN | R/W | maska przerwań |
| 0x05 | IRQ_STAT | R/W1C | RX_FRAME, TX_EMPTY, LINK_CHG, SFP_CHG, I2C_DONE, ERR |
| 0x06–0x07 | TX_LEN | R/W | długość ramki do wysłania |
| 0x08 | TX_COMMIT | W | wyślij ramkę |
| 0x09–0x0A | TX_SPACE | R | wolne miejsce w TX FIFO |
| 0x0B–0x0C | RX_LEN | R | długość ramki na czele RX FIFO |
| 0x0D | RX_POP | W | zwolnij ramkę |
| 0x10–0x1F | CNT_* | R | liczniki: CODE_ERR, DISP_ERR, CRC_ERR, FRAMES_TX, FRAMES_RX (32-bit) |
| 0x20 | I2C_DEV | R/W | 0x50 lub 0x51 |
| 0x21 | I2C_OFFSET | R/W | |
| 0x22 | I2C_LEN | R/W | |
| 0x23 | I2C_CMD | W | START_READ / START_WRITE |
| 0x24 | I2C_STATUS | R | BUSY, DONE, NACK |
| 0x30–0x3F | DDM_* | R | rejestry cienia DDM |
| 0x40 | DDM_PERIOD | R/W | okres autopollingu |
| 0x80–0xFF | I2C_BUF | R/W | okno na bufor I2C (128 B, stronicowane) |

### 7.5 Szacunek zasobów (GW1N-9)

| Blok | LUT | BSRAM |
|---|---|---|
| xSPI slave + CSR | 400–600 | – |
| 2 × async FIFO | 150–250 | 4 |
| Framer/deframer + CRC32 | 300–500 | – |
| 8b/10b enc + dec | 150–200 | – |
| CDR + comma align + link_ctrl | 300–500 | – |
| I2C + mailbox + DDM | 200–400 | 1 |
| **Razem** | **ok. 1,5–2,5k / 8,6k** | **5 / 26** |

### 7.6 Prymitywy Gowin (VHDL)

Deklaracje komponentów są w bibliotece prymitywów dostarczanej z Gowin EDA. Użyte prymitywy: `rPLL`, `CLKDIV`, `TLVDS_IBUF`, `TLVDS_OBUF`, `IDES4`, opcjonalnie `OSER4`, `IODELAY` (strojenie fazy RX), `SDPB` (BSRAM semi-dual port) lub wnioskowanie RAM z kodu, `IOBUF` (I2C, xSPI IO).

Plan weryfikacji: symulacja w GHDL lub ModelSim z modelami prymitywów Gowin. Testbench `tb_cdr_os4` z odchyleniem częstotliwości ±100 ppm i losowym jitterem ±0,2 UI.

---

## 8. Biblioteka C dla STM32

```
firmware/sfp_bridge/
  include/sfp_bridge.h
  src/sfp_bridge.c          -- logika: ramki, rejestry, I2C SFP, DDM
  port/sfp_bridge_port.h    -- warstwa abstrakcji transportu
  port/stm32_ospi_port.c    -- HAL_XSPI / HAL_OSPI (H5/H7/U5)
  port/stm32_qspi_port.c    -- HAL_QSPI (F7/H7)
  port/stm32_spi_port.c     -- HAL_SPI + DMA
```

Warstwa portu (do zaimplementowania per MCU):

```c
typedef struct {
    int (*cmd_write)(void *ctx, uint8_t opcode, const uint8_t *addr, uint8_t addr_len,
                     const uint8_t *data, size_t len, uint8_t data_lines);
    int (*cmd_read)(void *ctx, uint8_t opcode, const uint8_t *addr, uint8_t addr_len,
                    uint8_t dummy_cycles, uint8_t *data, size_t len, uint8_t data_lines);
    void (*delay_ms)(uint32_t ms);
    void *ctx;
} sfpb_port_t;
```

API (szkic):

```c
int  sfpb_init(sfpb_t *dev, const sfpb_port_t *port, uint8_t data_lines);   // 1, 4 lub 8
int  sfpb_link_status(sfpb_t *dev, sfpb_status_t *st);
int  sfpb_send(sfpb_t *dev, const void *buf, uint16_t len);                // blokująco lub z timeoutem
int  sfpb_recv(sfpb_t *dev, void *buf, uint16_t maxlen, uint16_t *len);
int  sfpb_irq_handler(sfpb_t *dev);                                         // z EXTI na HOST_IRQ_N
int  sfpb_sfp_read(sfpb_t *dev, uint8_t i2c_addr, uint8_t off, void *buf, uint8_t len);
int  sfpb_sfp_ddm(sfpb_t *dev, sfpb_ddm_t *ddm);                            // przeliczone jednostki
int  sfpb_set_loopback(sfpb_t *dev, sfpb_loopback_t mode);
int  sfpb_counters(sfpb_t *dev, sfpb_counters_t *cnt);
```

Założenia: bez dynamicznej alokacji, obsługa DMA w warstwie portu, opcjonalny tryb nieblokujący z callbackami.

---

## 9. Plan uruchomienia (bring-up)

1. Zasilanie, konfiguracja FPGA przez JTAG, LED DONE.
2. `READ_ID` przez SPI (1 linia, 1–5 MHz), potem QSPI i OCTOSPI z rosnącym zegarem.
3. Odczyt EEPROM SFP przez mailbox I2C (vendor, part number) i DDM.
4. Near-end loopback w FPGA (bez optyki): ramki TX → RX, liczniki CRC = 0.
5. **Niska prędkość linii (10–25 Mbaud)** na dwóch modułach połączonych patchcordem: wykres oczkowy na RD±, CDR na 8–10× nadpróbkowaniu w logice.
6. 100 Mbaud z IDES4, test BER (pseudolosowe ramki, liczniki, ≥ 10¹² bitów).
7. Test z tłumikiem optycznym i różnymi modułami (MM, SM, BiDi).
8. Opcjonalnie: 125 Mbaud i wyżej.

---

## 10. Otwarte punkty / do weryfikacji

- [ ] Numery pinów QN48 (UG114): przydział do zatwierdzenia i wpisania do tabeli 3.1.
- [x] Programowalna terminacja 100 Ω: w GW1N-9 wyłącznie bank 0 (UG289, rozdz. 3.3.2).
- [x] HCLK: w GW1N-9C HCLKMUX przenosi HCLK między bankami; PnR testowy umieścił `clk_fast` w `BANK0_BANK1_HCLK0` i `BANK2_BANK3_HCLK0` (UG286, rozdz. 2.2).
- [x] Tryb konfiguracji w QN48: pin 48 = MODE2 + MODE1, MODE0 wewnętrznie do masy; pin 48 ściągnięty do masy daje AUTOBOOT (UG114, UG290 tab. 5-1).
- [x] Zasilanie QN48 (UG114): VCC — piny 12 i 37, VCCX — pin 36, VCCIO0/VCCIO3 — pin 1, VCCIO1/VCCIO2 — pin 25, VSS — piny 2 i 26 oraz EPAD.
- [ ] Minimalna amplituda wejścia TD wybranego modułu SFP względem VOD FPGA (500 mVppd min).
- [ ] Czy wybrany moduł SFP nie ma wewnętrznego CDR (moduły z CDR nie zadziałają przy 100 Mbaud).
- [ ] Generowanie VHDL dla FIFO IP Gowin (jeśli nie — własne `async_fifo`).
- [ ] Timing xSPI przy 50 MHz: setup/hold FPGA vs STM32 OCTOSPI (dummy cycles, opóźnienie próbkowania po stronie MCU).

## 11. Dokumentacja źródłowa

| Dokument | Zawartość |
|---|---|
| DS100 — GW1N series Data Sheet | zasoby, tabela obudów, LVDS DC, gearbox, PLL |
| UG103 — GW1N Package & Pinout | obudowy, opis pinów |
| UG114 — GW1N-9 Pinout | przypisanie pinów QN48, pary true LVDS |
| UG286 — Gowin Clock User Guide | rPLL, CLKDIV, HCLK |
| UG289 — Gowin Programmable IO User Guide | TLVDS, IDES/OSER, terminacja |
| UG290 — Programming & Configuration | tryby konfiguracji, piny dedykowane |
| UG284 — GW1N/GW1NR Schematic Manual | zasilanie, odsprzęganie, piny konfiguracyjne |
| UG285 — BSRAM & SSRAM User Guide | SDPB, FIFO |
| SUG935 — Physical Constraints | składnia .cst |
| SFF-8431 / SFP MSA (INF-8074) | elektryka i zasilanie SFP |
| SFF-8472 | mapa pamięci DDM (A0h/A2h) |
| Xilinx XAPP224 / XAPP523 | odzysk danych z nadpróbkowania |
