# Interfejs hosta: `xspi_slave`

Plik: `vhdl/sfp_bridge/src/host/xspi_slave.vhd` (z pakietem `xspi_pkg`) · testbench: `vhdl/sim/tb/tb_xspi_slave.vhd`

Slave SPI / Quad-SPI / Octal-SPI mostka ([ADR 0009](../adr/0009-interfejs-hosta.md); [plan, rozdz. 7.3](../sfp-xspi-bridge-plan.md)): SDR, tryb 0, najstarszy bit pierwszy, SCLK ≤ 40 MHz. Instrukcja i adres zawsze na IO0; w formatach 1-x-1 dane od hosta na IO0, do hosta na IO1; w formatach 4- i 8-liniowych na IO3..0 / IO7..0 (najpierw starszy półbajt).

## Komendy

| Opkod | Nazwa | Format | Dummy | Działanie |
|---|---|---|---|---|
| `0x9F` | READ_ID | 1-0-1 | 0 | `0x5B 0x5F` (ID), wersja, `0x00`, dalej `0x00` |
| `0x05` | READ_STATUS | 1-0-1 | 0 | `status_fast`, powtarzany |
| `0x0B` | READ_REG | 1-1-1 | 8 | rejestry od adresu (zatrzaśnięte przy opadnięciu CS), auto-inkrementacja |
| `0x02` | WRITE_REG | 1-1-1 | 0 | do `WR_MAX` = 8 bajtów od adresu do bufora zapisu |
| `0x12` / `0x32` / `0x82` | TX_WRITE_1 / _4 / _8 | 1-0-x | 0 | bajty ramki do FIFO TX |
| `0x13` / `0x6B` / `0x8B` | RX_READ_1 / _4 / _8 | 1-0-x | 8 | bajty ramek z FIFO RX |
| `0x66` | TX_ABORT | 1-0-0 | — | porzucenie niezatwierdzonej ramki |

Inne opkody: transakcja ignorowana do podniesienia CS.

## Interfejs

| Port | Kierunek | Opis |
|---|---|---|
| `clk` | in | `clk_host`: SCLK w trybie xSPI, `clk_sys` w resecie ([`host_clk`](../sfp-xspi-bridge-plan.md)) |
| `rst` | in | reset synchroniczny strony hosta (wymaga taktów zegara — w resecie `clk_host` = `clk_sys`) |
| `cs_n` | in | CS = 1: asynchroniczny reset maszyny stanów transakcji |
| `io_in`, `io_out`, `io_oe` | in / out | linie IO7..0; bufory trójstanowe w top-level |
| `reg_addr`, `reg_rdata` | out / in | adres i wartość z zatrzaśniętej przestrzeni rejestrów (`csr_regs`) |
| `status_fast` | in | zatrzaśnięty `STATUS_FAST` |
| `wr_addr`, `wr_data`, `wr_cnt`, `wr_txn` | out | bufor `WRITE_REG`: adres, bajty, liczba; `wr_txn` przełącza się na początku każdego `WRITE_REG`; wartości stabilne po podniesieniu CS |
| `tx_wr`, `tx_data`, `tx_commit`, `tx_commit_prev`, `tx_abort` / `tx_full` | out / in | strona zapisu FIFO TX (`async_fifo`: `PUB_STABLE`, `WR_FALLING`) |
| `rx_rd` / `rx_data`, `rx_valid`, `rx_empty` | out / in | strona odczytu FIFO RX (`RD_FALLING`) |
| `ev_tx_ovf_t` | out | przełącza się przy każdym bajcie utraconym na pełnym FIFO TX |

## Struktura czasowa

- Piny są zatrzaskiwane w `io_q` na zboczu narastającym SCLK. Cała logika — maszyna stanów, zapis FIFO TX, odczyt FIFO RX, przygotowanie porcji wyjściowej — pracuje na następującym zboczu opadającym. W trybie 0 po każdym zboczu narastającym następuje opadające (SCLK w spoczynku ma stan niski), więc ostatni bajt transakcji jest przetwarzany bez dodatkowych taktów.
- Wyjścia zmieniają się na zboczu opadającym. Przy SCLK = 40 MHz zalecane jest przesunięcie próbkowania po stronie STM32 (`SSHT`) — host próbkuje wtedy na kolejnym zboczu opadającym, z pełnym okresem na ścieżkę wyjściową.
- Między `io_q` a logiką na zboczu opadającym jest pół okresu. Logika zależna od pinów jest więc płytka: opkod jest dekodowany przy 7. bicie dla czterech możliwych zakończeń z samych rejestrów, a pin tylko wybiera wynik; pierwsza porcja `READ_ID` / `READ_STATUS` i sterowanie OE są wyliczone wcześniej.
- `TX_ABORT` i zatwierdzenie ramki z LEN = 0 (odrzucanej przez odbiornik jako błąd długości) działają na najbliższym zboczu opadającym — w razie potrzeby w następnej transakcji, zawsze przed jej pierwszym bajtem danych. Zatwierdzenie LEN = 0 używa `tx_commit_prev` (bez bajtu zapisywanego w tym samym takcie, jeśli w tej samej transakcji zaczyna się kolejna ramka).

Próbna synteza (GW1N-9C) z oboma FIFO, SCLK na pinie 19 (GCLKT_4), z ograniczeniami wejść (dane hosta ważne do 4 ns po zboczu opadającym) i wyjść: 784 LUT/ALU, 535 rejestrów; SCLK 40 MHz — wszystkie ścieżki spełnione (zapas 1,4 ns), 50 MHz — brak 0,8 ns na ścieżkach pół okresu, stąd wymaganie SCLK ≤ 40 MHz. Przepustowość 8 × 40 Mb/s = 40 MB/s czterokrotnie przewyższa przepustowość łącza (10 MB/s).

## Ramki

- **TX:** parser odczytuje `TYPE, LEN_H, LEN_L` ze strumienia i zatwierdza ramkę z ostatnim bajtem treści; stan parsera przetrwa koniec transakcji (ramka może być podzielona). Bajt zapisany przy pełnym FIFO jest tracony (`ev_tx_ovf_t`); host sprawdza `TX_SPACE` przed ramką.
- **RX:** kolejka 2 bajtów jest uzupełniana kombinacyjnym żądaniem odczytu w fazach dummy i danych (w formacie 8-liniowym bajt w każdym takcie). Bajt jest zdejmowany z kolejki dopiero, gdy host spróbkował jego ostatnią porcję; bajty pobrane, a niewysłane, zostają w kolejce na następną transakcję. Pusta kolejka daje `0x00` — host czyta tyle, ile podaje `RX_LEVEL`.

## Testbench `tb_xspi_slave`

Behawioralny master (SDR, tryb 0, 50 MHz — ostrzej niż wymaganie, logika funkcjonalnie poprawna), magistrala trójstanowa z podciąganiem, rzeczywiste FIFO (TX 64 B na SCLK / `clk_sys`, RX 1 KiB), model zatrzaśniętej przestrzeni rejestrów; `clk_sys` = 47 MHz (asynchronicznie). W resecie zegar slave'a pracuje ciągle (jak z `host_clk`), potem SCLK tylko w transakcjach.

| Nr | Sprawdzenie |
|---|---|
| 1 | `READ_ID`: `5B 5F` wersja `00`; w fazie danych sterowana tylko IO1 |
| 2 | `READ_STATUS` dwukrotnie |
| 3 | `READ_REG` od 0x10, 6 bajtów (auto-inkrementacja) |
| 4 | `WRITE_REG`: 3 bajty i 10 bajtów (bufor ograniczony do 8); `wr_txn`, `wr_addr`, `wr_cnt`, dane po podniesieniu CS |
| 5 | `TX_WRITE_1` / `_4` / `_8`: ramka w jednej transakcji, zatwierdzona bez dalszych taktów SCLK; ramka podzielona na 3 transakcje — niezatwierdzona przed końcem |
| 6 | `TX_ABORT` po części ramki — dociera tylko następna ramka; nagłówek LEN = 0 z następną ramką w tej samej transakcji; samotny nagłówek LEN = 0 zatwierdzony przy następnej transakcji |
| 7 | `RX_READ_8` całej ramki; `RX_READ_1` nagłówka i `RX_READ_4` treści; `RX_READ_8` ramki w dwóch częściach — wszystkie bajty zgodne, bajty pobrane z wyprzedzeniem nie giną |
| 8 | nieznany opkod: nic nie zapisane, nic nie sterowane |
| 9 | przepełnienie FIFO TX: `ev_tx_ovf_t` |

W całym teście: bajty po stronie łącza zgodne z zapisanymi ramkami; slave steruje wyłącznie liniami dozwolonymi w danej fazie.

**Test mutacyjny:** wykrywane — zdejmowanie bajtu z kolejki RX po każdej porcji, zamieniona kolejność półbajtów, brak przełączenia `wr_txn`, zatwierdzenie o bajt za wcześnie, brak `TX_ABORT`, brak zatwierdzenia LEN = 0, brak auto-inkrementacji adresu.

## Przebieg

`.\view.ps1 tb_xspi_slave` — czas symulacji ok. 42 µs; każda transakcja to okres `cs_n` = 0.

| Czas (ok.) | Co widać |
|---|---|
| 0–0,3 µs | reset przy ciągłym zegarze |
| 0,5–3 µs | `READ_ID`, `READ_STATUS`, `READ_REG`: `st` INSTR → DATA (lub ADDR → DUMMY → DATA), `io_oe` = 02 w fazie danych, `ounit` zmienia się na zboczach opadających |
| 3–6 µs | `WRITE_REG`: `wr_txn` zmienia stan po bajcie adresu, `wr_cnt` rośnie |
| 6–20 µs | `TX_WRITE`: `tx_wr` na zboczach opadających, `tx_commit` z ostatnim bajtem ramki; `n_tx_bytes` rośnie zaraz po transakcji |
| ok. 20–25 µs | `TX_ABORT` (impuls `tx_abort` na pierwszym zboczu następnej transakcji), ramki LEN = 0 (`tx_commit_prev`) |
| 25–36 µs | `RX_READ`: w fazie dummy `rx_rd` i `rx_valid`, `qn` = 2; w 8-liniowym odczycie `io_oe` = FF, bajt na takt |
| koniec | nieznany opkod, przepełnienie FIFO TX |
