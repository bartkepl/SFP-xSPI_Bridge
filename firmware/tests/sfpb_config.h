/* sfpb_config.h for the host tests: own transport (mock), all features. */
#ifndef SFPB_CONFIG_H
#define SFPB_CONFIG_H

#define SFPB_TRANSPORT   SFPB_TRANSPORT_CUSTOM
#define SFPB_DATA_LINES  8
#define SFPB_USE_I2C     1
#define SFPB_USE_DDM     1
#define SFPB_DDM_EXT_CAL 1
#define SFPB_USE_FLOAT   1
#define SFPB_USE_UART    1
#define SFPB_USE_EVENTS  1

#endif
