# firmware

Biblioteka C `sfp_bridge` dla STM32 — host mostka SFP-xSPI. C11, bez dynamicznej alokacji, konfiguracja przez `#define` w `sfpb_config.h`, porty HAL dla OCTOSPI, XSPI, QUADSPI i SPI (opcjonalnie DMA) oraz własny transport.

```
sfp_bridge/include/   API (sfp_bridge.h), komendy i rejestry, interfejs transportu
sfp_bridge/config/    szablon sfpb_config.h
sfp_bridge/src/       implementacja
sfp_bridge/port/      porty STM32 HAL
examples/             przykład użycia
tests/                testy na PC z modelem mostka
```

Szybki start:

1. Dodać `sfp_bridge/src/*.c`, `sfp_bridge/port/*.c` i ścieżki `include/`, `src/`, `port/`.
2. Skopiować `sfp_bridge/config/sfpb_config_template.h` jako `sfpb_config.h`, ustawić `SFPB_TRANSPORT` i uchwyt peryferium.
3. `sfpb_init(&dev, NULL)`, w obsłudze EXTI `HOST_IRQ_N` — `sfpb_irq_notify(&dev)`, w pętli głównej — `sfpb_process(&dev, 0)`.

Testy: `make -C tests` (gcc).

Dokumentacja: [`../doc/firmware.md`](../doc/firmware.md); protokół i rejestry: [`../doc/datasheet/index.md`](../doc/datasheet/index.md).
