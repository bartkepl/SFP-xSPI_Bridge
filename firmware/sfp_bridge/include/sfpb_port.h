/*
 * sfpb_port.h - transport layer of the SFP-xSPI bridge library.
 *
 * A port executes one xSPI transaction (CS low ... CS high):
 *   instruction (8 bit, 1 line) [address (8 bit, 1 line)] [dummy cycles]
 *   [data on 1 / 4 / 8 lines, host -> bridge or bridge -> host]
 * Formats 1-x-1: data from the host on IO0, to the host on IO1.
 * Ready ports for the STM32 HAL: port/sfpb_port_{ospi,xspi,qspi,spi}.c.
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef SFPB_PORT_H
#define SFPB_PORT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    SFPB_DIR_NONE  = 0,   /* no data phase (TX_ABORT)        */
    SFPB_DIR_WRITE = 1,   /* host -> bridge                  */
    SFPB_DIR_READ  = 2    /* bridge -> host                  */
} sfpb_dir_t;

typedef struct {
    uint8_t    opcode;
    uint8_t    addr;       /* valid when has_addr             */
    uint8_t    has_addr;
    uint8_t    dummy;      /* dummy cycles (0 or 8)           */
    uint8_t    lines;      /* data lines: 1, 4, 8             */
    sfpb_dir_t dir;
} sfpb_cmd_t;

typedef struct sfpb_port {
    /* One transaction; data / len describe the data phase (len = 0 with
     * SFPB_DIR_NONE). Returns 0 on success, < 0 on a bus error. */
    int (*xfer)(void *ctx, const sfpb_cmd_t *cmd, uint8_t *data, size_t len);
    /* HOST_RST_N: asserted != 0 drives the pin low. NULL when not wired. */
    void (*set_reset)(void *ctx, int asserted);
    /* Millisecond tick (wraps) and delay. */
    uint32_t (*get_ms)(void *ctx);
    void (*delay_ms)(void *ctx, uint32_t ms);
    void *ctx;
    uint8_t max_lines;    /* widest data phase of the peripheral: 1, 4, 8 */
} sfpb_port_t;

#ifdef __cplusplus
}
#endif

#endif /* SFPB_PORT_H */
