# SFP-xSPI Bridge — plan konstrukcji

Moduł mostka **OCTOSPI / QUADSPI / SPI ↔ SFP (światłowód)** do łączenia dwóch mikrokontrolerów (STM32) łączem optycznym punkt–punkt, bez stosu IP. Własny, lekki protokół ramkowy z kodowaniem 8b/10b i programowym odzyskiem zegara (soft-CDR) w małym FPGA Gowin.

| Element | Wybór |
|---|---|
| FPGA | Gowin **GW1N-UV9QN48C6/I5** (GW1N-9, wersja C) — wybór uzasadnia [ADR 0001](adr/0001-fpga-gw1n-9.md) |
| Narzędzia | KiCad (PCB), Gowin EDA (VHDL), biblioteka C dla STM32 |
| Prędkość linii | **100 Mbaud** (8b/10b → 80 Mbit/s → ok. 9 MB/s danych użytecznych) |
| Interfejs hosta | SPI (1-1-1), QSPI (1-1-4 / 1-4-4), OCTOSPI (1-1-8 / 1-8-8), SDR |
| Strona optyczna | moduł SFP (INF-8074i) bez wewnętrznego CDR: 100BASE-FX / OC-3 lub 1000BASE-X (MM/SM, duplex lub BiDi); SFP+ nieobsługiwane |
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
- **True LVDS input** wymaga terminacji 100 Ω. W GW1N-9 wewnętrzna programowalna terminacja 100 Ω jest dostępna **wyłącznie w banku 0** (UG289, rozdz. 3.3.2; atrybut `.cst`: `DIFF_RESISTOR=ON`). Wariantem podstawowym jest terminacja zewnętrzna (5.2, [ADR 0002](adr/0002-terminacja-rx-zewnetrzna.md)); wewnętrzna pozostaje opcją awaryjną.
- Wejście różnicowe (`TLVDS_IBUF`) obsługują wszystkie banki. Wyjście true LVDS (`TLVDS_OBUF`) wyłącznie pary oznaczone w UG114 jako *TRUE*. Prąd wyjścia LVDS25 w GW1N-9: 1,25 / 2 / 2,5 / 3,5 mA (DS100, tab. 2-1).
- Podczas konfiguracji wszystkie GPIO są w stanie wysokiej impedancji ze słabym pull-upem. Uwzględnić w sterowaniu `TX_DISABLE` (pull-up = laser wyłączony, to dobrze).
- **QN48, tryb konfiguracji:** MODE0 jest wewnętrznie zwarty do masy, MODE1 i MODE2 są połączone na pinie 48. Pin 48 w stanie niskim daje `000` = AUTOBOOT, w stanie wysokim `110` = DUAL BOOT (UG290, tab. 5-1). Ze względu na wewnętrzny pull-up pin 48 wymaga **zewnętrznego rezystora do masy**.

---

## 3. Przydział pinów

Numery pinów pochodzą z UG114 (GW1N-9 Pinout, kolumna QN48). Przydział, wszystkie alternatywy z tabeli 3.3 oraz warianty negatywne zostały sprawdzone przebiegiem syntezy i PnR w Gowin EDA 1.9.11.03 (projekt testowy z rPLL, CLKDIV, IDES4, OSER4 i wszystkimi 26 portami). Plik ograniczeń: [`vhdl/constraints/sfp_bridge.cst`](../vhdl/constraints/sfp_bridge.cst).

Bilans: 41 wyprowadzeń I/O w QN48, z czego 8 to piny konfiguracyjne (3–9, 48), 26 jest przydzielonych, 7 pozostaje w zapasie.

Rozkład na obudowie (numeracja przeciwnie do ruchu wskazówek zegara od lewego górnego narożnika): lewa krawędź 1–12, dolna 13–24, prawa 25–36, górna 37–48. Wynikający z tego układ płytki: **złącze hosta przy dolnej krawędzi, klatka SFP przy prawym górnym narożniku, JTAG przy lewej krawędzi**.

```
                   48   47  46  45  44  43  42  41  40  39  38  37
                  MODE SDA SCL  -   -  RDP RDN ABS LOS FLT DIS VCC
     VCCIO0/3  1                                                    36  VCCX
          VSS  2                                                    35  CLK_25M
    JTAGSEL_N  3                                                    34  TD_P
          TMS  4                                                    33  TD_N
          TCK  5                                                    32  LED_ACT
          TDI  6                    GW1N-UV9QN48                    31  LED_LINK
          TDO  7                                                    30  -
   RECONFIG_N  8                                                    29  -
         DONE  9                                                    28  -
            - 10                                                    27  -
   HOST_RST_N 11                                                    26  VSS
          VCC 12                                                    25  VCCIO1/2
                  IRQ  CS  IO0 IO1 IO2 IO3 SCLK DQS IO4 IO5 IO6 IO7
                   13   14  15  16  17  18  19  20  21  22  23  24
```

### 3.1 Tabela sygnałów

Nazwy sieci w schemacie pisane są wielkimi literami, porty VHDL małymi (`SFP_TD_P` ↔ `sfp_td_p`).

| Sygnał | Kier. | Standard I/O | Pin | Bank | Miejsce w UG114 | Uwagi |
|---|---|---|---|---|---|---|
| `SFP_TD_P` | out | LVDS25, DRIVE=3.5 | **34** | 1 | IOR11A (MI/D7) | para z wyjściem true LVDS; funkcja MSPI nieużywana w AUTOBOOT |
| `SFP_TD_N` | out | LVDS25 | **33** | 1 | IOR11B (MO/D6) | |
| `SFP_RD_P` | in | LVDS25 | **43** | 0 | IOT32A | IDES4; terminacja zewnętrzna (5.2), wewnętrzna jako opcja awaryjna |
| `SFP_RD_N` | in | LVDS25 | **42** | 0 | IOT32B | |
| `CLK_25M` | in | LVCMOS33 | **35** | 1 | IOR5A (RPLL_T_in) | dedykowane wejście prawego PLL |
| `XSPI_SCLK` | in | LVCMOS33 | **19** | 2 | IOB29A (GCLKT_4) | wejście zegara globalnego, środek magistrali |
| `XSPI_CS_N` | in | LVCMOS33, pull-up | **14** | 2 | IOB8B | |
| `XSPI_IO0` | inout | LVCMOS33 | **15** | 2 | IOB17A | |
| `XSPI_IO1` | inout | LVCMOS33 | **16** | 2 | IOB17B | |
| `XSPI_IO2` | inout | LVCMOS33 | **17** | 2 | IOB27A | |
| `XSPI_IO3` | inout | LVCMOS33 | **18** | 2 | IOB27B | |
| `XSPI_DQS` | out | LVCMOS33 | **20** | 2 | IOB29B (GCLKC_4) | GCLKC nie jest wejściem zegara przy SCLK single-ended |
| `XSPI_IO4` | inout | LVCMOS33 | **21** | 2 | IOB35A | |
| `XSPI_IO5` | inout | LVCMOS33 | **22** | 2 | IOB35B | |
| `XSPI_IO6` | inout | LVCMOS33 | **23** | 2 | IOB39A | |
| `XSPI_IO7` | inout | LVCMOS33 | **24** | 2 | IOB39B | |
| `HOST_IRQ_N` | out | LVCMOS33 | **13** | 2 | IOB8A | open-drain lub push-pull |
| `HOST_RST_N` | in | LVCMOS33, pull-up | **11** | 3 | IOL15B (GCLKC_6) | reset logiki, nie rekonfiguracja |
| `SFP_TX_DIS` | out | LVCMOS33 | **38** | 1 | IOT42B | zewnętrzny pull-up 4,7 kΩ (laser wyłączony domyślnie) |
| `SFP_TX_FAULT` | in | LVCMOS33 | **39** | 1 | IOT42A | pull-up 4,7–10 kΩ |
| `SFP_LOS` | in | LVCMOS33 | **40** | 1 | IOT37B | pull-up 4,7–10 kΩ |
| `SFP_MOD_ABS` | in | LVCMOS33 | **41** | 1 | IOT37A | MOD_DEF0; pull-up 4,7–10 kΩ |
| `SFP_SCL` | inout (OD) | LVCMOS33, OPEN_DRAIN | **46** | 3 | IOT12B | MOD_DEF1; pull-up 4,7 kΩ |
| `SFP_SDA` | inout (OD) | LVCMOS33, OPEN_DRAIN | **47** | 3 | IOT12A | MOD_DEF2; pull-up 4,7 kΩ |
| `LED_LINK` | out | LVCMOS33 | **31** | 1 | IOR12B (MCLK/D4) | |
| `LED_ACT` | out | LVCMOS33 | **32** | 1 | IOR12A (MCS_N/D5) | |

Piny zapasowe: **10** (GCLKT_6), **27/28** (IOR24, para z wyjściem true LVDS), **29/30** (IOR17, para z wyjściem true LVDS, GCLKT_3), **44/45** (IOT22, bank 0, para z opcją terminacji wewnętrznej). Zaleca się wyprowadzenie ich na pola testowe lub złącze rozszerzeń.

Piny konfiguracyjne i zasilania, **nieużywane jako GPIO**:

| Pin | Sygnał | Połączenie |
|---|---|---|
| 3 | `JTAGSEL_N` (także LPLL_T_in) | pull-up 4,7–10 kΩ; AUX programatora przez JP2 (5.6); opcja „Use JTAG as regular IO” wyłączona |
| 4, 5, 6, 7 | `TMS`, `TCK`, `TDI`, `TDO` | złącze TC2050 (5.6); TCK z pull-downem 4,7 kΩ (UG290, tab. 7-3) |
| 8 | `RECONFIG_N` | pull-up 10 kΩ; nRESET programatora przez JP1, domyślnie rozwartą (5.6) |
| 9 | `DONE` | pull-up 4,7–10 kΩ, LED; opcjonalnie AUX programatora przez JP2; `READY` nie jest wyprowadzony w QN48 |
| 48 | `MODE2` + `MODE1` (MODE0 wewnętrznie do masy) | **1 kΩ do masy** (UG290, Figure 7-1) → `000` = AUTOBOOT. Wewnętrzny pull-up do 150 µA (DS100, IPU): 10 kΩ dałoby do 1,5 V, czyli ryzyko odczytu stanu wysokiego i DUAL BOOT |
| 12, 37 | `VCC` | 3,3 V (wersja UV, wewnętrzny stabilizator rdzenia) |
| 36 | `VCCX` | 3,3 V |
| 1 | `VCCIO0` / `VCCIO3` | 3,3 V |
| 25 | `VCCIO1` / `VCCIO2` | 3,3 V |
| 2, 26, EPAD | `VSS` | masa; EPAD obowiązkowo do masy |

### 3.2 Reguły przydziału

1. **Wszystkie banki VCCIO = 3,3 V.** LVDS25 (TLVDS) działa przy VCCIO 2,5/3,3 V jako wejście i wyjście (DS100, tab. 2-1, 2-2).
2. **TD wyłącznie na parze z wyjściem true LVDS** (kolumna „LVDS” = TRUE w UG114). Umieszczenie `TLVDS_OBUF` na parze bez tej cechy (np. 45/44, 39/38) kończy się błędem CT1005.
3. **RD na dowolnej parze różnicowej** — wejście `TLVDS_IBUF` obsługują wszystkie banki. Atrybut `DIFF_RESISTOR` jest akceptowany wyłącznie w banku 0 (poza nim błąd CT1118, także przy wartości `OFF`); po przeniesieniu RD poza bank 0 atrybut należy usunąć.
4. **IDES4/OSER4:** HCLK z PLL obejmuje wszystkie banki (PnR: `BANK0_BANK1_HCLK0`, `BANK2_BANK3_HCLK0`); w GW1N-9 nie ma pinów bez IO logic.
5. **`XSPI_SCLK` na pinie GCLKT.** Przy 25–50 MHz SCLK nie da się go nadpróbkować zegarem 100 MHz. Pin GCLKC tej samej pary pozostaje zwykłym I/O.
6. **Magistrala xSPI w jednym banku** (bank 2, dolna krawędź) z krótkimi i równymi ścieżkami.
7. **`CLK_25M` na dedykowanym wejściu PLL.** Wejście przez sieć globalną (pin GCLKT) działa, ale dodaje jitter na wejściu PLL.
8. **Piny MSPI (31–34)** pracują jako GPIO dzięki opcji `-use_mspi_as_gpio 1`; wymaga to trybu AUTOBOOT (pin 48 do masy).

### 3.3 Alternatywy przydziału

Warianty na wypadek trudności w schemacie lub prowadzeniu ścieżek. Wariant oznaczony „PnR OK” przeszedł syntezę, PnR i generację bitstreamu przy pozostałych pinach bez zmian, o ile w kolumnie warunków nie podano inaczej.

| Sygnał | Podstawowy | Alternatywa | Warunki / koszt | Weryfikacja |
|---|---|---|---|---|
| `SFP_TD_P/N` | 34/33 | **28/27** (IOR24) | prawa krawędź niżej, dalej od SFP | PnR OK |
| | | **30/29** (IOR17) | zajmuje GCLKT_3 | PnR OK |
| | | **11/10** (IOL15) | lewa krawędź; `HOST_RST_N` → np. 28; zajmuje GCLKT_6 | PnR OK |
| | | 13–24 (bank 2) | pary TRUE, ale kolidują z magistralą xSPI | nie zalecane |
| `SFP_RD_P/N` | 43/42 | **45/44** (IOT22, bank 0) | zachowuje opcję terminacji wewnętrznej | PnR OK (z `DIFF_RESISTOR=ON`) |
| | | **39/38** (IOT42, bank 1) | najbliżej narożnika SFP; tylko terminacja zewnętrzna; `SFP_TX_DIS`/`SFP_TX_FAULT` → 44/45 | PnR OK |
| | | **41/40** (IOT37, bank 1) | tylko terminacja zewnętrzna; `SFP_LOS`/`SFP_MOD_ABS` → 44/45 | PnR OK |
| | | **28/27**, **30/29** (bank 1) | tylko terminacja zewnętrzna | PnR OK |
| `CLK_25M` | 35 | **30** (GCLKT_3) lub **10** (GCLKT_6) | wejście PLL przez sieć globalną, większy jitter | PnR OK (30) |
| | | 3 (LPLL_T_in) | koliduje z `JTAGSEL_N` | nie zalecane |
| `XSPI_SCLK` | 19 | **10** (GCLKT_6) lub **30** (GCLKT_3) | 19 staje się zwykłym I/O banku 2 | PnR OK (oba) |
| `XSPI_IO0..7`, `XSPI_CS_N`, `XSPI_DQS`, `HOST_IRQ_N` | 13–18, 20–24 | **dowolna permutacja** w obrębie 13–24 (poza pinem SCLK) | kolejność bitów ustala `.cst`; logika bez zmian | — |
| Wolne sygnały SFP, LED, `HOST_RST_N` | jak w 3.1 | dowolny pin zapasowy: 10, 27–30, 44, 45 | `OPEN_DRAIN=ON` dla SCL/SDA działa na każdym pinie | — |

Jako alternatyw **nie** wolno użyć pinów 3–9 i 48 (konfiguracja) ani 1, 2, 12, 25, 26, 36, 37 (zasilanie).

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

Moduł i złącze zgodne z SFP MSA (INF-8074i). SFF-8431 opisuje elektrykę SFP+ (10 Gb/s) i nie jest podstawą tego projektu. Klatka i złącze 20-pinowe są wspólne dla SFP i SFP+.

**Klasa modułów.** Obsługiwane są moduły SFP bez wewnętrznego CDR: 100BASE-FX / OC-3 (125–155 Mb/s, zakres zgodny z linią 100–125 Mbaud) oraz 1000BASE-X (1,25 Gb/s). Moduły SFP+ (10G) nie są obsługiwane: zwykle zawierają CDR zablokowany na ok. 10 Gbaud i nie są specyfikowane dla 100 Mbaud.

Przyporządkowanie pinów złącza (INF-8074i, Table 1; numeracja zgodna z symbolem `Connector_SFP_and_Cage`):

| Pin SFP | Nazwa (INF-8074i) | Sieć / FPGA | Połączenie |
|---|---|---|---|
| 1, 17, 20 | VeeT | GND | masa nadajnika |
| 2 | TX Fault | `SFP_TX_FAULT` → pin 39 | wyjście OC/OD modułu; pull-up 4,7–10 kΩ do 3,3 V |
| 3 | TX Disable | `SFP_TX_DIS` ← pin 38 | wejście modułu z wewnętrznym pull-upem 4,7–10 kΩ (stan wysoki lub rozwarty = laser wyłączony); dodatkowy pull-up 4,7 kΩ na płytce |
| 4 | MOD-DEF2 | `SFP_SDA` ↔ pin 47 | SDA interfejsu 2-wire (EEPROM A0h, DDM A2h); pull-up 4,7–10 kΩ |
| 5 | MOD-DEF1 | `SFP_SCL` ← pin 46 | SCL, maks. 100 kHz; pull-up 4,7–10 kΩ |
| 6 | MOD-DEF0 | `SFP_MOD_ABS` → pin 41 | zwarte do masy w module = moduł obecny; pull-up 4,7–10 kΩ |
| 7 | Rate Select | — | **jeden pin**; opcjonalne wejście modułu z wewnętrznym pull-downem > 30 kΩ (niski lub rozwarty = pasmo zmniejszone, wysoki = pełne); 10 kΩ do masy. W SFP+ ten pin nazywa się RS0 |
| 8 | LOS | `SFP_LOS` → pin 40 | wyjście OC/OD modułu; pull-up 4,7–10 kΩ |
| 9, 10, 11, 14 | VeeR | GND | masa odbiornika. W SFP+ pin 9 to wejście RS1 — połączenie z masą jest dla modułu SFP+ stanem niskim, więc pozostaje poprawne |
| 12 | RD− | → `SFP_RD_N` (pin 42) | połączenie bezpośrednie; terminacja i bias przy FPGA (5.2) |
| 13 | RD+ | → `SFP_RD_P` (pin 43) | jw. |
| 15 | VccR | 3,3 V przez filtr | filtr odbiornika (poniżej) |
| 16 | VccT | 3,3 V przez filtr | filtr nadajnika (poniżej) |
| 18 | TD+ | ← `SFP_TD_P` (pin 34) | połączenie bezpośrednie |
| 19 | TD− | ← `SFP_TD_N` (pin 33) | jw. |
| — | klatka (cage) | masa obudowy | zgodnie z wytycznymi producenta klatki |

Napięcia pull-upów sygnałów sterujących: 2,0 V … VccT/VccR + 0,3 V; przy zasilaniu 3,3 V pull-upy do szyny 3,3 V spełniają wymaganie.

**Sprzężenie AC.** Sprzężenie AC jest realizowane wewnątrz modułu na TD± i RD±, a kondensatory na płytce hosta nie są wymagane (INF-8074i, Table 1, uwagi 7 i 9). Pary TD i RD łączą się z FPGA bezpośrednio. Ponieważ wyjście RD± modułu jest odcięte stałoprądowo, napięcie wspólne po stronie FPGA ustala dzielnik Vbias (5.2); bez niego wejście LVDS nie ma określonego punktu pracy. Wyjście TD FPGA (VOS ok. 1,2 V) podaje się wprost na wewnętrzne kondensatory modułu.

**Filtr zasilania** (INF-8074i, Figure 2A):

```
                  ┌──[1 µH]──┬──────────── VccT (16)
                  │        0,1 µF
3,3 V ──┬──────┬──┤
      10 µF  0,1 µF
                  └──[1 µH]──┬───────┬──── VccR (15)
                           0,1 µF  10 µF
```

- Dławiki 1 µH, DCR < 1 Ω (spadek napięcia przy 300 mA), prąd znamionowy ≥ 0,5 A.
- Kondensatory 0,1 µF przy pinach VccT i VccR; 10 µF na gałęzi VccR; 10 µF + 0,1 µF po stronie szyny 3,3 V.
- Przy tym filtrze prąd udarowy przy wpięciu modułu na gorąco nie przekracza prądu ustalonego o więcej niż 30 mA. Maksymalny prąd modułu: 300 mA.

**Poziomy sygnałów:**

- TX: GW1N-9 daje VOD 250–450 mV, czyli **500–900 mVppd**. Wejście TD± modułu przyjmuje 500–2400 mVppd, zalecane 500–1200 mVppd (INF-8074i, uwaga 9). Margines przy dolnej granicy jest minimalny, dlatego obowiązuje **DRIVE=3.5** (maksymalny prąd wyjścia LVDS25). Wymaganie minimalnej amplitudy wybranego modułu **[DO WERYFIKACJI]** w jego datasheecie.
- RX: wyjście RD± modułu 370–2000 mVppd przy terminacji 100 Ω (INF-8074i, uwaga 7). VTHD FPGA ±100 mV daje duży zapas. Bias ok. 1,2 V mieści się w VCM 0,05–2,1 V.

### 5.2 Terminacja i bias toru RX

Wariant podstawowy: **terminacja zewnętrzna** ([ADR 0002](adr/0002-terminacja-rx-zewnetrzna.md)).

```
RD+ (SFP 13) ───┬──────────────── FPGA RD_P (pin 43)
              49,9 Ω 1% 0402
                ├── Vbias 1,2 V (dzielnik z 3,3 V: np. 2,1 kΩ / 1,2 kΩ + 100 nF do masy)
              49,9 Ω 1% 0402
RD− (SFP 12) ───┴──────────────── FPGA RD_N (pin 42)
```

- Rezystory 49,9 Ω umieszcza się bezpośrednio przy pinach 42/43 (odcinek do odbiornika ≤ 2 mm). Kondensator 100 nF w węźle środkowym zwiera do masy zakłócenia wspólne.
- Wariant awaryjny: rezystory 49,9 Ω niemontowane, w `.cst` `DIFF_RESISTOR=ON` (tylko bank 0), bias przez 2 × 10 kΩ z każdej linii do Vbias. Footprinty 10 kΩ przewiduje się jako DNP.
- Obie terminacje jednocześnie dają ok. 50 Ω i są niedopuszczalne; domyślnie `DIFF_RESISTOR=OFF`.

### 5.3 Reguły layoutu (100 Mbaud, zbocza SFP ok. 100–200 ps)

| Reguła | Wartość |
|---|---|
| Impedancja par TD/RD | 100 Ω różnicowo, ciągła płaszczyzna odniesienia |
| Dopasowanie w parze | ≤ 0,5 mm |
| Przelotki w parze | minimum, symetrycznie |
| Sprzężenie AC | brak kondensatorów na płytce — sprzężenie AC wewnątrz modułu (INF-8074i) |
| xSPI | wspólna długość ±5 mm, rezystory szeregowe 22–33 Ω przy źródle (MCU dla CLK/CS, przy FPGA dla IO w kierunku odczytu — footprinty z obu stron) |
| Stack-up | min. 4 warstwy (sygnał / GND / 3V3 / sygnał) |

### 5.4 Zasilanie

| Odbiornik | Prąd (szac.) |
|---|---|
| Moduł SFP | do 300 mA (INF-8074i) |
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

### 5.6 Złącze programowania (Tag-Connect TC2050)

Footprint `Tag-Connect_TC2050-IDC-NL_2x05_P1.27mm_Vertical` (J2). Układ zgodny ze złączem ARM Cortex Debug 10-pin, z wykorzystaniem pinu 7 (w standardzie Cortex: klucz, niepodłączony) na sygnał AUX programatora.

| Pin TC2050 | Sygnał | Połączenie w FPGA |
|---|---|---|
| 1 | 3V3 (VTref) | szyna 3,3 V |
| 2 | TMS | pin 4 |
| 3 | GND | |
| 4 | TCK | pin 5; pull-down 4,7 kΩ (UG290, tab. 7-3, uwaga 2) |
| 5 | GND | |
| 6 | TDO | pin 7 |
| 7 | AUX | przez 1 kΩ (R7) na zworkę trójpozycyjną JP2: `JTAGSEL_N` (pin 3) lub `DONE` (pin 9) |
| 8 | TDI | pin 6 |
| 9 | GND (GNDDetect) | |
| 10 | nRESET | przez zworkę JP1 (domyślnie rozwartą) na `RECONFIG_N` (pin 8) |

- **nRESET → `RECONFIG_N`** przeładowuje konfigurację z Flash. `RECONFIG_N` nie może przyjąć stanu niskiego w czasie programowania Flash ani ładowania AUTOBOOT (UG290, rozdz. 7 — ryzyko trwałego uszkodzenia Flash), dlatego połączenie jest domyślnie rozwarte (JP1) i zamykane tylko dla programatora sterującego resetem wyłącznie na żądanie.
- **AUX → `JTAGSEL_N`** przywraca funkcję JTAG pinów 4–7, gdyby bitstream przełączył je na GPIO (działa przy MODE ≠ `001`). **AUX → `DONE`** pozwala programatorowi odczytać stan konfiguracji. Rezystor 1 kΩ chroni oba układy przy różnych stanach zasilania.
- Do samego programowania (SRAM i Flash) wystarczają TCK, TMS, TDI, TDO; przeładowanie po zapisie Flash odbywa się instrukcją JTAG.
- Poziomy logiczne programatora: 3,3 V (bank 3, VCCIO3 = 3,3 V).


### 5.7 Lista elementów (BOM, główne pozycje)

| Pozycja | Uwagi |
|---|---|
| GW1N-UV9QN48C6/I5 | Mouser (jedyne źródło, stan 2026-10-08: ok. 90 szt.) |
| Klatka SFP + złącze 20-pin | press-fit lub SMT |
| Generator 25 MHz, ±25 ppm, CMOS 3,3 V | |
| Dławiki 1 µH × 2 (filtr INF-8074i, Figure 2A) | DCR < 1 Ω, ≥ 0,5 A |
| Rezystory, kondensatory 0402 | pull-upy, bias, terminacja |
| Złącze hosta 2 × 10 / 1,27 mm | |
| Tag-Connect TC2050-IDC-NL (footprint, bez elementu) | kabel TC2050 po stronie programatora |
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
| Constraints (.cst) | IO_TYPE: `LVDS25` dla par TD/RD, `LVCMOS33` dla reszty; DRIVE=3.5 dla TD; DIFF_RESISTOR=OFF dla RD (terminacja zewnętrzna); PULL_MODE=UP dla CS_N, RST_N; OPEN_DRAIN=ON dla SCL/SDA |
| Timing (.sdc) | `create_clock` 25 MHz (`CLK_25M`), 50 MHz (`XSPI_SCLK`); clock groups asynchroniczne między `clk_spi` a `clk_sys`; set_input/output_delay dla xSPI wg timingu STM32 |

Ograniczenia: [`vhdl/constraints/sfp_bridge.cst`](../vhdl/constraints/sfp_bridge.cst) (piny, standardy I/O) i [`vhdl/constraints/sfp_bridge.sdc`](../vhdl/constraints/sfp_bridge.sdc) (zegary).

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

- [x] Numery pinów QN48 (UG114): przydział w tabeli 3.1, alternatywy w 3.3, sprawdzone w PnR.
- [x] Programowalna terminacja 100 Ω: w GW1N-9 wyłącznie bank 0 (UG289, rozdz. 3.3.2).
- [x] HCLK: w GW1N-9C HCLKMUX przenosi HCLK między bankami; PnR testowy umieścił `clk_fast` w `BANK0_BANK1_HCLK0` i `BANK2_BANK3_HCLK0` (UG286, rozdz. 2.2).
- [x] Tryb konfiguracji w QN48: pin 48 = MODE2 + MODE1, MODE0 wewnętrznie do masy; pin 48 ściągnięty do masy daje AUTOBOOT (UG114, UG290 tab. 5-1).
- [x] Zasilanie QN48 (UG114): VCC — piny 12 i 37, VCCX — pin 36, VCCIO0/VCCIO3 — pin 1, VCCIO1/VCCIO2 — pin 25, VSS — piny 2 i 26 oraz EPAD.
- [ ] Minimalna amplituda wejścia TD wybranego modułu SFP względem VOD FPGA (INF-8074i: 500 mVppd min).
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
| INF-8074i — SFP MSA | pinout złącza, sygnały sterujące, poziomy TD/RD, filtr zasilania ([`datasheets/INF-8074i.pdf`](datasheets/INF-8074i.pdf)) |
| SFF-8472 | mapa pamięci DDM (A0h/A2h) |
| Xilinx XAPP224 / XAPP523 | odzysk danych z nadpróbkowania |
