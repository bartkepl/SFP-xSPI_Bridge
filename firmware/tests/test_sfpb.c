/*
 * test_sfpb.c - host tests of the SFP-xSPI bridge library against the
 * transaction-level bridge model (mock_bridge.c).
 *
 * Build and run: make -C firmware/tests   (gcc, C11)
 *
 * SPDX-License-Identifier: MIT
 */
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "mock_bridge.h"
#include "sfp_bridge.h"

static int n_checks, n_fail;

#define CHECK(cond, msg)                                                         \
    do {                                                                         \
        n_checks++;                                                              \
        if (!(cond)) {                                                           \
            n_fail++;                                                            \
            printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, msg);               \
        }                                                                        \
    } while (0)
#define CHECK_EQ(a, b, msg)                                                      \
    do {                                                                         \
        long long a_ = (long long)(a), b_ = (long long)(b);                      \
        n_checks++;                                                              \
        if (a_ != b_) {                                                          \
            n_fail++;                                                            \
            printf("  FAIL %s:%d: %s (%lld != %lld)\n", __FILE__, __LINE__, msg, a_, b_); \
        }                                                                        \
    } while (0)

static mock_bridge_t ma, mb;
static sfpb_t da, db;
static sfpb_port_t pa, pb;

static void setup(int with_reset)
{
    mock_init(&ma);
    mock_init(&mb);
    mock_connect(&ma, &mb);
    mock_port(&ma, &pa, with_reset);
    mock_port(&mb, &pb, with_reset);
    CHECK_EQ(sfpb_init(&da, &pa), SFPB_OK, "init A");
    CHECK_EQ(sfpb_init(&db, &pb), SFPB_OK, "init B");
}

static void no_violations(const char *where)
{
    if (ma.violations || mb.violations) {
        printf("  %s: protocol violation A %u B %u: %s %s\n", where, ma.violations, mb.violations,
               ma.last_violation, mb.last_violation);
    }
    CHECK(ma.violations == 0u && mb.violations == 0u, "transactions follow the command table");
}

/* ------------------------------------------------------------------------------- */

static void test_init(void)
{
    sfpb_t d;
    sfpb_port_t p;

    puts("init");
    setup(0);
    CHECK_EQ(da.version, 0x01, "VERSION read by init");
    CHECK_EQ(ma.irq_en, SFPB_IRQ_MASK_DEFAULT, "IRQ_EN = default mask");
    CHECK_EQ(da.lines, 8, "data lines from the configuration");
    mock_init(&ma);
    ma.absent = 1;
    mock_port(&ma, &p, 0);
    CHECK_EQ(sfpb_init(&d, &p), SFPB_ERR_NO_DEVICE, "no bridge -> NO_DEVICE");
    CHECK(ma.time_us >= SFPB_READY_TIMEOUT_MS * 1000u, "READ_ID retried for the ready timeout");
    CHECK_EQ(sfpb_init(&d, NULL), SFPB_ERR_PARAM, "CUSTOM transport needs a port");
    p.max_lines = 4u;
    ma.absent = 0;
    CHECK_EQ(sfpb_init(&d, &p), SFPB_OK, "init with a 4-line port");
    CHECK_EQ(d.lines, 4, "data lines limited by the port");
    CHECK_EQ(sfpb_set_data_lines(&d, 8), SFPB_ERR_PARAM, "8 lines rejected on a 4-line port");
    CHECK_EQ(sfpb_set_data_lines(&d, 3), SFPB_ERR_PARAM, "3 lines rejected");
    CHECK_EQ(sfpb_set_data_lines(&d, 1), SFPB_OK, "1 line accepted");
    CHECK_EQ(strcmp(sfpb_strerror(SFPB_ERR_NACK), "I2C NACK"), 0, "strerror");
    CHECK_EQ(strcmp(sfpb_strerror(-99), "unknown error"), 0, "strerror unknown");
}

static void test_registers(void)
{
    uint8_t b[16], r[16];
    sfpb_status_t st;
    unsigned i;

    puts("registers");
    setup(0);
    for (i = 0u; i < sizeof b; i++) {
        b[i] = (uint8_t)(0xA0u + i);
    }
    CHECK_EQ(sfpb_write_regs(&da, SFPB_REG_I2C_BUF, b, sizeof b), SFPB_OK, "write 16 B (2 transactions)");
    CHECK_EQ(memcmp(ma.i2c_buf, b, sizeof b), 0, "I2C_BUF written");
    CHECK_EQ(sfpb_read_regs(&da, SFPB_REG_I2C_BUF, r, sizeof r), SFPB_OK, "read 16 B");
    CHECK_EQ(memcmp(r, b, sizeof b), 0, "I2C_BUF read back");
    CHECK_EQ(sfpb_read_regs(&da, 0, r, 0), SFPB_ERR_PARAM, "zero length rejected");

    CHECK_EQ(sfpb_get_status(&da, &st), SFPB_OK, "status snapshot");
    CHECK_EQ(st.ctrl, SFPB_CTRL_RESET_VAL, "CTRL after reset");
    CHECK_EQ(st.tx_space, MOCK_TX_FIFO, "TX_SPACE empty FIFO");
    CHECK_EQ(st.rx_level, 0, "RX_LEVEL empty");
    CHECK(st.status_fast & SFPB_SF_TX_EMPTY, "TX_EMPTY");
    CHECK_EQ(sfpb_link_up(&da), 0, "link down");
    CHECK_EQ(sfpb_wait_link(&da, 5), SFPB_ERR_TIMEOUT, "wait_link timeout");
    mock_set_link(&ma, 1);
    CHECK_EQ(sfpb_wait_link(&da, 5), SFPB_OK, "wait_link");
    CHECK_EQ(sfpb_mode_sel(&da), 1, "MODE_SEL jumper open");

    CHECK_EQ(sfpb_set_loopback(&da, 1), SFPB_OK, "loopback on");
    CHECK_EQ(ma.ctrl, SFPB_CTRL_RESET_VAL | SFPB_CTRL_LB_NEAR, "CTRL.LB_NEAR set, other bits kept");
    CHECK_EQ(sfpb_set_laser_off(&da, 1), SFPB_OK, "laser off");
    CHECK_EQ(sfpb_set_tx_enable(&da, 0), SFPB_OK, "TX disable");
    CHECK_EQ(ma.ctrl, SFPB_CTRL_RX_EN | SFPB_CTRL_LB_NEAR | SFPB_CTRL_SFP_TX_DIS, "CTRL bits");
    CHECK_EQ(sfpb_ctrl_update(&da, SFPB_CTRL_SOFT_RST, SFPB_CTRL_SOFT_RST), SFPB_ERR_PARAM,
             "pulse bits not accepted by ctrl_update");
    CHECK_EQ(ma.soft_resets, 0, "no soft reset");
    no_violations("registers");
}

static void test_frames(void)
{
    static uint8_t tx[SFPB_MAX_PAYLOAD], rx[SFPB_MAX_PAYLOAD];
    static const uint16_t sizes[] = { 1, 11, 255, 256, 1024 };
    static const uint8_t lines[] = { 8, 4, 1 };
    uint16_t len;
    uint8_t type;
    unsigned i, k, l;
    int bad;

    puts("frames");
    setup(0);
    mock_set_link(&ma, 1);
    for (i = 0u; i < sizeof tx; i++) {
        tx[i] = (uint8_t)(i * 7u + 3u);
    }
    for (l = 0u; l < sizeof lines; l++) {
        sfpb_set_data_lines(&da, lines[l]);
        sfpb_set_data_lines(&db, lines[l]);
        bad = 0;
        for (k = 0u; k < sizeof sizes / sizeof sizes[0]; k++) {
            if (sfpb_send(&da, (uint8_t)(0x10u + k), tx, sizes[k]) != SFPB_OK) {
                bad++;
            }
        }
        CHECK_EQ(bad, 0, "5 frames sent");
        for (k = 0u; k < sizeof sizes / sizeof sizes[0]; k++) {
            memset(rx, 0, sizeof rx);
            if (sfpb_recv(&db, &type, rx, sizeof rx, &len) != SFPB_OK || type != 0x10u + k ||
                len != sizes[k] || memcmp(rx, tx, len) != 0) {
                bad++;
            }
        }
        CHECK_EQ(bad, 0, "5 frames received intact and in order");
        CHECK_EQ(sfpb_recv(&db, &type, rx, sizeof rx, &len), SFPB_ERR_EMPTY, "RX FIFO empty");
    }
    CHECK_EQ(ma.cnt[SFPB_CNT_FRAMES_TX], 15, "FRAMES_TX");

    /* truncation: rest of the frame dropped, next frame intact */
    sfpb_send(&da, 0x00, tx, 100);
    sfpb_send(&da, 0x01, tx, 5);
    CHECK_EQ(sfpb_recv(&db, &type, rx, 10, &len), SFPB_ERR_TRUNC, "frame truncated");
    CHECK_EQ(len, 100, "real length reported");
    CHECK_EQ(sfpb_recv(&db, &type, rx, sizeof rx, &len), SFPB_OK, "next frame after truncation");
    CHECK(type == 0x01 && len == 5 && memcmp(rx, tx, 5) == 0, "next frame intact");
    CHECK_EQ(sfpb_recv(&db, &type, NULL, 0, &len), SFPB_ERR_EMPTY, "empty, NULL buffer allowed");

    CHECK_EQ(sfpb_send(&da, 0, tx, 0), SFPB_ERR_PARAM, "LEN 0 rejected");
    CHECK_EQ(sfpb_send(&da, 0, tx, SFPB_MAX_PAYLOAD + 1u), SFPB_ERR_PARAM, "LEN > 1024 rejected");
    CHECK_EQ(sfpb_send(&da, 0, NULL, 4), SFPB_ERR_PARAM, "NULL data rejected");

    /* link down: frames wait in the TX FIFO until it is full */
    mock_set_link(&ma, 0);
    for (i = 0u; i < 3u; i++) {
        CHECK_EQ(sfpb_send(&da, 0x00, tx, 1024), SFPB_OK, "frame queued while the link is down");
    }
    CHECK_EQ(sfpb_send(&da, 0x00, tx, 1024), SFPB_ERR_TIMEOUT, "TX FIFO full -> timeout");
    CHECK_EQ(sfpb_send_timeout(&da, 0x00, tx, 1013, 0), SFPB_ERR_TIMEOUT, "1013 + 3 B > TX_SPACE 1015");
    CHECK_EQ(sfpb_send_timeout(&da, 0x00, tx, 1000, 0), SFPB_OK, "1000 B fits in TX_SPACE (no TX_READY)");
    CHECK_EQ(sfpb_wait_tx_empty(&da, 2), SFPB_ERR_TIMEOUT, "TX not empty while the link is down");
    mock_set_link(&ma, 1);
    CHECK_EQ(sfpb_wait_tx_empty(&da, 2), SFPB_OK, "TX empty after the link is up");
    for (i = 0u; i < 4u; i++) {
        CHECK_EQ(sfpb_recv_timeout(&db, &type, rx, sizeof rx, &len, 5), SFPB_OK, "queued frame received");
    }
    CHECK_EQ(sfpb_recv_timeout(&db, &type, rx, sizeof rx, &len, 5), SFPB_ERR_TIMEOUT, "recv timeout");

    /* bus error in the payload: TX_ABORT drops the uncommitted header */
    ma.fail_data_after = 3;                   /* READ_STATUS, header, payload */
    CHECK_EQ(sfpb_send(&da, 0x00, tx, 20), SFPB_ERR_IO, "transport error reported");
    CHECK_EQ(ma.aborts, 1, "TX_ABORT issued");
    CHECK_EQ(ma.txp_n, 0, "uncommitted bytes dropped");
    CHECK_EQ(sfpb_send(&da, 0x22, tx, 20), SFPB_OK, "next frame");
    CHECK(sfpb_recv(&db, &type, rx, sizeof rx, &len) == SFPB_OK && type == 0x22 && len == 20, "next frame intact");

    /* inconsistent RX stream */
    mb.rx[0] = 0x00; mb.rx[1] = 0x00; mb.rx[2] = 0x00; mb.rx[3] = 0x55; mb.rx_n = 4;
    db.rx_left = 0;
    CHECK_EQ(sfpb_recv(&db, &type, rx, sizeof rx, &len), SFPB_ERR_PROTO, "LEN 0 in the RX stream -> PROTO");
    no_violations("frames");
}

/* ------------------------------------------------------------------------------- */

static struct {
    int frames, link_up, link_down, sfp, errors, last_err, tx_empty;
    uint16_t last_len;
} ev;

static void on_rx(void *u, uint8_t type, const uint8_t *d, uint16_t len)
{
    (void)u; (void)type; (void)d;
    ev.frames++;
    ev.last_len = len;
}
static void on_link(void *u, int up) { (void)u; if (up) ev.link_up++; else ev.link_down++; }
static void on_sfp(void *u, uint8_t st) { (void)u; (void)st; ev.sfp++; }
static void on_err(void *u, int e) { (void)u; ev.errors++; ev.last_err = e; }
static void on_txe(void *u) { (void)u; ev.tx_empty++; }

static void test_events(void)
{
    static const sfpb_callbacks_t cb = { on_rx, on_link, on_sfp, on_txe, NULL, on_err };
    uint8_t d[64] = { 0 };
    int r;

    puts("events");
    setup(0);
    memset(&ev, 0, sizeof ev);
    sfpb_set_callbacks(&db, &cb, NULL);
    CHECK_EQ(sfpb_process(&db, 0), 0, "nothing without a notification");
    mock_set_link(&ma, 1);
    CHECK_EQ(mock_irq_n(&mb), 0, "HOST_IRQ_N low on LINK_CHG");
    sfpb_irq_notify(&db);
    r = sfpb_process(&db, 0);
    CHECK_EQ(r, SFPB_IRQ_LINK_CHG, "LINK_CHG handled");
    CHECK_EQ(ev.link_up, 1, "link_change(up)");
    CHECK_EQ(mock_irq_n(&mb), 1, "HOST_IRQ_N released (W1C)");
    sfpb_send(&da, 0x00, d, 64);
    sfpb_send(&da, 0x00, d, 10);
    sfpb_send(&da, 0x00, d, 3);
    sfpb_irq_notify(&db);
    sfpb_process(&db, 0);
    CHECK_EQ(ev.frames, 3, "all frames delivered by one process()");
    CHECK_EQ(ev.last_len, 3, "last frame length");
    mock_set_module(&mb, 0);
    CHECK_EQ(sfpb_process(&db, 1), SFPB_IRQ_SFP_CHG, "poll mode without notification");
    CHECK_EQ(ev.sfp, 1, "sfp_change");
    mock_irq_set(&mb, SFPB_IRQ_ERR);
    sfpb_process(&db, 1);
    CHECK(ev.errors == 1 && ev.last_err == SFPB_ERR_LINK, "error(SFPB_ERR_LINK) on IRQ ERR");
    mock_set_link(&ma, 0);
    sfpb_process(&db, 1);
    CHECK_EQ(ev.link_down, 1, "link_change(down)");
    CHECK_EQ(sfpb_irq_enable(&db, SFPB_IRQ_ALL), SFPB_OK, "IRQ_EN all");
    CHECK_EQ(mb.irq_en, SFPB_IRQ_ALL, "IRQ_EN written");
    CHECK_EQ(sfpb_soft_reset(&db), SFPB_OK, "soft reset");
    CHECK_EQ(mb.soft_resets, 1, "bridge reset");
    CHECK_EQ(mb.irq_en, SFPB_IRQ_ALL, "IRQ_EN restored after the reset");
    no_violations("events");
}

/* ------------------------------------------------------------------------------- */

static void put_str(uint8_t *mem, unsigned off, const char *s, unsigned n)
{
    unsigned i, l = (unsigned)strlen(s);

    for (i = 0u; i < n; i++) {
        mem[off + i] = (i < l) ? (uint8_t)s[i] : ' ';
    }
}

static void fill_a0(mock_bridge_t *m)
{
    unsigned i;
    uint8_t s = 0;

    memset(m->a0, 0, sizeof m->a0);
    m->a0[0] = 0x03; m->a0[2] = 0x07; m->a0[11] = 0x01; m->a0[12] = 13; m->a0[14] = 20;
    put_str(m->a0, 20, "ACME OPTICS", 16);
    put_str(m->a0, 40, "SFP-1G-LX", 16);
    put_str(m->a0, 56, "A1", 4);
    m->a0[60] = 0x05; m->a0[61] = 0x1E;          /* 1310 nm */
    put_str(m->a0, 68, "SN123456", 16);
    put_str(m->a0, 84, "26100901", 8);
    m->a0[92] = 0x68;                            /* DDM, internal cal, addr change */
    m->a0[94] = 0x08;
    for (i = 0; i < 63; i++) s = (uint8_t)(s + m->a0[i]);
    m->a0[63] = s;
    for (s = 0, i = 64; i < 95; i++) s = (uint8_t)(s + m->a0[i]);
    m->a0[95] = s;
}

static void test_sfp(void)
{
    sfpb_sfp_info_t info;
    uint8_t buf[256], w[20];
    unsigned i;
    int bad = 0;

    puts("sfp i2c");
    setup(0);
    fill_a0(&ma);
    for (i = 0u; i < 256u; i++) {
        ma.a2[i] = (uint8_t)(255u - i);
    }
    CHECK_EQ(sfpb_sfp_present(&da), 1, "module present");
    CHECK_EQ(sfpb_sfp_info(&da, &info), SFPB_OK, "serial ID");
    CHECK_EQ(strcmp(info.vendor_name, "ACME OPTICS"), 0, "vendor name trimmed");
    CHECK_EQ(strcmp(info.vendor_pn, "SFP-1G-LX"), 0, "vendor PN");
    CHECK_EQ(strcmp(info.vendor_rev, "A1"), 0, "vendor rev");
    CHECK_EQ(strcmp(info.vendor_sn, "SN123456"), 0, "vendor SN");
    CHECK_EQ(strcmp(info.date_code, "26100901"), 0, "date code");
    CHECK_EQ(info.wavelength_nm, 1310, "wavelength");
    CHECK_EQ(info.br_nominal_mbd, 1300, "nominal bit rate");
    CHECK(info.cc_base_ok && info.cc_ext_ok, "checksums");
    CHECK_EQ(info.diag_type, 0x68, "diagnostic type");
    CHECK_EQ(sfpb_sfp_read(&da, SFPB_SFP_A2, 0, buf, 256), SFPB_OK, "read 256 B (2 commands)");
    for (i = 0u; i < 256u; i++) {
        if (buf[i] != ma.a2[i]) bad++;
    }
    CHECK_EQ(bad, 0, "A2h 0..255 read back");
    CHECK_EQ(sfpb_sfp_read(&da, SFPB_SFP_A2, 200, buf, 57), SFPB_ERR_PARAM, "offset + len > 256 rejected");

    for (i = 0u; i < sizeof w; i++) {
        w[i] = (uint8_t)(0x40u + i);
    }
    CHECK_EQ(sfpb_sfp_write(&da, SFPB_SFP_A2, 126, w, sizeof w), SFPB_OK,
             "write 20 B from 126 (pages, EEPROM busy NACK retried)");
    CHECK_EQ(memcmp(&ma.a2[126], w, sizeof w), 0, "EEPROM written");
    CHECK_EQ(sfpb_sfp_read(&da, SFPB_SFP_A2, 126, buf, sizeof w), SFPB_OK, "read after write (NACK retried)");
    CHECK_EQ(memcmp(buf, w, sizeof w), 0, "read back");
    CHECK_EQ(sfpb_sfp_read(&da, 0x52, 0, buf, 4), SFPB_ERR_NACK, "unknown device -> NACK");
    ma.eeprom_busy_cmds = 100;
    CHECK_EQ(sfpb_sfp_read(&da, SFPB_SFP_A0, 0, buf, 4), SFPB_ERR_NACK, "NACK after the EEPROM timeout");
    ma.eeprom_busy_cmds = 0;
    ma.i2c_busy_xfers = 1000000;
    CHECK_EQ(sfpb_sfp_read(&da, SFPB_SFP_A0, 0, buf, 4), SFPB_ERR_TIMEOUT, "BUSY stuck -> timeout");
    ma.i2c_busy = 0;
    ma.i2c_busy_xfers = 3;
    mock_set_module(&ma, 0);
    CHECK_EQ(sfpb_sfp_present(&da), 0, "module absent");
    CHECK_EQ(sfpb_sfp_read(&da, SFPB_SFP_A0, 0, buf, 4), SFPB_ERR_BAD_CMD, "no module -> BAD_CMD");
    no_violations("sfp");
}

static void put16(uint8_t *m, unsigned off, uint16_t v)
{
    m[off] = (uint8_t)(v >> 8);
    m[off + 1] = (uint8_t)v;
}

static void put_float(uint8_t *m, unsigned off, float f)
{
    uint32_t u;

    memcpy(&u, &f, 4);
    m[off] = (uint8_t)(u >> 24); m[off + 1] = (uint8_t)(u >> 16);
    m[off + 2] = (uint8_t)(u >> 8); m[off + 3] = (uint8_t)u;
}

static void test_ddm(void)
{
    sfpb_ddm_raw_t raw;
    sfpb_ddm_t d;
    sfpb_ddm_alarms_t al;

    puts("ddm");
    setup(0);
    fill_a0(&ma);
    put16(ma.a2, 96, (uint16_t)(int16_t)(25 * 256 + 128));   /* 25.5 C   */
    put16(ma.a2, 98, 33000);                                  /* 3.3 V    */
    put16(ma.a2, 100, 3000);                                  /* 6 mA     */
    put16(ma.a2, 102, 5000);                                  /* 0.5 mW   */
    put16(ma.a2, 104, 1000);                                  /* 0.1 mW   */
    ma.a2[110] = SFPB_DDMF_RX_LOS;
    ma.a2[112] = 0x80; ma.a2[113] = 0x01; ma.a2[116] = 0x40; ma.a2[117] = 0x02;
    CHECK_EQ(sfpb_ddm_raw(&da, &raw), SFPB_OK, "DDM raw");
    CHECK(raw.temp == 25 * 256 + 128 && raw.vcc == 33000 && raw.rx_power == 1000, "raw values little-endian");
    CHECK_EQ(raw.stat, SFPB_DDM_VALID, "DDM_STAT.VALID");
    CHECK_EQ(sfpb_ddm_read(&da, &d), SFPB_OK, "DDM converted");
    CHECK_EQ(d.temp_mc, 25500, "temperature");
    CHECK_EQ(d.vcc_uv, 3300000, "Vcc");
    CHECK_EQ(d.tx_bias_ua, 6000, "TX bias");
    CHECK_EQ(d.tx_power_nw, 500000, "TX power");
    CHECK_EQ(d.rx_power_nw, 100000, "RX power");
    CHECK_EQ(d.flags, SFPB_DDMF_RX_LOS, "flags");
    CHECK_EQ(d.ext_cal, 0, "internal calibration");
    CHECK_EQ(sfpb_ddm_alarms(&da, &al), SFPB_OK, "alarms");
    CHECK(al.alarm == 0x8001 && al.warning == 0x4002, "alarm / warning flags");
    CHECK(fabsf(sfpb_nw_to_dbm(1000000u)) < 0.001f, "1 mW = 0 dBm");
    CHECK(fabsf(sfpb_nw_to_dbm(100000u) + 10.0f) < 0.001f, "0.1 mW = -10 dBm");

    /* negative temperature */
    put16(ma.a2, 96, (uint16_t)(int16_t)(-10 * 256));
    sfpb_ddm_read(&da, &d);
    CHECK_EQ(d.temp_mc, -10000, "negative temperature");

    /* external calibration: slope 2.0 (0x0200), offsets, RX polynomial */
    ma.a0[92] = 0x58;
    sfpb_ddm_invalidate_cal(&da);
    put_float(ma.a2, 56, 0.0f);   /* Rx_PWR(4) */
    put_float(ma.a2, 60, 0.0f);   /* Rx_PWR(3) */
    put_float(ma.a2, 64, 0.0f);   /* Rx_PWR(2) */
    put_float(ma.a2, 68, 2.0f);   /* Rx_PWR(1) */
    put_float(ma.a2, 72, 10.0f);  /* Rx_PWR(0) */
    put16(ma.a2, 76, 0x0200); put16(ma.a2, 78, 100);                 /* TX_I    */
    put16(ma.a2, 80, 0x0100); put16(ma.a2, 82, (uint16_t)-1000);     /* TX_PWR  */
    put16(ma.a2, 84, 0x0100); put16(ma.a2, 86, (uint16_t)(int16_t)(5 * 256)); /* T */
    put16(ma.a2, 88, 0x0080); put16(ma.a2, 90, 0);                   /* V       */
    put16(ma.a2, 96, (uint16_t)(20 * 256));
    CHECK_EQ(sfpb_ddm_read(&da, &d), SFPB_OK, "DDM external calibration");
    CHECK_EQ(d.ext_cal, 1, "external calibration applied");
    CHECK_EQ(d.tx_bias_ua, (3000 * 2 + 100) * 2, "TX bias calibrated");
    CHECK_EQ(d.tx_power_nw, (5000 - 1000) * 100, "TX power calibrated");
    CHECK_EQ(d.temp_mc, 25000, "temperature calibrated");
    CHECK_EQ(d.vcc_uv, 16500 * 100, "Vcc calibrated");
    CHECK_EQ(d.rx_power_nw, (1000 * 2 + 10) * 100, "RX power polynomial");

    /* module without DDM */
    ma.a0[92] = 0x00;
    sfpb_ddm_invalidate_cal(&da);
    CHECK_EQ(sfpb_ddm_read(&da, &d), SFPB_ERR_NO_DDM, "no DDM (A0h byte 92)");
    ma.ddm_valid = 0;
    CHECK_EQ(sfpb_ddm_read(&da, &d), SFPB_ERR_NO_DDM, "DDM_STAT.VALID = 0");
    CHECK_EQ(sfpb_ddm_set_period(&da, 0), SFPB_OK, "DDM period");
    CHECK_EQ(ma.ddm_period, 0, "DDM_PERIOD written");
    no_violations("ddm");
}

/* ------------------------------------------------------------------------------- */

static void test_uart(void)
{
    uint32_t baud;
    uint8_t st, b[4] = { 1, 2, 3, 4 };

    puts("uart");
    CHECK_EQ(sfpb_uart_div(115200), 434, "UART_DIV 115200");
    CHECK_EQ(sfpb_uart_div(1000000), 50, "UART_DIV 1 Mbit/s");
    CHECK_EQ(sfpb_uart_div(3000000), 17, "UART_DIV 3 Mbit/s");
    CHECK_EQ(sfpb_uart_div(6250000), 8, "UART_DIV minimum");
    CHECK_EQ(sfpb_uart_div(7000000), 0, "too fast");
    CHECK_EQ(sfpb_uart_div(700), 0, "too slow");
    CHECK_EQ(sfpb_uart_div(0), 0, "zero");

    setup(0);
    CHECK_EQ(sfpb_uart_set_baud(&da, 1000000), SFPB_OK, "set 1 Mbit/s");
    CHECK_EQ(ma.uart_div, 50, "UART_DIV written");
    CHECK_EQ(sfpb_uart_get_baud(&da, &baud), SFPB_OK, "get baud");
    CHECK_EQ(baud, 1000000, "baud read back");
    CHECK_EQ(sfpb_uart_set_baud(&da, 10000000), SFPB_ERR_PARAM, "out of range");
    CHECK_EQ(sfpb_uart_set_rtscts(&da, 1), SFPB_OK, "RTS/CTS");
    CHECK_EQ(ma.mode, SFPB_MODE_RTSCTS, "MODE_CTRL.RTSCTS_EN");
    CHECK_EQ(ma.soft_resets, 0, "RTSCTS_EN alone does not reset");
    CHECK_EQ(sfpb_uart_set_rtscts(&da, 0), SFPB_OK, "RTS/CTS off");
    CHECK_EQ(ma.mode, 0, "MODE_CTRL.RTSCTS_EN cleared");
    CHECK_EQ(sfpb_mode_exit(&da), SFPB_ERR_NOT_SUPPORTED, "no reset pin");

    setup(1);
    ma.uart_status = SFPB_UART_FRAME_ERR;    /* from an earlier session */
    CHECK_EQ(sfpb_uart_enter(&da, 921600, 1), SFPB_OK, "enter UART mode");
    CHECK_EQ(ma.mode, SFPB_MODE_UART | SFPB_MODE_RTSCTS, "MODE_CTRL");
    CHECK_EQ(ma.uart_div, 54, "UART_DIV kept for the UART mode");
    CHECK_EQ(ma.soft_resets, 1, "mode change resets the bridge");
    CHECK_EQ(sfpb_send(&da, 0, b, 4), SFPB_ERR_STATE, "no xSPI access in the UART mode");
    CHECK_EQ(ma.offline_xfers, 0, "no transaction sent in the UART mode");
    ma.uart_status |= SFPB_UART_RX_OVF;
    CHECK_EQ(sfpb_mode_exit(&da), SFPB_OK, "back to xSPI (HOST_RST_N)");
    CHECK_EQ(ma.hard_resets, 1, "hardware reset");
    CHECK_EQ(ma.mode, 0, "MODE_CTRL cleared");
    CHECK_EQ(sfpb_uart_status(&da, &st, 1), SFPB_OK, "UART_STATUS");
    CHECK_EQ(st, SFPB_UART_FRAME_ERR | SFPB_UART_RX_OVF, "UART_STATUS kept over HOST_RST_N");
    CHECK_EQ(ma.uart_status, 0, "UART_STATUS cleared (W1C)");
    CHECK_EQ(ma.irq_en, SFPB_IRQ_MASK_DEFAULT, "IRQ_EN restored after HOST_RST_N");

    CHECK_EQ(sfpb_echo_enter(&da), SFPB_OK, "enter echo mode");
    CHECK_EQ(ma.mode, SFPB_MODE_ECHO, "MODE_CTRL.FRAME_ECHO");
    CHECK_EQ(sfpb_link_up(&da), SFPB_ERR_STATE, "no xSPI access in the echo mode");
    CHECK_EQ(sfpb_hw_reset(&da), SFPB_OK, "hardware reset");
    CHECK_EQ(sfpb_link_up(&da), 0, "xSPI access again");

    CHECK_EQ(sfpb_clear_counters(&da), SFPB_OK, "clear counters");
    no_violations("uart");
}

static void test_counters(void)
{
    sfpb_counters_t c;
    uint8_t d[8] = { 0 };

    puts("counters");
    setup(0);
    mock_set_link(&ma, 1);
    sfpb_send(&da, 0, d, 8);
    sfpb_send(&da, 0, d, 8);
    mb.cnt[SFPB_CNT_CRC_ERR] = 0x12345678u;
    CHECK_EQ(sfpb_read_counters(&da, &c), SFPB_OK, "counters A");
    CHECK_EQ(c.n.frames_tx, 2, "FRAMES_TX");
    CHECK_EQ(sfpb_read_counters(&db, &c), SFPB_OK, "counters B");
    CHECK_EQ(c.n.frames_rx, 2, "FRAMES_RX");
    CHECK_EQ(c.v[SFPB_CNT_CRC_ERR], 0x12345678u, "32-bit little-endian");
    CHECK_EQ(sfpb_clear_counters(&db), SFPB_OK, "CNT_CLR");
    sfpb_read_counters(&db, &c);
    CHECK(c.n.frames_rx == 0 && c.n.crc_err == 0, "counters cleared");
    CHECK_EQ(mb.ctrl, SFPB_CTRL_RESET_VAL, "CTRL kept by CNT_CLR");
    no_violations("counters");
}

int main(void)
{
    test_init();
    test_registers();
    test_frames();
    test_events();
    test_sfp();
    test_ddm();
    test_uart();
    test_counters();
    printf("%s: %d checks, %d failed\n", n_fail ? "FAIL" : "PASS", n_checks, n_fail);
    return n_fail ? 1 : 0;
}
