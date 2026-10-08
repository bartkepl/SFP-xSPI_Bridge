# SFP-xSPI Bridge

Moduł mostka **OCTOSPI / QUADSPI / SPI ↔ SFP** do łączenia dwóch mikrokontrolerów (STM32) łączem światłowodowym punkt–punkt, bez stosu IP. Transmisja odbywa się własnym, lekkim protokołem ramkowym z kodowaniem 8b/10b i programowym odzyskiem zegara (soft-CDR) w małym FPGA Gowin. Dodatkowy tryb przezroczysty UART przenosi strumień bajtów między dwoma portami szeregowymi bez konfiguracji.

```
STM32 <== xSPI ==> GW1N-9 <== LVDS ==> SFP ~~~ światłowód ~~~ SFP <==> GW1N-9 <==> STM32
```

Projekt open-hardware / open-source, tworzony hobbystycznie.

## Założenia

| Element | Wybór |
|---|---|
| FPGA | Gowin GW1N-UV9QN48C6/I5 (GW1N-9, wersja C), QN48 — zob. [ADR 0001](doc/adr/0001-fpga-gw1n-9.md) |
| Prędkość linii | 100 Mbaud (8b/10b → 80 Mbit/s, ok. 9 MB/s danych użytecznych) |
| Interfejs hosta | SPI (1-1-1), QSPI (1-1-4 / 1-4-4), OCTOSPI (1-1-8 / 1-8-8), SDR, do 50 MHz |
| Tryb przezroczysty | UART 8N1, domyślnie 115200 baud (do ok. 3 Mbaud), opcjonalnie RTS/CTS; wybór zworką `MODE_SEL` — [ADR 0006](doc/adr/0006-tryb-uart-przezroczysty.md) |
| Protokół łącza | ramki z CRC-32, bez retransmisji (błędy zgłaszane hostowi), kontrola przepływu XON/XOFF — [ADR 0005](doc/adr/0005-protokol-lacza.md) |
| Strona optyczna | moduł SFP (INF-8074i) bez wewnętrznego CDR: 100BASE-FX / OC-3 lub 1000BASE-X (MM/SM, duplex lub BiDi); SFP+ nieobsługiwane |
| Zarządzanie SFP | I2C master w FPGA: EEPROM (A0h), DDM (A2h), sygnały TX_DISABLE / TX_FAULT / LOS / MOD_ABS |
| Zasilanie | jedno 3,3 V, ok. 0,5 A |
| Narzędzia | KiCad 10 (PCB), Gowin EDA (VHDL-2008), GHDL + GTKWave (symulacja), MkDocs (dokumentacja), biblioteka C dla STM32 |

Pełny opis architektury, przydziału pinów, zegarów, warstwy fizycznej, modułów VHDL, zestawu komend xSPI, mapy rejestrów i planu uruchomienia: [`doc/sfp-xspi-bridge-plan.md`](doc/sfp-xspi-bridge-plan.md). Decyzje projektowe: [`doc/adr/`](doc/adr/README.md). Opisy modułów VHDL i symulacji: [`doc/vhdl/`](doc/vhdl/index.md).

Dokumentacja jako serwis MkDocs:

```
python -m mkdocs serve     # podgląd: http://127.0.0.1:8000
```

## Struktura repozytorium

```
doc/                    — plan konstrukcji, ADR-y, opisy modułów VHDL, dokumentacja producentów (MkDocs)
pcb/                    — projekt płytki (KiCad), reguły DRC
vhdl/constraints/       — przydział pinów (.cst) i ograniczenia czasowe (.sdc)
vhdl/sfp_bridge/        — projekt docelowy FPGA (Gowin EDA)
vhdl/sfp_bridge_testled/ — projekt testowy: miganie LED
vhdl/sim/               — testbenche (GHDL), skrypty uruchomieniowe, widoki GTKWave
firmware/               — biblioteka C dla STM32 (sfp_bridge) i przykłady
mkdocs.yml              — konfiguracja serwisu dokumentacji
```

## Status

| Część | Stan |
|---|---|
| Schemat | rev. A gotowy; do dodania zworka `MODE_SEL` (pin 10) dla trybu UART |
| PCB | w toku (4 warstwy, JLCPCB JLC04161H-7628) |
| FPGA | etapy 1–4 z 10: synchronizatory, CRC-32, kod 8b/10b, FIFO dwuzegarowe, ramkowanie łącza, warstwa fizyczna (IDES8/OSER8), odzysk danych (soft-CDR) i wyrównanie symboli — z testbenchami (PASS), w tym pełna pętla łącza dwóch końców z odchyłką 200 ppm i jitterem; kolejny etap: sterowanie łączem (`link_ctrl`) — [stan modułów](doc/vhdl/index.md) |
| Firmware | nierozpoczęte |

Otwarte punkty: rozdział 10 planu.

## Licencja

Projekt udostępniony na licencji [MIT](LICENSE).
