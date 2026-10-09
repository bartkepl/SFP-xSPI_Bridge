/*
 * sfpb_regs.h - SFP-xSPI bridge: xSPI commands and CSR map.
 *
 * Source of truth: doc/datasheet/index.md (chapters 6 and 7),
 * doc/sfp-xspi-bridge-plan.md (7.3, 7.4). Multi-byte registers are
 * little-endian.
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef SFPB_REGS_H
#define SFPB_REGS_H

/* ---- xSPI commands (instruction and address always on 1 line) ---------- */
#define SFPB_OP_READ_ID      0x9Fu  /* 1-0-1, 0 dummy, 4 B: 5B 5F VERSION 00 */
#define SFPB_OP_READ_STATUS  0x05u  /* 1-0-1, 0 dummy, STATUS_FAST repeated  */
#define SFPB_OP_READ_REG     0x0Bu  /* 1-1-1, 8 dummy                        */
#define SFPB_OP_WRITE_REG    0x02u  /* 1-1-1, 0 dummy, 1..8 B                */
#define SFPB_OP_TX_WRITE_1   0x12u  /* 1-0-1, 0 dummy                        */
#define SFPB_OP_TX_WRITE_4   0x32u  /* 1-0-4                                 */
#define SFPB_OP_TX_WRITE_8   0x82u  /* 1-0-8                                 */
#define SFPB_OP_RX_READ_1    0x13u  /* 1-0-1, 8 dummy                        */
#define SFPB_OP_RX_READ_4    0x6Bu  /* 1-0-4, 8 dummy                        */
#define SFPB_OP_RX_READ_8    0x8Bu  /* 1-0-8, 8 dummy                        */
#define SFPB_OP_TX_ABORT     0x66u  /* 1-0-0                                 */

#define SFPB_DUMMY_READ_REG  8u
#define SFPB_DUMMY_RX_READ   8u
#define SFPB_WRITE_REG_MAX   8u     /* bytes per WRITE_REG transaction        */

#define SFPB_ID0             0x5Bu
#define SFPB_ID1             0x5Fu

/* ---- CSR addresses ------------------------------------------------------ */
#define SFPB_REG_ID          0x00u  /* 2 B, 0x5F5B                            */
#define SFPB_REG_VERSION     0x02u
#define SFPB_REG_CTRL        0x04u
#define SFPB_REG_STATUS      0x05u
#define SFPB_REG_STATUS_FAST 0x06u
#define SFPB_REG_IRQ_EN      0x07u
#define SFPB_REG_IRQ_STAT    0x08u  /* W1C                                    */
#define SFPB_REG_TX_SPACE    0x0Au  /* 2 B                                    */
#define SFPB_REG_RX_LEVEL    0x0Cu  /* 2 B                                    */
#define SFPB_REG_CNT_BASE    0x10u  /* 8 x 4 B                                */
#define SFPB_REG_I2C_DEV     0x30u
#define SFPB_REG_I2C_OFFSET  0x31u
#define SFPB_REG_I2C_LEN     0x32u
#define SFPB_REG_I2C_CMD     0x33u
#define SFPB_REG_I2C_STATUS  0x34u
#define SFPB_REG_DDM_TEMP    0x40u  /* 5 x 2 B: TEMP VCC TXBIAS TXPWR RXPWR    */
#define SFPB_REG_DDM_FLAGS   0x4Au
#define SFPB_REG_DDM_STAT    0x4Bu
#define SFPB_REG_DDM_SEQ     0x4Cu
#define SFPB_REG_DDM_PERIOD  0x4Fu
#define SFPB_REG_MODE_CTRL   0x50u
#define SFPB_REG_UART_DIV    0x51u  /* 2 B, both bytes in one WRITE_REG       */
#define SFPB_REG_UART_STATUS 0x53u  /* W1C, cleared only at power-on and W1C   */
#define SFPB_REG_I2C_BUF     0x80u  /* 128 B                                  */

/* CTRL (0x04) */
#define SFPB_CTRL_TX_EN      0x01u
#define SFPB_CTRL_RX_EN      0x02u
#define SFPB_CTRL_LB_NEAR    0x04u
#define SFPB_CTRL_SFP_TX_DIS 0x08u
#define SFPB_CTRL_LOS_IGNORE 0x10u
#define SFPB_CTRL_CNT_CLR    0x40u  /* write-only pulse                       */
#define SFPB_CTRL_SOFT_RST   0x80u  /* write-only pulse                       */
#define SFPB_CTRL_RW_MASK    0x1Fu
#define SFPB_CTRL_RESET_VAL  0x03u

/* STATUS (0x05) */
#define SFPB_ST_LINK_UP      0x01u
#define SFPB_ST_SYNC         0x02u
#define SFPB_ST_REMOTE_READY 0x04u
#define SFPB_ST_XOFF_LOCAL   0x08u
#define SFPB_ST_XOFF_REMOTE  0x10u
#define SFPB_ST_LOS          0x20u
#define SFPB_ST_TX_FAULT     0x40u
#define SFPB_ST_MOD_ABS      0x80u

/* STATUS_FAST (0x06, READ_STATUS) */
#define SFPB_SF_LINK_UP      0x01u
#define SFPB_SF_RX_AVAIL     0x02u
#define SFPB_SF_TX_READY     0x04u  /* TX_SPACE >= 1027                        */
#define SFPB_SF_TX_EMPTY     0x08u
#define SFPB_SF_IRQ          0x10u
#define SFPB_SF_MODE_SEL     0x20u  /* jumper open (xSPI)                      */

/* IRQ_EN / IRQ_STAT (0x07 / 0x08) */
#define SFPB_IRQ_RX_FRAME    0x01u
#define SFPB_IRQ_TX_EMPTY    0x02u
#define SFPB_IRQ_LINK_CHG    0x04u
#define SFPB_IRQ_SFP_CHG     0x08u
#define SFPB_IRQ_I2C_DONE    0x10u
#define SFPB_IRQ_ERR         0x20u
#define SFPB_IRQ_ALL         0x3Fu

/* Counters (index; address = SFPB_REG_CNT_BASE + 4 * index) */
#define SFPB_CNT_CODE_ERR    0u
#define SFPB_CNT_CRC_ERR     1u
#define SFPB_CNT_LEN_ERR     2u
#define SFPB_CNT_FRAMING_ERR 3u
#define SFPB_CNT_RX_OVF      4u
#define SFPB_CNT_FRAMES_TX   5u
#define SFPB_CNT_FRAMES_RX   6u
#define SFPB_CNT_SYNC_LOSS   7u
#define SFPB_CNT_NUM         8u

/* I2C_CMD / I2C_STATUS */
#define SFPB_I2C_CMD_READ    0x01u
#define SFPB_I2C_CMD_WRITE   0x02u
#define SFPB_I2C_BUSY        0x01u
#define SFPB_I2C_NACK        0x02u
#define SFPB_I2C_TIMEOUT     0x04u
#define SFPB_I2C_BAD_CMD     0x08u
#define SFPB_I2C_MAX_LEN     128u

/* DDM_STAT */
#define SFPB_DDM_VALID       0x01u
#define SFPB_DDM_NACK        0x02u
#define SFPB_DDM_TIMEOUT     0x04u

/* MODE_CTRL (0x50) */
#define SFPB_MODE_UART       0x01u
#define SFPB_MODE_ECHO       0x02u
#define SFPB_MODE_RTSCTS     0x04u

/* UART_STATUS (0x53) */
#define SFPB_UART_RX_OVF     0x01u
#define SFPB_UART_FRAME_ERR  0x02u

#define SFPB_UART_CLK_HZ     50000000u  /* clk_sys                             */
#define SFPB_UART_DIV_MIN    8u
#define SFPB_UART_DIV_RESET  434u       /* 115200 bit/s                        */

/* ---- Frames --------------------------------------------------------------- */
#define SFPB_FRAME_HDR       3u         /* TYPE, LEN_H, LEN_L                  */
#define SFPB_MAX_PAYLOAD     1024u
#define SFPB_TYPE_DATA       0x00u
#define SFPB_TYPE_UART       0x01u      /* reserved for the UART mode          */

/* ---- SFP module (SFF-8472) ------------------------------------------------ */
#define SFPB_SFP_A0          0x50u      /* serial ID                           */
#define SFPB_SFP_A2          0x51u      /* diagnostics                         */

#endif /* SFPB_REGS_H */
