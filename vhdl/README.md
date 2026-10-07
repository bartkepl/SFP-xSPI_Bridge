# vhdl

Projekt FPGA w Gowin EDA (VHDL-2008, GowinSynthesis): slave xSPI, rejestry CSR, asynchroniczne FIFO, framer/deframer z CRC-32, koder/dekoder 8b/10b, soft-CDR z 4× nadpróbkowaniem (IDES4), I2C master do zarządzania modułem SFP.

Planowany układ katalogów:

```
sfp_bridge.gprj
constraints/   — .cst (piny, standardy I/O), .sdc (zegary)
src/           — pkg, top, clk, host, fifo, link, mgmt
sim/           — testbenche (GHDL / ModelSim)
```

Opis modułów, zestaw komend xSPI i mapa rejestrów: [`../doc/sfp-xspi-bridge-plan.md`](../doc/sfp-xspi-bridge-plan.md), rozdziały 6–7.
