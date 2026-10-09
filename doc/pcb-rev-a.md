# Płytka rev. A — weryfikacja projektu

Raport z weryfikacji schematu i PCB rev. A przed wykonaniem prototypu. Zakres: zgodność połączeń z przydziałem pinów FPGA i dokumentacją elementów, reguły projektowe (DRC, ERC), prowadzenie par LVDS, zasilanie i odsprzęganie, wykonalność produkcyjna oraz komplet plików produkcyjnych.

## 1 Opis płytki

| Parametr | Wartość |
|---|---|
| Wymiary | 68,0 × 29,3 mm, 4 otwory montażowe M2,5 (GND) |
| Stos | 4 warstwy, 1,6 mm, JLC04161H-7628: L1 sygnały i pary LVDS, L2 GND, L3 +3V3, L4 sygnały i wylewka GND |
| Schemat | 3 arkusze: główny, `EXT_IO` (FPGA, złącze hosta, programowanie), `SFP` (klatka, filtry, terminacja RX, generator, diody) |
| Elementy | 53: U1 GW1N-UV9QN48C6/I5, J1 klatka SFP, J2 TC2050, J3 2 × 10 / 1,27 mm, Y1 25 MHz, L1/L2 1 µH, D1 TVS, D2/D3 LED, JP1–JP3, 17 rezystorów, 19 kondensatorów, H1–H4 |
| Zasilanie | 3,3 V z hosta (J3, piny 1–2), bez stabilizatora; TVS D1 przy złączu |
| Montaż | ręczny; elementy na obu stronach (na dolnej: 15 elementów pasywnych 0603 — kondensatory odsprzęgające i filtra SFP, część rezystorów) |

## 2 Reguły projektowe

**DRC** (wszystkie poziomy, z ponownym wypełnieniem stref i kontrolą zgodności ze schematem): 0 błędów, 0 niepołączonych elementów, 0 rozbieżności schemat–PCB. Ostrzeżenia:

| Ostrzeżenie | Liczba | Ocena |
|---|---|---|
| `silk_overlap` — nakładające się opisy D2/D3 i R1/JP2 | 6 | kosmetyka nadruku |
| `silk_edge_clearance` — obrys J1 przycięty krawędzią płytki | 3 | wynika z wysięgu klatki poza krawędź; bez wpływu |
| `lib_footprint_mismatch` — U1 | 1 | zamierzone: pole EPAD z przelotkami 0,3 mm zamiast 0,2 mm z biblioteki |

**ERC:** 0 błędów; 3 ostrzeżenia `lib_symbol_mismatch` (symbole zworek lutowanych różnią się od biblioteki) i 1 `multiple_net_names` (GND i EPAD U1 na jednym węźle — zamierzone, EPAD jest masą).

## 3 Połączenia

### 3.1 FPGA

Wszystkie przydziały `IO_LOC` z `vhdl/constraints/sfp_bridge.cst` porównano z sieciami padów U1 w PCB: 25 portów (pary różnicowe po pinie A), **zgodność 100 %**, w tym odwrócona para RD (`sfp_rd_n` na pinie 43, `sfp_rd_p` na 42, kompensowana w `rx_phy`). Bitstream jest budowany z tego samego pliku `.cst`.

| Obszar | Podstawa | Wynik |
|---|---|---|
| Zasilanie U1: VCC 12, 37; VCCX 36; VCCIO 1, 25; VSS 2, 26, EPAD | UG114 (QN48) | zgodne |
| Konfiguracja: MODE (48) 1 kΩ do GND (AUTOBOOT); JTAGSEL_N, RECONFIG_N, DONE — 10 kΩ do 3,3 V; TCK 4,7 kΩ do GND | UG290 (rys. 7-1, tab. 7-3) | zgodne |
| `CLK_25M` na dedykowanym wejściu PLL (35) | UG114, UG286 | zgodne |
| `MODE_SEL` (10): 10 kΩ do 3,3 V (R16), JP3 do GND | [ADR 0006](adr/0006-tryb-uart-przezroczysty.md) | zgodne |

### 3.2 Moduł SFP

| Obszar | Podstawa | Wynik |
|---|---|---|
| Złącze J1, 20 pinów: VeeT 1/17/20, VeeR 9/10/11/14, TD± 18/19, RD± 13/12, VccT 16, VccR 15, sygnały 2–8 | INF-8074i, rys. 3 | zgodne |
| Filtr zasilania: 2 × 1 µH, 0,1 µF przy VccT i VccR, 10 µF na VccR, 10 µF + 0,1 µF po stronie 3,3 V | INF-8074i, rys. 2A | zgodne |
| `SFP_TX_DIS`: pull-up 4,7 kΩ do 3,3 V (R17) — laser wyłączony w czasie konfiguracji FPGA | INF-8074i, rys. 2B | zgodne |
| `SFP_SCL`, `SFP_SDA`: pull-up 10 kΩ (R4, R3) | INF-8074i (4,7–10 kΩ) | zgodne |
| `RATE_SELECT`: 10 kΩ do GND (R8) | [koncepcja](sfp-xspi-bridge-plan.md), 5.1 | zgodne |
| `SFP_TX_FAULT`, `SFP_LOS`, `SFP_MOD_ABS`: wewnętrzne pull-upy FPGA zamiast 4,7–10 kΩ na płytce | INF-8074i, rys. 2B | odstępstwo rev. A — sygnały wolne i filtrowane (50 µs / 10 ms); rezystory w kolejnej rewizji |
| Terminacja RX: R9/R10 49,9 Ω przy pinach 42/43, Vbias 1,20 V (R11 2,1 kΩ / R12 1,2 kΩ, C6) | [ADR 0002](adr/0002-terminacja-rx-zewnetrzna.md) | zgodne; odcinek do odbiornika ok. 3,7 mm (wartość projektowa ≤ 2 mm) — pomijalne przy 100 Mbaud |

### 3.3 Złącza hosta i programowania

- J3 (2 × 10, 1,27 mm): 3,3 V na pinach 1–2, GND 3/5/15/19/20, magistrala xSPI, `HOST_IRQ_N`, `HOST_RST_N` — zgodnie z [koncepcją](sfp-xspi-bridge-plan.md), 5.5.
- J2 (TC2050): układ ARM Cortex 10-pin; AUX przez R7 1 kΩ i JP2 na `JTAGSEL_N` lub `DONE`; nRESET przez JP1 (domyślnie rozwarta) na `RECONFIG_N` — zgodnie z 5.6.

Elementy, dla których pinout oceniono według konwencji obudowy (bez porównania z kartą katalogową w tej weryfikacji): Y1 (generator 3225: 1 EN, 2 GND, 3 OUT, 4 VDD), D1 (SOD-123FL, katoda do 3,3 V), D2/D3 (anoda przez 1 kΩ do 3,3 V, ok. 1,3 mA).

## 4 Pary LVDS

| Para | Długość ścieżek P / N | Różnica | Szerokość / odstęp | Warstwa |
|---|---|---|---|---|
| TD (U1 34/33 → J1 18/19) | 9,43 / 9,76 mm | 0,33 mm | 0,20 / 0,20 mm | F.Cu, bez przelotek |
| RD (J1 13/12 → U1 42/43) | 11,37 / 11,71 mm | 0,33 mm | 0,20 / 0,20 mm | F.Cu, bez przelotek |

Obie pary w całości nad ciągłą płaszczyzną GND (L2). Różnica długości mieści się w regule 0,5 mm (`pcb/SFP_xSPI_Bridge.kicad_dru`, liczona wewnątrz pary); przy UI = 10 ns odpowiada ok. 2 ps i jest pomijalna. Odstęp od innych sieci i wylewek zgodny z regułą 0,5 mm; odcinki niesprzężone przy padach U1, J1 i rezystorach terminacji mieszczą się w limicie 2 mm.

## 5 Zasilanie i odsprzęganie

- Tor 3,3 V: J3 → ścieżka 1,0 mm (F.Cu) i 0,6–0,8 mm (B.Cu) → przelotki do płaszczyzny L3. Pobór szacowany 0,45 A (moduł SFP do 300 mA) — zapas kilkukrotny.
- Każdy pin zasilania U1 ma kondensator 100 nF w odległości 1,5–2,3 mm (C1, C2, C4, C5, C19); Y1 — C12 (3,4 mm); VccT / VccR — C7 / C8 (2,6 mm).
- Płaszczyzna L2 (GND) ciągła poza otworami przelotek. W L3 (+3V3) ścieżki VccR/VccT tworzą szczelinę pod obszarem złącza SFP; nad nią przebiegają wyłącznie wolne sygnały (I2C, LOS, MOD_ABS).
- Przelotki: 494 (490 × 0,6/0,3 mm, 4 × 0,45/0,3 mm), w tym 437 GND — zszycie wylewek L1/L4 z płaszczyzną L2 na całej powierzchni płytki i wzdłuż par LVDS.
- EPAD U1: 16 przelotek 0,3 mm do GND; moc FPGA < 0,5 W, brak innych źródeł ciepła.
- `CLK_25M` (9,7 mm): jedna para przelotek, odcinek na B.Cu; ścieżka powrotna przez płaszczyznę +3V3 odsprzęganą w pobliżu. Przy 25 MHz bez wpływu na działanie.

## 6 Wykonalność produkcyjna

| Parametr | Wartość | Próg technologii (JLCPCB, 4 warstwy) |
|---|---|---|
| Ścieżka / odstęp min. | 0,20 / 0,20 mm | 0,09 / 0,09 mm |
| Otwór min. | 0,30 mm | 0,30 mm bez dopłaty |
| Przelotka min. | 0,45 / 0,30 mm | 0,4–0,45 / 0,3 mm bez dopłaty |
| Via-in-pad | EPAD, bez wypełniania | bez opcji płatnych |
| Odstęp miedzi od krawędzi | ≥ 0,5 mm | 0,2–0,3 mm |

- Klatka J1 wystaje poza krawędź płytki (montaż klatki do panelu urządzenia); wysięg należy porównać z rysunkiem zamawianej klatki ([koncepcja](sfp-xspi-bridge-plan.md), rozdz. 10).
- Brak fiducjali i punktów testowych — zbędne przy montażu ręcznym.

## 7 Pliki produkcyjne

| Plik | Zawartość |
|---|---|
| `prod/SFP_xSPI_Bridge.zip` | Gerbery 4 warstw miedzi, maski, pasty, nadruki, obrys; wiercenia PTH i NPTH (13 plików) |
| `prod/sch/SFP_xSPI_Bridge.pdf` | schemat |
| `prod/pcb/SFP_xSPI_Bridge.pdf` | rysunek PCB |
| `prod/ibom/SFP_xSPI_Bridge_ibom.html` | interaktywny BOM do montażu ręcznego |
| `media/SFP_xSPI_Bridge_{angle,front,back}.png` | rendery 3D |

Pliki generują jobsety KiCad (`pcb/gen_gerber.kicad_jobset`, `gen_prod.kicad_jobset`, `gen_media.kicad_jobset`) z bieżącej wersji schematu i PCB.

## 8 Wynik

Płytka rev. A jest gotowa do wykonania. Połączenia FPGA są zgodne z plikiem ograniczeń bitstreamu, połączenia modułu SFP i filtr zasilania — z INF-8074i; pary LVDS spełniają reguły projektowe; DRC i ERC nie zgłaszają błędów.

Uwagi do kolejnej rewizji (nie blokują rev. A):

1. Pull-upy 4,7–10 kΩ na `SFP_TX_FAULT`, `SFP_LOS`, `SFP_MOD_ABS`.
2. Uporządkowanie nadruku (D2/D3, R1/JP2); nazwa i rewizja płytki na nadruku oraz w tabliczkach arkuszy.
3. Model 3D klatki SFP i numery katalogowe (MPN) w polach symboli.
4. Złącze hosta z kluczem (box header 1,27 mm) albo wyraźne oznaczenie pinu 1.
5. Terminacja RX bliżej pinów 42/43, `CLK_25M` w całości na F.Cu.
