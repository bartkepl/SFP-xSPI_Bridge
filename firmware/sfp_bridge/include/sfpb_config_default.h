/*
 * sfpb_config_default.h - compile-time configuration of the SFP-xSPI bridge
 * library: the user file sfpb_config.h (template: config/sfpb_config_template.h)
 * followed by the defaults of everything it does not define.
 *
 * The user file is found in this order:
 *   1. SFPB_CONFIG_FILE defined on the compiler command line
 *      (e.g. -DSFPB_CONFIG_FILE=\"my_cfg.h\"),
 *   2. sfpb_config.h on the include path (when the compiler has __has_include),
 *   3. none - SFPB_NO_CONFIG_FILE must then be defined to confirm the defaults.
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef SFPB_CONFIG_DEFAULT_H
#define SFPB_CONFIG_DEFAULT_H

#if defined(SFPB_CONFIG_FILE)
#include SFPB_CONFIG_FILE
#elif defined(__has_include)
#if __has_include("sfpb_config.h")
#include "sfpb_config.h"
#elif !defined(SFPB_NO_CONFIG_FILE)
#error "sfpb_config.h not found (copy config/sfpb_config_template.h) or define SFPB_NO_CONFIG_FILE"
#endif
#elif !defined(SFPB_NO_CONFIG_FILE)
#include "sfpb_config.h"
#endif

/* ---- Transport -------------------------------------------------------------- */
#define SFPB_TRANSPORT_CUSTOM  0   /* port supplied by the application          */
#define SFPB_TRANSPORT_OSPI    1   /* HAL_OSPI  (L4+, L5, U5, H7A3/B3, H72x...)  */
#define SFPB_TRANSPORT_XSPI    2   /* HAL_XSPI  (H5, H7R/S, N6, U5 new HAL...)   */
#define SFPB_TRANSPORT_QSPI    3   /* HAL_QSPI  (F4, F7, H7, L4, G4)             */
#define SFPB_TRANSPORT_SPI     4   /* HAL_SPI + GPIO chip select (any STM32)     */

#ifndef SFPB_TRANSPORT
#define SFPB_TRANSPORT SFPB_TRANSPORT_OSPI
#endif

/* Data lines of the frame commands (TX_WRITE_x / RX_READ_x): 1, 4 or 8. */
#ifndef SFPB_DATA_LINES
#if SFPB_TRANSPORT == SFPB_TRANSPORT_QSPI
#define SFPB_DATA_LINES 4
#elif SFPB_TRANSPORT == SFPB_TRANSPORT_SPI
#define SFPB_DATA_LINES 1
#else
#define SFPB_DATA_LINES 8
#endif
#endif

#if (SFPB_DATA_LINES != 1) && (SFPB_DATA_LINES != 4) && (SFPB_DATA_LINES != 8)
#error "SFPB_DATA_LINES must be 1, 4 or 8"
#endif
#if (SFPB_TRANSPORT == SFPB_TRANSPORT_QSPI) && (SFPB_DATA_LINES > 4)
#error "QUADSPI supports at most 4 data lines"
#endif
#if (SFPB_TRANSPORT == SFPB_TRANSPORT_SPI) && (SFPB_DATA_LINES != 1)
#error "SPI transport supports 1 data line only"
#endif

/* HAL header of the target (CubeMX projects: main.h includes stm32xxxx_hal.h). */
#ifndef SFPB_HAL_HEADER
#define SFPB_HAL_HEADER "main.h"
#endif

/* Peripheral handles of the default port (CubeMX global names). */
#ifndef SFPB_OSPI_HANDLE
#define SFPB_OSPI_HANDLE hospi1
#endif
#ifndef SFPB_XSPI_HANDLE
#define SFPB_XSPI_HANDLE hxspi1
#endif
#ifndef SFPB_QSPI_HANDLE
#define SFPB_QSPI_HANDLE hqspi
#endif
#ifndef SFPB_SPI_HANDLE
#define SFPB_SPI_HANDLE hspi1
#endif
/* SPI chip select (GPIO output, idle high) - required for the SPI transport:
 *   #define SFPB_SPI_CS_PORT GPIOA
 *   #define SFPB_SPI_CS_PIN  GPIO_PIN_4                                         */

/* HOST_RST_N (optional GPIO output, idle high). Without it hardware reset,
 * leaving the UART / echo mode and sfpb_uart_exit() are not available:
 *   #define SFPB_RST_PORT GPIOB
 *   #define SFPB_RST_PIN  GPIO_PIN_0                                            */

/* HAL call timeout of one transaction [ms]. */
#ifndef SFPB_HAL_TIMEOUT_MS
#define SFPB_HAL_TIMEOUT_MS 10u
#endif

/* DMA for data phases of at least SFPB_DMA_MIN_LEN bytes (the DMA channel and
 * its interrupt configured by CubeMX; data buffers must be DMA-accessible and,
 * on cores with a data cache, cache-maintained by the application). */
#ifndef SFPB_USE_DMA
#define SFPB_USE_DMA 0
#endif
#ifndef SFPB_DMA_MIN_LEN
#define SFPB_DMA_MIN_LEN 32u
#endif

/* ---- Features --------------------------------------------------------------- */
#ifndef SFPB_USE_I2C            /* SFP module memory: read / write, serial ID     */
#define SFPB_USE_I2C 1
#endif
#ifndef SFPB_USE_DDM            /* digital diagnostics (DDM_* registers)           */
#define SFPB_USE_DDM 1
#endif
#ifndef SFPB_DDM_EXT_CAL        /* SFF-8472 external calibration (float math)      */
#define SFPB_DDM_EXT_CAL 1
#endif
#ifndef SFPB_USE_FLOAT          /* float helpers (dBm conversion)                  */
#define SFPB_USE_FLOAT 1
#endif
#ifndef SFPB_USE_UART           /* UART_DIV, MODE_CTRL, UART_STATUS, echo          */
#define SFPB_USE_UART 1
#endif
#ifndef SFPB_USE_EVENTS         /* sfpb_process() with callbacks (HOST_IRQ_N)      */
#define SFPB_USE_EVENTS 1
#endif

#if SFPB_USE_DDM && !SFPB_USE_I2C && SFPB_DDM_EXT_CAL
#error "SFPB_DDM_EXT_CAL needs SFPB_USE_I2C (calibration constants are read from A2h)"
#endif

/* IRQ_EN written by sfpb_init() (SFPB_IRQ_* bits). */
#ifndef SFPB_IRQ_MASK_DEFAULT
#if SFPB_USE_EVENTS
#define SFPB_IRQ_MASK_DEFAULT (SFPB_IRQ_RX_FRAME | SFPB_IRQ_LINK_CHG | SFPB_IRQ_SFP_CHG | SFPB_IRQ_ERR)
#else
#define SFPB_IRQ_MASK_DEFAULT 0u
#endif
#endif

/* Receive buffer of sfpb_process() (bytes; frames longer are dropped). */
#ifndef SFPB_RX_BUF_SIZE
#define SFPB_RX_BUF_SIZE SFPB_MAX_PAYLOAD
#endif

/* ---- Timeouts [ms] ------------------------------------------------------------ */
#ifndef SFPB_TIMEOUT_MS         /* default for blocking calls (TX space)           */
#define SFPB_TIMEOUT_MS 100u
#endif
#ifndef SFPB_READY_TIMEOUT_MS   /* READ_ID after a reset (PLL lock, reset release) */
#define SFPB_READY_TIMEOUT_MS 100u
#endif
#ifndef SFPB_I2C_TIMEOUT_MS     /* one I2C command (128 B at 100 kHz ~ 13 ms)      */
#define SFPB_I2C_TIMEOUT_MS 100u
#endif
#ifndef SFPB_EEPROM_WRITE_MS    /* EEPROM write cycle (NACK retries)               */
#define SFPB_EEPROM_WRITE_MS 20u
#endif
#ifndef SFPB_EEPROM_PAGE        /* EEPROM page size: writes never cross a page     */
#define SFPB_EEPROM_PAGE 8u
#endif
#ifndef SFPB_RESET_PULSE_MS     /* HOST_RST_N low time (filter 640 ns)             */
#define SFPB_RESET_PULSE_MS 1u
#endif

/* ---- Hooks ---------------------------------------------------------------------- */
#ifndef SFPB_ASSERT
#define SFPB_ASSERT(x) ((void)0)
#endif

#endif /* SFPB_CONFIG_DEFAULT_H */
