/*
 * sfpb_port_spi.c - port for a standard STM32 SPI peripheral (HAL_SPI, any
 * family) with a GPIO chip select. Formats 1-x-1 only: MOSI = IO0,
 * MISO = IO1; 8 dummy cycles = one byte.
 *
 * CubeMX settings: full-duplex master, 8-bit, CPOL = 0, CPHA = 0 (mode 0),
 * MSB first, software NSS (chip select by SFPB_SPI_CS_PORT / PIN, output
 * push-pull, idle high). The SPI samples MISO on the rising edge while the
 * bridge changes data on the falling edge, so the read timing budget is
 * half a period (datasheet 4.2): use a lower SCLK, e.g. <= 20 MHz.
 *
 * SPDX-License-Identifier: MIT
 */
#include "sfpb_stm32.h"

#if SFPB_PORT_SPI

#if SFPB_USE_DMA
static int wait_ready(SPI_HandleTypeDef *h)
{
    uint32_t t0 = HAL_GetTick();

    while (HAL_SPI_GetState(h) != HAL_SPI_STATE_READY) {
        if (HAL_GetTick() - t0 > SFPB_HAL_TIMEOUT_MS) {
            (void)HAL_SPI_Abort(h);
            return -1;
        }
    }
    return (h->ErrorCode == HAL_SPI_ERROR_NONE) ? 0 : -1;
}
#endif

static int spi_data(SPI_HandleTypeDef *h, sfpb_dir_t dir, uint8_t *data, uint16_t len)
{
    HAL_StatusTypeDef st;

#if SFPB_USE_DMA
    if (len >= SFPB_DMA_MIN_LEN) {
        st = (dir == SFPB_DIR_WRITE) ? HAL_SPI_Transmit_DMA(h, data, len) : HAL_SPI_Receive_DMA(h, data, len);
        return (st == HAL_OK) ? wait_ready(h) : -1;
    }
#endif
    st = (dir == SFPB_DIR_WRITE) ? HAL_SPI_Transmit(h, data, len, SFPB_HAL_TIMEOUT_MS)
                                 : HAL_SPI_Receive(h, data, len, SFPB_HAL_TIMEOUT_MS);
    return (st == HAL_OK) ? 0 : -1;
}

static int spi_xfer(void *ctx, const sfpb_cmd_t *c, uint8_t *data, size_t len)
{
    sfpb_stm32_ctx_t *x = (sfpb_stm32_ctx_t *)ctx;
    SPI_HandleTypeDef *h = (SPI_HandleTypeDef *)x->handle;
    uint8_t hdr[3];
    uint16_t n = 0u;
    int r;

    if (c->lines != 1u || (c->dummy % 8u) != 0u || len > 0xFFFFu) {
        return -1;
    }
    hdr[n++] = c->opcode;
    if (c->has_addr) {
        hdr[n++] = c->addr;
    }
    if (c->dummy != 0u) {
        hdr[n++] = 0x00u;   /* 8 dummy cycles */
    }
    HAL_GPIO_WritePin(x->cs_port, x->cs_pin, GPIO_PIN_RESET);
    r = (HAL_SPI_Transmit(h, hdr, n, SFPB_HAL_TIMEOUT_MS) == HAL_OK) ? 0 : -1;
    if (r == 0 && c->dir != SFPB_DIR_NONE && len > 0u) {
        r = spi_data(h, c->dir, data, (uint16_t)len);
    }
    HAL_GPIO_WritePin(x->cs_port, x->cs_pin, GPIO_PIN_SET);
    return r;
}

void sfpb_port_spi(sfpb_port_t *port, sfpb_stm32_ctx_t *ctx)
{
    sfpb_stm32_fill(port, ctx, spi_xfer, 1u);
}

#endif /* SFPB_PORT_SPI */
