/*
 * sfpb_internal.h - helpers shared by the library sources (not public).
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef SFPB_INTERNAL_H
#define SFPB_INTERNAL_H

#include "sfp_bridge.h"

int      sfpb__xfer(sfpb_t *dev, uint8_t opcode, int has_addr, uint8_t addr, uint8_t dummy,
                    uint8_t lines, sfpb_dir_t dir, uint8_t *data, size_t len);
uint32_t sfpb__now(const sfpb_t *dev);
uint32_t sfpb__elapsed(const sfpb_t *dev, uint32_t t0);
void     sfpb__delay(const sfpb_t *dev, uint32_t ms);

#endif /* SFPB_INTERNAL_H */
