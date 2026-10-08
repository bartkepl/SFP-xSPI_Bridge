# 0007. Zegar systemowy 50 MHz z serializerami IDES8/OSER8

**Stan:** przyjęta · **Data:** 2026-10-08
**Dotyczy:** vhdl, doc

## Kontekst

Plan wstępny zakładał `clk_fast` = 200 MHz (FCLK serializerów) i `clk_sys` = 100 MHz z IDES4 (4 próbki na takt, 4× nadpróbkowanie przy 100 Mbaud). Próbne syntezy pierwszych modułów na GW1N-9C wykazały:

| Blok | Fmax |
|---|---|
| CRC-32 + koder/dekoder 8b/10b + synchronizatory | 125,7 MHz |
| `async_fifo` 4096 × 8 (po optymalizacji ścieżek) | 101,3 MHz |
| tor znakowy: FIFO TX, framer, koder, dekoder, deframer, FIFO RX | 70 MHz |

Ścieżki krytyczne (porównania i liczniki 13-bitowe, logika decyzyjna za dekoderem, funkcja kodera) mają po 9–14 ns — to granica szybkości logiki GW1N-9, a nie pojedyncze wąskie gardło. Jednocześnie logika znakowa wykonuje pracę raz na symbol, czyli co 100 ns (10 bitów przy 100 Mbaud): przy `clk_sys` = 100 MHz raz na 10 taktów.

## Rozważane warianty

1. **`clk_sys` = 100 MHz, IDES4** — wymaga przebudowy framera, deframera, kodera i dekodera na potoki wielotaktowe; zapas czasowy nadal minimalny; przy 125 Mbaud (`clk_sys` = 125 MHz) praktycznie nieosiągalne.
2. **`clk_sys` = 50 MHz, IDES8/OSER8** — serializery 1:8 przy FCLK 200 MHz (DDR, 400 Msps) i PCLK = FCLK/4 = 50 MHz (UG289, rozdz. 4.2.4); 8 próbek na takt = 2 bity na takt przy 4× nadpróbkowaniu.

## Decyzja

Wariant 2:

| Zegar | Źródło | Częstotliwość | Zastosowanie |
|---|---|---|---|
| `clk_fast` | rPLL z `CLK_25M` | 200 MHz | FCLK `IDES8` / `OSER8` (sieć HCLK) |
| `clk_sys` | `CLKDIV` (`DIV_MODE = "4"`) z `clk_fast` | 50 MHz | całe łącze (CDR, wyrównanie, 8b/10b, framer, CRC, FIFO strona łącza), I2C, UART, CSR |
| `clk_spi` | pin SCLK hosta | ≤ 50 MHz | slave xSPI, strona hosta FIFO |

- Odbiór: `TLVDS_IBUF` → `IDES8` → 8 próbek na takt `clk_sys`; CDR wydaje nominalnie 2 bity na takt, przy różnicy częstotliwości 1 lub 3 bity.
- Nadawanie: `OSER8` z każdym bitem powielonym 4× (2 bity na takt `clk_sys`) → `TLVDS_OBUF`.
- Symbol 8b/10b (10 bitów) przypada na 5 taktów `clk_sys`; moduły znakowe (`tx_framer`, `rx_deframer`) wymagają co najmniej 4 taktów między znakami.
- Kryterium czasowe dla wszystkich modułów domeny `clk_sys`: Fmax ≥ 50 MHz z zapasem (cel ≥ 60 MHz).

## Konsekwencje

- Zapas czasowy logiki łącza: 70 MHz / 50 MHz (tor znakowy), 101 MHz / 50 MHz (FIFO) — bez restrukturyzacji gotowych modułów.
- Przepustowość, częstotliwość próbkowania (4×), PCB i oprogramowanie bez zmian.
- CDR przetwarza 8 próbek na takt i oddaje zmienną liczbę bitów (1–3); wyrównanie do comma przyjmuje strumień bitów o zmiennej szerokości.
- Przy 125 Mbaud: `clk_fast` = 250 MHz, `clk_sys` = 62,5 MHz (VCO 1000 MHz) — w zasięgu logiki.
- Moduł `cdr_os4` nosi nazwę `cdr_os4x8` (4× nadpróbkowanie, 8 próbek na takt).
