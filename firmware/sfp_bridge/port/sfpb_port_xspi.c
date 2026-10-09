/*
 * sfpb_port_xspi.c - port for the STM32 XSPI / OCTOSPI peripheral with the
 * HAL_XSPI driver (H5, H7R/S, N6, U5 with the XSPI HAL). Indirect mode, instruction and
 * address on 1 line, data on 1 / 4 / 8 lines, SDR.
 *
 * CubeMX settings: memory type Micron (standard), IO select IO[7:0], ChipSelectHighTime >= 100 ns
 * (4 cycles at 40 MHz), ClockPrescaler for SCLK <= 40 MHz, SampleShifting =
 * HALFCYCLE, DelayHoldQuarterCycle disabled, clock mode 0 (low).
 *
 * SPDX-License-Identifier: MIT
 */
#include "sfpb_stm32.h"

#if SFPB_PORT_XSPI

static uint32_t data_mode(uint8_t lines)
{
    return (lines == 8u) ? HAL_XSPI_DATA_8_LINES : (lines == 4u) ? HAL_XSPI_DATA_4_LINES : HAL_XSPI_DATA_1_LINE;
}

#if SFPB_USE_DMA
static int wait_ready(XSPI_HandleTypeDef *h)
{
    uint32_t t0 = HAL_GetTick();

    while (HAL_XSPI_GetState(h) != HAL_XSPI_STATE_READY) {
        if (HAL_GetTick() - t0 > SFPB_HAL_TIMEOUT_MS) {
            (void)HAL_XSPI_Abort(h);
            return -1;
        }
    }
    return (h->ErrorCode == HAL_XSPI_ERROR_NONE) ? 0 : -1;
}
#endif

static int xspi_xfer(void *ctx, const sfpb_cmd_t *c, uint8_t *data, size_t len)
{
    XSPI_HandleTypeDef *h = (XSPI_HandleTypeDef *)((sfpb_stm32_ctx_t *)ctx)->handle;
    XSPI_RegularCmdTypeDef cmd = {0};
    HAL_StatusTypeDef st;

    cmd.OperationType      = HAL_XSPI_OPTYPE_COMMON_CFG;
    cmd.IOSelect           = HAL_XSPI_SELECT_IO_7_0;
    cmd.Instruction        = c->opcode;
    cmd.InstructionMode    = HAL_XSPI_INSTRUCTION_1_LINE;
    cmd.InstructionWidth   = HAL_XSPI_INSTRUCTION_8_BITS;
    cmd.InstructionDTRMode = HAL_XSPI_INSTRUCTION_DTR_DISABLE;
    cmd.Address            = c->addr;
    cmd.AddressMode        = c->has_addr ? HAL_XSPI_ADDRESS_1_LINE : HAL_XSPI_ADDRESS_NONE;
    cmd.AddressWidth       = HAL_XSPI_ADDRESS_8_BITS;
    cmd.AddressDTRMode     = HAL_XSPI_ADDRESS_DTR_DISABLE;
    cmd.AlternateBytesMode = HAL_XSPI_ALT_BYTES_NONE;
    cmd.DataMode           = (c->dir == SFPB_DIR_NONE || len == 0u) ? HAL_XSPI_DATA_NONE : data_mode(c->lines);
    cmd.DataLength         = (uint32_t)len;
    cmd.DataDTRMode        = HAL_XSPI_DATA_DTR_DISABLE;
    cmd.DummyCycles        = c->dummy;
    cmd.DQSMode            = HAL_XSPI_DQS_DISABLE;

    if (HAL_XSPI_Command(h, &cmd, SFPB_HAL_TIMEOUT_MS) != HAL_OK) {
        return -1;
    }
    if (cmd.DataMode == HAL_XSPI_DATA_NONE) {
        return 0;
    }
#if SFPB_USE_DMA
    if (len >= SFPB_DMA_MIN_LEN) {
        st = (c->dir == SFPB_DIR_WRITE) ? HAL_XSPI_Transmit_DMA(h, data) : HAL_XSPI_Receive_DMA(h, data);
        return (st == HAL_OK) ? wait_ready(h) : -1;
    }
#endif
    st = (c->dir == SFPB_DIR_WRITE) ? HAL_XSPI_Transmit(h, data, SFPB_HAL_TIMEOUT_MS)
                                    : HAL_XSPI_Receive(h, data, SFPB_HAL_TIMEOUT_MS);
    return (st == HAL_OK) ? 0 : -1;
}

void sfpb_port_xspi(sfpb_port_t *port, sfpb_stm32_ctx_t *ctx)
{
    sfpb_stm32_fill(port, ctx, xspi_xfer, 8u);
}

#endif /* SFPB_PORT_XSPI */
