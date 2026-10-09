/*
 * sfpb_port_ospi.c - port for the STM32 OCTOSPI peripheral (HAL_OSPI:
 * L4+, L5, U5, H7A3/B3/B0, H72x/73x). Indirect mode, instruction and
 * address on 1 line, data on 1 / 4 / 8 lines, SDR.
 *
 * CubeMX settings: memory type Micron (standard), ChipSelectHighTime >= 100 ns
 * (4 cycles at 40 MHz), ClockPrescaler for SCLK <= 40 MHz, SampleShifting =
 * HALFCYCLE, DelayHoldQuarterCycle disabled, clock mode 0 (low).
 *
 * SPDX-License-Identifier: MIT
 */
#include "sfpb_stm32.h"

#if SFPB_PORT_OSPI

static uint32_t data_mode(uint8_t lines)
{
    return (lines == 8u) ? HAL_OSPI_DATA_8_LINES : (lines == 4u) ? HAL_OSPI_DATA_4_LINES : HAL_OSPI_DATA_1_LINE;
}

#if SFPB_USE_DMA
static int wait_ready(OSPI_HandleTypeDef *h)
{
    uint32_t t0 = HAL_GetTick();

    while (HAL_OSPI_GetState(h) != HAL_OSPI_STATE_READY) {
        if (HAL_GetTick() - t0 > SFPB_HAL_TIMEOUT_MS) {
            (void)HAL_OSPI_Abort(h);
            return -1;
        }
    }
    return (h->ErrorCode == HAL_OSPI_ERROR_NONE) ? 0 : -1;
}
#endif

static int ospi_xfer(void *ctx, const sfpb_cmd_t *c, uint8_t *data, size_t len)
{
    OSPI_HandleTypeDef *h = (OSPI_HandleTypeDef *)((sfpb_stm32_ctx_t *)ctx)->handle;
    OSPI_RegularCmdTypeDef cmd = {0};
    HAL_StatusTypeDef st;

    cmd.OperationType      = HAL_OSPI_OPTYPE_COMMON_CFG;
    cmd.FlashId            = HAL_OSPI_FLASH_ID_1;
    cmd.Instruction        = c->opcode;
    cmd.InstructionMode    = HAL_OSPI_INSTRUCTION_1_LINE;
    cmd.InstructionSize    = HAL_OSPI_INSTRUCTION_8_BITS;
    cmd.InstructionDtrMode = HAL_OSPI_INSTRUCTION_DTR_DISABLE;
    cmd.Address            = c->addr;
    cmd.AddressMode        = c->has_addr ? HAL_OSPI_ADDRESS_1_LINE : HAL_OSPI_ADDRESS_NONE;
    cmd.AddressSize        = HAL_OSPI_ADDRESS_8_BITS;
    cmd.AddressDtrMode     = HAL_OSPI_ADDRESS_DTR_DISABLE;
    cmd.AlternateBytesMode = HAL_OSPI_ALTERNATE_BYTES_NONE;
    cmd.DataMode           = (c->dir == SFPB_DIR_NONE || len == 0u) ? HAL_OSPI_DATA_NONE : data_mode(c->lines);
    cmd.NbData             = (uint32_t)len;
    cmd.DataDtrMode        = HAL_OSPI_DATA_DTR_DISABLE;
    cmd.DummyCycles        = c->dummy;
    cmd.DQSMode            = HAL_OSPI_DQS_DISABLE;
    cmd.SIOOMode           = HAL_OSPI_SIOO_INST_EVERY_CMD;

    if (HAL_OSPI_Command(h, &cmd, SFPB_HAL_TIMEOUT_MS) != HAL_OK) {
        return -1;
    }
    if (cmd.DataMode == HAL_OSPI_DATA_NONE) {
        return 0;
    }
#if SFPB_USE_DMA
    if (len >= SFPB_DMA_MIN_LEN) {
        st = (c->dir == SFPB_DIR_WRITE) ? HAL_OSPI_Transmit_DMA(h, data) : HAL_OSPI_Receive_DMA(h, data);
        return (st == HAL_OK) ? wait_ready(h) : -1;
    }
#endif
    st = (c->dir == SFPB_DIR_WRITE) ? HAL_OSPI_Transmit(h, data, SFPB_HAL_TIMEOUT_MS)
                                    : HAL_OSPI_Receive(h, data, SFPB_HAL_TIMEOUT_MS);
    return (st == HAL_OK) ? 0 : -1;
}

void sfpb_port_ospi(sfpb_port_t *port, sfpb_stm32_ctx_t *ctx)
{
    sfpb_stm32_fill(port, ctx, ospi_xfer, 8u);
}

#endif /* SFPB_PORT_OSPI */
