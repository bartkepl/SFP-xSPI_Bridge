/*
 * sfpb_port_qspi.c - port for the STM32 QUADSPI peripheral (HAL_QSPI: F4,
 * F7, H7, L4, G4). Indirect mode, instruction and address on 1 line, data
 * on 1 or 4 lines, SDR, bank 1.
 *
 * CubeMX settings: ChipSelectHighTime >= 100 ns (4 cycles at 40 MHz),
 * ClockPrescaler for SCLK <= 40 MHz, SampleShifting = HALFCYCLE, clock mode 0
 * (low), FlashSize irrelevant (indirect mode).
 *
 * SPDX-License-Identifier: MIT
 */
#include "sfpb_stm32.h"

#if SFPB_PORT_QSPI

#if SFPB_USE_DMA
static int wait_ready(QSPI_HandleTypeDef *h)
{
    uint32_t t0 = HAL_GetTick();

    while (HAL_QSPI_GetState(h) != HAL_QSPI_STATE_READY) {
        if (HAL_GetTick() - t0 > SFPB_HAL_TIMEOUT_MS) {
            (void)HAL_QSPI_Abort(h);
            return -1;
        }
    }
    return (h->ErrorCode == HAL_QSPI_ERROR_NONE) ? 0 : -1;
}
#endif

static int qspi_xfer(void *ctx, const sfpb_cmd_t *c, uint8_t *data, size_t len)
{
    QSPI_HandleTypeDef *h = (QSPI_HandleTypeDef *)((sfpb_stm32_ctx_t *)ctx)->handle;
    QSPI_CommandTypeDef cmd = {0};
    HAL_StatusTypeDef st;

    cmd.Instruction       = c->opcode;
    cmd.InstructionMode   = QSPI_INSTRUCTION_1_LINE;
    cmd.Address           = c->addr;
    cmd.AddressMode       = c->has_addr ? QSPI_ADDRESS_1_LINE : QSPI_ADDRESS_NONE;
    cmd.AddressSize       = QSPI_ADDRESS_8_BITS;
    cmd.AlternateByteMode = QSPI_ALTERNATE_BYTES_NONE;
    cmd.DataMode          = (c->dir == SFPB_DIR_NONE || len == 0u) ? QSPI_DATA_NONE
                          : (c->lines == 4u) ? QSPI_DATA_4_LINES : QSPI_DATA_1_LINE;
    cmd.NbData            = (uint32_t)len;
    cmd.DummyCycles       = c->dummy;
    cmd.DdrMode           = QSPI_DDR_MODE_DISABLE;
    cmd.DdrHoldHalfCycle  = QSPI_DDR_HHC_ANALOG_DELAY;
    cmd.SIOOMode          = QSPI_SIOO_INST_EVERY_CMD;

    if (c->lines > 4u) {
        return -1;
    }
    if (HAL_QSPI_Command(h, &cmd, SFPB_HAL_TIMEOUT_MS) != HAL_OK) {
        return -1;
    }
    if (cmd.DataMode == QSPI_DATA_NONE) {
        return 0;
    }
#if SFPB_USE_DMA
    if (len >= SFPB_DMA_MIN_LEN) {
        st = (c->dir == SFPB_DIR_WRITE) ? HAL_QSPI_Transmit_DMA(h, data) : HAL_QSPI_Receive_DMA(h, data);
        return (st == HAL_OK) ? wait_ready(h) : -1;
    }
#endif
    st = (c->dir == SFPB_DIR_WRITE) ? HAL_QSPI_Transmit(h, data, SFPB_HAL_TIMEOUT_MS)
                                    : HAL_QSPI_Receive(h, data, SFPB_HAL_TIMEOUT_MS);
    return (st == HAL_OK) ? 0 : -1;
}

void sfpb_port_qspi(sfpb_port_t *port, sfpb_stm32_ctx_t *ctx)
{
    sfpb_stm32_fill(port, ctx, qspi_xfer, 4u);
}

#endif /* SFPB_PORT_QSPI */
