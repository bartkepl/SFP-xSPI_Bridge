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
