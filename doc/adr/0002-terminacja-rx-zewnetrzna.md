# 0002. Terminacja toru RX zewnętrzna, wewnętrzna jako opcja awaryjna

**Stan:** przyjęta · **Data:** 2026-10-08
**Dotyczy:** pcb, vhdl

## Kontekst

Wejście true LVDS wymaga terminacji różnicowej 100 Ω. GW1N-9 ma programowalną terminację 100 Ω wyłącznie w banku 0 (UG289, rozdz. 3.3.2; atrybut `DIFF_RESISTOR`, akceptowany przez Gowin EDA tylko dla pinów banku 0).

Wyjście RD modułu SFP jest typu CML i jest sprzężone pojemnościowo. Po stronie odbiornika wymagane jest zewnętrzne ustalenie napięcia wspólnego (ok. 1,2 V, w zakresie VCM 0,05–2,1 V wejścia FPGA) niezależnie od sposobu terminacji.

## Rozważane warianty

1. **Terminacja wewnętrzna** (`DIFF_RESISTOR=ON`) i bias przez 2 × 10 kΩ do Vbias. Brak odcinka linii między terminacją a odbiornikiem. Wartość i tolerancja rezystancji wewnętrznej nie są specyfikowane w DS100. Wiąże tor RX z bankiem 0.
2. **Terminacja zewnętrzna** 2 × 49,9 Ω 1% (0402) z węzłem środkowym do Vbias i kondensatorem 100 nF do masy. Jeden układ realizuje terminację i bias; kondensator tłumi zakłócenia wspólne. Znana tolerancja. Odcinek linii od rezystorów do pinów ok. 1–2 mm, pomijalny przy czasach narastania 100–200 ps i 100 Mbaud.

## Decyzja

Wariantem podstawowym jest **terminacja zewnętrzna** (wariant 2). W `.cst` obowiązuje `DIFF_RESISTOR=OFF`.

Para RD pozostaje w banku 0 (piny 43/42), aby zachować terminację wewnętrzną jako opcję awaryjną bez zmiany płytki: rezystory 49,9 Ω niemontowane, footprinty 2 × 10 kΩ do Vbias zmontowane, `DIFF_RESISTOR=ON`.

## Konsekwencje

- Płytka zawiera 2 × 49,9 Ω (montowane) i 2 × 10 kΩ (DNP) przy pinach 42/43 oraz dzielnik Vbias z kondensatorem.
- Jednoczesne użycie obu terminacji daje ok. 50 Ω i jest niedopuszczalne.
- Tor RX może zostać przeniesiony poza bank 0 (alternatywy w planie, tabela 3.3); wtedy atrybut `DIFF_RESISTOR` musi zostać usunięty z `.cst`, a opcja awaryjna przestaje istnieć.
