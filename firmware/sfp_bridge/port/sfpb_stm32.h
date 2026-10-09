/*
 * sfpb_stm32.h - STM32 HAL ports of the SFP-xSPI bridge library.
 *
 * The default port (sfpb_port_default(), used by sfpb_init(dev, NULL)) is
 * built from sfpb_config.h: SFPB_TRANSPORT, the peripheral handle
 * (SFPB_OSPI_HANDLE ...), SFPB_SPI_CS_PORT / PIN, SFPB_RST_PORT / PIN.
 * The functions below build ports at run time, e.g. for two bridges:
 *
 *   static sfpb_stm32_ctx_t ctx_b = { &hospi2, NULL, 0, GPIOC, GPIO_PIN_3 };
 *   sfpb_port_t port_b;
 *   sfpb_port_ospi(&port_b, &ctx_b);
 *   sfpb_init(&bridge_b, &port_b);
 *
 * A port file is compiled when its transport is selected by SFPB_TRANSPORT
 * or enabled with SFPB_PORT_OSPI / _XSPI / _QSPI / _SPI = 1.
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef SFPB_STM32_H
#define SFPB_STM32_H

#include "sfp_bridge.h"
#include SFPB_HAL_HEADER

#ifdef __cplusplus
extern "C" {
#endif

#ifndef SFPB_PORT_OSPI
#define SFPB_PORT_OSPI (SFPB_TRANSPORT == SFPB_TRANSPORT_OSPI)
#endif
#ifndef SFPB_PORT_XSPI
#define SFPB_PORT_XSPI (SFPB_TRANSPORT == SFPB_TRANSPORT_XSPI)
#endif
#ifndef SFPB_PORT_QSPI
#define SFPB_PORT_QSPI (SFPB_TRANSPORT == SFPB_TRANSPORT_QSPI)
#endif
#ifndef SFPB_PORT_SPI
#define SFPB_PORT_SPI (SFPB_TRANSPORT == SFPB_TRANSPORT_SPI)
#endif

typedef struct {
    void         *handle;     /* OSPI / XSPI / QSPI / SPI handle              */
    GPIO_TypeDef *cs_port;    /* SPI only: chip select GPIO (output, idle 1)  */
    uint16_t      cs_pin;
    GPIO_TypeDef *rst_port;   /* HOST_RST_N GPIO or NULL                      */
    uint16_t      rst_pin;
} sfpb_stm32_ctx_t;

#if SFPB_PORT_OSPI
void sfpb_port_ospi(sfpb_port_t *port, sfpb_stm32_ctx_t *ctx);
#endif
#if SFPB_PORT_XSPI
void sfpb_port_xspi(sfpb_port_t *port, sfpb_stm32_ctx_t *ctx);
#endif
#if SFPB_PORT_QSPI
void sfpb_port_qspi(sfpb_port_t *port, sfpb_stm32_ctx_t *ctx);
#endif
#if SFPB_PORT_SPI
void sfpb_port_spi(sfpb_port_t *port, sfpb_stm32_ctx_t *ctx);
#endif

/* Common helpers of the HAL ports (port/sfpb_port_stm32.c). */
uint32_t sfpb_stm32_get_ms(void *ctx);
void     sfpb_stm32_delay_ms(void *ctx, uint32_t ms);
void     sfpb_stm32_set_reset(void *ctx, int asserted);
void     sfpb_stm32_fill(sfpb_port_t *port, sfpb_stm32_ctx_t *ctx,
                         int (*xfer)(void *, const sfpb_cmd_t *, uint8_t *, size_t), uint8_t max_lines);

#ifdef __cplusplus
}
#endif

#endif /* SFPB_STM32_H */
