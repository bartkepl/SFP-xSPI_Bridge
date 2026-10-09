/*
 * example_bridge.c - use of the SFP-xSPI bridge library in a CubeMX project.
 *
 * sfpb_config.h selects the transport and the handle (e.g. OCTOSPI, hospi1),
 * HOST_IRQ_N is an EXTI input (falling edge), HOST_RST_N a GPIO output.
 *
 * SPDX-License-Identifier: MIT
 */
#include <stdio.h>

#include "sfp_bridge.h"

static sfpb_t bridge;

/* ---- events --------------------------------------------------------------------- */

static void on_frame(void *user, uint8_t type, const uint8_t *data, uint16_t len)
{
    (void)user;
    (void)data;
    printf("frame type 0x%02X, %u B\r\n", type, len);
}

static void on_link(void *user, int up)
{
    (void)user;
    printf("link %s\r\n", up ? "UP" : "DOWN");
}

static void on_sfp(void *user, uint8_t status)
{
    (void)user;
    printf("SFP %s%s\r\n", (status & SFPB_ST_MOD_ABS) ? "removed" : "present",
           (status & SFPB_ST_LOS) ? ", LOS" : "");
}

static void on_error(void *user, int err)
{
    (void)user;
    printf("bridge: %s\r\n", sfpb_strerror(err));
}

static const sfpb_callbacks_t callbacks = {
    .rx_frame = on_frame, .link_change = on_link, .sfp_change = on_sfp, .error = on_error
};

/* HOST_IRQ_N falling edge (HAL EXTI callback of the application). */
void sfpb_example_exti(void)
{
    sfpb_irq_notify(&bridge);
}

/* ---- start-up --------------------------------------------------------------------- */

int sfpb_example_start(void)
{
    sfpb_sfp_info_t info;
    int r = sfpb_init(&bridge, NULL);            /* default port from sfpb_config.h */

    if (r != SFPB_OK) {
        printf("bridge: %s\r\n", sfpb_strerror(r));
        return r;
    }
    printf("bridge VERSION 0x%02X\r\n", bridge.version);
    sfpb_set_callbacks(&bridge, &callbacks, NULL);

    if (sfpb_sfp_info(&bridge, &info) == SFPB_OK) {
        printf("SFP %s %s, %u nm\r\n", info.vendor_name, info.vendor_pn, info.wavelength_nm);
    }
    return SFPB_OK;
}

/* ---- main loop step ----------------------------------------------------------------- */

void sfpb_example_poll(void)
{
    static const char hello[] = "Hello, SFP!";
    static uint32_t n;
    sfpb_ddm_t ddm;

    (void)sfpb_process(&bridge, 0);              /* frames, link and SFP events */

    if (sfpb_link_up(&bridge) == 1 && (++n % 1000u) == 0u) {
        (void)sfpb_send(&bridge, SFPB_TYPE_DATA, hello, (uint16_t)(sizeof hello - 1u));
        if (sfpb_ddm_read(&bridge, &ddm) == SFPB_OK) {
#if SFPB_USE_FLOAT
            printf("T %ld mC, RX %.2f dBm\r\n", (long)ddm.temp_mc, (double)sfpb_nw_to_dbm(ddm.rx_power_nw));
#else
            printf("T %ld mC, RX %lu nW\r\n", (long)ddm.temp_mc, (unsigned long)ddm.rx_power_nw);
#endif
        }
    }
}

/* ---- transparent UART at 1 Mbit/s, back to xSPI by HOST_RST_N ------------------------ */

int sfpb_example_uart_session(void)
{
    uint8_t st;
    int r = sfpb_uart_enter(&bridge, 1000000u, 0);   /* bridge leaves the xSPI mode */

    if (r != SFPB_OK) {
        return r;
    }
    /* ... UART traffic on J3 IO0 / IO1 ... */
    r = sfpb_mode_exit(&bridge);                     /* needs SFPB_RST_PORT / PIN */
    if (r == SFPB_OK) {
        r = sfpb_uart_status(&bridge, &st, 1);
        if (r == SFPB_OK && st != 0u) {
            printf("UART session: %s%s\r\n", (st & SFPB_UART_RX_OVF) ? "bytes lost " : "",
                   (st & SFPB_UART_FRAME_ERR) ? "framing errors" : "");
        }
    }
    return r;
}
