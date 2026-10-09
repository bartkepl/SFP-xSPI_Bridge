/*
 * sfp_bridge.c - SFP-xSPI bridge library: transactions, registers, frames,
 * interrupts, counters, UART mode. SFP module access: sfpb_sfp.c.
 *
 * SPDX-License-Identifier: MIT
 */
#include <string.h>

#include "sfp_bridge.h"
#include "sfpb_internal.h"

/* ---- Transactions ------------------------------------------------------------ */

int sfpb__xfer(sfpb_t *dev, uint8_t opcode, int has_addr, uint8_t addr, uint8_t dummy,
               uint8_t lines, sfpb_dir_t dir, uint8_t *data, size_t len)
{
    sfpb_cmd_t cmd;

    if (dev->mode != SFPB_HOST_XSPI) {
        return SFPB_ERR_STATE;
    }
    cmd.opcode   = opcode;
    cmd.addr     = addr;
    cmd.has_addr = (uint8_t)(has_addr != 0);
    cmd.dummy    = dummy;
    cmd.lines    = lines;
    cmd.dir      = dir;
    return (dev->port.xfer(dev->port.ctx, &cmd, data, len) == 0) ? SFPB_OK : SFPB_ERR_IO;
}

uint32_t sfpb__elapsed(const sfpb_t *dev, uint32_t t0)
{
    return dev->port.get_ms(dev->port.ctx) - t0;
}

uint32_t sfpb__now(const sfpb_t *dev)
{
    return dev->port.get_ms(dev->port.ctx);
}

void sfpb__delay(const sfpb_t *dev, uint32_t ms)
{
    dev->port.delay_ms(dev->port.ctx, ms);
}

static uint8_t op_tx(uint8_t lines)
{
    return (lines == 8u) ? SFPB_OP_TX_WRITE_8 : (lines == 4u) ? SFPB_OP_TX_WRITE_4 : SFPB_OP_TX_WRITE_1;
}

static uint8_t op_rx(uint8_t lines)
{
    return (lines == 8u) ? SFPB_OP_RX_READ_8 : (lines == 4u) ? SFPB_OP_RX_READ_4 : SFPB_OP_RX_READ_1;
}

static uint16_t le16(const uint8_t *b)
{
    return (uint16_t)(b[0] | ((uint16_t)b[1] << 8));
}

/* ---- Initialisation and reset -------------------------------------------------- */

int sfpb_read_id(sfpb_t *dev, uint8_t *version)
{
    uint8_t id[4];
    int r = sfpb__xfer(dev, SFPB_OP_READ_ID, 0, 0, 0, 1, SFPB_DIR_READ, id, sizeof id);

    if (r != SFPB_OK) {
        return r;
    }
    if (id[0] != SFPB_ID0 || id[1] != SFPB_ID1) {
        return SFPB_ERR_NO_DEVICE;
    }
    if (version != NULL) {
        *version = id[2];
    }
    return SFPB_OK;
}

int sfpb_wait_ready(sfpb_t *dev, uint32_t timeout_ms)
{
    uint32_t t0 = sfpb__now(dev);
    int r;

    for (;;) {
        r = sfpb_read_id(dev, &dev->version);
        if (r == SFPB_OK || r == SFPB_ERR_STATE) {
            return r;
        }
        if (sfpb__elapsed(dev, t0) >= timeout_ms) {
            return r;   /* SFPB_ERR_NO_DEVICE or SFPB_ERR_IO */
        }
        sfpb__delay(dev, 1u);
    }
}

/* State after any reset of the bridge: FIFOs empty, IRQ_EN restored. */
static int after_reset(sfpb_t *dev)
{
    int r;

    dev->rx_left = 0u;
    dev->irq_pending = 0u;
#if SFPB_USE_DDM && SFPB_DDM_EXT_CAL
    dev->cal_state = 0u;
#endif
    r = sfpb_wait_ready(dev, SFPB_READY_TIMEOUT_MS);
    if (r == SFPB_OK) {
        uint8_t clr = SFPB_IRQ_ALL;
        r = sfpb_write_reg8(dev, SFPB_REG_IRQ_EN, dev->irq_mask);
        if (r == SFPB_OK) {
            r = sfpb_write_regs(dev, SFPB_REG_IRQ_STAT, &clr, 1u);
        }
    }
    return r;
}

int sfpb_init(sfpb_t *dev, const sfpb_port_t *port)
{
    if (dev == NULL) {
        return SFPB_ERR_PARAM;
    }
    memset(dev, 0, sizeof *dev);
    if (port == NULL) {
#if SFPB_TRANSPORT != SFPB_TRANSPORT_CUSTOM
        port = sfpb_port_default();
#endif
        if (port == NULL) {
            return SFPB_ERR_PARAM;
        }
    }
    if (port->xfer == NULL || port->get_ms == NULL || port->delay_ms == NULL) {
        return SFPB_ERR_PARAM;
    }
    dev->port = *port;
    if (dev->port.max_lines == 0u) {
        dev->port.max_lines = 1u;
    }
    dev->timeout_ms = SFPB_TIMEOUT_MS;
    dev->mode = SFPB_HOST_XSPI;
    dev->irq_mask = (uint8_t)SFPB_IRQ_MASK_DEFAULT;
    dev->lines = (uint8_t)SFPB_DATA_LINES;
    if (dev->lines > dev->port.max_lines) {
        dev->lines = dev->port.max_lines;
    }
    return after_reset(dev);
}

int sfpb_hw_reset(sfpb_t *dev)
{
    if (dev->port.set_reset == NULL) {
        return SFPB_ERR_NOT_SUPPORTED;
    }
    dev->port.set_reset(dev->port.ctx, 1);
    sfpb__delay(dev, SFPB_RESET_PULSE_MS);
    dev->port.set_reset(dev->port.ctx, 0);
    dev->mode = SFPB_HOST_XSPI;
    return after_reset(dev);
}

int sfpb_soft_reset(sfpb_t *dev)
{
    int r = sfpb_write_reg8(dev, SFPB_REG_CTRL, SFPB_CTRL_SOFT_RST | SFPB_CTRL_RESET_VAL);

    return (r == SFPB_OK) ? after_reset(dev) : r;
}

void sfpb_set_timeout(sfpb_t *dev, uint32_t timeout_ms)
{
    dev->timeout_ms = timeout_ms;
}

int sfpb_set_data_lines(sfpb_t *dev, uint8_t lines)
{
    if ((lines != 1u && lines != 4u && lines != 8u) || lines > dev->port.max_lines) {
        return SFPB_ERR_PARAM;
    }
    dev->lines = lines;
    return SFPB_OK;
}

const char *sfpb_strerror(int err)
{
    static const char *const msg[] = {
        "ok", "transport error", "timeout", "invalid parameter", "no bridge (READ_ID)",
        "RX FIFO empty", "frame truncated", "I2C NACK", "I2C command rejected",
        "I2C bus timeout", "not supported", "bridge in UART / echo mode",
        "no diagnostics", "invalid frame header", "link error (IRQ ERR)"
    };
    int i = -err;

    return (i >= 0 && i < (int)(sizeof msg / sizeof msg[0])) ? msg[i] : "unknown error";
}

/* ---- Registers ------------------------------------------------------------------- */

int sfpb_read_regs(sfpb_t *dev, uint8_t addr, uint8_t *buf, size_t n)
{
    if (buf == NULL || n == 0u || n > 256u) {
        return SFPB_ERR_PARAM;
    }
    return sfpb__xfer(dev, SFPB_OP_READ_REG, 1, addr, SFPB_DUMMY_READ_REG, 1, SFPB_DIR_READ, buf, n);
}

int sfpb_write_regs(sfpb_t *dev, uint8_t addr, const uint8_t *buf, size_t n)
{
    if (buf == NULL || n == 0u || n > 256u) {
        return SFPB_ERR_PARAM;
    }
    while (n > 0u) {
        size_t k = (n > SFPB_WRITE_REG_MAX) ? SFPB_WRITE_REG_MAX : n;
        /* the port does not modify data in the write direction */
        int r = sfpb__xfer(dev, SFPB_OP_WRITE_REG, 1, addr, 0, 1, SFPB_DIR_WRITE, (uint8_t *)(uintptr_t)buf, k);
        if (r != SFPB_OK) {
            return r;
        }
        addr = (uint8_t)(addr + k);
        buf += k;
        n -= k;
    }
    return SFPB_OK;
}

int sfpb_read_reg8(sfpb_t *dev, uint8_t addr, uint8_t *val)
{
    return sfpb_read_regs(dev, addr, val, 1u);
}

int sfpb_write_reg8(sfpb_t *dev, uint8_t addr, uint8_t val)
{
    return sfpb_write_regs(dev, addr, &val, 1u);
}

int sfpb_read_status_fast(sfpb_t *dev, uint8_t *sf)
{
    return sfpb__xfer(dev, SFPB_OP_READ_STATUS, 0, 0, 0, 1, SFPB_DIR_READ, sf, 1u);
}

int sfpb_get_status(sfpb_t *dev, sfpb_status_t *st)
{
    uint8_t b[10];
    int r = sfpb_read_regs(dev, SFPB_REG_CTRL, b, sizeof b);

    if (r == SFPB_OK) {
        st->ctrl        = b[0];
        st->status      = b[1];
        st->status_fast = b[2];
        st->irq_en      = b[3];
        st->irq_stat    = b[4];
        st->tx_space    = le16(&b[6]);
        st->rx_level    = le16(&b[8]);
    }
    return r;
}

int sfpb_link_up(sfpb_t *dev)
{
    uint8_t sf;
    int r = sfpb_read_status_fast(dev, &sf);

    return (r == SFPB_OK) ? ((sf & SFPB_SF_LINK_UP) != 0u) : r;
}

int sfpb_wait_link(sfpb_t *dev, uint32_t timeout_ms)
{
    uint32_t t0 = sfpb__now(dev);

    for (;;) {
        int r = sfpb_link_up(dev);
        if (r != 0) {
            return (r > 0) ? SFPB_OK : r;
        }
        if (sfpb__elapsed(dev, t0) >= timeout_ms) {
            return SFPB_ERR_TIMEOUT;
        }
        sfpb__delay(dev, 1u);
    }
}

int sfpb_mode_sel(sfpb_t *dev)
{
    uint8_t sf;
    int r = sfpb_read_status_fast(dev, &sf);

    return (r == SFPB_OK) ? ((sf & SFPB_SF_MODE_SEL) != 0u) : r;
}

int sfpb_ctrl_update(sfpb_t *dev, uint8_t mask, uint8_t value)
{
    uint8_t c;
    int r;

    if ((mask & (uint8_t)~SFPB_CTRL_RW_MASK) != 0u) {
        return SFPB_ERR_PARAM;
    }
    r = sfpb_read_reg8(dev, SFPB_REG_CTRL, &c);
    if (r != SFPB_OK) {
        return r;
    }
    c = (uint8_t)((c & SFPB_CTRL_RW_MASK & (uint8_t)~mask) | (value & mask));
    return sfpb_write_reg8(dev, SFPB_REG_CTRL, c);
}

/* ---- Interrupts ------------------------------------------------------------------- */

int sfpb_irq_enable(sfpb_t *dev, uint8_t mask)
{
    int r = sfpb_write_reg8(dev, SFPB_REG_IRQ_EN, mask & SFPB_IRQ_ALL);

    if (r == SFPB_OK) {
        dev->irq_mask = mask & SFPB_IRQ_ALL;
    }
    return r;
}

int sfpb_irq_read_clear(sfpb_t *dev, uint8_t *stat)
{
    int r = sfpb_read_reg8(dev, SFPB_REG_IRQ_STAT, stat);

    if (r == SFPB_OK && *stat != 0u) {
        r = sfpb_write_reg8(dev, SFPB_REG_IRQ_STAT, *stat);
    }
    return r;
}

#if SFPB_USE_EVENTS
void sfpb_set_callbacks(sfpb_t *dev, const sfpb_callbacks_t *cb, void *user)
{
    dev->cb = cb;
    dev->user = user;
}

static void cb_error(sfpb_t *dev, int err)
{
    if (dev->cb != NULL && dev->cb->error != NULL) {
        dev->cb->error(dev->user, err);
    }
}

int sfpb_process(sfpb_t *dev, int poll)
{
    const sfpb_callbacks_t *cb = dev->cb;
    uint8_t stat, st, sf;
    int r;

    if (!poll && !dev->irq_pending) {
        return 0;
    }
    dev->irq_pending = 0u;
    r = sfpb_irq_read_clear(dev, &stat);
    if (r != SFPB_OK) {
        return r;
    }
    if ((stat & (SFPB_IRQ_LINK_CHG | SFPB_IRQ_SFP_CHG)) != 0u) {
        r = sfpb_read_reg8(dev, SFPB_REG_STATUS, &st);
        if (r != SFPB_OK) {
            return r;
        }
        if ((stat & SFPB_IRQ_SFP_CHG) != 0u) {
#if SFPB_USE_DDM && SFPB_DDM_EXT_CAL
            dev->cal_state = 0u;
#endif
            if (cb != NULL && cb->sfp_change != NULL) {
                cb->sfp_change(dev->user, st);
            }
        }
        if ((stat & SFPB_IRQ_LINK_CHG) != 0u && cb != NULL && cb->link_change != NULL) {
            cb->link_change(dev->user, (st & SFPB_ST_LINK_UP) != 0u);
        }
    }
    if ((stat & SFPB_IRQ_RX_FRAME) != 0u || dev->rx_left != 0u) {
        for (;;) {
            uint8_t type;
            uint16_t len;
            r = sfpb_recv(dev, &type, dev->rx_buf, (uint16_t)sizeof dev->rx_buf, &len);
            if (r == SFPB_ERR_EMPTY) {
                break;
            }
            if (r == SFPB_OK) {
                if (cb != NULL && cb->rx_frame != NULL) {
                    cb->rx_frame(dev->user, type, dev->rx_buf, len);
                }
            } else {
                cb_error(dev, r);
                if (r != SFPB_ERR_TRUNC) {
                    break;
                }
            }
        }
    }
    if ((stat & SFPB_IRQ_TX_EMPTY) != 0u && cb != NULL && cb->tx_empty != NULL) {
        cb->tx_empty(dev->user);
    }
    if ((stat & SFPB_IRQ_I2C_DONE) != 0u && cb != NULL && cb->i2c_done != NULL) {
        cb->i2c_done(dev->user);
    }
    if ((stat & SFPB_IRQ_ERR) != 0u) {
        cb_error(dev, SFPB_ERR_LINK);
    }
    /* an event between the read and the W1C keeps HOST_IRQ_N low without a
     * new edge: look at the IRQ bit once more */
    if (sfpb_read_status_fast(dev, &sf) == SFPB_OK && (sf & SFPB_SF_IRQ) != 0u) {
        dev->irq_pending = 1u;
    }
    return stat;
}
#endif

/* ---- Frames ------------------------------------------------------------------------ */

int sfpb_tx_space(sfpb_t *dev, uint16_t *space)
{
    uint8_t b[2];
    int r = sfpb_read_regs(dev, SFPB_REG_TX_SPACE, b, sizeof b);

    if (r == SFPB_OK) {
        *space = le16(b);
    }
    return r;
}

int sfpb_send_timeout(sfpb_t *dev, uint8_t type, const void *data, uint16_t len, uint32_t timeout_ms)
{
    uint8_t hdr[SFPB_FRAME_HDR];
    uint32_t t0;
    int r;

    if (data == NULL || len == 0u || len > SFPB_MAX_PAYLOAD) {
        return SFPB_ERR_PARAM;
    }
    t0 = sfpb__now(dev);
    for (;;) {
        uint8_t sf;
        uint16_t space;
        r = sfpb_read_status_fast(dev, &sf);
        if (r != SFPB_OK) {
            return r;
        }
        if ((sf & SFPB_SF_TX_READY) != 0u) {
            break;
        }
        r = sfpb_tx_space(dev, &space);
        if (r != SFPB_OK) {
            return r;
        }
        if (space >= (uint16_t)(len + SFPB_FRAME_HDR)) {
            break;
        }
        if (sfpb__elapsed(dev, t0) >= timeout_ms) {
            return SFPB_ERR_TIMEOUT;
        }
        sfpb__delay(dev, 1u);
    }
    hdr[0] = type;
    hdr[1] = (uint8_t)(len >> 8);
    hdr[2] = (uint8_t)len;
    r = sfpb__xfer(dev, op_tx(dev->lines), 0, 0, 0, dev->lines, SFPB_DIR_WRITE, hdr, sizeof hdr);
    if (r != SFPB_OK) {
        return r;
    }
    r = sfpb__xfer(dev, op_tx(dev->lines), 0, 0, 0, dev->lines, SFPB_DIR_WRITE,
                   (uint8_t *)(uintptr_t)data, len);
    if (r != SFPB_OK) {
        (void)sfpb_tx_abort(dev);   /* drop the uncommitted frame */
    }
    return r;
}

int sfpb_send(sfpb_t *dev, uint8_t type, const void *data, uint16_t len)
{
    return sfpb_send_timeout(dev, type, data, len, dev->timeout_ms);
}

int sfpb_tx_abort(sfpb_t *dev)
{
    return sfpb__xfer(dev, SFPB_OP_TX_ABORT, 0, 0, 0, 1, SFPB_DIR_NONE, NULL, 0u);
}

int sfpb_wait_tx_empty(sfpb_t *dev, uint32_t timeout_ms)
{
    uint32_t t0 = sfpb__now(dev);

    for (;;) {
        uint8_t sf;
        int r = sfpb_read_status_fast(dev, &sf);
        if (r != SFPB_OK) {
            return r;
        }
        if ((sf & SFPB_SF_TX_EMPTY) != 0u) {
            return SFPB_OK;
        }
        if (sfpb__elapsed(dev, t0) >= timeout_ms) {
            return SFPB_ERR_TIMEOUT;
        }
        sfpb__delay(dev, 1u);
    }
}

int sfpb_rx_level(sfpb_t *dev, uint16_t *level)
{
    uint8_t b[2];
    int r = sfpb_read_regs(dev, SFPB_REG_RX_LEVEL, b, sizeof b);

    if (r == SFPB_OK) {
        *level = le16(b);
    }
    return r;
}

int sfpb_recv(sfpb_t *dev, uint8_t *type, void *buf, uint16_t maxlen, uint16_t *len)
{
    uint8_t hdr[SFPB_FRAME_HDR];
    uint16_t flen, keep, rest;
    int r;

    if (buf == NULL && maxlen != 0u) {
        return SFPB_ERR_PARAM;
    }
    if (dev->rx_left == 0u) {
        r = sfpb_rx_level(dev, &dev->rx_left);
        if (r != SFPB_OK) {
            return r;
        }
        if (dev->rx_left == 0u) {
            return SFPB_ERR_EMPTY;
        }
    }
    if (dev->rx_left < SFPB_FRAME_HDR + 1u) {
        dev->rx_left = 0u;
        return SFPB_ERR_PROTO;
    }
    r = sfpb__xfer(dev, op_rx(dev->lines), 0, 0, SFPB_DUMMY_RX_READ, dev->lines, SFPB_DIR_READ, hdr, sizeof hdr);
    if (r != SFPB_OK) {
        return r;
    }
    flen = (uint16_t)(((uint16_t)hdr[1] << 8) | hdr[2]);
    if (flen == 0u || flen > SFPB_MAX_PAYLOAD || flen + SFPB_FRAME_HDR > dev->rx_left) {
        dev->rx_left = 0u;   /* stream out of step: a soft reset resynchronises */
        return SFPB_ERR_PROTO;
    }
    dev->rx_left = (uint16_t)(dev->rx_left - SFPB_FRAME_HDR - flen);
    keep = (flen < maxlen) ? flen : maxlen;
    if (keep > 0u) {
        r = sfpb__xfer(dev, op_rx(dev->lines), 0, 0, SFPB_DUMMY_RX_READ, dev->lines, SFPB_DIR_READ,
                       (uint8_t *)buf, keep);
        if (r != SFPB_OK) {
            dev->rx_left = 0u;
            return r;
        }
    }
    for (rest = (uint16_t)(flen - keep); rest > 0u;) {
        uint8_t tmp[32];
        uint16_t k = (rest > sizeof tmp) ? (uint16_t)sizeof tmp : rest;
        r = sfpb__xfer(dev, op_rx(dev->lines), 0, 0, SFPB_DUMMY_RX_READ, dev->lines, SFPB_DIR_READ, tmp, k);
        if (r != SFPB_OK) {
            dev->rx_left = 0u;
            return r;
        }
        rest = (uint16_t)(rest - k);
    }
    if (type != NULL) {
        *type = hdr[0];
    }
    if (len != NULL) {
        *len = flen;
    }
    return (keep < flen) ? SFPB_ERR_TRUNC : SFPB_OK;
}

int sfpb_recv_timeout(sfpb_t *dev, uint8_t *type, void *buf, uint16_t maxlen, uint16_t *len,
                      uint32_t timeout_ms)
{
    uint32_t t0 = sfpb__now(dev);

    for (;;) {
        int r = sfpb_recv(dev, type, buf, maxlen, len);
        if (r != SFPB_ERR_EMPTY) {
            return r;
        }
        if (sfpb__elapsed(dev, t0) >= timeout_ms) {
            return SFPB_ERR_TIMEOUT;
        }
        sfpb__delay(dev, 1u);
    }
}

/* ---- Counters ------------------------------------------------------------------------ */

int sfpb_read_counters(sfpb_t *dev, sfpb_counters_t *cnt)
{
    uint8_t b[4u * SFPB_CNT_NUM];
    unsigned i;
    int r = sfpb_read_regs(dev, SFPB_REG_CNT_BASE, b, sizeof b);

    if (r == SFPB_OK) {
        for (i = 0u; i < SFPB_CNT_NUM; i++) {
            const uint8_t *p = &b[4u * i];
            cnt->v[i] = (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
        }
    }
    return r;
}

int sfpb_clear_counters(sfpb_t *dev)
{
    uint8_t c;
    int r = sfpb_read_reg8(dev, SFPB_REG_CTRL, &c);

    return (r == SFPB_OK) ? sfpb_write_reg8(dev, SFPB_REG_CTRL, (uint8_t)((c & SFPB_CTRL_RW_MASK) | SFPB_CTRL_CNT_CLR))
                          : r;
}

/* ---- UART mode and frame echo ---------------------------------------------------------- */
#if SFPB_USE_UART
uint16_t sfpb_uart_div(uint32_t baud)
{
    uint32_t div;

    if (baud == 0u) {
        return 0u;
    }
    div = (SFPB_UART_CLK_HZ + baud / 2u) / baud;
    return (div < SFPB_UART_DIV_MIN || div > 0xFFFFu) ? 0u : (uint16_t)div;
}

int sfpb_uart_set_baud(sfpb_t *dev, uint32_t baud)
{
    uint16_t div = sfpb_uart_div(baud);
    uint8_t b[2];

    if (div == 0u) {
        return SFPB_ERR_PARAM;
    }
    b[0] = (uint8_t)div;
    b[1] = (uint8_t)(div >> 8);
    return sfpb_write_regs(dev, SFPB_REG_UART_DIV, b, sizeof b);   /* one transaction */
}

int sfpb_uart_get_baud(sfpb_t *dev, uint32_t *baud)
{
    uint8_t b[2];
    int r = sfpb_read_regs(dev, SFPB_REG_UART_DIV, b, sizeof b);

    if (r == SFPB_OK) {
        uint16_t div = le16(b);
        *baud = (div != 0u) ? SFPB_UART_CLK_HZ / div : 0u;
    }
    return r;
}

int sfpb_uart_set_rtscts(sfpb_t *dev, int on)
{
    uint8_t m;
    int r = sfpb_read_reg8(dev, SFPB_REG_MODE_CTRL, &m);

    if (r != SFPB_OK) {
        return r;
    }
    m = on ? (uint8_t)(m | SFPB_MODE_RTSCTS) : (uint8_t)(m & (uint8_t)~SFPB_MODE_RTSCTS);
    return sfpb_write_reg8(dev, SFPB_REG_MODE_CTRL, m);   /* bits 0, 1 unchanged: no reset */
}

int sfpb_uart_enter(sfpb_t *dev, uint32_t baud, int rtscts)
{
    int r = sfpb_uart_set_baud(dev, baud);

    if (r == SFPB_OK) {
        r = sfpb_write_reg8(dev, SFPB_REG_MODE_CTRL, (uint8_t)(SFPB_MODE_UART | (rtscts ? SFPB_MODE_RTSCTS : 0u)));
    }
    if (r == SFPB_OK) {
        dev->mode = SFPB_HOST_UART;
    }
    return r;
}

int sfpb_echo_enter(sfpb_t *dev)
{
    int r = sfpb_write_reg8(dev, SFPB_REG_MODE_CTRL, SFPB_MODE_ECHO);

    if (r == SFPB_OK) {
        dev->mode = SFPB_HOST_ECHO;
    }
    return r;
}

int sfpb_mode_exit(sfpb_t *dev)
{
    return sfpb_hw_reset(dev);
}

int sfpb_uart_status(sfpb_t *dev, uint8_t *st, int clear)
{
    int r = sfpb_read_reg8(dev, SFPB_REG_UART_STATUS, st);

    if (r == SFPB_OK && clear && *st != 0u) {
        r = sfpb_write_reg8(dev, SFPB_REG_UART_STATUS, *st);
    }
    return r;
}
#endif
