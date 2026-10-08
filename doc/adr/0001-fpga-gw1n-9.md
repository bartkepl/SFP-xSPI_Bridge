# 0001. FPGA: GW1N-UV9QN48C6/I5 zamiast GW1N-UV4QN48C6/I5

**Stan:** przyjęta · **Data:** 2026-10-08
**Dotyczy:** pcb, vhdl

## Kontekst

Plan wstępny zakładał GW1N-UV4QN48C6/I5 (GW1N-4), z GW1N-UV9QN48C6/I5 (GW1N-9) jako alternatywą w tej samej obudowie QN48. Wymagania wobec układu:

- obudowa QN48 (6 × 6 mm) lub porównywalna,
- jedno zasilanie 3,3 V (wersja UV),
- co najmniej jedna para z wyjściem true LVDS (TD) i jedna para wejściowa LVDS z logiką IDES4 (RD),
- dostępność w detalu u co najmniej jednego dystrybutora (LCSC, Mouser, DigiKey),
- możliwość syntezy w dostępnych narzędziach.

Stan na 2026-10-08:

| Kryterium | GW1N-UV4QN48C6/I5 | GW1N-UV9QN48C6/I5 |
|---|---|---|
| LUT4 / FF | 4608 / 3456 | 8640 / 6480 |
| BSRAM | 10 × 18 kbit | 26 × 18 kbit, tryb dual-port (wersja C) |
| Pary true LVDS w QN48 | 9 | 12 |
| PLL VCO (C6/I5) | 400–1000 MHz | 400–1200 MHz |
| Gowin EDA Education | nieobsługiwany | obsługiwany (GW1N-9C) |
| Mouser | ok. 405 szt., ok. 19,9 USD / 1 szt. | ok. 90 szt., ok. 33,4 USD / 1 szt. |
| LCSC, DigiKey | brak | brak |

## Rozważane warianty

1. **GW1N-UV4QN48C6/I5** — tańszy o ok. 13 USD, większy zapas magazynowy. Wymaga pełnej licencji Gowin EDA. Przy 125 Mbaud VCO pracuje na granicy zakresu (1000 MHz).
2. **GW1N-UV9QN48C6/I5** — droższy, mniejszy zapas magazynowy u jedynego dystrybutora. Syntezowalny w wersji Education, większy zapas zasobów i par LVDS.
3. **GW1NSR-LV4CQN48PC6/I5** (dostępny w LCSC) — wymaga osobnego zasilania rdzenia 1,2 V, zawiera niepotrzebny rdzeń Cortex-M3 i PSRAM. Odrzucony.

## Decyzja

Układem docelowym jest **GW1N-UV9QN48C6/I5** (w Gowin EDA: GW1N-9C, `-device_version C`).

## Konsekwencje

- Przydział pinów oparty jest na UG114 (GW1N-9 Pinout), nie na UG105. Płytka zaprojektowana pod GW1N-9 **nie** przyjmuje GW1N-4 bez weryfikacji pinoutu.
- Ograniczenie GW1N-4 dotyczące pinów `IOL10`/`IOR10` bez IO logic nie obowiązuje.
- BSRAM dual-port jest dostępny, ale FIFO pozostaje w trybie semi-dual port dla przenośności. Wersja C nie obsługuje szerokości danych BSRAM 1 i 2 bit (DS100).
- Wewnętrzna terminacja 100 Ω wejścia różnicowego jest dostępna wyłącznie w banku 0 (UG289, rozdz. 3.3.2).
- Prędkość linii 125 Mbaud mieści się w zakresie VCO z zapasem (VCO = 1000 MHz przy granicy 1200 MHz).
- Mouser jest jedynym źródłem; zakup egzemplarzy prototypowych należy wykonać z zapasem.
