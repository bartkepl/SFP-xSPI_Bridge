/*
 * sfpb_port_stm32.c - common part of the STM32 HAL ports: tick, delay,
 * HOST_RST_N and the default port built from sfpb_config.h.
 *
 * SPDX-License-Identifier: MIT
 */
#include "sfp_bridge.h"

#if (SFPB_TRANSPORT != SFPB_TRANSPORT_CUSTOM) || defined(SFPB_PORT_OSPI) || defined(SFPB_PORT_XSPI) || \
    defined(SFPB_PORT_QSPI) || defined(SFPB_PORT_SPI)

#include "sfpb_stm32.h"

uint32_t sfpb_stm32_get_ms(void *ctx)
{
    (void)ctx;
    return HAL_GetTick();
}

void sfpb_stm32_delay_ms(void *ctx, uint32_t ms)
{
    (void)ctx;
    HAL_Delay(ms);
}

void sfpb_stm32_set_reset(void *ctx, int asserted)
{
    sfpb_stm32_ctx_t *c = (sfpb_stm32_ctx_t *)ctx;

    HAL_GPIO_WritePin(c->rst_port, c->rst_pin, asserted ? GPIO_PIN_RESET : GPIO_PIN_SET);
}

void sfpb_stm32_fill(sfpb_port_t *port, sfpb_stm32_ctx_t *ctx,
                     int (*xfer)(void *, const sfpb_cmd_t *, uint8_t *, size_t), uint8_t max_lines)
{
    port->xfer      = xfer;
    port->set_reset = (ctx->rst_port != NULL) ? sfpb_stm32_set_reset : NULL;
    port->get_ms    = sfpb_stm32_get_ms;
    port->delay_ms  = sfpb_stm32_delay_ms;
    port->ctx       = ctx;
    port->max_lines = max_lines;
}

/* ---- Default port ----------------------------------------------------------------- */
#if SFPB_TRANSPORT != SFPB_TRANSPORT_CUSTOM

#if SFPB_TRANSPORT == SFPB_TRANSPORT_OSPI
extern OSPI_HandleTypeDef SFPB_OSPI_HANDLE;
#define SFPB__HANDLE (&SFPB_OSPI_HANDLE)
#define SFPB__FILL   sfpb_port_ospi
#elif SFPB_TRANSPORT == SFPB_TRANSPORT_XSPI
extern XSPI_HandleTypeDef SFPB_XSPI_HANDLE;
#define SFPB__HANDLE (&SFPB_XSPI_HANDLE)
#define SFPB__FILL   sfpb_port_xspi
#elif SFPB_TRANSPORT == SFPB_TRANSPORT_QSPI
extern QSPI_HandleTypeDef SFPB_QSPI_HANDLE;
#define SFPB__HANDLE (&SFPB_QSPI_HANDLE)
#define SFPB__FILL   sfpb_port_qspi
#elif SFPB_TRANSPORT == SFPB_TRANSPORT_SPI
extern SPI_HandleTypeDef SFPB_SPI_HANDLE;
#define SFPB__HANDLE (&SFPB_SPI_HANDLE)
#define SFPB__FILL   sfpb_port_spi
#if !defined(SFPB_SPI_CS_PORT) || !defined(SFPB_SPI_CS_PIN)
#error "SPI transport: define SFPB_SPI_CS_PORT and SFPB_SPI_CS_PIN"
#endif
#else
#error "unknown SFPB_TRANSPORT"
#endif

#ifndef SFPB_SPI_CS_PORT
#define SFPB_SPI_CS_PORT NULL
#define SFPB_SPI_CS_PIN  0u
#endif
#ifndef SFPB_RST_PORT
#define SFPB_RST_PORT NULL
#define SFPB_RST_PIN  0u
#endif

static sfpb_stm32_ctx_t default_ctx;
static sfpb_port_t      default_port;

const sfpb_port_t *sfpb_port_default(void)
{
    default_ctx.handle   = SFPB__HANDLE;
    default_ctx.cs_port  = SFPB_SPI_CS_PORT;
    default_ctx.cs_pin   = SFPB_SPI_CS_PIN;
    default_ctx.rst_port = SFPB_RST_PORT;
    default_ctx.rst_pin  = SFPB_RST_PIN;
    SFPB__FILL(&default_port, &default_ctx);
    return &default_port;
}

#endif /* SFPB_TRANSPORT != SFPB_TRANSPORT_CUSTOM */

#endif
