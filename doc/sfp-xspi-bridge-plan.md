# SFP-xSPI Bridge — koncepcja konstrukcji

Moduł mostka **OCTOSPI / QUADSPI / SPI ↔ SFP (światłowód)** do łączenia dwóch mikrokontrolerów (STM32) łączem optycznym punkt–punkt, bez stosu IP. Własny, lekki protokół ramkowy z kodowaniem 8b/10b i programowym odzyskiem zegara (soft-CDR) w małym FPGA Gowin. Tryb przezroczysty UART pozwala użyć mostka bez hosta SPI.

| Element | Wybór |
|---|---|
| FPGA | Gowin **GW1N-UV9QN48C6/I5** (GW1N-9, wersja C) — wybór uzasadnia [ADR 0001](adr/0001-fpga-gw1n-9.md) |
| Narzędzia | KiCad 10 (PCB), Gowin EDA (VHDL-2008), GHDL + GTKWave (symulacja, [ADR 0003](adr/0003-weryfikacja-ghdl.md)), C11 (biblioteka STM32) |
| Prędkość linii | **100 Mbaud** (8b/10b → 80 Mbit/s → ok. 9 MB/s danych użytecznych) |
| Interfejs hosta | SPI (1-x-1), QSPI (1-0-4), OCTOSPI (1-0-8), SDR, tryb 0, SCLK ≤ 40 MHz ([ADR 0009](adr/0009-interfejs-hosta.md)) — albo tryb przezroczysty UART ([ADR 0006](adr/0006-tryb-uart-przezroczysty.md)) |
| Protokół łącza | ramki z CRC-32 bez retransmisji, gotowość odbiornika i XON/XOFF w sekwencji bezczynności ([ADR 0005](adr/0005-protokol-lacza.md), [ADR 0008](adr/0008-stan-lacza.md)) |
| Zegar logiki | `clk_sys` = 50 MHz, serializery IDES8/OSER8 przy 200 MHz ([ADR 0007](adr/0007-zegar-systemowy-50mhz.md)) |
| Strona optyczna | moduł SFP (INF-8074i) bez wewnętrznego CDR: 100BASE-FX / OC-3 lub 1000BASE-X (MM/SM, duplex lub BiDi); SFP+ nieobsługiwane |
| Zasilanie | jedno **3,3 V** (wersja UV FPGA, moduł SFP) |

Dokument opisuje przyjęte rozwiązania konstrukcyjne: architekturę, przydział pinów, zegary, warstwę fizyczną i płytkę, projekt FPGA, interfejs hosta, bibliotekę STM32 oraz plan uruchomienia. Uzasadnienia decyzji zawiera [rejestr ADR](adr/README.md), szczegóły programowania — [datasheet interfejsu hosta](datasheet/index.md). Pozycje oznaczone **[DO WERYFIKACJI]** wymagają potwierdzenia na prototypie lub w dokumentacji wybranych elementów (rozdział 10).

---

## 1. Architektura

```
            OCTOSPI/QSPI/SPI                       LVDS 100 Mbaud
  STM32  <=====================>  GW1N-9    <=====================>  SFP  ~~~ światłowód ~~~  SFP <=> GW1N <=> STM32
  (master)   CLK, CS, IO0..7,      (FPGA)     TD±  -> moduł SFP
             DQS, IRQ, RST                   RD±  <- moduł SFP
                                   I2C master ---> SFP EEPROM/DDM (0x50/0x51)
                                   GPIO ---------> TX_DISABLE, TX_FAULT, LOS, MOD_ABS

  tryb UART (zworka MODE_SEL):  urządzenie UART <== RX/TX (IO0/IO1), opcj. RTS/CTS ==> GW1N-9 <== LVDS ==> ...
```

Wewnątrz FPGA:

```
 xSPI slave ─> rejestry/CSR ─┬─> TX FIFO ─> framer ─> CRC32 ─> enc 8b/10b ─> serializer ─> TLVDS_OBUF ─> SFP TD±
  (domena SCLK)              │
                             ├─< RX FIFO <─ deframer <─ CRC check <─ dec 8b/10b <─ comma align <─ soft-CDR <─ IDES8 <─ TLVDS_IBUF <─ SFP RD±
                             │
                             ├─> I2C master + mailbox + autopolling DDM ─> SFP SCL/SDA
                             └─> GPIO SFP, LED, IRQ

 tryb UART: uart_rx ─> pakietyzator (ramki TYPE 0x01) ─> TX FIFO ;  RX FIFO ─> depakietyzator ─> uart_tx
```

Domeny zegarowe:

| Domena | Źródło | Częstotliwość | Co pracuje |
|---|---|---|---|
| `clk_spi` / `clk_host` | pin SCLK od MCU (przez `DCS`; w trybach UART i echa `clk_sys`) | ≤ 40 MHz | slave xSPI, strona hosta FIFO |
| `clk_fast` | PLL | 200 MHz | FCLK serializerów IDES8 / OSER8 |
| `clk_sys` | CLKDIV(/4) z `clk_fast` | 50 MHz | całe łącze: CDR, 8b/10b, framer, CRC, FIFO (strona łącza), I2C, UART, CSR — [ADR 0007](adr/0007-zegar-systemowy-50mhz.md) |

Przejścia między domenami: asynchroniczne FIFO (BSRAM w trybie semi-dual port; wskaźnik odczytu w kodzie Graya, zatwierdzony wskaźnik zapisu przez handshake — [`async_fifo`](vhdl/async_fifo.md)) oraz synchronizatory 2-FF dla pojedynczych bitów ([`sync_bit`](vhdl/sync.md)). Reset: [ADR 0004](adr/0004-strategia-resetu.md).

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
| IDES4, max szybkość szeregowa (C6/I5) | 750 Mbps | 750 Mbps | |
| IDES8/10, max (C6/I5) | 1000 Mbps | 1000 Mbps | IDES8/OSER8 pracują przy 400 Msps |
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

Numery pinów pochodzą z UG114 (GW1N-9 Pinout, kolumna QN48). Przydział, wszystkie alternatywy z tabeli 3.3 oraz warianty negatywne są sprawdzone syntezą i PnR w Gowin EDA 1.9.11.03 (projekt próbny z rPLL, CLKDIV, serializerami i kompletem portów). Plik ograniczeń: `vhdl/constraints/sfp_bridge.cst`.

Bilans: 41 wyprowadzeń I/O w QN48, z czego 8 to piny konfiguracyjne (3–9, 48), 27 jest przydzielonych (w tym `MODE_SEL`, [ADR 0006](adr/0006-tryb-uart-przezroczysty.md)), 6 pozostaje w zapasie.

Rozkład na obudowie (numeracja przeciwnie do ruchu wskazówek zegara od lewego górnego narożnika): lewa krawędź 1–12, dolna 13–24, prawa 25–36, górna 37–48. Wynikający z tego układ płytki: **złącze hosta przy dolnej krawędzi, klatka SFP przy prawym górnym narożniku, JTAG przy lewej krawędzi**.

```
                   48   47  46  45  44  43  42  41  40  39  38  37
                  MODE SDA SCL  -   -  RDN RDP ABS LOS FLT DIS VCC
     VCCIO0/3  1                                                    36  VCCX
          VSS  2                                                    35  CLK_25M
    JTAGSEL_N  3                                                    34  TD_P
          TMS  4                                                    33  TD_N
          TCK  5                                                    32  LED_ACT
          TDI  6                    GW1N-UV9QN48                    31  LED_LINK
          TDO  7                                                    30  -
   RECONFIG_N  8                                                    29  -
         DONE  9                                                    28  -
     MODE_SEL 10                                                    27  -
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
| `SFP_RD_P` | in | LVDS25 | **42** | 0 | IOT32B | IDES8; terminacja zewnętrzna (5.2), wewnętrzna jako opcja awaryjna; **polaryzacja odwrócona** (3.2, reguła 9) |
| `SFP_RD_N` | in | LVDS25 | **43** | 0 | IOT32A | wejście `I` bufora `TLVDS_IBUF` |
| `CLK_25M` | in | LVCMOS33 | **35** | 1 | IOR5A (RPLL_T_in) | dedykowane wejście prawego PLL |
| `XSPI_SCLK` | in | LVCMOS33 | **19** | 2 | IOB29A (GCLKT_4) | wejście zegara globalnego, środek magistrali; ≤ 40 MHz ([ADR 0009](adr/0009-interfejs-hosta.md)) |
| `XSPI_CS_N` | in | LVCMOS33, pull-up | **14** | 2 | IOB8B | |
| `XSPI_IO0` | inout | LVCMOS33 | **15** | 2 | IOB17A | |
| `XSPI_IO1` | inout | LVCMOS33 | **16** | 2 | IOB17B | |
| `XSPI_IO2` | inout | LVCMOS33 | **17** | 2 | IOB27A | |
| `XSPI_IO3` | inout | LVCMOS33 | **18** | 2 | IOB27B | |
| `XSPI_DQS` | out | LVCMOS33 | **20** | 2 | IOB29B (GCLKC_4) | nieużywany (SDR), stan wysokiej impedancji; rezerwa na tryb DTR |
| `XSPI_IO4` | inout | LVCMOS33 | **21** | 2 | IOB35A | |
| `XSPI_IO5` | inout | LVCMOS33 | **22** | 2 | IOB35B | |
| `XSPI_IO6` | inout | LVCMOS33 | **23** | 2 | IOB39A | |
| `XSPI_IO7` | inout | LVCMOS33 | **24** | 2 | IOB39B | |
| `HOST_IRQ_N` | out | LVCMOS33 | **13** | 2 | IOB8A | open-drain lub push-pull |
| `HOST_RST_N` | in | LVCMOS33, pull-up | **11** | 3 | IOL15B (GCLKC_6) | reset logiki, nie rekonfiguracja |
| `SFP_TX_DIS` | out | LVCMOS33 | **38** | 1 | IOT42B | pull-up wewnątrz modułu (laser wyłączony, dopóki FPGA nie wystawi 0) |
| `SFP_TX_FAULT` | in | LVCMOS33, PULL_MODE=UP | **39** | 1 | IOT42A | brak zewnętrznego pull-upu (rev. A) — wewnętrzny pull-up FPGA |
| `SFP_LOS` | in | LVCMOS33, PULL_MODE=UP | **40** | 1 | IOT37B | jw. |
| `SFP_MOD_ABS` | in | LVCMOS33, PULL_MODE=UP | **41** | 1 | IOT37A | MOD_DEF0; jw. |
| `SFP_SCL` | inout (OD) | LVCMOS33, OPEN_DRAIN | **46** | 3 | IOT12B | MOD_DEF1; pull-up 4,7 kΩ |
| `SFP_SDA` | inout (OD) | LVCMOS33, OPEN_DRAIN | **47** | 3 | IOT12A | MOD_DEF2; pull-up 4,7 kΩ |
| `MODE_SEL` | in | LVCMOS33, PULL_MODE=UP | **10** | 3 | IOL15A (GCLKT_6) | wybór trybu ([ADR 0006](adr/0006-tryb-uart-przezroczysty.md)): otwarta zworka = xSPI, zwarta do masy = UART; pull-up 10 kΩ |
| `LED_LINK` | out | LVCMOS33 | **31** | 1 | IOR12B (MCLK/D4) | aktywny stanem niskim (3V3 → 1 kΩ → LED → pin) |
| `LED_ACT` | out | LVCMOS33 | **32** | 1 | IOR12A (MCS_N/D5) | aktywny stanem niskim |

Piny zapasowe: **27/28** (IOR24, para z wyjściem true LVDS), **29/30** (IOR17, para z wyjściem true LVDS, GCLKT_3), **44/45** (IOT22, bank 0, para z opcją terminacji wewnętrznej); w rev. A niepodłączone (znaczniki no-connect).

Piny konfiguracyjne i zasilania, **nieużywane jako GPIO**:

| Pin | Sygnał | Połączenie |
|---|---|---|
| 3 | `JTAGSEL_N` (także LPLL_T_in) | pull-up 4,7–10 kΩ; AUX programatora przez JP2 (5.6); opcja „Use JTAG as regular IO” wyłączona |
| 4, 5, 6, 7 | `TMS`, `TCK`, `TDI`, `TDO` | złącze TC2050 (5.6); TCK z pull-downem 4,7 kΩ (UG290, tab. 7-3) |
| 8 | `RECONFIG_N` | pull-up 10 kΩ; nRESET programatora przez JP1, domyślnie rozwartą (5.6) |
| 9 | `DONE` | pull-up 10 kΩ (R6); opcjonalnie AUX programatora przez JP2; bez diody LED; `READY` nie jest wyprowadzony w QN48 |
| 48 | `MODE2` + `MODE1` (MODE0 wewnętrznie do masy) | **1 kΩ do masy** (UG290, Figure 7-1) → `000` = AUTOBOOT. Wewnętrzny pull-up do 150 µA (DS100, IPU): 10 kΩ dałoby do 1,5 V, czyli ryzyko odczytu stanu wysokiego i DUAL BOOT |
| 12, 37 | `VCC` | 3,3 V (wersja UV, wewnętrzny stabilizator rdzenia) |
| 36 | `VCCX` | 3,3 V |
| 1 | `VCCIO0` / `VCCIO3` | 3,3 V |
| 25 | `VCCIO1` / `VCCIO2` | 3,3 V |
| 2, 26, EPAD (49) | `VSS` | masa; **EPAD obowiązkowo do masy** — symbol nie ma pinu EPAD, połączenie wykonuje się ręcznie w PCB (5.3.5) |

### 3.2 Reguły przydziału

1. **Wszystkie banki VCCIO = 3,3 V.** LVDS25 (TLVDS) działa przy VCCIO 2,5/3,3 V jako wejście i wyjście (DS100, tab. 2-1, 2-2).
2. **TD wyłącznie na parze z wyjściem true LVDS** (kolumna „LVDS” = TRUE w UG114). Umieszczenie `TLVDS_OBUF` na parze bez tej cechy (np. 45/44, 39/38) kończy się błędem CT1005.
3. **RD na dowolnej parze różnicowej** — wejście `TLVDS_IBUF` obsługują wszystkie banki. Atrybut `DIFF_RESISTOR` jest akceptowany wyłącznie w banku 0 (poza nim błąd CT1118, także przy wartości `OFF`); po przeniesieniu RD poza bank 0 atrybut należy usunąć.
4. **IDES8/OSER8:** HCLK z PLL obejmuje wszystkie banki (PnR: `BANK0_BANK1_HCLK0`, `BANK2_BANK3_HCLK0`); w GW1N-9 nie ma pinów bez IO logic.
5. **`XSPI_SCLK` na pinie GCLKT.** SCLK do 40 MHz nie da się nadpróbkować zegarem `clk_sys`, więc taktuje on bezpośrednio stronę hosta. Pin GCLKC tej samej pary pozostaje zwykłym I/O.
6. **Magistrala xSPI w jednym banku** (bank 2, dolna krawędź) z krótkimi i równymi ścieżkami.
7. **`CLK_25M` na dedykowanym wejściu PLL.** Wejście przez sieć globalną (pin GCLKT) działa, ale dodaje jitter na wejściu PLL.
8. **Piny MSPI (31–34)** pracują jako GPIO dzięki opcji `-use_mspi_as_gpio 1`; wymaga to trybu AUTOBOOT (pin 48 do masy).
9. **Polaryzacja par LVDS może być odwrócona na płytce**, jeśli upraszcza to prowadzenie pary (bez skrzyżowania i bez przelotek). Pin A pary (true) jest zawsze wejściem `I` bufora `TLVDS_IBUF` lub wyjściem `O` bufora `TLVDS_OBUF`; port VHDL przypisany do tego pinu w `.cst` (`IO_LOC "<port>" A,B`) nosi nazwę sieci, która jest do niego podłączona. Odwrócenie kompensuje generyk `INVERT` modułu `rx_phy` / `tx_phy`. Stan w rev. A: **RD odwrócona** (`SFP_RD_N` na pinie A 43, `SFP_RD_P` na pinie B 42, `rx_phy` z `INVERT => true`), **TD bez zmian** (`SFP_TD_P` na pinie A 34).

### 3.3 Alternatywy przydziału

Warianty na wypadek trudności w schemacie lub prowadzeniu ścieżek. Wariant oznaczony „PnR OK” przeszedł syntezę, PnR i generację bitstreamu przy pozostałych pinach bez zmian, o ile w kolumnie warunków nie podano inaczej.

| Sygnał | Podstawowy | Alternatywa | Warunki / koszt | Weryfikacja |
|---|---|---|---|---|
| `SFP_TD_P/N` | 34/33 | **28/27** (IOR24) | prawa krawędź niżej, dalej od SFP | PnR OK |
| | | **30/29** (IOR17) | zajmuje GCLKT_3 | PnR OK |
| | | **11/10** (IOL15) | lewa krawędź; `HOST_RST_N` → np. 28; zajmuje GCLKT_6 | PnR OK |
| | | 13–24 (bank 2) | pary TRUE, ale kolidują z magistralą xSPI | nie zalecane |
| `SFP_RD_N/P` (odwrócona, reguła 9) | 43/42 | **45/44** (IOT22, bank 0) | zachowuje opcję terminacji wewnętrznej | PnR OK (z `DIFF_RESISTOR=ON`) |
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
          └─> CLKDIV (DIV_MODE="4")   → 50 MHz                            (clk_sys)
```

- 200 MHz FCLK × DDR daje **400 Msps**, czyli dokładnie **4× nadpróbkowanie przy 100 Mbaud**. IDES8 oddaje 8 próbek (2 bity) co takt `clk_sys` (50 MHz) — [ADR 0007](adr/0007-zegar-systemowy-50mhz.md).
- VCO 800 MHz mieści się w zakresie 400–1200 MHz (GW1N-9 C6/I5).
- `CLKDIV` zamiast drugiego wyjścia PLL, żeby `clk_sys` był fazowo powiązany z FCLK gearboxa (wymagane przez IDES/OSER).
- Oba końce łącza pracują na niezależnych generatorach. Różnicę ppm absorbuje sam CDR z nadpróbkowaniem (wydaje 1, 2 lub 3 bity na takt, nominalnie 2), więc **bufor elastyczny nie jest potrzebny**.
- Rozszerzenie do 125 Mbaud: `clk_fast` = 250 MHz, `clk_sys` = 62,5 MHz (VCO 1000 MHz, w zakresie GW1N-9 do 1200 MHz). Prędkość linii jest parametrem pakietu `bridge_pkg` (`LINE_BAUD`), z którego wynikają nastawy PLL.

---

## 5. Warstwa fizyczna (PCB)

### 5.1 SFP

Moduł i złącze zgodne z SFP MSA (INF-8074i). SFF-8431 opisuje elektrykę SFP+ (10 Gb/s) i nie jest podstawą tego projektu. Klatka i złącze 20-pinowe są wspólne dla SFP i SFP+.

**Klasa modułów.** Obsługiwane są moduły SFP bez wewnętrznego CDR: 100BASE-FX / OC-3 (125–155 Mb/s, zakres zgodny z linią 100–125 Mbaud) oraz 1000BASE-X (1,25 Gb/s). Moduły SFP+ (10G) nie są obsługiwane: zwykle zawierają CDR zablokowany na ok. 10 Gbaud i nie są specyfikowane dla 100 Mbaud.

Przyporządkowanie pinów złącza (INF-8074i, Table 1; numeracja zgodna z symbolem `Connector_SFP_and_Cage`):

| Pin SFP | Nazwa (INF-8074i) | Sieć / FPGA | Połączenie |
|---|---|---|---|
| 1, 17, 20 | VeeT | GND | masa nadajnika |
| 2 | TX Fault | `SFP_TX_FAULT` → pin 39 | wyjście OC/OD modułu; w rev. A wewnętrzny pull-up FPGA (`PULL_MODE=UP`), INF-8074i zaleca 4,7–10 kΩ |
| 3 | TX Disable | `SFP_TX_DIS` ← pin 38 | wejście modułu z wewnętrznym pull-upem 4,7–10 kΩ (stan wysoki lub rozwarty = laser wyłączony); pull-up 4,7 kΩ na płytce (R17) utrzymuje laser wyłączony także w czasie konfiguracji FPGA |
| 4 | MOD-DEF2 | `SFP_SDA` ↔ pin 47 | SDA interfejsu 2-wire (EEPROM A0h, DDM A2h); pull-up 4,7–10 kΩ |
| 5 | MOD-DEF1 | `SFP_SCL` ← pin 46 | SCL, maks. 100 kHz; pull-up 4,7–10 kΩ |
| 6 | MOD-DEF0 | `SFP_MOD_ABS` → pin 41 | zwarte do masy w module = moduł obecny; pull-up jak TX Fault |
| 7 | Rate Select | — | **jeden pin**; opcjonalne wejście modułu z wewnętrznym pull-downem > 30 kΩ (niski lub rozwarty = pasmo zmniejszone, wysoki = pełne); 10 kΩ do masy. W SFP+ ten pin nazywa się RS0 |
| 8 | LOS | `SFP_LOS` → pin 40 | wyjście OC/OD modułu; pull-up jak TX Fault |
| 9, 10, 11, 14 | VeeR | GND | masa odbiornika. W SFP+ pin 9 to wejście RS1 — połączenie z masą jest dla modułu SFP+ stanem niskim, więc pozostaje poprawne |
| 12 | RD− | → `SFP_RD_N` (pin 43) | połączenie bezpośrednie; terminacja i bias przy FPGA (5.2) |
| 13 | RD+ | → `SFP_RD_P` (pin 42) | jw.; polaryzacja odwrócona względem pinów A/B pary (3.2, reguła 9) |
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
RD+ (SFP 13) ───┬──────────────── FPGA RD_P (pin 42, IOT32B)
              R9 49,9 Ω 1% 0402
                ├── Vbias 1,2 V (R11 2,1 kΩ z 3,3 V / R12 1,2 kΩ do masy, C6 100 nF do masy)
              R10 49,9 Ω 1% 0402
RD− (SFP 12) ───┴──────────────── FPGA RD_N (pin 43, IOT32A)
```

- R9 i R10 umieszcza się bezpośrednio przy pinach 42/43 (odcinek do odbiornika ≤ 2 mm). C6 w węźle Vbias zwiera do masy zakłócenia wspólne.
- Sprzężenie AC jest wewnątrz modułu, więc linie RD± nie mają po stronie płytki określonego napięcia stałego; dzielnik Vbias jest wymagany niezależnie od wariantu terminacji.
- Wariant awaryjny: w miejsce R9/R10 montuje się 10 kΩ (te same footprinty 0402), w `.cst` `DIFF_RESISTOR=ON` (tylko bank 0). Dodatkowe footprinty nie są potrzebne.
- Obie terminacje jednocześnie (49,9 Ω i `DIFF_RESISTOR=ON`) dają ok. 50 Ω i są niedopuszczalne; domyślnie `DIFF_RESISTOR=OFF`.

### 5.3 Płytka drukowana: stackup, reguły i prowadzenie ścieżek

#### 5.3.1 Technologia (JLCPCB, najniższy próg cenowy 4 warstw)

| Parametr | Wartość |
|---|---|
| Liczba warstw / grubość | 4 / 1,6 mm |
| Stackup | **JLC04161H-7628** |
| Miedź zewnętrzna / wewnętrzna | 1 oz (35 µm) / 0,5 oz (15,2 µm) |
| Wykończenie | HASL (bezołowiowy lub ołowiowy) — bez ENIG |
| Przelotki | „Min via hole size/diameter: **0,3 mm / (0,4/0,45 mm)**” (opcja domyślna, bez dopłaty); pokrycie: tented |
| Via-in-pad | bez wypełniania i zaślepiania (bez opcji „Epoxy Filled & Capped”) |
| Kontrola impedancji | nie zamawia się; geometrię wyznacza się obliczeniowo (5.3.3), tolerancja ±10–15% jest bez znaczenia przy 100 Mbaud |

#### 5.3.2 Stackup do wpisania w KiCad

`Board Setup → Board Stackup → Physical Stackup` (warstwy miedzi: 4, grubość płytki 1,6 mm):

| Warstwa | Materiał | Grubość | εr | Przeznaczenie |
|---|---|---|---|---|
| F.Mask | soldermaska | 0,010 mm | 3,8 | |
| **F.Cu (L1)** | miedź 1 oz | 0,035 mm | — | sygnały, **pary LVDS**, elementy |
| Dielectric 1 | prepreg 7628 | 0,2104 mm | 4,4 | |
| **In1.Cu (L2)** | miedź 0,5 oz | 0,0152 mm | — | **GND — płaszczyzna ciągła, bez podziałów** |
| Dielectric 2 | rdzeń FR-4 | 1,065 mm | 4,6 | |
| **In2.Cu (L3)** | miedź 0,5 oz | 0,0152 mm | — | 3V3 — płaszczyzna |
| Dielectric 3 | prepreg 7628 | 0,2104 mm | 4,4 | |
| **B.Cu (L4)** | miedź 1 oz | 0,035 mm | — | sygnały wolne, wylewka GND |
| B.Mask | soldermaska | 0,010 mm | 3,8 | |

Wartości grubości i εr należy potwierdzić w kalkulatorze impedancji JLCPCB dla JLC04161H-7628 przed zamówieniem **[DO WERYFIKACJI]**.

#### 5.3.3 Geometria linii (L1 nad L2 GND)

Obliczenia: solver 2D równania Laplace'a (metoda różnic skończonych), przekrój prostokątny, soldermaska 10–15 µm, εr = 4,4, h = 0,2104 mm, t = 35 µm. Kontrola: linia 50 Ω wychodzi przy szerokości ok. 0,36 mm, zgodnie z danymi publikowanymi dla tego stackupu.

| Linia | Szerokość | Odstęp w parze | Impedancja |
|---|---|---|---|
| **LVDS TD±, RD± — podstawowa** | **0,22 mm** | **0,20 mm** | **ok. 101 Ω różnicowo** |
| LVDS — zwężenie przy U1 (raster 0,4 mm) i J1 | 0,20 mm | 0,20 mm | ok. 105 Ω, odcinek ≤ 1–2 mm |
| sygnał pojedynczy 0,20 mm (xSPI, zegar, sterowanie) | 0,20 mm | — | ok. 66 Ω (niekontrolowana) |
| sygnał pojedynczy 50 Ω (tylko dla odniesienia) | 0,36 mm | — | ok. 50 Ω |

Wrażliwość: zmiana odstępu o ±0,05 mm zmienia impedancję różnicową o ok. ±7 Ω; zmiana szerokości o ±0,02 mm — o ok. ∓3,5 Ω.

#### 5.3.4 Ustawienia w KiCad

**Board Setup → Design Rules → Constraints** (zgodne z JLCPCB, z zapasem):

| Parametr | Wartość |
|---|---|
| Minimalna szerokość ścieżki | 0,20 mm (technologicznie 0,09 mm; 0,20 mm wystarcza wszędzie) |
| Minimalny odstęp (clearance) | 0,20 mm (pady QN48: 0,2 mm przy rastrze 0,4 mm) |
| Minimalny otwór (PTH i przelotka) | **0,30 mm** |
| Minimalna średnica przelotki | 0,45 mm (zalecane 0,6 mm) |
| Minimalny pierścień przelotki | 0,10 mm (0,6/0,3 → 0,15 mm) |
| Odstęp miedzi od krawędzi | 0,5 mm (JLCPCB min. 0,2–0,3 mm) |
| Otwór–otwór | 0,25 mm |
| Soldermaska: poszerzenie / minimalny mostek | 0,05 mm / 0,10 mm |
| Nadruk: grubość linii / wysokość tekstu | ≥ 0,15 mm / ≥ 1,0 mm |

**Board Setup → Net Classes:**

| Klasa | Ścieżka | Clearance | Przelotka | Para różnicowa (szer./odstęp) | Przypisanie sieci |
|---|---|---|---|---|---|
| Default | 0,20 mm | 0,20 mm | 0,6 / 0,3 mm | — | wszystkie pozostałe |
| LVDS | 0,22 mm | 0,20 mm | 0,6 / 0,3 mm (nieużywane) | **0,22 / 0,20 mm** | `/SFP/SFP_TD_*`, `/SFP/SFP_RD_*` |
| PWR | 0,50 mm | 0,20 mm | 0,6 / 0,3 mm | — | `+3V3`, `Net-(J1-VccT)`, `Net-(J1-VccR)` |

**Board Setup → Pre-defined Sizes:** ścieżki 0,20 / 0,22 / 0,30 / 0,50 / 0,80 mm; przelotki 0,6/0,3 i 0,45/0,3 mm; para różnicowa 0,22/0,20 mm.

**Reguły dodatkowe:** plik `pcb/SFP_xSPI_Bridge.kicad_dru`, wczytywany automatycznie obok `.kicad_pcb` (podgląd i edycja: `Board Setup → Design Rules → Custom Rules`). Zawiera:

- przelotki: otwór ≥ 0,3 mm, średnica ≥ 0,45 mm (próg bez dopłaty JLCPCB),
- pary LVDS: szerokość 0,20–0,24 mm (opt. 0,22), odstęp 0,18–0,22 mm (opt. 0,20), odcinek niesprzężony ≤ 2 mm, różnica długości w parze ≤ 0,5 mm, **zakaz przelotek**,
- odstęp par LVDS od innych ścieżek, przelotek i wylewek ≥ 0,5 mm (wylewka GND bliżej pary obniża jej impedancję przez sprzężenie z masą w tej samej warstwie),
- zwężenie przy U1 i J1 (w obrębie courtyardu): szerokość 0,20 mm, odstęp do 0,60 mm.

#### 5.3.5 Zasady prowadzenia

**Pary LVDS (TD: U1 33/34 ↔ J1 19/18; RD: U1 42/43 ↔ J1 12/13):**

- W całości na L1, nad ciągłą płaszczyzną GND na L2; bez przelotek, bez przejść nad krawędzią lub przerwą w L2.
- Router par różnicowych KiCad (`6` lub `Route → Differential Pair`) rozpoznaje pary po sufiksach `_P`/`_N`.
- Dopasowanie długości w parze ≤ 0,5 mm; między parami TD i RD dopasowanie nie jest wymagane. Skew w parze przy 100 Mbaud (UI = 10 ns) jest pomijalny; reguła utrzymuje symetrię dla tłumienia zakłóceń wspólnych.
- Zakręty 45° lub łukowe; meandry wyrównujące przy końcu z krótszą linią.
- Odstęp od innych sygnałów ≥ 0,5 mm (≈ 2× szerokość pary); generator Y1 i linia `CLK_25M` jak najdalej od par.
- Terminacja RX (R9, R10) i węzeł Vbias (R11, R12, C6) bezpośrednio przy pinach 42/43.
- Para TD wychodzi z pinów 33/34 na prawej krawędzi U1, para RD z pinów 42/43 na górnej — obie w stronę klatki SFP przy prawym górnym narożniku U1.

**Magistrala xSPI (U1 13–24 ↔ J3):**

- Ścieżki 0,20 mm na L1 i/lub L4 (L4 odnosi się do płaszczyzny 3V3 — dopuszczalne dzięki odsprzęganiu).
- Wyrównanie długości ±5 mm względem `XSPI_SCLK`; przy 40 MHz i ścieżkach < 50 mm impedancja nie jest kontrolowana.
- Przelotki przy zmianie warstwy uzupełnia się przelotką GND w pobliżu (ścieżka powrotna).

**Zasilanie i odsprzęganie:**

- 3V3 rozprowadza płaszczyzna L3; od złącza J3 do płaszczyzny ścieżka ≥ 0,8 mm lub wylewka, TVS D1 przy złączu.
- Kondensatory 100 nF (C1–C5) przy pinach zasilania U1 (1, 12, 25, 36, 37), każdy z własną przelotką do L2/L3, odległość ≤ 2 mm.
- Filtry SFP (L1/C7 dla VccT, L2/C8/C9 dla VccR, C10–C12 po stronie 3V3) przy klatce J1; dławiki 0805 nieekranowane — kilka mm od par LVDS.
- Generator Y1: 100 nF przy pinie 4, wyjście `CLK_25M` krótkie do pinu 35.

**EPAD U1 (pad 49):**

- Symbol `GW1N-6&9_QN48` z biblioteki lokalnej nie ma pinu EPAD — **pad 49 musi zostać ręcznie połączony z GND** (UG114: „Exposed pad. Connect to ground.”).
- Footprint bez przelotek w padzie (`QFN-48-1EP_6x6mm_P0.4mm_EP4.2x4.2mm`); przelotki 0,3/0,5 mm dodane ręcznie w polu EPAD do L2 GND (w rev. A: 16). Wariant `…_ThermalVias` ma przelotki Ø 0,2 mm, wymagające płatnej opcji JLCPCB.
- Przelotki w padzie bez wypełnienia odprowadzają część lutu; otwór pasty w EPAD dzieli się na 4–9 okien (pokrycie ok. 50–60%). Moc rozpraszana przez FPGA (< 0,5 W) nie wymaga więcej przelotek.

**Pozostałe:**

- Wylewki GND na L1 i L4 zszywane przelotkami GND co ok. 5 mm, szczególnie wzdłuż par LVDS i krawędzi płytki.
- Klatka SFP: otwory wg rysunku producenta wybranej klatki (press-fit), sprawdzić zgodność footprintu `Connector_SFP_and_Cage` z konkretnym numerem katalogowym klatki **[DO WERYFIKACJI]**.
- Zworka lutowana `MODE_SEL`: pin 10 FPGA ↔ GND, pull-up 10 kΩ do 3,3 V ([ADR 0006](adr/0006-tryb-uart-przezroczysty.md)).

### 5.4 Zasilanie

| Odbiornik | Prąd (szac.) |
|---|---|
| Moduł SFP | do 300 mA (INF-8074i) |
| GW1N-UV9 (VCC=VCCX=VCCIO=3,3 V) | ok. 50–100 mA |
| Generator, LED, reszta | ok. 10 mA |
| **Razem** | **ok. 0,45 A → projektować na 0,6–0,8 A** |

- Wejście: J3 piny 1–2 (3V3), TVS D1 SMF3.3A (katoda do 3V3) przy złączu. Bez PTC i koralika — każdy element szeregowy zmniejsza margines napięcia modułu SFP (min. 3,135 V na pinie VccT/VccR).
- Odsprzęganie: 5 × 100 nF przy pinach zasilania FPGA, 7 × 10 µF ceramicznych na szynie 3V3 (ok. 70 µF łącznie), filtry SFP wg 5.1.
- TVS ogranicza ESD i szpilki; nie chroni przed stałym przepięciem (np. 5 V na pinie 3V3) — maksymalne napięcie GW1N-UV to 3,75 V (DS100, tab. 3-1).

### 5.5 Złącze hosta J3 (2 × 10, raster 1,27 mm)

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

- W trybie UART ([ADR 0006](adr/0006-tryb-uart-przezroczysty.md)) piny 7–10 pełnią funkcje: 7 `UART_RX` (wejście), 8 `UART_TX` (wyjście), 9 `UART_RTS_N` (wyjście, opcja), 10 `UART_CTS_N` (wejście, opcja); zasilanie i masa bez zmian.
- Footprint `PinHeader_2x10_P1.27mm_Vertical` nie ma klucza. Odwrócona wtyczka łączy 3V3 hosta z GND (piny 19/20) — zaleca się złącze z obudową i kluczem (box header 1,27 mm) albo wyraźne oznaczenie pinu 1 na nadruku.
- Rezystory szeregowe na liniach xSPI nie są przewidziane; ewentualne dzwonienie ogranicza się ustawieniem `DRIVE` wyjść FPGA (4/8 mA) i prędkości GPIO po stronie STM32.

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

| Ozn. | Pozycja | Źródło / numer | Uwagi |
|---|---|---|---|
| U1 | GW1N-UV9QN48C6/I5 | Mouser | jedyny dystrybutor; dostępność sprawdzić przed zamówieniem |
| J1 | klatka SFP + złącze 20-pin | — | press-fit lub SMT; dopasować do footprintu |
| Y1 | generator 25 MHz CMOS, ±20 ppm, 3225 | LCSC C669088 (YXC OT322525MJBA4SL) | alternatywnie 7050: C669095 |
| L1, L2 | dławik 1 µH, drutowy 0805 | TME Viking NL05KTC1R0 | DCR 0,169 Ω, 1,1 A wg TME (prąd do potwierdzenia w datasheecie) |
| D1 | TVS SMF3.3A, SOD-123FL | LCSC C283866 / C37331473 / C5197392 | VRWM 3,3 V |
| D2 | LED żółtozielona 575 nm, 0603 | LCSC C965805 (XL-1608SYGC-06) | LINK |
| D3 | LED pomarańczowa 601 nm, 0603 | LCSC C965800 (XL-1608UOC-06) | ACT |
| R9, R10 | 49,9 Ω 1%, 0402 | — | terminacja RX |
| R11, R12 | 2,1 kΩ / 1,2 kΩ, 0603 | — | Vbias 1,2 V |
| R14, R15 | 1 kΩ, 0603 | — | LED, ok. 1,4 mA |
| R2 | 1 kΩ, 0603 | — | MODE → AUTOBOOT |
| R13 | 4,7 kΩ, 0603 | — | pull-down TCK |
| J3 | złącze 2 × 10, 1,27 mm | — | preferowane z kluczem |
| J2 | Tag-Connect TC2050-IDC-NL | footprint, bez elementu | kabel TC2050 po stronie programatora |
| JP1, JP2 | zworki lutowane 2- i 3-pozycyjna | — | nRESET → `RECONFIG_N`; AUX → `JTAGSEL_N` / `DONE` (5.6) |
| JP3 | zworka lutowana 2-pozycyjna | — | `MODE_SEL` (pin 10) ↔ GND: zwarta = tryb UART ([ADR 0006](adr/0006-tryb-uart-przezroczysty.md)) |
| R16 | 10 kΩ, 0603 | — | pull-up `MODE_SEL` do 3,3 V |
| R17 | 4,7 kΩ, 0603 | — | pull-up `SFP_TX_DIS` do 3,3 V (laser wyłączony w czasie konfiguracji FPGA) |

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
| Timing (.sdc) | `create_clock` 25 MHz (`CLK_25M`) i 40 MHz (`XSPI_SCLK`); zegary generowane: `clk_fast` (rPLL ×8), `clk_sys` (CLKDIV ÷4), `clk_host` (wyjście DCS); grupy asynchroniczne {`clk_spi`, `clk_host`} i {`clk_25m`, `clk_fast`, `clk_sys`}; opóźnienia wejść i wyjść xSPI względem zbocza opadającego SCLK ([integracja](vhdl/top.md#ograniczenia-czasowe)) |

Ograniczenia: `vhdl/constraints/sfp_bridge.cst` (piny, standardy I/O) i `vhdl/constraints/sfp_bridge.sdc` (zegary, opóźnienia).

Składnia atrybutów `DRIVE=3.5` (LVDS25) i `DIFF_RESISTOR=ON` jest potwierdzona syntezą i PnR w Gowin EDA 1.9.11.03.

---

## 7. Projekt FPGA (VHDL)

### 7.1 Struktura katalogów

Moduły, testbenche i wyniki syntezy: [projekt FPGA](vhdl/index.md).

```
vhdl/
  constraints/
    sfp_bridge.cst            -- piny, standardy I/O (wspólne dla projektów)
    sfp_bridge.sdc            -- zegary
  sfp_bridge/                 -- projekt Gowin EDA (sfp_bridge.gprj, build.tcl)
  sfp_bridge/src/
    pkg/
      bridge_pkg.vhd          -- stałe: zegary, kody K, identyfikacja
      code8b10b_pkg.vhd       -- tablice i funkcja kodu 8b/10b (jedno źródło dla kodera i dekodera)
    common/
      sync_bit.vhd            -- synchronizator bitu
      reset_sync.vhd          -- mostek resetu domeny (ADR 0004)
    top/
      sfp_bridge_top.vhd
    clk/
      clk_rst.vhd             -- rPLL + CLKDIV + mostki resetu domen
      host_clk.vhd            -- DCS: zegar strony hosta (SCLK / clk_sys)
    host/
      xspi_slave.vhd          -- SPI/QSPI/OCTOSPI slave, dekoder komend
      csr_regs.vhd            -- rejestry kontrolne/statusowe, IRQ
      frame_echo.vhd          -- echo ramek (pętla far-end)
    fifo/
      async_fifo.vhd          -- FIFO na BSRAM semi-dual port, Gray + handshake, commit/abort
    link/
      crc32.vhd               -- CRC-32 (bajtowo)
      enc_8b10b.vhd, dec_8b10b.vhd
      tx_framer.vhd           -- ramki, bezczynność /I/ /P/ /R/ (XON/XOFF, odbiornik niegotowy)
      rx_deframer.vhd         -- kontrola ramek, odrzucanie błędnych, XOFF
      tx_gearbox.vhd          -- symbol 10 bitów → 2 bity na takt, char_en co 5 taktów
      tx_phy.vhd              -- OSER8 (bity powielone 4×) + TLVDS_OBUF
      rx_phy.vhd              -- TLVDS_IBUF + IDES8
      cdr_os4x8.vhd           -- odzysk danych z 4× nadpróbkowania, 8 próbek na takt
      comma_align.vhd         -- wyrównanie do K28.5
      link_ctrl.vhd           -- stan łącza, LOS, liczniki błędów, pętle zwrotne
    uart/
      uart_rx.vhd, uart_tx.vhd
      uart_bridge.vhd         -- pakietyzacja ramek TYPE 0x01, RTS/CTS (ADR 0006)
    mgmt/
      i2c_master.vhd
      sfp_mgmt.vhd            -- skrzynka I2C, odczyt DDM, sygnały SFP
      leds.vhd
  sim/
    tb/                       -- tb_pkg, testbenche tb_<moduł>.vhd (24), e2e_bench
                              --   (testy end-to-end dwóch mostków)
    waves/                    -- widoki GTKWave (.gtkw)
    sources.txt               -- kolejność kompilacji
    run_tests.ps1 / .sh       -- uruchamianie testów (GHDL w WSL)
    view.ps1                  -- podgląd przebiegu
```

### 7.2 Moduły

**`clk_rst`** — [opis](vhdl/clk_rst.md)
- `rPLL` (25 → 200 MHz), `CLKDIV` (/4 → 50 MHz); parametry PLL wyliczane z `LINE_BAUD` w `bridge_pkg`.
- Reset globalny trzymany do `LOCK` PLL; `HOST_RST_N` z filtrem zakłóceń 640 ns; `CTRL.SOFT_RST` kończący się samoczynnie. Reset domeny `clk_sys` przez `reset_sync`; `rst_hard` bez resetu programowego (`MODE_CTRL`, `UART_DIV`), `rst_por` tylko od blokady PLL (`UART_STATUS`); żądanie `arst_n` dla mostka resetu domeny `clk_spi` (reset asynchroniczny, zwalnianie synchroniczne).

**`xspi_slave`** — [opis](vhdl/xspi_slave.md) (domena `clk_host` = SCLK w trybie xSPI, piny zatrzaskiwane na zboczu narastającym, logika na opadającym, CS_N jako asynchroniczny reset maszyny stanów; [ADR 0009](adr/0009-interfejs-hosta.md))
- Fazy: instrukcja (zawsze 1 linia) → opcjonalny adres → dummy → dane, szerokość fazy danych wynika z opkodu (tabela 7.3).
- Próbkowanie na zboczu narastającym SCLK, wystawianie na opadającym (tryb 0).
- Kierunek IO0..7 przełączany po fazie dummy przy odczycie.
- Interfejs do FIFO: zapis bajtów do TX FIFO / odczyt z RX FIFO bez udziału `clk_sys`. Rejestry CSR: zatrzask w domenie `clk_sys` przy opadnięciu CS, odczyt multiplekserem w domenie SCLK ([ADR 0009](adr/0009-interfejs-hosta.md)).

**`csr_regs`** — [opis](vhdl/csr_regs.md) (domena `clk_sys`) — mapa rejestrów w rozdziale 7.4; zatrzask przestrzeni odczytu przy opadnięciu CS, zapis po podniesieniu CS, przerwania, `MODE_CTRL` zachowywany przy resecie programowym.

**`host_clk`** — [opis](vhdl/host_clk.md) — prymityw `DCS`: zegar strony hosta FIFO = `clk_sys` w resecie oraz w trybach UART i echa ramek, SCLK w trybie xSPI; reset strony hosta zawsze na `clk_sys`.

**`frame_echo`** — [opis](vhdl/host_clk.md) — echo ramek (`MODE_CTRL.FRAME_ECHO`): kopiowanie ramek z FIFO RX do FIFO TX po stronie hosta.

**`async_fifo`** — [opis](vhdl/async_fifo.md)
- BSRAM w trybie semi-dual port (zapis port A, odczyt port B, różne zegary); wskaźnik odczytu w kodzie Graya, zatwierdzony wskaźnik zapisu przez handshake (zatwierdzenie przesuwa wskaźnik o całą ramkę).
- Zatwierdzanie i odrzucanie ramki (`commit` / `abort`).
- Flagi: pusty, pełny (dokładne); poziomy zapełnienia (informacyjne, takt opóźnienia).
- Rozmiary: TX 4 KiB (2 bloki), RX 8 KiB (4 bloki — wymagane przez progi XOFF, [ramkowanie](vhdl/framing.md)), tablica dekodera 8b/10b (1 blok). Razem 7 z 26 bloków. Bufor I2C (128 B) jest w pamięci rozproszonej (SSRAM), bo odczyt rejestrów z domeny SCLK wymaga odczytu asynchronicznego.

**`tx_framer`** — [opis](vhdl/framing.md)
- Ramka: `K27.7 (SOF) | TYPE | LEN_H | LEN_L | payload (1..1024 B) | CRC32 (4 B) | K29.7 (EOF)`; FIFO TX zawiera ramki w postaci `TYPE, LEN_H, LEN_L, payload`.
- Poza ramką ciągła bezczynność: para `K28.5 + D16.2` (/I/, XON), `K28.5 + D21.5` (/P/, XOFF) lub `K28.5 + D5.6` (/R/, własny odbiornik niezsynchronizowany — [ADR 0008](adr/0008-stan-lacza.md)).
- Ramkę zaczyna dopiero wtedy, gdy w TX FIFO jest cała (zatwierdzona) ramka i strona przeciwna nie zgłasza XOFF ani niegotowości; ramka rozpoczęta jest wysyłana do końca.

**`crc32`** — [opis](vhdl/crc32.md): CRC-32 IEEE 802.3, przetwarzanie bajtowe, jeden bajt na takt.

**`enc_8b10b` / `dec_8b10b`** — [opis](vhdl/8b10b.md)
- Standardowa tabela 5b/6b + 3b/4b z bieżącym dysparytetem; tablica dekodera wyliczana z funkcji kodera (ROM w BSRAM).
- Dekoder zgłasza flagi `code_err` i `disp_err`.

**`tx_gearbox`, `tx_phy`, `rx_phy`** — [opis](vhdl/phy.md)
- `tx_gearbox`: symbol 10-bitowy co 5 taktów `clk_sys` → 2 bity na takt; impuls `char_en` dla `tx_framer` i `enc_8b10b`.
- `tx_phy`: `OSER8` taktowany `clk_fast` (FCLK) / `clk_sys` (PCLK), każdy bit powielony 4× → `TLVDS_OBUF`.
- `rx_phy`: `TLVDS_IBUF` → `IDES8` (FCLK = 200 MHz, PCLK = 50 MHz) → 8 próbek na takt `clk_sys`.
- Generyk `INVERT` — odwrócenie polaryzacji pary. W rev. A para RD jest odwrócona na płytce (3.2, reguła 9): `rx_phy` z `INVERT => true`, wejścia bufora `rd_p => sfp_rd_n`, `rd_n => sfp_rd_p`; `tx_phy` z `INVERT => false`.

**`cdr_os4x8`** — [opis](vhdl/cdr.md)
- Wejście: 8 próbek na takt (2 bity × 4 próbki). Wykrywanie zboczy między kolejnymi próbkami (także między taktami), liczniki zboczy w czterech klasach fazowych przez okno 32 taktów.
- Decyzja raz na okno: średnie położenie granic bitów względem chwili próbkowania; krok fazy o 1/4 UI przy odchyleniu > 0,625 okresu próbkowania (strefa martwa z histerezą — jitter nie przełącza fazy); osobna reguła dla granic leżących przy chwili próbkowania.
- Śledzenie dryfu: przy zawinięciu fazy wydanie **1 albo 3 bitów** zamiast 2, co kompensuje różnicę ppm (zakres ok. 3900 ppm).
- Wyjście: liczba bitów (1–3) + `bits(2:0)`.

**`comma_align`** — [opis](vhdl/comma_align.md)
- Rejestr przesuwny 12 bitów, wykrywanie wzorca comma (`0011111` / `1100000`) w do 3 położeniach na takt i ustalenie granicy słowa 10-bit.
- Synchronizacja po 4 comma w oczekiwanej pozycji bez błędów dekodera; w synchronizacji granica nie jest przesuwana, utrata po 4 błędach (licznik maleje po 4 poprawnych symbolach) — maszyna stanów jak w 1000BASE-X PCS, ze sprzężeniem zwrotnym z `dec_8b10b`.

**`rx_deframer`** — [opis](vhdl/framing.md)
- Oczekiwanie na SOF, odczyt typu i długości, zapis do RX FIFO, liczenie CRC.
- Błąd (kod/dysparytet, długość, nieoczekiwany znak sterujący, CRC, brak miejsca) → odrzucenie ramki (`abort`) i impuls zdarzenia dla liczników.
- Odbiór stanu strony przeciwnej (gotowość /R/, XON/XOFF); generowanie własnego XOFF z progiem i histerezą (FIFO RX 8 KiB).

**`link_ctrl`** — [opis](vhdl/link_ctrl.md), [ADR 0008](adr/0008-stan-lacza.md)
- Stany: `DOWN` (LOS — o ile nie jest ignorowany, brak modułu lub brak synchronizacji) → `SYNC` (własny odbiornik zsynchronizowany, strona przeciwna nadaje /R/) → `UP`. Ramki są rozpoczynane tylko w stanie UP.
- Sterowanie `tx_framer`: `rx_ready` (gdy 0 — bezczynność /R/) i wstrzymanie nadawania (`tx_hold`).
- Liczniki 32-bit (zawijanie, `CNT_CLR`): błędy kodu i dysparytetu, CRC, długości, ramkowania, przepełnienia, ramki TX/RX, utraty synchronizacji.
- Pętle zwrotne: near-end (bity `tx_gearbox` → wejście `cdr_os4x8`, bez SFP) w `link_ctrl`; far-end jako echo ramek (FIFO RX → FIFO TX, `MODE_CTRL.FRAME_ECHO`, moduł `frame_echo`).

**`i2c_master` + `sfp_mgmt`** — [opis](vhdl/sfp_mgmt.md)
- I2C 100 kHz (INF-8074i), open-drain, wydłużanie SCL przez moduł, limit 25 ms, odblokowanie magistrali (impulsy SCL przy SDA trzymanej przez moduł).
- Skrzynka poleceń: `I2C_DEV`, `I2C_OFFSET`, `I2C_LEN` (1–128), `I2C_CMD` (READ / WRITE), `I2C_STATUS` (BUSY / NACK / TIMEOUT / BAD_CMD), bufor `I2C_BUF` 128 B w pamięci rozproszonej (odczyt asynchroniczny w domenie SCLK, jak zatrzask CSR).
- Odczyt DDM co `DDM_PERIOD` × 100 ms (domyślnie 1 s), od 300–400 ms po włożeniu modułu: bajty 96–110 z A2h w jednym poleceniu; kopia temperatury, Vcc, prądu lasera, mocy TX i RX (little-endian) oraz bajtu 110, aktualizowana w całości po udanym odczycie.
- Filtry `MOD_ABS` (10 ms), `LOS` i `TX_FAULT` (50 µs); zmiana stanu generuje przerwanie `SFP_CHG`. `SFP_TX_DIS` = 1 w czasie resetu.

**`leds`** — [opis](vhdl/top.md) — LINK: świeci przy `UP`, miga 2 Hz przy `SYNC`, zgaszona przy `DOWN`; ACT: błysk 30 ms z przerwą 30 ms przy ramce TX/RX; diody aktywne stanem niskim.

**`sfp_bridge_top`** — [opis](vhdl/top.md) — integracja wszystkich modułów, wybór trybu (UART / echo / xSPI) i multipleksowanie pinów J3, odwrócona para RD (`rx_phy` z `INVERT`), ograniczenia czasowe z zegarami generowanymi PLL / CLKDIV / DCS; testy end-to-end dwóch mostków: [wyniki](e2e/index.md).

**`uart_rx`, `uart_tx`, `uart_bridge`** — tryb przezroczysty, zob. 7.7.

### 7.3 Zestaw komend xSPI (wzorowany na SPI NOR)

Decyzja i uzasadnienie: [ADR 0009](adr/0009-interfejs-hosta.md). Instrukcja zawsze na 1 linii, adres 8-bit na 1 linii, SDR, tryb 0, najstarszy bit pierwszy; w formacie 1-x-1 dane od hosta na IO0, do hosta na IO1.

| Opkod | Nazwa | Format | Dummy | Dane |
|---|---|---|---|---|
| `0x9F` | READ_ID | 1-0-1 | 0 | 4 B: `0x5B`, `0x5F` (ID), wersja, `0x00` |
| `0x05` | READ_STATUS | 1-0-1 | 0 | rejestr `STATUS_FAST` (powtarzany) |
| `0x0B` | READ_REG | 1-1-1 | 8 | rejestry od adresu, auto-inkrementacja |
| `0x02` | WRITE_REG | 1-1-1 | 0 | do 8 bajtów od adresu, auto-inkrementacja |
| `0x12` / `0x32` / `0x82` | TX_WRITE_1 / _4 / _8 | 1-0-1 / 1-0-4 / 1-0-8 | 0 | bajty ramki do FIFO TX |
| `0x13` / `0x6B` / `0x8B` | RX_READ_1 / _4 / _8 | 1-0-1 / 1-0-4 / 1-0-8 | 8 | bajty ramek z FIFO RX |
| `0x66` | TX_ABORT | 1-0-0 | — | porzucenie niezatwierdzonej ramki |

Zasady:
- Ramki w formacie surowym FIFO: zapis `TX_WRITE_x` — bajty `TYPE, LEN_H, LEN_L, treść`, slave zatwierdza ramkę z ostatnim bajtem treści (ramka może być podzielona na kilka transakcji); odczyt `RX_READ_x` — bajty `TYPE, LEN_H, LEN_L, treść` kolejnych ramek. Przed zapisem host sprawdza `TX_SPACE` / `TX_READY`, przed odczytem `RX_AVAIL` / `RX_LEVEL`.
- Rejestry są zatrzaskiwane przy opadnięciu CS (spójny odczyt w obrębie transakcji), zapisy stosowane po podniesieniu CS. Wymagania: SCLK ≤ 40 MHz (przy odczycie zalecane przesunięcie próbkowania `SSHT`), CS w stanie wysokim ≥ 100 ns między transakcjami.
- Dummy cycles dają FPGA czas na publikację wskaźnika FIFO w domenie SCLK i pobranie pierwszego bajtu.
- Opkody `0x8x` są własne (nie z JEDEC), a STM32 OCTOSPI w trybie indirect przyjmie dowolny opkod.

### 7.4 Mapa rejestrów CSR

Adresy bajtowe, wartości wielobajtowe little-endian ([ADR 0009](adr/0009-interfejs-hosta.md)).

| Adres | Nazwa | R/W | Zawartość |
|---|---|---|---|
| 0x00–0x01 | ID | R | `0x5F5B` |
| 0x02 | VERSION | R | wersja bitstreamu |
| 0x04 | CTRL | R/W | b0 `TX_EN`, b1 `RX_EN`, b2 `LB_NEAR` (pętla near-end), b3 `SFP_TX_DIS`, b4 `LOS_IGNORE`, b6 `CNT_CLR` (zapis 1: kasowanie liczników), b7 `SOFT_RST` (zapis 1: reset mostka); po resecie `0x03` |
| 0x05 | STATUS | R | b0 `LINK_UP`, b1 `SYNC`, b2 `REMOTE_READY`, b3 `XOFF_LOCAL`, b4 `XOFF_REMOTE`, b5 `LOS`, b6 `TX_FAULT`, b7 `MOD_ABS` |
| 0x06 | STATUS_FAST | R | b0 `LINK_UP`, b1 `RX_AVAIL`, b2 `TX_READY`, b3 `TX_EMPTY`, b4 `IRQ`, b5 `MODE_SEL` (stan zworki) |
| 0x07 | IRQ_EN | R/W | maska przerwań |
| 0x08 | IRQ_STAT | R/W1C | b0 `RX_FRAME`, b1 `TX_EMPTY`, b2 `LINK_CHG`, b3 `SFP_CHG`, b4 `I2C_DONE`, b5 `ERR` |
| 0x0A–0x0B | TX_SPACE | R | wolne bajty w FIFO TX |
| 0x0C–0x0D | RX_LEVEL | R | bajty zatwierdzonych ramek w FIFO RX |
| 0x10–0x2F | CNT_* | R | liczniki 32-bit (zawijanie, kasowanie `CTRL.CNT_CLR`): CODE_ERR, CRC_ERR, LEN_ERR, FRAMING_ERR, RX_OVF, FRAMES_TX, FRAMES_RX, SYNC_LOSS |
| 0x30 | I2C_DEV | R/W | adres 7-bit urządzenia I2C; po resecie 0x50 (A0h) |
| 0x31 | I2C_OFFSET | R/W | offset w urządzeniu |
| 0x32 | I2C_LEN | R/W | liczba bajtów 1–128 |
| 0x33 | I2C_CMD | W | 0x01 READ, 0x02 WRITE (odczyt 0) |
| 0x34 | I2C_STATUS | R | b0 `BUSY` (ustawiony już w takcie przyjęcia polecenia), b1 `NACK`, b2 `TIMEOUT`, b3 `BAD_CMD` (`LEN` spoza 1–128, brak modułu, polecenie w czasie `BUSY`; do następnego przyjętego polecenia) |
| 0x40–0x49 | DDM_TEMP, DDM_VCC, DDM_TXBIAS, DDM_TXPWR, DDM_RXPWR | R | kopia A2h bajtów 96–105, wartości 16-bit little-endian |
| 0x4A | DDM_FLAGS | R | kopia A2h bajtu 110 |
| 0x4B | DDM_STAT | R | b0 `VALID` (udany odczyt od włożenia modułu), b1 `NACK`, b2 `TIMEOUT` (ostatni odczyt) |
| 0x4C | DDM_SEQ | R | licznik udanych odczytów DDM (zawijanie) |
| 0x4F | DDM_PERIOD | R/W | okres odczytu DDM × 100 ms; 0 = wyłączony; po resecie 10 |
| 0x50 | MODE_CTRL | R/W | b0 `UART_MODE`, b1 `FRAME_ECHO`, b2 `RTSCTS_EN`; zachowywany przy resecie programowym; zmiana b0 / b1 resetuje mostek |
| 0x51–0x52 | UART_DIV | R/W | takty `clk_sys` na bit UART (434 = 115 200); zachowywany przy resecie programowym (jak `MODE_CTRL`), więc prędkość ustawiona przed przejściem w tryb UART przez `MODE_CTRL` obowiązuje po resecie, który to przejście wywołuje |
| 0x53 | UART_STATUS | R/W1C | b0 `RX_OVF`, b1 `FRAME_ERR`; kasowany tylko przy włączeniu zasilania i przez W1C (przetrwa `HOST_RST_N`, którym host wraca z trybu UART do xSPI) |
| 0x80–0xFF | I2C_BUF | R/W | bufor I2C 128 B: wynik READ, dane do WRITE (od 0x80); czytany bez zatrzasku, stały przy `BUSY` = 0 |

Nieopisane adresy: odczyt 0, zapis ignorowany. `HOST_IRQ_N` = 0, gdy (`IRQ_STAT` ∧ `IRQ_EN`) ≠ 0.

### 7.5 Zasoby (GW1N-9)

Pełny układ po syntezie i PnR (Gowin EDA 1.9.11.03, ograniczenia z `sfp_bridge.sdc`):

| Zasób | Użycie |
|---|---|
| logika (LUT, ALU) | 4483 z 8640 (52 %) |
| rejestry | 2833 z 6480 (44 %) |
| BSRAM | 7 z 26 (FIFO TX 2, FIFO RX 4, tablica dekodera 8b/10b 1) |
| SSRAM (RAM16) | 40 (bufor I2C, bufor `uart_bridge`) |
| rPLL / CLKDIV / DCS | 1 / 1 / 1 |
| `clk_sys` / `clk_host` | wymaganie 50 / 40 MHz, Fmax 56 / 44 MHz |

### 7.6 Prymitywy Gowin (VHDL)

Deklaracje komponentów: `library gw1n; use gw1n.components.all;` (biblioteka z Gowin EDA). Użyte prymitywy: `rPLL`, `CLKDIV`, `DCS`, `TLVDS_IBUF`, `TLVDS_OBUF`, `IDES8`, `OSER8`; bufory trójstanowe (xSPI IO, I2C) są wnioskowane z kodu. Pamięci (FIFO — SDPB, tablica dekodera — pROM) są wnioskowane z kodu; synteza potwierdza mapowanie na BSRAM.

Weryfikacja: GHDL, samosprawdzające testbenche VHDL-2008, przebiegi w GTKWave ([ADR 0003](adr/0003-weryfikacja-ghdl.md), [symulacja](vhdl/symulacja.md)); moduły z prymitywami Gowin z modelami `prim_sim.vhd`. Testbench `tb_cdr_os4x8`: odchyłka częstotliwości do ±1000 ppm, losowy jitter do ±0,3 UI (wymaganie: ±100 ppm, ±0,2 UI).

### 7.7 Tryb przezroczysty UART

Decyzja i uzasadnienie: [ADR 0006](adr/0006-tryb-uart-przezroczysty.md).

- Wybór trybu: zworka `MODE_SEL` (pin 10) próbkowana po resecie — otwarta: xSPI, zwarta do masy: UART; w trybie xSPI dodatkowo bit `UART_MODE` w `MODE_CTRL`.
- Piny J3 w trybie UART: `XSPI_IO0` = `UART_RX` (wejście), `XSPI_IO1` = `UART_TX` (wyjście), opcjonalnie `XSPI_IO2` = `UART_RTS_N` (wyjście), `XSPI_IO3` = `UART_CTS_N` (wejście); pozostałe linie xSPI w stanie wysokiej impedancji, `HOST_IRQ_N` = stan łącza.
- 8N1, domyślnie 115200 baud; inna prędkość (do ok. 3 Mbaud) przez `UART_DIV` w trybie xSPI.
- Pakietyzacja: ramka `TYPE = 0x01` po 64 bajtach lub po przerwie > 2 czasy znaku; odbiór: treść ramek `TYPE = 0x01` na `UART_TX`.
- Moduły: `uart_rx`, `uart_tx`, `uart_bridge` — [opis](vhdl/uart.md); `UART_DIV` = liczba taktów `clk_sys` na bit (434 = 115 200, minimum 8); RTS wstrzymuje nadawcę przy zapełnieniu FIFO TX; multipleksowanie pinów J3 i zegara strony hosta FIFO w `sfp_bridge_top` ([integracja](vhdl/top.md)); RTS (IO2) jest sterowany tylko przy `RTSCTS_EN`, w przeciwnym razie IO2 pozostaje w stanie wysokiej impedancji.

---

## 8. Biblioteka C dla STM32

Biblioteka `sfp_bridge` — [opis](firmware.md). C11, bez dynamicznej alokacji, prefiks `sfpb_`, konfiguracja przez `#define` w `sfpb_config.h`.

```
firmware/
  sfp_bridge/include/   sfp_bridge.h (API), sfpb_regs.h (komendy, rejestry),
                        sfpb_port.h (transport), sfpb_config_default.h
  sfp_bridge/config/    sfpb_config_template.h
  sfp_bridge/src/       sfp_bridge.c (transakcje, rejestry, ramki, zdarzenia,
                        liczniki, UART), sfpb_sfp.c (I2C, identyfikacja, DDM)
  sfp_bridge/port/      sfpb_port_ospi.c, sfpb_port_xspi.c, sfpb_port_qspi.c,
                        sfpb_port_spi.c (HAL + GPIO CS), sfpb_port_stm32.c
  examples/             example_bridge.c
  tests/                testy na PC z modelem mostka (make)
```

- Transport: `SFPB_TRANSPORT_OSPI` / `_XSPI` / `_QSPI` / `_SPI` (porty HAL, opcjonalnie DMA) lub `_CUSTOM` (struktura `sfpb_port_t`: transakcja xSPI, `HOST_RST_N`, zegar ms, opóźnienie). Port domyślny z makr konfiguracji; kolejne mostki — porty budowane w czasie wykonania.
- Funkcje: ramki (`sfpb_send()`, `sfpb_recv()` z obsługą obcięcia), rejestry i stan, przerwania (`sfpb_irq_notify()` z EXTI, `sfpb_process()` z wywołaniami zwrotnymi), liczniki, pamięć modułu SFP i identyfikacja, DDM w jednostkach SFF-8472 z kalibracją wewnętrzną i zewnętrzną, alarmy, tryb UART (`UART_DIV`, RTS/CTS, `UART_STATUS`), echo ramek, reset programowy i sprzętowy.
- Weryfikacja: testy na PC z modelem mostka na poziomie transakcji (207 sprawdzeń, kontrola każdej transakcji z tabelą komend 7.3), test mutacyjny (17 wariantów), kompilacja portów z nagłówkami STM32Cube dla L4R5 (OSPI), H563 (XSPI), F446 / L476 (QSPI), G0B1 (SPI).

---

## 9. Plan uruchomienia (bring-up)

1. Zasilanie, konfiguracja FPGA przez JTAG, odczyt `DONE` (programator przez AUX/JP2 lub pomiar na R6).
2. Bitstream `sfp_bridge` bez modułu SFP: `LED_LINK` zgaszona (stan DOWN), `SFP_TX_DIS` = 1, odpowiedź na `READ_ID` przez SPI (1 linia, 1–5 MHz).
3. **Tryb UART** (zworka `MODE_SEL` zwarta) na dwóch płytkach połączonych patchcordem, po stronie każdej adapter USB-UART i terminal: echo i transfer plików 115200 → 3 Mbaud. Pierwszy test łącza optycznego bez sterownika OCTOSPI.
4. Near-end loopback w FPGA (bez optyki): ramki TX → RX, liczniki błędów = 0.
5. Biblioteka STM32: SPI, potem QSPI i OCTOSPI z rosnącym zegarem do 40 MHz; pomiar marginesu próbkowania (t_V z datasheetu, 4.2).
6. Odczyt identyfikacji modułu SFP przez I2C (producent, numer części) i diagnostyki DDM.
7. **Niska prędkość linii (10–25 Mbaud)** — wariant diagnostyczny: wykres oczkowy na RD±.
8. 100 Mbaud, test BER (pseudolosowe ramki, liczniki, ≥ 10¹² bitów).
9. Test z tłumikiem optycznym i różnymi modułami (MM, SM, BiDi).
10. Opcjonalnie: 125 Mbaud i wyżej.

---

## 10. Punkty do potwierdzenia

Weryfikację schematu i PCB rev. A (reguły projektowe, zgodność z przydziałem pinów i INF-8074i, pary LVDS, pliki produkcyjne) opisuje [raport weryfikacji płytki](pcb-rev-a.md).

Rozstrzygnięcia z dokumentacji producenta są podane w treści wraz ze źródłem (przydział pinów i bilans zasilania QN48 — UG114; terminacja wewnętrzna tylko w banku 0 — UG289, rozdz. 3.3.2; HCLK w GW1N-9C — UG286, rozdz. 2.2; tryb konfiguracji QN48 — UG290, tab. 5-1). Do potwierdzenia pozostają:

| Punkt | Sposób potwierdzenia |
|---|---|
| Stackup JLC04161H-7628: grubości dielektryków i εr (5.3.2) | kalkulator impedancji JLCPCB przed zamówieniem |
| Footprint klatki SFP zgodny z wybraną klatką (otwory press-fit) | rysunek producenta klatki |
| Minimalna amplituda wejścia TD wybranego modułu względem VOD FPGA (500 mVppd min wg INF-8074i) | datasheet modułu, pomiar na prototypie |
| Moduł SFP bez wewnętrznego CDR (moduły z CDR nie pracują przy 100 Mbaud) | datasheet modułu, test |
| Background upgrade Flash przez JTAG w GW1N-9C | UG290, test |
| Parametry czasowe xSPI przy 40 MHz (t_SU, t_V; datasheet 4.2) | pomiar na prototypie z OCTOSPI |
| Pull-upy 4,7–10 kΩ na `SFP_TX_FAULT`, `SFP_LOS`, `SFP_MOD_ABS` (w rev. A wewnętrzne pull-upy FPGA) | kolejna rewizja PCB |
| Zapas czasowy `clk_sys`: Fmax 56 MHz przy celu 60 MHz z [ADR 0007](adr/0007-zegar-systemowy-50mhz.md) | przy zmianach logiki; warunek konieczny dla 125 Mbaud |

## 11. Dokumentacja źródłowa

Dokumenty producentów nie są częścią repozytorium; są dostępne u wydawców.

| Dokument | Wydawca | Zawartość |
|---|---|---|
| DS100 — GW1N series of FPGA Products Data Sheet | Gowin Semiconductor | zasoby, tabela obudów, LVDS DC, gearbox, PLL |
| UG103 — GW1N series Package & Pinout | Gowin Semiconductor | obudowy, opis pinów |
| UG114 — GW1N-9 Pinout | Gowin Semiconductor | przypisanie pinów QN48, pary true LVDS |
| UG286 — Gowin Clock User Guide | Gowin Semiconductor | rPLL, CLKDIV, DCS, HCLK |
| UG289 — Gowin Programmable IO User Guide | Gowin Semiconductor | TLVDS, IDES/OSER, terminacja |
| UG290 — Gowin FPGA Products Programming and Configuration Guide | Gowin Semiconductor | tryby konfiguracji, piny dedykowane |
| UG284 — GW1N series Schematic Manual | Gowin Semiconductor | zasilanie, odsprzęganie, piny konfiguracyjne |
| UG285 — Gowin BSRAM & SSRAM User Guide | Gowin Semiconductor | SDPB, pamięć rozproszona |
| SUG935 — Gowin Design Physical Constraints User Guide | Gowin Semiconductor | składnia .cst |
| INF-8074i — SFP Transceiver | SFF Committee (SNIA) | pinout złącza, sygnały sterujące, poziomy TD/RD, filtr zasilania |
| SFF-8472 — Management Interface for SFP+ | SFF Committee (SNIA) | mapa pamięci A0h / A2h, diagnostyka DDM |
| XAPP224, XAPP523 — Data Recovery, LVDS 4x Asynchronous Oversampling | AMD (Xilinx) | odzysk danych z nadpróbkowania |
