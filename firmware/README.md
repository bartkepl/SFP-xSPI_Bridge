# firmware

Biblioteka C `sfp_bridge` dla STM32 z warstwą portu dla HAL_XSPI/HAL_OSPI, HAL_QSPI i HAL_SPI + DMA. Bez dynamicznej alokacji.

Planowany układ katalogów:

```
sfp_bridge/
  include/   — sfp_bridge.h
  src/       — sfp_bridge.c
  port/      — sfp_bridge_port.h, stm32_ospi_port.c, stm32_qspi_port.c, stm32_spi_port.c
```

API i interfejs warstwy portu: [`../doc/sfp-xspi-bridge-plan.md`](../doc/sfp-xspi-bridge-plan.md), rozdział 8.
