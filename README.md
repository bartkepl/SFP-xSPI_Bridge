# SFP-xSPI Bridge

Moduł mostka **OCTOSPI / QUADSPI / SPI ↔ SFP** do łączenia dwóch mikrokontrolerów (STM32) łączem światłowodowym punkt–punkt, bez stosu IP. Transmisja odbywa się własnym, lekkim protokołem ramkowym z kodowaniem 8b/10b i programowym odzyskiem zegara (soft-CDR) w małym FPGA Gowin.

```
STM32 <== xSPI ==> GW1N-4/9 <== LVDS ==> SFP ~~~ światłowód ~~~ SFP <==> GW1N-4/9 <==> STM32
```

Projekt open-hardware / open-source, tworzony hobbystycznie.

## Założenia

| Element | Wybór |
|---|---|
| FPGA | Gowin GW1N-UV4QN48C6/I5 (alternatywnie GW1N-UV9QN48 — ta sama obudowa) |
| Prędkość linii | 100 Mbaud (8b/10b → 80 Mbit/s, ok. 9 MB/s danych użytecznych) |
| Interfejs hosta | SPI (1-1-1), QSPI (1-1-4 / 1-4-4), OCTOSPI (1-1-8 / 1-8-8), SDR, do 50 MHz |
| Strona optyczna | dowolny moduł SFP 1.25G bez wewnętrznego CDR (MM/SM, duplex lub BiDi) |
| Zarządzanie SFP | I2C master w FPGA: EEPROM (A0h), DDM (A2h), sygnały TX_DISABLE / TX_FAULT / LOS / MOD_ABS |
| Zasilanie | jedno 3,3 V, ok. 0,5 A |
| Narzędzia | KiCad (PCB), Gowin EDA (VHDL-2008), GHDL (symulacja), biblioteka C dla STM32 |

Pełny opis architektury, przydziału pinów, zegarów, warstwy fizycznej, modułów VHDL, zestawu komend xSPI, mapy rejestrów i planu uruchomienia: [`doc/sfp-xspi-bridge-plan.md`](doc/sfp-xspi-bridge-plan.md).

## Struktura repozytorium

```
doc/        — dokumentacja projektowa, rejestr decyzji (doc/adr)
pcb/        — projekt płytki (KiCad)
vhdl/       — projekt FPGA (Gowin EDA, VHDL-2008), constraints, testbenche
firmware/   — biblioteka C dla STM32 (sfp_bridge) i przykłady
```

## Status

Faza koncepcyjna — przed rysowaniem schematu. Otwarte punkty do weryfikacji w dokumentacji Gowin wymienia rozdział 10 planu.

## Licencja

Projekt udostępniony na licencji [MIT](LICENSE).
