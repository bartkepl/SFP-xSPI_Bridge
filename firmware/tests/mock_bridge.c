/*
 * mock_bridge.c - transaction-level model of the SFP-xSPI bridge.
 *
 * SPDX-License-Identifier: MIT
 */
#include <stdio.h>
#include <string.h>

#include "mock_bridge.h"

static void violation(mock_bridge_t *m, const char *what, uint8_t op)
{
    m->violations++;
    snprintf(m->last_violation, sizeof m->last_violation, "%s (opcode 0x%02X)", what, op);
}

static void reset_bridge(mock_bridge_t *m, int hard)
{
    m->ctrl = SFPB_CTRL_RESET_VAL;
    m->irq_en = 0u;
    m->irq_stat = 0u;
    m->i2c_dev = SFPB_SFP_A0;
    m->i2c_off = 0u;
    m->i2c_len = 0u;
    m->i2c_status = 0u;
    m->i2c_busy = 0;
    m->ddm_period = 10u;
    memset(m->cnt, 0, sizeof m->cnt);
    m->txp_n = 0u;
    m->txq_n = 0u;
    m->rx_n = 0u;
    if (hard) {
        m->mode = 0u;
        m->uart_div = SFPB_UART_DIV_RESET;
        m->hard_resets++;
    } else {
        m->soft_resets++;
    }
}

void mock_init(mock_bridge_t *m)
{
    memset(m, 0, sizeof *m);
    m->version = 0x01u;
    m->mod_present = 1;
    m->ddm_valid = 1;
    m->i2c_busy_xfers = 3;
    reset_bridge(m, 1);
    m->hard_resets = 0u;
}

void mock_connect(mock_bridge_t *a, mock_bridge_t *b)
{
    a->peer = b;
    b->peer = a;
}

void mock_irq_set(mock_bridge_t *m, uint8_t bits)
{
    m->irq_stat |= bits;
}

int mock_irq_n(const mock_bridge_t *m)
{
    return (m->irq_stat & m->irq_en) == 0u;
}

/* frame committed by this bridge: to the own RX (near-end loopback) or to
 * the peer when the link is up, otherwise kept in the TX queue */
static void deliver(mock_bridge_t *m, const uint8_t *f, unsigned n)
{
    mock_bridge_t *dst = (m->ctrl & SFPB_CTRL_LB_NEAR) ? m : (m->link ? m->peer : NULL);

    if (dst == NULL) {
        if (m->txq_n + n <= MOCK_TX_FIFO) {
            memcpy(&m->txq[m->txq_n], f, n);
            m->txq_n += n;
        }
        return;
    }
    m->cnt[SFPB_CNT_FRAMES_TX]++;
    if (!(dst->ctrl & SFPB_CTRL_RX_EN) || dst->rx_n + n > MOCK_RX_FIFO) {
        dst->cnt[SFPB_CNT_RX_OVF]++;
        mock_irq_set(dst, SFPB_IRQ_ERR);
        return;
    }
    memcpy(&dst->rx[dst->rx_n], f, n);
    dst->rx_n += n;
    dst->cnt[SFPB_CNT_FRAMES_RX]++;
    mock_irq_set(dst, SFPB_IRQ_RX_FRAME);
}

static void flush_txq(mock_bridge_t *m)
{
    uint8_t q[MOCK_TX_FIFO];
    unsigned n = m->txq_n, p = 0u;

    memcpy(q, m->txq, n);
    m->txq_n = 0u;
    while (p + SFPB_FRAME_HDR <= n) {
        unsigned len = ((unsigned)q[p + 1] << 8) | q[p + 2];
        deliver(m, &q[p], SFPB_FRAME_HDR + len);
        p += SFPB_FRAME_HDR + len;
    }
    if (n > 0u && m->txq_n == 0u) {
        mock_irq_set(m, SFPB_IRQ_TX_EMPTY);
    }
}

void mock_set_link(mock_bridge_t *m, int up)
{
    mock_bridge_t *e[2] = { m, m->peer };
    int i;

    for (i = 0; i < 2; i++) {
        if (e[i] != NULL && e[i]->link != up) {
            e[i]->link = up;
            mock_irq_set(e[i], SFPB_IRQ_LINK_CHG);
        }
    }
    if (up) {
        for (i = 0; i < 2; i++) {
            if (e[i] != NULL) {
                flush_txq(e[i]);
            }
        }
    }
}

void mock_set_module(mock_bridge_t *m, int present)
{
    if (m->mod_present != present) {
        m->mod_present = present;
        mock_irq_set(m, SFPB_IRQ_SFP_CHG);
    }
}

static unsigned tx_used(const mock_bridge_t *m)
{
    return m->txq_n + m->txp_n;
}

static uint8_t status_fast(const mock_bridge_t *m)
{
    uint8_t s = SFPB_SF_MODE_SEL;

    if (m->link) s |= SFPB_SF_LINK_UP;
    if (m->rx_n > 0u) s |= SFPB_SF_RX_AVAIL;
    if (MOCK_TX_FIFO - tx_used(m) >= SFPB_FRAME_HDR + SFPB_MAX_PAYLOAD) s |= SFPB_SF_TX_READY;
    if (tx_used(m) == 0u) s |= SFPB_SF_TX_EMPTY;
    if (!mock_irq_n(m)) s |= SFPB_SF_IRQ;
    return s;
}

/* register snapshot at the falling edge of CS */
static void snapshot(const mock_bridge_t *m, uint8_t r[256])
{
    unsigned i;
    unsigned space = MOCK_TX_FIFO - tx_used(m);

    memset(r, 0, 256);
    r[0x00] = SFPB_ID0;
    r[0x01] = SFPB_ID1;
    r[0x02] = m->version;
    r[0x04] = m->ctrl;
    r[0x05] = (uint8_t)((m->link ? SFPB_ST_LINK_UP | SFPB_ST_SYNC | SFPB_ST_REMOTE_READY : 0u) |
                        (m->mod_present ? 0u : SFPB_ST_MOD_ABS | SFPB_ST_LOS));
    r[0x06] = status_fast(m);
    r[0x07] = m->irq_en;
    r[0x08] = m->irq_stat;
    r[0x0A] = (uint8_t)space;
    r[0x0B] = (uint8_t)(space >> 8);
    r[0x0C] = (uint8_t)m->rx_n;
    r[0x0D] = (uint8_t)(m->rx_n >> 8);
    for (i = 0u; i < SFPB_CNT_NUM; i++) {
        r[0x10 + 4 * i + 0] = (uint8_t)m->cnt[i];
        r[0x10 + 4 * i + 1] = (uint8_t)(m->cnt[i] >> 8);
        r[0x10 + 4 * i + 2] = (uint8_t)(m->cnt[i] >> 16);
        r[0x10 + 4 * i + 3] = (uint8_t)(m->cnt[i] >> 24);
    }
    r[0x30] = m->i2c_dev;
    r[0x31] = m->i2c_off;
    r[0x32] = m->i2c_len;
    r[0x34] = (uint8_t)(m->i2c_status | (m->i2c_busy > 0 ? SFPB_I2C_BUSY : 0u));
    if (m->mod_present && m->ddm_valid) {
        for (i = 0u; i < 5u; i++) {          /* A2h big-endian -> little-endian */
            r[0x40 + 2 * i] = m->a2[96 + 2 * i + 1];
            r[0x41 + 2 * i] = m->a2[96 + 2 * i];
        }
        r[0x4A] = m->a2[110];
        r[0x4B] = SFPB_DDM_VALID;
    } else {
        r[0x4B] = m->mod_present ? SFPB_DDM_NACK : 0u;
    }
    r[0x4C] = m->ddm_seq;
    r[0x4F] = m->ddm_period;
    r[0x50] = m->mode;
    r[0x51] = (uint8_t)m->uart_div;
    r[0x52] = (uint8_t)(m->uart_div >> 8);
    r[0x53] = m->uart_status;
    memcpy(&r[0x80], m->i2c_buf, 128);
}

static void i2c_start(mock_bridge_t *m)
{
    if (m->i2c_busy > 0 || m->i2c_len == 0u || m->i2c_len > SFPB_I2C_MAX_LEN || !m->mod_present) {
        m->i2c_status = SFPB_I2C_BAD_CMD;
        mock_irq_set(m, SFPB_IRQ_I2C_DONE);
        return;
    }
    m->i2c_status = 0u;
    m->i2c_busy = m->i2c_busy_xfers;
}

static void i2c_finish(mock_bridge_t *m)
{
    uint8_t *mem = (m->i2c_dev == SFPB_SFP_A0) ? m->a0 : (m->i2c_dev == SFPB_SFP_A2) ? m->a2 : NULL;
    unsigned i;

    if (mem == NULL || m->eeprom_busy_cmds > 0) {
        if (m->eeprom_busy_cmds > 0) {
            m->eeprom_busy_cmds--;
        }
        m->i2c_status = SFPB_I2C_NACK;
    } else if (m->i2c_cmd == SFPB_I2C_CMD_READ) {
        for (i = 0u; i < m->i2c_len; i++) {
            m->i2c_buf[i] = mem[(m->i2c_off + i) & 0xFFu];
        }
    } else {
        for (i = 0u; i < m->i2c_len; i++) {   /* EEPROM: address wraps inside an 8-byte page */
            mem[(m->i2c_off & 0xF8u) | ((m->i2c_off + i) & 0x07u)] = m->i2c_buf[i];
        }
        m->eeprom_busy_cmds = 2;             /* write cycle */
    }
    mock_irq_set(m, SFPB_IRQ_I2C_DONE);
}

static void write_reg(mock_bridge_t *m, uint8_t a, uint8_t v, int *soft, int *i2c_go)
{
    switch (a) {
    case 0x04:
        m->ctrl = v & 0x3Fu;
        if (v & SFPB_CTRL_CNT_CLR) {
            memset(m->cnt, 0, sizeof m->cnt);
        }
        if (v & SFPB_CTRL_SOFT_RST) {
            *soft = 1;
        }
        break;
    case 0x07: m->irq_en = v & SFPB_IRQ_ALL; break;
    case 0x08: m->irq_stat &= (uint8_t)~v; break;
    case 0x30: m->i2c_dev = v & 0x7Fu; break;
    case 0x31: m->i2c_off = v; break;
    case 0x32: m->i2c_len = v; break;
    case 0x33:
        if (v == SFPB_I2C_CMD_READ || v == SFPB_I2C_CMD_WRITE) {
            m->i2c_cmd = v;
            *i2c_go = 1;
        }
        break;
    case 0x4F: m->ddm_period = v; break;
    case 0x50:
        if ((v ^ m->mode) & (SFPB_MODE_UART | SFPB_MODE_ECHO)) {
            *soft = 1;
        }
        m->mode = v & 0x07u;
        break;
    case 0x51: m->uart_div = (uint16_t)((m->uart_div & 0xFF00u) | v); break;
    case 0x52: m->uart_div = (uint16_t)((m->uart_div & 0x00FFu) | ((uint16_t)v << 8)); break;
    case 0x53: m->uart_status &= (uint8_t)~v; break;
    default:
        if (a >= 0x80u) {
            m->i2c_buf[a - 0x80u] = v;
        }
        break;
    }
}

static void tx_byte(mock_bridge_t *m, uint8_t b)
{
    if (tx_used(m) >= MOCK_TX_FIFO) {
        mock_irq_set(m, SFPB_IRQ_ERR);       /* byte lost */
        return;
    }
    m->txp[m->txp_n++] = b;
    if (m->txp_n >= SFPB_FRAME_HDR) {
        unsigned len = ((unsigned)m->txp[1] << 8) | m->txp[2];
        if (m->txp_n == SFPB_FRAME_HDR + len) {
            unsigned n = m->txp_n;
            m->txp_n = 0u;
            deliver(m, m->txp, n);
        }
    }
}

/* expected format of an opcode: lines (0 = none), address, dummy, direction */
static int check_cmd(mock_bridge_t *m, const sfpb_cmd_t *c, size_t len)
{
    int lines = 1, addr = 0, dummy = 0;
    sfpb_dir_t dir = SFPB_DIR_READ;

    switch (c->opcode) {
    case SFPB_OP_READ_ID:     break;
    case SFPB_OP_READ_STATUS: break;
    case SFPB_OP_READ_REG:    addr = 1; dummy = 8; break;
    case SFPB_OP_WRITE_REG:   addr = 1; dir = SFPB_DIR_WRITE;
        if (len == 0u || len > SFPB_WRITE_REG_MAX) {
            violation(m, "WRITE_REG length", c->opcode);
            return -1;
        }
        break;
    case SFPB_OP_TX_WRITE_1:  dir = SFPB_DIR_WRITE; break;
    case SFPB_OP_TX_WRITE_4:  dir = SFPB_DIR_WRITE; lines = 4; break;
    case SFPB_OP_TX_WRITE_8:  dir = SFPB_DIR_WRITE; lines = 8; break;
    case SFPB_OP_RX_READ_1:   dummy = 8; break;
    case SFPB_OP_RX_READ_4:   dummy = 8; lines = 4; break;
    case SFPB_OP_RX_READ_8:   dummy = 8; lines = 8; break;
    case SFPB_OP_TX_ABORT:    dir = SFPB_DIR_NONE; break;
    default:
        violation(m, "unknown opcode", c->opcode);
        return -1;
    }
    if (c->has_addr != addr) violation(m, "address phase", c->opcode);
    if (c->dummy != dummy) violation(m, "dummy cycles", c->opcode);
    if (c->dir != dir) violation(m, "direction", c->opcode);
    if (dir != SFPB_DIR_NONE && c->lines != lines) violation(m, "data lines", c->opcode);
    if (dir == SFPB_DIR_NONE && len != 0u) violation(m, "data on TX_ABORT", c->opcode);
    if (dir != SFPB_DIR_NONE && len == 0u) violation(m, "empty data phase", c->opcode);
    return 0;
}

static int mock_xfer(void *ctx, const sfpb_cmd_t *c, uint8_t *data, size_t len)
{
    mock_bridge_t *m = (mock_bridge_t *)ctx;
    uint8_t r[256];
    size_t i;
    int soft = 0, i2c_go = 0;

    m->xfers++;
    m->time_us += 1u + len / 10u;
    if (m->absent || m->reset_asserted || (m->mode & (SFPB_MODE_UART | SFPB_MODE_ECHO))) {
        if (!m->absent && !m->reset_asserted) {
            m->offline_xfers++;
        }
        if (c->dir == SFPB_DIR_READ) {
            memset(data, 0xFF, len);
        }
        return 0;
    }
    if (check_cmd(m, c, len) != 0) {
        return 0;
    }
    if (len > 0u && m->fail_data_after > 0 && --m->fail_data_after == 0) {
        return -1;                            /* bus error in the data phase */
    }
    snapshot(m, r);
    if (m->i2c_busy > 0 && --m->i2c_busy == 0) {
        i2c_finish(m);
    }
    switch (c->opcode) {
    case SFPB_OP_READ_ID:
        for (i = 0u; i < len; i++) {
            data[i] = (i == 0u) ? SFPB_ID0 : (i == 1u) ? SFPB_ID1 : (i == 2u) ? m->version : 0u;
        }
        break;
    case SFPB_OP_READ_STATUS:
        memset(data, r[0x06], len);
        break;
    case SFPB_OP_READ_REG:
        for (i = 0u; i < len; i++) {
            data[i] = r[(c->addr + i) & 0xFFu];
        }
        break;
    case SFPB_OP_WRITE_REG:                   /* applied after CS rises */
        for (i = 0u; i < len; i++) {
            write_reg(m, (uint8_t)(c->addr + i), data[i], &soft, &i2c_go);
        }
        if (i2c_go) {
            i2c_start(m);
        }
        if (soft) {
            reset_bridge(m, 0);
        }
        break;
    case SFPB_OP_TX_WRITE_1:
    case SFPB_OP_TX_WRITE_4:
    case SFPB_OP_TX_WRITE_8:
        for (i = 0u; i < len; i++) {
            tx_byte(m, data[i]);
        }
        break;
    case SFPB_OP_RX_READ_1:
    case SFPB_OP_RX_READ_4:
    case SFPB_OP_RX_READ_8:
        for (i = 0u; i < len; i++) {
            if (m->rx_n > 0u) {
                data[i] = m->rx[0];
                memmove(m->rx, m->rx + 1, --m->rx_n);
            } else {
                data[i] = 0u;
            }
        }
        break;
    case SFPB_OP_TX_ABORT:
        m->txp_n = 0u;
        m->aborts++;
        break;
    default:
        break;
    }
    return 0;
}

static void mock_set_reset(void *ctx, int asserted)
{
    mock_bridge_t *m = (mock_bridge_t *)ctx;

    if (asserted && !m->reset_asserted) {
        reset_bridge(m, 1);                   /* UART_STATUS kept (power-on only) */
        if (m->link) {
            mock_set_link(m, 0);
        }
    }
    m->reset_asserted = asserted;
}

static uint32_t mock_get_ms(void *ctx)
{
    return (uint32_t)(((mock_bridge_t *)ctx)->time_us / 1000u);
}

static void mock_delay_ms(void *ctx, uint32_t ms)
{
    ((mock_bridge_t *)ctx)->time_us += (uint64_t)ms * 1000u;
}

void mock_port(mock_bridge_t *m, sfpb_port_t *port, int with_reset)
{
    port->xfer      = mock_xfer;
    port->set_reset = with_reset ? mock_set_reset : NULL;
    port->get_ms    = mock_get_ms;
    port->delay_ms  = mock_delay_ms;
    port->ctx       = m;
    port->max_lines = 8u;
}
