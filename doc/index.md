# SFP-xSPI Bridge

Moduł mostka **OCTOSPI / QUADSPI / SPI ↔ SFP** łączący dwa mikrokontrolery STM32 łączem światłowodowym punkt–punkt, bez stosu IP. Transmisja odbywa się własnym protokołem ramkowym z kodowaniem 8b/10b i programowym odzyskiem zegara (soft-CDR) w FPGA Gowin GW1N-UV9QN48C6/I5.

```
STM32 <== xSPI ==> GW1N-9 <== LVDS ==> SFP ~~~ światłowód ~~~ SFP <==> GW1N-9 <==> STM32
```

## Dokumentacja

| Część | Zawartość |
|---|---|
| [Plan konstrukcji](sfp-xspi-bridge-plan.md) | architektura, przydział pinów, zegary, PCB, moduły VHDL, komendy xSPI, rejestry, biblioteka C, plan uruchomienia |
| [Interfejs hosta (datasheet)](datasheet/index.md) | komendy xSPI, mapa rejestrów, tryb UART, parametry czasowe |
| [Biblioteka C (STM32)](firmware.md) | konfiguracja, porty HAL, API, weryfikacja |
| [VHDL](vhdl/index.md) | struktura projektu FPGA, konwencje kodu, symulacja, opisy modułów |
| [Decyzje (ADR)](adr/README.md) | rejestr decyzji projektowych z uzasadnieniem |

## Budowa dokumentacji

```
python -m mkdocs serve     # podgląd: http://127.0.0.1:8000
python -m mkdocs build     # statyczny serwis w site/
```

Wymagania: `mkdocs` 1.6 i `mkdocs-material` 9.x.
