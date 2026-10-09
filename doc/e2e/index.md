# Testy end-to-end

Testy sprawdzają dwa kompletne mostki tak, jak para konwerterów na stole: obserwowane są wyłącznie wyprowadzenia — wejście jednego mostka (J3 mostka A), łącze między nimi (pary SFP) i wyjście drugiego mostka (J3 mostka B). Każdy tryb interfejsu jest sprawdzany osobno, z tym samym trybem po obu stronach.

```
host A ──J3──> [ mostek A ] ──SFP TD → RD──> [ mostek B ] ──J3──> host B
                (sfp_bridge_top)  <──RD ← TD──  (sfp_bridge_top)
```

## Model

- Dwie instancje `sfp_bridge_top` z modelami symulacyjnymi prymitywów Gowin (rPLL, CLKDIV, DCS, IDES8, OSER8, TLVDS) — ten sam kod, który trafia do syntezy; generyki skracają tylko filtry sygnałów SFP i czasy diod.
- Oscylatory: mostek A 25 MHz, mostek B 25 MHz + 100 ppm (niezależne zegary, jak w rzeczywistej parze).
- Linia: `SFP_TD±` jednego mostka → `SFP_RD±` drugiego, opóźnienie 5 ns, w obu kierunkach. Połączenie odpowiada płytce rev. A — zamiana polaryzacji pary RD na pinach FPGA jest kompensowana w mostku ([integracja](../vhdl/top.md)).
- Moduł SFP: obecny, bez LOS i TX_FAULT; linie I2C tylko z rezystorami podciągającymi.
- Host xSPI: behawioralny master trybu 0, SCLK 40 MHz, CS w stanie wysokim 120 ns między transakcjami. Urządzenia UART: behawioralny nadajnik i odbiornik 115 200 8N1.

## Wyniki

| Test | Komendy / tryb | Dane | Wynik |
|---|---|---|---|
| [SPI ↔ SPI](spi.md) | TX_WRITE_1 / RX_READ_1 | F1: 3,15 µs na wejściu A, 2000 ns na linii | PASS (17 checks) |
| [QSPI ↔ QSPI](qspi.md) | TX_WRITE_4 / RX_READ_4 | F1: 1,04 µs na wejściu A, 2000 ns na linii | PASS (17 checks) |
| [OSPI ↔ OSPI](ospi.md) | TX_WRITE_8 / RX_READ_8 | F1: 0,69 µs na wejściu A, 2000 ns na linii | PASS (17 checks) |
| [UART ↔ UART](uart.md) | 115 200 8N1, zworka `MODE_SEL` | 174,21 µs od końca bajtu na wejściu A do ramki na linii | PASS (7 checks) |

## Uruchomienie

```
cd vhdl\sim
.\run_tests.ps1 tb_e2e_spi tb_e2e_qspi tb_e2e_ospi tb_e2e_uart
cd ..
python sim\wave_svg.py
```

Każdy test zapisuje przebieg `sim/out/<test>.ghw` (podgląd: `.\view.ps1 <test>`) oraz zapis wyprowadzeń i znaków łącza `sim/out/<test>_trace.txt`, z którego `wave_svg.py` tworzy rysunki w `doc/e2e/img/`.
