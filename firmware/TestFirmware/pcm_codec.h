#pragma once

#include <stddef.h>
#include <stdint.h>

size_t pcmCodecEncodeUplinkFrame(const int16_t *pcmSamples, size_t sampleCount,
                                  uint8_t *out, size_t outCapacity);

size_t pcmCodecDecodeDownlinkFrame(const uint8_t *frame, size_t frameLen,
                                    int16_t *outSamples, size_t outCapacitySamples);
