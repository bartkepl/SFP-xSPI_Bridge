# 0004. Strategia resetu: reset synchroniczny w domenie, asynchroniczne załączenie i synchroniczne zwolnienie na wejściu domeny

**Stan:** przyjęta · **Data:** 2026-10-08
**Dotyczy:** vhdl

## Kontekst

Projekt ma trzy domeny zegarowe (`clk_spi` z pinu SCLK hosta, `clk_fast` i `clk_sys` z PLL). Źródła resetu są asynchroniczne względem tych zegarów: brak blokady PLL (`LOCK = 0`), pin `HOST_RST_N`, reset programowy z rejestru CTRL. Zegar domeny może być nieobecny w chwili żądania resetu (PLL nie zablokowany, host nie podaje SCLK).

Zwolnienie resetu asynchronicznego blisko zbocza zegara grozi stanem metastabilnym i wyjściem części przerzutników z resetu o takt później niż pozostałych (np. maszyna stanów w stanie nieprawidłowym).

## Rozważane warianty

1. **Reset asynchroniczny we wszystkich przerzutnikach** — działa bez zegara, ale zwolnienie jest asynchroniczne; ścieżki resetu nie są analizowane czasowo jak dane.
2. **Reset synchroniczny we wszystkich przerzutnikach, bez mostka** — wymaga zegara w chwili żądania i synchronizacji źródła; krótki impuls bez zegara jest tracony.
3. **Mostek resetu na wejściu domeny (asynchroniczne załączenie, synchroniczne zwolnienie) + reset synchroniczny wewnątrz domeny.**

## Decyzja

Wariant 3:

- Każda domena ma jeden moduł `reset_sync` (`vhdl/sfp_bridge/src/common/reset_sync.vhd`), sterowany asynchronicznym żądaniem `arst_n` (aktywny niskim). Wyjście `rst` załącza się natychmiast, także bez zegara, i zwalnia po `STAGES` zboczach zegara domeny.
- Wewnątrz domeny wszystkie moduły używają **resetu synchronicznego, aktywnego wysokim** (`if rst = '1' then` wewnątrz `rising_edge`).
- Rejestry, które nie wymagają resetu (potoki danych, wyjścia pamięci), nie są resetowane; ich stan po resecie jest nieistotny, bo towarzyszy im resetowany sygnał ważności (`valid`, `en`).
- Wartości początkowe sygnałów (`:= ...`) określają stan po konfiguracji FPGA (GW1N inicjuje przerzutniki zgodnie z nimi).

## Konsekwencje

- Ścieżki resetu wewnątrz domeny są zwykłymi ścieżkami synchronicznymi, objętymi analizą czasową.
- Moduły są niezależne od sposobu generowania resetu; testbenche sterują `rst` synchronicznie.
- Moduł `clk_rst` łączy źródła resetu (LOCK, `HOST_RST_N`, reset programowy) w `arst_n` i instancjonuje `reset_sync` dla każdej domeny.
- Mniejsza liczba resetowanych rejestrów zmniejsza obciążenie sieci resetu.
