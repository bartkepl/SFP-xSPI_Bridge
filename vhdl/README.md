# vhdl

Projekt FPGA w Gowin EDA (VHDL-2008, GowinSynthesis): slave xSPI, rejestry CSR, asynchroniczne FIFO, framer/deframer z CRC-32, koder/dekoder 8b/10b, soft-CDR z 4× nadpróbkowaniem (IDES4), I2C master do zarządzania modułem SFP.

Układ katalogów:

```
constraints/                 — sfp_bridge.cst (piny, standardy I/O), sfp_bridge.sdc (zegary); wspólne dla obu projektów
sfp_bridge/                  — projekt docelowy Gowin EDA (sfp_bridge.gprj)
  impl/                      — wyniki syntezy i PnR (ignorowane), poza sfp_bridge_process_config.json
  src/pkg/bridge_pkg.vhd     — stałe (współdzielone także przez projekt testowy)
  src/top/sfp_bridge_top.vhd — top docelowy
  src/clk|host|fifo|link|mgmt/  — moduły (kolejne etapy)
sfp_bridge_testled/          — projekt testowy: naprzemienne miganie LED_LINK / LED_ACT
  src/sfp_bridge_testled_top.vhd
sim/                         — testbenche (GHDL / ModelSim)
```

Ustawienia obu projektów (w `impl/*_process_config.json`): urządzenie GW1N-UV9QN48C6/I5 (`gw1n9c-003`), VHDL-2008, MSPI jako GPIO (piny 31–34). Top: `sfp_bridge_top` / `sfp_bridge_testled_top`.

Budowa wsadowa (w katalogu projektu):

```
gw_sh build.tcl      # build.tcl: open_project <projekt>.gprj ; run all
```

Bitstream: `<projekt>/impl/pnr/<projekt>.fs`.

Stan:

- `sfp_bridge` — szkielet: wszystkie porty zadeklarowane, wyjścia w stanie bezpiecznym (laser SFP wyłączony, interfejs hosta w spoczynku, LED zgaszone).
- `sfp_bridge_testled` — test uruchomieniowy: `LED_LINK` i `LED_ACT` migają naprzemiennie (2 Hz) bezpośrednio z zegara 25 MHz, bez PLL; pozostałe wyjścia jak w szkielecie.

Opis modułów, zestaw komend xSPI i mapa rejestrów: [`../doc/sfp-xspi-bridge-plan.md`](../doc/sfp-xspi-bridge-plan.md), rozdziały 6–7.
