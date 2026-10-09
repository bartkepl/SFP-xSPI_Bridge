/*
 * mock_bridge.h - transaction-level model of the SFP-xSPI bridge for the
 * host tests of the library (PC, no hardware).
 *
 * Models: register map with latching and W1C, TX FIFO with frame commit and
 * TX_ABORT, RX FIFO, link between two models (or near-end loopback),
 * interrupts, counters, I2C engine with SFP memory (A0h / A2h) and EEPROM
 * busy time, DDM registers, MODE_CTRL / UART_DIV / UART_STATUS, HOST_RST_N.
 * Every transaction is checked against the command table of the datasheet
 * (lines, address, dummy cycles, direction, WRITE_REG length).
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef MOCK_BRIDGE_H
#define MOCK_BRIDGE_H

#include <stdint.h>

#include "sfp_bridge.h"

#define MOCK_TX_FIFO 4096u
#define MOCK_RX_FIFO 8192u

typedef struct mock_bridge {
    /* configuration by the test */
    int      absent;            /* no bridge: reads return 0xFF              */
    int      mod_present;       /* SFP module plugged in                     */
    int      ddm_valid;         /* DDM_STAT.VALID                            */
    int      fail_data_after;   /* > 0: the n-th following data phase fails  */
    uint8_t  version;
    uint8_t  a0[256], a2[256];  /* SFP memory                                */
    int      eeprom_busy_cmds;  /* NACK for this many following commands     */
    int      i2c_busy_xfers;    /* transactions with BUSY = 1 per command    */
    /* state */
    struct mock_bridge *peer;
    int      link;
    int      reset_asserted;
    uint8_t  ctrl, irq_en, irq_stat, mode, uart_status;
    uint16_t uart_div;
    uint8_t  i2c_dev, i2c_off, i2c_len, i2c_status, ddm_period, ddm_seq;
    int      i2c_busy;          /* remaining transactions                    */
    uint8_t  i2c_cmd;
    uint8_t  i2c_buf[128];
    uint32_t cnt[SFPB_CNT_NUM];
    uint8_t  txp[SFPB_FRAME_HDR + SFPB_MAX_PAYLOAD];  /* uncommitted frame    */
    unsigned txp_n;
    uint8_t  txq[MOCK_TX_FIFO]; /* committed frames waiting for the link     */
    unsigned txq_n;
    uint8_t  rx[MOCK_RX_FIFO];
    unsigned rx_n;
    /* statistics */
    unsigned xfers, violations, soft_resets, hard_resets, offline_xfers, aborts;
    uint64_t time_us;
    char     last_violation[128];
} mock_bridge_t;

void mock_init(mock_bridge_t *m);
void mock_connect(mock_bridge_t *a, mock_bridge_t *b);
void mock_set_link(mock_bridge_t *m, int up);           /* both ends          */
void mock_set_module(mock_bridge_t *m, int present);    /* SFP_CHG            */
void mock_port(mock_bridge_t *m, sfpb_port_t *port, int with_reset);
int  mock_irq_n(const mock_bridge_t *m);                /* HOST_IRQ_N level   */
void mock_irq_set(mock_bridge_t *m, uint8_t bits);      /* event              */

#endif /* MOCK_BRIDGE_H */
