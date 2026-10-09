/*
 * sfpb_config.h - configuration of the SFP-xSPI bridge library.
 *
 * Copy this file as sfpb_config.h to a directory on the include path of the
 * application and adjust. Every option left undefined takes the default from
 * include/sfpb_config_default.h.
 */
#ifndef SFPB_CONFIG_H
#define SFPB_CONFIG_H

/* ---- Transport ---------------------------------------------------------------
 * SFPB_TRANSPORT_OSPI   HAL_OSPI  (STM32L4+, L5, U5, H7A3/B3, H72x/73x)
 * SFPB_TRANSPORT_XSPI   HAL_XSPI  (STM32H5, H7R/S, N6)
 * SFPB_TRANSPORT_QSPI   HAL_QSPI  (STM32F4, F7, H7, L4, G4)
 * SFPB_TRANSPORT_SPI    HAL_SPI + GPIO chip select (any STM32)
 * SFPB_TRANSPORT_CUSTOM own sfpb_port_t passed to sfpb_init()                  */
#define SFPB_TRANSPORT       SFPB_TRANSPORT_OSPI

/* Data lines of TX_WRITE / RX_READ: 8 (OSPI/XSPI), 4 (QSPI), 1 (SPI). */
#define SFPB_DATA_LINES      8

/* HAL header (CubeMX: main.h). */
#define SFPB_HAL_HEADER      "main.h"

/* Peripheral handle of the default port (name of the CubeMX global). */
#define SFPB_OSPI_HANDLE     hospi1
/* #define SFPB_XSPI_HANDLE  hxspi1 */
/* #define SFPB_QSPI_HANDLE  hqspi  */
/* #define SFPB_SPI_HANDLE   hspi1  */
/* #define SFPB_SPI_CS_PORT  GPIOA       SPI transport: chip select */
/* #define SFPB_SPI_CS_PIN   GPIO_PIN_4 */

/* HOST_RST_N (optional): hardware reset, return from the UART / echo mode. */
/* #define SFPB_RST_PORT     GPIOB */
/* #define SFPB_RST_PIN      GPIO_PIN_0 */

/* DMA for data phases >= SFPB_DMA_MIN_LEN bytes (DMA set up in CubeMX). */
#define SFPB_USE_DMA         0
/* #define SFPB_DMA_MIN_LEN  32 */

/* ---- Features (1 = compiled in) ---------------------------------------------- */
#define SFPB_USE_I2C         1    /* SFP memory, serial ID                      */
#define SFPB_USE_DDM         1    /* digital diagnostics                        */
#define SFPB_DDM_EXT_CAL     1    /* external calibration (float)               */
#define SFPB_USE_FLOAT       1    /* sfpb_nw_to_dbm()                           */
#define SFPB_USE_UART        1    /* UART mode, echo, UART_STATUS               */
#define SFPB_USE_EVENTS      1    /* sfpb_process() + callbacks                 */

/* IRQ_EN after sfpb_init() and after every reset. */
/* #define SFPB_IRQ_MASK_DEFAULT (SFPB_IRQ_RX_FRAME | SFPB_IRQ_LINK_CHG | SFPB_IRQ_SFP_CHG | SFPB_IRQ_ERR) */

/* Receive buffer inside sfpb_t used by sfpb_process() (max. payload 1024). */
/* #define SFPB_RX_BUF_SIZE  1024 */

/* ---- Timeouts [ms] ------------------------------------------------------------- */
/* #define SFPB_TIMEOUT_MS        100   TX space wait of sfpb_send()             */
/* #define SFPB_READY_TIMEOUT_MS  100   READ_ID after a reset                    */
/* #define SFPB_I2C_TIMEOUT_MS    100   one I2C command                          */
/* #define SFPB_EEPROM_WRITE_MS    20   NACK retries after an EEPROM write       */
/* #define SFPB_EEPROM_PAGE         8   EEPROM page size                         */
/* #define SFPB_HAL_TIMEOUT_MS     10   one HAL transfer                         */

#endif /* SFPB_CONFIG_H */
