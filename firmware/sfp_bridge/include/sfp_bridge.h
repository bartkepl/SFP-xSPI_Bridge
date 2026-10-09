/*
 * sfp_bridge.h - host library of the SFP-xSPI bridge (GW1N FPGA,
 * OCTOSPI / QUADSPI / SPI <-> SFP fibre link).
 *
 * C11, no dynamic allocation, one sfpb_t per bridge. Compile-time
 * configuration: sfpb_config.h (see config/sfpb_config_template.h and
 * include/sfpb_config_default.h). Documentation: doc/firmware.md.
 *
 * All functions returning int give SFPB_OK (0) or a negative sfpb_err_t.
 * The library is not reentrant: calls for one sfpb_t must not run
 * concurrently (sfpb_irq_notify() excepted - it only sets a flag).
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef SFP_BRIDGE_H
#define SFP_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#include "sfpb_regs.h"
#include "sfpb_config_default.h"
#include "sfpb_port.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SFPB_LIB_VERSION 0x0100u   /* 1.0 */

typedef enum {
    SFPB_OK                =   0,
    SFPB_ERR_IO            =  -1,  /* transport (HAL) error                       */
    SFPB_ERR_TIMEOUT       =  -2,  /* condition not reached in time               */
    SFPB_ERR_PARAM         =  -3,  /* invalid argument                            */
    SFPB_ERR_NO_DEVICE     =  -4,  /* READ_ID does not return 5B 5F               */
    SFPB_ERR_EMPTY         =  -5,  /* no complete frame in the RX FIFO            */
    SFPB_ERR_TRUNC         =  -6,  /* frame longer than the buffer (rest dropped) */
    SFPB_ERR_NACK          =  -7,  /* I2C: no acknowledge                         */
    SFPB_ERR_BAD_CMD       =  -8,  /* I2C: command rejected (no module, length)   */
    SFPB_ERR_I2C_TIMEOUT   =  -9,  /* I2C: SCL held / bus stuck                   */
    SFPB_ERR_NOT_SUPPORTED = -10,  /* feature not configured (e.g. no reset pin)  */
    SFPB_ERR_STATE         = -11,  /* bridge in the UART / echo mode              */
    SFPB_ERR_NO_DDM        = -12,  /* module without diagnostics                  */
    SFPB_ERR_PROTO         = -13,  /* invalid frame header read from the RX FIFO  */
    SFPB_ERR_LINK          = -14   /* IRQ ERR: frame error on the link or byte lost
                                      at a full TX FIFO (see the counters)        */
} sfpb_err_t;

typedef enum {
    SFPB_HOST_XSPI = 0,           /* registers and frames accessible             */
    SFPB_HOST_UART = 1,           /* entered by sfpb_uart_enter()                */
    SFPB_HOST_ECHO = 2            /* entered by sfpb_echo_enter()                */
} sfpb_host_mode_t;

/* Registers 0x04..0x0D read in one transaction (consistent snapshot). */
typedef struct {
    uint8_t  ctrl;                /* SFPB_CTRL_*                                  */
    uint8_t  status;              /* SFPB_ST_*                                    */
    uint8_t  status_fast;         /* SFPB_SF_*                                    */
    uint8_t  irq_en;
    uint8_t  irq_stat;
    uint16_t tx_space;            /* free bytes in the TX FIFO                    */
    uint16_t rx_level;            /* bytes of complete frames in the RX FIFO      */
} sfpb_status_t;

typedef union {
    struct {
        uint32_t code_err, crc_err, len_err, framing_err;
        uint32_t rx_ovf, frames_tx, frames_rx, sync_loss;
    } n;
    uint32_t v[SFPB_CNT_NUM];     /* index SFPB_CNT_*                             */
} sfpb_counters_t;

#if SFPB_USE_I2C
/* SFP serial ID (A0h, bytes 0..95), strings without trailing spaces. */
typedef struct {
    uint8_t  identifier;          /* byte 0: 0x03 = SFP / SFP+                    */
    uint8_t  ext_identifier;      /* byte 1                                       */
    uint8_t  connector;           /* byte 2: 0x07 = LC                            */
    uint8_t  transceiver[8];      /* bytes 3..10: compliance codes                */
    uint8_t  encoding;            /* byte 11: 0x01 = 8B/10B                       */
    uint16_t br_nominal_mbd;      /* byte 12 x 100 MBd                            */
    uint16_t wavelength_nm;       /* bytes 60..61                                 */
    uint8_t  length_km;           /* byte 14: SMF length [km]                     */
    char     vendor_name[17];     /* bytes 20..35                                 */
    uint8_t  vendor_oui[3];       /* bytes 37..39                                 */
    char     vendor_pn[17];       /* bytes 40..55                                 */
    char     vendor_rev[5];       /* bytes 56..59                                 */
    char     vendor_sn[17];       /* bytes 68..83                                 */
    char     date_code[9];        /* bytes 84..91: YYMMDDLL                       */
    uint8_t  diag_type;           /* byte 92: b6 DDM, b5 internal, b4 external cal */
    uint8_t  enhanced_options;    /* byte 93                                      */
    uint8_t  sff8472_compliance;  /* byte 94                                      */
    uint8_t  cc_base_ok;          /* checksum of bytes 0..62 matches byte 63      */
    uint8_t  cc_ext_ok;           /* checksum of bytes 64..94 matches byte 95     */
} sfpb_sfp_info_t;
#endif

#if SFPB_USE_DDM
/* DDM registers of the bridge (A2h bytes 96..105, 110), as read. */
typedef struct {
    int16_t  temp;                /* raw A2h 96..97                               */
    uint16_t vcc;                 /* raw A2h 98..99                               */
    uint16_t tx_bias;             /* raw A2h 100..101                             */
    uint16_t tx_power;            /* raw A2h 102..103                             */
    uint16_t rx_power;            /* raw A2h 104..105                             */
    uint8_t  flags;               /* A2h 110 (status / control)                   */
    uint8_t  stat;                /* SFPB_DDM_VALID / NACK / TIMEOUT              */
    uint8_t  seq;                 /* successful reads (wraps)                     */
} sfpb_ddm_raw_t;

/* Converted diagnostics (SFF-8472 units, calibration applied). */
typedef struct {
    int32_t  temp_mc;             /* milli-degrees Celsius                        */
    uint32_t vcc_uv;              /* microvolts                                   */
    uint32_t tx_bias_ua;          /* microamperes                                 */
    uint32_t tx_power_nw;         /* nanowatts                                    */
    uint32_t rx_power_nw;         /* nanowatts                                    */
    uint8_t  flags;               /* A2h 110: b7 TX_DIS, b2 TX_FAULT, b1 RX_LOS, b0 /DATA_READY */
    uint8_t  seq;
    uint8_t  ext_cal;             /* 1: external calibration applied              */
} sfpb_ddm_t;

/* A2h 112..113 (alarm) and 116..117 (warning) flags, byte 112/116 in bits 15..8. */
typedef struct {
    uint16_t alarm;
    uint16_t warning;
} sfpb_ddm_alarms_t;

#define SFPB_DDMF_TX_DIS      0x80u
#define SFPB_DDMF_SOFT_TX_DIS 0x40u
#define SFPB_DDMF_TX_FAULT    0x04u
#define SFPB_DDMF_RX_LOS      0x02u
#define SFPB_DDMF_NOT_READY   0x01u
#endif

#if SFPB_USE_EVENTS
/* Callbacks of sfpb_process(); any may be NULL. Called from sfpb_process()
 * context (not from the interrupt). */
typedef struct {
    void (*rx_frame)(void *user, uint8_t type, const uint8_t *data, uint16_t len);
    void (*link_change)(void *user, int up);
    void (*sfp_change)(void *user, uint8_t status);     /* STATUS register        */
    void (*tx_empty)(void *user);
    void (*i2c_done)(void *user);
    void (*error)(void *user, int err);                 /* SFPB_ERR_LINK (IRQ ERR),
                                                           SFPB_ERR_TRUNC, SFPB_ERR_PROTO, I/O errors */
} sfpb_callbacks_t;
#endif

typedef struct {
    sfpb_port_t port;
    uint32_t    timeout_ms;
    uint16_t    rx_left;          /* bytes of complete frames not read yet        */
    uint8_t     lines;
    uint8_t     version;          /* VERSION of the bitstream                     */
    uint8_t     mode;             /* sfpb_host_mode_t                             */
    uint8_t     irq_mask;         /* IRQ_EN, restored after a reset               */
    volatile uint8_t irq_pending;
#if SFPB_USE_DDM && SFPB_DDM_EXT_CAL
    uint8_t     cal_state;        /* 0 unknown, 1 internal, 2 external, 3 no DDM  */
    float       cal_rx[5];        /* Rx_PWR(0..4)                                 */
    uint16_t    cal_slope[4];     /* TX_I, TX_PWR, T, V (unsigned 8.8)             */
    int16_t     cal_offset[4];
#endif
#if SFPB_USE_EVENTS
    const sfpb_callbacks_t *cb;
    void       *user;
    uint8_t     rx_buf[SFPB_RX_BUF_SIZE];
#endif
} sfpb_t;

/* ---- Initialisation and reset --------------------------------------------- */

/* Default port built from sfpb_config.h (not with SFPB_TRANSPORT_CUSTOM). */
const sfpb_port_t *sfpb_port_default(void);

/* port = NULL: default port. Waits for READ_ID (SFPB_READY_TIMEOUT_MS), reads
 * VERSION, writes IRQ_EN = SFPB_IRQ_MASK_DEFAULT. */
int  sfpb_init(sfpb_t *dev, const sfpb_port_t *port);
int  sfpb_wait_ready(sfpb_t *dev, uint32_t timeout_ms);
int  sfpb_read_id(sfpb_t *dev, uint8_t *version);
int  sfpb_hw_reset(sfpb_t *dev);          /* HOST_RST_N pulse, back to xSPI    */
int  sfpb_soft_reset(sfpb_t *dev);        /* CTRL.SOFT_RST                     */
void sfpb_set_timeout(sfpb_t *dev, uint32_t timeout_ms);
int  sfpb_set_data_lines(sfpb_t *dev, uint8_t lines);
const char *sfpb_strerror(int err);

/* ---- Registers --------------------------------------------------------------- */

int  sfpb_read_regs(sfpb_t *dev, uint8_t addr, uint8_t *buf, size_t n);
int  sfpb_write_regs(sfpb_t *dev, uint8_t addr, const uint8_t *buf, size_t n);
int  sfpb_read_reg8(sfpb_t *dev, uint8_t addr, uint8_t *val);
int  sfpb_write_reg8(sfpb_t *dev, uint8_t addr, uint8_t val);
int  sfpb_read_status_fast(sfpb_t *dev, uint8_t *sf);
int  sfpb_get_status(sfpb_t *dev, sfpb_status_t *st);
int  sfpb_link_up(sfpb_t *dev);                        /* 1, 0 or error   */
int  sfpb_wait_link(sfpb_t *dev, uint32_t timeout_ms);
int  sfpb_mode_sel(sfpb_t *dev);                       /* jumper: 1 open  */

/* CTRL read-modify-write of the bits in mask (SFPB_CTRL_RW_MASK). */
int  sfpb_ctrl_update(sfpb_t *dev, uint8_t mask, uint8_t value);
static inline int sfpb_set_tx_enable(sfpb_t *d, int on)  { return sfpb_ctrl_update(d, SFPB_CTRL_TX_EN, on ? SFPB_CTRL_TX_EN : 0u); }
static inline int sfpb_set_rx_enable(sfpb_t *d, int on)  { return sfpb_ctrl_update(d, SFPB_CTRL_RX_EN, on ? SFPB_CTRL_RX_EN : 0u); }
static inline int sfpb_set_loopback(sfpb_t *d, int on)   { return sfpb_ctrl_update(d, SFPB_CTRL_LB_NEAR, on ? SFPB_CTRL_LB_NEAR : 0u); }
static inline int sfpb_set_laser_off(sfpb_t *d, int off) { return sfpb_ctrl_update(d, SFPB_CTRL_SFP_TX_DIS, off ? SFPB_CTRL_SFP_TX_DIS : 0u); }
static inline int sfpb_set_los_ignore(sfpb_t *d, int on) { return sfpb_ctrl_update(d, SFPB_CTRL_LOS_IGNORE, on ? SFPB_CTRL_LOS_IGNORE : 0u); }

/* ---- Interrupts and events ---------------------------------------------------- */

int  sfpb_irq_enable(sfpb_t *dev, uint8_t mask);         /* IRQ_EN          */
int  sfpb_irq_read_clear(sfpb_t *dev, uint8_t *stat);     /* IRQ_STAT + W1C  */
/* From the HOST_IRQ_N EXTI handler (falling edge): only sets a flag. */
static inline void sfpb_irq_notify(sfpb_t *dev) { dev->irq_pending = 1u; }
#if SFPB_USE_EVENTS
void sfpb_set_callbacks(sfpb_t *dev, const sfpb_callbacks_t *cb, void *user);
/* Main loop: when an interrupt was notified (or always, poll != 0) reads and
 * clears IRQ_STAT, receives all frames and calls the callbacks. Returns the
 * handled IRQ_STAT bits (>= 0) or an error. */
int  sfpb_process(sfpb_t *dev, int poll);
#endif

/* ---- Frames --------------------------------------------------------------------- */

int  sfpb_tx_space(sfpb_t *dev, uint16_t *space);
/* Waits up to the device timeout for TX FIFO space, then writes
 * TYPE, LEN, payload (1..1024 bytes). */
int  sfpb_send(sfpb_t *dev, uint8_t type, const void *data, uint16_t len);
int  sfpb_send_timeout(sfpb_t *dev, uint8_t type, const void *data, uint16_t len, uint32_t timeout_ms);
int  sfpb_tx_abort(sfpb_t *dev);
int  sfpb_wait_tx_empty(sfpb_t *dev, uint32_t timeout_ms);
int  sfpb_rx_level(sfpb_t *dev, uint16_t *level);
/* One frame from the RX FIFO, non-blocking (SFPB_ERR_EMPTY). A frame longer
 * than maxlen is read completely: maxlen bytes stored, *len = real length,
 * SFPB_ERR_TRUNC returned. */
int  sfpb_recv(sfpb_t *dev, uint8_t *type, void *buf, uint16_t maxlen, uint16_t *len);
int  sfpb_recv_timeout(sfpb_t *dev, uint8_t *type, void *buf, uint16_t maxlen, uint16_t *len,
                       uint32_t timeout_ms);

/* ---- Counters ---------------------------------------------------------------------- */

int  sfpb_read_counters(sfpb_t *dev, sfpb_counters_t *cnt);
int  sfpb_clear_counters(sfpb_t *dev);

/* ---- SFP module (I2C) ------------------------------------------------------------- */
#if SFPB_USE_I2C
/* i2c_addr: 7-bit (SFPB_SFP_A0 = 0x50, SFPB_SFP_A2 = 0x51); offset + len <= 256. */
int  sfpb_sfp_read(sfpb_t *dev, uint8_t i2c_addr, uint8_t offset, void *buf, size_t len);
/* EEPROM write in pages of SFPB_EEPROM_PAGE, NACK retried for SFPB_EEPROM_WRITE_MS. */
int  sfpb_sfp_write(sfpb_t *dev, uint8_t i2c_addr, uint8_t offset, const void *buf, size_t len);
int  sfpb_sfp_info(sfpb_t *dev, sfpb_sfp_info_t *info);
int  sfpb_sfp_present(sfpb_t *dev);                    /* 1, 0 or error  */
#endif

/* ---- Diagnostics (DDM) ----------------------------------------------------------- */
#if SFPB_USE_DDM
int  sfpb_ddm_raw(sfpb_t *dev, sfpb_ddm_raw_t *raw);
/* SFPB_ERR_NO_DDM until the first successful read (300..400 ms after the
 * module is plugged in) or when the module has no diagnostics. */
int  sfpb_ddm_read(sfpb_t *dev, sfpb_ddm_t *ddm);
int  sfpb_ddm_set_period(sfpb_t *dev, uint8_t period_100ms);   /* 0 = off     */
void sfpb_ddm_invalidate_cal(sfpb_t *dev);       /* after a module change     */
#if SFPB_USE_I2C
int  sfpb_ddm_alarms(sfpb_t *dev, sfpb_ddm_alarms_t *al);
#endif
#endif
#if SFPB_USE_FLOAT
float sfpb_nw_to_dbm(uint32_t nw);                /* -40 dBm for 0            */
#endif

/* ---- UART mode and frame echo ----------------------------------------------------- */
#if SFPB_USE_UART
/* UART_DIV for a bit rate (rounded); 0 when out of range (div < 8 or > 65535). */
uint16_t sfpb_uart_div(uint32_t baud);
int  sfpb_uart_set_baud(sfpb_t *dev, uint32_t baud);
int  sfpb_uart_get_baud(sfpb_t *dev, uint32_t *baud);
int  sfpb_uart_set_rtscts(sfpb_t *dev, int on);  /* no reset                  */
/* Sets UART_DIV and MODE_CTRL.UART_MODE: the bridge resets itself into the
 * transparent UART mode and no longer answers xSPI commands. */
int  sfpb_uart_enter(sfpb_t *dev, uint32_t baud, int rtscts);
/* MODE_CTRL.FRAME_ECHO: received frames are sent back (no xSPI access). */
int  sfpb_echo_enter(sfpb_t *dev);
/* Back to the xSPI mode (HOST_RST_N); UART_DIV returns to 115200. */
int  sfpb_mode_exit(sfpb_t *dev);
/* UART_STATUS (SFPB_UART_*), events of the last UART session; clear != 0
 * clears the read bits (W1C). */
int  sfpb_uart_status(sfpb_t *dev, uint8_t *st, int clear);
#endif

#ifdef __cplusplus
}
#endif

#endif /* SFP_BRIDGE_H */
