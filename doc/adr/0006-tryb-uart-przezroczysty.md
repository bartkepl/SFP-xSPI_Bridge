# 0006. Tryb przezroczysty UART obok trybu xSPI

**Stan:** przyjęta · **Data:** 2026-10-08
**Dotyczy:** pcb, vhdl, firmware, doc

## Kontekst

Mostek jest projektowany jako urządzenie podrzędne hosta STM32 z interfejsem SPI/QSPI/OCTOSPI, wymagające sterownika i konfiguracji. Pożądany jest dodatkowy tryb „przezroczysty”: strumień bajtów podany na UART jednego mostka pojawia się na UART drugiego, bez konfiguracji i bez wiedzy urządzeń końcowych o łączu światłowodowym.

Tryb ten upraszcza także uruchomienie sprzętu: łącze światłowodowe można sprawdzić dwoma adapterami USB-UART i terminalem, przed napisaniem sterownika OCTOSPI.

## Rozważane warianty

**Wybór trybu:** (a) zworka na PCB + rejestr; (b) rejestr z zapisem w Flash użytkownika FPGA; (c) tylko zworka.
**Prędkość UART:** (a) 115200 domyślnie + rejestr; (b) stałe 115200; (c) zworki.
**Sterowanie przepływem:** (a) opcjonalne RTS/CTS; (b) brak.

## Decyzja

- **Wybór trybu — zworka + rejestr.** Pin 10 FPGA (`MODE_SEL`, dotychczas zapasowy, IOL15A/GCLKT_6) z pull-upem: zworka otwarta → tryb xSPI, zwarta do masy → tryb UART. Stan pinu jest próbkowany po resecie. W trybie xSPI rejestr `MODE_CTRL` pozwala przełączyć mostek na UART bez restartu.
- **Prędkość — 115200 8N1 domyślnie**, bez konfiguracji. W trybie xSPI rejestr `UART_DIV` ustawia inną prędkość, do ok. 3 Mbaud.
- **RTS/CTS — opcjonalne**, domyślnie wyłączone, włączane bitem w `MODE_CTRL`.
- **Piny w trybie UART** (złącze J3, bez zmian na PCB poza `MODE_SEL`):

| Sygnał | Pin J3 | Pin FPGA | Kierunek (z punktu widzenia FPGA) |
|---|---|---|---|
| `UART_RX` | 7 (`XSPI_IO0`) | 15 | wejście — dane od urządzenia |
| `UART_TX` | 8 (`XSPI_IO1`) | 16 | wyjście — dane do urządzenia |
| `UART_RTS_N` | 9 (`XSPI_IO2`) | 17 | wyjście — FPGA może przyjmować dane (aktywny niskim) |
| `UART_CTS_N` | 10 (`XSPI_IO3`) | 18 | wejście — urządzenie może przyjmować dane (aktywny niskim) |

  Pozostałe linie xSPI są w trybie UART w stanie wysokiej impedancji; `HOST_IRQ_N` sygnalizuje stan łącza (niski = łącze nieaktywne).

- **Pakietyzacja:** bajty z UART są zbierane w ramkę łącza ([ADR 0005](0005-protokol-lacza.md)) o typie `TYPE = 0x01` (strumień UART). Ramka jest wysyłana po zebraniu 64 bajtów albo po przerwie na linii RX dłuższej niż 2 czasy znaku. Strona odbiorcza wysyła treść ramek typu `0x01` na `UART_TX` w kolejności odbioru.
- **Współpraca trybów:** mostek w trybie xSPI przekazuje ramki `TYPE = 0x01` hostowi jak inne ramki i może je wysyłać, więc host STM32 po jednej stronie może komunikować się z urządzeniem UART po drugiej.

## Konsekwencje

- PCB: zworka lutowana między pinem 10 FPGA a masą oraz rezystor pull-up 10 kΩ do 3,3 V (dodatkowo wewnętrzny pull-up FPGA `PULL_MODE=UP`). Pin 10 przestaje być zapasowy.
- `.cst`: port `mode_sel` na pinie 10.
- Nowe moduły VHDL: `uart_rx`, `uart_tx`, `uart_bridge` (pakietyzator/depakietyzator, RTS/CTS), multipleksowanie pinów J3 w topie; szacunkowo ok. 300 LUT.
- Nowe rejestry CSR: `MODE_CTRL`, `UART_DIV`, `UART_STATUS`.
- Przy różnych prędkościach UART po obu stronach i wyłączonym RTS/CTS dane mogą zostać utracone przy przepełnieniu bufora strony wolniejszej; strata jest zliczana.
