# Rejestr decyzji projektowych

Decyzje, których uzasadnienie przestałoby być oczywiste po kilku miesiącach — w szczególności wynikające z ograniczeń układu FPGA, obudowy, modułów SFP lub peryferiów STM32.

Zapis obejmuje **kontekst i konsekwencje**, nie samą treść decyzji. Decyzja bez zapisanego powodu bywa odwracana przez kogoś, kto nie zna ograniczenia, które ją wymusiło.

## Format

Plik `NNNN-krotki-opis.md`, numeracja od `0001`:

```
# NNNN. Tytuł decyzji

**Stan:** proponowana | przyjęta | zastąpiona przez NNNN · **Data:** RRRR-MM-DD
**Dotyczy:** pcb | vhdl | firmware | doc

## Kontekst
## Rozważane warianty
## Decyzja
## Konsekwencje
```

## Indeks

| Nr | Decyzja | Stan |
|---|---|---|
| [0001](0001-fpga-gw1n-9.md) | FPGA: GW1N-UV9QN48C6/I5 zamiast GW1N-UV4QN48C6/I5 | przyjęta |
| [0002](0002-terminacja-rx-zewnetrzna.md) | Terminacja toru RX zewnętrzna (2 × 49,9 Ω z biasem), wewnętrzna jako opcja awaryjna | przyjęta |
| [0003](0003-weryfikacja-ghdl.md) | Weryfikacja VHDL: GHDL, samosprawdzające testbenche VHDL-2008, przebiegi GTKWave | przyjęta |
| [0004](0004-strategia-resetu.md) | Reset synchroniczny w domenie, asynchroniczne załączenie i synchroniczne zwolnienie na wejściu domeny | przyjęta |
| [0005](0005-protokol-lacza.md) | Protokół łącza: ramka z CRC-32 bez retransmisji, XON/XOFF w sekwencji bezczynności | przyjęta |
| [0006](0006-tryb-uart-przezroczysty.md) | Tryb przezroczysty UART obok trybu xSPI (zworka MODE_SEL, 115200, opcjonalne RTS/CTS) | przyjęta |
| [0007](0007-zegar-systemowy-50mhz.md) | Zegar systemowy 50 MHz z serializerami IDES8/OSER8 | przyjęta |
