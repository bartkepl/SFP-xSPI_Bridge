/*
 * sfpb_sfp.c - SFP module access through the bridge: I2C commands (memory
 * of A0h / A2h), serial ID, digital diagnostics (SFF-8472).
 *
 * SPDX-License-Identifier: MIT
 */
#include <string.h>

#include "sfp_bridge.h"
#include "sfpb_internal.h"

#if SFPB_USE_FLOAT
#include <math.h>
#endif

#if SFPB_USE_I2C

/* One I2C command: I2C_DEV, OFFSET, LEN, CMD in one WRITE_REG transaction
 * (applied together), then I2C_STATUS polled until BUSY = 0. NACK is retried
 * for SFPB_EEPROM_WRITE_MS (EEPROM busy after a write). */
static int i2c_cmd(sfpb_t *dev, uint8_t cmd, uint8_t i2c_addr, uint8_t offset, uint8_t len)
{
    uint8_t w[4];
    uint32_t t_nack = sfpb__now(dev);

    w[0] = (uint8_t)(i2c_addr & 0x7Fu);
    w[1] = offset;
    w[2] = len;
    w[3] = cmd;
    for (;;) {
        uint32_t t0;
        uint8_t st;
        int r = sfpb_write_regs(dev, SFPB_REG_I2C_DEV, w, sizeof w);
        if (r != SFPB_OK) {
            return r;
        }
        t0 = sfpb__now(dev);
        for (;;) {
            r = sfpb_read_reg8(dev, SFPB_REG_I2C_STATUS, &st);
            if (r != SFPB_OK) {
                return r;
            }
            if ((st & SFPB_I2C_BUSY) == 0u) {
                break;
            }
            if (sfpb__elapsed(dev, t0) >= SFPB_I2C_TIMEOUT_MS) {
                return SFPB_ERR_TIMEOUT;
            }
            sfpb__delay(dev, 1u);
        }
        if ((st & SFPB_I2C_BAD_CMD) != 0u) {
            return SFPB_ERR_BAD_CMD;
        }
        if ((st & SFPB_I2C_TIMEOUT) != 0u) {
            return SFPB_ERR_I2C_TIMEOUT;
        }
        if ((st & SFPB_I2C_NACK) == 0u) {
            return SFPB_OK;
        }
        if (sfpb__elapsed(dev, t_nack) >= SFPB_EEPROM_WRITE_MS) {
            return SFPB_ERR_NACK;
        }
        sfpb__delay(dev, 1u);
    }
}

int sfpb_sfp_read(sfpb_t *dev, uint8_t i2c_addr, uint8_t offset, void *buf, size_t len)
{
    uint8_t *p = (uint8_t *)buf;
    unsigned off = offset;

    if (buf == NULL || len == 0u || off + len > 256u) {
        return SFPB_ERR_PARAM;
    }
    while (len > 0u) {
        uint8_t k = (uint8_t)((len > SFPB_I2C_MAX_LEN) ? SFPB_I2C_MAX_LEN : len);
        int r = i2c_cmd(dev, SFPB_I2C_CMD_READ, i2c_addr, (uint8_t)off, k);
        if (r == SFPB_OK) {
            r = sfpb_read_regs(dev, SFPB_REG_I2C_BUF, p, k);
        }
        if (r != SFPB_OK) {
            return r;
        }
        p += k;
        off += k;
        len -= k;
    }
    return SFPB_OK;
}

int sfpb_sfp_write(sfpb_t *dev, uint8_t i2c_addr, uint8_t offset, const void *buf, size_t len)
{
    const uint8_t *p = (const uint8_t *)buf;
    unsigned off = offset;

    if (buf == NULL || len == 0u || off + len > 256u || SFPB_EEPROM_PAGE == 0u ||
        SFPB_EEPROM_PAGE > SFPB_I2C_MAX_LEN) {
        return SFPB_ERR_PARAM;
    }
    while (len > 0u) {
        size_t k = SFPB_EEPROM_PAGE - off % SFPB_EEPROM_PAGE;   /* up to the page end */
        int r;
        if (k > len) {
            k = len;
        }
        r = sfpb_write_regs(dev, SFPB_REG_I2C_BUF, p, k);
        if (r == SFPB_OK) {
            r = i2c_cmd(dev, SFPB_I2C_CMD_WRITE, i2c_addr, (uint8_t)off, (uint8_t)k);
        }
        if (r != SFPB_OK) {
            return r;
        }
        p += k;
        off += (unsigned)k;
        len -= k;
    }
    return SFPB_OK;
}

static void copy_str(char *dst, const uint8_t *src, size_t n)
{
    memcpy(dst, src, n);
    dst[n] = '\0';
    while (n > 0u && (dst[n - 1u] == ' ' || dst[n - 1u] == '\0')) {
        dst[--n] = '\0';
    }
}

static uint8_t sum8(const uint8_t *b, size_t n)
{
    uint8_t s = 0u;

    while (n-- > 0u) {
        s = (uint8_t)(s + *b++);
    }
    return s;
}

int sfpb_sfp_info(sfpb_t *dev, sfpb_sfp_info_t *info)
{
    uint8_t a0[96];
    int r = sfpb_sfp_read(dev, SFPB_SFP_A0, 0u, a0, sizeof a0);

    if (r != SFPB_OK) {
        return r;
    }
    info->identifier     = a0[0];
    info->ext_identifier = a0[1];
    info->connector      = a0[2];
    memcpy(info->transceiver, &a0[3], sizeof info->transceiver);
    info->encoding       = a0[11];
    info->br_nominal_mbd = (uint16_t)(a0[12] * 100u);
    info->length_km      = a0[14];
    copy_str(info->vendor_name, &a0[20], 16u);
    memcpy(info->vendor_oui, &a0[37], 3u);
    copy_str(info->vendor_pn, &a0[40], 16u);
    copy_str(info->vendor_rev, &a0[56], 4u);
    info->wavelength_nm  = (uint16_t)(((uint16_t)a0[60] << 8) | a0[61]);
    copy_str(info->vendor_sn, &a0[68], 16u);
    copy_str(info->date_code, &a0[84], 8u);
    info->diag_type          = a0[92];
    info->enhanced_options   = a0[93];
    info->sff8472_compliance = a0[94];
    info->cc_base_ok = (uint8_t)(sum8(a0, 63u) == a0[63]);
    info->cc_ext_ok  = (uint8_t)(sum8(&a0[64], 31u) == a0[95]);
    return SFPB_OK;
}

int sfpb_sfp_present(sfpb_t *dev)
{
    uint8_t st;
    int r = sfpb_read_reg8(dev, SFPB_REG_STATUS, &st);

    return (r == SFPB_OK) ? ((st & SFPB_ST_MOD_ABS) == 0u) : r;
}

#endif /* SFPB_USE_I2C */

#if SFPB_USE_DDM

int sfpb_ddm_raw(sfpb_t *dev, sfpb_ddm_raw_t *raw)
{
    uint8_t b[13];
    int r = sfpb_read_regs(dev, SFPB_REG_DDM_TEMP, b, sizeof b);

    if (r == SFPB_OK) {
        raw->temp     = (int16_t)(uint16_t)(b[0] | ((uint16_t)b[1] << 8));
        raw->vcc      = (uint16_t)(b[2] | ((uint16_t)b[3] << 8));
        raw->tx_bias  = (uint16_t)(b[4] | ((uint16_t)b[5] << 8));
        raw->tx_power = (uint16_t)(b[6] | ((uint16_t)b[7] << 8));
        raw->rx_power = (uint16_t)(b[8] | ((uint16_t)b[9] << 8));
        raw->flags    = b[10];
        raw->stat     = b[11];
        raw->seq      = b[12];
    }
    return r;
}

int sfpb_ddm_set_period(sfpb_t *dev, uint8_t period_100ms)
{
    return sfpb_write_reg8(dev, SFPB_REG_DDM_PERIOD, period_100ms);
}

void sfpb_ddm_invalidate_cal(sfpb_t *dev)
{
#if SFPB_DDM_EXT_CAL
    dev->cal_state = 0u;
#else
    (void)dev;
#endif
}

#if SFPB_DDM_EXT_CAL
static float be_float(const uint8_t *b)
{
    uint32_t u = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
    float f;

    memcpy(&f, &u, sizeof f);
    return f;
}

/* A0h byte 92: DDM implemented (b6), calibration type (b5 internal, b4
 * external); external constants from A2h 56..91. */
static int load_cal(sfpb_t *dev)
{
    uint8_t t, c[36];
    unsigned i;
    int r = sfpb_sfp_read(dev, SFPB_SFP_A0, 92u, &t, 1u);

    if (r != SFPB_OK) {
        return r;
    }
    if ((t & 0x40u) == 0u) {
        dev->cal_state = 3u;
        return SFPB_OK;
    }
    if ((t & 0x10u) == 0u) {
        dev->cal_state = 1u;
        return SFPB_OK;
    }
    r = sfpb_sfp_read(dev, SFPB_SFP_A2, 56u, c, sizeof c);
    if (r != SFPB_OK) {
        return r;
    }
    for (i = 0u; i < 5u; i++) {               /* 56: Rx_PWR(4) ... 72: Rx_PWR(0) */
        dev->cal_rx[4u - i] = be_float(&c[4u * i]);
    }
    for (i = 0u; i < 4u; i++) {               /* 76: TX_I, 80: TX_PWR, 84: T, 88: V */
        const uint8_t *p = &c[20u + 4u * i];
        dev->cal_slope[i]  = (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
        dev->cal_offset[i] = (int16_t)(uint16_t)(((uint16_t)p[2] << 8) | p[3]);
    }
    dev->cal_state = 2u;
    return SFPB_OK;
}

static uint16_t cal_u16(const sfpb_t *dev, unsigned k, uint16_t raw)
{
    int32_t v = (int32_t)(((uint32_t)dev->cal_slope[k] * raw) >> 8) + dev->cal_offset[k];

    return (uint16_t)((v < 0) ? 0 : (v > 0xFFFF) ? 0xFFFF : v);
}
#endif

int sfpb_ddm_read(sfpb_t *dev, sfpb_ddm_t *ddm)
{
    sfpb_ddm_raw_t raw;
    int32_t temp;
    uint32_t rx_nw;
    int r = sfpb_ddm_raw(dev, &raw);

    if (r != SFPB_OK) {
        return r;
    }
    if ((raw.stat & SFPB_DDM_VALID) == 0u) {
        return SFPB_ERR_NO_DDM;
    }
    temp  = raw.temp;
    rx_nw = (uint32_t)raw.rx_power * 100u;
    ddm->ext_cal = 0u;
#if SFPB_DDM_EXT_CAL
    if (dev->cal_state == 0u) {
        r = load_cal(dev);
        if (r != SFPB_OK) {
            return r;
        }
    }
    if (dev->cal_state == 3u) {
        return SFPB_ERR_NO_DDM;
    }
    if (dev->cal_state == 2u) {
        float x = (float)raw.rx_power, p = 0.0f;
        int i;
        raw.tx_bias  = cal_u16(dev, 0u, raw.tx_bias);
        raw.tx_power = cal_u16(dev, 1u, raw.tx_power);
        temp = (int32_t)(((int32_t)dev->cal_slope[2] * temp) / 256) + dev->cal_offset[2];
        raw.vcc      = cal_u16(dev, 3u, raw.vcc);
        for (i = 4; i >= 0; i--) {             /* Horner: sum Rx_PWR(i) * x^i */
            p = p * x + dev->cal_rx[i];
        }
        rx_nw = (p <= 0.0f) ? 0u : (uint32_t)(p * 100.0f + 0.5f);
        ddm->ext_cal = 1u;
    }
#endif
    ddm->temp_mc     = (temp * 1000) / 256;
    ddm->vcc_uv      = (uint32_t)raw.vcc * 100u;
    ddm->tx_bias_ua  = (uint32_t)raw.tx_bias * 2u;
    ddm->tx_power_nw = (uint32_t)raw.tx_power * 100u;
    ddm->rx_power_nw = rx_nw;
    ddm->flags       = raw.flags;
    ddm->seq         = raw.seq;
    return SFPB_OK;
}

#if SFPB_USE_I2C
int sfpb_ddm_alarms(sfpb_t *dev, sfpb_ddm_alarms_t *al)
{
    uint8_t b[6];
    int r = sfpb_sfp_read(dev, SFPB_SFP_A2, 112u, b, sizeof b);

    if (r == SFPB_OK) {
        al->alarm   = (uint16_t)(((uint16_t)b[0] << 8) | b[1]);
        al->warning = (uint16_t)(((uint16_t)b[4] << 8) | b[5]);
    }
    return r;
}
#endif

#endif /* SFPB_USE_DDM */

#if SFPB_USE_FLOAT
float sfpb_nw_to_dbm(uint32_t nw)
{
    return (nw == 0u) ? -40.0f : 10.0f * log10f((float)nw / 1.0e6f);
}
#endif
