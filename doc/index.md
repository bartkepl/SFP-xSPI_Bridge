# SFP-xSPI Bridge

Moduł mostka **OCTOSPI / QUADSPI / SPI ↔ SFP** łączący dwa mikrokontrolery STM32 łączem światłowodowym punkt–punkt, bez stosu IP. Transmisja odbywa się własnym protokołem ramkowym z kodowaniem 8b/10b i programowym odzyskiem zegara (soft-CDR) w FPGA Gowin GW1N-UV9QN48C6/I5. Tryb przezroczysty UART przenosi strumień bajtów między dwoma portami szeregowymi bez sterownika.

```
STM32 <== xSPI ==> GW1N-9 <== LVDS ==> SFP ~~~ światłowód ~~~ SFP <==> GW1N-9 <==> STM32
```

## Dokumentacja

| Część | Zawartość |
|---|---|
| [Koncepcja konstrukcji](sfp-xspi-bridge-plan.md) | architektura, przydział pinów, zegary, warstwa fizyczna i PCB, moduły FPGA, komendy xSPI, rejestry, plan uruchomienia |
| [Interfejs hosta (datasheet)](datasheet/index.md) | wyprowadzenia, parametry czasowe, komendy xSPI, mapa rejestrów, tryb UART |
| [Biblioteka C (STM32)](firmware.md) | konfiguracja, porty HAL, API, weryfikacja |
| [Weryfikacja płytki rev. A](pcb-rev-a.md) | reguły projektowe, zgodność połączeń, pary LVDS, zasilanie, pliki produkcyjne |
| [Projekt FPGA](vhdl/index.md) | struktura projektu, konwencje kodu, symulacja, opisy modułów, wyniki syntezy |
| [Testy end-to-end](e2e/index.md) | dwa kompletne mostki połączone łączem, z przebiegami |
| [Decyzje (ADR)](adr/README.md) | rejestr decyzji projektowych z uzasadnieniem |

## Budowa dokumentacji

```
python -m mkdocs serve     # podgląd: http://127.0.0.1:8000
python -m mkdocs build     # statyczny serwis w site/
```

Wymagania: `mkdocs` 1.6 i `mkdocs-material` 9.x.
